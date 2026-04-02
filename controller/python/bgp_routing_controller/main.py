"""kopf handlers — entry point for the BGP routing controller."""

from __future__ import annotations

import logging
import threading
import time

import kopf
from kubernetes import config as k8s_config

from .config import ControllerConfig
from .gcp import GCPClient
from .reconciler import Reconciler

logger = logging.getLogger(__name__)

_reconciler: Reconciler | None = None
_cfg: ControllerConfig | None = None
_last_reconcile: float = 0.0


def _periodic_loop() -> None:
    """Background thread for periodic drift reconciliation."""
    assert _reconciler is not None and _cfg is not None
    while True:
        time.sleep(_cfg.reconcile_interval_seconds)
        try:
            _reconciler.reconcile()
        except Exception:
            logger.exception("Periodic reconciliation failed")


@kopf.on.startup()
def startup(settings: kopf.OperatorSettings, **kwargs) -> None:
    global _reconciler, _cfg

    settings.posting.level = logging.WARNING
    # No finalizers or annotations on Nodes — pure event watching.
    settings.persistence.finalizer = (
        "bgp-routing-controller.cudn.redhat.com/kopf-finalizer"
    )

    _cfg = ControllerConfig.from_env()

    try:
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        k8s_config.load_kube_config()

    gcp = GCPClient(project=_cfg.gcp_project, region=_cfg.cloud_router_region)
    _reconciler = Reconciler(_cfg, gcp)

    logger.info("BGP routing controller started")
    logger.info("  GCP project:       %s", _cfg.gcp_project)
    logger.info("  Cloud Router:      %s (%s)", _cfg.cloud_router_name, _cfg.cloud_router_region)
    logger.info("  NCC hub:           %s", _cfg.ncc_hub_name)
    logger.info("  NCC spoke prefix:  %s (spokes {prefix}-0, {prefix}-1, …)", _cfg.ncc_spoke_prefix)
    logger.info("  Worker pool label: %s", _cfg.node_label_selector)
    logger.info("  Router label key:  %s", _cfg.router_label_key)
    logger.info("  FRR ASN:           %d", _cfg.frr_asn)

    _reconciler.reconcile()

    t = threading.Thread(target=_periodic_loop, daemon=True, name="periodic-reconcile")
    t.start()
    logger.info(
        "Periodic reconciliation every %.0fs", _cfg.reconcile_interval_seconds
    )


@kopf.on.event("", "v1", "nodes")
def on_node_event(event, **kwargs) -> None:
    """React to any Node event (create, update, delete, status change)."""
    global _last_reconcile

    if _reconciler is None:
        return

    now = time.monotonic()
    if now - _last_reconcile < _cfg.debounce_seconds:
        return
    _last_reconcile = now

    node_name = event.get("object", {}).get("metadata", {}).get("name", "?")
    event_type = event.get("type", "?")
    logger.debug("Node event %s on %s — triggering reconciliation", event_type, node_name)

    try:
        _reconciler.reconcile()
    except Exception:
        logger.exception("Event-driven reconciliation failed (will retry on next event)")
