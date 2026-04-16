package gcp

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"google.golang.org/api/compute/v1"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
)

// NewComputeClient builds a ComputeClient using Application Default Credentials.
func NewComputeClient(ctx context.Context, project, region string) (ComputeClient, error) {
	svc, err := compute.NewService(ctx, option.WithScopes(compute.CloudPlatformScope))
	if err != nil {
		return nil, err
	}
	return &computeClient{
		svc:     svc,
		project: project,
		region:  region,
		inst:    svc.Instances,
		routers: svc.Routers,
	}, nil
}

type computeClient struct {
	svc     *compute.Service
	project string
	region  string
	inst    *compute.InstancesService
	routers *compute.RoutersService
}

func (c *computeClient) EnsureCanIPForward(ctx context.Context, node RouterNode) (bool, error) {
	zone := shortZone(node.Zone)
	inst, err := c.inst.Get(c.project, zone, node.Name).Context(ctx).Do()
	if err != nil {
		return false, err
	}
	if inst.CanIpForward {
		return false, nil
	}
	inst.CanIpForward = true
	op, err := c.inst.Update(c.project, zone, node.Name, inst).
		MostDisruptiveAllowedAction("REFRESH").
		Context(ctx).
		Do()
	if err != nil {
		return false, err
	}
	if err := c.waitZoneOp(ctx, zone, op); err != nil {
		return false, err
	}
	return true, nil
}

func (c *computeClient) EnsureNestedVirtualization(ctx context.Context, node RouterNode) (bool, error) {
	zone := shortZone(node.Zone)
	inst, err := c.inst.Get(c.project, zone, node.Name).Context(ctx).Do()
	if err != nil {
		return false, err
	}
	if inst.AdvancedMachineFeatures != nil && inst.AdvancedMachineFeatures.EnableNestedVirtualization {
		return false, nil
	}
	if inst.AdvancedMachineFeatures == nil {
		inst.AdvancedMachineFeatures = &compute.AdvancedMachineFeatures{}
	}
	inst.AdvancedMachineFeatures.EnableNestedVirtualization = true
	// GCP rejects REFRESH for this field; API returns 400 requiring RESTART.
	op, err := c.inst.Update(c.project, zone, node.Name, inst).
		MostDisruptiveAllowedAction("RESTART").
		Context(ctx).
		Do()
	if err != nil {
		return false, err
	}
	if err := c.waitZoneOp(ctx, zone, op); err != nil {
		return false, err
	}
	return true, nil
}

func (c *computeClient) waitZoneOp(ctx context.Context, zone string, op *compute.Operation) error {
	if op == nil {
		return nil
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
		cur, err := c.svc.ZoneOperations.Get(c.project, zone, op.Name).Context(ctx).Do()
		if err != nil {
			return err
		}
		if cur.Status == "DONE" {
			if cur.Error != nil {
				return fmt.Errorf("operation failed: %v", cur.Error)
			}
			return nil
		}
	}
}

func (c *computeClient) GetRouterTopology(ctx context.Context, routerName string) (*CloudRouterTopology, error) {
	r, err := c.routers.Get(c.project, c.region, routerName).Context(ctx).Do()
	if err != nil {
		return nil, err
	}
	var names, ips []string
	for _, iface := range r.Interfaces {
		names = append(names, iface.Name)
		ip := iface.IpRange
		if idx := strings.Index(ip, "/"); idx >= 0 {
			ip = ip[:idx]
		}
		ips = append(ips, ip)
	}
	var asn int64
	if r.Bgp != nil {
		asn = r.Bgp.Asn
	}
	return &CloudRouterTopology{
		CloudRouterASN: asn,
		InterfaceNames: names,
		InterfaceIPs:   ips,
	}, nil
}

func (c *computeClient) ReconcilePeers(ctx context.Context, routerName, clusterName string, nodes []RouterNode, topology *CloudRouterTopology, frrASN int) (bool, error) {
	r, err := c.routers.Get(c.project, c.region, routerName).Context(ctx).Do()
	if err != nil {
		return false, err
	}

	sorted := append([]RouterNode(nil), nodes...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Name < sorted[j].Name })

	var desired []*compute.RouterBgpPeer
	for idx := range sorted {
		for ifaceIdx, ifaceName := range topology.InterfaceNames {
			if ifaceIdx >= len(topology.InterfaceIPs) {
				break
			}
			desired = append(desired, &compute.RouterBgpPeer{
				Name:                    fmt.Sprintf("%s-bgp-peer-%d-%d", clusterName, idx, ifaceIdx),
				InterfaceName:           ifaceName,
				PeerIpAddress:           sorted[idx].IPAddress,
				IpAddress:               topology.InterfaceIPs[ifaceIdx],
				PeerAsn:                 int64(frrASN),
				RouterApplianceInstance: sorted[idx].SelfLink,
			})
		}
	}

	currentSet := buildPeerSet(r.BgpPeers)
	desiredSet := buildPeerSet(desired)
	if currentSet.Equal(desiredSet) {
		return false, nil
	}

	patch := &compute.Router{BgpPeers: desired}
	op, err := c.routers.Patch(c.project, c.region, routerName, patch).Context(ctx).Do()
	if err != nil {
		return false, err
	}
	if err := c.waitRegionOp(ctx, op); err != nil {
		return false, err
	}
	return true, nil
}

func (c *computeClient) ClearPeers(ctx context.Context, routerName string) (bool, error) {
	r, err := c.routers.Get(c.project, c.region, routerName).Context(ctx).Do()
	if err != nil {
		return false, err
	}
	if len(r.BgpPeers) == 0 {
		return false, nil
	}
	r.BgpPeers = nil
	op, err := c.routers.Update(c.project, c.region, routerName, r).Context(ctx).Do()
	if err != nil {
		if ge, ok := err.(*googleapi.Error); ok && ge.Code == 400 {
			return false, err
		}
		return false, err
	}
	if err := c.waitRegionOp(ctx, op); err != nil {
		return false, err
	}
	return true, nil
}

func (c *computeClient) waitRegionOp(ctx context.Context, op *compute.Operation) error {
	if op == nil {
		return nil
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
		cur, err := c.svc.RegionOperations.Get(c.project, c.region, op.Name).Context(ctx).Do()
		if err != nil {
			return err
		}
		if cur.Status == "DONE" {
			if cur.Error != nil {
				return fmt.Errorf("operation failed: %v", cur.Error)
			}
			return nil
		}
	}
}

type peerKey struct {
	name, peerIP string
	peerASN      int64
}

type peerSet map[peerKey]struct{}

func buildPeerSet(peers []*compute.RouterBgpPeer) peerSet {
	s := make(peerSet)
	for _, p := range peers {
		if p == nil {
			continue
		}
		s[peerKey{p.Name, p.PeerIpAddress, p.PeerAsn}] = struct{}{}
	}
	return s
}

func (a peerSet) Equal(b peerSet) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if _, ok := b[k]; !ok {
			return false
		}
	}
	return true
}

func shortZone(zone string) string {
	if i := strings.LastIndex(zone, "/"); i >= 0 && i+1 < len(zone) {
		return zone[i+1:]
	}
	return zone
}
