package reconciler

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestReconcilerConfig_NodeLabelSelector(t *testing.T) {
	cfg := &ReconcilerConfig{NodeLabelKey: "node-role.kubernetes.io/worker"}
	require.Equal(t, "node-role.kubernetes.io/worker", cfg.NodeLabelSelector())

	cfg.NodeLabelValue = "true"
	require.Equal(t, "node-role.kubernetes.io/worker=true", cfg.NodeLabelSelector())
}

func TestSortCandidates(t *testing.T) {
	cands := []Candidate{
		{K8sName: "n-c", RouterNode: struct {
			Name      string
			SelfLink  string
			Zone      string
			IPAddress string
		}{Name: "c"}},
		{K8sName: "n-a", RouterNode: struct {
			Name      string
			SelfLink  string
			Zone      string
			IPAddress string
		}{Name: "a"}},
		{K8sName: "n-b", RouterNode: struct {
			Name      string
			SelfLink  string
			Zone      string
			IPAddress string
		}{Name: "b"}},
	}

	sorted := SortCandidates(cands)
	require.Len(t, sorted, 3)
	require.Equal(t, "a", sorted[0].RouterNode.Name)
	require.Equal(t, "b", sorted[1].RouterNode.Name)
	require.Equal(t, "c", sorted[2].RouterNode.Name)

	require.Equal(t, "c", cands[0].RouterNode.Name, "original unchanged")
}

func TestControllerGCPAnnotationKeys(t *testing.T) {
	keys := ControllerGCPAnnotationKeys()
	require.Contains(t, keys, AnnotationGCPCanIPForward)
	require.Contains(t, keys, AnnotationGCPNestedVirtualization)
	require.Equal(t, "routing.osd.redhat.com/gcp-can-ip-forward", AnnotationGCPCanIPForward)
	require.Equal(t, "routing.osd.redhat.com/gcp-nested-virtualization", AnnotationGCPNestedVirtualization)
}
