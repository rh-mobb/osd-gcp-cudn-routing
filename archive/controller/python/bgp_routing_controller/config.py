"""Controller configuration loaded from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


# GCP system limit: router appliance instances per NCC spoke (cannot be increased).
NCC_MAX_INSTANCES_PER_SPOKE: int = 8


@dataclass(frozen=True)
class ControllerConfig:
    gcp_project: str
    cloud_router_name: str
    cloud_router_region: str
    ncc_hub_name: str
    ncc_spoke_prefix: str
    cluster_name: str
    frr_asn: int = 65003

    ncc_spoke_site_to_site: bool = False

    # When true, set GCE advancedMachineFeatures.enableNestedVirtualization on router VMs
    # (not supported on OSD-GCP; same API path as canIpForward). Default on; set env false to skip.
    enable_gce_nested_virtualization: bool = True

    # Candidate pool: workers with this label, excluding infra_label_key.
    node_label_key: str = "node-role.kubernetes.io/worker"
    node_label_value: str = ""

    router_label_key: str = "cudn.redhat.com/bgp-router"
    infra_label_key: str = "node-role.kubernetes.io/infra"

    frr_namespace: str = "openshift-frr-k8s"
    frr_label_key: str = "cudn.redhat.com/bgp-stack"
    frr_label_value: str = "osd-gcp-bgp"

    reconcile_interval_seconds: float = 60.0
    debounce_seconds: float = 5.0

    # Used by cleanup to remove the in-cluster Deployment (matches deploy/deployment.yaml).
    controller_namespace: str = "bgp-routing-system"
    controller_deployment_name: str = "bgp-routing-controller"

    @classmethod
    def from_env(cls) -> ControllerConfig:
        """Build config from environment variables (see deploy/configmap.yaml)."""

        def _require(key: str) -> str:
            val = os.environ.get(key)
            if not val:
                raise RuntimeError(f"Required environment variable {key} is not set")
            return val

        return cls(
            gcp_project=_require("GCP_PROJECT"),
            cloud_router_name=_require("CLOUD_ROUTER_NAME"),
            cloud_router_region=_require("CLOUD_ROUTER_REGION"),
            ncc_hub_name=_require("NCC_HUB_NAME"),
            ncc_spoke_prefix=_require("NCC_SPOKE_PREFIX"),
            cluster_name=_require("CLUSTER_NAME"),
            frr_asn=int(os.environ.get("FRR_ASN", "65003")),
            ncc_spoke_site_to_site=os.environ.get(
                "NCC_SPOKE_SITE_TO_SITE", "false"
            ).lower() in ("true", "1", "yes"),
            enable_gce_nested_virtualization=os.environ.get(
                "ENABLE_GCE_NESTED_VIRTUALIZATION", "true"
            ).lower() in ("true", "1", "yes"),
            node_label_key=os.environ.get(
                "NODE_LABEL_KEY", "node-role.kubernetes.io/worker"
            ),
            node_label_value=os.environ.get("NODE_LABEL_VALUE", ""),
            router_label_key=os.environ.get(
                "ROUTER_LABEL_KEY", "cudn.redhat.com/bgp-router"
            ),
            infra_label_key=os.environ.get(
                "INFRA_EXCLUDE_LABEL_KEY", "node-role.kubernetes.io/infra"
            ),
            frr_namespace=os.environ.get("FRR_NAMESPACE", "openshift-frr-k8s"),
            frr_label_key=os.environ.get(
                "FRR_LABEL_KEY", "cudn.redhat.com/bgp-stack"
            ),
            frr_label_value=os.environ.get("FRR_LABEL_VALUE", "osd-gcp-bgp"),
            reconcile_interval_seconds=float(
                os.environ.get("RECONCILE_INTERVAL_SECONDS", "60")
            ),
            debounce_seconds=float(os.environ.get("DEBOUNCE_SECONDS", "5")),
            controller_namespace=os.environ.get(
                "CONTROLLER_NAMESPACE", "bgp-routing-system"
            ),
            controller_deployment_name=os.environ.get(
                "CONTROLLER_DEPLOYMENT_NAME", "bgp-routing-controller"
            ),
        )

    @property
    def node_label_selector(self) -> str:
        if self.node_label_value:
            return f"{self.node_label_key}={self.node_label_value}"
        return self.node_label_key
