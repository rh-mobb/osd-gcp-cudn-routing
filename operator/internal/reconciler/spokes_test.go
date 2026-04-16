package reconciler

import (
	"testing"

	"github.com/rh-mobb/osd-gcp-cudn-routing/operator/internal/gcp"
	"github.com/stretchr/testify/require"
)

func TestChunkRouterNodes(t *testing.T) {
	mk := func(names ...string) []gcp.RouterNode {
		var out []gcp.RouterNode
		for _, n := range names {
			out = append(out, gcp.RouterNode{Name: n})
		}
		return out
	}
	chunks := ChunkRouterNodes(mk("b", "a", "c"), NCCMaxInstancesPerSpoke)
	require.Len(t, chunks, 1)
	require.Len(t, chunks[0], 3)
	require.Equal(t, "a", chunks[0][0].Name)

	nodes := mk("1", "2", "3", "4", "5", "6", "7", "8", "9")
	chunks = ChunkRouterNodes(nodes, 8)
	require.Len(t, chunks, 2)
	require.Len(t, chunks[0], 8)
	require.Len(t, chunks[1], 1)
	require.Equal(t, "9", chunks[1][0].Name)
}
