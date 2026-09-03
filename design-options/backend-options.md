# Backend options — Fabric Spark → on-premises SQL Server over ExpressRoute

**Drafted:** 2026-08-26
**Status:** Design only — no build work started. Resolves the *"Deferred — backend pool track"* section of `fabric-mpe-tracker.md`.
**Scope:** what sits behind the internal load balancer and the Private Link Service. The control-plane chain (Fabric → MPE → PLS) is already proven end-to-end at P4 and is **not** revisited here.

---

## 1. The scenario, stated precisely

| Element | Value |
| --- | --- |
| Consumer | **Fabric Spark notebooks** (JDBC, TDS/1433) |
| Data source | **On-premises SQL Server**, physically in the corporate datacenter |
| Existing connectivity | **ExpressRoute circuit → ExpressRoute Gateway** in Azure |
| Required property | Traffic never traverses the public internet |
| Already built (lab) | Fabric MPE → PLS → ILB, approved both sides, DNS resolving to `10.250.0.7` |

**Naming convention used throughout:** **`MPE-Azure-infra-VNet`** = the customer VNet holding the Azure-side landing infrastructure — PLS, ILB, and whatever backend terminates the connection. It is deliberately distinguished from the **hub VNet**, which holds the `GatewaySubnet` / ExpressRoute Gateway and, in most landing zones, the Azure Firewall or NVA.

**Why an MPE at all — the question to answer first.** Fabric's normal answer for on-premises data is the **on-premises data gateway (OPDG)**. It does not apply here: managed private endpoints exist precisely because *Data Engineering* workloads have no gateway path. The supported item list is **notebooks (Spark and Python runtimes), lakehouses, Spark job definitions**, plus Eventstream — and nothing else.

> Fabric Data Engineering workloads: This includes notebooks (Spark and Python runtimes), lakehouses, and Spark job definitions.
> — [Overview of managed private endpoints](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-overview)

So: **if the requirement is literally "a Spark notebook issues a query against on-prem SQL," the MPE → PLS chain is the only path.** If the requirement is actually "notebook code needs the *data*," Option D below removes the entire network problem. That distinction is worth forcing the customer to make explicitly — it is the single highest-leverage question in this design.

---

## 2. The one constraint that generates every option

There is no private-link resource type for a server sitting in someone's datacenter. A PLS is therefore the only way in, and a PLS inherits its reachability from a Standard Load Balancer:

> **Backend pool must be NIC-based.** PLS is supported only on a Standard LB whose backend pool is configured **by NIC**. Backend pools configured **by IP address are NOT supported.**
> — recorded in `fabric-mpe-tracker.md` from [Private Link service limitations](https://learn.microsoft.com/en-us/azure/private-link/private-link-service-overview)

An on-premises IP address is not a NIC in your VNet. **It can never be placed in the backend pool.** Every option below is a different answer to the same forced question:

> *Something inside the VNet must receive the connection and re-originate it toward on-prem. What is that something?*

- **A / B** — a VM, either NAT-forwarding or proxying.
- **C** — nothing; a preview feature that removes the load balancer requirement entirely.
- **D** — nothing; move the data instead of the connection.

---

## 3. Options

### Option A — NAT VMs behind the ILB (iptables DNAT + MASQUERADE)

**This is the second image, and it is the documented Microsoft pattern.**

Source: [Tutorial: access on-premises SQL Server from Data Factory Managed VNet using Private Endpoint](https://learn.microsoft.com/en-us/azure/data-factory/tutorial-managed-virtual-network-on-premise-sql-server). ADF's Managed VNet and Fabric's managed VNet are the **same architecture** — outbound-only managed private endpoints into a customer PLS — so the tutorial transfers essentially unchanged. The customer's diagram is that tutorial.

```
Fabric Spark → MPE (Microsoft VNet) → PLS (NAT to pls-subnet)
             → ILB frontend (fe-subnet) :1433
             → NAT VM ×2 (be-subnet)  ── DNAT :1433 → <on-prem IP>:1433, MASQUERADE
             → ER Gateway → ExpressRoute → on-prem SQL Server
```

Learn's build, condensed:

| Step | Detail |
| --- | --- |
| Subnets | `be-subnet` (VMs), `fe-subnet` (ILB frontend), `pls-subnet` (PLS NAT) |
| ILB | Standard, internal, zone-redundant |
| Rule | TCP 1433 → 1433, idle timeout **15 min**, TCP reset disabled |
| Probe | **TCP port 22** |
| Backend | 2 × Ubuntu VMs, no public IP, in the backend pool |
| Forwarding | `sudo bash ./ip_fwd.sh -i eth0 -f 1433 -a <on-prem IP> -b 1433` |

**Three things Learn tells you that you must not skim past:**

1. > "The configuration within the virtual machine (VM) isn't permanent. This means that each time the VM restarts, it requires reconfiguration."

   A rebooted NAT VM silently stops forwarding. **Not production-viable as written** — the iptables rules and `net.ipv4.ip_forward` must be made durable via `netfilter-persistent` / a systemd unit / cloud-init.

2. > "FQDN doesn't work for on-premises SQL Server unless you add a record in Azure DNS zone."

   The forwarding target is effectively a **static IP**. Option C's "static IP only" limitation is therefore *not* the differentiator it first appears to be — Option A has the same practical constraint.

3. `ip_fwd.sh` is sourced from a **community GitHub repo** (`sajitsasi/az-ip-fwd`), not a Microsoft-shipped artifact. Fine for a lab; expect a customer security review to object. It is ~15 lines of iptables that you can and should vendor into your own IaC.

**The probe is the real defect.** Probing **port 22** proves *the VM booted*. It proves nothing about iptables state, ER routing, or SQL being up. Combine that with defect #1 and you get the worst possible failure mode: **a rebooted VM probes healthy, stays in the pool, and blackholes every connection.** Nothing in the chain reports a fault — Fabric just times out.

---

### Option B — TCP proxy VMs behind the ILB (HAProxy / nginx `stream`)

**This is the first image.** Note that the two diagrams the customer supplied are *not* the same design: one is labelled **"TCP proxy"**, the other **"NAT VM."** Same topology, materially different box. That difference is worth making explicit rather than treating the images as interchangeable.

A real proxy terminates the inbound TCP connection and re-originates a fresh one from the VM's own IP. Consequences, all of them favourable:

| | Option A (NAT) | Option B (proxy) |
| --- | --- | --- |
| Azure `enableIPForwarding` on NIC | Required | **Not required** |
| iptables | Yes | **None** |
| Survives reboot | Manual work | `systemctl enable haproxy` |
| Health probe fidelity | VM liveness only | **True end-to-end** |
| Connection logging / metrics | None | Per-connection |
| TCP Proxy Protocol v2 | Impossible | **Possible** |

**The probe fix — the main reason to prefer B.** HAProxy health-checks on-prem SQL itself and can fail its *own* probe listener when the backend is down, so the ILB removes it from the pool correctly:

```haproxy
frontend sql_in
    bind *:1433
    mode tcp
    timeout client 30m
    default_backend onprem_sql

backend onprem_sql
    mode tcp
    timeout server 30m
    option tcp-check
    server sql1 10.100.5.20:1433 check inter 5s fall 3 rise 2

listen health
    bind *:8080
    mode http
    monitor-uri /healthz
    monitor fail if { nbsrv(onprem_sql) lt 1 }   # ← LB probes this; reflects on-prem reality
```

Point the ILB health probe at **TCP/HTTP 8080 `/healthz`**, not port 22.

**Option B reopens `revisit-proxy-protocol`, and this is a genuinely new fact.** P1 disabled TCP Proxy v2 with sound reasoning: SQL Server cannot parse a PROXY v2 header, so it would arrive as garbage ahead of the TDS handshake. That reasoning holds for Option A (iptables passes bytes through untouched) and for Option C (no backend exists to parse anything). But **HAProxy parses and strips PROXY v2 natively** via `bind *:1433 accept-proxy`. So:

> **Option B is the only design in which TCP Proxy Protocol v2 is implementable at all** — and therefore the only one that can recover the true Fabric source IP and the PLS `linkIdentifier` (captured at P3 for the lab connection) for audit logging.

⚠️ Validate before committing: PLS injects the header into **health probes** too, so the probe listener must tolerate it (bind the `health` listener separately, or add `accept-proxy` to it). Getting this half-right fails as a *health* problem, which is the confusing failure mode P1 already flagged.

---

### Option C — PLS Direct Connect (Public Preview): no load balancer, no VM

[Configure Private Link service Direct Connect](https://learn.microsoft.com/en-us/azure/private-link/configure-private-link-service-direct-connect) attaches a PLS straight to a privately routable destination IP.

```powershell
az network private-link-service create -g <rg> -n pls-directconnect `
  --destination-ip-address 10.100.5.20 --location westus3 `
  --ip-configurations '[{...ipconfig1...},{...ipconfig2...}]'   # minimum 2, in multiples of 2
```

Deletes the ILB, the VMs, the iptables, the patching, the probes — the entire Option A/B apparatus. **West US 3 is a supported preview region**, so it is testable in this exact lab.

#### 🚨 The docs contradict each other, and the contradiction is decisive

**The Fabric doc actively recommends it for this scenario:**

> Common scenarios include: **Direct connection to on-premises databases or servers via ExpressRoute or VPN.**
> — [Connect to on-premises data sources using managed private endpoints](https://learn.microsoft.com/fabric/security/connect-to-on-premise-sources-using-managed-private-endpoints)

**The owning Private Link doc lists the opposite under Limitations:**

> **On-premises connectivity via ExpressRoute**: Routing to on-premises destinations through a **peered virtual network or globally peered virtual network's ExpressRoute gateway is not supported**, as the PLS Direct Connect and ExpressRoute gateway **must be in the same virtual network**.
> — [Configure Private Link service Direct Connect](https://learn.microsoft.com/en-us/azure/private-link/configure-private-link-service-direct-connect)

**Reconciliation:** both are true. On-prem via ER works — but **only if the PLS Direct Connect lives in the same VNet as the ExpressRoute Gateway.** Gateway transit across peering does *not* work for it.

**Why that is the crux of this customer's design.** They said the ER "lands in an ER GW." In effectively every enterprise landing zone that gateway sits in a **hub** VNet, and data workloads sit in **spokes**. So Option C requires **deploying the PLS into the hub VNet itself** — the shared, tightly-governed, platform-team-owned VNet. That is usually a governance conversation, not a technical one, and it is often a hard no.

**This is also precisely what Options A and B are immune to.** A proxy/NAT VM's traffic to on-prem is ordinary VNet egress: peering + "use remote gateway" + BGP-learned routes. It works from any spoke, which is why the pattern exists.

> **Confirm before designing further:** is the ER Gateway in the same VNet the customer intends to host the PLS in? A single question that eliminates or promotes an entire option.

Other preview constraints worth pricing in:

| Constraint | Impact here |
| --- | --- |
| No migration — requires a **new** PLS | An existing PLS cannot be converted; new PLS ⇒ new MPE ⇒ new FQDN ⇒ 15-min cooldown rules apply |
| Feature flag `Microsoft.Network/AllowPrivateLinkserviceUDR` | Subscription-level registration, needs owner rights |
| Min 2 IP configs (multiples of 2, max 8) | Fine |
| **Static destination IP only** | No AG listener failover to a second IP; see §5 |
| Max **10 PLS per region per subscription** | Caps the "one PLS per SQL server" scaling pattern |
| 10 Gbps per Direct Connect | Well above ER capacity in most cases |
| Same region for PE, PLS and client | ✅ MPE already lands `westus3` (proven at P3) |
| PE `NetworkSecurityGroupEnabled` unsupported in preview | **Unverifiable for us** — the PE is in Microsoft's managed VNet; we cannot inspect its network policies |
| CLI / PowerShell / Terraform only | Portal via preview link `aka.ms/PortalPLSDirectConnect` |

---

### Option D — don't cross the network: land the data in OneLake

If the notebook needs the *data* rather than a live TDS session, the correct answer is to stop building network plumbing.

- **Mirroring from SQL Server** — continuous CDC-based replication into OneLake, supported for **SQL Server 2016+**. Requires SQL Server Agent running and CDC enabled; uses an **on-premises data gateway** when the instance isn't publicly reachable. ([Configure Fabric mirrored databases from SQL Server](https://learn.microsoft.com/fabric/mirroring/sql-server))
- **Copy job / Data pipeline via OPDG** → Lakehouse table → notebook reads Delta.

The notebook then reads a Lakehouse table. **No MPE, no PLS, no ILB, no VMs, no ExpressRoute data path, no 1433 exposure, nothing to patch.**

**Where it genuinely fails:** live/interactive queries against current state, `INSERT`/`UPDATE` write-back to on-prem, stored-procedure execution, and reading tables that CDC can't cover. Those are real requirements — but they are *narrower* than "notebooks need on-prem SQL," and the customer has probably not been asked to distinguish them.

---

### Option E — Azure Firewall private-IP DNAT behind PLS Direct Connect (no VMs at all)

**Answers "can AzFW replace the NAT/proxy VMs?" — yes, but only in the Direct Connect topology, never behind the ILB.**

#### First, the hard blocker (which is why this must be Option C's topology, not A/B's)

Azure Firewall **cannot** be a load balancer backend pool member. Two independent, explicit doc statements close this, and they close it twice over:

> Supported only on Standard Load Balancer where backend pool is configured **by NIC**. Not supported on Standard Load Balancer where backend pool is configured by IP address.
> — [Private Link service limitations](https://learn.microsoft.com/en-us/azure/private-link/private-link-service-overview)

> Backend instances in an IP-based backend pool must be **virtual machines or virtual machine scale sets. You can't attach other PaaS services.**
> …
> A load balancer with an IP-based backend pool **can't function as a Private Link service.**
> — [Backend pool management](https://learn.microsoft.com/azure/load-balancer/backend-pool-management)

Both escape routes are sealed: Azure Firewall's NICs are platform-managed and never exposed to you (no NIC-based path), and even if you tried to cheat with an IP-based pool listing the firewall's private IP, that pool (a) may only contain VMs/VMSS and (b) disqualifies the LB from backing a PLS at all. **There is no ILB-based design in which Azure Firewall is the forwarder.**

#### But under Direct Connect it works, and it's elegant

PLS Direct Connect needs a *privately routable destination IP* — it does not care what that IP belongs to. Point it at the **Azure Firewall's private IP** and let the firewall translate:

```
Fabric Spark → MPE → PLS Direct Connect (destinationIpAddress = <azfw-private-ip>)
             → AzFW DNAT rule :1433 → <on-prem SQL>:1433
             → ER Gateway → on-prem SQL Server
```

This is a real, documented Azure Firewall capability — and one of its two headline scenarios is *literally this*:

> **Non-routable networks**: When you need to provide access to resources through networks that aren't directly routable… such as **accessing on-premises resources through Azure Firewall**.
> — [Deploy Azure Firewall private IP DNAT](https://learn.microsoft.com/azure/firewall/tutorial-private-ip-dnat)

| Property | Value |
| --- | --- |
| SKU required | **Standard or Premium**. Basic does **not** support private IP DNAT. |
| Rule shape | Destination = firewall private IP; Translated address = on-prem IP **or FQDN** |
| Logging | `AZFWNatRule` — timestamp, source IP/port, pre- and post-translation destination |

**Three things Option E buys that nothing else does:**

1. **It restores the audit trail P1 gave up.** Disabling TCP Proxy v2 meant losing per-consumer attribution. `AZFWNatRule` logs every translated flow to Log Analytics — different mechanism, same outcome, and it needs no cooperation from SQL Server.
2. **FQDN as the translated address.** AzFW DNAT accepts an FQDN target and resolves it via DNS proxy. This **partially defuses trap #4** (AG listener failover), which otherwise disqualifies plain Direct Connect's static-IP-only rule. Documented caveats: *"If an FQDN resolves to multiple IP addresses… Azure Firewall's DNS proxy selects the first IP address from the list. This behavior is by design"*, and *"If Azure Firewall can't resolve an FQDN, the DNAT rule doesn't match, so the traffic isn't processed"* — a DNS failure becomes a silent no-match rather than an error.
3. **Zero IaaS.** No VMs, no VMSS, no images, no patching, no cloud-init, no iptables. For a customer already running Azure Firewall, the marginal operational cost is one rule.

#### ⚠️ The trap that will break this on first attempt: DNAT without SNAT is asymmetric

Azure Firewall's default SNAT behaviour is the problem:

> By default, Azure Firewall **doesn't use SNAT with network rules when the destination IP address is in a private IP address range** per IANA RFC 1918.
> — [Azure Firewall SNAT private IP address ranges](https://learn.microsoft.com/azure/firewall/snat-private-range)

Follow that through. On-prem SQL is a private range, so no SNAT, so the on-prem server sees the **PLS NAT IP** as source and replies straight to it. That reply crosses ExpressRoute into the VNet and is delivered to the PLS subnet by system route — **never passing back through the firewall.** The reverse DNAT translation never happens, the PLS receives a packet from an address it never sent to, and the connection dies. Symptom: a clean TCP timeout that looks exactly like a firewall *rule* problem and will be misdiagnosed as one.

Two fixes, not equal:

| Fix | Mechanism | Assessment |
| --- | --- | --- |
| **Force SNAT at the firewall** | Set the policy's SNAT private ranges to exclude the on-prem prefix, so AzFW SNATs to its own private IP | ✅ **Preferred.** Self-contained, and gives on-prem a *single stable IP* to allow-list |
| UDR on `GatewaySubnet` | Route the `MPE-Azure-infra-VNet` prefix back via the firewall | ⚠️ Works, but edits a **platform-team-owned** route table on the shared gateway subnet — change-control, and it affects unrelated flows |

**Cost is the honest counterweight.** Azure Firewall Standard costs roughly **an order of magnitude** more than two small proxy VMs before a byte moves, then adds **per-GB data processing** on top. Spark pulling multi-terabyte extracts through a firewall is a line item someone will notice. If the customer *already* runs AzFW, this is marginal. If Option E would stand a firewall up *for this alone*, it is the most expensive option on the page by a wide margin.

---

### Option F — VMSS instead of standalone VMs (a modifier on A/B, not a rival)

**Answers "does VMSS add anything to a NAT or proxy pool?" — it changes nothing about the network path, and it is nonetheless the highest-value change available to Options A and B.**

Supported without question: the same sentence that excludes Azure Firewall explicitly *includes* scale sets — *"must be virtual machines or **virtual machine scale sets**."* VMSS attaching to a Standard LB NIC-based backend pool is the native pattern, so PLS compatibility is unaffected.

The value is that it **structurally repairs the two documented defects** in Learn's pattern rather than patching them:

| Defect (Option A as documented) | Standalone-VM workaround | VMSS resolution |
| --- | --- | --- |
| *"The configuration within the VM isn't permanent… each time the VM restarts, it requires reconfiguration"* | Hand-roll `netfilter-persistent`/systemd and hope nobody SSHes in | **cloud-init in the VMSS model.** Config is declarative; every new or reimaged instance is born correct. The instance becomes disposable. |
| Broken VM stays in the pool and blackholes traffic | Manual detection | **Automatic instance repair** — VMSS watches the LB health probe and reimages/replaces unhealthy instances |
| Patching (trap #8) | Maintenance windows, drift | **Rolling upgrades and in-guest patching.** Note that *image-based* Automatic OS Upgrades are **not** supported under Flexible orchestration, and in-guest patching needs outbound package access — see the egress note below |
| Zone HA | Manually pin 2 VMs to zones | Zone-spanning by configuration |

> **🔗 The compounding insight:** automatic instance repair is driven by a health signal that must reflect reality. With Learn's **port-22** probe it is worthless — a VM that lost its iptables rules still answers SSH, still probes healthy, and is never repaired. With a probe that fails when on-prem SQL is unreachable, instance repair becomes a genuine self-healing loop.
>
> **Option B and Option F are not two improvements. They are one improvement that only works when both halves are present.** That combination is the production shape.

> ### ⚠️ The repair signal is *not* the load balancer probe under Flexible
>
> It is tempting to conclude that instance repair is driven by the load balancer health probe — most scale set documentation and nearly every sample reads that way, because it is true under **Uniform** orchestration. **It is false for Flexible**, which is the mode this document recommends. Learn's unsupported-parameter list is explicit:
>
> > Application health via SLB health probe - use Application Health Extension on instances
> > — [Orchestration modes for Virtual Machine Scale Sets](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes)
>
> The two signals must therefore be designed **separately**: the load balancer probe decides whether an instance *receives traffic*, and the Application Health extension decides whether an instance is *replaced*. The conclusion above survives — a liveness-only signal is worthless either way — but the mechanism does not. A design built on the intuitive reading ships `automaticRepairsPolicy` enabled with **no working repair signal at all**, and fails silently: the policy is present in the template, the portal shows it enabled, and nothing is ever repaired.
>
> A second consequence: the extension probes an endpoint **on the instance**, so the health logic has to run locally. Note that a locally originated reachability test traverses `OUTPUT`, not the DNAT rules in `PREROUTING` — so "is the target reachable" and "are the forwarding rules installed" are genuinely independent questions and both have to be asked.

> ### 🔌 Egress is the hidden decider between A+F and B+F
>
> Scale sets in Flexible orchestration have **no default outbound internet access**, and Azure's platform default outbound access retired in **September 2025**. There is no implicit internet path to inherit.
>
> That turns "which forwarder?" into a question about the *landing zone*, not about elegance:
>
> | Need | iptables (A) | HAProxy (B) |
> | --- | --- | --- |
> | Package install at first boot | **None** — `iptables`, `systemd` and `bash` ship in the Azure Ubuntu image | **Required** — HAProxy is not in the base image |
> | Works in a subnet with zero egress | ✅ | ❌ without a NAT gateway, a private apt mirror, or a prebaked custom image |
>
> Extensions are *not* the obstacle people expect: a supported Azure Linux Agent pulls extension packages through the fabric controller on `168.63.129.16` rather than Azure Storage, so the Application Health extension installs with no internet at all — at the documented cost that initialization *"incurs more delays"* without `*.blob.windows.net` access. ([VM extensions for Linux](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/features-linux))
>
> **So the honest ranking is conditional.** Where egress is permitted, B+F remains better on probe fidelity, logging and Proxy Protocol v2. Where it is not — which is common in the gov and regulated landing zones this repo targets — **A+F is the only option that boots correctly without either a NAT gateway or a custom image pipeline**, and its probe-fidelity gap can be closed with an in-box health responder rather than by adding HAProxy.

**Where VMSS does *not* help, and can hurt:**

- **Autoscale is close to pointless here.** A TCP proxy for JDBC is neither CPU- nor memory-bound; the real ceilings are ExpressRoute bandwidth and SNAT ports, neither of which autoscale metrics observe.
- **Scale-in is actively destructive.** Azure Load Balancer does not drain TCP connections. A scale-in during a Spark job holding a JDBC connection open for forty minutes **kills that read mid-flight**. Fix the instance count or go scale-out-only; if autoscale is mandatory, use a long scale-in cooldown outside batch windows.
- **SNAT port math (Option A only).** With `MASQUERADE`, each instance has ~64K ephemeral ports toward a single on-prem `IP:port` tuple. Spark with a high `numPartitions` opens many parallel JDBC connections. More instances means more source ports — one of the few genuine arguments for scaling out here. Option B's HAProxy makes this observable before it becomes an outage.
- Use **Flexible** orchestration (current default); it supports instance repair and rolling upgrades and attaches to Standard LB NIC-based pools.

**Verdict:** VMSS is not an alternative option, it is the **correct packaging** of Options A and B. Recommend unconditionally for anything beyond a lab.

---

### Option G — third-party NVA (Palo Alto, FortiGate, etc.) in the backend pool

Worth separating from Azure Firewall, because the answer is **the opposite**.

An NVA is a **customer-owned virtual machine with a customer-visible NIC.** It can therefore join a NIC-based LB backend pool — the exact thing Azure Firewall cannot do. If the customer already runs VM-Series firewalls, Option G is "Option B, where the proxy is the appliance they already operate, monitor and audit."

**The catch is the same catch as Direct Connect, wearing a different hat:**

> The backend resources must be in the **same virtual network as the load balancer**.
> — [Backend pool management](https://learn.microsoft.com/azure/load-balancer/backend-pool-management)

Regional Azure Load Balancer does not span VNets. So a **hub-resident NVA cannot back a spoke's ILB.** Option G requires either placing the ILB + PLS in the hub alongside the NVA, or deploying dedicated NVA instances into the `MPE-Azure-infra-VNet`.

> **The recurring shape of this entire design space:** Direct Connect needs the PLS in the ER Gateway's VNet. Option G needs the ILB in the NVA's VNet. **Every option that removes proxy VMs from the `MPE-Azure-infra-VNet` relocates the requirement into the hub instead.** Only the proxy/NAT VM designs (A, B, F) are genuinely spoke-local — which is the real reason the Learn pattern looks the way it does.

---

### Ruled out — and why (so they don't resurface)

| Candidate | Verdict |
| --- | --- |
| ILB backend pool **by IP address** = on-prem IP | ❌ PLS requires **NIC-based** pools — and an IP-based pool disqualifies the LB from backing a PLS entirely. This is the constraint that creates the whole problem. |
| **Azure Firewall in the ILB backend pool** | ❌ Not a VM/VMSS and no customer-visible NIC. Doubly blocked. ✅ *But viable as a **PLS Direct Connect destination** — see Option E.* |
| **Application Gateway** as the forwarder | ❌ L7 HTTP/HTTPS only. TDS is not HTTP. |
| **On-premises data gateway** for the notebook | ❌ No Spark/Data Engineering gateway path — see §1. |
| **NAT Gateway** | ❌ Outbound-to-internet SNAT. Wrong direction, wrong destination. |

---

## 4. Where the firewall sits: hub AzFW/NVA vs the `MPE-Azure-infra-VNet`

The third question — *"what if an AzFW or NVA is in a hub VNet that the `MPE-Azure-infra-VNet` peers to?"* — is really **two different designs** that are easy to conflate and behave completely differently. Separate them before deciding anything.

### 4a. Firewall as an *inspection point* on the egress path (proxy VMs remain)

```
Fabric Spark → MPE → PLS → ILB → proxy VMSS  ┐  MPE-Azure-infra-VNet (spoke)
                                              │  UDR: on-prem prefixes → AzFW private IP
                                              ▼
                          AzFW / NVA → ER Gateway ┐  hub VNet
                                                   ▼
                                            on-prem SQL Server
```

**This works, it is the normal enterprise landing-zone shape, and it is compatible with Options A, B and F unchanged.** The proxy VM's traffic to on-prem is ordinary VNet egress; the firewall is just a hop on the way. Requirements:

| Element | Setting |
| --- | --- |
| Peering (spoke side) | **Use remote gateways** = enabled |
| Peering (hub side) | **Allow gateway transit** = enabled |
| UDR on `be-subnet` | On-prem prefixes → next hop `VirtualAppliance` = AzFW private IP |
| AzFW rule | **Network rule** (L4): `be-subnet` → on-prem prefix, TCP 1433 |
| On-prem firewall | Allow the proxy instance IPs (AzFW does not SNAT to private destinations — see below) |

**Four things to get right, in descending order of how often they bite:**

1. **🚨 Do not put a UDR on `pls-subnet` or `fe-subnet`.** Only the *backend* subnet's egress needs steering. Forcing PLS or load-balancer traffic through the firewall breaks the PLS return path and produces asymmetric routing. This is the most common self-inflicted failure in this topology, and it is tempting precisely because "route everything through the firewall" is the standard governance instruction.
2. **🚨 Check for an existing `GatewaySubnet` UDR.** Many landing zones already route on-prem→spoke return traffic to the firewall for inspection. That is **fine and symmetric** if egress also traverses the firewall — and **fatal if only one direction does**, because AzFW is stateful and drops the out-of-state half. Read the platform team's existing route tables *before* designing, not after the timeout.
3. **Health probes bypass the firewall entirely.** LB probes originate from `168.63.129.16` directly to the backend NIC — they never traverse the UDR or the firewall. Convenient: probes stay green regardless of firewall misconfiguration. Also dangerous: **a firewall rule that blocks SQL will not show up as a probe failure.** Another argument for Option B's `/healthz`, which *does* test the real path.
4. **On-prem sees the proxy VM IPs, not the firewall IP.** Because *"Azure Firewall doesn't use SNAT with network rules when the destination IP address is in a private IP address range"*. Customers routinely assume the opposite and allow-list the wrong address. Note the corollary: **application rules always SNAT** — so if someone "simplifies" the L4 network rule into an application rule, the source IP silently changes and the on-prem allow-list breaks.

**Cost note:** every byte Spark reads from on-prem is billed as AzFW data processing. This is an inspection tax on bulk extracts, not on control traffic — size it against actual table volumes before assuming it's noise.

### 4b. Firewall as the *forwarder* for PLS Direct Connect (no proxy VMs) — Option E in a hub-spoke

Here the hub placement stops being incidental and becomes the crux, because **two different same-VNet rules collide**:

| Rule | Source |
| --- | --- |
| PLS Direct Connect and the ER Gateway must be in the **same VNet** for on-prem destinations | [Direct Connect limitations](https://learn.microsoft.com/en-us/azure/private-link/configure-private-link-service-direct-connect) |
| Direct Connect routes to *"a privately routable destination IP address **within your virtual network**"* | same page |

**The hypothesis worth testing:** if the Direct Connect destination is the **firewall's private IP** rather than the on-prem IP, then from the PLS's point of view the destination is an *Azure* address, and the on-prem hop happens *after* the firewall as an ordinary AzFW egress flow. On that reading, the ER-gateway-same-VNet limitation is satisfied trivially, because the PLS never routes to on-prem at all.

**Honest confidence: unproven.** The phrase *"within your virtual network"* may mean the destination must be in the **same** VNet, not merely reachable across peering. The docs do not say which, and this is exactly the kind of ambiguity that has already bitten this project twice (portal-vs-REST at P2, `visibility=[]` semantics at P1). **Do not design on it — test it.**

**The unambiguous variant, if the test fails:** place the firewall in the **`MPE-Azure-infra-VNet` itself**, alongside the PLS Direct Connect.

```
Fabric Spark → MPE → PLS Direct Connect ─► AzFW (same VNet) ─► peering ─► hub ER GW ─► on-prem
                     └── destination IP is in the same VNet ✅        └── ordinary appliance egress ✅
```

Both same-VNet requirements are then satisfied by construction: the PLS destination is local, and the firewall's onward path to on-prem is a normal peering + gateway-transit egress that the Direct Connect limitation simply does not govern. **Cost is the objection** — a dedicated firewall in the infra VNet, not a shared hub one.

### 4c. Which of the two questions to ask the customer

These collapse into a single decision:

| If the customer says… | Then |
| --- | --- |
| "The hub is shared, platform-owned, and we're not putting data-plane resources in it" | **Options A/B/F in the spoke, with 4a inspection.** Direct Connect and Option G are both off the table. |
| "We can place resources in the hub / the ER GW is in the data VNet" | **Options C or E become available** and delete the VM fleet entirely. |
| "We already run Azure Firewall Standard/Premium in the hub" | **Test 4b.** If it works it's the cheapest *marginal* design on the page. |
| "We run Palo Alto / FortiGate VM-Series" | **Option G**, but the ILB + PLS must move to the NVA's VNet. |

---

## 5. Recommendation

**Primary: Option B + Option F — HAProxy TCP proxy on a VMSS.** Same topology as the documented pattern, so it inherits Learn's credibility, while fixing both of Option A's production defects — reboot persistence and the blind port-22 probe — and it is the only option that keeps TCP Proxy v2 on the table. Critically, it is also the **only family that is spoke-local**: it needs nothing from the hub except normal gateway transit, so it survives every governance answer the customer might give. The cost over Option A is a config file and a VMSS model.

**Do not ship Option A as written.** It is the right *reference*; it is not a production build. If the customer insists on iptables, the reboot-persistence and probe-fidelity gaps must be closed anyway.

> The obvious follow-on — *"at which point the delta to HAProxy is negligible"* — holds only where outbound egress is available. Where it is not, HAProxy costs a NAT gateway or a custom image pipeline while iptables costs nothing, so the delta is the opposite of negligible. See the egress box in Option F.
>
> **`azuredeploy.json` in this repository now implements A+F** — iptables on a Flexible scale set, with reboot persistence, drift reconciliation and a two-part in-box health endpoint driving automatic instance repair. Option B remains the upgrade path wherever egress is permitted and Proxy Protocol v2 or L7 logging is wanted.

**Option E is the most elegant design here, and the most conditional.** Azure Firewall private-IP DNAT behind PLS Direct Connect deletes the entire VM fleet, restores per-flow audit logging that P1 gave up, and can target an FQDN rather than a static IP. It is the right answer *if and only if* the customer already runs AzFW Standard/Premium **and** the placement question in §4b resolves favourably. Standing up a firewall solely for this is the most expensive option on the page.

**Run Option C as a parallel lab experiment, gated on one question.** Ask where the ER Gateway lives. If it is in the VNet that can host the PLS, Direct Connect deletes the VMs and is strictly better. If it is in a hub and the PLS must live in a spoke, **it is disqualified by a documented limitation**, not by preference — and the contradicting Fabric doc will otherwise send the customer down a dead end. This lab is well positioned to settle it empirically: same region, chain already proven, only the tail differs.

**Option G only if the customer already runs VM-Series NVAs** — and only with eyes open that the ILB and PLS must move into the NVA's VNet.

**Raise Option D regardless.** Not as a deflection — as the design question the customer should be answering before anyone provisions a VM.

### At a glance

| | A — NAT VM | **B+F — HAProxy VMSS** | C — Direct Connect | E — AzFW DNAT | G — NVA pool | D — OneLake |
| --- | --- | --- | --- | --- | --- | --- |
| ILB required | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ |
| VMs to operate | 2 | VMSS | none | none | NVAs | none |
| Spoke-local (no hub ask) | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ |
| Preview dependency | — | — | ⚠️ yes | ⚠️ yes (PLS DC) | — | — |
| Survives reboot | ❌ | ✅ | n/a | n/a | ✅ | n/a |
| Probe reflects real health | ❌ | ✅ | n/a | n/a | ✅ | n/a |
| TCP Proxy v2 possible | ❌ | ✅ | ❌ | ❌ | ✅ | n/a |
| Per-flow audit log | ❌ | ✅ | ❌ | ✅ | ✅ | n/a |
| FQDN target (AG listener) | ❌ | ✅ | ❌ | ✅ | ✅ | n/a |
| Relative cost | $ | $ | ¢ | $$$ | $$ | $ |

---

## 6. Traps that apply to every option

| # | Trap | Detail |
| --- | --- | --- |
| 1 | **Windows / Kerberos auth** | On-prem SQL is usually integrated-auth. Fabric Spark pods are **not domain-joined** and there is no Kerberos path. Requires **SQL authentication** (or Entra where supported), credentials in **Key Vault**. *This blocks the scenario independently of every networking choice above and should be validated on day one.* |
| 2 | **Idle timeout stack** | PLS idles at **~5 min** (`fabric-mpe-tracker.md`, P1); the LB rule is separately configurable (Learn uses 15 min). The **shortest wins.** Interactive notebooks hold JDBC connections idle between cells → mid-notebook connection reset. Set TCP keepalive **below 300 s** in the JDBC properties. |
| 3 | **Multiple SQL servers** | One MPE ⇒ one PLS ⇒ one PE IP. Two routes: **(a)** port-map on a single PLS — `1433`→SQL-A, `1434`→SQL-B, with a matching LB rule and forwarder entry each, and the port made **explicit** in the connection string (Learn: *"If it's not explicitly specified, the connection will always time out"*); or **(b)** one PLS per server — cleaner, keeps 1433 everywhere, but burns toward the **10 PLS per region per subscription** cap. |
| 4 | **AG listeners / failover** | Learn flags `ApplicationIntent` and `MultiSubnetFailover` as unsupported through this path. A listener that fails over to a **different IP** breaks Option C outright (static destination IP) and requires reconfiguration in A/B. Design against a stable VIP. |
| 5 | **6-character MPE naming** | Only 6 chars of the MPE name survive into the Azure connection name (P3). `sql-prod-01` and `sql-prod-02` both render `sql-pr`. **Front-load the distinguishing characters:** `p01sql`, `p02sql`. |
| 6 | **On-prem firewall source IP** | A/B with SNAT → on-prem sees the **VM IPs** (2, stable, easy to allow-list). C → on-prem sees the **PLS NAT IPs**. Either way on-prem must have a **return route to the Azure prefix** over ER. Get this into the customer's firewall change request early; it is usually the longest-lead item in the whole build. |
| 7 | **NSG rules** | Inbound to backend: allow **`AzureLoadBalancer`** service tag (probes) + **`pls-subnet` prefix** on the app port — remember PLS NATs, so the source is the NAT IP, never the Fabric IP. Outbound: backend → on-prem prefix on 1433. |
| 8 | **VM lifecycle** | Options A/B reintroduce IaaS the customer thought they'd escaped: patching, 2× zonal VMs for HA, image drift, and config that must live in IaC rather than SSH history. This is the honest cost of A/B versus C. |

---

## 7. Subnet design (closes P5 `subnet-design`)

Everything currently shares `10.0.0.0/24`. Split before the topology grows:

| Subnet | Prefix | Contents | Required setting |
| --- | --- | --- | --- |
| `pls-subnet` | `10.0.1.0/26` | PLS NAT IPs | `privateLinkServiceNetworkPolicies=Disabled` |
| `fe-subnet` | `10.0.2.0/28` | ILB frontend | — |
| `be-subnet` | `10.0.3.0/27` | Proxy / NAT VMs | NSG per trap #7 |

Sizing note carried forward from P4: MPE count **never** consumes your address space — the managed PE resolved to `10.250.0.7`, outside `10.0.0.0/16` entirely. Size `pls-subnet` for **NAT-IP port scale** (8 max per PLS), not for consumers.

Option C collapses this to `pls-subnet` alone — but that subnet must then sit in the **ER Gateway's VNet** (§3).

---

## 8. Next actions

1. ❓ **Ask the customer: where is the ER Gateway — hub VNet or the `MPE-Azure-infra-VNet`?** Gates Options C, E and G simultaneously (§4c).
2. ❓ **Ask the customer: does the notebook need live SQL, or the data?** Gates Option D — and this is the question worth asking first.
3. ❓ **Ask the customer: do they already run Azure Firewall Standard/Premium, or VM-Series NVAs?** Decides whether E or G is nearly free or absurdly expensive.
4. ❓ **Confirm SQL authentication is available** on the target instances (trap #1). A blocker at any layer above.
5. 🔎 **Read the platform team's existing route tables** — specifically any `GatewaySubnet` UDR (§4a #2) — before designing, not after the first timeout.
6. 🔬 Build **Option B + F** in the lab against a simulated "on-prem" VM in a peered VNet — proves the full data plane and finally closes `notebook-validation`.
7. 🔬 Stand up an **Option C** PLS side by side (new PLS + new MPE, per the no-migration rule) and measure the delta.
8. 🔬 **Test the §4b hypothesis**: can a PLS Direct Connect target a private IP in a *peered* VNet, or must the destination be in the same VNet? One experiment, decides Option E's viability in every hub-spoke landing zone. Highest information-per-hour test on this list.
9. 🔁 Re-run `revisit-proxy-protocol` **only** under Option B, where it is implementable.

## References

- [Connect to external or on-premises data sources using managed private endpoints](https://learn.microsoft.com/fabric/security/connect-to-on-premise-sources-using-managed-private-endpoints)
- [Tutorial: access on-premises SQL Server from Data Factory Managed VNet using Private Endpoint](https://learn.microsoft.com/en-us/azure/data-factory/tutorial-managed-virtual-network-on-premise-sql-server) — the pattern in the customer's diagram
- [Configure Private Link service Direct Connect](https://learn.microsoft.com/en-us/azure/private-link/configure-private-link-service-direct-connect) — preview limits, incl. the ER-gateway-same-VNet rule
- [Overview of managed private endpoints for Fabric](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-overview) — supported item types
- [What is Azure Private Link service?](https://learn.microsoft.com/en-us/azure/private-link/private-link-service-overview) — NIC-based backend pool constraint
- [Configure Fabric mirrored databases from SQL Server](https://learn.microsoft.com/fabric/mirroring/sql-server) — Option D
- [Backend pool management](https://learn.microsoft.com/azure/load-balancer/backend-pool-management) — VM/VMSS-only backends, no PaaS, same-VNet rule, IP-based pools can't back a PLS
- [Deploy Azure Firewall private IP DNAT](https://learn.microsoft.com/azure/firewall/tutorial-private-ip-dnat) — Option E; Standard/Premium only
- [Azure Firewall DNAT rules](https://learn.microsoft.com/azure/firewall/destination-nat-rules) — FQDN translation targets, `AZFWNatRule` logging
- [Azure Firewall SNAT private IP address ranges](https://learn.microsoft.com/azure/firewall/snat-private-range) — the asymmetric-routing trap in §4a/§4b
