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
	// BGPRouter condition types for per-node status.
	ConditionTypeCanIPForwardReady  = "CanIPForwardReady"
	ConditionTypeNestedVirtReady    = "NestedVirtReady"
	ConditionTypeNCCSpokeJoined     = "NCCSpokeJoined"
	ConditionTypeBGPPeersConfigured = "BGPPeersConfigured"
	ConditionTypeFRRConfigured      = "FRRConfigured"
)

// BGPRouterSpec identifies the GCE instance backing this BGP router.
// This is controller-populated; users should not create BGPRouter resources.
type BGPRouterSpec struct {
	// NodeName is the Kubernetes node name.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	NodeName string `json:"nodeName"`

	// GCEInstance is the GCE instance name.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	GCEInstance string `json:"gceInstance"`

	// GCEZone is the GCE zone of the instance.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	GCEZone string `json:"gceZone"`
}

// BGPRouterStatus defines the observed state of a single BGP router node.
type BGPRouterStatus struct {
	// Conditions represent the latest available observations of this router's state.
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// GCEInstanceLink is the fully-qualified GCE instance self-link.
	// +optional
	GCEInstanceLink string `json:"gceInstanceLink,omitempty"`

	// IPAddress is the node's internal IP address.
	// +optional
	IPAddress string `json:"ipAddress,omitempty"`

	// CanIPForward indicates whether IP forwarding is enabled on the GCE instance.
	// +optional
	CanIPForward bool `json:"canIpForward,omitempty"`

	// NestedVirtualization indicates whether nested virtualization is enabled.
	// nil means the feature is not managed.
	// +optional
	NestedVirtualization *bool `json:"nestedVirtualization,omitempty"`

	// NCCSpokeName is the NCC spoke this router belongs to.
	// +optional
	NCCSpokeName string `json:"nccSpokeName,omitempty"`

	// BGPPeers lists the Cloud Router BGP peer names associated with this router.
	// +optional
	BGPPeers []string `json:"bgpPeers,omitempty"`

	// FRRConfigurationName is the name of the FRRConfiguration CR created for this router.
	// +optional
	FRRConfigurationName string `json:"frrConfigurationName,omitempty"`

	// LastUpdated is the time when this status was last written.
	// +optional
	LastUpdated *metav1.Time `json:"lastUpdated,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:printcolumn:name="Node",type=string,JSONPath=`.spec.nodeName`
// +kubebuilder:printcolumn:name="Instance",type=string,JSONPath=`.spec.gceInstance`
// +kubebuilder:printcolumn:name="Zone",type=string,JSONPath=`.spec.gceZone`
// +kubebuilder:printcolumn:name="IP",type=string,JSONPath=`.status.ipAddress`
// +kubebuilder:printcolumn:name="Spoke",type=string,JSONPath=`.status.nccSpokeName`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// BGPRouter is the Schema for the bgprouters API.
// Each BGPRouter represents a single Kubernetes node elected as a BGP router.
// These resources are controller-managed via ownerReferences to BGPRoutingConfig.
type BGPRouter struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BGPRouterSpec   `json:"spec,omitempty"`
	Status BGPRouterStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BGPRouterList contains a list of BGPRouter.
type BGPRouterList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BGPRouter `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BGPRouter{}, &BGPRouterList{})
}
