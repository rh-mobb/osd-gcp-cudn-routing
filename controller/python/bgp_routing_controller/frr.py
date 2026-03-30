"""Build FRRConfiguration CR bodies for the Kubernetes API."""

from __future__ import annotations

from .gcp import CloudRouterTopology, RouterNode


def frr_config_name(instance_name: str) -> str:
    safe = instance_name.lower()
    safe = "".join(c if c.isalnum() or c == "-" else "-" for c in safe)[:50]
    return f"bgp-{safe}"


def build_frr_configuration(
    node: RouterNode,
    k8s_node_name: str,
    topology: CloudRouterTopology,
    frr_asn: int,
    label_key: str,
    label_value: str,
) -> dict:
    """Return a FRRConfiguration dict ready for the K8s API."""
    name = frr_config_name(node.name)

    neighbors = []
    raw_lines = [f"      router bgp {frr_asn}"]
    for cr_ip in topology.interface_ips:
        neighbors.append(
            {
                "address": cr_ip,
                "asn": topology.cloud_router_asn,
                "disableMP": True,
                "toReceive": {"allowed": {"mode": "all"}},
            }
        )
        raw_lines.append(f"       neighbor {cr_ip} disable-connected-check")

    return {
        "apiVersion": "frrk8s.metallb.io/v1beta1",
        "kind": "FRRConfiguration",
        "metadata": {
            "name": name,
            "namespace": "openshift-frr-k8s",
            "labels": {label_key: label_value},
        },
        "spec": {
            "nodeSelector": {
                "matchLabels": {"kubernetes.io/hostname": k8s_node_name}
            },
            "bgp": {
                "routers": [{"asn": frr_asn, "neighbors": neighbors}],
            },
            "raw": {
                "priority": 20,
                "rawConfig": "\n".join(raw_lines) + "\n",
            },
        },
    }
