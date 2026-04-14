package reconciler

import (
	"context"
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/config"
	"github.com/rh-mobb/osd-gcp-cudn-routing/controller/go/internal/gcp"
	"github.com/stretchr/testify/require"
)

type recordingNCC struct {
	deleted []string
}

func (r *recordingNCC) ReconcileSpoke(ctx context.Context, spokeName, hubName string, nodes []gcp.RouterNode, siteToSite bool) (bool, error) {
	return false, nil
}

func (r *recordingNCC) DeleteSpoke(ctx context.Context, spokeName string) (bool, error) {
	r.deleted = append(r.deleted, spokeName)
	return true, nil
}

func (r *recordingNCC) ListSpokesByPrefix(ctx context.Context, hubName, prefix string) ([]string, error) {
	return []string{prefix + "-0", prefix + "-99"}, nil
}

func TestReconcileNCCSpokes_DeletesStaleNumberedSpokes(t *testing.T) {
	cfg := &config.ControllerConfig{
		NCCHubName:     "hub",
		NCCSpokePrefix: "mysp",
	}
	ncc := &recordingNCC{}
	nodes := []gcp.RouterNode{{Name: "vm1"}}
	ch, err := ReconcileNCCSpokes(context.Background(), ncc, cfg, nodes)
	require.NoError(t, err)
	require.GreaterOrEqual(t, ch, 1)
	require.Contains(t, ncc.deleted, "mysp-99")
}
