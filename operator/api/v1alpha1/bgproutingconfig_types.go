/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	// ConditionTypeReady indicates all subsystems reconciled successfully.
	ConditionTypeReady = "Ready"
	// ConditionTypeDegraded indicates partial failure during reconciliation.
	ConditionTypeDegraded = "Degraded"
	// ConditionTypeProgressing indicates reconciliation is in progress.
	ConditionTypeProgressing = "Progressing"
	// ConditionTypeSuspended indicates the operator is suspended and cleanup has completed.
	ConditionTypeSuspended = "Suspended"

	// FinalizerName is applied to BGPRoutingConfig to run cleanup on deletion.
	FinalizerName = "routing.osd.redhat.com/cleanup"

	// DefaultFRRASN is the default autonomous system number for FRR.
	DefaultFRRASN = 65003
	// DefaultFRRNamespace is the default namespace for FRR resources.
	DefaultFRRNamespace = "openshift-frr-k8s"
	// DefaultFRRLabelKey is the default label key applied to FRR CRs.
	DefaultFRRLabelKey = "routing.osd.redhat.com/bgp-stack"
	// DefaultFRRLabelValue is the default label value applied to FRR CRs.
	DefaultFRRLabelValue = "osd-gcp-bgp"

	// DefaultNodeLabelKey selects worker nodes as BGP router candidates.
	DefaultNodeLabelKey = "node-role.kubernetes.io/worker"
	// DefaultRouterLabelKey marks a node as an active BGP router.
	DefaultRouterLabelKey = "routing.osd.redhat.com/bgp-router"
	// DefaultInfraExcludeLabelKey excludes infra nodes from selection.
	DefaultInfraExcludeLabelKey = "node-role.kubernetes.io/infra"

	// DefaultReconcileIntervalSeconds is the default reconciliation interval.
	DefaultReconcileIntervalSeconds = 60
	// DefaultDebounceSeconds is the default debounce period for node events.
	DefaultDebounceSeconds = 5
	// DefaultMachineNamespace is the default namespace for OpenShift Machine objects.
	DefaultMachineNamespace = "openshift-machine-api"
)

// BGPRoutingConfigSpec defines the desired BGP routing configuration for the cluster.
type BGPRoutingConfigSpec struct {
	// Suspended triggers cleanup of all controller-managed resources and pauses
	// reconciliation while preserving the configuration for re-enablement.
	// +optional
	Suspended bool `json:"suspended,omitempty"`

	// GCPProject is the Google Cloud project ID containing the cluster.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	GCPProject string `json:"gcpProject"`

	// CloudRouter specifies the Cloud Router used for BGP peering.
	// +kubebuilder:validation:Required
	CloudRouter CloudRouterSpec `json:"cloudRouter"`

	// NCC specifies the Network Connectivity Center hub and spoke configuration.
	// +kubebuilder:validation:Required
	NCC NCCSpec `json:"ncc"`

	// ClusterName is the OpenShift cluster name (used for BGP peer naming).
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	ClusterName string `json:"clusterName"`

	// FRR configures FRR (Free Range Routing) integration.
	// +optional
	FRR FRRSpec `json:"frr,omitempty"`

	// GCE configures Google Compute Engine instance settings.
	// +optional
	GCE GCESpec `json:"gce,omitempty"`

	// NodeSelector controls which nodes are eligible as BGP routers.
	// +optional
	NodeSelector NodeSelectorSpec `json:"nodeSelector,omitempty"`

	// ReconcileIntervalSeconds is the interval between reconciliation passes.
	// +optional
	// +kubebuilder:default=60
	// +kubebuilder:validation:Minimum=5
	ReconcileIntervalSeconds int `json:"reconcileIntervalSeconds,omitempty"`

	// DebounceSeconds is the debounce period for batching node events.
	// +optional
	// +kubebuilder:default=5
	// +kubebuilder:validation:Minimum=1
	DebounceSeconds int `json:"debounceSeconds,omitempty"`

	// MachineNamespace is the namespace where OpenShift Machine objects are managed.
	// The operator registers a preTerminate lifecycle hook on each BGP router Machine
	// to ensure BGP peers are removed before GCE instance deletion.
	// +optional
	// +kubebuilder:default="openshift-machine-api"
	MachineNamespace string `json:"machineNamespace,omitempty"`
}

// CloudRouterSpec identifies the GCP Cloud Router for BGP peering.
type CloudRouterSpec struct {
	// Name is the Cloud Router resource name.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// Region is the GCP region of the Cloud Router.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Region string `json:"region"`
}

// NCCSpec configures the Network Connectivity Center spoke management.
type NCCSpec struct {
	// HubName is the NCC hub resource name.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	HubName string `json:"hubName"`

	// SpokePrefix is the naming prefix for controller-managed NCC spokes.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	SpokePrefix string `json:"spokePrefix"`

	// SiteToSite enables site-to-site data transfer on spokes.
	// +optional
	SiteToSite bool `json:"siteToSite,omitempty"`
}

// FRRSpec configures FRR integration parameters.
type FRRSpec struct {
	// ASN is the autonomous system number advertised by FRR on router nodes.
	// +optional
	// +kubebuilder:default=65003
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4294967295
	ASN int `json:"asn,omitempty"`

	// Namespace is the Kubernetes namespace where FRRConfiguration CRs are created.
	// +optional
	// +kubebuilder:default="openshift-frr-k8s"
	Namespace string `json:"namespace,omitempty"`

	// LabelKey is the label key applied to controller-managed FRRConfiguration CRs.
	// +optional
	// +kubebuilder:default="routing.osd.redhat.com/bgp-stack"
	LabelKey string `json:"labelKey,omitempty"`

	// LabelValue is the label value applied to controller-managed FRRConfiguration CRs.
	// +optional
	// +kubebuilder:default="osd-gcp-bgp"
	LabelValue string `json:"labelValue,omitempty"`
}

// GCESpec configures Google Compute Engine instance behavior.
type GCESpec struct {
	// EnableNestedVirtualization enables nested virtualization on router GCE instances.
	// Requires instances.update with RESTART; not supported on OSD-GCP.
	// +optional
	// +kubebuilder:default=true
	EnableNestedVirtualization *bool `json:"enableNestedVirtualization,omitempty"`
}

// NodeSelectorSpec controls which nodes are selected as BGP routers.
type NodeSelectorSpec struct {
	// LabelKey is the node label key used to discover candidate nodes.
	// +optional
	// +kubebuilder:default="node-role.kubernetes.io/worker"
	LabelKey string `json:"labelKey,omitempty"`

	// LabelValue is the required label value; empty means the key must exist with any value.
	// +optional
	LabelValue string `json:"labelValue,omitempty"`

	// RouterLabelKey is the label applied to nodes selected as active BGP routers.
	// +optional
	// +kubebuilder:default="routing.osd.redhat.com/bgp-router"
	RouterLabelKey string `json:"routerLabelKey,omitempty"`

	// InfraExcludeLabelKey excludes nodes with this label from router selection.
	// +optional
	// +kubebuilder:default="node-role.kubernetes.io/infra"
	InfraExcludeLabelKey string `json:"infraExcludeLabelKey,omitempty"`
}

// BGPRoutingConfigStatus defines the observed state of BGPRoutingConfig.
type BGPRoutingConfigStatus struct {
	// ObservedGeneration is the most recent generation observed by the controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions represent the latest available observations of the resource's state.
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// RouterCount is the number of active BGP router nodes.
	// +optional
	RouterCount int `json:"routerCount,omitempty"`

	// SpokeCount is the number of NCC spokes managed by the controller.
	// +optional
	SpokeCount int `json:"spokeCount,omitempty"`

	// CloudRouterASN is the observed ASN of the Cloud Router.
	// +optional
	CloudRouterASN int64 `json:"cloudRouterASN,omitempty"`

	// CloudRouterInterfaces lists the discovered Cloud Router interface IPs.
	// +optional
	CloudRouterInterfaces []string `json:"cloudRouterInterfaces,omitempty"`

	// LastReconcileTime is the timestamp of the last successful reconciliation.
	// +optional
	LastReconcileTime *metav1.Time `json:"lastReconcileTime,omitempty"`

	// LastReconcileResult summarizes the outcome of the last reconciliation pass.
	// +optional
	LastReconcileResult *ReconcileResultStatus `json:"lastReconcileResult,omitempty"`
}

// ReconcileResultStatus captures the outcome of a single reconciliation pass.
type ReconcileResultStatus struct {
	// NodesFound is the count of eligible BGP router nodes discovered.
	NodesFound int `json:"nodesFound"`
	// CanIPForwardChanged is the number of instances where canIpForward was toggled.
	CanIPForwardChanged int `json:"canIpForwardChanged"`
	// NestedVirtualizationChanged is the number of instances where nested virt was toggled.
	NestedVirtualizationChanged int `json:"nestedVirtualizationChanged"`
	// SpokesChanged is the number of NCC spoke mutations performed.
	SpokesChanged int `json:"spokesChanged"`
	// PeersChanged indicates whether Cloud Router BGP peers were modified.
	PeersChanged bool `json:"peersChanged"`
	// FRRCreated is the number of FRRConfiguration CRs created.
	FRRCreated int `json:"frrCreated"`
	// FRRDeleted is the number of FRRConfiguration CRs deleted.
	FRRDeleted int `json:"frrDeleted"`
	// RouterLabelsChanged is the number of node router label changes applied.
	RouterLabelsChanged int `json:"routerLabelsChanged"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:printcolumn:name="Suspended",type=boolean,JSONPath=`.spec.suspended`
// +kubebuilder:printcolumn:name="Routers",type=integer,JSONPath=`.status.routerCount`
// +kubebuilder:printcolumn:name="Spokes",type=integer,JSONPath=`.status.spokeCount`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// BGPRoutingConfig is the Schema for the bgproutingconfigs API.
// It defines the desired BGP routing configuration for an OSD-GCP cluster.
type BGPRoutingConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BGPRoutingConfigSpec   `json:"spec,omitempty"`
	Status BGPRoutingConfigStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BGPRoutingConfigList contains a list of BGPRoutingConfig.
type BGPRoutingConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BGPRoutingConfig `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BGPRoutingConfig{}, &BGPRoutingConfigList{})
}

// IsNestedVirtEnabled returns whether nested virtualization is enabled (defaults to true).
func (s *BGPRoutingConfigSpec) IsNestedVirtEnabled() bool {
	if s.GCE.EnableNestedVirtualization == nil {
		return true
	}
	return *s.GCE.EnableNestedVirtualization
}
