package controller

import (
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/event"
)

func TestNodeEventFilter_Update(t *testing.T) {
	pred := nodeEventFilter{}

	oldNode := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "n1", Labels: map[string]string{"a": "1"}},
		Spec:       corev1.NodeSpec{ProviderID: "gce://p/z/vm1"},
	}

	t.Run("label change triggers reconcile", func(t *testing.T) {
		newNode := oldNode.DeepCopy()
		newNode.Labels["b"] = "2"
		require.True(t, pred.Update(event.UpdateEvent{ObjectOld: oldNode, ObjectNew: newNode}))
	})

	t.Run("providerID change triggers reconcile", func(t *testing.T) {
		newNode := oldNode.DeepCopy()
		newNode.Spec.ProviderID = "gce://p/z/vm2"
		require.True(t, pred.Update(event.UpdateEvent{ObjectOld: oldNode, ObjectNew: newNode}))
	})

	t.Run("address change triggers reconcile", func(t *testing.T) {
		newNode := oldNode.DeepCopy()
		newNode.Status.Addresses = []corev1.NodeAddress{{Type: corev1.NodeInternalIP, Address: "10.0.0.1"}}
		require.True(t, pred.Update(event.UpdateEvent{ObjectOld: oldNode, ObjectNew: newNode}))
	})

	t.Run("no relevant change skips reconcile", func(t *testing.T) {
		newNode := oldNode.DeepCopy()
		newNode.Status.Phase = corev1.NodeRunning
		require.False(t, pred.Update(event.UpdateEvent{ObjectOld: oldNode, ObjectNew: newNode}))
	})
}
