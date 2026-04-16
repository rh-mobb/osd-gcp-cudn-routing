package config

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestFromEnv_RequiredMissing(t *testing.T) {
	for _, k := range []string{
		"GCP_PROJECT", "CLOUD_ROUTER_NAME", "CLOUD_ROUTER_REGION",
		"NCC_HUB_NAME", "NCC_SPOKE_PREFIX", "CLUSTER_NAME",
	} {
		t.Setenv(k, "")
	}
	_, err := FromEnv()
	require.Error(t, err)
	require.Contains(t, err.Error(), "GCP_PROJECT")
}

func TestFromEnv_AllRequired(t *testing.T) {
	setRequired(t)
	t.Setenv("FRR_ASN", "65005")
	t.Setenv("NCC_SPOKE_SITE_TO_SITE", "true")
	t.Setenv("ENABLE_GCE_NESTED_VIRTUALIZATION", "true")
	t.Setenv("NODE_LABEL_KEY", "custom.io/worker")
	t.Setenv("NODE_LABEL_VALUE", "yes")
	t.Setenv("ROUTER_LABEL_KEY", "custom.io/bgp")
	t.Setenv("INFRA_EXCLUDE_LABEL_KEY", "custom.io/infra")
	t.Setenv("FRR_NAMESPACE", "frr-ns")
	t.Setenv("FRR_LABEL_KEY", "app")
	t.Setenv("FRR_LABEL_VALUE", "test")
	t.Setenv("RECONCILE_INTERVAL_SECONDS", "120")
	t.Setenv("DEBOUNCE_SECONDS", "10")
	t.Setenv("CONTROLLER_NAMESPACE", "ctrl-ns")
	t.Setenv("CONTROLLER_DEPLOYMENT_NAME", "dep")

	c, err := FromEnv()
	require.NoError(t, err)
	require.Equal(t, "p", c.GCPProject)
	require.Equal(t, "r", c.CloudRouterName)
	require.Equal(t, "us-central1", c.CloudRouterRegion)
	require.Equal(t, "hub", c.NCCHubName)
	require.Equal(t, "sp", c.NCCSpokePrefix)
	require.Equal(t, "cl", c.ClusterName)
	require.Equal(t, 65005, c.FRRASN)
	require.True(t, c.NCCSpokeSiteToSite)
	require.True(t, c.EnableGCENestedVirt)
	require.Equal(t, "custom.io/worker", c.NodeLabelKey)
	require.Equal(t, "yes", c.NodeLabelValue)
	require.Equal(t, "custom.io/worker=yes", c.NodeLabelSelector())
	require.Equal(t, "custom.io/bgp", c.RouterLabelKey)
	require.Equal(t, "custom.io/infra", c.InfraExcludeLabelKey)
	require.Equal(t, "frr-ns", c.FRRNamespace)
	require.Equal(t, "app", c.FRRLabelKey)
	require.Equal(t, "test", c.FRRLabelValue)
	require.Equal(t, 120*time.Second, c.ReconcileInterval)
	require.Equal(t, 10*time.Second, c.Debounce)
	require.Equal(t, "ctrl-ns", c.ControllerNamespace)
	require.Equal(t, "dep", c.ControllerDeployment)
}

func TestFromEnv_Defaults(t *testing.T) {
	setRequired(t)
	c, err := FromEnv()
	require.NoError(t, err)
	require.Equal(t, 65003, c.FRRASN)
	require.False(t, c.NCCSpokeSiteToSite)
	require.True(t, c.EnableGCENestedVirt)
	require.Equal(t, "node-role.kubernetes.io/worker", c.NodeLabelKey)
	require.Equal(t, "", c.NodeLabelValue)
	require.Equal(t, "node-role.kubernetes.io/worker", c.NodeLabelSelector())
	require.Equal(t, "cudn.redhat.com/bgp-router", c.RouterLabelKey)
	require.Equal(t, "openshift-frr-k8s", c.FRRNamespace)
	require.Equal(t, 60*time.Second, c.ReconcileInterval)
	require.Equal(t, 5*time.Second, c.Debounce)
}

func TestParseBoolVariants(t *testing.T) {
	require.False(t, parseBool("", false))
	require.True(t, parseBool("TRUE", false))
	require.True(t, parseBool("1", false))
	require.True(t, parseBool("yes", false))
	require.False(t, parseBool("false", true))
	require.False(t, parseBool("0", true))
}

func TestFromEnv_NestedVirtExplicitFalse(t *testing.T) {
	setRequired(t)
	t.Setenv("ENABLE_GCE_NESTED_VIRTUALIZATION", "false")
	c, err := FromEnv()
	require.NoError(t, err)
	require.False(t, c.EnableGCENestedVirt)
}

func TestFromEnv_InvalidFRRASN(t *testing.T) {
	setRequired(t)
	t.Setenv("FRR_ASN", "x")
	_, err := FromEnv()
	require.Error(t, err)
}

func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("GCP_PROJECT", "p")
	t.Setenv("CLOUD_ROUTER_NAME", "r")
	t.Setenv("CLOUD_ROUTER_REGION", "us-central1")
	t.Setenv("NCC_HUB_NAME", "hub")
	t.Setenv("NCC_SPOKE_PREFIX", "sp")
	t.Setenv("CLUSTER_NAME", "cl")
}
