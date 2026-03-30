"""CLI entry point: python -m bgp_routing_controller [--once]."""

from __future__ import annotations

import argparse
import logging
import os
import subprocess
import sys

from kubernetes import config as k8s_config

from .config import ControllerConfig
from .gcp import GCPClient
from .reconciler import Reconciler

logging.basicConfig(
    level=logging.DEBUG if os.environ.get("DEBUG") else logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s  %(message)s",
)
logger = logging.getLogger(__name__)


def _init() -> tuple[ControllerConfig, Reconciler]:
    """Load config and build a Reconciler."""
    cfg = ControllerConfig.from_env()

    try:
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        k8s_config.load_kube_config()

    gcp = GCPClient(project=cfg.gcp_project, region=cfg.cloud_router_region)
    return cfg, Reconciler(cfg, gcp)


def _log_config(cfg: ControllerConfig) -> None:
    logger.info("  GCP project:       %s", cfg.gcp_project)
    logger.info("  Cloud Router:      %s (%s)", cfg.cloud_router_name, cfg.cloud_router_region)
    logger.info("  NCC hub:           %s", cfg.ncc_hub_name)
    logger.info("  NCC spoke:         %s", cfg.ncc_spoke_name)
    logger.info("  Node selector:     %s", cfg.node_label_selector)
    logger.info("  FRR ASN:           %d", cfg.frr_asn)


def _run_once() -> int:
    """Single reconciliation pass. Returns 0 on success, 1 on failure."""
    cfg, reconciler = _init()
    logger.info("Running one-shot reconciliation")
    _log_config(cfg)

    result = reconciler.reconcile()

    logger.info("Result: %s", result)
    if result.any_change:
        logger.info(
            "Changes applied — nodes=%d canIpForward=%d spoke=%s peers=%s frr_created=%d frr_deleted=%d",
            result.nodes_found,
            result.can_ip_forward_changed,
            result.spoke_changed,
            result.peers_changed,
            result.frr_created,
            result.frr_deleted,
        )
    else:
        logger.info("No changes needed (%d nodes in sync)", result.nodes_found)
    return 0


def _run_cleanup() -> int:
    """Delete all controller-managed resources. Returns 0 on success."""
    cfg, reconciler = _init()
    logger.info("Running cleanup — deleting all controller-managed resources")
    _log_config(cfg)

    reconciler.cleanup()
    return 0


def _run_operator() -> int:
    """Start the long-running kopf operator."""
    return subprocess.call(
        [sys.executable, "-m", "kopf", "run", "-m", "bgp_routing_controller.main", "--verbose"],
        env={**os.environ, "PYTHONPATH": os.path.dirname(os.path.dirname(__file__))},
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="bgp_routing_controller",
        description="BGP routing controller for OSD-GCP CUDN",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--once",
        action="store_true",
        help="Run a single reconciliation pass and exit (no operator loop)",
    )
    group.add_argument(
        "--cleanup",
        action="store_true",
        help="Delete all controller-managed resources (BGP peers, NCC spoke, FRRConfigurations) and exit",
    )
    args = parser.parse_args()

    try:
        if args.cleanup:
            sys.exit(_run_cleanup())
        elif args.once:
            sys.exit(_run_once())
        else:
            sys.exit(_run_operator())
    except Exception:
        logger.exception("Fatal error")
        sys.exit(1)


main()
