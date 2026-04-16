package reconciler

import (
	"context"
	"fmt"

	frpkg "github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/frr"
	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var frrListGVK = schema.GroupVersionKind{
	Group:   frpkg.Group,
	Version: frpkg.Version,
	Kind:    frpkg.Kind + "List",
}

// CleanupStaleFRR deletes FRRConfigurations with our label that are not in desiredNames.
func CleanupStaleFRR(ctx context.Context, c client.Client, cfg *ReconcilerConfig, desiredNames map[string]struct{}) (int, error) {
	sel, err := labels.Parse(fmt.Sprintf("%s=%s", cfg.FRRLabelKey, cfg.FRRLabelValue))
	if err != nil {
		return 0, err
	}
	var list unstructured.UnstructuredList
	list.SetGroupVersionKind(frrListGVK)
	if err := c.List(ctx, &list, client.InNamespace(cfg.FRRNamespace), client.MatchingLabelsSelector{Selector: sel}); err != nil {
		return 0, err
	}
	deleted := 0
	for i := range list.Items {
		name := list.Items[i].GetName()
		if _, keep := desiredNames[name]; keep {
			continue
		}
		if err := c.Delete(ctx, &list.Items[i]); err != nil && !apierrors.IsNotFound(err) {
			continue
		}
		deleted++
	}
	return deleted, nil
}

// ReconcileFRRConfigurations ensures one FRRConfiguration per router node.
func ReconcileFRRConfigurations(ctx context.Context, c client.Client, cfg *ReconcilerConfig, routerNodes []gcp.RouterNode, nodeMap map[string]string, topology *gcp.CloudRouterTopology) (created, deleted int, err error) {
	desired := make(map[string]struct{})
	for _, n := range routerNodes {
		desired[frpkg.ConfigName(n.Name)] = struct{}{}
	}
	d, err := CleanupStaleFRR(ctx, c, cfg, desired)
	if err != nil {
		return 0, 0, err
	}
	deleted = d

	for _, node := range routerNodes {
		k8sName := nodeMap[node.Name]
		if k8sName == "" {
			continue
		}
		obj := frpkg.BuildFRRConfiguration(node, k8sName, topology, cfg.FRRASN, cfg.FRRNamespace, cfg.FRRLabelKey, cfg.FRRLabelValue)
		obj.SetGroupVersionKind(frrGVK())
		key := types.NamespacedName{Namespace: cfg.FRRNamespace, Name: obj.GetName()}
		var cur unstructured.Unstructured
		cur.SetGroupVersionKind(frrGVK())
		getErr := c.Get(ctx, key, &cur)
		if apierrors.IsNotFound(getErr) {
			if err := c.Create(ctx, obj); err != nil {
				continue
			}
			created++
			continue
		}
		if getErr != nil {
			continue
		}
		obj.SetResourceVersion(cur.GetResourceVersion())
		if err := c.Update(ctx, obj); err != nil {
			continue
		}
	}
	return created, deleted, nil
}

func frrGVK() schema.GroupVersionKind {
	return schema.GroupVersionKind{Group: frpkg.Group, Version: frpkg.Version, Kind: frpkg.Kind}
}
