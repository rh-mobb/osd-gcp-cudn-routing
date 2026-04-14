package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/event"

	"github.com/stretchr/testify/require"
)

func TestNodePredicate_Update(t *testing.T) {
	var p nodePredicate
	old := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "n", Labels: map[string]string{"a": "1"}}}
	newN := old.DeepCopy()
	require.False(t, p.Update(event.UpdateEvent{ObjectOld: old, ObjectNew: newN}))

	newN.Labels["b"] = "2"
	require.True(t, p.Update(event.UpdateEvent{ObjectOld: old, ObjectNew: newN}))

	old2 := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "n"}, Spec: corev1.NodeSpec{ProviderID: "gce://p/z/i"}}
	new2 := old2.DeepCopy()
	new2.Spec.ProviderID = "gce://p/z/j"
	require.True(t, p.Update(event.UpdateEvent{ObjectOld: old2, ObjectNew: new2}))
}
