#!/usr/bin/env bash
# Print the pod IP on the CUDN (primary user-defined network).
#
# OVN-Kubernetes does not put the UDN address in status.podIP / status.podIPs — those stay on the
# default "infrastructure" network for kubelet health checks. The real CUDN IP is in annotations.
# See: https://ovn-kubernetes.io/features/user-defined-networks/user-defined-networks/
set -euo pipefail

REPO_CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
POD_NAME="icanhazip-cudn"
CUDN_CIDR="${CUDN_CIDR:-}"

usage() {
  echo "Usage: $(basename "$0") [-n namespace] [-c cudn_cidr] [pod_name]"
  echo "  Defaults: namespace=cudn1 (or CUDN_NAMESPACE), pod=icanhazip-cudn"
  echo "  -c / CUDN_CIDR: optional; if set, verify the extracted IP lies under this CIDR (prefix match)."
  echo "  If -c omitted, loads terraform output cudn_cidr for validation only."
  echo "Requires: oc, jq, (optional) terraform in PATH for default -c validation."
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -c | --cudn-cidr)
      CUDN_CIDR="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POD_NAME="$1"
      shift
      ;;
  esac
done

command -v oc >/dev/null 2>&1 || {
  echo "Error: oc not found on PATH." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "Error: jq not found on PATH." >&2
  exit 1
}

if [[ -z "$CUDN_CIDR" ]]; then
  CUDN_CIDR="$(cd "$REPO_CLUSTER_DIR" && terraform output -raw cudn_cidr)"
fi

# Prefix match for optional sanity-check (common /8, /16, /24).
cudn_prefix_from_cidr() {
  local cidr="$1"
  local net="${cidr%/*}"
  local mask="${cidr#*/}"
  mask="${mask:-16}"
  case "$mask" in
    8) printf '%s.' "$(echo "$net" | cut -d. -f1)" ;;
    16) printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
    24) printf '%s.' "$(echo "$net" | cut -d. -f1,2,3)" ;;
    *)
      printf '%s.' "$(echo "$net" | cut -d. -f1,2)" ;;
  esac
}

PREF="$(cudn_prefix_from_cidr "$CUDN_CIDR")"

# 1) k8s.ovn.org/pod-networks JSON: entry with role primary → ip_address or ip_addresses[0]
# 2) k8s.v1.cni.cncf.io/network-status: element with default:true → ips[0]
# 3) status.podIPs matching cudn prefix (legacy / unusual clusters)
IP="$(
  oc get pod -n "$NAMESPACE" "$POD_NAME" -o json | jq -r --arg p "$PREF" '
    def strip_cidr: if . == null or . == "" then empty else split("/")[0] end;

    def from_ovn_pod_networks:
      (.metadata.annotations["k8s.ovn.org/pod-networks"] // empty) as $raw |
      if $raw == "" then empty else
        ($raw | fromjson | to_entries | map(select(.value.role | ascii_downcase == "primary")) | first) as $entry |
        if $entry == null then empty else
          ($entry.value | .ip_address // .ip_addresses[0] // empty) | strip_cidr
        end
      end;

    def from_cni_network_status:
      (.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // empty) as $raw |
      if $raw == "" then empty else
        ($raw | fromjson | .[] | select(.default == true) | .ips[0] // empty)
      end;

    def from_podips:
      [(.status.podIPs // [])[] | .ip] | map(select(startswith($p))) | .[0] // empty;

    (from_ovn_pod_networks // from_cni_network_status // from_podips)
  '
)"

if [[ -z "$IP" ]]; then
  echo "Error: could not derive CUDN / primary UDN IP for ${NAMESPACE}/${POD_NAME}." >&2
  echo "Inspect: oc get pod -n ${NAMESPACE} ${POD_NAME} -o json | jq '.metadata.annotations'" >&2
  exit 1
fi

if [[ -n "$PREF" && "$IP" != ${PREF}* ]]; then
  echo "Warning: IP ${IP} does not start with expected prefix ${PREF} (from ${CUDN_CIDR})." >&2
fi

printf '%s\n' "$IP"
