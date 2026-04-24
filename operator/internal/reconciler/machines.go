package reconciler

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	MachineGroup          = "machine.openshift.io"
	MachineVersion        = "v1beta1"
	MachineKind           = "Machine"
	MachineResource       = "machines"
	BGPLifecycleHookName  = "routing.osd.redhat.com/bgp-cleanup"
	BGPLifecycleHookOwner = "BGPRoutingConfig"
)

var machineGVK = schema.GroupVersionKind{
	Group:   MachineGroup,
	Version: MachineVersion,
	Kind:    MachineKind,
}

var machineListGVK = schema.GroupVersionKind{
	Group:   MachineGroup,
	Version: MachineVersion,
	Kind:    MachineKind + "List",
}

// terminatingMachine holds identity for a Machine that is being deleted and has our hook.
type terminatingMachine struct {
	Name      string
	Namespace string
	SelfLink  string
}

// FindTerminatingMachines lists all Machines in cfg.MachineNamespace, adds our preTerminate
// lifecycle hook to active BGP router Machines (idempotent), and returns those that are
// terminating with our hook present. Machines whose selfLink is no longer in routerSelfLinks
// have the hook removed as cleanup.
//
// Returns nil, nil on non-OCP clusters where the machine.openshift.io API group is absent.
func FindTerminatingMachines(ctx context.Context, c client.Client, cfg *ReconcilerConfig, routerSelfLinks map[string]struct{}) ([]terminatingMachine, error) {
	var list unstructured.UnstructuredList
	list.SetGroupVersionKind(machineListGVK)
	if err := c.List(ctx, &list, client.InNamespace(cfg.MachineNamespace)); err != nil {
		if apierrors.IsNotFound(err) || isMachineAPIAbsent(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list machines: %w", err)
	}

	var terminating []terminatingMachine
	for i := range list.Items {
		m := &list.Items[i]
		selfLink, err := machineGCESelfLink(m)
		if err != nil || selfLink == "" {
			continue
		}

		_, inRouterSet := routerSelfLinks[selfLink]
		isDeleting := m.GetDeletionTimestamp() != nil
		hasHook := hasBGPLifecycleHook(m)

		switch {
		case inRouterSet && isDeleting && hasHook:
			terminating = append(terminating, terminatingMachine{
				Name:      m.GetName(),
				Namespace: m.GetNamespace(),
				SelfLink:  selfLink,
			})
		case inRouterSet && !isDeleting && !hasHook:
			if err := addLifecycleHook(ctx, c, m); err != nil {
				return nil, fmt.Errorf("add lifecycle hook to machine %s: %w", m.GetName(), err)
			}
		case !inRouterSet && hasHook:
			if err := removeLifecycleHook(ctx, c, m); err != nil {
				return nil, fmt.Errorf("remove lifecycle hook from machine %s: %w", m.GetName(), err)
			}
		}
	}
	return terminating, nil
}

// ReleaseMachines removes our lifecycle hook from each terminating Machine, unblocking
// the Machine controller to proceed with GCE instance deletion. Must only be called
// after BGP peers have been successfully removed.
func ReleaseMachines(ctx context.Context, c client.Client, machines []terminatingMachine) error {
	for _, tm := range machines {
		var m unstructured.Unstructured
		m.SetGroupVersionKind(machineGVK)
		if err := c.Get(ctx, client.ObjectKey{Name: tm.Name, Namespace: tm.Namespace}, &m); err != nil {
			if apierrors.IsNotFound(err) {
				continue
			}
			return fmt.Errorf("get machine %s/%s: %w", tm.Namespace, tm.Name, err)
		}
		if err := removeLifecycleHook(ctx, c, &m); err != nil {
			return fmt.Errorf("release lifecycle hook on machine %s: %w", tm.Name, err)
		}
	}
	return nil
}

// selfLinkSet builds a set of GCE instance selfLinks from a slice of RouterNodes.
func selfLinkSet(nodes []gcp.RouterNode) map[string]struct{} {
	out := make(map[string]struct{}, len(nodes))
	for _, n := range nodes {
		out[n.SelfLink] = struct{}{}
	}
	return out
}

// excludeTerminating returns a copy of nodes with terminating instances removed.
func excludeTerminating(nodes []gcp.RouterNode, terminating []terminatingMachine) []gcp.RouterNode {
	if len(terminating) == 0 {
		return nodes
	}
	skip := make(map[string]struct{}, len(terminating))
	for _, tm := range terminating {
		skip[tm.SelfLink] = struct{}{}
	}
	var out []gcp.RouterNode
	for _, n := range nodes {
		if _, found := skip[n.SelfLink]; !found {
			out = append(out, n)
		}
	}
	return out
}

// addLifecycleHook patches the Machine to add our preTerminate lifecycle hook (idempotent).
func addLifecycleHook(ctx context.Context, c client.Client, m *unstructured.Unstructured) error {
	hooks := getPreTerminateHooks(m)
	for _, h := range hooks {
		hm, _ := h.(map[string]interface{})
		if hm["name"] == BGPLifecycleHookName {
			return nil
		}
	}
	hooks = append(hooks, map[string]interface{}{
		"name":  BGPLifecycleHookName,
		"owner": BGPLifecycleHookOwner,
	})
	return patchLifecycleHooks(ctx, c, m, hooks)
}

// removeLifecycleHook patches the Machine to remove our preTerminate lifecycle hook (idempotent).
func removeLifecycleHook(ctx context.Context, c client.Client, m *unstructured.Unstructured) error {
	hooks := getPreTerminateHooks(m)
	var filtered []interface{}
	for _, h := range hooks {
		hm, _ := h.(map[string]interface{})
		if hm["name"] == BGPLifecycleHookName {
			continue
		}
		filtered = append(filtered, h)
	}
	if len(filtered) == len(hooks) {
		return nil
	}
	return patchLifecycleHooks(ctx, c, m, filtered)
}

func getPreTerminateHooks(m *unstructured.Unstructured) []interface{} {
	lh, _, _ := unstructured.NestedMap(m.Object, "spec", "lifecycleHooks")
	if lh == nil {
		return nil
	}
	pt, _ := lh["preTerminate"].([]interface{})
	return pt
}

func hasBGPLifecycleHook(m *unstructured.Unstructured) bool {
	for _, h := range getPreTerminateHooks(m) {
		hm, _ := h.(map[string]interface{})
		if hm["name"] == BGPLifecycleHookName {
			return true
		}
	}
	return false
}

type lifecycleHookPatch struct {
	Spec struct {
		LifecycleHooks struct {
			PreTerminate []lifecycleHookEntry `json:"preTerminate,omitempty"`
		} `json:"lifecycleHooks"`
	} `json:"spec"`
}

type lifecycleHookEntry struct {
	Name  string `json:"name"`
	Owner string `json:"owner"`
}

func patchLifecycleHooks(ctx context.Context, c client.Client, m *unstructured.Unstructured, hooks []interface{}) error {
	var p lifecycleHookPatch
	for _, h := range hooks {
		hm, _ := h.(map[string]interface{})
		name, _ := hm["name"].(string)
		owner, _ := hm["owner"].(string)
		p.Spec.LifecycleHooks.PreTerminate = append(p.Spec.LifecycleHooks.PreTerminate, lifecycleHookEntry{Name: name, Owner: owner})
	}
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	patch := m.DeepCopy()
	return c.Patch(ctx, patch, client.RawPatch(types.MergePatchType, data))
}

// machineGCESelfLink extracts the GCE instance selfLink from a Machine's spec.providerID.
// Returns "" if the providerID is absent or not a GCE provider ID.
func machineGCESelfLink(m *unstructured.Unstructured) (string, error) {
	pid, found, err := unstructured.NestedString(m.Object, "spec", "providerID")
	if err != nil || !found || pid == "" {
		return "", nil
	}
	parts := providerIDRe.FindStringSubmatch(pid)
	if parts == nil {
		return "", nil
	}
	sub := providerIDRe.SubexpNames()
	var project, zone, inst string
	for i, n := range sub {
		switch n {
		case "project":
			project = parts[i]
		case "zone":
			zone = parts[i]
		case "name":
			inst = parts[i]
		}
	}
	if project == "" || zone == "" || inst == "" {
		return "", nil
	}
	return fmt.Sprintf("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/instances/%s", project, zone, inst), nil
}

// isMachineAPIAbsent returns true for errors indicating the machine.openshift.io API group
// is not registered on the cluster (e.g. non-OCP environments like kind or local dev).
func isMachineAPIAbsent(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "no matches for kind") ||
		strings.Contains(msg, "no kind is registered") ||
		strings.Contains(msg, "the server could not find the requested resource")
}
