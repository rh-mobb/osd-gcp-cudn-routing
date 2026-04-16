package reconciler

import (
	"context"
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/stretchr/testify/require"
)

func TestDiscoverCandidates(t *testing.T) {
	cfg := &config.ControllerConfig{
		NodeLabelKey:         "node-role.kubernetes.io/worker",
		NodeLabelValue:       "",
		RouterLabelKey:       "cudn.redhat.com/bgp-router",
		InfraExcludeLabelKey: "node-role.kubernetes.io/infra",
	}
	n1 := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: "ok-node",
			Labels: map[string]string{
				"node-role.kubernetes.io/worker": "",
				"topology.kubernetes.io/zone":    "us-central1-a",
			},
		},
		Spec: corev1.NodeSpec{ProviderID: "gce://myproj/us-central1-a/inst-1"},
		Status: corev1.NodeStatus{Addresses: []corev1.NodeAddress{
			{Type: corev1.NodeInternalIP, Address: "10.0.0.7"},
		}},
	}
	infra := n1.DeepCopy()
	infra.Name = "infra"
	infra.Labels["node-role.kubernetes.io/infra"] = ""
	badProv := n1.DeepCopy()
	badProv.Name = "bad"
	badProv.Spec.ProviderID = "aws://foo"
	noIP := n1.DeepCopy()
	noIP.Name = "noip"
	noIP.Status.Addresses = nil

	sch := runtime.NewScheme()
	_ = corev1.AddToScheme(sch)
	cl := fake.NewClientBuilder().WithScheme(sch).WithObjects(n1, infra, badProv, noIP).Build()

	cands, err := DiscoverCandidates(context.Background(), cl, cfg)
	require.NoError(t, err)
	require.Len(t, cands, 1)
	require.Equal(t, "ok-node", cands[0].K8sName)
	require.Equal(t, "inst-1", cands[0].RouterNode.Name)
	require.Contains(t, cands[0].RouterNode.SelfLink, "inst-1")
}

func TestSortCandidates(t *testing.T) {
	a := Candidate{K8sName: "n2", RouterNode: gcp.RouterNode{Name: "vm-b"}}
	b := Candidate{K8sName: "n1", RouterNode: gcp.RouterNode{Name: "vm-a"}}
	c := Candidate{K8sName: "n3", RouterNode: gcp.RouterNode{Name: "vm-a"}}
	out := SortCandidates([]Candidate{a, b, c})
	require.Equal(t, "vm-a", out[0].RouterNode.Name)
	require.Equal(t, "n1", out[0].K8sName)
	require.Equal(t, "vm-a", out[1].RouterNode.Name)
	require.Equal(t, "n3", out[1].K8sName)
}
