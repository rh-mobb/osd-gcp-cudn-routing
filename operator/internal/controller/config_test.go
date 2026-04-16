package controller

import (
	"testing"
	"time"

	api "github.com/rh-mobb/osd-gcp-cudn-routing/operator/api/v1alpha1"
	"github.com/stretchr/testify/require"
)

func TestSpecToReconcilerConfig_Defaults(t *testing.T) {
	spec := &api.BGPRoutingConfigSpec{
		GCPProject:  "my-project",
		CloudRouter: api.CloudRouterSpec{Name: "router", Region: "us-east1"},
		NCC:         api.NCCSpec{HubName: "hub", SpokePrefix: "spoke"},
		ClusterName: "cluster",
	}

	cfg := specToReconcilerConfig(spec)

	require.Equal(t, "my-project", cfg.GCPProject)
	require.Equal(t, "router", cfg.CloudRouterName)
	require.Equal(t, "us-east1", cfg.CloudRouterRegion)
	require.Equal(t, "hub", cfg.NCCHubName)
	require.Equal(t, "spoke", cfg.NCCSpokePrefix)
	require.Equal(t, "cluster", cfg.ClusterName)
	require.Equal(t, api.DefaultFRRASN, cfg.FRRASN)
	require.Equal(t, api.DefaultFRRNamespace, cfg.FRRNamespace)
	require.Equal(t, api.DefaultFRRLabelKey, cfg.FRRLabelKey)
	require.Equal(t, api.DefaultFRRLabelValue, cfg.FRRLabelValue)
	require.Equal(t, api.DefaultNodeLabelKey, cfg.NodeLabelKey)
	require.Equal(t, api.DefaultRouterLabelKey, cfg.RouterLabelKey)
	require.Equal(t, api.DefaultInfraExcludeLabelKey, cfg.InfraExcludeLabelKey)
	require.True(t, cfg.EnableGCENestedVirt)
	require.Equal(t, 60*time.Second, cfg.ReconcileInterval)
	require.Equal(t, 5*time.Second, cfg.Debounce)
	require.False(t, cfg.NCCSpokeSiteToSite)
}

func TestSpecToReconcilerConfig_CustomValues(t *testing.T) {
	nestedVirt := false
	spec := &api.BGPRoutingConfigSpec{
		GCPProject:  "proj",
		CloudRouter: api.CloudRouterSpec{Name: "r", Region: "eu-west1"},
		NCC:         api.NCCSpec{HubName: "h", SpokePrefix: "sp", SiteToSite: true},
		ClusterName: "c",
		FRR: api.FRRSpec{
			ASN:        65100,
			Namespace:  "custom-frr",
			LabelKey:   "my/label",
			LabelValue: "v",
		},
		GCE: api.GCESpec{
			EnableNestedVirtualization: &nestedVirt,
		},
		NodeSelector: api.NodeSelectorSpec{
			LabelKey:             "custom/key",
			LabelValue:           "val",
			RouterLabelKey:       "custom/router",
			InfraExcludeLabelKey: "custom/infra",
		},
		ReconcileIntervalSeconds: 120,
		DebounceSeconds:          10,
	}

	cfg := specToReconcilerConfig(spec)

	require.Equal(t, 65100, cfg.FRRASN)
	require.Equal(t, "custom-frr", cfg.FRRNamespace)
	require.Equal(t, "my/label", cfg.FRRLabelKey)
	require.Equal(t, "v", cfg.FRRLabelValue)
	require.Equal(t, "custom/key", cfg.NodeLabelKey)
	require.Equal(t, "val", cfg.NodeLabelValue)
	require.Equal(t, "custom/router", cfg.RouterLabelKey)
	require.Equal(t, "custom/infra", cfg.InfraExcludeLabelKey)
	require.False(t, cfg.EnableGCENestedVirt)
	require.True(t, cfg.NCCSpokeSiteToSite)
	require.Equal(t, 120*time.Second, cfg.ReconcileInterval)
	require.Equal(t, 10*time.Second, cfg.Debounce)
}

func TestIsNestedVirtEnabled(t *testing.T) {
	spec := &api.BGPRoutingConfigSpec{}
	require.True(t, spec.IsNestedVirtEnabled(), "default should be true")

	enabled := true
	spec.GCE.EnableNestedVirtualization = &enabled
	require.True(t, spec.IsNestedVirtEnabled())

	disabled := false
	spec.GCE.EnableNestedVirtualization = &disabled
	require.False(t, spec.IsNestedVirtEnabled())
}
