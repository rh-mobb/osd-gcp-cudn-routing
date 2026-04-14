package frr

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const (
	Group   = "frrk8s.metallb.io"
	Version = "v1beta1"
	Kind    = "FRRConfiguration"
	Plural  = "frrconfigurations"
)

// ConfigName returns the FRRConfiguration metadata name for an instance.
func ConfigName(instanceName string) string {
	safe := strings.ToLower(instanceName)
	var b strings.Builder
	for _, r := range safe {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	s := b.String()
	if len(s) > 50 {
		s = s[:50]
	}
	return "bgp-" + s
}

// BuildFRRConfiguration returns an unstructured FRRConfiguration matching Python build_frr_configuration.
func BuildFRRConfiguration(
	node gcp.RouterNode,
	k8sNodeName string,
	topology *gcp.CloudRouterTopology,
	frrASN int,
	frrNamespace, labelKey, labelValue string,
) *unstructured.Unstructured {
	name := ConfigName(node.Name)

	var neighbors []any
	var rawLines []string
	rawLines = append(rawLines, fmt.Sprintf("      router bgp %d", frrASN))
	for _, crIP := range topology.InterfaceIPs {
		// Omit disableMP: MetalLB/frr-k8s deprecated it; default neighbor behavior matches former disableMP=true.
		neighbors = append(neighbors, map[string]any{
			"address": crIP,
			"asn":     topology.CloudRouterASN,
			"toReceive": map[string]any{
				"allowed": map[string]any{"mode": "all"},
			},
		})
		rawLines = append(rawLines, fmt.Sprintf("       neighbor %s disable-connected-check", crIP))
	}
	rawConfig := strings.Join(rawLines, "\n") + "\n"

	obj := &unstructured.Unstructured{}
	obj.SetAPIVersion(Group + "/" + Version)
	obj.SetKind(Kind)
	obj.SetName(name)
	obj.SetNamespace(frrNamespace)
	obj.SetLabels(map[string]string{labelKey: labelValue})

	_ = unstructured.SetNestedMap(obj.Object, map[string]any{
		"matchLabels": map[string]any{"kubernetes.io/hostname": k8sNodeName},
	}, "spec", "nodeSelector")

	_ = unstructured.SetNestedSlice(obj.Object, []any{
		map[string]any{
			"asn":       int64(frrASN),
			"neighbors": neighbors,
		},
	}, "spec", "bgp", "routers")

	_ = unstructured.SetNestedMap(obj.Object, map[string]any{
		"priority":  int64(20),
		"rawConfig": rawConfig,
	}, "spec", "raw")

	return obj
}
