# Production readiness — BGP reference stack

Supplements the repo-wide [PRODUCTION.md](../PRODUCTION.md) (Kubernetes controller concept, shared gaps, operations). Read that first for **cross-cutting** automation and security expectations.

For PoC limits in this stack, see [Known limitations](README.md#known-limitations) in [README.md](README.md). **IAM** for Terraform principals is summarized in [ILB-vs-BGP.md § Additional IAM requirements](../ILB-vs-BGP.md#additional-iam-requirements).

---

## BGP-specific gaps

1. **NCC hub/spoke and Cloud Router peers** must stay consistent when workers are **added, replaced, or relabeled**. The PoC relies on **Terraform re-apply** (or **`configure-routing.sh`** driving FRR) after discovery; production needs **event-driven reconciliation** similar in spirit to ILB backend drift — update **Router Appliance spoke** attachment lists, **BGP peers**, and **per-node `FRRConfiguration`** when **Nodes** or **Machines** change.

2. **Per-node `FRRConfiguration`:** The reference script matches GCE instance names to **`Node.spec.providerID`**. Production may prefer **labels**, **Machine** objects, or a **controller** to emit configs when nodes change.

3. **Cloud Router interface IPs:** Default allocation uses **`cidrhost(subnet, offset + index)`**; collisions with other hosts must be prevented (override **`router_interface_private_ips`** in Terraform if needed).

4. **IAM:** Principals applying [**`modules/osd-bgp-routing`**](../modules/osd-bgp-routing/README.md) need **NCC** and **network admin**-class roles; the OSD WIF service account alone may be insufficient for **`terraform apply`** unless those roles are granted to the identity you use.

5. **ASN policy, session monitoring, BFD:** Production should define **allowed ASNs**, **hold timers**, and **observability** for BGP sessions (beyond what the PoC demonstrates). Align with your org’s **Network Connectivity Center** standards.

6. **Peered VPCs, VPN, Interconnect:** Remote networks do not automatically learn CUDN prefixes. With BGP, routes propagate via **Cloud Router** import policy and **NCC** topology; validate **end-to-end** whenever hub/spoke or **Cloud Router** attachments change (see also shared [PRODUCTION.md](../PRODUCTION.md#cross-vpc-and-hybrid-connectivity)).
