"""GCP API operations for canIpForward, NCC spoke, and Cloud Router peers."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

from google.api_core.exceptions import NotFound
from google.cloud import compute_v1
from google.cloud import networkconnectivity_v1 as network_connectivity_v1
from google.protobuf import field_mask_pb2

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RouterNode:
    """A GCE instance that participates in BGP routing."""

    name: str
    self_link: str
    zone: str
    ip_address: str


@dataclass(frozen=True)
class CloudRouterTopology:
    """Discovered Cloud Router interfaces and ASN."""

    cloud_router_asn: int
    interface_names: list[str]
    interface_ips: list[str]


class GCPClient:
    """Wraps GCP Compute and NCC APIs for the BGP routing reconciler."""

    def __init__(self, project: str, region: str):
        self._project = project
        self._region = region
        self._instances = compute_v1.InstancesClient()
        self._routers = compute_v1.RoutersClient()
        self._hubs = network_connectivity_v1.HubServiceClient()

    # -- canIpForward (step 1) ------------------------------------------------

    def ensure_can_ip_forward(self, node: RouterNode) -> bool:
        """Enable canIpForward on an instance. Returns True if a change was made."""
        zone = _short_zone(node.zone)
        instance = self._instances.get(
            project=self._project, zone=zone, instance=node.name
        )
        if instance.can_ip_forward:
            return False

        instance.can_ip_forward = True
        op = self._instances.update(
            request=compute_v1.UpdateInstanceRequest(
                project=self._project,
                zone=zone,
                instance=node.name,
                instance_resource=instance,
                most_disruptive_allowed_action="REFRESH",
            )
        )
        op.result()
        logger.info("Enabled canIpForward on %s", node.name)
        return True

    # -- NCC spoke (step 2) ---------------------------------------------------

    def reconcile_spoke(
        self,
        spoke_name: str,
        hub_name: str,
        desired_nodes: list[RouterNode],
        site_to_site_data_transfer: bool = False,
    ) -> bool:
        """Create or update the NCC spoke so linked_router_appliance_instances matches desired_nodes."""
        spoke_path = (
            f"projects/{self._project}/locations/{self._region}/spokes/{spoke_name}"
        )
        try:
            spoke = self._hubs.get_spoke(
                request=network_connectivity_v1.GetSpokeRequest(name=spoke_path)
            )
        except NotFound:
            return self._create_spoke(
                spoke_name, hub_name, desired_nodes, site_to_site_data_transfer
            )

        current = {
            inst.virtual_machine
            for inst in spoke.linked_router_appliance_instances.instances
        }
        desired = {n.self_link for n in desired_nodes}

        if current == desired:
            return False

        spoke.linked_router_appliance_instances.instances = [
            network_connectivity_v1.RouterApplianceInstance(
                virtual_machine=n.self_link,
                ip_address=n.ip_address,
            )
            for n in sorted(desired_nodes, key=lambda n: n.name)
        ]
        op = self._hubs.update_spoke(
            request=network_connectivity_v1.UpdateSpokeRequest(
                spoke=spoke,
                update_mask=field_mask_pb2.FieldMask(
                    paths=["linked_router_appliance_instances"]
                ),
            )
        )
        op.result()
        added = desired - current
        removed = current - desired
        logger.info(
            "Updated NCC spoke %s: +%d -%d instances", spoke_name, len(added), len(removed)
        )
        return True

    def _create_spoke(
        self,
        spoke_name: str,
        hub_name: str,
        desired_nodes: list[RouterNode],
        site_to_site_data_transfer: bool,
    ) -> bool:
        """Create a new NCC spoke attached to the hub with the desired router nodes."""
        if hub_name.startswith("projects/"):
            hub_path = hub_name
        else:
            hub_path = f"projects/{self._project}/locations/global/hubs/{hub_name}"
        parent = f"projects/{self._project}/locations/{self._region}"

        spoke = network_connectivity_v1.Spoke(
            name=f"{parent}/spokes/{spoke_name}",
            hub=hub_path,
            description="Router appliance spoke for OSD BGP routing (managed by controller)",
            linked_router_appliance_instances=network_connectivity_v1.LinkedRouterApplianceInstances(
                site_to_site_data_transfer=site_to_site_data_transfer,
                instances=[
                    network_connectivity_v1.RouterApplianceInstance(
                        virtual_machine=n.self_link,
                        ip_address=n.ip_address,
                    )
                    for n in sorted(desired_nodes, key=lambda n: n.name)
                ],
            ),
        )
        op = self._hubs.create_spoke(
            request=network_connectivity_v1.CreateSpokeRequest(
                parent=parent,
                spoke_id=spoke_name,
                spoke=spoke,
            )
        )
        op.result()
        logger.info(
            "Created NCC spoke %s with %d instance(s)", spoke_name, len(desired_nodes)
        )
        return True

    def delete_spoke(self, spoke_name: str) -> bool:
        """Delete the NCC spoke. Returns True if it existed and was deleted."""
        spoke_path = (
            f"projects/{self._project}/locations/{self._region}/spokes/{spoke_name}"
        )
        try:
            op = self._hubs.delete_spoke(
                request=network_connectivity_v1.DeleteSpokeRequest(name=spoke_path)
            )
            op.result()
            logger.info("Deleted NCC spoke %s", spoke_name)
            return True
        except NotFound:
            logger.info("NCC spoke %s not found (already deleted)", spoke_name)
            return False

    # -- Cloud Router (step 3) ------------------------------------------------

    def get_router_topology(self, router_name: str) -> CloudRouterTopology:
        """Read Cloud Router interfaces and ASN (source of truth for peer config)."""
        router = self._routers.get(
            project=self._project, region=self._region, router=router_name
        )
        iface_names = [iface.name for iface in router.interfaces]
        iface_ips = [
            iface.ip_range.split("/")[0] if "/" in iface.ip_range else iface.ip_range
            for iface in router.interfaces
        ]
        return CloudRouterTopology(
            cloud_router_asn=router.bgp.asn,
            interface_names=iface_names,
            interface_ips=iface_ips,
        )

    def reconcile_peers(
        self,
        router_name: str,
        cluster_name: str,
        desired_nodes: list[RouterNode],
        topology: CloudRouterTopology,
        frr_asn: int,
    ) -> bool:
        """Set Cloud Router BGP peers to exactly the desired set."""
        router = self._routers.get(
            project=self._project, region=self._region, router=router_name
        )

        sorted_nodes = sorted(desired_nodes, key=lambda n: n.name)
        desired_peers: list[compute_v1.RouterBgpPeer] = []
        for idx, node in enumerate(sorted_nodes):
            for iface_idx, iface_name in enumerate(topology.interface_names):
                peer = compute_v1.RouterBgpPeer(
                    name=f"{cluster_name}-bgp-peer-{idx}-{iface_idx}",
                    interface_name=iface_name,
                    peer_ip_address=node.ip_address,
                    ip_address=topology.interface_ips[iface_idx],
                    peer_asn=frr_asn,
                    router_appliance_instance=node.self_link,
                )
                desired_peers.append(peer)

        current_peer_set = {
            (p.name, p.peer_ip_address, p.peer_asn) for p in router.bgp_peers
        }
        desired_peer_set = {
            (p.name, p.peer_ip_address, p.peer_asn) for p in desired_peers
        }

        if current_peer_set == desired_peer_set:
            return False

        patch = compute_v1.Router()
        patch.bgp_peers = desired_peers
        op = self._routers.patch(
            project=self._project,
            region=self._region,
            router=router_name,
            router_resource=patch,
        )
        op.result()
        logger.info(
            "Updated Cloud Router %s peers: %d peers for %d nodes",
            router_name,
            len(desired_peers),
            len(sorted_nodes),
        )
        return True


    def clear_peers(self, router_name: str) -> bool:
        """Remove all BGP peers from the Cloud Router. Returns True if any were removed.

        Uses update (PUT) instead of patch because proto3 serialization
        omits empty repeated fields, making patch silently skip the change.
        """
        router = self._routers.get(
            project=self._project, region=self._region, router=router_name
        )
        if not router.bgp_peers:
            logger.info("Cloud Router %s has no BGP peers", router_name)
            return False

        count = len(router.bgp_peers)
        router.bgp_peers = []
        op = self._routers.update(
            project=self._project,
            region=self._region,
            router=router_name,
            router_resource=router,
        )
        op.result()
        logger.info("Removed %d BGP peer(s) from Cloud Router %s", count, router_name)
        return True


def _short_zone(zone: str) -> str:
    """Extract the zone suffix from a full zone URL or return as-is."""
    m = re.search(r"zones/([^/]+)$", zone)
    return m.group(1) if m else zone
