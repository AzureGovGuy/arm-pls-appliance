#!/usr/bin/env bash
# Offline harness for the cloud-init forwarding logic.
#
# Stubs `iptables` with a small state machine and `ip` with a fixed default route, then drives
# the real script through apply / verify / flush / reconcile. Catches map-parsing, chain-handling
# and idempotency bugs without needing a Linux VM.
set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STATE="$WORK/rules"
: > "$STATE"
# Built-in chains always exist in real iptables.
printf 'nat|PREROUTING|__EXISTS__\nnat|POSTROUTING|__EXISTS__\nfilter|FORWARD|__EXISTS__\n' > "$STATE"

mkdir -p "$WORK/bin"

cat > "$WORK/bin/iptables" <<'STUB'
#!/usr/bin/env bash
# Minimal iptables simulator. Records rules as "TABLE|CHAIN|ARGS" lines.
STATE="$PLS_TEST_STATE"
table=filter
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -t) table="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
action="$1"; shift
chain="$1"; shift || true
# -I takes an optional numeric position that is not part of the rule identity.
if [ "$action" = "-I" ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then shift; fi
rule="$*"
key="$table|$chain|$rule"
case "$action" in
  -N) grep -qxF "$table|$chain|__EXISTS__" "$STATE" && exit 1
      echo "$table|$chain|__EXISTS__" >> "$STATE"; exit 0 ;;
  -A|-I) grep -qxF "$table|$chain|__EXISTS__" "$STATE" || exit 1
         echo "$key" >> "$STATE"; exit 0 ;;
  -C) grep -qxF "$key" "$STATE" ;;
  -D) grep -qxF "$key" "$STATE" || exit 1
      grep -vxF "$key" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; exit 0 ;;
  -F) grep -v "^$table|$chain|" "$STATE" > "$STATE.tmp" || true
      mv "$STATE.tmp" "$STATE"
      echo "$table|$chain|__EXISTS__" >> "$STATE"; exit 0 ;;
  -X) grep -v "^$table|$chain|" "$STATE" > "$STATE.tmp" || true
      mv "$STATE.tmp" "$STATE"; exit 0 ;;
  -L) grep "^$table|$chain|" "$STATE" || true; exit 0 ;;
  *) exit 0 ;;
esac
STUB

cat > "$WORK/bin/ip" <<'STUB'
#!/usr/bin/env bash
echo "default via 10.20.1.1 dev eth0 proto dhcp src 10.20.1.4 metric 100"
STUB

chmod +x "$WORK/bin/iptables" "$WORK/bin/ip"

export PLS_TEST_STATE="$STATE"
export PATH="$WORK/bin:$PATH"

# Extract the real script from the rendered cloud-init and retarget its two absolute paths.
python - "$1" "$WORK" <<'PY'
import sys, yaml, os
rendered, work = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(rendered, encoding='utf-8'))
for f in d['write_files']:
    if f['path'].startswith('/usr/local/sbin/'):
        name = os.path.basename(f['path'])
        body = (f['content']
                .replace('/etc/private-link-forwarder/forward.map', os.path.join(work, 'forward.map').replace('\\', '/'))
                .replace('/proc/sys/net/ipv4/ip_forward', os.path.join(work, 'ip_forward').replace('\\', '/'))
                .replace('/usr/local/sbin/private-link-forwarder', os.path.join(work, name and 'private-link-forwarder').replace('\\', '/')))
        open(os.path.join(work, name), 'w', newline='\n', encoding='utf-8').write(body)
PY

FWD="$WORK/private-link-forwarder"
HC="$WORK/private-link-healthcheck"
chmod +x "$FWD" "$HC"

printf '# listenPort targetHost targetPort\n1433 10.100.5.20 1433\n' > "$WORK/forward.map"
printf '1\n' > "$WORK/ip_forward"

pass=0; fail=0
check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 (expected rc=$2 got rc=$3)"; fail=$((fail+1)); fi
}

echo "== apply =="
"$FWD" apply; check "apply succeeds" 0 $?
"$FWD" verify; check "verify passes after apply" 0 $?

dnat=$(grep -c 'DNAT --to-destination 10.100.5.20:1433' "$STATE")
masq=$(grep -c 'MASQUERADE' "$STATE")
echo "  rules: dnat=$dnat masquerade=$masq"
[ "$dnat" = 1 ] && check "exactly one DNAT rule" 0 0 || check "exactly one DNAT rule" 0 1
grep -q 'nat|PLS_FORWARDER|-i eth0 -p tcp --dport 1433' "$STATE"; check "DNAT bound to derived uplink eth0" 0 $?

echo "== idempotency =="
"$FWD" apply >/dev/null 2>&1
"$FWD" apply >/dev/null 2>&1
"$FWD" verify; check "verify passes after repeated apply" 0 $?
dnat2=$(grep -c 'DNAT --to-destination 10.100.5.20:1433' "$STATE")
echo "  dnat rules after 3 applies: $dnat2"
[ "$dnat2" = 1 ] && check "no duplicate rules after repeated apply" 0 0 || check "no duplicate rules after repeated apply" 0 1

echo "== drift detection =="
grep -v 'DNAT --to-destination' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
"$FWD" verify; check "verify fails when a DNAT rule is removed" 1 $?
"$FWD" reconcile >/dev/null 2>&1
"$FWD" verify; check "reconcile repairs the drift" 0 $?

echo "== ip_forward gate =="
printf '0\n' > "$WORK/ip_forward"
"$FWD" verify; check "verify fails when ip_forward is off" 1 $?
printf '1\n' > "$WORK/ip_forward"

echo "== empty map =="
printf '# listenPort targetHost targetPort\n' > "$WORK/forward.map"
"$FWD" verify; check "verify fails on an unconfigured appliance" 1 $?
printf '# listenPort targetHost targetPort\n1433 10.100.5.20 1433\n' > "$WORK/forward.map"
"$FWD" apply >/dev/null 2>&1

echo "== flush =="
"$FWD" flush; check "flush succeeds" 0 $?
"$FWD" verify; check "verify fails after flush" 1 $?
left=$(grep -c 'PLS_FORWARDER' "$STATE" || true)
echo "  residual PLS_FORWARDER entries: $left"
[ "$left" = 0 ] && check "flush removes every owned rule" 0 0 || check "flush removes every owned rule" 0 1

echo "== health responder =="
# Two deterministic branches. Reachability is asserted against a real local listener rather
# than an unroutable address, because bash's /dev/tcp under cygwin reports success for
# addresses that would fail on Linux.
"$FWD" flush >/dev/null 2>&1
out=$(printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n' | "$HC" 2>/dev/null)
echo "$out" | head -1
echo "$out" | grep -q '^HTTP/1.1 200 OK'; check "responds 200 even when unhealthy" 0 $?
echo "$out" | grep -q '"ApplicationHealthState":"Unhealthy"'; check "missing rules report Unhealthy" 0 $?

port=18433
python -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
listener=$!
sleep 2
printf '# listenPort targetHost targetPort\n1433 127.0.0.1 %s\n' "$port" > "$WORK/forward.map"
"$FWD" apply >/dev/null 2>&1
out=$(printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n' | "$HC" 2>/dev/null)
kill "$listener" 2>/dev/null
echo "$out" | grep -q '"ApplicationHealthState":"Healthy"'; check "rules present and target listening report Healthy" 0 $?
echo "$out" | grep -q 'Content-Length:'; check "response carries Content-Length" 0 $?

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
