#!/usr/bin/env bash
# Interactive SSH into a virt-e2e guest (cloud-user) via netshoot-cudn.
# Primary-UDN clusters often cannot use virtctl ssh; this path matches the e2e probes.
#
# Usage:
#   virt-ssh.sh -C /path/to/cluster_bgp_routing [-n cudn1] <vm-name> [-- <remote command...>]
# Without a remote command: interactive TTY (same as make virt.ssh.bridge / virt.ssh.masq).
# With "-- cmd ...": non-interactive; runs ssh in BatchMode (fails if key auth does not work).
# Env (defaults match e2e-virt-live-migration.sh):
#   CUDN_NAMESPACE, VIRT_SSH_NETSHOOT_POD (default netshoot-cudn),
#   VIRT_SSH_NETSHOOT_CONTAINER (default netshoot)
#
# Requires: oc (logged in), jq; CLUSTER_DIR/.virt-e2e/id_ed25519;
#           netshoot-cudn pod Ready in the namespace.
set -euo pipefail

fail() {
  printf '[virt-ssh] %s\n' "$1" >&2
  exit 1
}

NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
CLUSTER_DIR=""
NETSHOOT_POD="${VIRT_SSH_NETSHOOT_POD:-netshoot-cudn}"
NETSHOOT_CTR="${VIRT_SSH_NETSHOOT_CONTAINER:-netshoot}"
KEY_DEST_IN_POD="/tmp/virt-e2e-vm-key"
VM_NAME=""

usage() {
  cat >&2 <<'EOF'
Usage: virt-ssh.sh -C CLUSTER_DIR [-n NAMESPACE] <virtualmachine-name> [-- <remote command...>]

  Copies CLUSTER_DIR/.virt-e2e/id_ed25519 into netshoot and runs ssh to cloud-user@<guest-ip>.
  Omit the remote command for an interactive shell; pass "-- cmd" for a one-shot (scripting).

  Typical VM names: virt-e2e-bridge, virt-e2e-masq (overridable via make virt.ssh.* env).

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -C | --cluster-dir)
      CLUSTER_DIR="${2:?}"
      shift 2
      ;;
    -n | --namespace)
      NAMESPACE="${2:?}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -z "$VM_NAME" ]]; then
        VM_NAME="$1"
        shift
      else
        fail "unexpected argument: $1"
      fi
      ;;
  esac
done

if [[ -z "$VM_NAME" ]]; then
  usage
  exit 1
fi

REMOTE_CMD=()
if [[ $# -gt 0 ]]; then
  REMOTE_CMD=("$@")
fi

if [[ -z "$CLUSTER_DIR" ]]; then
  CLUSTER_DIR="$PWD"
fi
CLUSTER_DIR="$(cd "$CLUSTER_DIR" && pwd)"

SSH_KEY="${CLUSTER_DIR}/.virt-e2e/id_ed25519"
[[ -f "$SSH_KEY" ]] || fail "missing ${SSH_KEY} — run make virt.e2e or scripts/e2e-virt-live-migration.sh -C \"${CLUSTER_DIR}\" first"

for bin in oc jq; do
  command -v "$bin" >/dev/null 2>&1 || fail "${bin} not on PATH"
done

if ! oc get pod -n "$NAMESPACE" "$NETSHOOT_POD" >/dev/null 2>&1; then
  fail "pod ${NETSHOOT_POD} not in ${NAMESPACE} — deploy CUDN test pods (scripts/deploy-cudn-test-pods.sh or make virt.e2e)"
fi

oc wait --for=condition=Ready "pod/${NETSHOOT_POD}" -n "$NAMESPACE" --timeout=120s >/dev/null

oc cp "$SSH_KEY" "${NAMESPACE}/${NETSHOOT_POD}:${KEY_DEST_IN_POD}" -c "$NETSHOOT_CTR"
oc exec -n "$NAMESPACE" "$NETSHOOT_POD" -c "$NETSHOOT_CTR" -- chmod 600 "$KEY_DEST_IN_POD"

cudn_prefix() {
  local cidr net mask
  cidr="$(cd "$CLUSTER_DIR" && terraform output -raw cudn_cidr 2>/dev/null || true)"
  [[ -z "$cidr" ]] && {
    printf ''
    return
  }
  net="${cidr%/*}"
  mask="${cidr#*/}"
  mask="${mask:-16}"
  case "$mask" in
    8) printf '%s.' "$(echo "$net" | cut -d. -f1)" ;;
    16) printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
    24) printf '%s.' "$(echo "$net" | cut -d. -f1,2,3)" ;;
    *) printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
  esac
}

vmi_guest_ip() {
  local vmn="${1:?vm name}" pref doc ip
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

if ! oc get "vmi/${VM_NAME}" -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "vmi/${VM_NAME} not found in ${NAMESPACE} — start the VM (make virt.e2e)"
fi

VM_IP="$(vmi_guest_ip "$VM_NAME")"
[[ -n "$VM_IP" ]] || fail "could not resolve a guest IPv4 for vmi/${VM_NAME}"

printf '[virt-ssh] %s → cloud-user@%s (via %s/%s)\n' "$VM_NAME" "$VM_IP" "$NETSHOOT_POD" "$NETSHOOT_CTR" >&2

ssh_base=(
  ssh
  -i "$KEY_DEST_IN_POD"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

if [[ ${#REMOTE_CMD[@]} -gt 0 ]]; then
  oc exec -n "$NAMESPACE" "$NETSHOOT_POD" -c "$NETSHOOT_CTR" -- \
    "${ssh_base[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    "cloud-user@${VM_IP}" -- "${REMOTE_CMD[@]}"
else
  exec oc exec -it -n "$NAMESPACE" "$NETSHOOT_POD" -c "$NETSHOOT_CTR" -- \
    "${ssh_base[@]}" \
    "cloud-user@${VM_IP}"
fi
