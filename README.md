# Private Link forwarding appliance ARM template

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzureGovGuy%2Farm-vnet2-pls-appliance%2Fmain%2Fazuredeploy.json)

This resource-group-scoped ARM template deploys the provider side of a Private Link connection:

- One virtual network with three dedicated subnets
- One Standard internal load balancer
- One private Ubuntu forwarding VM with IP forwarding enabled
- One Private Link Service attached to the load balancer frontend
- NSG rules for Private Link Service traffic and load-balancer health probes
- Reboot-persistent DNAT, SNAT, and forwarding rules managed by systemd

The template does not create Fabric, Azure Data Factory, a managed private endpoint, hub peering, a route table, or the destination service. Those remain customer-owned integration steps.

## Traffic path

```text
Fabric or ADF managed private endpoint
  -> Private Link Service
  -> Standard internal load balancer
  -> forwarding VM
  -> peered hub/spoke network
  -> targetPrivateIp:targetPort
```

The forwarding VM applies both DNAT and MASQUERADE. The target sees the source as the forwarding VM private IP. The target must be reachable from the appliance VNet after the customer creates peering and any required hub routes or firewall rules.

## Deploy

Select the intended Azure commercial subscription first:

```powershell
az cloud set --name AzureCloud
az account set --subscription <subscription-id>
```

Run the helper script with an existing SSH public key:

```powershell
./deploy.ps1 `
  -ResourceGroupName rg-customer-pls-lab `
  -Location eastus2 `
  -TargetPrivateIp 10.40.1.4 `
  -TargetPort 8080 `
  -AdminSshPublicKey (Get-Content ~/.ssh/id_ed25519.pub -Raw) `
  -ConsumerSubscriptionIds <fabric-or-adf-subscription-id>
```

Add `-AutoApproveConsumers` only when private endpoint requests from every listed consumer subscription should be approved automatically. Otherwise, approve each connection on the deployed Private Link Service.

Alternatively, replace placeholders in `azuredeploy.parameters.json` and run:

```powershell
az deployment group create `
  --resource-group rg-customer-pls-lab `
  --template-file azuredeploy.json `
  --parameters '@azuredeploy.parameters.json'
```

## Connect Fabric or ADF

1. Copy the `privateLinkServiceAlias` deployment output.
2. In Fabric or ADF, create a managed private endpoint targeting that alias or the `privateLinkServiceId`, depending on the product workflow.
3. Approve the pending private endpoint connection on the Private Link Service unless auto-approval was enabled.
4. Test the configured TCP port from the managed environment.

This template exposes one TCP port. Deploy another load-balancing rule and matching forwarding rules if the workload requires additional ports.

## Peer to a hub

Before deployment, set `vnetAddressPrefix` and all subnet prefixes to ranges that do not overlap the customer hub, target VNet, or any transit network. Azure VNet peering rejects overlapping address spaces.

Create bidirectional VNet peering between the deployed `virtualNetworkId` output and the customer hub. Enable forwarded traffic on both peerings because the VM forwards packets whose source and destination are not its own address.

If the hub uses Azure Firewall or another NVA, associate a customer-owned route table with `forwarder-subnet` so the target prefix uses that appliance as the next hop. Ensure the return path can reach the forwarding VM subnet. The VM's MASQUERADE rule reduces the return-route requirement to the deployed VNet address space rather than the Fabric or ADF managed VNet.

## Operational notes

- No public IP is assigned to the VM. Admin access must come through the customer's private network or Azure Run Command.
- The load-balancer probe checks the configured target port through the forwarding VM. A failed downstream target makes the backend unhealthy.
- The Linux rules are recreated at every boot by `private-link-forwarder.service`.
- For production, add monitoring, backup, patching, availability-zone design, and at least one additional forwarding VM. This one-VM package is intended for lab validation.