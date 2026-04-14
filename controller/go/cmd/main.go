// BGP routing controller for OSD-GCP CUDN (controller-runtime).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"os"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	bgctrl "github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/controller"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/reconciler"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/scheme"
	"go.uber.org/zap/zapcore"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	ctrl "sigs.k8s.io/controller-runtime"
)

func main() {
	var (
		once    = flag.Bool("once", false, "run a single reconciliation pass and exit")
		cleanup = flag.Bool("cleanup", false, "delete controller-managed resources and exit")
	)
	flag.Parse()

	zapOpts := zap.Options{Development: os.Getenv("DEBUG") != ""}
	if zapOpts.Development {
		zapOpts.EncoderConfigOptions = append(zapOpts.EncoderConfigOptions, func(ec *zapcore.EncoderConfig) {
			ec.EncodeLevel = zapcore.CapitalColorLevelEncoder
		})
	}
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))

	cfg, err := config.FromEnv()
	if err != nil {
		log.Log.Error(err, "configuration")
		os.Exit(1)
	}
	if !cfg.EnableGCENestedVirt {
		log.Log.Info("ENABLE_GCE_NESTED_VIRTUALIZATION=false — skipping nested virt on router VMs")
	}

	logADCPathAndWIFSummary()

	ctx := context.Background()
	computeClient, err := gcp.NewComputeClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		log.Log.Error(err, "GCP compute client")
		os.Exit(1)
	}
	nccClient, err := gcp.NewNCCClient(ctx, cfg.GCPProject, cfg.CloudRouterRegion)
	if err != nil {
		log.Log.Error(err, "GCP NCC client")
		os.Exit(1)
	}

	restCfg, err := ctrl.GetConfig()
	if err != nil {
		log.Log.Error(err, "kubernetes config")
		os.Exit(1)
	}

	sch := scheme.New()
	k8sClient, err := client.New(restCfg, client.Options{Scheme: sch})
	if err != nil {
		log.Log.Error(err, "kubernetes client")
		os.Exit(1)
	}

	rec := &reconciler.Reconciler{
		Cfg:     cfg,
		Client:  k8sClient,
		Compute: computeClient,
		NCC:     nccClient,
	}

	if *cleanup {
		if err := rec.Cleanup(ctx); err != nil {
			log.Log.Error(err, "cleanup")
			os.Exit(1)
		}
		os.Exit(0)
	}

	if *once {
		onceCtx := log.IntoContext(context.Background(), log.Log)
		res, err := rec.Reconcile(onceCtx)
		if err != nil {
			log.Log.Error(err, "reconcile")
			os.Exit(1)
		}
		log.Log.Info(
			"reconcile complete",
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
		os.Exit(0)
	}

	mgr, err := ctrl.NewManager(restCfg, ctrl.Options{
		Scheme: sch,
		Metrics: metricsserver.Options{
			BindAddress: ":8080",
		},
		HealthProbeBindAddress:  ":8081",
		LeaderElection:          true,
		LeaderElectionID:        "bgp-routing-controller.cudn.redhat.com",
		LeaderElectionNamespace: cfg.ControllerNamespace,
	})
	if err != nil {
		log.Log.Error(err, "manager")
		os.Exit(1)
	}

	rec.Client = mgr.GetClient()
	if err := (&bgctrl.BGPReconciler{Cfg: cfg, Reconciler: rec}).SetupWithManager(mgr); err != nil {
		log.Log.Error(err, "controller")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Log.Error(err, "healthz")
		os.Exit(1)
	}
	// Readiness must not depend on GCP API calls: a failed WIF/ADC path would block
	// /readyz forever and OpenShift rollout never completes. GCP connectivity is exercised
	// on every reconcile (logs + metrics).
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Log.Error(err, "readyz")
		os.Exit(1)
	}

	log.Log.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Log.Error(err, "manager exited")
		os.Exit(1)
	}
}

// logADCPathAndWIFSummary logs how Application Default Credentials are loaded (no secrets).
// A 403 mentioning the controller's GCP service account indicates WIF/ADC is working but IAM is insufficient.
func logADCPathAndWIFSummary() {
	path := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	if path == "" {
		log.Log.Info("GOOGLE_APPLICATION_CREDENTIALS unset — GCP clients use other ADC sources (e.g. local gcloud)")
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		log.Log.Error(err, "read GOOGLE_APPLICATION_CREDENTIALS", "path", path)
		return
	}
	var ext struct {
		Type             string `json:"type"`
		CredentialSource struct {
			File string `json:"file"`
		} `json:"credential_source"`
		ServiceAccountImpersonationURL string `json:"service_account_impersonation_url"`
	}
	if err := json.Unmarshal(raw, &ext); err != nil {
		log.Log.Info("ADC file present (unparseable JSON)", "path", path)
		return
	}
	log.Log.Info("Application Default Credentials",
		"path", path,
		"jsonType", ext.Type,
		"credentialSourceFile", ext.CredentialSource.File,
		"hasServiceAccountImpersonationURL", ext.ServiceAccountImpersonationURL != "",
	)
}
