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
# cloud-init: user/password + chpasswd (Virt UI), ssh_authorized_keys, packages (podman), short runcmd (icanhazip).
# Two VMs on the default pod network for side-by-side console comparison:
#   VIRT_E2E_VM_NAME_BRIDGE (bridge: {} / l2bridge) and VIRT_E2E_VM_NAME_MASQ (masquerade: {} / SNAT).
# VIRT_E2E_VM_NAME / --vm-name selects which VM runs live migrations and netshoot probes.
# Default: VIRT_E2E_SKIP_TESTS=1 — no netshoot/migrations; use --run-tests for full e2e.
# virtctl console (primary UDN namespaces: virtctl ssh unsupported).
# --cleanup removes all virt-e2e VMs (label) + labeled migration CRs (not .virt-e2e keys/password file).
set -euo pipefail

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

case "${VIRT_E2E_CLEANUP:-}" in
  1 | true | True | yes | YES) DO_CLEANUP=1 ;;
esac

# Default 1: deploy VMs + print virtctl console/ssh only (no netshoot, migrations, ping/curl). Set 0 or use --run-tests for full e2e.
: "${VIRT_E2E_SKIP_TESTS:=1}"
SKIP_TESTS="${VIRT_E2E_SKIP_TESTS}"
case "${SKIP_TESTS}" in
  1 | true | True | yes | YES) SKIP_TESTS=1 ;;
  0 | false | False | no | NO) SKIP_TESTS=0 ;;
  *) SKIP_TESTS=1 ;;
esac

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
pass() { printf '%s%s[ PASS ]%s %s\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "$1" >&2; }
warn() { printf '%s%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2; }
fail() { printf '%s%s[ FAIL ]%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2; }
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

usage() {
  cat <<EOF
Virt e2e: two VirtualMachines on the default pod network for side-by-side console comparison:
  VIRT_E2E_VM_NAME_BRIDGE (bridge: {} / l2bridge) and VIRT_E2E_VM_NAME_MASQ (masquerade: {} / SNAT).
Default mode: deploy both VMs + print virtctl console/ssh for each.

Usage: $(basename "$0") [options]

  -C, --cluster-dir DIR     Terraform stack (for cudn_cidr / cudn-pod-ip.sh); default PWD
  -n, --namespace NS        CUDN namespace (default: cudn1 or CUDN_NAMESPACE)
      --vm-name NAME        VM to migrate + probe when --run-tests (default: virt-e2e-bridge or VIRT_E2E_VM_NAME)
      --skip-tests            Deploy VMs and print access commands only (default; same as VIRT_E2E_SKIP_TESTS=1)
      --run-tests             Full e2e: netshoot, HTTP/ping/curl, live migrations (VIRT_E2E_SKIP_TESTS=0)
      --timeout DUR         deploy-cudn-test-pods wait (default: 600s)
      --skip-deploy         Do not run deploy-cudn-test-pods (netshoot must be Ready)
      --ping-iface IFACE    Force ping -I IFACE on netshoot
      --allow-icmp-fail     Ping failures warn only (do not fail script)
      --recreate-test-pods  Forward to deploy-cudn-test-pods
      --cleanup             Delete VMs labeled virt-e2e + labeled vmi-migrations; exit (no tests)
      --cleanup-include-test-pods  With --cleanup, also delete netshoot-cudn and icanhazip-cudn
  -h, --help                This help

Env: VIRT_E2E_CLEANUP=1 same as --cleanup.
     VIRT_E2E_SKIP_TESTS: 1 (default) = no netshoot/migration/ping/curl; 0 or --run-tests = full e2e.
     CUDN_E2E_HTTP_* for curl retries (full e2e only).
     VIRT_E2E_VM_NAME_BRIDGE: bridge VM name (default: virt-e2e-bridge).
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
  virtctl console vm/VM_NAME -n NAMESPACE
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
    --skip-tests) SKIP_TESTS=1; shift ;;
    --run-tests) SKIP_TESTS=0; shift ;;
    --timeout)
      WAIT_TIMEOUT="$2"
      DEPLOY_EXTRA_ARGS+=(--timeout "$2")
      shift 2
      ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --ping-iface) PING_IFACE_OVERRIDE="$2"; shift 2 ;;
    --allow-icmp-fail) ALLOW_ICMP_FAIL=1; shift ;;
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

if [[ "$SKIP_TESTS" -eq 0 ]]; then
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

# cloud-init: match common-templates (user/password/chpasswd + keys); packages + flat runcmd only (easy to read in VM YAML / MCP).
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
  - podman
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
# binding: "bridge" (l2bridge) or "masquerade" (SNAT / pod network NAT).
render_virt_e2e_vm_list_json() {
  local out_json="$1"
  local vm_name="$2"
  local binding="$3"   # bridge | masquerade
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
    --arg binding "$binding" \
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
              "routing.osd.redhat.com/virt-e2e-network": $binding
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
                      if $binding == "masquerade"
                      then {name: "default", masquerade: {}}
                      else {name: "default", bridge: {}}
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
  kv "network" "default pod network (two bindings: bridge {} l2bridge + masquerade {} SNAT)"

  local vm_json
  vm_json="$(mktemp)"

  title "VM ${VIRT_E2E_VM_NAME_BRIDGE} (bridge / l2bridge)"
  kv "interfaces" "default + bridge {}"
  render_virt_e2e_vm_list_json "$vm_json" "$VIRT_E2E_VM_NAME_BRIDGE" "bridge"
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
    if [[ -z "$out" ]]; then
      warn "No PVCs for vm.kubevirt.io/name=${vm} yet (may still be provisioning)"
    else
      info "$out"
    fi
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

# --- main ---
title "Virt live-migration e2e"
if [[ "$SKIP_TESTS" -eq 1 ]]; then
  kv "mode" "access-only (VIRT_E2E_SKIP_TESTS=1 — no netshoot/migrations)"
else
  kv "mode" "full e2e (netshoot + migrations + probes)"
fi
kv "namespace" "$NAMESPACE"
kv "cluster-dir" "$CLUSTER_DIR"
kv "VM bridge (l2bridge)" "$VIRT_E2E_VM_NAME_BRIDGE"
kv "VM masq (masquerade)" "$VIRT_E2E_VM_NAME_MASQ"
if [[ "$SKIP_TESTS" -eq 0 ]]; then
  kv "migration / probes VM" "$VM_NAME"
fi
kv "boot DataSource" "${VIRT_E2E_BOOT_DATASOURCE_NAMESPACE}/${VIRT_E2E_BOOT_DATASOURCE_NAME}"
if namespace_is_primary_udn; then
  kv "primary UDN namespace" "yes (virtctl ssh may not work — try console first)"
else
  kv "primary UDN namespace" "no"
fi

if [[ "$SKIP_TESTS" -eq 0 ]]; then
  if ! command -v terraform >/dev/null 2>&1; then
    fail "terraform not on PATH (required for cudn_cidr / cudn-pod-ip.sh)"
    exit 1
  fi
  ensure_two_nodes_for_virt

  title "Setup: test pods (netshoot)"
  if [[ "$SKIP_DEPLOY" -eq 1 ]]; then
    verbose_run oc wait --for=condition=Ready pod/netshoot-cudn -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"
  else
    if [[ ${#DEPLOY_EXTRA_ARGS[@]} -gt 0 ]]; then
      verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE" "${DEPLOY_EXTRA_ARGS[@]}"
    else
      verbose_run env "CUDN_NAMESPACE=$NAMESPACE" "$DEPLOY_PODS" -n "$NAMESPACE"
    fi
  fi
  pass "netshoot-cudn Ready"

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
  info "Skipping netshoot, two-node check, and migration probes (use --run-tests or VIRT_E2E_SKIP_TESTS=0 to enable)."
fi

apply_virt_e2e_vms
ensure_vm_running "$VIRT_E2E_VM_NAME_BRIDGE"
ensure_vm_running "$VIRT_E2E_VM_NAME_MASQ"
wait_vmi_ready "$VIRT_E2E_VM_NAME_BRIDGE"
wait_vmi_ready "$VIRT_E2E_VM_NAME_MASQ"

title "Access: virtctl console and ssh"
VIRTCTL_CONSOLE_VM_BRIDGE="virtctl console vm/${VIRT_E2E_VM_NAME_BRIDGE} -n ${NAMESPACE}"
VIRTCTL_CONSOLE_VMI_BRIDGE="virtctl console vmi/${VIRT_E2E_VM_NAME_BRIDGE} -n ${NAMESPACE}"
VIRTCTL_SSH_BRIDGE="virtctl ssh -i ${VIRT_E2E_SSH_KEY} cloud-user@vm/${VIRT_E2E_VM_NAME_BRIDGE} -n ${NAMESPACE}"
VIRTCTL_CONSOLE_VM_MASQ="virtctl console vm/${VIRT_E2E_VM_NAME_MASQ} -n ${NAMESPACE}"
VIRTCTL_CONSOLE_VMI_MASQ="virtctl console vmi/${VIRT_E2E_VM_NAME_MASQ} -n ${NAMESPACE}"
VIRTCTL_SSH_MASQ="virtctl ssh -i ${VIRT_E2E_SSH_KEY} cloud-user@vm/${VIRT_E2E_VM_NAME_MASQ} -n ${NAMESPACE}"
kv "--- bridge VM (l2bridge) ---" ""
kv "virtctl console (vm)" "$VIRTCTL_CONSOLE_VM_BRIDGE"
kv "virtctl console (vmi)" "$VIRTCTL_CONSOLE_VMI_BRIDGE"
kv "virtctl ssh" "$VIRTCTL_SSH_BRIDGE"
kv "--- masq VM (masquerade) ---" ""
kv "virtctl console (vm)" "$VIRTCTL_CONSOLE_VM_MASQ"
kv "virtctl console (vmi)" "$VIRTCTL_CONSOLE_VMI_MASQ"
kv "virtctl ssh" "$VIRTCTL_SSH_MASQ"
kv "SSH identity (-i)" "$VIRT_E2E_SSH_KEY"
kv "console user" "cloud-user"
kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
printf '\n%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_CONSOLE_VM_BRIDGE" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_DIM" "$C_GREEN" "$VIRTCTL_CONSOLE_VMI_BRIDGE" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_SSH_BRIDGE" "$C_RESET" >&2
printf '\n%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_CONSOLE_VM_MASQ" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_DIM" "$C_GREEN" "$VIRTCTL_CONSOLE_VMI_MASQ" "$C_RESET" >&2
printf '%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$VIRTCTL_SSH_MASQ" "$C_RESET" >&2
info "Password is also in: ${VIRT_E2E_SSH_DIR}/console-password"
if command -v virtctl >/dev/null 2>&1; then
  info "virtctl console 404: match virtctl to cluster (virtctl version; Help → Command line tools). If already matched, bypass HTTP(S)_PROXY or add API host to NO_PROXY; oc get apiservice | grep subresources.kubevirt.io; try vmi/ form above. Details: ARCHITECTURE.md (VM-Specific Considerations)."
fi
if namespace_is_primary_udn; then
  warn "Primary UDN: product docs often list virtctl ssh as unsupported; if ssh fails, use console."
fi
info "cloud-init / icanhazip may still be finishing in the background."

if [[ "$SKIP_TESTS" -eq 1 ]]; then
  title "Summary (access-only)"
  pass "Both VMs are Ready — use virtctl console / virtctl ssh above (full e2e: --run-tests or VIRT_E2E_SKIP_TESTS=0)"
  kv "bridge VM console" "$VIRTCTL_CONSOLE_VM_BRIDGE"
  kv "bridge VM ssh" "$VIRTCTL_SSH_BRIDGE"
  kv "masq VM console" "$VIRTCTL_CONSOLE_VM_MASQ"
  kv "masq VM ssh" "$VIRTCTL_SSH_MASQ"
  kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
  printf '\n%s\n' "Cleanup: $0 -C \"$CLUSTER_DIR\" -n \"$NAMESPACE\" --cleanup" >&2
  exit 0
fi

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

# --- Ping during migration ---
MIG2="virt-e2e-mig-during-ping"
title "Concurrent ping during migration (${MIG2})"
PING_LOG="/tmp/virt-e2e-ping-$$.log"
verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- sh -c "rm -f '${PING_LOG}'; nohup ping -I '${PING_IFACE}' -c 400 -i 0.1 '${VM_IP}' >'${PING_LOG}' 2>&1 &"
sleep 2
migration_apply "$MIG2"
migration_wait_succeeded "$MIG2"
# wait for ping to finish
for _ in $(seq 1 120); do
  if oc exec -n "$NAMESPACE" netshoot-cudn -- test -f "$PING_LOG" 2>/dev/null; then
    if ! oc exec -n "$NAMESPACE" netshoot-cudn -- pgrep -x ping >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 1
done
sleep 1
PING_SUMMARY="$(oc exec -n "$NAMESPACE" netshoot-cudn -- cat "$PING_LOG" 2>/dev/null | tail -n 5 || true)"
kv "Ping log (tail)" "$(printf '%s' "$PING_SUMMARY" | tr '\n' ';')"
PASS_LOSS_LINE="$(printf '%s' "$PING_SUMMARY" | grep -E 'packet loss' | tail -n1 || true)"
if [[ -n "$PASS_LOSS_LINE" ]]; then
  pass "Ping during migration: ${PASS_LOSS_LINE}"
else
  warn "Could not parse packet loss line from ping log"
fi
verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- rm -f "$PING_LOG" 2>/dev/null || true

# --- Curl loop during migration ---
MIG3="virt-e2e-mig-during-curl"
title "Concurrent curl during migration (${MIG3})"
CURL_SCRIPT="/tmp/virt-e2e-curl-$$.sh"
CURL_LOG="/tmp/virt-e2e-curl-$$.log"
REMOTE_CURL_SH="$(cat <<EOSH
#!/bin/sh
set -eu
url="http://${VM_IP}:8080/"
expected="${NETSHOOT_CUDN_IP}"
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
verbose_run oc exec -i -n "$NAMESPACE" netshoot-cudn -- sh -c "rm -f '${CURL_SCRIPT}' '${CURL_LOG}' && cat >'${CURL_SCRIPT}' && chmod +x '${CURL_SCRIPT}' && nohup sh '${CURL_SCRIPT}' >/dev/null 2>&1 &" <<<"$REMOTE_CURL_SH"
sleep 2
migration_apply "$MIG3"
migration_wait_succeeded "$MIG3"
for _ in $(seq 1 180); do
  if oc exec -n "$NAMESPACE" netshoot-cudn -- test -f "$CURL_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done
CURL_STATS="$(oc exec -n "$NAMESPACE" netshoot-cudn -- cat "$CURL_LOG" 2>/dev/null || true)"
kv "Curl stats" "${CURL_STATS:-"(empty)"}"
if [[ "$CURL_STATS" =~ curl_fail= ]]; then
  pass "Curl during migration summary: $CURL_STATS"
else
  warn "Curl stats file missing or empty"
fi
verbose_run oc exec -n "$NAMESPACE" netshoot-cudn -- rm -f "$CURL_SCRIPT" "$CURL_LOG" 2>/dev/null || true

title "Summary"
pass "Virt live-migration e2e completed"
kv "Migrations (target ${VM_NAME})" "${MIG1}, ${MIG2}, ${MIG3}"
kv "bridge VM console" "${VIRTCTL_CONSOLE_VM_BRIDGE}"
kv "masq VM console" "${VIRTCTL_CONSOLE_VM_MASQ}"
kv "console password" "$VIRT_E2E_CONSOLE_PASSWORD"
kv "bridge VM ssh" "${VIRTCTL_SSH_BRIDGE}"
kv "masq VM ssh" "${VIRTCTL_SSH_MASQ}"
printf '\n%s\n' "Cleanup: $0 -C \"$CLUSTER_DIR\" -n \"$NAMESPACE\" --cleanup" >&2
