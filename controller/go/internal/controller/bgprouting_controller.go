package controller

import (
	"context"
	"reflect"
	"time"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/reconciler"
	"golang.org/x/time/rate"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/util/workqueue"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/event"
	crlog "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// BGPReconciler wires Node watches to the domain reconciler.
type BGPReconciler struct {
	Cfg        *config.ControllerConfig
	Reconciler *reconciler.Reconciler
}

// Reconcile implements reconcile.Reconciler (runs full cluster sync; trigger node is only for logging).
func (r *BGPReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	log := crlog.FromContext(ctx)
	log.Info("BGP routing reconcile started",
		"triggerNode", req.Name,
		"requeueAfter", r.Cfg.ReconcileInterval.String(),
	)
	res, err := r.Reconciler.Reconcile(ctx)
	if err != nil {
		return reconcile.Result{}, err
	}
	log.Info("BGP routing reconcile completed",
		"triggerNode", req.Name,
		"routerNodes", res.NodesFound,
		"canIpForwardChanged", res.CanIPForwardChanged,
		"nestedVirtChanged", res.NestedVirtualizationChanged,
		"spokesMutations", res.SpokesChanged,
		"peersChanged", res.PeersChanged,
		"frrCreated", res.FRRCreated,
		"frrDeleted", res.FRRDeleted,
		"routerLabelsChanged", res.RouterLabelsChanged,
		"anyChange", res.AnyChange(),
	)
	return reconcile.Result{RequeueAfter: r.Cfg.ReconcileInterval}, nil
}

// SetupWithManager registers the Node controller.
func (r *BGPReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("bgp-routing-controller").
		For(&corev1.Node{}).
		WithEventFilter(nodePredicate{}).
		WithOptions(controller.Options{
			RateLimiter: workqueueRateLimiter(r.Cfg.Debounce),
		}).
		Complete(r)
}

func workqueueRateLimiter(debounce time.Duration) workqueue.TypedRateLimiter[reconcile.Request] {
	if debounce <= 0 {
		debounce = 5 * time.Second
	}
	return workqueue.NewTypedMaxOfRateLimiter[reconcile.Request](
		workqueue.NewTypedItemExponentialFailureRateLimiter[reconcile.Request](debounce, 60*time.Second),
		&workqueue.TypedBucketRateLimiter[reconcile.Request]{Limiter: rate.NewLimiter(rate.Every(debounce), 1)},
	)
}

type nodePredicate struct{}

func (nodePredicate) Create(e event.CreateEvent) bool   { return true }
func (nodePredicate) Delete(e event.DeleteEvent) bool   { return true }
func (nodePredicate) Generic(e event.GenericEvent) bool { return true }

func (nodePredicate) Update(e event.UpdateEvent) bool {
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
