package reconciler

import (
	"context"
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	frpkg "github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/frr"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/scheme"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	apierrors "k8s.io/apimachinery/pkg/api/errors"

	"github.com/stretchr/testify/require"
)

func TestCleanupStaleFRR(t *testing.T) {
	cfg := &config.ControllerConfig{
		FRRNamespace:  "frr",
		FRRLabelKey:   "app",
		FRRLabelValue: "x",
	}
	sch := scheme.New()
	keep := frpkg.BuildFRRConfiguration(
		gcp.RouterNode{Name: "vm1"},
		"n1",
		&gcp.CloudRouterTopology{CloudRouterASN: 1, InterfaceIPs: []string{"10.0.0.1"}},
		65003, cfg.FRRNamespace, cfg.FRRLabelKey, cfg.FRRLabelValue,
	)
	keep.SetResourceVersion("1")
	stale := keep.DeepCopy()
	stale.SetName("bgp-stale")
	stale.SetResourceVersion("1")
	cl := fake.NewClientBuilder().WithScheme(sch).WithObjects(keep, stale).Build()

	n, err := CleanupStaleFRR(context.Background(), cl, cfg, map[string]struct{}{keep.GetName(): {}})
	require.NoError(t, err)
	require.Equal(t, 1, n)

	var u unstructured.Unstructured
	u.SetGroupVersionKind(frrGVK())
	err = cl.Get(context.Background(), types.NamespacedName{Namespace: cfg.FRRNamespace, Name: "bgp-stale"}, &u)
	require.True(t, apierrors.IsNotFound(err))

	err = cl.Get(context.Background(), types.NamespacedName{Namespace: cfg.FRRNamespace, Name: keep.GetName()}, &u)
	require.NoError(t, err)
}
