package gcp

import "context"

// ComputeClient abstracts GCE instances and Cloud Router operations.
type ComputeClient interface {
	EnsureCanIPForward(ctx context.Context, node RouterNode) (changed bool, err error)
	EnsureNestedVirtualization(ctx context.Context, node RouterNode) (changed bool, err error)
	GetRouterTopology(ctx context.Context, routerName string) (*CloudRouterTopology, error)
	ReconcilePeers(ctx context.Context, routerName, clusterName string, nodes []RouterNode, topology *CloudRouterTopology, frrASN int) (changed bool, err error)
	ClearPeers(ctx context.Context, routerName string) (changed bool, err error)
}

// NCCClient abstracts Network Connectivity Center spoke operations.
type NCCClient interface {
	ReconcileSpoke(ctx context.Context, spokeName, hubName string, nodes []RouterNode, siteToSite bool) (changed bool, err error)
	DeleteSpoke(ctx context.Context, spokeName string) (deleted bool, err error)
	ListSpokesByPrefix(ctx context.Context, hubName, prefix string) ([]string, error)
}
