package reconciler

import (
	"context"
	"sort"
	"strconv"

	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
)

// ChunkRouterNodes splits nodes into chunks of at most maxPer (GCP NCC limit).
func ChunkRouterNodes(nodes []gcp.RouterNode, maxPer int) [][]gcp.RouterNode {
	if maxPer <= 0 {
		maxPer = 1
	}
	sorted := append([]gcp.RouterNode(nil), nodes...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Name < sorted[j].Name })
	var out [][]gcp.RouterNode
	for i := 0; i < len(sorted); i += maxPer {
		end := i + maxPer
		if end > len(sorted) {
			end = len(sorted)
		}
		out = append(out, sorted[i:end])
	}
	return out
}

// ReconcileNCCSpokes creates/updates numbered spokes and deletes stale ones.
func ReconcileNCCSpokes(ctx context.Context, ncc gcp.NCCClient, cfg *ReconcilerConfig, routerNodes []gcp.RouterNode) (int, error) {
	prefix := cfg.NCCSpokePrefix
	chunks := ChunkRouterNodes(routerNodes, NCCMaxInstancesPerSpoke)
	desiredIDs := make([]string, len(chunks))
	desiredSet := make(map[string]struct{})
	for i := range chunks {
		id := prefix + "-" + strconv.Itoa(i)
		desiredIDs[i] = id
		desiredSet[id] = struct{}{}
	}
	changes := 0
	for i, id := range desiredIDs {
		changed, err := ncc.ReconcileSpoke(ctx, id, cfg.NCCHubName, chunks[i], cfg.NCCSpokeSiteToSite)
		if err != nil {
			return changes, err
		}
		if changed {
			changes++
		}
	}
	existing, err := ncc.ListSpokesByPrefix(ctx, cfg.NCCHubName, prefix)
	if err != nil {
		return changes, err
	}
	for _, spokeID := range existing {
		if _, ok := desiredSet[spokeID]; ok {
			continue
		}
		deleted, err := ncc.DeleteSpoke(ctx, spokeID)
		if err != nil {
			return changes, err
		}
		if deleted {
			changes++
		}
	}
	return changes, nil
}
