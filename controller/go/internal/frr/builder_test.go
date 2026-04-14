package frr

import (
	"strings"
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestConfigName(t *testing.T) {
	require.Equal(t, "bgp-myvm", ConfigName("myVM"))
	require.Equal(t, "bgp-a-b", ConfigName("a_b"))
	long := strings.Repeat("x", 60)
	name := ConfigName(long)
	// "bgp-" (4) + sanitized instance segment (max 50) = 54, matching Python frr.frr_config_name.
	require.LessOrEqual(t, len(name), 54)
	require.True(t, strings.HasPrefix(name, "bgp-"))
}

func TestBuildFRRConfiguration(t *testing.T) {
	node := gcp.RouterNode{Name: "vm-1", SelfLink: "https://compute/v1/instances/vm-1", Zone: "z", IPAddress: "10.0.0.5"}
	top := &gcp.CloudRouterTopology{
		CloudRouterASN: 64512,
		InterfaceIPs:   []string{"10.0.1.2", "10.0.1.3"},
	}
	u := BuildFRRConfiguration(node, "node-a", top, 65003, "openshift-frr-k8s", "app", "osd")

	require.Equal(t, "frrk8s.metallb.io/v1beta1", u.GetAPIVersion())
	require.Equal(t, "FRRConfiguration", u.GetKind())
	require.Equal(t, "bgp-vm-1", u.GetName())
	require.Equal(t, "openshift-frr-k8s", u.GetNamespace())
	require.Equal(t, "osd", u.GetLabels()["app"])

	host, found, err := unstructured.NestedString(u.Object, "spec", "nodeSelector", "matchLabels", "kubernetes.io/hostname")
	require.NoError(t, err)
	require.True(t, found)
	require.Equal(t, "node-a", host)

	routers, found, err := unstructured.NestedSlice(u.Object, "spec", "bgp", "routers")
	require.NoError(t, err)
	require.True(t, found)
	require.Len(t, routers, 1)
	r0 := routers[0].(map[string]any)
	require.Equal(t, int64(65003), r0["asn"])
	neighbors := r0["neighbors"].([]any)
	require.Len(t, neighbors, 2)
	for _, nb := range neighbors {
		_, has := nb.(map[string]any)["disableMP"]
		require.False(t, has, "disableMP is deprecated in MetalLB/frr-k8s; omit it")
	}

	prio, found, err := unstructured.NestedInt64(u.Object, "spec", "raw", "priority")
	require.NoError(t, err)
	require.True(t, found)
	require.Equal(t, int64(20), prio)
	rc, found, err := unstructured.NestedString(u.Object, "spec", "raw", "rawConfig")
	require.NoError(t, err)
	require.True(t, found)
	require.Contains(t, rc, "router bgp 65003")
	require.Contains(t, rc, "neighbor 10.0.1.2 disable-connected-check")
	require.Contains(t, rc, "neighbor 10.0.1.3 disable-connected-check")
}
