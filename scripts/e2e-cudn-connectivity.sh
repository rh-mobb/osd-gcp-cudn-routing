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
E2E_RECREATE_TEST_PODS=0

usage() {
  echo "CUDN e2e: pod <-> echo VM (ping, curl, verify reflected IPs). ILB or BGP stack."
  echo
  echo "Usage: $(basename "$0") [options]"
  echo "  -C, --cluster-dir DIR   Terraform stack directory (default: current directory)"
  echo "  -n, --namespace NS      CUDN namespace (default: cudn1 or CUDN_NAMESPACE)"
  echo "      --timeout DUR       Passed to deploy-cudn-test-pods oc wait (default: 120s)"
  echo "      --ping-iface IFACE  Force ping -I IFACE (default: auto-detect from netshoot ip -br a)"
  echo "      --allow-icmp-fail   If ping fails, warn and do not count it toward the final exit code"
  echo "      --recreate-test-pods  Passed to deploy: delete test pods before apply (immutable spec / fresh IPs)"
  echo "      --skip-deploy       Do not run deploy-cudn-test-pods (pods must already be Ready)"
  echo "  -h, --help              This help"
  echo
  echo "Example (from ILB or BGP stack directory):"
  echo "  ../scripts/$(basename "$0")"
  echo "  NO_COLOR=1 disables ANSI colors; FORCE_COLOR=1 forces colors when stderr is not a TTY."
  echo
  echo "Env (optional, positive integers): CUDN_E2E_HTTP_CURL_ATTEMPTS (default 12),"
  echo "  CUDN_E2E_HTTP_CONNECT_TIMEOUT (default 10s), CUDN_E2E_HTTP_MAX_TIME (default 25s),"
  echo "  CUDN_E2E_HTTP_RETRY_SLEEP (default 3s) — used for both pod→VM and VM→pod HTTP probes."
  echo "  CUDN_E2E_RECREATE_TEST_PODS=1 — same as --recreate-test-pods (passed to deploy script)."
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
    --recreate-test-pods)
      E2E_RECREATE_TEST_PODS=1
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

case "${CUDN_E2E_RECREATE_TEST_PODS:-}" in
  1 | true | True | yes | YES) E2E_RECREATE_TEST_PODS=1 ;;
esac

if [[ "$E2E_RECREATE_TEST_PODS" -eq 1 ]]; then
  DEPLOY_EXTRA_ARGS+=(--recreate-test-pods)
fi

if [[ -z "$CLUSTER_DIR" ]]; then
  CLUSTER_DIR="$PWD"
fi
CLUSTER_DIR="$(cd "$CLUSTER_DIR" && pwd)"

# HTTP curl retries (pod↔echo VM); BGP/GCP paths are often slow to converge.
: "${CUDN_E2E_HTTP_CURL_ATTEMPTS:=12}"
: "${CUDN_E2E_HTTP_CONNECT_TIMEOUT:=10}"
: "${CUDN_E2E_HTTP_MAX_TIME:=25}"
: "${CUDN_E2E_HTTP_RETRY_SLEEP:=3}"

e2e_validate_positive_int() {
  local name="$1" val="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
    fail "invalid $name (need positive integer): ${val:-empty}"
    exit 1
  fi
}

e2e_validate_positive_int CUDN_E2E_HTTP_CURL_ATTEMPTS "$CUDN_E2E_HTTP_CURL_ATTEMPTS"
e2e_validate_positive_int CUDN_E2E_HTTP_CONNECT_TIMEOUT "$CUDN_E2E_HTTP_CONNECT_TIMEOUT"
e2e_validate_positive_int CUDN_E2E_HTTP_MAX_TIME "$CUDN_E2E_HTTP_MAX_TIME"
e2e_validate_positive_int CUDN_E2E_HTTP_RETRY_SLEEP "$CUDN_E2E_HTTP_RETRY_SLEEP"

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
kv "netshoot CUDN IP" "$NETSHOOT_CUDN_IP"
kv "ping interface" "$PING_IFACE"
kv "icanhazip CUDN IP" "$ICAN_CUDN_IP"
kv "echo VM IP" "$ECHO_IP"
kv "HTTP curl attempts" "$CUDN_E2E_HTTP_CURL_ATTEMPTS (connect ${CUDN_E2E_HTTP_CONNECT_TIMEOUT}s, max ${CUDN_E2E_HTTP_MAX_TIME}s, sleep ${CUDN_E2E_HTTP_RETRY_SLEEP}s)"
printf '\n' >&2

# Connectivity steps (1–3) always run; failures are summarized and exit 1 only at the end.
E2E_CONNECTIVITY_FAILED=0

title "1/3 Pod → echo VM (ping)"
run_ping_pod_to_vm() {
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 3 "$ECHO_IP"
}

PING_POD_VM_RESULT="pass"
if run_ping_pod_to_vm; then
  pass "Pod → echo VM ICMP (ping -I $PING_IFACE → $ECHO_IP)"
else
  if [[ "$ALLOW_ICMP_FAIL" -eq 1 ]]; then
    PING_POD_VM_RESULT="warn (ICMP failed; --allow-icmp-fail)"
    warn "Pod → echo VM ping failed — continuing (--allow-icmp-fail); ICMP may be blocked"
  else
    PING_POD_VM_RESULT="fail"
    fail "Pod → echo VM ping failed (try --allow-icmp-fail if ICMP is blocked)"
    E2E_CONNECTIVITY_FAILED=$((E2E_CONNECTIVITY_FAILED + 1))
  fi
fi

title "2/3 Pod → echo VM (curl, caller IP)"
curl_retry_pod() {
  local url="$1"
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c \
    'a=$1; cto=$2; mto=$3; sl=$4; url=$5; i=1; \
     while [ "$i" -le "$a" ]; do \
       out="$(curl -sS --connect-timeout "$cto" --max-time "$mto" "$url")" && printf %s "$out" && exit 0; \
       sleep "$sl"; i=$((i + 1)); \
     done; exit 1' \
    sh \
    "$CUDN_E2E_HTTP_CURL_ATTEMPTS" \
    "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
    "$CUDN_E2E_HTTP_MAX_TIME" \
    "$CUDN_E2E_HTTP_RETRY_SLEEP" \
    "$url"
}

set +e
body_pod="$(curl_retry_pod "$ECHO_URL" | tr -d '\r')"
curl_pod_vm_ec=$?
set -e

CURL_POD_VM_RESULT="fail"
info "HTTP body (expected netshoot CUDN IP ${NETSHOOT_CUDN_IP}): ${body_pod}"
if [[ "$curl_pod_vm_ec" -eq 0 ]] && [[ "$body_pod" == "$NETSHOOT_CUDN_IP" ]]; then
  pass "Pod → echo VM HTTP: reflected IP matches netshoot CUDN address"
  CURL_POD_VM_RESULT="pass"
else
  if [[ "$curl_pod_vm_ec" -ne 0 ]]; then
    fail "Pod → echo VM curl: failed or timed out (exit ${curl_pod_vm_ec})"
  else
    fail "Pod → echo VM curl: expected body ${NETSHOOT_CUDN_IP}, got ${body_pod}"
  fi
  E2E_CONNECTIVITY_FAILED=$((E2E_CONNECTIVITY_FAILED + 1))
fi

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
i=1
while [ "\$i" -le ${CUDN_E2E_HTTP_CURL_ATTEMPTS} ]; do
  echo '+ curl -sS --connect-timeout ${CUDN_E2E_HTTP_CONNECT_TIMEOUT} --max-time ${CUDN_E2E_HTTP_MAX_TIME} http://${ICAN_CUDN_IP}:8080/'
  if body=\$(curl -sS --connect-timeout ${CUDN_E2E_HTTP_CONNECT_TIMEOUT} --max-time ${CUDN_E2E_HTTP_MAX_TIME} http://${ICAN_CUDN_IP}:8080/) && [ "\$body" = "${ECHO_IP}" ]; then
    echo "echo VM -> pod curl response (expected caller IP ${ECHO_IP}): \$body"
    exit 0
  fi
  sleep ${CUDN_E2E_HTTP_RETRY_SLEEP}
  i=\$((i + 1))
done
echo "Error: expected icanhazip body ${ECHO_IP}, got '\$body'" >&2
exit 1
EOF
)

VM_TO_POD_RESULT="pass"
set +e
vm_ssh "$REMOTE_CMD"
vm_ssh_ec=$?
set -e
if [[ "$vm_ssh_ec" -eq 0 ]]; then
  pass "Echo VM → pod ICMP + HTTP: reflected IP matches echo VM (${ECHO_IP})"
else
  VM_TO_POD_RESULT="fail"
  fail "Echo VM → pod ping and/or curl failed (exit ${vm_ssh_ec})"
  E2E_CONNECTIVITY_FAILED=$((E2E_CONNECTIVITY_FAILED + 1))
fi

title "Summary"
if [[ "$E2E_CONNECTIVITY_FAILED" -eq 0 ]]; then
  printf '%s%s✓ All CUDN e2e checks passed%s\n\n' "$C_GREEN" "$C_BOLD" "$C_RESET" >&2
else
  printf '%s%s✗ CUDN e2e: %s check(s) failed (see above)%s\n\n' "$C_RED" "$C_BOLD" "$E2E_CONNECTIVITY_FAILED" "$C_RESET" >&2
fi
kv "1. Pod → VM ICMP" "$PING_POD_VM_RESULT"
kv "2. Pod → VM HTTP" "$CURL_POD_VM_RESULT"
kv "3. Echo VM → pod ICMP + HTTP" "$VM_TO_POD_RESULT"
printf '\n' >&2

if [[ "$E2E_CONNECTIVITY_FAILED" -gt 0 ]]; then
  exit 1
fi
