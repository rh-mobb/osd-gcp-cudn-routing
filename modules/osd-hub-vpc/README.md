# Module: `osd-hub-vpc`

Hub VPC for **internet egress**: regional MIG of NAT VMs (**nftables MASQUERADE**), **internal passthrough NLB**, reserved ILB VIP, hub-only **Cloud NAT** for hub subnet management traffic.

Peering is **not** defined here — wire **`google_compute_network_peering`** in the root stack after both hub and spoke VPCs exist.

## Outputs

| Output | Use |
|--------|-----|
| `nat_ilb_forwarding_rule_self_link` | Spoke **`google_compute_route`** **`next_hop_ilb`** |
| `hub_vpc_self_link` | Peering |
| `nat_ilb_ip` | Debugging / documentation |

See [ARCHITECTURE.md](../../ARCHITECTURE.md).
