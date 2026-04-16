package scheme

import (
	frpkg "github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/frr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
)

// New builds a runtime.Scheme with core types and FRRConfiguration as unstructured.
func New() *runtime.Scheme {
	s := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(s))
	utilruntime.Must(corev1.AddToScheme(s))
	utilruntime.Must(appsv1.AddToScheme(s))

	gv := schema.GroupVersion{Group: frpkg.Group, Version: frpkg.Version}
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: gv.Group, Version: gv.Version, Kind: frpkg.Kind},
		&unstructured.Unstructured{},
	)
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: gv.Group, Version: gv.Version, Kind: frpkg.Kind + "List"},
		&unstructured.UnstructuredList{},
	)
	return s
}
