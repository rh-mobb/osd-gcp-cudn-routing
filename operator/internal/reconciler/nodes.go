package reconciler

import (
	"context"
	"fmt"
	"regexp"
	"sort"

	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const topologyZoneLabel = "topology.kubernetes.io/zone"

const (
	AnnotationGCPCanIPForward         = "routing.osd.redhat.com/gcp-can-ip-forward"
	AnnotationGCPNestedVirtualization = "routing.osd.redhat.com/gcp-nested-virtualization"
)

func ControllerGCPAnnotationKeys() []string {
	return []string{AnnotationGCPCanIPForward, AnnotationGCPNestedVirtualization}
}

var providerIDRe = regexp.MustCompile(`^gce://(?P<project>[^/]+)/(?P<zone>[^/]+)/(?P<name>.+)$`)

// Candidate is an eligible worker node with GCE identity.
type Candidate struct {
	K8sName        string
	TopologyZone   string
	RouterNode     gcp.RouterNode
	HasRouterLabel bool
}

// DiscoverCandidates lists worker nodes matching the config selector (excluding infra)
// with valid GCE providerID and InternalIP.
func DiscoverCandidates(ctx context.Context, c client.Client, cfg *ReconcilerConfig) ([]Candidate, error) {
	nodeSel, err := labels.Parse(cfg.NodeLabelSelector())
	if err != nil {
		return nil, fmt.Errorf("node label selector: %w", err)
	}
	var list corev1.NodeList
	if err := c.List(ctx, &list, client.MatchingLabelsSelector{Selector: nodeSel}); err != nil {
		return nil, err
	}

	var out []Candidate
	for i := range list.Items {
		node := &list.Items[i]
		nodeLabels := node.Labels
		if nodeLabels == nil {
			nodeLabels = map[string]string{}
		}
		if _, infra := nodeLabels[cfg.InfraExcludeLabelKey]; infra {
			continue
		}
		pid := node.Spec.ProviderID
		m := providerIDRe.FindStringSubmatch(pid)
		if m == nil {
			continue
		}
		sub := providerIDRe.SubexpNames()
		var project, zone, inst string
		for j, name := range sub {
			if j == 0 || name == "" {
				continue
			}
			switch name {
			case "project":
				project = m[j]
			case "zone":
				zone = m[j]
			case "name":
				inst = m[j]
			}
		}
		topologyZone := nodeLabels[topologyZoneLabel]
		if topologyZone == "" {
			topologyZone = zone
		}
		internalIP := ""
		for _, a := range node.Status.Addresses {
			if a.Type == corev1.NodeInternalIP {
				internalIP = a.Address
				break
			}
		}
		if internalIP == "" {
			continue
		}
		selfLink := fmt.Sprintf("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/instances/%s", project, zone, inst)
		_, hasRouter := nodeLabels[cfg.RouterLabelKey]
		out = append(out, Candidate{
			K8sName:        node.Name,
			TopologyZone:   topologyZone,
			HasRouterLabel: hasRouter,
			RouterNode: gcp.RouterNode{
				Name:      inst,
				SelfLink:  selfLink,
				Zone:      zone,
				IPAddress: internalIP,
			},
		})
	}
	return out, nil
}

// SortCandidates sorts by (instance name, k8s name).
func SortCandidates(in []Candidate) []Candidate {
	out := append([]Candidate(nil), in...)
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].RouterNode.Name, out[j].RouterNode.Name
		if a != b {
			return a < b
		}
		return out[i].K8sName < out[j].K8sName
	})
	return out
}

// SyncRouterLabels adds router label to selected nodes and removes from non-selected candidates.
func SyncRouterLabels(ctx context.Context, c client.Client, cfg *ReconcilerConfig, selected, candidates []Candidate) (int, error) {
	selectedNames := make(map[string]struct{})
	for _, s := range selected {
		selectedNames[s.K8sName] = struct{}{}
	}
	changes := 0
	for _, cand := range selected {
		if !cand.HasRouterLabel {
			if err := patchNodeMetadata(ctx, c, cand.K8sName, map[string]string{cfg.RouterLabelKey: ""}, nil, nil, nil); err != nil {
				return changes, fmt.Errorf("add router label %q on node %q: %w", cfg.RouterLabelKey, cand.K8sName, err)
			}
			changes++
		}
	}
	for _, cand := range candidates {
		if _, ok := selectedNames[cand.K8sName]; ok {
			continue
		}
		if cand.HasRouterLabel {
			if err := patchNodeMetadata(ctx, c, cand.K8sName, nil, []string{cfg.RouterLabelKey}, nil, ControllerGCPAnnotationKeys()); err != nil {
				return changes, fmt.Errorf("remove router label %q from node %q: %w", cfg.RouterLabelKey, cand.K8sName, err)
			}
			changes++
		}
	}
	n, err := removeRouterLabelFromNonSelected(ctx, c, cfg, selectedNames)
	return changes + n, err
}

func patchNodeMetadata(ctx context.Context, c client.Client, nodeName string,
	labelAdd map[string]string, labelRemove []string,
	annAdd map[string]string, annRemove []string,
) error {
	var node corev1.Node
	if err := c.Get(ctx, types.NamespacedName{Name: nodeName}, &node); err != nil {
		return err
	}
	nodeLabels := node.Labels
	if nodeLabels == nil {
		nodeLabels = map[string]string{}
	}
	for _, k := range labelRemove {
		delete(nodeLabels, k)
	}
	for k, v := range labelAdd {
		nodeLabels[k] = v
	}
	node.Labels = nodeLabels

	ann := node.Annotations
	if ann == nil {
		ann = map[string]string{}
	}
	for _, k := range annRemove {
		delete(ann, k)
	}
	for k, v := range annAdd {
		ann[k] = v
	}
	node.Annotations = ann
	return c.Update(ctx, &node)
}

func removeRouterLabelFromNonSelected(ctx context.Context, c client.Client, cfg *ReconcilerConfig, selectedNames map[string]struct{}) (int, error) {
	rSel, err := labels.Parse(cfg.RouterLabelKey)
	if err != nil {
		return 0, err
	}
	var list corev1.NodeList
	if err := c.List(ctx, &list, client.MatchingLabelsSelector{Selector: rSel}); err != nil {
		return 0, err
	}
	changes := 0
	for i := range list.Items {
		name := list.Items[i].Name
		if _, ok := selectedNames[name]; ok {
			continue
		}
		nodeLabels := list.Items[i].Labels
		if nodeLabels == nil {
			continue
		}
		if _, has := nodeLabels[cfg.RouterLabelKey]; !has {
			continue
		}
		if err := patchNodeMetadata(ctx, c, name, nil, []string{cfg.RouterLabelKey}, nil, ControllerGCPAnnotationKeys()); err != nil {
			return changes, fmt.Errorf("remove stale router label from node %q: %w", name, err)
		}
		changes++
	}
	return changes, nil
}

// RemoveAllRouterLabels strips the router label from every node that has it.
func RemoveAllRouterLabels(ctx context.Context, c client.Client, cfg *ReconcilerConfig) (int, error) {
	rSel, err := labels.Parse(cfg.RouterLabelKey)
	if err != nil {
		return 0, err
	}
	var list corev1.NodeList
	if err := c.List(ctx, &list, client.MatchingLabelsSelector{Selector: rSel}); err != nil {
		return 0, err
	}
	n := 0
	for i := range list.Items {
		if err := patchNodeMetadata(ctx, c, list.Items[i].Name, nil, []string{cfg.RouterLabelKey}, nil, ControllerGCPAnnotationKeys()); err != nil {
			return n, fmt.Errorf("remove router label from node %q: %w", list.Items[i].Name, err)
		}
		n++
	}
	return n, nil
}
