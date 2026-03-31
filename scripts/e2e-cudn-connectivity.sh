#!/usr/bin/env bash
# End-to-end CUDN checks: pod ↔ echo VM (ping + curl with IP verification).
# Works for both ILB and BGP stacks. Run from a Terraform root that defines
# echo_client_vm_* outputs (cluster_ilb_routing/ or cluster_bgp_routing/), or pass -C.
#
# Requires: oc (logged in), jq, gcloud, terraform in PATH; deploy-cudn-test-pods.sh.
set -euo pipefail

# --- Terminal colors (https://no-color.org/: respect NO_COLOR; optional FORCE_COLOR=1)
init_term_colors() {
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
  local use=0
  if [[ "${FORCE_COLOR:-0}" == "1" || "${FORCE_COLOR:-}" == "yes" ]]; then
    use=1
  elif [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    use=1
  fi
  if [[ "$use" -eq 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
  fi
}

title() {
  printf '\n%s%s━━━ %s ━━━%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET" >&2
}

kv() {
  printf '  %s%-26s%s %s%s%s\n' "$C_CYAN" "$1" "$C_RESET" "$C_BOLD" "$2" "$C_RESET" >&2
}

pass() {
  printf '%s%s[ PASS ]%s %s\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "$1" >&2
}

warn() {
  printf '%s%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2
}

fail() {
  printf '%s%s[ FAIL ]%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2
}

info() {
  printf '%s▸ %s%s\n' "$C_DIM" "$1" "$C_RESET" >&2
}

# Print one shell-escaped command line to stderr (prefix '+', like set -x).
print_cmd_line() {
  local arg
  printf '%s+' "$C_DIM" >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '%s\n' "$C_RESET" >&2
}

verbose_run() {
  print_cmd_line "$@"
  "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_PODS="$SCRIPT_DIR/deploy-cudn-test-pods.sh"

NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
CLUSTER_DIR=""
WAIT_TIMEOUT="${CUDN_TEST_PODS_WAIT_TIMEOUT:-120s}"
DO_DEPLOY=1
PING_IFACE_OVERRIDE="${CUDN_PING_IFACE:-}"
ALLOW_ICMP_FAIL=0
DEPLOY_EXTRA_ARGS=()
E2E_AVOID_BGP_ROUTER=0
BGP_ROUTER_LABEL_KEY="${CUDN_E2E_BGP_ROUTER_LABEL_KEY:-node-role.kubernetes.io/bgp-router}"

usage() {
  echo "CUDN e2e: pod <-> echo VM (ping, curl, verify reflected IPs). ILB or BGP stack."
  echo
  echo "Usage: $(basename "$0") [options]"
  echo "  -C, --cluster-dir DIR   Terraform stack directory (default: current directory)"
  echo "  -n, --namespace NS      CUDN namespace (default: cudn1 or CUDN_NAMESPACE)"
  echo "      --timeout DUR       Passed to deploy-cudn-test-pods oc wait (default: 120s)"
  echo "      --ping-iface IFACE  Force ping -I IFACE (default: auto-detect from netshoot ip -br a)"
  echo "      --allow-icmp-fail   If ping fails, warn and continue (curl still must pass)"
  echo "      --avoid-bgp-router  Schedule test pods on nodes without ${BGP_ROUTER_LABEL_KEY} (fix-bgp-ra Phase 3)"
  echo "      --skip-deploy       Do not run deploy-cudn-test-pods (pods must already be Ready)"
  echo "  -h, --help              This help"
  echo
  echo "Example (from ILB or BGP stack directory):"
  echo "  ../scripts/$(basename "$0")"
  echo "  CUDN_E2E_POD_AVOID_BGP_ROUTERS=1 ../scripts/$(basename "$0")   # strict VM→pod stress (BGP subset)"
  echo "  NO_COLOR=1 disables ANSI colors; FORCE_COLOR=1 forces colors when stderr is not a TTY."
}

init_term_colors

while [[ $# -gt 0 ]]; do
  case $1 in
    -C | --cluster-dir)
      CLUSTER_DIR="$2"
      shift 2
      ;;
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --timeout)
      WAIT_TIMEOUT="$2"
      DEPLOY_EXTRA_ARGS+=(--timeout "$2")
      shift 2
      ;;
    --ping-iface)
      PING_IFACE_OVERRIDE="$2"
      shift 2
      ;;
    --allow-icmp-fail)
      ALLOW_ICMP_FAIL=1
      shift
      ;;
    --avoid-bgp-router)
      E2E_AVOID_BGP_ROUTER=1
      shift
      ;;
    --skip-deploy)
      DO_DEPLOY=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

case "${CUDN_E2E_POD_AVOID_BGP_ROUTERS:-}" in
  1 | true | True | yes | YES) E2E_AVOID_BGP_ROUTER=1 ;;
esac

if [[ "$E2E_AVOID_BGP_ROUTER" -eq 1 ]]; then
  DEPLOY_EXTRA_ARGS+=(--avoid-bgp-router)
fi

if [[ -z "$CLUSTER_DIR" ]]; then
  CLUSTER_DIR="$PWD"
fi
CLUSTER_DIR="$(cd "$CLUSTER_DIR" && pwd)"

for bin in oc jq gcloud terraform; do
  command -v "$bin" >/dev/null 2>&1 || {
    fail "$bin not found on PATH"
    exit 1
  }
done

if [[ ! -f "$DEPLOY_PODS" ]]; then
  fail "missing $DEPLOY_PODS"
  exit 1
fi

CUDN_POD_IP_SH="$CLUSTER_DIR/scripts/cudn-pod-ip.sh"
if [[ ! -f "$CUDN_POD_IP_SH" ]]; then
  fail "expected $CUDN_POD_IP_SH (wrong --cluster-dir?)"
  exit 1
fi

run_deploy() {
  # Bash 3.x + set -u: "${DEPLOY_EXTRA_ARGS[@]}" errors when the array is empty.
  if [[ ${#DEPLOY_EXTRA_ARGS[@]} -gt 0 ]]; then
    verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE" "${DEPLOY_EXTRA_ARGS[@]}"
  else
    verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE"
  fi
}

title "Setup: test pods"
if [[ "$DO_DEPLOY" -eq 1 ]]; then
  run_deploy
else
  verbose_run oc wait --for=condition=Ready pod/netshoot-cudn pod/icanhazip-cudn -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"
fi
pass "CUDN test pods Ready (netshoot-cudn, icanhazip-cudn)"

if [[ "$E2E_AVOID_BGP_ROUTER" -eq 1 ]]; then
  for pod in netshoot-cudn icanhazip-cudn; do
    node="$(oc get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}')"
    if oc get node "$node" -o json | jq -e --arg k "$BGP_ROUTER_LABEL_KEY" '.metadata.labels | has($k)' >/dev/null 2>&1; then
      fail "avoid-bgp-router: pod ${pod} scheduled on router node ${node} (has label ${BGP_ROUTER_LABEL_KEY})"
      exit 1
    fi
  done
  pass "Pods are on non-router nodes (label ${BGP_ROUTER_LABEL_KEY} absent)"
fi

cd "$CLUSTER_DIR"

ECHO_IP="$(terraform output -raw echo_client_vm_internal_ip | tr -d '\r\n')"
ECHO_URL="$(terraform output -raw echo_client_http_url | tr -d '\r\n')"
CLUSTER_NAME="$(terraform output -raw cluster_name | tr -d '\r\n')"
GCP_PROJECT="$(terraform output -raw gcp_project_id | tr -d '\r\n')"
VM_ZONE="$(terraform output -raw echo_client_vm_zone | tr -d '\r\n')"

print_cmd_line bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" netshoot-cudn
NETSHOOT_CUDN_IP="$(bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" netshoot-cudn)"
print_cmd_line bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn
ICAN_CUDN_IP="$(bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn)"

discover_ping_iface() {
  local ip="$1" out
  print_cmd_line oc exec -n "$NAMESPACE" netshoot-cudn -- ip -br a
  out="$(oc exec -n "$NAMESPACE" netshoot-cudn -- ip -br a 2>/dev/null)"
  printf '%s\n' "$out" | awk -v w="$ip" '{ for (i = 3; i <= NF; i++) if ($i ~ "^" w "/") { print $1; exit } }'
}

if [[ -n "$PING_IFACE_OVERRIDE" ]]; then
  PING_IFACE="$PING_IFACE_OVERRIDE"
else
  PING_IFACE="$(discover_ping_iface "$NETSHOOT_CUDN_IP")"
  if [[ -z "$PING_IFACE" ]]; then
    warn "could not auto-detect CUDN iface; falling back to ovn-udn1"
    PING_IFACE="ovn-udn1"
  fi
fi
# ip -br uses peer names like ovn-udn1@if35; ping -I / SO_BINDTODEVICE need ovn-udn1 only.
PING_IFACE="${PING_IFACE%%@*}"

title "CUDN end-to-end run"
kv "namespace" "$NAMESPACE"
kv "cluster-dir" "$CLUSTER_DIR"
if [[ "$E2E_AVOID_BGP_ROUTER" -eq 1 ]]; then
  kv "avoid BGP router nodes" "yes (${BGP_ROUTER_LABEL_KEY})"
fi
kv "netshoot CUDN IP" "$NETSHOOT_CUDN_IP"
kv "ping interface" "$PING_IFACE"
kv "icanhazip CUDN IP" "$ICAN_CUDN_IP"
kv "echo VM IP" "$ECHO_IP"
printf '\n' >&2

title "1/3 Pod → echo VM (ping)"
run_ping_pod_to_vm() {
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 3 "$ECHO_IP"
}

PING_POD_VM_RESULT="pass"
if run_ping_pod_to_vm; then
  pass "Pod → echo VM ICMP (ping -I $PING_IFACE → $ECHO_IP)"
else
  if [[ "$ALLOW_ICMP_FAIL" -eq 1 ]]; then
    PING_POD_VM_RESULT="skipped (ICMP failed; --allow-icmp-fail)"
    warn "Pod → echo VM ping failed — continuing (--allow-icmp-fail); ICMP may be blocked"
  else
    fail "Pod → echo VM ping failed (try --allow-icmp-fail if ICMP is blocked)"
    exit 1
  fi
fi

title "2/3 Pod → echo VM (curl, caller IP)"
curl_retry_pod() {
  local url="$1"
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c \
    'for i in 1 2 3 4 5; do out="$(curl -sS --connect-timeout 5 --max-time 15 "$1")" && printf %s "$out" && exit 0; sleep 2; done; exit 1' \
    sh "$url"
}

body_pod="$(curl_retry_pod "$ECHO_URL" | tr -d '\r')"
info "HTTP body (expected netshoot CUDN IP ${NETSHOOT_CUDN_IP}): ${body_pod}"
if [[ "$body_pod" != "$NETSHOOT_CUDN_IP" ]]; then
  fail "Pod → echo VM curl: expected body ${NETSHOOT_CUDN_IP}, got ${body_pod}"
  exit 1
fi
pass "Pod → echo VM HTTP: reflected IP matches netshoot CUDN address"

title "3/3 Echo VM → pod (ping + curl)"
vm_ssh() {
  # Echo VM has no public IP; SSH uses IAP TCP forwarding (firewall allows 35.235.240.0/20).
  verbose_run gcloud compute ssh "${CLUSTER_NAME}-echo-client" \
    --project="$GCP_PROJECT" \
    --zone="$VM_ZONE" \
    --tunnel-through-iap \
    --command="$1"
}

REMOTE_CMD=$(cat <<EOF
set -euo pipefail
echo '+ ping -c 3 ${ICAN_CUDN_IP}'
ping -c 3 ${ICAN_CUDN_IP}
body=""
for i in 1 2 3 4 5; do
  echo '+ curl -sS --connect-timeout 5 --max-time 15 http://${ICAN_CUDN_IP}:8080/'
  if body=\$(curl -sS --connect-timeout 5 --max-time 15 http://${ICAN_CUDN_IP}:8080/) && [ "\$body" = "${ECHO_IP}" ]; then
    echo "echo VM -> pod curl response (expected caller IP ${ECHO_IP}): \$body"
    exit 0
  fi
  sleep 2
done
echo "Error: expected icanhazip body ${ECHO_IP}, got '\$body'" >&2
exit 1
EOF
)

if vm_ssh "$REMOTE_CMD"; then
  pass "Echo VM → pod ICMP + HTTP: reflected IP matches echo VM (${ECHO_IP})"
else
  fail "Echo VM → pod ping and/or curl failed"
  exit 1
fi

title "Summary"
printf '%s%s✓ All CUDN e2e checks passed%s\n\n' "$C_GREEN" "$C_BOLD" "$C_RESET" >&2
kv "1. Pod → VM ICMP" "$PING_POD_VM_RESULT"
kv "2. Pod → VM HTTP" "pass (body = $NETSHOOT_CUDN_IP)"
kv "3. Echo VM → pod ICMP + HTTP" "pass (body = $ECHO_IP)"
printf '\n' >&2
