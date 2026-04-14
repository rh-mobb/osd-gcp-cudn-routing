// Package config loads controller settings from environment variables.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// NCCMaxInstancesPerSpoke is the GCP limit for router appliance instances per NCC spoke.
const NCCMaxInstancesPerSpoke = 8

// ControllerConfig holds runtime configuration (parity with Python ControllerConfig).
type ControllerConfig struct {
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
	ControllerNamespace  string
	ControllerDeployment string
}

// NodeLabelSelector returns the Kubernetes label selector for candidate nodes.
func (c *ControllerConfig) NodeLabelSelector() string {
	if c.NodeLabelValue != "" {
		return c.NodeLabelKey + "=" + c.NodeLabelValue
	}
	return c.NodeLabelKey
}

// FromEnv builds configuration from the process environment.
func FromEnv() (*ControllerConfig, error) {
	req := func(key string) (string, error) {
		v := strings.TrimSpace(os.Getenv(key))
		if v == "" {
			return "", fmt.Errorf("required environment variable %s is not set", key)
		}
		return v, nil
	}

	gcpProject, err := req("GCP_PROJECT")
	if err != nil {
		return nil, err
	}
	cloudRouter, err := req("CLOUD_ROUTER_NAME")
	if err != nil {
		return nil, err
	}
	region, err := req("CLOUD_ROUTER_REGION")
	if err != nil {
		return nil, err
	}
	hub, err := req("NCC_HUB_NAME")
	if err != nil {
		return nil, err
	}
	spokePrefix, err := req("NCC_SPOKE_PREFIX")
	if err != nil {
		return nil, err
	}
	cluster, err := req("CLUSTER_NAME")
	if err != nil {
		return nil, err
	}

	frrASN := 65003
	if s := os.Getenv("FRR_ASN"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil {
			return nil, fmt.Errorf("FRR_ASN: %w", err)
		}
		frrASN = n
	}

	siteToSite := parseBool(os.Getenv("NCC_SPOKE_SITE_TO_SITE"), false)
	nestedVirt := parseBool(os.Getenv("ENABLE_GCE_NESTED_VIRTUALIZATION"), true)

	nodeKey := getenvDefault("NODE_LABEL_KEY", "node-role.kubernetes.io/worker")
	nodeVal := strings.TrimSpace(os.Getenv("NODE_LABEL_VALUE"))
	routerKey := getenvDefault("ROUTER_LABEL_KEY", "cudn.redhat.com/bgp-router")
	infraKey := getenvDefault("INFRA_EXCLUDE_LABEL_KEY", "node-role.kubernetes.io/infra")
	frrNS := getenvDefault("FRR_NAMESPACE", "openshift-frr-k8s")
	frrLKey := getenvDefault("FRR_LABEL_KEY", "cudn.redhat.com/bgp-stack")
	frrLVal := getenvDefault("FRR_LABEL_VALUE", "osd-gcp-bgp")

	reconcileSec := 60.0
	if s := os.Getenv("RECONCILE_INTERVAL_SECONDS"); s != "" {
		reconcileSec, err = strconv.ParseFloat(s, 64)
		if err != nil {
			return nil, fmt.Errorf("RECONCILE_INTERVAL_SECONDS: %w", err)
		}
	}
	debounceSec := 5.0
	if s := os.Getenv("DEBOUNCE_SECONDS"); s != "" {
		debounceSec, err = strconv.ParseFloat(s, 64)
		if err != nil {
			return nil, fmt.Errorf("DEBOUNCE_SECONDS: %w", err)
		}
	}

	ctrlNS := getenvDefault("CONTROLLER_NAMESPACE", "bgp-routing-system")
	ctrlDep := getenvDefault("CONTROLLER_DEPLOYMENT_NAME", "bgp-routing-controller")

	return &ControllerConfig{
		GCPProject:           gcpProject,
		CloudRouterName:      cloudRouter,
		CloudRouterRegion:    region,
		NCCHubName:           hub,
		NCCSpokePrefix:       spokePrefix,
		ClusterName:          cluster,
		FRRASN:               frrASN,
		NCCSpokeSiteToSite:   siteToSite,
		EnableGCENestedVirt:  nestedVirt,
		NodeLabelKey:         nodeKey,
		NodeLabelValue:       nodeVal,
		RouterLabelKey:       routerKey,
		InfraExcludeLabelKey: infraKey,
		FRRNamespace:         frrNS,
		FRRLabelKey:          frrLKey,
		FRRLabelValue:        frrLVal,
		ReconcileInterval:    time.Duration(reconcileSec * float64(time.Second)),
		Debounce:             time.Duration(debounceSec * float64(time.Second)),
		ControllerNamespace:  ctrlNS,
		ControllerDeployment: ctrlDep,
	}, nil
}

func getenvDefault(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func parseBool(s string, def bool) bool {
	s = strings.ToLower(strings.TrimSpace(s))
	if s == "" {
		return def
	}
	switch s {
	case "true", "1", "yes":
		return true
	case "false", "0", "no":
		return false
	default:
		return def
	}
}
