"""Core reconciliation loop: Node list → GCP + FRR alignment."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

from kubernetes import client as k8s_client

from .config import ControllerConfig
from .frr import build_frr_configuration, frr_config_name
from .gcp import CloudRouterTopology, GCPClient, RouterNode

logger = logging.getLogger(__name__)

_PROVIDER_ID_RE = re.compile(r"^gce://(?P<project>[^/]+)/(?P<zone>[^/]+)/(?P<name>.+)$")

FRR_GROUP = "frrk8s.metallb.io"
FRR_VERSION = "v1beta1"
FRR_PLURAL = "frrconfigurations"


@dataclass
class ReconcileResult:
    nodes_found: int = 0
    can_ip_forward_changed: int = 0
    spoke_changed: bool = False
    peers_changed: bool = False
    frr_created: int = 0
    frr_deleted: int = 0

    @property
    def any_change(self) -> bool:
        return (
            self.can_ip_forward_changed > 0
            or self.spoke_changed
            or self.peers_changed
            or self.frr_created > 0
            or self.frr_deleted > 0
        )


class Reconciler:
    def __init__(self, config: ControllerConfig, gcp: GCPClient):
        self._cfg = config
        self._gcp = gcp
        self._core = k8s_client.CoreV1Api()
        self._custom = k8s_client.CustomObjectsApi()

    def reconcile(self) -> ReconcileResult:
        result = ReconcileResult()

        router_nodes, node_map = self._discover_nodes()
        result.nodes_found = len(router_nodes)
        if not router_nodes:
            logger.warning(
                "No nodes matching label %s — skipping GCP reconciliation",
                self._cfg.node_label_selector,
            )
            self._cleanup_stale_frr(set())
            return result

        logger.info(
            "Reconciling %d router node(s): %s",
            len(router_nodes),
            [n.name for n in router_nodes],
        )

        # Step 1: canIpForward
        for node in router_nodes:
            try:
                if self._gcp.ensure_can_ip_forward(node):
                    result.can_ip_forward_changed += 1
            except Exception:
                logger.exception("Failed to set canIpForward on %s", node.name)

        # Step 2: NCC spoke (create if missing, update if drifted)
        try:
            result.spoke_changed = self._gcp.reconcile_spoke(
                self._cfg.ncc_spoke_name,
                self._cfg.ncc_hub_name,
                router_nodes,
                self._cfg.ncc_spoke_site_to_site,
            )
        except Exception:
            logger.exception("Failed to reconcile NCC spoke")
            raise

        # Step 3: Cloud Router peers
        try:
            topology = self._gcp.get_router_topology(self._cfg.cloud_router_name)
            result.peers_changed = self._gcp.reconcile_peers(
                self._cfg.cloud_router_name,
                self._cfg.cluster_name,
                router_nodes,
                topology,
                self._cfg.frr_asn,
            )
        except Exception:
            logger.exception("Failed to reconcile Cloud Router peers")
            raise

        # Step 4: FRRConfiguration CRs
        created, deleted = self._reconcile_frr(router_nodes, node_map, topology)
        result.frr_created = created
        result.frr_deleted = deleted

        if result.any_change:
            logger.info("Reconciliation complete: %s", result)
        else:
            logger.debug("Reconciliation complete: no changes")

        return result

    def cleanup(self) -> None:
        """Delete all controller-managed resources (reverse of reconcile)."""
        logger.info("Cleaning up all controller-managed resources")

        # 1. Delete FRRConfigurations
        deleted = self._cleanup_stale_frr(set())
        logger.info("Deleted %d FRRConfiguration(s)", deleted)

        # 2. Remove Cloud Router BGP peers
        try:
            self._gcp.clear_peers(self._cfg.cloud_router_name)
        except Exception:
            logger.exception("Failed to clear Cloud Router peers")

        # 3. Delete NCC spoke
        try:
            self._gcp.delete_spoke(self._cfg.ncc_spoke_name)
        except Exception:
            logger.exception("Failed to delete NCC spoke")

        logger.info("Cleanup complete")

    # -- Node discovery -------------------------------------------------------

    def _discover_nodes(self) -> tuple[list[RouterNode], dict[str, str]]:
        """List K8s Nodes with the target label and extract GCE identity.

        Returns (router_nodes, node_map) where node_map is {gce_instance_name: k8s_node_name}.
        """
        nodes = self._core.list_node(
            label_selector=self._cfg.node_label_selector
        )

        router_nodes: list[RouterNode] = []
        node_map: dict[str, str] = {}

        for node in nodes.items:
            provider_id = node.spec.provider_id or ""
            m = _PROVIDER_ID_RE.match(provider_id)
            if not m:
                logger.warning(
                    "Node %s has no parseable providerID (%s) — skipping",
                    node.metadata.name,
                    provider_id,
                )
                continue

            instance_name = m.group("name")
            zone = m.group("zone")

            internal_ip = ""
            for addr in node.status.addresses or []:
                if addr.type == "InternalIP":
                    internal_ip = addr.address
                    break
            if not internal_ip:
                logger.warning(
                    "Node %s has no InternalIP address — skipping",
                    node.metadata.name,
                )
                continue

            self_link = (
                f"https://www.googleapis.com/compute/v1/"
                f"projects/{m.group('project')}/zones/{zone}/instances/{instance_name}"
            )

            router_nodes.append(
                RouterNode(
                    name=instance_name,
                    self_link=self_link,
                    zone=zone,
                    ip_address=internal_ip,
                )
            )
            node_map[instance_name] = node.metadata.name

        return router_nodes, node_map

    # -- FRRConfiguration CRs -------------------------------------------------

    def _reconcile_frr(
        self,
        router_nodes: list[RouterNode],
        node_map: dict[str, str],
        topology: CloudRouterTopology,
    ) -> tuple[int, int]:
        """Create/update/delete FRRConfiguration CRs. Returns (created, deleted)."""
        desired_names = {frr_config_name(n.name) for n in router_nodes}

        deleted = self._cleanup_stale_frr(desired_names)
        created = 0

        for node in router_nodes:
            k8s_name = node_map.get(node.name)
            if not k8s_name:
                continue
            body = build_frr_configuration(
                node=node,
                k8s_node_name=k8s_name,
                topology=topology,
                frr_asn=self._cfg.frr_asn,
                label_key=self._cfg.frr_label_key,
                label_value=self._cfg.frr_label_value,
            )
            try:
                existing = self._custom.get_namespaced_custom_object(
                    FRR_GROUP,
                    FRR_VERSION,
                    self._cfg.frr_namespace,
                    FRR_PLURAL,
                    body["metadata"]["name"],
                )
                body["metadata"]["resourceVersion"] = existing["metadata"]["resourceVersion"]
                self._custom.replace_namespaced_custom_object(
                    FRR_GROUP,
                    FRR_VERSION,
                    self._cfg.frr_namespace,
                    FRR_PLURAL,
                    body["metadata"]["name"],
                    body,
                )
            except k8s_client.ApiException as exc:
                if exc.status == 404:
                    self._custom.create_namespaced_custom_object(
                        FRR_GROUP,
                        FRR_VERSION,
                        self._cfg.frr_namespace,
                        FRR_PLURAL,
                        body,
                    )
                    created += 1
                    logger.info("Created FRRConfiguration %s", body["metadata"]["name"])
                else:
                    logger.exception(
                        "Failed to reconcile FRRConfiguration %s",
                        body["metadata"]["name"],
                    )

        return created, deleted

    def _cleanup_stale_frr(self, desired_names: set[str]) -> int:
        """Delete FRRConfigurations with our label that are no longer desired."""
        deleted = 0
        try:
            existing = self._custom.list_namespaced_custom_object(
                FRR_GROUP,
                FRR_VERSION,
                self._cfg.frr_namespace,
                FRR_PLURAL,
                label_selector=f"{self._cfg.frr_label_key}={self._cfg.frr_label_value}",
            )
        except k8s_client.ApiException:
            logger.exception("Failed to list FRRConfigurations")
            return 0

        for item in existing.get("items", []):
            name = item["metadata"]["name"]
            if name not in desired_names:
                try:
                    self._custom.delete_namespaced_custom_object(
                        FRR_GROUP,
                        FRR_VERSION,
                        self._cfg.frr_namespace,
                        FRR_PLURAL,
                        name,
                    )
                    deleted += 1
                    logger.info("Deleted stale FRRConfiguration %s", name)
                except k8s_client.ApiException:
                    logger.exception("Failed to delete FRRConfiguration %s", name)

        return deleted
