"""Core reconciliation loop: Node list → GCP + FRR alignment."""

from __future__ import annotations

import logging
import re
from collections import deque
from dataclasses import dataclass

from kubernetes import client as k8s_client

from .config import ControllerConfig
from .frr import build_frr_configuration, frr_config_name
from .gcp import CloudRouterTopology, GCPClient, RouterNode

logger = logging.getLogger(__name__)

_PROVIDER_ID_RE = re.compile(r"^gce://(?P<project>[^/]+)/(?P<zone>[^/]+)/(?P<name>.+)$")
_TOPOLOGY_ZONE_LABEL = "topology.kubernetes.io/zone"

FRR_GROUP = "frrk8s.metallb.io"
FRR_VERSION = "v1beta1"
FRR_PLURAL = "frrconfigurations"


@dataclass(frozen=True)
class _Candidate:
    """Eligible worker (non-infra) with GCE identity and zone for spreading."""

    k8s_name: str
    topology_zone: str
    router_node: RouterNode
    has_router_label: bool


@dataclass
class ReconcileResult:
    nodes_found: int = 0
    can_ip_forward_changed: int = 0
    spoke_changed: bool = False
    peers_changed: bool = False
    frr_created: int = 0
    frr_deleted: int = 0
    router_labels_changed: int = 0

    @property
    def any_change(self) -> bool:
        return (
            self.can_ip_forward_changed > 0
            or self.spoke_changed
            or self.peers_changed
            or self.frr_created > 0
            or self.frr_deleted > 0
            or self.router_labels_changed > 0
        )


class Reconciler:
    def __init__(self, config: ControllerConfig, gcp: GCPClient):
        self._cfg = config
        self._gcp = gcp
        self._core = k8s_client.CoreV1Api()
        self._apps = k8s_client.AppsV1Api()
        self._custom = k8s_client.CustomObjectsApi()

    def reconcile(self) -> ReconcileResult:
        result = ReconcileResult()

        candidates = self._discover_candidates()
        if not candidates:
            logger.warning(
                "No eligible worker nodes (selector %s, excluding %s) — skipping GCP reconciliation",
                self._cfg.node_label_selector,
                self._cfg.infra_label_key,
            )
            self._cleanup_stale_frr(set())
            result.router_labels_changed = self._remove_router_label_from_non_selected(set())
            return result

        by_zone = self._group_candidates_by_zone(candidates)
        target = self._target_router_count(len(by_zone), len(candidates))
        selected = self._select_router_nodes(by_zone, target)

        result.router_labels_changed = self._sync_router_node_labels(selected, candidates)

        router_nodes = [c.router_node for c in selected]
        node_map = {c.router_node.name: c.k8s_name for c in selected}
        result.nodes_found = len(router_nodes)

        logger.info(
            "Reconciling %d router node(s) (target=%d, %d zone(s)): %s",
            len(router_nodes),
            target,
            len(by_zone),
            [c.k8s_name for c in selected],
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

    def _delete_controller_deployment_if_present(self) -> None:
        """Remove the controller Deployment if it exists (typical in-cluster install)."""
        ns = self._cfg.controller_namespace
        name = self._cfg.controller_deployment_name
        try:
            self._apps.delete_namespaced_deployment(
                name=name,
                namespace=ns,
                body=k8s_client.V1DeleteOptions(propagation_policy="Foreground"),
            )
            logger.info("Deleted Deployment %s/%s", ns, name)
        except k8s_client.ApiException as exc:
            if exc.status == 404:
                logger.info(
                    "Controller Deployment %s/%s not found — skipping",
                    ns,
                    name,
                )
            else:
                logger.exception(
                    "Failed to delete Deployment %s/%s (HTTP %s)",
                    ns,
                    name,
                    exc.status,
                )

    def cleanup(self) -> None:
        """Delete all controller-managed resources (reverse of reconcile)."""
        logger.info("Cleaning up all controller-managed resources")

        # 0. Stop the in-cluster Deployment first so it cannot race FRR/GCP teardown.
        self._delete_controller_deployment_if_present()

        # 1. Remove bgp-router role labels from all nodes that have them
        removed = self._remove_all_router_labels()
        logger.info("Removed %s from %d node(s)", self._cfg.router_label_key, removed)

        # 2. Delete FRRConfigurations
        deleted = self._cleanup_stale_frr(set())
        logger.info("Deleted %d FRRConfiguration(s)", deleted)

        # 3. Remove Cloud Router BGP peers
        try:
            self._gcp.clear_peers(self._cfg.cloud_router_name)
        except Exception:
            logger.exception("Failed to clear Cloud Router peers")

        # 4. Delete NCC spoke
        try:
            self._gcp.delete_spoke(self._cfg.ncc_spoke_name)
        except Exception:
            logger.exception("Failed to delete NCC spoke")

        logger.info("Cleanup complete")

    # -- Node discovery & selection -------------------------------------------

    def _discover_candidates(self) -> list[_Candidate]:
        """Workers matching node_label_selector, not infra, with GCE providerID + InternalIP."""
        nodes = self._core.list_node(label_selector=self._cfg.node_label_selector)

        candidates: list[_Candidate] = []

        for node in nodes.items:
            labels = node.metadata.labels or {}
            if self._cfg.infra_label_key in labels:
                continue

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
            topology_zone = labels.get(_TOPOLOGY_ZONE_LABEL) or zone

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

            router_node = RouterNode(
                name=instance_name,
                self_link=self_link,
                zone=zone,
                ip_address=internal_ip,
            )
            has_router = self._cfg.router_label_key in labels
            candidates.append(
                _Candidate(
                    k8s_name=node.metadata.name,
                    topology_zone=topology_zone,
                    router_node=router_node,
                    has_router_label=has_router,
                )
            )

        return candidates

    def _group_candidates_by_zone(
        self, candidates: list[_Candidate]
    ) -> dict[str, list[_Candidate]]:
        by_zone: dict[str, list[_Candidate]] = {}
        for c in candidates:
            by_zone.setdefault(c.topology_zone, []).append(c)
        return by_zone

    def _target_router_count(self, num_zones: int, num_candidates: int) -> int:
        if self._cfg.router_node_count > 0:
            t = self._cfg.router_node_count
        else:
            t = 2 if num_zones <= 1 else 3
        return min(t, num_candidates)

    def _select_router_nodes(
        self,
        by_zone: dict[str, list[_Candidate]],
        target: int,
    ) -> list[_Candidate]:
        """Round-robin across zones; labeled nodes first within each zone."""
        zones = sorted(by_zone.keys())
        queues: dict[str, deque[_Candidate]] = {}
        for z in zones:
            sorted_c = sorted(
                by_zone[z],
                key=lambda c: (not c.has_router_label, c.k8s_name),
            )
            queues[z] = deque(sorted_c)

        selected: list[_Candidate] = []
        while len(selected) < target and any(queues[z] for z in zones):
            for z in zones:
                if len(selected) >= target:
                    break
                if queues[z]:
                    selected.append(queues[z].popleft())

        return selected

    def _sync_router_node_labels(
        self,
        selected: list[_Candidate],
        candidates: list[_Candidate],
    ) -> int:
        """Add router label to selected; remove from candidates not selected."""
        selected_names = {c.k8s_name for c in selected}
        changes = 0

        for c in selected:
            if not c.has_router_label:
                if self._patch_node_label(c.k8s_name, add={self._cfg.router_label_key: ""}):
                    changes += 1

        candidate_names = {c.k8s_name for c in candidates}
        for c in candidates:
            if c.k8s_name not in selected_names and c.has_router_label:
                if self._patch_node_label(
                    c.k8s_name, remove={self._cfg.router_label_key}
                ):
                    changes += 1

        changes += self._remove_router_label_from_non_selected(selected_names)
        return changes

    def _remove_router_label_from_non_selected(self, selected_names: set[str]) -> int:
        """Remove router label from nodes that still carry it but are not selected."""
        changes = 0
        try:
            nodes = self._core.list_node(label_selector=self._cfg.router_label_key)
        except k8s_client.ApiException:
            logger.exception("Failed to list nodes with router label")
            return 0

        for node in nodes.items:
            name = node.metadata.name
            if name in selected_names:
                continue
            labels = node.metadata.labels or {}
            if self._cfg.router_label_key not in labels:
                continue
            if self._patch_node_label(name, remove={self._cfg.router_label_key}):
                changes += 1
                logger.info("Removed %s from node %s", self._cfg.router_label_key, name)
        return changes

    def _remove_all_router_labels(self) -> int:
        """Strip router label from every node that has it."""
        count = 0
        try:
            nodes = self._core.list_node(label_selector=self._cfg.router_label_key)
        except k8s_client.ApiException:
            logger.exception("Failed to list nodes with router label")
            return 0

        for node in nodes.items:
            if self._patch_node_label(
                node.metadata.name, remove={self._cfg.router_label_key}
            ):
                count += 1
        return count

    def _patch_node_label(
        self,
        node_name: str,
        add: dict[str, str] | None = None,
        remove: set[str] | None = None,
    ) -> bool:
        """Merge-update node labels. Returns True if API call succeeded."""
        try:
            node = self._core.read_node(node_name)
        except k8s_client.ApiException as exc:
            logger.warning("read_node %s: %s", node_name, exc)
            return False

        labels = dict(node.metadata.labels or {})
        if remove:
            for k in remove:
                labels.pop(k, None)
        if add:
            labels.update(add)

        body = {"metadata": {"labels": labels}}
        try:
            self._core.patch_node(node_name, body)
        except k8s_client.ApiException as exc:
            logger.exception("patch_node %s: %s", node_name, exc)
            return False
        return True

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
