#!/usr/bin/env bash
# Virt live-migration e2e: two CentOS Stream 9 VirtualMachines (DataSource + DataVolume + cloud-init),
# icanhazip-clone in-guest on :8080, probes from netshoot-cudn, live migrate + ping/curl.
# Same manifest style as a hand-written VM (e.g. rh-mobb/rosa-bgp test-vm-cudn.yaml) but with the
# openshift-virtualization DataSource boot disk instead of containerDisk.
#
# Prerequisites: oc, jq, terraform, ssh-keygen; logged-in cluster; CNV; configure-routing CUDN namespace;
# make virt.deploy storage; >=2 schedulable workers for Virt.
#
# Idempotent: oc apply for VMs (stable names + label). Creates CLUSTER_DIR/.virt-e2e/id_ed25519[.pub] for
# cloud-init: user/password + chpasswd (Virt UI), ssh_authorized_keys, packages (podman + mtr/traceroute/tcpdump), runcmd (icanhazip).
# Two VMs on the default pod network for side-by-side console comparison:
#   VIRT_E2E_VM_NAME_BRIDGE (binding.name: l2bridge, rh-mobb/rosa-bgp style) and VIRT_E2E_VM_NAME_MASQ (masquerade: {} / SNAT).
# VIRT_E2E_VM_NAME / --vm-name selects which VM runs live migrations and netshoot probes.
# Default: VIRT_E2E_SKIP_TESTS=0 — after VMs are Ready, runs a connectivity mesh (netshoot↔VMs, icanhazip
# pod, optional echo VM stack). Live migrations are opt-in: --with-migrations, VIRT_E2E_RUN_MIGRATIONS=1, or
# --run-tests (compatibility: connectivity + full migration sequence, same as networking.validate virt phase).
# --access-only / --skip-tests: apply VMs and print console/virtctl hints only (old default behavior).
# virtctl console (primary UDN namespaces: virtctl ssh unsupported; use netshoot jump — see AGENTS.md / KNOWLEDGE.md).
# --cleanup removes all virt-e2e VMs (label) + labeled migration CRs (not .virt-e2e keys/password file).
set -euo pipefail

E2E_RESULT_LOG="${TMPDIR:-/tmp}/e2e-virt-$$.results"
: >"$E2E_RESULT_LOG"
E2E_SUMMARY_DONE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_PODS="$SCRIPT_DIR/deploy-cudn-test-pods.sh"

NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
CLUSTER_DIR=""
: "${VIRT_E2E_VM_NAME_BRIDGE:=virt-e2e-bridge}"
: "${VIRT_E2E_VM_NAME_MASQ:=virt-e2e-masq}"
# Which VM to use for migrations + HTTP/ping probes.
VM_NAME="${VIRT_E2E_VM_NAME:-${VIRT_E2E_VM_NAME_BRIDGE}}"
# Boot disk: cluster DataSource (same family as openshift/centos-stream9-server-small template).
: "${VIRT_E2E_BOOT_DATASOURCE_NAME:=centos-stream9}"
: "${VIRT_E2E_BOOT_DATASOURCE_NAMESPACE:=openshift-virtualization-os-images}"
: "${VIRT_E2E_BOOT_DISK_Gi:=30}"
# Optional: set e.g. ReadWriteMany when your StorageClass requires it for live migration.
: "${VIRT_E2E_BOOT_STORAGE_ACCESS_MODE:=}"
: "${VIRT_E2E_VM_MEMORY:=2Gi}"
: "${VIRT_E2E_VM_CPU:=1}"
# Retained for cudn_cidr IP preference in vmi_probe_ip (CUDN vs pod-network fallbacks).
: "${VIRT_E2E_CUDN_NETWORK_NAME:=bgp-routing-cudn}"
WAIT_TIMEOUT="${CUDN_TEST_PODS_WAIT_TIMEOUT:-600s}"
VM_WAIT_TIMEOUT="${VIRT_E2E_VM_WAIT_TIMEOUT:-900s}"
MIGRATION_WAIT_TIMEOUT="${VIRT_E2E_MIGRATION_WAIT_TIMEOUT:-600s}"
DO_CLEANUP=0
CLEANUP_TEST_PODS=0
SKIP_DEPLOY=0
PING_IFACE_OVERRIDE="${CUDN_PING_IFACE:-}"
ALLOW_ICMP_FAIL=0
DEPLOY_EXTRA_ARGS=()
E2E_RECREATE_TEST_PODS=0

LABEL_VIRT_E2E='routing.osd.redhat.com/virt-e2e'
LABEL_MIGRATION='routing.osd.redhat.com/virt-e2e-migration'

# HTTP probe defaults (align with e2e-cudn-connectivity.sh)
: "${CUDN_E2E_HTTP_CURL_ATTEMPTS:=12}"
: "${CUDN_E2E_HTTP_CONNECT_TIMEOUT:=10}"
: "${CUDN_E2E_HTTP_MAX_TIME:=25}"
: "${CUDN_E2E_HTTP_RETRY_SLEEP:=3}"
# Internet reachability (Phase A): ping + HTTPS fetch (CUDN egress can be ECMP-limited; see KNOWLEDGE.md)
: "${VIRT_E2E_INTERNET_PING_HOST:=8.8.8.8}"
: "${VIRT_E2E_INTERNET_CURL_URL:=https://www.google.com/}"
# If 1 (default), internet probe failures are warnings; if 0 / --strict-internet, the script fails (exit 1)
: "${VIRT_E2E_ALLOW_INTERNET_FAIL:=1}"
: "${VIRT_E2E_INTERNET_CURL_MAX_TIME:=25}"
# MIG2/MIG3 long ping|curl during live migration: auto = echo VM (VPC path / BGP) if Terraform echo exists + gcloud; else netshoot. netshoot = always pod. echo = require echo.
: "${VIRT_E2E_MIG_CONCURRENT_FROM:=auto}"
# 1 = strip gcloud's multi-line "install NumPy for IAP tunnel" tip on stderr. Set 0 to show it (e2e_gcloud_iap* only).
: "${VIRT_E2E_GCLOUD_SUPPRESS_IAP_NUMPY_TIP:=1}"

case "${VIRT_E2E_CLEANUP:-}" in
  1 | true | True | yes | YES) DO_CLEANUP=1 ;;
esac

# 1 = only deploy VMs + print virtctl / console hints. 0 = run connectivity (and optional migrations).
: "${VIRT_E2E_SKIP_TESTS:=0}"
SKIP_TESTS="${VIRT_E2E_SKIP_TESTS}"
case "${SKIP_TESTS}" in
  1 | true | True | yes | YES) SKIP_TESTS=1 ;;
  0 | false | False | no | NO) SKIP_TESTS=0 ;;
  *) SKIP_TESTS=0 ;;
esac
# 1 = run VirtualMachineInstanceMigration sequence. Default 0; use with VIRT_E2E_SKIP_TESTS=0; --run-tests also enables it.
: "${VIRT_E2E_RUN_MIGRATIONS:=0}"
# 1 = include Terraform echo-VM + gcloud checks (when outputs and gcloud exist)
: "${VIRT_E2E_INCLUDE_ECHO_STACK:=1}"
RUN_MIGRATIONS=0
case "${VIRT_E2E_RUN_MIGRATIONS:-}" in
  1 | true | True | yes | YES) RUN_MIGRATIONS=1 ;;
esac
KEY_IN_NETSHOOT="/tmp/virt-e2e-vm-key"
NETSHOOT_CTN="netshoot"
NETSHOOT_KEY_COPIED=""

init_term_colors() {
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
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

title() { printf '\n%s%s━━━ %s ━━━%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET" >&2; }
kv() { printf '  %s%-26s%s %s%s%s\n' "$C_CYAN" "$1" "$C_RESET" "$C_BOLD" "$2" "$C_RESET" >&2; }

# TSV: STATUS|message (for end-of-run e2e_print_test_summary; message sanitized)
e2e_sanitize_log_msg() { printf '%s' "${1-}" | tr '\n' ' ' | tr '|' '/' | head -c 320; }
e2e_result_register() {
  local s="${1-}" m
  m="$(e2e_sanitize_log_msg "${2-}")"
  [[ -n "$E2E_RESULT_LOG" ]] || return 0
  printf '%s|%s\n' "$s" "$m" >>"$E2E_RESULT_LOG"
}

e2e_print_test_summary() {
  # Colors when EXIT runs after a preflight fail (init_term_colors in main not reached)
  if [[ -z "${C_GREEN:-}" ]]; then
    init_term_colors
  fi
  [[ -n "$E2E_RESULT_LOG" && -s "$E2E_RESULT_LOG" ]] || return 0
  if [[ "$E2E_SUMMARY_DONE" -eq 1 ]]; then
    return 0
  fi
  E2E_SUMMARY_DONE=1
  title "Test result summary (pass / warn / fail)"
  local line status msg pc wc fc n
  pc=0
  wc=0
  fc=0
  n=0
  # Do not use "read ... || true" — on EOF that makes the while-test succeed and loops forever.
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" ]] && continue
    status="${line%%|*}"
    msg="${line#*|}"
    n=$((n + 1))
    case "$status" in
    PASS) pc=$((pc + 1)) ; printf '  %s[ PASS ]%s  %s\n' "$C_GREEN" "$C_RESET" "$msg" >&2 ;;
    WARN) wc=$((wc + 1)) ; printf '  %s[ WARN ]%s  %s\n' "$C_YELLOW" "$C_RESET" "$msg" >&2 ;;
    FAIL) fc=$((fc + 1)) ; printf '  %s[ FAIL ]%s  %s\n' "$C_RED" "$C_RESET" "$msg" >&2 ;;
    *) printf '  [ %s ]  %s\n' "$status" "$msg" >&2 ;;
    esac
  done <"$E2E_RESULT_LOG" 2>/dev/null
  printf '\n' >&2
  printf '  %s── Totals: %d passed, %d warned, %d failed (%d checks)%s\n' \
    "$C_DIM" "$pc" "$wc" "$fc" "$n" "$C_RESET" >&2
}

# EXIT: print a summary on failure (success paths call e2e_print before cleanup) and remove the temp log
e2e_exit_test_summary() {
  if [[ "${E2E_SUMMARY_DONE:-0}" -eq 0 && -n "${E2E_RESULT_LOG:-}" && -s "$E2E_RESULT_LOG" ]]; then
    e2e_print_test_summary
  fi
  if [[ -n "$E2E_RESULT_LOG" && -f "$E2E_RESULT_LOG" ]]; then
    rm -f "$E2E_RESULT_LOG" 2>/dev/null || true
  fi
  E2E_RESULT_LOG=""
}
trap e2e_exit_test_summary EXIT

pass() {
  e2e_result_register PASS "$1"
  printf '%s%s[ PASS ]%s %s\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "$1" >&2
}
warn() {
  e2e_result_register WARN "$1"
  printf '%s%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2
}
fail() {
  e2e_result_register FAIL "$1"
  printf '%s%s[ FAIL ]%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2
}
info() { printf '%s▸ %s%s\n' "$C_DIM" "$1" "$C_RESET" >&2; }

print_cmd_line() {
  local arg
  printf '%s+' "$C_DIM" >&2
  for arg in "$@"; do printf ' %q' "$arg" >&2; done
  printf '%s\n' "$C_RESET" >&2
}

verbose_run() {
  print_cmd_line "$@"
  "$@"
}

# gcloud --tunnel-through-iap prints a NumPy / performance tip to stderr. Filter those lines; keep real errors and ssh(1) output.
# Alternative (host-wide): install numpy for gcloud's python + CLOUDSDK_PYTHON_SITEPACKAGES=1 (see gcloud + IAP docs).
_e2e_gcloud_iap_filter_to_stderr() {
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"consider installing NumPy"*) continue ;;
      *"increasing_the_tcp_upload_bandwidth"*) continue ;;
      *"cloud.google.com/iap/docs"*"increasing"*) continue ;; # wrapped doc URL
    esac
    printf '%s\n' "$line" >&2
  done
}

# Run gcloud; use for every compute {ssh,scp} with --tunnel-through-iap. Preserves exit status of gcloud.
e2e_gcloud_iap() {
  if [[ "${VIRT_E2E_GCLOUD_SUPPRESS_IAP_NUMPY_TIP:-1}" -eq 1 ]]; then
    command gcloud "$@" 2> >(_e2e_gcloud_iap_filter_to_stderr)
  else
    command gcloud "$@"
  fi
  return $?
}

e2e_gcloud_iap_verbose() {
  print_cmd_line gcloud "$@"
  e2e_gcloud_iap "$@"
  return $?
}

usage() {
  cat <<EOF
Virt e2e: two VirtualMachines on the default pod network for side-by-side console comparison:
  VIRT_E2E_VM_NAME_BRIDGE (binding.name: l2bridge) and VIRT_E2E_VM_NAME_MASQ (masquerade: {} / SNAT).
Default mode: deploy both VMs + print virtctl console/ssh for each.

Usage: $(basename "$0") [options]

  -C, --cluster-dir DIR     Terraform stack (for cudn_cidr / cudn-pod-ip.sh); default PWD
  -n, --namespace NS        CUDN namespace (default: cudn1 or CUDN_NAMESPACE)
      --vm-name NAME        Target VM for migration phases when --with-migrations / --run-tests (VIRT_E2E_VM_NAME)
      --access-only, --skip-tests
                            Deploy VMs + print console/virtctl only (VIRT_E2E_SKIP_TESTS=1; no probes)
      --run-tests             Full e2e: connectivity mesh + three migration phases (VIRT_E2E_SKIP_TESTS=0,
                            VIRT_E2E_RUN_MIGRATIONS=1). Same as networking.validate virt default.
      --with-migrations     After connectivity mesh, run live-migration + concurrent ping/curl phases
      --no-migrations         Do not run live migrations (default; connectivity mesh only)
      --skip-echo-stack     Skip pod↔echo VM checks (no gcloud; Terraform must still exist for cudn_cidr)
      --strict-internet     Fail the script if ping 8.8.8.8 / curl to VIRT_E2E_INTERNET_CURL_URL fail (default: warn)
      --timeout DUR         deploy-cudn-test-pods wait (default: 600s)
      --skip-deploy         Do not run deploy-cudn-test-pods (netshoot must be Ready)
      --ping-iface IFACE    Force ping -I IFACE on netshoot
      --allow-icmp-fail     Ping failures warn only (do not fail script)
      --recreate-test-pods  Forward to deploy-cudn-test-pods
      --cleanup             Delete VMs labeled virt-e2e + labeled vmi-migrations; exit (no tests)
      --cleanup-include-test-pods  With --cleanup, also delete netshoot-cudn and icanhazip-cudn
  -h, --help                This help

Env: VIRT_E2E_CLEANUP=1 same as --cleanup.
     VIRT_E2E_SKIP_TESTS: 0 (default) = run connectivity after VMs Ready; 1 = --access-only.
     VIRT_E2E_RUN_MIGRATIONS: 0 (default) or 1; use with SKIP_TESTS=0, or set --with-migrations / --run-tests.
     VIRT_E2E_INCLUDE_ECHO_STACK: 1 (default) — include e2e-cudn style echo-VM + icanhazip pod to VPC VM checks.
     VIRT_E2E_INTERNET_PING_HOST (default 8.8.8.8), VIRT_E2E_INTERNET_CURL_URL (default https://www.google.com/),
       VIRT_E2E_INTERNET_CURL_MAX_TIME (default 25) — after mesh + echo, test from netshoot, icanhazip pod, both guests, echo VM.
     VIRT_E2E_ALLOW_INTERNET_FAIL: 1 (default) = warn on internet failures; 0 or --strict-internet = exit 1 (CUDN internet is often ECMP-limited).
     CUDN_E2E_HTTP_* for curl retries (probes and migrations when enabled).
     VIRT_E2E_MIG_CONCURRENT_FROM: auto|echo|netshoot — where MIG2/MIG3 (ping|curl) run during live migration. auto uses the Terraform echo client VM (gcloud IAP) when cluster_name, gcp_project_id, echo_client_vm_*, and gcloud exist; else netshoot. echo = require that path; netshoot = always the CUDN netshoot pod.
     VIRT_E2E_GCLOUD_SUPPRESS_IAP_NUMPY_TIP: 1 (default) = filter gcloud's "install NumPy" IAP tunnel note on stderr; 0 to print it (host can also use CLOUDSDK_PYTHON_SITEPACKAGES + numpy for gcloud's Python).
     VIRT_E2E_VM_NAME_BRIDGE: l2bridge-binding VM name (default: virt-e2e-bridge).
     VIRT_E2E_VM_NAME_MASQ: masquerade VM name (default: virt-e2e-masq).
     VIRT_E2E_VM_NAME: migration + ping/curl target (default: virt-e2e-bridge; also accepts virt-e2e-masq).
     VIRT_E2E_CUDN_NETWORK_NAME: unused for interface spec; optional hint for IP selection vs Terraform cudn_cidr.
     VIRT_E2E_BOOT_DATASOURCE_NAME / VIRT_E2E_BOOT_DATASOURCE_NAMESPACE: DataSource for root disk
       (defaults: centos-stream9 / openshift-virtualization-os-images). VIRT_E2E_BOOT_DISK_Gi (default 30).
     VIRT_E2E_BOOT_STORAGE_ACCESS_MODE: optional PVC access mode for the DataVolume (e.g. ReadWriteMany).
     VIRT_E2E_VM_MEMORY / VIRT_E2E_VM_CPU: domain resources.requests (defaults 2Gi / 1).
     VIRT_E2E_CONSOLE_PASSWORD: optional; if unset, a random alphanumeric password is generated and
       stored in CLUSTER_DIR/.virt-e2e/console-password (reused on reruns). Avoid ':' and '#' in a custom password.

Note: masquerade binding is NOT supported with primary UDN namespaces (KubeVirt: "Masquerade is only
  allowed to connect to the pod network"). Both VMs connect to the pod network (networks: default/pod);
  the bridge VM gets a CUDN IP when the namespace is a primary UDN, while the masq VM is always SNAT'd.

Console (primary UDN namespaces, e.g. cudn1 — no virtctl ssh per product docs):
  virtctl console vmi/VM_NAME -n NAMESPACE
  Login: cloud-user / password printed by this script (also CLUSTER_DIR/.virt-e2e/console-password).

virtctl must match KubeVirt on the cluster. Run virtctl version — if Client Version and Server Version differ,
  install virtctl from this cluster's OpenShift release: web console Help (?) → Command line tools → virtctl.

If versions already match but you still get "Can't connect to websocket (404)" / bad handshake (while the web UI
  console works): WebSockets go to the Kubernetes API — unset HTTP_PROXY/HTTPS_PROXY for that shell, or add the
  API hostname from "oc whoami --show-server" to NO_PROXY; check "oc get apiservice | grep subresources.kubevirt.io"
  shows AVAILABLE=True; try "virtctl console vmi/VM_NAME -n NAMESPACE". See ARCHITECTURE.md (VM-Specific Considerations).

SSH keypair CLUSTER_DIR/.virt-e2e/id_ed25519 is in cloud-init; virtctl ssh is printed (primary UDN may not support ssh per product docs).
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -C | --cluster-dir) CLUSTER_DIR="$2"; shift 2 ;;
    -n | --namespace) NAMESPACE="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --skip-tests | --access-only) SKIP_TESTS=1; shift ;;
    --run-tests) SKIP_TESTS=0; RUN_MIGRATIONS=1; shift ;;
    --with-migrations) RUN_MIGRATIONS=1; shift ;;
    --no-migrations) RUN_MIGRATIONS=0; shift ;;
    --skip-echo-stack) VIRT_E2E_INCLUDE_ECHO_STACK=0; shift ;;
    --timeout)
      WAIT_TIMEOUT="$2"
      DEPLOY_EXTRA_ARGS+=(--timeout "$2")
      shift 2
      ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --ping-iface) PING_IFACE_OVERRIDE="$2"; shift 2 ;;
    --allow-icmp-fail) ALLOW_ICMP_FAIL=1; shift ;;
    --strict-internet) VIRT_E2E_ALLOW_INTERNET_FAIL=0; shift ;;
    --recreate-test-pods) E2E_RECREATE_TEST_PODS=1; shift ;;
    --cleanup) DO_CLEANUP=1; shift ;;
    --cleanup-include-test-pods) CLEANUP_TEST_PODS=1; DO_CLEANUP=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      fail "unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$SKIP_TESTS" -eq 1 ]]; then
  RUN_MIGRATIONS=0
fi

validate_virt_e2e_migration_target() {
  if [[ "$VM_NAME" != "${VIRT_E2E_VM_NAME_BRIDGE}" && "$VM_NAME" != "${VIRT_E2E_VM_NAME_MASQ}" ]]; then
    fail "VIRT_E2E_VM_NAME / --vm-name must be ${VIRT_E2E_VM_NAME_BRIDGE} or ${VIRT_E2E_VM_NAME_MASQ} (got: ${VM_NAME})"
    exit 1
  fi
}

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

CUDN_POD_IP_SH="$CLUSTER_DIR/scripts/cudn-pod-ip.sh"

init_term_colors

for bin in oc jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    fail "$bin not found on PATH"
    exit 1
  }
done

if [[ ! -f "$DEPLOY_PODS" ]]; then
  fail "missing $DEPLOY_PODS"
  exit 1
fi
if [[ ! -f "$CUDN_POD_IP_SH" ]]; then
  fail "expected $CUDN_POD_IP_SH (wrong --cluster-dir?)"
  exit 1
fi

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
e2e_validate_positive_int VIRT_E2E_BOOT_DISK_Gi "$VIRT_E2E_BOOT_DISK_Gi"

run_cleanup() {
  title "Cleanup (${NAMESPACE})"
  verbose_run oc delete virtualmachineinstancemigrations -n "$NAMESPACE" -l "${LABEL_MIGRATION}=true" --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
  if oc get virtualmachine -n "$NAMESPACE" -l "${LABEL_VIRT_E2E}=true" -o name >/dev/null 2>&1; then
    verbose_run oc delete virtualmachine -n "$NAMESPACE" -l "${LABEL_VIRT_E2E}=true" --wait=true --timeout=300s
  fi
  if [[ "$CLEANUP_TEST_PODS" -eq 1 ]]; then
    verbose_run oc delete pod -n "$NAMESPACE" netshoot-cudn icanhazip-cudn --ignore-not-found --wait=true --timeout=120s || true
  fi
  pass "Cleanup finished"
}

if [[ "$DO_CLEANUP" -eq 1 ]]; then
  run_cleanup
  exit 0
fi

if [[ "$SKIP_TESTS" -eq 0 && "$RUN_MIGRATIONS" -eq 1 ]]; then
  validate_virt_e2e_migration_target
fi

for bin in ssh-keygen openssl; do
  command -v "$bin" >/dev/null 2>&1 || {
    fail "$bin not found on PATH (required for CLUSTER_DIR/.virt-e2e keypair and console password)"
    exit 1
  }
done

# Populated by ensure_virt_e2e_ssh_keypair / ensure_virt_e2e_console_password; consumed by build_cloud_userdata.
VIRT_E2E_SSH_DIR=""
VIRT_E2E_SSH_KEY=""
VIRT_E2E_SSH_PUB=""
VIRT_E2E_CONSOLE_PASSWORD=""
CLOUD_USERDATA=""

ensure_virt_e2e_ssh_keypair() {
  VIRT_E2E_SSH_DIR="${CLUSTER_DIR}/.virt-e2e"
  VIRT_E2E_SSH_KEY="${VIRT_E2E_SSH_DIR}/id_ed25519"
  VIRT_E2E_SSH_PUB="${VIRT_E2E_SSH_DIR}/id_ed25519.pub"
  mkdir -p "$VIRT_E2E_SSH_DIR"
  chmod 700 "$VIRT_E2E_SSH_DIR" 2>/dev/null || true
  if [[ ! -f "$VIRT_E2E_SSH_KEY" ]]; then
    verbose_run ssh-keygen -t ed25519 -N "" -f "$VIRT_E2E_SSH_KEY" -C "virt-e2e@${NAMESPACE}"
  fi
  chmod 600 "$VIRT_E2E_SSH_KEY" 2>/dev/null || true
  chmod 644 "$VIRT_E2E_SSH_PUB" 2>/dev/null || true
}

ensure_virt_e2e_console_password() {
  local f="${VIRT_E2E_SSH_DIR}/console-password"
  if [[ -n "${VIRT_E2E_CONSOLE_PASSWORD:-}" ]]; then
    printf '%s\n' "$VIRT_E2E_CONSOLE_PASSWORD" >"$f"
    chmod 600 "$f"
  elif [[ -f "$f" ]]; then
    VIRT_E2E_CONSOLE_PASSWORD="$(tr -d '\r\n' <"$f")"
  else
    # Alphanumeric only so cloud-init password and YAML stay unambiguous.
    VIRT_E2E_CONSOLE_PASSWORD="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c24)"
    printf '%s\n' "$VIRT_E2E_CONSOLE_PASSWORD" >"$f"
    chmod 600 "$f"
  fi
  if [[ -z "$VIRT_E2E_CONSOLE_PASSWORD" ]]; then
    fail "VIRT_E2E_CONSOLE_PASSWORD is empty"
    exit 1
  fi
}

# cloud-init: match common-templates (user/password/chpasswd + keys); packages (podman + debug tools) + flat runcmd only.
build_cloud_userdata() {
  local pub_line
  pub_line="$(tr -d '\r\n' <"$VIRT_E2E_SSH_PUB")"
  cat <<EOF
#cloud-config
user: cloud-user
password: ${VIRT_E2E_CONSOLE_PASSWORD}
chpasswd:
  expire: false
ssh_authorized_keys:
  - ${pub_line}
ssh_pwauth: true
package_update: false
packages:
  - mtr
  - podman
  - tcpdump
  - traceroute
runcmd:
  - systemctl stop firewalld || true
  - systemctl disable firewalld || true
  - podman rm -f icanhazip-e2e 2>/dev/null || true
  - podman pull docker.io/thejordanprice/icanhazip-clone:latest
  - >-
    podman run -d --name icanhazip-e2e --restart always --network host
    -w /app docker.io/thejordanprice/icanhazip-clone:latest
    /bin/sh -c 'exec python -m flask run --host=0.0.0.0 --port=8080'
EOF
}

# configure-routing.sh labels CUDN namespaces with this key (primary UDN — virtctl ssh unsupported).
namespace_is_primary_udn() {
  oc get namespace "$NAMESPACE" -o json 2>/dev/null \
    | jq -e '.metadata.labels // {} | has("k8s.ovn.org/primary-user-defined-network")' >/dev/null 2>&1
}

# Emit a v1 List with one kubevirt.io/v1 VirtualMachine (DataVolumeTemplates + cloudInitNoCloud), jq-built for stable apply.
# network_kind: "l2bridge" (binding.name l2bridge, same spelling as rh-mobb/rosa-bgp) or "masquerade" (masquerade: {} / SNAT).
render_virt_e2e_vm_list_json() {
  local out_json="$1"
  local vm_name="$2"
  local network_kind="$3"   # l2bridge | masquerade
  jq -n \
    --arg name "$vm_name" \
    --arg ns "$NAMESPACE" \
    --arg lbl "$LABEL_VIRT_E2E" \
    --arg ud "$CLOUD_USERDATA" \
    --arg dsns "$VIRT_E2E_BOOT_DATASOURCE_NAMESPACE" \
    --arg dsn "$VIRT_E2E_BOOT_DATASOURCE_NAME" \
    --argjson diskGi "$VIRT_E2E_BOOT_DISK_Gi" \
    --arg mem "$VIRT_E2E_VM_MEMORY" \
    --arg cpu "$VIRT_E2E_VM_CPU" \
    --arg accessMode "${VIRT_E2E_BOOT_STORAGE_ACCESS_MODE}" \
    --arg network_kind "$network_kind" \
    '
    {
      kind: "List",
      apiVersion: "v1",
      items: [
        {
          apiVersion: "kubevirt.io/v1",
          kind: "VirtualMachine",
          metadata: {
            name: $name,
            namespace: $ns,
            labels: {
              ($lbl): "true",
              "kubevirt.io/vm": $name,
              "routing.osd.redhat.com/virt-e2e-network": $network_kind
            }
          },
          spec: {
            runStrategy: "Always",
            dataVolumeTemplates: [
              {
                apiVersion: "cdi.kubevirt.io/v1beta1",
                kind: "DataVolume",
                metadata: {name: $name},
                spec: {
                  sourceRef: {kind: "DataSource", name: $dsn, namespace: $dsns},
                  storage: (
                    {resources: {requests: {storage: (($diskGi | tostring) + "Gi")}}}
                    | if $accessMode != "" then . + {accessModes: [$accessMode]} else . end
                  )
                }
              }
            ],
            template: {
              metadata: {labels: {"kubevirt.io/vm": $name}},
              spec: {
                domain: {
                  devices: {
                    disks: [
                      {name: "rootdisk", disk: {bus: "virtio"}},
                      {name: "cloudinitdisk", disk: {bus: "virtio"}}
                    ],
                    interfaces: [
                      if $network_kind == "masquerade"
                      then {name: "default", masquerade: {}}
                      else {name: "default", binding: {name: "l2bridge"}}
                      end
                    ]
                  },
                  resources: {requests: {memory: $mem, cpu: $cpu}}
                },
                networks: [{name: "default", pod: {}}],
                volumes: [
                  {name: "rootdisk", dataVolume: {name: $name}},
                  {name: "cloudinitdisk", cloudInitNoCloud: {userData: $ud}}
                ]
              }
            }
          }
        }
      ]
    }
    ' >"$out_json"
}

apply_virt_e2e_vms() {
  ensure_virt_e2e_ssh_keypair
  ensure_virt_e2e_console_password
  title "Virt e2e credentials (cloud-init)"
  kv "SSH private key" "$VIRT_E2E_SSH_KEY"
  kv "SSH public key" "$VIRT_E2E_SSH_PUB"
  kv "console password file" "${VIRT_E2E_SSH_DIR}/console-password"
  CLOUD_USERDATA="$(build_cloud_userdata)"

  title "Apply VirtualMachines (explicit manifests)"
  if ! oc get datasource -n "$VIRT_E2E_BOOT_DATASOURCE_NAMESPACE" "$VIRT_E2E_BOOT_DATASOURCE_NAME" >/dev/null 2>&1; then
    fail "DataSource not found: ${VIRT_E2E_BOOT_DATASOURCE_NAMESPACE}/${VIRT_E2E_BOOT_DATASOURCE_NAME} (oc get datasource -A | grep -i centos)"
    exit 1
  fi
  kv "boot DataSource" "${VIRT_E2E_BOOT_DATASOURCE_NAMESPACE}/${VIRT_E2E_BOOT_DATASOURCE_NAME}"
  kv "root disk size" "${VIRT_E2E_BOOT_DISK_Gi}Gi"
  kv "network" "default pod network (binding.name l2bridge + masquerade: {})"

  local vm_json
  vm_json="$(mktemp)"

  title "VM ${VIRT_E2E_VM_NAME_BRIDGE} (binding.name: l2bridge)"
  kv "interfaces" "default + binding.name l2bridge"
  render_virt_e2e_vm_list_json "$vm_json" "$VIRT_E2E_VM_NAME_BRIDGE" "l2bridge"
  verbose_run oc apply -n "$NAMESPACE" -f "$vm_json"

  title "VM ${VIRT_E2E_VM_NAME_MASQ} (masquerade / SNAT)"
  kv "interfaces" "default + masquerade {}"
  render_virt_e2e_vm_list_json "$vm_json" "$VIRT_E2E_VM_NAME_MASQ" "masquerade"
  verbose_run oc apply -n "$NAMESPACE" -f "$vm_json"

  rm -f "$vm_json"
  pass "VM manifests applied (idempotent)"
}

ensure_vm_running() {
  local vm="${1:?vm name}"
  title "Start / ensure VM running (${vm})"
  # OpenShift 4.21+ templates use spec.runStrategy; spec.running is deprecated and mutually exclusive.
  local rs
  rs="$(oc get "vm/${vm}" -n "$NAMESPACE" -o json | jq -r '.spec.runStrategy // empty')"
  if [[ -n "$rs" ]]; then
    if [[ "$rs" != "Always" ]]; then
      verbose_run oc patch "virtualmachine/${vm}" -n "$NAMESPACE" --type merge -p '{"spec":{"runStrategy":"Always"}}'
      pass "VM ${vm} runStrategy patched to Always (was: ${rs})"
    else
      pass "VM ${vm} runStrategy already Always"
    fi
  else
    local r
    r="$(oc get "vm/${vm}" -n "$NAMESPACE" -o jsonpath='{.spec.running}' 2>/dev/null || printf 'false')"
    if [[ "$r" != "true" ]]; then
      verbose_run oc patch "virtualmachine/${vm}" -n "$NAMESPACE" --type merge -p '{"spec":{"running":true}}'
    fi
    pass "VM ${vm} spec.running true (legacy)"
  fi
}

wait_vmi_ready() {
  local vm="${1:?vm name}"
  title "Wait for VMI Ready: ${vm} (${VM_WAIT_TIMEOUT})"
  verbose_run oc wait "vmi/${vm}" -n "$NAMESPACE" --for=condition=Ready --timeout="$VM_WAIT_TIMEOUT"
  pass "VMI Ready (${vm})"
}

# Prefer an IP in the Terraform cudn_cidr range when present; else first guest IPv4 (pod-network VMs).
vmi_probe_ip() {
  local vmn="${1:?vm name}"
  local pref doc ip
  pref="$(cudn_prefix)"
  doc="$(oc get "vmi/${vmn}" -n "$NAMESPACE" -o json)"
  ip="$(printf '%s' "$doc" | jq -r --arg pref "$pref" '
    def strip: if . == null or . == "" then empty else split("/")[0] end;
    def allips:
      [
        [ .status.interfaces[]? | (.ipAddress // .ip // empty) | strip ],
        [ .status.interfaces[]? | .ips[]? | strip ]
      ] | add | map(select(. != null and . != ""));
    allips | map(select(test("^[0-9]+\\."))) | unique | .[]
    | select($pref == "" or startswith($pref))
  ' | head -n1)"
  if [[ -z "$ip" ]]; then
    ip="$(printf '%s' "$doc" | jq -r '
      def strip: if . == null or . == "" then empty else split("/")[0] end;
      [
        [ .status.interfaces[]? | (.ipAddress // .ip // empty) | strip ],
        [ .status.interfaces[]? | .ips[]? | strip ]
      ] | add | map(select(. != null and . != "")) | map(select(test("^[0-9]+\\."))) | .[0] // empty
    ')"
  fi
  printf '%s' "$ip"
}

cudn_prefix() {
  local cidr
  cidr="$(cd "$CLUSTER_DIR" && terraform output -raw cudn_cidr 2>/dev/null || true)"
  [[ -z "$cidr" ]] && { printf ''; return; }
  local net="${cidr%/*}"
  local mask="${cidr#*/}"
  mask="${mask:-16}"
  case "$mask" in
    8) printf '%s.' "$(echo "$net" | cut -d. -f1)" ;;
    16) printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
    24) printf '%s.' "$(echo "$net" | cut -d. -f1,2,3)" ;;
    *) printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
  esac
}

discover_ping_iface() {
  local ip="$1" out
  out="$(oc exec -n "$NAMESPACE" netshoot-cudn -- ip -br a 2>/dev/null)"
  printf '%s\n' "$out" | awk -v w="$ip" '{ for (i = 3; i <= NF; i++) if ($i ~ "^" w "/") { print $1; exit } }'
}

preflight_pvc_access_modes() {
  title "Preflight: VM-related PVC access modes (assume migration-capable unless API blocks)"
  local out vm
  for vm in "$VIRT_E2E_VM_NAME_BRIDGE" "$VIRT_E2E_VM_NAME_MASQ"; do
    out="$(oc get pvc -n "$NAMESPACE" -o json 2>/dev/null | jq -r \
      --arg a "$vm" \
      '.items[]? | select((.metadata.labels["vm.kubevirt.io/name"] // "") == $a) | "\(.metadata.name)\t\(.spec.accessModes)\t\(.spec.storageClassName // "n/a")"' 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      info "$out"
    fi
    # When empty: boot disks from our VM spec often use a different label chain — not worth warning.
  done
  pass "Preflight logged"
}

wait_http_vm() {
  local vm_ip="$1"
  local url="http://${vm_ip}:8080/"
  local i=1
  title "Wait HTTP 8080 on VM (${CUDN_E2E_HTTP_CURL_ATTEMPTS} attempts)"
  while [[ "$i" -le "$CUDN_E2E_HTTP_CURL_ATTEMPTS" ]]; do
    if oc exec -n "$NAMESPACE" netshoot-cudn -- curl -sfS \
      --connect-timeout "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
      --max-time "$CUDN_E2E_HTTP_MAX_TIME" \
      "$url" >/dev/null 2>&1; then
      pass "HTTP 8080 reachable on ${vm_ip}"
      return 0
    fi
    sleep "$CUDN_E2E_HTTP_RETRY_SLEEP"
    i=$((i + 1))
  done
  fail "Timed out waiting for HTTP 8080 on ${vm_ip}"
  exit 1
}

ping_vm() {
  local vm_ip="$1"
  local label="$2"
  title "$label: ping VM"
  if oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 3 "$vm_ip"; then
    pass "ping OK ($vm_ip)"
  else
    if [[ "$ALLOW_ICMP_FAIL" -eq 1 ]]; then
      warn "ping failed (--allow-icmp-fail)"
    else
      fail "ping failed"
      exit 1
    fi
  fi
}

curl_vm_body() {
  local vm_ip="$1"
  oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c \
    'a=$1; cto=$2; mto=$3; sl=$4; url=$5; i=1;
     while [ "$i" -le "$a" ]; do
       out="$(curl -sS --connect-timeout "$cto" --max-time "$mto" "$url")" && printf %s "$out" && exit 0
       sleep "$sl"; i=$((i + 1))
     done; exit 1' \
    sh \
    "$CUDN_E2E_HTTP_CURL_ATTEMPTS" \
    "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
    "$CUDN_E2E_HTTP_MAX_TIME" \
    "$CUDN_E2E_HTTP_RETRY_SLEEP" \
    "http://${vm_ip}:8080/"
}

curl_vm_check() {
  local vm_ip="$1"
  local label="$2"
  title "$label: curl VM (icanhazip body = netshoot CUDN IP)"
  local body
  body="$(curl_vm_body "$vm_ip" | tr -d '\r')"
  if [[ "$body" == "$NETSHOOT_CUDN_IP" ]]; then
    pass "curl body matches netshoot CUDN IP"
  else
    fail "expected HTTP body ${NETSHOOT_CUDN_IP}, got '${body}'"
    exit 1
  fi
}

netshoot_ensure_key_copied() {
  if [[ -n "$NETSHOOT_KEY_COPIED" ]]; then
    return 0
  fi
  local key="${VIRT_E2E_SSH_KEY:?}"
  [[ -f "$key" ]] || {
    fail "Missing SSH key ${key} (netshoot → VM needs same key as cloud-init; run apply first)"
    exit 1
  }
  verbose_run oc cp "$key" "${NAMESPACE}/netshoot-cudn:${KEY_IN_NETSHOOT}" -c "$NETSHOOT_CTN"
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -c "$NETSHOOT_CTN" -- chmod 600 "$KEY_IN_NETSHOOT"
  NETSHOOT_KEY_COPIED=1
}

# Non-interactive: oc exec into netshoot → ssh to guest (see virt-ssh.sh and AGENTS.md)
netshoot_vm_ssh() {
  local vmn="${1:?vm name}"
  shift
  netshoot_ensure_key_copied
  local ip
  ip="$(vmi_probe_ip "$vmn")"
  if [[ -z "$ip" ]]; then
    fail "Could not resolve guest IP for vmi/${vmn}"
    exit 1
  fi
  verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -c "$NETSHOOT_CTN" -- \
    ssh -i "$KEY_IN_NETSHOOT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=20 "cloud-user@${ip}" -- "$@"
}

curl_string_expect() {
  local what="${1-}" want="${2-}" got="${3-}"
  if [[ "$got" == "$want" ]]; then
    pass "$what"
  else
    fail "$what — expected '$want', got '$got'"
    exit 1
  fi
}

run_connectivity_mesh() {
  local VM_IP_BRIDGE VM_IP_MASQ
  local body

  title "Connectivity mesh: virt-e2e ↔ icanhazip-cudn (same as e2e-cudn pod)"
  print_cmd_line bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn
  ICAN_CUDN_IP="$(bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn)"
  if [[ -z "$ICAN_CUDN_IP" ]]; then
    fail "icanhazip-cudn CUDN IP not resolvable (cudn-pod-ip.sh)"
    exit 1
  fi
  kv "icanhazip CUDN IP" "$ICAN_CUDN_IP"
  netshoot_ensure_key_copied

  VM_IP_BRIDGE="$(vmi_probe_ip "$VIRT_E2E_VM_NAME_BRIDGE")"
  VM_IP_MASQ="$(vmi_probe_ip "$VIRT_E2E_VM_NAME_MASQ")"
  if [[ -z "$VM_IP_BRIDGE" || -z "$VM_IP_MASQ" ]]; then
    fail "VM guest IP resolution failed (bridge='${VM_IP_BRIDGE}' masq='${VM_IP_MASQ}')"
    exit 1
  fi
  kv "bridge guest IP" "$VM_IP_BRIDGE"
  kv "masq guest IP" "$VM_IP_MASQ"

  wait_http_vm "$VM_IP_BRIDGE"
  wait_http_vm "$VM_IP_MASQ"

  title "Mesh: netshoot → icanhazip-cudn:8080 (body = netshoot IP)"
  body="$(
    oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c \
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
      "http://${ICAN_CUDN_IP}:8080/" 2>/dev/null | tr -d '\r'
  )" || {
    fail "netshoot → icanhazip pod: curl failed"
    exit 1
  }
  curl_string_expect "netshoot → icanhazip: HTTP body" "$NETSHOOT_CUDN_IP" "$body"

  ping_vm "$VM_IP_BRIDGE" "Mesh: netshoot → ${VIRT_E2E_VM_NAME_BRIDGE} (ping)"
  curl_vm_check "$VM_IP_BRIDGE" "Mesh: netshoot → ${VIRT_E2E_VM_NAME_BRIDGE} (HTTP)"
  ping_vm "$VM_IP_MASQ" "Mesh: netshoot → ${VIRT_E2E_VM_NAME_MASQ} (ping)"
  curl_vm_check "$VM_IP_MASQ" "Mesh: netshoot → ${VIRT_E2E_VM_NAME_MASQ} (HTTP)"

  title "Mesh: ${VIRT_E2E_VM_NAME_BRIDGE} → ${VIRT_E2E_VM_NAME_MASQ} (in-guest curl to peer :8080)"
  body="$(
    netshoot_vm_ssh "$VIRT_E2E_VM_NAME_BRIDGE" curl -sS --connect-timeout "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
      --max-time "$CUDN_E2E_HTTP_MAX_TIME" "http://${VM_IP_MASQ}:8080/" 2>/dev/null | tr -d '\r' || true
  )"
  curl_string_expect "in-guest curl: reflected IP on masq" "$VM_IP_BRIDGE" "$body"

  title "Mesh: ${VIRT_E2E_VM_NAME_MASQ} → ${VIRT_E2E_VM_NAME_BRIDGE} (in-guest curl)"
  body="$(
    netshoot_vm_ssh "$VIRT_E2E_VM_NAME_MASQ" curl -sS --connect-timeout "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
      --max-time "$CUDN_E2E_HTTP_MAX_TIME" "http://${VM_IP_BRIDGE}:8080/" 2>/dev/null | tr -d '\r' || true
  )"
  curl_string_expect "in-guest curl: reflected IP on bridge" "$VM_IP_MASQ" "$body"

  title "Mesh: ${VIRT_E2E_VM_NAME_BRIDGE} → icanhazip pod (in-guest curl)"
  body="$(
    netshoot_vm_ssh "$VIRT_E2E_VM_NAME_BRIDGE" curl -sS --connect-timeout "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
      --max-time "$CUDN_E2E_HTTP_MAX_TIME" "http://${ICAN_CUDN_IP}:8080/" 2>/dev/null | tr -d '\r' || true
  )"
  curl_string_expect "in-guest curl: pod sees bridge IP" "$VM_IP_BRIDGE" "$body"

  title "Mesh: ${VIRT_E2E_VM_NAME_MASQ} → icanhazip pod (in-guest curl)"
  body="$(
    netshoot_vm_ssh "$VIRT_E2E_VM_NAME_MASQ" curl -sS --connect-timeout "$CUDN_E2E_HTTP_CONNECT_TIMEOUT" \
      --max-time "$CUDN_E2E_HTTP_MAX_TIME" "http://${ICAN_CUDN_IP}:8080/" 2>/dev/null | tr -d '\r' || true
  )"
  curl_string_expect "in-guest curl: pod sees masq IP" "$VM_IP_MASQ" "$body"

  pass "Connectivity mesh (CUDN pods + virt-e2e) completed"
}

internet_egress_fail() {
  local what="$1"
  if [[ "${VIRT_E2E_ALLOW_INTERNET_FAIL:-1}" -eq 1 ]]; then
    warn "${what} — (VIRT_E2E_ALLOW_INTERNET_FAIL=1: warn only. CUDN internet egress is often ECMP-limited; see KNOWLEDGE.md. Use --strict-internet or VIRT_E2E_ALLOW_INTERNET_FAIL=0 to fail the run.)"
  else
    fail "$what"
    exit 1
  fi
}

# Ping + curl from netshoot, icanhazip pod, both guests, and (if Terraform has one) the echo VM.
# icanhazip image is minimal: HTTPS only (Python), no ICMP in container.
run_internet_reachability_tests() {
  local ig_ping="$VIRT_E2E_INTERNET_PING_HOST" url="$VIRT_E2E_INTERNET_CURL_URL" cmax="$VIRT_E2E_INTERNET_CURL_MAX_TIME"

  title "Internet reachability: ping ${ig_ping} + curl ${url} (CUDN egress; may be flaky on GCP/BGP — KNOWLEDGE.md)"
  kv "VIRT_E2E_INTERNET_PING_HOST" "$ig_ping"
  kv "VIRT_E2E_INTERNET_CURL_URL" "$url"
  netshoot_ensure_key_copied

  title "Internet: netshoot-cudn (ping -I ${PING_IFACE}, then curl)"
  if ! oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 3 "$ig_ping"; then
    internet_egress_fail "netshoot: ping ${ig_ping} failed"
  else
    pass "netshoot: ping ${ig_ping} OK"
  fi
  if ! oc exec -n "$NAMESPACE" netshoot-cudn -- curl -4 -fsS -L --connect-timeout 10 --max-time "$cmax" -o /dev/null "$url"; then
    internet_egress_fail "netshoot: curl ${url} failed"
  else
    pass "netshoot: curl ${url} OK"
  fi

  title "Internet: icanhazip-cudn (HTTPS only — no ICMP: minimal image)"
  if ! oc exec -n "$NAMESPACE" icanhazip-cudn -c icanhazip -- env "VIRT_INTERNET_URL=$url" "VIRT_CMAX=$cmax" python -c "
import os, urllib.request
to = int(os.environ.get('VIRT_CMAX', '25'), 10)
r = urllib.request.urlopen(os.environ['VIRT_INTERNET_URL'], timeout=to)
r.read(64)
"; then
    internet_egress_fail "icanhazip: HTTPS fetch of ${url} failed (image: python, not python3)"
  else
    pass "icanhazip: HTTPS to ${url} (python urllib) OK"
  fi

  title "Internet: ${VIRT_E2E_VM_NAME_BRIDGE} (in-guest)"
  if ! netshoot_vm_ssh "$VIRT_E2E_VM_NAME_BRIDGE" ping -c 3 "$ig_ping"; then
    internet_egress_fail "${VIRT_E2E_VM_NAME_BRIDGE}: ping ${ig_ping} failed"
  else
    pass "${VIRT_E2E_VM_NAME_BRIDGE}: ping OK"
  fi
  if ! netshoot_vm_ssh "$VIRT_E2E_VM_NAME_BRIDGE" curl -4 -fsS -L --connect-timeout 10 --max-time "$cmax" -o /dev/null "$url"; then
    internet_egress_fail "${VIRT_E2E_VM_NAME_BRIDGE}: curl ${url} failed"
  else
    pass "${VIRT_E2E_VM_NAME_BRIDGE}: curl ${url} OK"
  fi

  title "Internet: ${VIRT_E2E_VM_NAME_MASQ} (in-guest)"
  if ! netshoot_vm_ssh "$VIRT_E2E_VM_NAME_MASQ" ping -c 3 "$ig_ping"; then
    internet_egress_fail "${VIRT_E2E_VM_NAME_MASQ}: ping ${ig_ping} failed"
  else
    pass "${VIRT_E2E_VM_NAME_MASQ}: ping OK"
  fi
  if ! netshoot_vm_ssh "$VIRT_E2E_VM_NAME_MASQ" curl -4 -fsS -L --connect-timeout 10 --max-time "$cmax" -o /dev/null "$url"; then
    internet_egress_fail "${VIRT_E2E_VM_NAME_MASQ}: curl ${url} failed"
  else
    pass "${VIRT_E2E_VM_NAME_MASQ}: curl ${url} OK"
  fi

  if [[ "$VIRT_E2E_INCLUDE_ECHO_STACK" != "1" ]] || ! command -v gcloud >/dev/null 2>&1; then
    info "Internet: echo VM gcloud leg skipped (match VIRT_E2E_INCLUDE_ECHO_STACK / gcloud like echo stack)"
  else
    local EIN_IP EIN_C EIN_P EIN_Z
    EIN_IP="$(
      cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_internal_ip 2>/dev/null | tr -d '\r\n' || true
    )"
    if [[ -z "$EIN_IP" ]]; then
      info "Internet: no Terraform echo_client_vm_internal_ip — skip echo VM internet"
    else
      EIN_C="$(cd "$CLUSTER_DIR" && terraform output -raw cluster_name 2>/dev/null | tr -d '\r\n' || true)"
      EIN_P="$(cd "$CLUSTER_DIR" && terraform output -raw gcp_project_id 2>/dev/null | tr -d '\r\n' || true)"
      EIN_Z="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_zone 2>/dev/null | tr -d '\r\n' || true)"
      if [[ -z "$EIN_C" || -z "$EIN_P" || -z "$EIN_Z" ]]; then
        info "Internet: echo VM Terraform context incomplete — skip gcloud"
      else
        title "Internet: echo VM ${EIN_C}-echo-client (gcloud IAP)"
        local IREMOTE
        IREMOTE=$(
          printf 'set -euo pipefail\nping -c 3 %s\ncurl -4 -fsS -L --connect-timeout 10 --max-time %s -o /dev/null %s\necho ok\n' \
            "$ig_ping" "$cmax" "$(printf '%q' "$url")"
        )
        if ! e2e_gcloud_iap_verbose compute ssh "${EIN_C}-echo-client" \
          --project="$EIN_P" --zone="$EIN_Z" --tunnel-through-iap --command="$IREMOTE"; then
          internet_egress_fail "echo VM: internet ping/curl failed"
        else
          pass "echo VM: ping + curl ${url} OK (IAP)"
        fi
      fi
    fi
  fi

  pass "Internet reachability tests finished (VIRT_E2E_ALLOW_INTERNET_FAIL=$VIRT_E2E_ALLOW_INTERNET_FAIL)"
}

# Shared with e2e-cudn-connectivity.sh: VPC echo VM <-> icanhazip pod
run_virt_e2e_echo_stack() {
  if [[ "$VIRT_E2E_INCLUDE_ECHO_STACK" != "1" ]]; then
    title "Echo stack (Terraform echo VM) — skipped (VIRT_E2E_INCLUDE_ECHO_STACK=0 or --skip-echo-stack)"
    return 0
  fi
  if ! command -v gcloud >/dev/null 2>&1; then
    warn "gcloud not on PATH — skip echo-VM / VPC leg (VIRT_E2E_INCLUDE_ECHO_STACK=0 to silence)"
    return 0
  fi
  local ECHO_IP ECHO_URL CLUSTER_NAME GCP_PROJECT VM_ZONE ican
  ECHO_IP="$(
    cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_internal_ip 2>/dev/null | tr -d '\r\n' || true
  )"
  if [[ -z "$ECHO_IP" ]]; then
    warn "No Terraform output echo_client_vm_internal_ip in ${CLUSTER_DIR} — skip echo stack"
    return 0
  fi
  ECHO_URL="$(
    cd "$CLUSTER_DIR" && terraform output -raw echo_client_http_url 2>/dev/null | tr -d '\r\n' || true
  )"
  if [[ -z "$ECHO_URL" ]]; then
    warn "No echo_client_http_url in Terraform — skip echo stack"
    return 0
  fi
  CLUSTER_NAME="$(cd "$CLUSTER_DIR" && terraform output -raw cluster_name 2>/dev/null | tr -d '\r\n' || true)"
  GCP_PROJECT="$(cd "$CLUSTER_DIR" && terraform output -raw gcp_project_id 2>/dev/null | tr -d '\r\n' || true)"
  VM_ZONE="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_zone 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "$CLUSTER_NAME" || -z "$GCP_PROJECT" || -z "$VM_ZONE" ]]; then
    warn "cluster_name / gcp_project_id / echo_client_vm_zone not all in Terraform — skip echo stack"
    return 0
  fi
  ican="${ICAN_CUDN_IP:-}"
  if [[ -z "$ican" ]]; then
    print_cmd_line bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn
    ican="$(bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" icanhazip-cudn)"
  fi
  if [[ -z "$ican" ]]; then
    fail "icanhazip CUDN IP not available for echo stack"
    exit 1
  fi

  title "Echo stack 1/2: netshoot → echo VM (e2e-cudn path)"
  if ! oc exec -n "$NAMESPACE" netshoot-cudn -- ping -I "$PING_IFACE" -c 3 "$ECHO_IP"; then
    if [[ "$ALLOW_ICMP_FAIL" -eq 1 ]]; then
      warn "netshoot → echo VM ping failed (ALLOW_ICMP_FAIL)"
    else
      fail "netshoot → echo VM ping ${ECHO_IP}"
      exit 1
    fi
  else
    pass "netshoot → echo VM ping OK"
  fi

  local body_pod
  body_pod="$(
    oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c \
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
      "$ECHO_URL" 2>/dev/null | tr -d '\r' || true
  )"
  if [[ "$body_pod" == "$NETSHOOT_CUDN_IP" ]]; then
    pass "netshoot → echo VM HTTP: body matches netshoot CUDN IP"
  else
    fail "netshoot → echo VM: expected body ${NETSHOOT_CUDN_IP}, got '${body_pod}'"
    exit 1
  fi

  title "Echo stack 2/2: gcloud (IAP) → echo VM → icanhazip pod (e2e-cudn path)"
  local REMOTE_CMD
  REMOTE_CMD=$(
    cat <<EOF
set -euo pipefail
echo '+ ping -c 3 ${ican}'
ping -c 3 ${ican}
body=""
i=1
while [ "\$i" -le ${CUDN_E2E_HTTP_CURL_ATTEMPTS} ]; do
  if body=\$(curl -sS --connect-timeout ${CUDN_E2E_HTTP_CONNECT_TIMEOUT} --max-time ${CUDN_E2E_HTTP_MAX_TIME} "http://${ican}:8080/") && [ "\$body" = "${ECHO_IP}" ]; then
    echo "ok: echo VM -> pod body: \$body"
    exit 0
  fi
  sleep ${CUDN_E2E_HTTP_RETRY_SLEEP}
  i=\$((i + 1))
done
echo "Error: expected icanhazip body ${ECHO_IP}, got '\$body'" >&2
exit 1
EOF
  )
  if e2e_gcloud_iap_verbose compute ssh "${CLUSTER_NAME}-echo-client" \
    --project="$GCP_PROJECT" --zone="$VM_ZONE" --tunnel-through-iap --command="$REMOTE_CMD"; then
    pass "echo VM → icanhazip pod: ICMP + HTTP (body = echo VM IP ${ECHO_IP})"
  else
    fail "echo VM → icanhazip pod (gcloud IAP ssh)"
    exit 1
  fi
}

migration_delete_if_exists() {
  local name="$1"
  oc delete "virtualmachineinstancemigrations/${name}" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
}

migration_apply() {
  local mig_name="$1"
  migration_delete_if_exists "$mig_name"
  verbose_run oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: ${mig_name}
  namespace: ${NAMESPACE}
  labels:
    ${LABEL_MIGRATION}: "true"
spec:
  vmiName: ${VM_NAME}
EOF
}

migration_wait_succeeded() {
  local mig_name="$1"
  verbose_run oc wait "virtualmachineinstancemigrations/${mig_name}" -n "$NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="$MIGRATION_WAIT_TIMEOUT"
}

vmi_node_name() {
  oc get "vmi/${VM_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}{"\n"}'
}

ensure_two_nodes_for_virt() {
  local cnt
  cnt="$(oc get nodes -o json | jq '[.items[] | select(.spec.unschedulable != true)] | length')"
  if [[ "${cnt:-0}" -lt 2 ]]; then
    fail "Need at least 2 schedulable nodes for live migration (found ${cnt:-0})"
    exit 1
  fi
}

run_migrate_sequence() {
  local mig_name="$1"
  local desc="$2"
  title "$desc: live migrate (${mig_name})"
  local before after
  before="$(vmi_node_name)"
  kv "source node" "$before"
  migration_apply "$mig_name"
  migration_wait_succeeded "$mig_name"
  after="$(vmi_node_name)"
  kv "target node" "$after"
  if [[ "$before" == "$after" ]]; then
    warn "nodeName unchanged after migration (scheduler may have kept same node)"
  else
    pass "VMI moved ${before} -> ${after}"
  fi
}

# Phase B: long ping (MIG2) / curl (MIG3) during live migration. Prefer the Terraform echo client VM
# (IAP) so traffic follows the same VPC/BGP path as the echo stack; else netshoot (CUDN in-cluster path).
# VIRT_E2E_MIG_CONCURRENT_FROM: auto | echo | netshoot
resolve_mig_concurrent_prober() {
  MIG_USE_ECHO=0
  MIG_CURL_EXPECT_BODY="${NETSHOOT_CUDN_IP:-}"
  MIG_ECHO_C="" MIG_ECHO_P="" MIG_ECHO_Z=""

  local m
  m="$(printf '%s' "${VIRT_E2E_MIG_CONCURRENT_FROM:-auto}" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    auto) m=auto ;;
    echo) m="echo" ;; # assign string (not the echo builtin)
    netshoot) m=netshoot ;;
    *) m=auto ;; # tolerate typos: prefer auto
  esac

  if [[ "$m" == "netshoot" ]]; then
    info "Phase B: MIG2/MIG3 concurrent probes from netshoot (VIRT_E2E_MIG_CONCURRENT_FROM=netshoot)"
    MIG_CURL_EXPECT_BODY="${NETSHOOT_CUDN_IP:-}"
    return 0
  fi

  # auto or echo: try Terraform echo + gcloud
  MIG_ECHO_C="$(cd "$CLUSTER_DIR" && terraform output -raw cluster_name 2>/dev/null | tr -d '\r\n' || true)"
  MIG_ECHO_P="$(cd "$CLUSTER_DIR" && terraform output -raw gcp_project_id 2>/dev/null | tr -d '\r\n' || true)"
  MIG_ECHO_Z="$(cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_zone 2>/dev/null | tr -d '\r\n' || true)"
  MIG_CURL_EXPECT_BODY="${NETSHOOT_CUDN_IP:-}"
  local m_echo_ip
  m_echo_ip="$(
    cd "$CLUSTER_DIR" && terraform output -raw echo_client_vm_internal_ip 2>/dev/null | tr -d '\r\n' || true
  )"
  if ! command -v gcloud >/dev/null 2>&1; then
    if [[ "$m" == "echo" ]]; then
      fail "VIRT_E2E_MIG_CONCURRENT_FROM=echo but gcloud not on PATH"
      return 1
    fi
    info "Phase B: gcloud not on PATH — MIG2/MIG3 from netshoot"
    return 0
  fi
  if [[ -n "$MIG_ECHO_C" && -n "$MIG_ECHO_P" && -n "$MIG_ECHO_Z" && -n "$m_echo_ip" ]]; then
    MIG_USE_ECHO=1
    MIG_CURL_EXPECT_BODY="$m_echo_ip"
    kv "Phase B concurrent probe source" "echo VM (${MIG_ECHO_C}-echo-client, IAP) — same path as echo stack"
    kv "MIG3 icanhazip expected (client = echo VM)" "$MIG_CURL_EXPECT_BODY"
    return 0
  fi
  if [[ "$m" == "echo" ]]; then
    fail "VIRT_E2E_MIG_CONCURRENT_FROM=echo: missing cluster_name, gcp_project_id, echo_client_vm_zone, and/or echo_client_vm_internal_ip in ${CLUSTER_DIR}"
    return 1
  fi
  info "Phase B: no Terraform echo client context — MIG2/MIG3 from netshoot (CUDN path). For VPC/BGP-traversing checks, set echo outputs; VIRT_E2E_MIG_CONCURRENT_FROM=netshoot silences this hint"
  MIG_CURL_EXPECT_BODY="${NETSHOOT_CUDN_IP:-}"
  return 0
}

gcloud_mig_instance() {
  printf '%s-echo-client' "$MIG_ECHO_C"
}

# shellcheck disable=SC2029
run_mig2_concurrent_ping() {
  local MIG2 PING_LOG PING_SUMMARY PASS_LOSS_LINE
  MIG2="virt-e2e-mig-during-ping"
  title "Concurrent ping during migration (${MIG2}) (from: $(
    if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then echo "echo VM"; else echo "netshoot"; fi
  ))"
  PING_LOG="/tmp/virt-e2e-mig2-ping-$$.log"

  if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
    local EINST PING_START
    EINST="$(gcloud_mig_instance)"
    # Non-root users on the echo VM: Linux allows ping interval -i 0.2, not 0.1 (see "cannot flood" / 200ms).
    PING_START="set -euo pipefail; rm -f ${PING_LOG}; nohup ping -c 400 -i 0.2 ${VM_IP} >${PING_LOG} 2>&1 &"
    if ! e2e_gcloud_iap_verbose compute ssh "$EINST" \
      --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap --command="$PING_START"; then
      fail "MIG2: could not start ping on ${EINST}"
      return 1
    fi
  else
    verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c "rm -f '${PING_LOG}'; nohup ping -I '${PING_IFACE}' -c 400 -i 0.1 '${VM_IP}' >'${PING_LOG}' 2>&1 &"
  fi
  sleep 2
  migration_apply "$MIG2"
  migration_wait_succeeded "$MIG2"

  if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
    EINST="$(gcloud_mig_instance)"
    if ! e2e_gcloud_iap compute ssh "$EINST" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap --command='
i=0
while pgrep -x ping >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -ge 200 ]; then break; fi
  sleep 1
done'; then
      warn "MIG2: remote wait for ping (non-fatal; checking log)"
    fi
  else
    for _ in $(seq 1 120); do
      if oc exec -n "$NAMESPACE" netshoot-cudn -- test -f "$PING_LOG" 2>/dev/null; then
        if ! oc exec -n "$NAMESPACE" netshoot-cudn -- pgrep -x ping >/dev/null 2>&1; then
          break
        fi
      fi
      sleep 1
    done
  fi

  sleep 1
  if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
    PING_SUMMARY="$(e2e_gcloud_iap compute ssh "$(gcloud_mig_instance)" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
      --command="cat ${PING_LOG} 2>/dev/null | tail -n 5" 2>/dev/null | tr -d '\r' || true)"
    e2e_gcloud_iap_verbose compute ssh "$(gcloud_mig_instance)" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
      --command="rm -f ${PING_LOG} 2>/dev/null" 2>/dev/null || true
  else
    PING_SUMMARY="$(oc exec -n "$NAMESPACE" netshoot-cudn -- cat "$PING_LOG" 2>/dev/null | tail -n 5 || true)"
    verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- rm -f "$PING_LOG" 2>/dev/null || true
  fi
  kv "Ping log (tail)" "$(printf '%s' "$PING_SUMMARY" | tr '\n' ';')"
  PASS_LOSS_LINE="$(printf '%s' "$PING_SUMMARY" | grep -E 'packet loss' | tail -n1 || true)"
  if [[ -n "$PASS_LOSS_LINE" ]]; then
    pass "Ping during migration: ${PASS_LOSS_LINE}"
  else
    warn "Could not parse packet loss line from ping log"
  fi
}

run_mig3_concurrent_curl() {
  local MIG3 CURL_LOG CURL_SCRIPT REMOTE_CURL_SH CURL_STATS
  local M3L RPATH EINST
  MIG3="virt-e2e-mig-during-curl"
  title "Concurrent curl during migration (${MIG3}) (from: $(
    if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then echo "echo VM"; else echo "netshoot"; fi
  ))"
  CURL_LOG="/tmp/virt-e2e-curl-$$.log"

  REMOTE_CURL_SH="$(cat <<EOSH
#!/bin/sh
set -eu
url="http://${VM_IP}:8080/"
expected="${MIG_CURL_EXPECT_BODY:-}"
fail=0
ok=0
i=0
while [ "\$i" -lt 300 ]; do
  i=\$((i + 1))
  if out=\$(curl -sS --connect-timeout ${CUDN_E2E_HTTP_CONNECT_TIMEOUT} --max-time ${CUDN_E2E_HTTP_MAX_TIME} "\$url" 2>/dev/null) && [ "\$out" = "\$expected" ]; then
    ok=\$((ok + 1))
  else
    fail=\$((fail + 1))
  fi
  sleep 0.15
done
printf 'curl_ok=%s curl_fail=%s\n' "\$ok" "\$fail" >${CURL_LOG}
EOSH
  )"
  if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
    EINST="$(gcloud_mig_instance)"
    M3L="${TMPDIR:-/tmp}/virt-mig3-echo-$$.sh"
    RPATH="/tmp/virt-mig3-$$.sh"
    printf '%s' "$REMOTE_CURL_SH" >"$M3L"
    if ! e2e_gcloud_iap_verbose compute scp "$M3L" "${EINST}:${RPATH}" \
      --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap; then
      fail "MIG3: gcloud compute scp to ${EINST} failed"
      rm -f "$M3L"
      return 1
    fi
    rm -f "$M3L"
    if ! e2e_gcloud_iap_verbose compute ssh "$EINST" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
      --command="rm -f ${CURL_LOG} 2>/dev/null; chmod +x ${RPATH} && nohup sh ${RPATH} >/dev/null 2>&1 &"; then
      fail "MIG3: could not start curl loop on ${EINST}"
      return 1
    fi
  else
    CURL_SCRIPT="/tmp/virt-e2e-curl-$$.sh"
    verbose_run oc exec -i -n "$NAMESPACE" netshoot-cudn -- sh -c "rm -f '${CURL_SCRIPT}' '${CURL_LOG}' && cat >'${CURL_SCRIPT}' && chmod +x '${CURL_SCRIPT}' && nohup sh '${CURL_SCRIPT}' >/dev/null 2>&1 &" <<<"$REMOTE_CURL_SH"
  fi
  sleep 2
  migration_apply "$MIG3"
  migration_wait_succeeded "$MIG3"
  for _ in $(seq 1 180); do
    if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
      if e2e_gcloud_iap compute ssh "$(gcloud_mig_instance)" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
        --command="test -f ${CURL_LOG}" 2>/dev/null; then
        break
      fi
    else
      if oc exec -n "$NAMESPACE" netshoot-cudn -- test -f "$CURL_LOG" 2>/dev/null; then
        break
      fi
    fi
    sleep 1
  done
  if [[ "${MIG_USE_ECHO:-0}" -eq 1 ]]; then
    CURL_STATS="$(
      e2e_gcloud_iap compute ssh "$(gcloud_mig_instance)" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
        --command="cat ${CURL_LOG} 2>/dev/null" 2>/dev/null | tr -d '\r' || true
    )"
    e2e_gcloud_iap compute ssh "$(gcloud_mig_instance)" --project="$MIG_ECHO_P" --zone="$MIG_ECHO_Z" --tunnel-through-iap \
      --command="rm -f ${CURL_LOG} ${RPATH} 2>/dev/null" 2>/dev/null || true
  else
    CURL_STATS="$(oc exec -n "$NAMESPACE" netshoot-cudn -- cat "$CURL_LOG" 2>/dev/null || true)"
    verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- rm -f "$CURL_SCRIPT" "$CURL_LOG" 2>/dev/null || true
  fi
  kv "Curl stats" "${CURL_STATS:-"(empty)"}"
  if [[ "$CURL_STATS" =~ curl_fail= ]]; then
    pass "Curl during migration summary: $CURL_STATS"
  else
    warn "Curl stats file missing or empty"
  fi
}

# --- main ---
title "Virt live-migration e2e"
if [[ "$SKIP_TESTS" -eq 1 ]]; then
  kv "mode" "access-only (VIRT_E2E_SKIP_TESTS=1 — no test pods, no mesh, no migrations)"
else
  if [[ "$RUN_MIGRATIONS" -eq 1 ]]; then
    kv "mode" "connectivity mesh + echo + live migrations (target ${VM_NAME})"
  else
    kv "mode" "connectivity mesh + echo stack (VIRT_E2E_RUN_MIGRATIONS=0; use --with-migrations to add live migrations)"
  fi
fi
kv "namespace" "$NAMESPACE"
kv "cluster-dir" "$CLUSTER_DIR"
kv "VM bridge (l2bridge)" "$VIRT_E2E_VM_NAME_BRIDGE"
kv "VM masq (masquerade)" "$VIRT_E2E_VM_NAME_MASQ"
if [[ "$SKIP_TESTS" -eq 0 && "$RUN_MIGRATIONS" -eq 1 ]]; then
  kv "live migration VMI" "$VM_NAME"
fi
kv "boot DataSource" "${VIRT_E2E_BOOT_DATASOURCE_NAMESPACE}/${VIRT_E2E_BOOT_DATASOURCE_NAME}"
if namespace_is_primary_udn; then
  kv "primary UDN namespace" "yes (virtctl ssh may not work — try console first)"
else
  kv "primary UDN namespace" "no"
fi

if [[ "$SKIP_TESTS" -eq 0 ]]; then
  if ! command -v terraform >/dev/null 2>&1; then
    fail "terraform not on PATH (required for cudn_cidr / cudn-pod-ip.sh + optional echo stack)"
    exit 1
  fi

  title "Setup: test pods (netshoot + icanhazip-cudn)"
  if [[ "$SKIP_DEPLOY" -eq 1 ]]; then
    verbose_run oc wait --for=condition=Ready pod/netshoot-cudn pod/icanhazip-cudn -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"
  else
    if [[ ${#DEPLOY_EXTRA_ARGS[@]} -gt 0 ]]; then
      verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE" "${DEPLOY_EXTRA_ARGS[@]}"
    else
      verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE"
    fi
  fi
  pass "CUDN test pods Ready (netshoot-cudn, icanhazip-cudn)"

  print_cmd_line bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" netshoot-cudn
  NETSHOOT_CUDN_IP="$(bash "$CUDN_POD_IP_SH" -n "$NAMESPACE" netshoot-cudn)"

  if [[ -n "$PING_IFACE_OVERRIDE" ]]; then
    PING_IFACE="$PING_IFACE_OVERRIDE"
  else
    PING_IFACE="$(discover_ping_iface "$NETSHOOT_CUDN_IP")"
    if [[ -z "$PING_IFACE" ]]; then
      warn "could not auto-detect CUDN iface; using ovn-udn1"
      PING_IFACE="ovn-udn1"
    fi
  fi
  PING_IFACE="${PING_IFACE%%@*}"
else
  info "Skipping test pods and connectivity (VIRT_E2E_SKIP_TESTS=1 or --access-only). Omitted: mesh and echo stack; re-run with default (SKIP=0) or see --with-migrations for migrations."
fi

apply_virt_e2e_vms
ensure_vm_running "$VIRT_E2E_VM_NAME_BRIDGE"
ensure_vm_running "$VIRT_E2E_VM_NAME_MASQ"
wait_vmi_ready "$VIRT_E2E_VM_NAME_BRIDGE"
wait_vmi_ready "$VIRT_E2E_VM_NAME_MASQ"

title "Access: virtctl console and ssh"
VIRTCTL_CONSOLE_VM_BRIDGE="virtctl console vmi/${VIRT_E2E_VM_NAME_BRIDGE} -n ${NAMESPACE}"
VIRTCTL_SSH_BRIDGE="virtctl ssh -i ${VIRT_E2E_SSH_KEY} cloud-user@vmi/${VIRT_E2E_VM_NAME_BRIDGE} -n ${NAMESPACE}"
VIRTCTL_CONSOLE_VM_MASQ="virtctl console vmi/${VIRT_E2E_VM_NAME_MASQ} -n ${NAMESPACE}"
VIRTCTL_SSH_MASQ="virtctl ssh -i ${VIRT_E2E_SSH_KEY} cloud-user@vmi/${VIRT_E2E_VM_NAME_MASQ} -n ${NAMESPACE}"
kv "--- bridge VM (l2bridge) ---" ""
kv "virtctl console" "$VIRTCTL_CONSOLE_VM_BRIDGE"
kv "virtctl ssh" "$VIRTCTL_SSH_BRIDGE"
kv "--- masq VM (masquerade) ---" ""
kv "virtctl console" "$VIRTCTL_CONSOLE_VM_MASQ"
kv "virtctl ssh" "$VIRTCTL_SSH_MASQ"
kv "SSH identity (-i)" "$VIRT_E2E_SSH_KEY"
kv "console user" "cloud-user"
kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
printf '\n%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_CONSOLE_VM_BRIDGE" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_SSH_BRIDGE" "$C_RESET" >&2
printf '\n%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_CONSOLE_VM_MASQ" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_SSH_MASQ" "$C_RESET" >&2
info "Password is also in: ${VIRT_E2E_SSH_DIR}/console-password"
if command -v virtctl >/dev/null 2>&1; then
  info "virtctl console 404: match virtctl to cluster (virtctl version; Help → Command line tools). If already matched, bypass HTTP(S)_PROXY or add API host to NO_PROXY; oc get apiservice | grep subresources.kubevirt.io. Details: ARCHITECTURE.md (VM-Specific Considerations)."
fi
if namespace_is_primary_udn; then
  info "Primary UDN: product docs often list virtctl ssh as unsupported; if ssh fails, use console or the netshoot jump in AGENTS.md."
fi
info "cloud-init / icanhazip may still be finishing in the background."

if [[ "$SKIP_TESTS" -eq 1 ]]; then
  title "Summary (access-only)"
  pass "Both VMs are Ready — use virtctl console or console password above (connectivity: VIRT_E2E_SKIP_TESTS=0; full mesh + migrations: --run-tests)"
  e2e_print_test_summary
  kv "bridge VM console" "$VIRTCTL_CONSOLE_VM_BRIDGE"
  kv "bridge VM ssh" "$VIRTCTL_SSH_BRIDGE"
  kv "masq VM console" "$VIRTCTL_CONSOLE_VM_MASQ"
  kv "masq VM ssh" "$VIRTCTL_SSH_MASQ"
  kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
  printf '\n%s\n' "Cleanup: $0 -C \"$CLUSTER_DIR\" -n \"$NAMESPACE\" --cleanup" >&2
  exit 0
fi

title "Phase A: virt-e2e / CUDN connectivity mesh"
info "In-guest SSH: oc copy key into netshoot, then oc exec into netshoot → ssh -i (see scripts/virt-ssh.sh, AGENTS.md, KNOWLEDGE.md OpenShift Virtualization on GCP → Ad-hoc SSH); primary UDN: prefer this over virtctl ssh."
run_connectivity_mesh
run_virt_e2e_echo_stack
run_internet_reachability_tests
if [[ "$RUN_MIGRATIONS" -eq 0 ]]; then
  title "Summary (connectivity; live migrations not requested)"
  pass "Mesh, optional echo stack, and internet reachability (ping / curl) completed — for VirtualMachineInstanceMigration + concurrent probes, use: VIRT_E2E_RUN_MIGRATIONS=1, --with-migrations, or --run-tests (same as networking.validate virt full)"
  e2e_print_test_summary
  kv "bridge VM console" "${VIRTCTL_CONSOLE_VM_BRIDGE:-}"
  kv "masq VM console" "${VIRTCTL_CONSOLE_VM_MASQ:-}"
  printf '\n%s\n' "Cleanup: $0 -C \"$CLUSTER_DIR\" -n \"$NAMESPACE\" --cleanup" >&2
  exit 0
fi

title "Phase B: live migration sequence (vmi: ${VM_NAME})"
ensure_two_nodes_for_virt

VM_IP="$(vmi_probe_ip "$VM_NAME")"
if [[ -z "$VM_IP" ]]; then
  fail "Could not determine guest IP for vmi/${VM_NAME} (check VMI status.interfaces)"
  exit 1
fi
kv "VMI probe IP (${VM_NAME})" "$VM_IP"
kv "netshoot CUDN IP" "$NETSHOOT_CUDN_IP"
kv "ping interface" "$PING_IFACE"

preflight_pvc_access_modes
wait_http_vm "$VM_IP"

ping_vm "$VM_IP" "Before migration"
curl_vm_check "$VM_IP" "Before migration"

MIG1="virt-e2e-mig-1"
run_migrate_sequence "$MIG1" "Step 1"

ping_vm "$VM_IP" "After first migration"
curl_vm_check "$VM_IP" "After first migration"

# MIG2 (ping) + MIG3 (curl) during a live migration: default to echo VM + IAP when Terraform has echo client outputs (VIRT_E2E_MIG_CONCURRENT_FROM=auto).
if ! resolve_mig_concurrent_prober; then
  exit 1
fi
run_mig2_concurrent_ping
run_mig3_concurrent_curl
MIG2="virt-e2e-mig-during-ping"
MIG3="virt-e2e-mig-during-curl"

title "Summary"
pass "Virt live-migration e2e completed"
e2e_print_test_summary
kv "Migrations (target ${VM_NAME})" "${MIG1}, ${MIG2}, ${MIG3}"
kv "bridge VM console" "${VIRTCTL_CONSOLE_VM_BRIDGE}"
kv "masq VM console" "${VIRTCTL_CONSOLE_VM_MASQ}"
kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
kv "bridge VM ssh" "${VIRTCTL_SSH_BRIDGE}"
kv "masq VM ssh" "${VIRTCTL_SSH_MASQ}"
printf '\n%s\n' "Cleanup: $0 -C \"$CLUSTER_DIR\" -n \"$NAMESPACE\" --cleanup" >&2
