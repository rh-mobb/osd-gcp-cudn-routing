#!/usr/bin/env bash
# Emit shell `export VAR=...` lines for the BGP controller from the current directory's
# Terraform state. Run with cwd = cluster_bgp_routing (or the same TF_DIR you use for apply).
#
# Prefer this over repeated `terraform output -raw ...`: when the state has no outputs,
# Terraform can print a colored "Warning: No outputs found" to stdout and still exit 0,
# which breaks command substitution for numeric vars like FRR_ASN.
set -euo pipefail

json_out='{}'
if ! json_out="$(terraform output -json 2>/dev/null)"; then
  json_out='{}'
fi
if [ -z "$json_out" ]; then
  json_out='{}'
fi

printf '%s' "$json_out" | python3 -c 'import json, sys, shlex

d = json.load(sys.stdin)


def out(name):
    o = d.get(name)
    if not isinstance(o, dict):
        return ""
    x = o.get("value")
    if x is None:
        return ""
    if isinstance(x, bool):
        return "true" if x else "false"
    return str(x)


pairs = [
    ("GCP_PROJECT", "gcp_project_id"),
    ("CLUSTER_NAME", "cluster_name"),
    ("CLOUD_ROUTER_NAME", "cloud_router_name"),
    ("CLOUD_ROUTER_REGION", "gcp_region"),
    ("NCC_HUB_NAME", "ncc_hub_name"),
    ("NCC_SPOKE_PREFIX", "ncc_spoke_prefix"),
    ("FRR_ASN", "frr_asn"),
]
for envk, tfk in pairs:
    val = out(tfk)
    print(f"export {envk}={shlex.quote(val)}")
'
