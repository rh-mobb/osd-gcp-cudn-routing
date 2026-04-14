package gcp

import (
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/compute/v1"
)

func TestShortZone(t *testing.T) {
	require.Equal(t, "us-central1-a", shortZone("https://www.googleapis.com/compute/v1/projects/p/zones/us-central1-a"))
	require.Equal(t, "us-central1-a", shortZone("us-central1-a"))
}

func TestBuildPeerSetEqual(t *testing.T) {
	a := []*compute.RouterBgpPeer{
		{Name: "p-0-0", PeerIpAddress: "10.0.0.1", PeerAsn: 65003},
		{Name: "p-0-1", PeerIpAddress: "10.0.0.1", PeerAsn: 65003},
	}
	b := []*compute.RouterBgpPeer{
		{Name: "p-0-1", PeerIpAddress: "10.0.0.1", PeerAsn: 65003},
		{Name: "p-0-0", PeerIpAddress: "10.0.0.1", PeerAsn: 65003},
	}
	require.True(t, buildPeerSet(a).Equal(buildPeerSet(b)))

	c := []*compute.RouterBgpPeer{
		{Name: "p-0-0", PeerIpAddress: "10.0.0.1", PeerAsn: 65004},
		{Name: "p-0-1", PeerIpAddress: "10.0.0.1", PeerAsn: 65003},
	}
	require.False(t, buildPeerSet(a).Equal(buildPeerSet(c)))
}
