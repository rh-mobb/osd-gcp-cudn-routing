package reconciler

import "time"

// NCCMaxInstancesPerSpoke is the GCP limit for router appliance instances per NCC spoke.
const NCCMaxInstancesPerSpoke = 8

// ReconcilerConfig holds the runtime configuration for the reconciler, derived from
// the BGPRoutingConfig CRD spec. This replaces the env-var-driven ControllerConfig
// used by controller/go.
type ReconcilerConfig struct {
	GCPProject           string
	CloudRouterName      string
	CloudRouterRegion    string
	NCCHubName           string
	NCCSpokePrefix       string
	ClusterName          string
	FRRASN               int
	NCCSpokeSiteToSite   bool
	EnableGCENestedVirt  bool
	NodeLabelKey         string
	NodeLabelValue       string
	RouterLabelKey       string
	InfraExcludeLabelKey string
	FRRNamespace         string
	FRRLabelKey          string
	FRRLabelValue        string
	ReconcileInterval    time.Duration
	Debounce             time.Duration
}

// NodeLabelSelector returns the Kubernetes label selector string for candidate nodes.
func (c *ReconcilerConfig) NodeLabelSelector() string {
	if c.NodeLabelValue != "" {
		return c.NodeLabelKey + "=" + c.NodeLabelValue
	}
	return c.NodeLabelKey
}
