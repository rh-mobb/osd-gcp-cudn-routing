package reconciler

import (
	"context"
	"fmt"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	appsv1 "k8s.io/api/apps/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	crlog "sigs.k8s.io/controller-runtime/pkg/log"
)

// ReconcileResult summarizes a reconciliation pass.
type ReconcileResult struct {
	NodesFound                  int
	CanIPForwardChanged         int
	NestedVirtualizationChanged int
	SpokesChanged               int
	PeersChanged                bool
	FRRCreated                  int
	FRRDeleted                  int
	RouterLabelsChanged         int
}

// AnyChange reports whether any mutating step ran.
func (r ReconcileResult) AnyChange() bool {
	return r.CanIPForwardChanged > 0 || r.NestedVirtualizationChanged > 0 || r.SpokesChanged > 0 || r.PeersChanged ||
		r.FRRCreated > 0 || r.FRRDeleted > 0 || r.RouterLabelsChanged > 0
}

// Reconciler orchestrates node discovery, GCP, and FRR CR alignment.
type Reconciler struct {
	Cfg     *config.ControllerConfig
	Client  client.Client
	Compute gcp.ComputeClient
	NCC     gcp.NCCClient
}

// Reconcile runs the full loop (Python Reconciler.reconcile).
func (r *Reconciler) Reconcile(ctx context.Context) (ReconcileResult, error) {
	log := crlog.FromContext(ctx)
	var res ReconcileResult
	cands, err := DiscoverCandidates(ctx, r.Client, r.Cfg)
	if err != nil {
		return res, err
	}
	if len(cands) == 0 {
		log.Info("no eligible BGP router candidates (selector/labels/providerID); cleaning stale FRR if any")
		d, err := CleanupStaleFRR(ctx, r.Client, r.Cfg, map[string]struct{}{})
		if err != nil {
			return res, err
		}
		res.FRRDeleted = d
		n, err := removeRouterLabelFromNonSelected(ctx, r.Client, r.Cfg, map[string]struct{}{})
		res.RouterLabelsChanged = n
		return res, err
	}

	selected := SortCandidates(cands)
	log.Info("BGP router selection",
		"candidates", len(cands),
		"selectedInstances", instanceNamesForLog(selected, 16),
	)
	n, err := SyncRouterLabels(ctx, r.Client, r.Cfg, selected, cands)
	if err != nil {
		return res, err
	}
	res.RouterLabelsChanged = n
	if n > 0 {
		log.Info("router label sync applied", "nodePatches", n)
	}

	routerNodes := make([]gcp.RouterNode, len(selected))
	nodeMap := make(map[string]string, len(selected))
	for i := range selected {
		routerNodes[i] = selected[i].RouterNode
		nodeMap[selected[i].RouterNode.Name] = selected[i].K8sName
	}
	res.NodesFound = len(routerNodes)

	log.Info("ensuring canIpForward on router instances", "count", len(routerNodes))
	for _, node := range routerNodes {
		changed, err := r.Compute.EnsureCanIPForward(ctx, node)
		if err != nil {
			return res, fmt.Errorf("ensure canIpForward for instance %q: %w", node.Name, err)
		}
		if changed {
			res.CanIPForwardChanged++
		}
		k8sName := nodeMap[node.Name]
		if err := patchNodeMetadata(ctx, r.Client, k8sName, nil, nil, map[string]string{AnnotationGCPCanIPForward: "true"}, nil); err != nil {
			return res, fmt.Errorf("annotate canIpForward on node %q: %w", k8sName, err)
		}
	}
	if res.CanIPForwardChanged > 0 {
		log.Info("canIpForward updated on instances", "changed", res.CanIPForwardChanged)
	}

	if r.Cfg.EnableGCENestedVirt {
		log.Info("ensuring nested virtualization on router instances", "count", len(routerNodes))
		for _, node := range routerNodes {
			changed, err := r.Compute.EnsureNestedVirtualization(ctx, node)
			if err != nil {
				return res, fmt.Errorf("ensure nested virtualization for instance %q: %w", node.Name, err)
			}
			if changed {
				res.NestedVirtualizationChanged++
			}
			k8sName := nodeMap[node.Name]
			if err := patchNodeMetadata(ctx, r.Client, k8sName, nil, nil, map[string]string{AnnotationGCPNestedVirtualization: "true"}, nil); err != nil {
				return res, fmt.Errorf("annotate nested virtualization on node %q: %w", k8sName, err)
			}
		}
		if res.NestedVirtualizationChanged > 0 {
			log.Info("nested virtualization updated on instances", "changed", res.NestedVirtualizationChanged)
		}
	} else {
		for _, node := range routerNodes {
			k8sName := nodeMap[node.Name]
			if err := patchNodeMetadata(ctx, r.Client, k8sName, nil, nil, nil, []string{AnnotationGCPNestedVirtualization}); err != nil {
				return res, fmt.Errorf("clear nested virtualization annotation on node %q: %w", k8sName, err)
			}
		}
	}

	log.Info("reconciling NCC spokes", "hub", r.Cfg.NCCHubName, "prefix", r.Cfg.NCCSpokePrefix)
	spokeDelta, err := ReconcileNCCSpokes(ctx, r.NCC, r.Cfg, routerNodes)
	if err != nil {
		return res, err
	}
	res.SpokesChanged = spokeDelta
	if spokeDelta != 0 {
		log.Info("NCC spoke mutations", "delta", spokeDelta)
	}

	log.Info("reconciling Cloud Router BGP peers", "router", r.Cfg.CloudRouterName, "region", r.Cfg.CloudRouterRegion)
	topology, err := r.Compute.GetRouterTopology(ctx, r.Cfg.CloudRouterName)
	if err != nil {
		return res, err
	}
	peerChanged, err := r.Compute.ReconcilePeers(ctx, r.Cfg.CloudRouterName, r.Cfg.ClusterName, routerNodes, topology, r.Cfg.FRRASN)
	if err != nil {
		return res, err
	}
	res.PeersChanged = peerChanged
	if peerChanged {
		log.Info("Cloud Router BGP peers updated")
	}

	log.Info("reconciling FRRConfiguration CRs", "namespace", r.Cfg.FRRNamespace)
	cr, del, err := ReconcileFRRConfigurations(ctx, r.Client, r.Cfg, routerNodes, nodeMap, topology)
	if err != nil {
		return res, err
	}
	res.FRRCreated = cr
	res.FRRDeleted = del
	if cr > 0 || del > 0 {
		log.Info("FRRConfiguration changes", "created", cr, "deleted", del)
	}

	return res, nil
}

// instanceNamesForLog returns GCE instance names from selected candidates (cap for log size).
func instanceNamesForLog(selected []Candidate, cap int) []string {
	if cap <= 0 || len(selected) == 0 {
		return nil
	}
	n := len(selected)
	if n > cap {
		n = cap
	}
	out := make([]string, 0, n+1)
	for i := 0; i < n; i++ {
		out = append(out, selected[i].RouterNode.Name)
	}
	if len(selected) > cap {
		out = append(out, "...")
	}
	return out
}

// Cleanup removes controller-managed resources (Python cleanup order).
func (r *Reconciler) Cleanup(ctx context.Context) error {
	if err := r.deleteControllerDeployment(ctx); err != nil {
		return err
	}
	if _, err := RemoveAllRouterLabels(ctx, r.Client, r.Cfg); err != nil {
		return fmt.Errorf("remove router labels: %w", err)
	}
	if _, err := CleanupStaleFRR(ctx, r.Client, r.Cfg, map[string]struct{}{}); err != nil {
		return fmt.Errorf("delete FRR configurations: %w", err)
	}
	if _, err := r.Compute.ClearPeers(ctx, r.Cfg.CloudRouterName); err != nil {
		return fmt.Errorf("clear cloud router peers: %w", err)
	}
	ids, err := r.NCC.ListSpokesByPrefix(ctx, r.Cfg.NCCHubName, r.Cfg.NCCSpokePrefix)
	if err != nil {
		return fmt.Errorf("list spokes: %w", err)
	}
	for _, id := range ids {
		if _, err := r.NCC.DeleteSpoke(ctx, id); err != nil {
			return fmt.Errorf("delete spoke %s: %w", id, err)
		}
	}
	return nil
}

func (r *Reconciler) deleteControllerDeployment(ctx context.Context) error {
	key := types.NamespacedName{Namespace: r.Cfg.ControllerNamespace, Name: r.Cfg.ControllerDeployment}
	var dep appsv1.Deployment
	if err := r.Client.Get(ctx, key, &dep); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	if err := r.Client.Delete(ctx, &dep); err != nil && !apierrors.IsNotFound(err) {
		return err
	}
	return nil
}
