package reconciler

import (
	"context"
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/scheme"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/stretchr/testify/require"
)

type mockCompute struct {
	topology *gcp.CloudRouterTopology
}

func (m *mockCompute) EnsureCanIPForward(ctx context.Context, node gcp.RouterNode) (bool, error) {
	return false, nil
}

func (m *mockCompute) EnsureNestedVirtualization(ctx context.Context, node gcp.RouterNode) (bool, error) {
	return false, nil
}

func (m *mockCompute) GetRouterTopology(ctx context.Context, routerName string) (*gcp.CloudRouterTopology, error) {
	return m.topology, nil
}

func (m *mockCompute) ReconcilePeers(ctx context.Context, routerName, clusterName string, nodes []gcp.RouterNode, topology *gcp.CloudRouterTopology, frrASN int) (bool, error) {
	return false, nil
}

func (m *mockCompute) ClearPeers(ctx context.Context, routerName string) (bool, error) {
	return false, nil
}

type mockNCC struct {
	spokeCalls int
}

func (m *mockNCC) ReconcileSpoke(ctx context.Context, spokeName, hubName string, nodes []gcp.RouterNode, siteToSite bool) (bool, error) {
	m.spokeCalls++
	return false, nil
}

func (m *mockNCC) DeleteSpoke(ctx context.Context, spokeName string) (bool, error) {
	return false, nil
}

func (m *mockNCC) ListSpokesByPrefix(ctx context.Context, hubName, prefix string) ([]string, error) {
	return nil, nil
}

func testNode(name, instance string) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: map[string]string{
			"node-role.kubernetes.io/worker": "",
		}},
		Spec: corev1.NodeSpec{ProviderID: "gce://p/us-central1-a/" + instance},
		Status: corev1.NodeStatus{Addresses: []corev1.NodeAddress{
			{Type: corev1.NodeInternalIP, Address: "10.0.0.2"},
		}},
	}
}

func TestReconciler_Reconcile_HappyPath(t *testing.T) {
	cfg := &config.ControllerConfig{
		GCPProject:           "p",
		CloudRouterName:      "r",
		CloudRouterRegion:    "us-central1",
		NCCHubName:           "h",
		NCCSpokePrefix:       "sp",
		ClusterName:          "c",
		FRRASN:               65003,
		NodeLabelKey:         "node-role.kubernetes.io/worker",
		RouterLabelKey:       "cudn.redhat.com/bgp-router",
		InfraExcludeLabelKey: "node-role.kubernetes.io/infra",
		FRRNamespace:         "frr",
		FRRLabelKey:          "app",
		FRRLabelValue:        "test",
	}
	top := &gcp.CloudRouterTopology{
		CloudRouterASN: 64512,
		InterfaceNames: []string{"if-redundant"},
		InterfaceIPs:   []string{"10.0.1.1"},
	}
	mc := &mockCompute{topology: top}
	mn := &mockNCC{}

	sch := scheme.New()
	cl := fake.NewClientBuilder().WithScheme(sch).WithObjects(testNode("n1", "vm1")).Build()

	r := &Reconciler{Cfg: cfg, Client: cl, Compute: mc, NCC: mn}
	res, err := r.Reconcile(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, res.NodesFound)
	require.Equal(t, 1, mn.spokeCalls)

	var n corev1.Node
	require.NoError(t, cl.Get(context.Background(), types.NamespacedName{Name: "n1"}, &n))
	_, has := n.Labels[cfg.RouterLabelKey]
	require.True(t, has, "router label should be set")
	require.Equal(t, "true", n.Annotations[AnnotationGCPCanIPForward])
}
