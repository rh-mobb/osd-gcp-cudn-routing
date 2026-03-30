# Production readiness — BGP reference stack

Supplements the repo-wide [PRODUCTION.md](../PRODUCTION.md) (Kubernetes controller concept, shared gaps, operations). Read that first for **cross-cutting** automation and security expectations.

For the **actionable checklist** with phased tasks, e2e test checkpoints, and priority ordering, see [**PRODUCTION-ROADMAP.md**](PRODUCTION-ROADMAP.md).

For PoC limits in this stack, see [Known limitations](README.md#known-limitations) in [README.md](README.md). **IAM** for Terraform principals is summarized in [ILB-vs-BGP.md § Additional IAM requirements](../ILB-vs-BGP.md#additional-iam-requirements).

---

## BGP-specific gaps

1. **NCC spoke, Cloud Router peers, canIpForward, and FRRConfiguration** are managed by the [BGP routing controller](../controller/python/README.md). The controller must be deployed and healthy for routing to converge after node changes. Production should validate the controller in a live cluster (node replacement, scale-up, scale-down) and consider porting to Go / controller-runtime for production hardening (see [PRODUCTION-ROADMAP.md § 4F](PRODUCTION-ROADMAP.md)).

2. **Per-node `FRRConfiguration`:** The controller creates one CR per router node, matching GCE instance names from **`Node.spec.providerID`**. Production may prefer a Go controller with a `BGPRoutingConfig` CRD for operator-owned configuration.

3. **Cloud Router interface IPs:** Default allocation uses **`cidrhost(subnet, offset + index)`**; collisions with other hosts must be prevented (override **`router_interface_private_ips`** in Terraform if needed).

4. **IAM:** Principals applying [**`modules/osd-bgp-routing`**](../modules/osd-bgp-routing/README.md) need **NCC hub admin** and **network admin** roles. The **controller** needs a separate GCP SA with spoke create/update and router peer update permissions — see [controller/python/README.md § GCP IAM](../controller/python/README.md#gcp-iam-custom-role--least-privilege).

5. **ASN policy, session monitoring, BFD:** Production should define **allowed ASNs**, **hold timers**, and **observability** for BGP sessions (beyond what the PoC demonstrates). Align with your org's **Network Connectivity Center** standards.

6. **Peered VPCs, VPN, Interconnect:** Remote networks do not automatically learn CUDN prefixes. With BGP, routes propagate via **Cloud Router** import policy and **NCC** topology; validate **end-to-end** whenever hub/spoke or **Cloud Router** attachments change (see also shared [PRODUCTION.md](../PRODUCTION.md#cross-vpc-and-hybrid-connectivity)).
