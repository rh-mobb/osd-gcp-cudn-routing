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

package controller

import (
	"context"
	"fmt"
	"reflect"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	api "github.com/rh-mobb/osd-gcp-cudn-routing/operator/api/v1alpha1"
	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/reconciler"
)

const singletonName = "cluster"

// BGPRoutingConfigReconciler reconciles a BGPRoutingConfig object.
type BGPRoutingConfigReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder

	// GCP client factories (injected for testability).
	NewComputeClient func(ctx context.Context, project, region string) (gcp.ComputeClient, error)
	NewNCCClient     func(ctx context.Context, project, region string) (gcp.NCCClient, error)
}

// +kubebuilder:rbac:groups=routing.osd.redhat.com,resources=bgproutingconfigs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=routing.osd.redhat.com,resources=bgproutingconfigs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=routing.osd.redhat.com,resources=bgproutingconfigs/finalizers,verbs=update
// +kubebuilder:rbac:groups=routing.osd.redhat.com,resources=bgprouters,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=routing.osd.redhat.com,resources=bgprouters/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch;update
// +kubebuilder:rbac:groups=frrk8s.metallb.io,resources=frrconfigurations,verbs=get;list;watch;create;update;patch;delete

func (r *BGPRoutingConfigReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var config api.BGPRoutingConfig
	if err := r.Get(ctx, req.NamespacedName, &config); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Handle deletion via finalizer.
	if !config.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, &config)
	}

	// Ensure finalizer is present.
	if !controllerutil.ContainsFinalizer(&config, api.FinalizerName) {
		controllerutil.AddFinalizer(&config, api.FinalizerName)
		if err := r.Update(ctx, &config); err != nil {
			return ctrl.Result{}, err
		}
	}

	cfg := specToReconcilerConfig(&config.Spec)

	// Handle suspended state.
	if config.Spec.Suspended {
		return r.handleSuspended(ctx, &config, cfg)
	}

	// Clear Suspended condition if it was previously set.
	if meta.IsStatusConditionTrue(config.Status.Conditions, api.ConditionTypeSuspended) {
		meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
			Type:               api.ConditionTypeSuspended,
			Status:             metav1.ConditionFalse,
			Reason:             "Resumed",
			Message:            "Reconciliation resumed",
			ObservedGeneration: config.Generation,
		})
	}

	// Set Progressing condition.
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeProgressing,
		Status:             metav1.ConditionTrue,
		Reason:             "Reconciling",
		Message:            "Reconciliation in progress",
		ObservedGeneration: config.Generation,
	})
	config.Status.ObservedGeneration = config.Generation
	if err := r.Status().Update(ctx, &config); err != nil {
		return ctrl.Result{}, err
	}

	// Build GCP clients.
	computeClient, err := r.NewComputeClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		return r.setDegraded(ctx, &config, "GCPComputeClientFailed", err)
	}
	nccClient, err := r.NewNCCClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		return r.setDegraded(ctx, &config, "GCPNCCClientFailed", err)
	}

	rec := &reconciler.Reconciler{
		Cfg:     cfg,
		Client:  r.Client,
		Compute: computeClient,
		NCC:     nccClient,
	}

	res, err := rec.Reconcile(ctx)
	if err != nil {
		return r.setDegraded(ctx, &config, "ReconcileFailed", err)
	}

	log.Info("BGP routing reconcile completed",
		"routerNodes", res.NodesFound,
		"anyChange", res.AnyChange(),
	)

	// Update BGPRouter status objects.
	if err := r.syncBGPRouters(ctx, &config, res); err != nil {
		log.Error(err, "failed to sync BGPRouter status objects")
	}

	// Update BGPRoutingConfig status.
	now := metav1.Now()
	config.Status.ObservedGeneration = config.Generation
	config.Status.RouterCount = res.NodesFound
	config.Status.LastReconcileTime = &now
	config.Status.LastReconcileResult = &api.ReconcileResultStatus{
		NodesFound:                  res.NodesFound,
		CanIPForwardChanged:         res.CanIPForwardChanged,
		NestedVirtualizationChanged: res.NestedVirtualizationChanged,
		SpokesChanged:               res.SpokesChanged,
		PeersChanged:                res.PeersChanged,
		FRRCreated:                  res.FRRCreated,
		FRRDeleted:                  res.FRRDeleted,
		RouterLabelsChanged:         res.RouterLabelsChanged,
	}
	if res.Topology != nil {
		config.Status.CloudRouterASN = res.Topology.CloudRouterASN
		config.Status.CloudRouterInterfaces = res.Topology.InterfaceIPs
	}

	// Compute spoke count from the per-node results.
	spokeSet := make(map[string]struct{})
	for _, nr := range res.PerNode {
		if nr.NCCSpokeName != "" {
			spokeSet[nr.NCCSpokeName] = struct{}{}
		}
	}
	config.Status.SpokeCount = len(spokeSet)

	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeReady,
		Status:             metav1.ConditionTrue,
		Reason:             "ReconcileSucceeded",
		Message:            fmt.Sprintf("Reconciled %d router nodes", res.NodesFound),
		ObservedGeneration: config.Generation,
	})
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeProgressing,
		Status:             metav1.ConditionFalse,
		Reason:             "ReconcileComplete",
		Message:            "Reconciliation finished",
		ObservedGeneration: config.Generation,
	})
	meta.RemoveStatusCondition(&config.Status.Conditions, api.ConditionTypeDegraded)

	if err := r.Status().Update(ctx, &config); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: cfg.ReconcileInterval}, nil
}

func (r *BGPRoutingConfigReconciler) handleDeletion(ctx context.Context, config *api.BGPRoutingConfig) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	if !controllerutil.ContainsFinalizer(config, api.FinalizerName) {
		return ctrl.Result{}, nil
	}

	log.Info("BGPRoutingConfig being deleted, running cleanup")
	cfg := specToReconcilerConfig(&config.Spec)

	computeClient, err := r.NewComputeClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		log.Error(err, "failed to create compute client for cleanup")
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}
	nccClient, err := r.NewNCCClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		log.Error(err, "failed to create NCC client for cleanup")
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}

	rec := &reconciler.Reconciler{
		Cfg:     cfg,
		Client:  r.Client,
		Compute: computeClient,
		NCC:     nccClient,
	}
	if err := rec.Cleanup(ctx); err != nil {
		log.Error(err, "cleanup failed, will retry")
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}

	log.Info("cleanup completed, removing finalizer")
	controllerutil.RemoveFinalizer(config, api.FinalizerName)
	if err := r.Update(ctx, config); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *BGPRoutingConfigReconciler) handleSuspended(ctx context.Context, config *api.BGPRoutingConfig, cfg *reconciler.ReconcilerConfig) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	if meta.IsStatusConditionTrue(config.Status.Conditions, api.ConditionTypeSuspended) {
		return ctrl.Result{}, nil
	}

	log.Info("BGPRoutingConfig suspended, running cleanup")

	computeClient, err := r.NewComputeClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		return r.setDegraded(ctx, config, "GCPComputeClientFailed", err)
	}
	nccClient, err := r.NewNCCClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		return r.setDegraded(ctx, config, "GCPNCCClientFailed", err)
	}

	rec := &reconciler.Reconciler{
		Cfg:     cfg,
		Client:  r.Client,
		Compute: computeClient,
		NCC:     nccClient,
	}
	if err := rec.Cleanup(ctx); err != nil {
		return r.setDegraded(ctx, config, "SuspendCleanupFailed", err)
	}

	// Delete all owned BGPRouters.
	if err := r.deleteAllBGPRouters(ctx, config); err != nil {
		log.Error(err, "failed to delete BGPRouter objects during suspend")
	}

	config.Status.ObservedGeneration = config.Generation
	config.Status.RouterCount = 0
	config.Status.SpokeCount = 0

	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeSuspended,
		Status:             metav1.ConditionTrue,
		Reason:             "Suspended",
		Message:            "BGP routing is suspended; cleanup completed",
		ObservedGeneration: config.Generation,
	})
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeReady,
		Status:             metav1.ConditionFalse,
		Reason:             "Suspended",
		Message:            "BGP routing is suspended",
		ObservedGeneration: config.Generation,
	})
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeProgressing,
		Status:             metav1.ConditionFalse,
		Reason:             "Suspended",
		Message:            "Reconciliation paused",
		ObservedGeneration: config.Generation,
	})
	meta.RemoveStatusCondition(&config.Status.Conditions, api.ConditionTypeDegraded)

	if err := r.Status().Update(ctx, config); err != nil {
		return ctrl.Result{}, err
	}

	r.Recorder.Event(config, corev1.EventTypeNormal, "Suspended", "BGP routing suspended and cleanup completed")
	log.Info("BGP routing suspended")
	return ctrl.Result{}, nil
}

func (r *BGPRoutingConfigReconciler) setDegraded(ctx context.Context, config *api.BGPRoutingConfig, reason string, err error) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	log.Error(err, "reconciliation degraded", "reason", reason)

	config.Status.ObservedGeneration = config.Generation
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeDegraded,
		Status:             metav1.ConditionTrue,
		Reason:             reason,
		Message:            err.Error(),
		ObservedGeneration: config.Generation,
	})
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeReady,
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            err.Error(),
		ObservedGeneration: config.Generation,
	})
	meta.SetStatusCondition(&config.Status.Conditions, metav1.Condition{
		Type:               api.ConditionTypeProgressing,
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            "Reconciliation failed",
		ObservedGeneration: config.Generation,
	})

	if statusErr := r.Status().Update(ctx, config); statusErr != nil {
		log.Error(statusErr, "failed to update degraded status")
	}

	cfg := specToReconcilerConfig(&config.Spec)
	return ctrl.Result{RequeueAfter: cfg.ReconcileInterval}, err
}

// syncBGPRouters creates/updates/deletes BGPRouter objects for the current set of router nodes.
func (r *BGPRoutingConfigReconciler) syncBGPRouters(ctx context.Context, config *api.BGPRoutingConfig, res reconciler.ReconcileResult) error {
	log := logf.FromContext(ctx)
	now := metav1.Now()

	desiredNames := make(map[string]struct{})
	for _, nr := range res.PerNode {
		name := bgpRouterName(nr.K8sName)
		desiredNames[name] = struct{}{}

		var router api.BGPRouter
		err := r.Get(ctx, types.NamespacedName{Name: name}, &router)
		if apierrors.IsNotFound(err) {
			router = api.BGPRouter{
				ObjectMeta: metav1.ObjectMeta{
					Name: name,
					OwnerReferences: []metav1.OwnerReference{
						*metav1.NewControllerRef(config, api.GroupVersion.WithKind("BGPRoutingConfig")),
					},
				},
				Spec: api.BGPRouterSpec{
					NodeName:    nr.K8sName,
					GCEInstance: nr.RouterNode.Name,
					GCEZone:     nr.RouterNode.Zone,
				},
			}
			if err := r.Create(ctx, &router); err != nil {
				log.Error(err, "failed to create BGPRouter", "name", name)
				continue
			}
		} else if err != nil {
			log.Error(err, "failed to get BGPRouter", "name", name)
			continue
		}

		// Update spec if changed.
		specChanged := router.Spec.NodeName != nr.K8sName ||
			router.Spec.GCEInstance != nr.RouterNode.Name ||
			router.Spec.GCEZone != nr.RouterNode.Zone
		if specChanged {
			router.Spec.NodeName = nr.K8sName
			router.Spec.GCEInstance = nr.RouterNode.Name
			router.Spec.GCEZone = nr.RouterNode.Zone
			if err := r.Update(ctx, &router); err != nil {
				log.Error(err, "failed to update BGPRouter spec", "name", name)
				continue
			}
		}

		// Update status.
		nestedVirt := config.Spec.IsNestedVirtEnabled()
		router.Status.GCEInstanceLink = nr.RouterNode.SelfLink
		router.Status.IPAddress = nr.RouterNode.IPAddress
		router.Status.CanIPForward = true
		router.Status.NestedVirtualization = &nestedVirt
		router.Status.NCCSpokeName = nr.NCCSpokeName
		router.Status.BGPPeers = nr.BGPPeerNames
		router.Status.FRRConfigurationName = nr.FRRCRName
		router.Status.LastUpdated = &now

		setBGPRouterConditions(&router, config.Spec.IsNestedVirtEnabled())

		if err := r.Status().Update(ctx, &router); err != nil {
			log.Error(err, "failed to update BGPRouter status", "name", name)
		}
	}

	// Delete stale BGPRouters.
	var routerList api.BGPRouterList
	if err := r.List(ctx, &routerList); err != nil {
		return fmt.Errorf("list BGPRouters: %w", err)
	}
	for i := range routerList.Items {
		router := &routerList.Items[i]
		if !isOwnedBy(router, config) {
			continue
		}
		if _, keep := desiredNames[router.Name]; keep {
			continue
		}
		if err := r.Delete(ctx, router); err != nil && !apierrors.IsNotFound(err) {
			log.Error(err, "failed to delete stale BGPRouter", "name", router.Name)
		}
	}

	return nil
}

func (r *BGPRoutingConfigReconciler) deleteAllBGPRouters(ctx context.Context, config *api.BGPRoutingConfig) error {
	var routerList api.BGPRouterList
	if err := r.List(ctx, &routerList); err != nil {
		return err
	}
	for i := range routerList.Items {
		router := &routerList.Items[i]
		if !isOwnedBy(router, config) {
			continue
		}
		if err := r.Delete(ctx, router); err != nil && !apierrors.IsNotFound(err) {
			return err
		}
	}
	return nil
}

func isOwnedBy(router *api.BGPRouter, config *api.BGPRoutingConfig) bool {
	for _, ref := range router.OwnerReferences {
		if ref.UID == config.UID {
			return true
		}
	}
	return false
}

func bgpRouterName(k8sNodeName string) string {
	return "bgprouter-" + k8sNodeName
}

func setBGPRouterConditions(router *api.BGPRouter, nestedVirtEnabled bool) {
	meta.SetStatusCondition(&router.Status.Conditions, metav1.Condition{
		Type:    api.ConditionTypeCanIPForwardReady,
		Status:  metav1.ConditionTrue,
		Reason:  "Configured",
		Message: "canIpForward is enabled on GCE instance",
	})
	if nestedVirtEnabled {
		meta.SetStatusCondition(&router.Status.Conditions, metav1.Condition{
			Type:    api.ConditionTypeNestedVirtReady,
			Status:  metav1.ConditionTrue,
			Reason:  "Configured",
			Message: "Nested virtualization is enabled on GCE instance",
		})
	}
	if router.Status.NCCSpokeName != "" {
		meta.SetStatusCondition(&router.Status.Conditions, metav1.Condition{
			Type:    api.ConditionTypeNCCSpokeJoined,
			Status:  metav1.ConditionTrue,
			Reason:  "Joined",
			Message: fmt.Sprintf("Member of spoke %s", router.Status.NCCSpokeName),
		})
	}
	if len(router.Status.BGPPeers) > 0 {
		meta.SetStatusCondition(&router.Status.Conditions, metav1.Condition{
			Type:    api.ConditionTypeBGPPeersConfigured,
			Status:  metav1.ConditionTrue,
			Reason:  "Configured",
			Message: fmt.Sprintf("%d BGP peers configured", len(router.Status.BGPPeers)),
		})
	}
	if router.Status.FRRConfigurationName != "" {
		meta.SetStatusCondition(&router.Status.Conditions, metav1.Condition{
			Type:    api.ConditionTypeFRRConfigured,
			Status:  metav1.ConditionTrue,
			Reason:  "Configured",
			Message: fmt.Sprintf("FRRConfiguration %s created", router.Status.FRRConfigurationName),
		})
	}
}

// specToReconcilerConfig converts a BGPRoutingConfigSpec to the reconciler's config struct.
func specToReconcilerConfig(spec *api.BGPRoutingConfigSpec) *reconciler.ReconcilerConfig {
	frrASN := spec.FRR.ASN
	if frrASN == 0 {
		frrASN = api.DefaultFRRASN
	}
	frrNS := spec.FRR.Namespace
	if frrNS == "" {
		frrNS = api.DefaultFRRNamespace
	}
	frrLabelKey := spec.FRR.LabelKey
	if frrLabelKey == "" {
		frrLabelKey = api.DefaultFRRLabelKey
	}
	frrLabelValue := spec.FRR.LabelValue
	if frrLabelValue == "" {
		frrLabelValue = api.DefaultFRRLabelValue
	}
	nodeLabelKey := spec.NodeSelector.LabelKey
	if nodeLabelKey == "" {
		nodeLabelKey = api.DefaultNodeLabelKey
	}
	routerLabelKey := spec.NodeSelector.RouterLabelKey
	if routerLabelKey == "" {
		routerLabelKey = api.DefaultRouterLabelKey
	}
	infraKey := spec.NodeSelector.InfraExcludeLabelKey
	if infraKey == "" {
		infraKey = api.DefaultInfraExcludeLabelKey
	}
	reconcileSeconds := spec.ReconcileIntervalSeconds
	if reconcileSeconds == 0 {
		reconcileSeconds = api.DefaultReconcileIntervalSeconds
	}
	debounceSeconds := spec.DebounceSeconds
	if debounceSeconds == 0 {
		debounceSeconds = api.DefaultDebounceSeconds
	}

	return &reconciler.ReconcilerConfig{
		GCPProject:           spec.GCPProject,
		CloudRouterName:      spec.CloudRouter.Name,
		CloudRouterRegion:    spec.CloudRouter.Region,
		NCCHubName:           spec.NCC.HubName,
		NCCSpokePrefix:       spec.NCC.SpokePrefix,
		ClusterName:          spec.ClusterName,
		FRRASN:               frrASN,
		NCCSpokeSiteToSite:   spec.NCC.SiteToSite,
		EnableGCENestedVirt:  spec.IsNestedVirtEnabled(),
		NodeLabelKey:         nodeLabelKey,
		NodeLabelValue:       spec.NodeSelector.LabelValue,
		RouterLabelKey:       routerLabelKey,
		InfraExcludeLabelKey: infraKey,
		FRRNamespace:         frrNS,
		FRRLabelKey:          frrLabelKey,
		FRRLabelValue:        frrLabelValue,
		ReconcileInterval:    time.Duration(reconcileSeconds) * time.Second,
		Debounce:             time.Duration(debounceSeconds) * time.Second,
	}
}

// SetupWithManager sets up the controller with the Manager.
func (r *BGPRoutingConfigReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&api.BGPRoutingConfig{}).
		Owns(&api.BGPRouter{}).
		Watches(&corev1.Node{}, handler.EnqueueRequestsFromMapFunc(
			func(ctx context.Context, obj client.Object) []reconcile.Request {
				return []reconcile.Request{
					{NamespacedName: types.NamespacedName{Name: singletonName}},
				}
			},
		)).
		WithEventFilter(nodeEventFilter{}).
		Named("bgproutingconfig").
		Complete(r)
}

// nodeEventFilter filters Node events to only relevant changes (labels, providerID, addresses).
type nodeEventFilter struct{}

func (nodeEventFilter) Create(e event.CreateEvent) bool   { return true }
func (nodeEventFilter) Delete(e event.DeleteEvent) bool   { return true }
func (nodeEventFilter) Generic(e event.GenericEvent) bool { return true }

func (nodeEventFilter) Update(e event.UpdateEvent) bool {
	oldN, ok1 := e.ObjectOld.(*corev1.Node)
	newN, ok2 := e.ObjectNew.(*corev1.Node)
	if !ok1 || !ok2 {
		return true
	}
	if !reflect.DeepEqual(oldN.Labels, newN.Labels) {
		return true
	}
	if oldN.Spec.ProviderID != newN.Spec.ProviderID {
		return true
	}
	if !reflect.DeepEqual(oldN.Status.Addresses, newN.Status.Addresses) {
		return true
	}
	return false
}
