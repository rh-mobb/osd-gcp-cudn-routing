# AGENTS.md

This repository contains Terraform modules, a CRD-based **operator** (`routing.osd.redhat.com/v1alpha1`), and a **BGP** (NCC + Cloud Router) reference deployment for CUDN routing on OpenShift Dedicated (OSD) for Google Cloud. The operator reconciles dynamic BGP resources (NCC spokes, Cloud Router peers, FRR CRs). An **ILB** reference stack and legacy controllers are archived under **`archive/`**. The [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google) repo provides the `osdgoogle` provider, VPC/cluster modules, and WIF configuration.

<!-- keel:start - DO NOT EDIT between these markers -->
## Rules

| Rule | Globs | Always Apply |
|------|-------|--------------|
| agent-behavior | `["**/*"]` | true |
| base | `["**/*"]` | true |
| markdown | `["**/*.md"]` | false |
| scaffolding | `["**/*"]` | true |
| terraform | `["**/*.tf", "**/*.tfvars", "**/*.tfvars.json"]` | false |
| yaml | `["**/*.yaml", "**/*.yml"]` | false |

## Rule Details

### agent-behavior
- **Description:** Universal behavioral safety rules for AI agents interacting with live systems
- **Globs:** `["**/*"]`
- **File:** `.agents/rules/keel/agent-behavior.md`

### base
- **Description:** Global coding standards that apply to all files and languages
- **Globs:** `["**/*"]`
- **File:** `.agents/rules/keel/base.md`

### markdown
- **Description:** Markdown writing conventions for .md files
- **Globs:** `["**/*.md"]`
- **File:** `.agents/rules/keel/markdown.md`

### scaffolding
- **Description:** Interactive guidance for essential project scaffolding files
- **Globs:** `["**/*"]`
- **File:** `.agents/rules/keel/scaffolding.md`

### terraform
- **Description:** Best practices and rules for Terraform infrastructure as code
- **Globs:** `["**/*.tf", "**/*.tfvars", "**/*.tfvars.json"]`
- **File:** `.agents/rules/keel/terraform.md`

### yaml
- **Description:** YAML formatting and structure conventions
- **Globs:** `["**/*.yaml", "**/*.yml"]`
- **File:** `.agents/rules/keel/yaml.md`
<!-- keel:end -->

## PR Requirements

Run `make fmt` before submission (Terraform formatting).

## Agent Responsibilities

When making changes to this codebase, AI agents **must**:

- **Keep documentation up to date** — Update [README.md](README.md) and module READMEs when behavior or inputs change.
- **Update the changelog** — For user-facing changes, add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) using Added, Changed, Deprecated, Removed, Fixed, or Security. **Exception:** changes limited to [presentation/](presentation/) (Slidev deck) do not require a CHANGELOG entry — see [presentation/AGENTS.md](presentation/AGENTS.md).
- **Maintain the knowledge base** — Record new learnings, invalidated assumptions, and testable hypotheses in [KNOWLEDGE.md](KNOWLEDGE.md), each with a **confidence score** and short reasoning or citation. This file works **alongside** [ARCHITECTURE.md](ARCHITECTURE.md) and runbooks: architecture docs stay curated and stable; `KNOWLEDGE.md` holds evidence, uncertainty, and institutional memory for humans and agents between sessions. Prefer updating an existing subsection when the topic is already covered; promote settled items into **Verified Facts** (and trim stale hypothesis text) when evidence warrants it.

### KNOWLEDGE.md: when to update

Update `KNOWLEDGE.md` when you:

- Confirm or refute behavior during debugging, tests, or cluster investigation.
- Rely on a **non-obvious assumption** to implement or recommend something—document the assumption, confidence, and what would prove it wrong.
- Find authoritative vendor or upstream documentation that resolves an open question.

Do **not** use `KNOWLEDGE.md` instead of updating [ARCHITECTURE.md](ARCHITECTURE.md) when the change is a deliberate, reviewed design decision that belongs in the canonical architecture narrative.

## Debugging

When investigating failures or unexpected behavior, agents should **use the tools available in the environment** (MCP integrations, CLIs, cluster/API clients, logs, tests, and repository search) to gather evidence **before** changing code or configuration. Prefer a short, targeted investigation that confirms root cause over speculative edits.

## OpenShift and Kubernetes clusters

When reading or changing cluster state (resources, logs, events, routes, operators, etc.), use tools in this **strict preference order**:

1. **Kubernetes MCP** — Use it first whenever the enabled MCP server exposes the needed capability (list/get/watch, apply, logs, port-forward equivalents, etc.).
2. **`oc`** — Use the OpenShift CLI second when the MCP is insufficient, unavailable, or OpenShift-specific behavior requires it.
3. **`kubectl`** — Use only as a last resort when neither the MCP nor `oc` can complete the task.

Do not skip the MCP in favor of raw CLIs when the MCP can perform the same operation.

## Command-line execution

Use **judgment** when choosing how to run shell commands. The **tmux MCP** is often the best fit—especially when you are juggling **multiple** debugging streams (several tails, watches, port-forwards, or compare-before/after runs), when work is **long-running**, or when you need **attachable, durable** session output. A single quick, non-interactive command (for example `make test` or `terraform fmt -check`) may be simpler through the ordinary shell integration without tmux. When you do use tmux, prefer an **isolated socket** when parallel agents need separate shells (follow the tmux MCP server’s socket guidance).

### CUDN / KubeVirt guests: SSH (primary UDN)

`virtctl ssh` is often **unsupported or unreliable** in **primary UDN** namespaces. Use a **jump pod on the same CUDN** and the repo keypair in **`cluster_bgp_routing/.virt-e2e/id_ed25519`** (or another `CLUSTER_DIR` passed to the virt e2e script):

1. `oc wait -n cudn1 --for=condition=Ready pod/netshoot-cudn` (or deploy [`scripts/deploy-cudn-test-pods.sh`](scripts/deploy-cudn-test-pods.sh))
2. `oc cp $CLUSTER_DIR/.virt-e2e/id_ed25519 cudn1/netshoot-cudn:/tmp/virt-e2e-vm-key -c netshoot` then `oc exec` … `chmod 600` on that path
3. `oc exec -n cudn1 -it netshoot-cudn -c netshoot -- ssh -i /tmp/virt-e2e-vm-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null cloud-user@<VMI-guest-IPv4>` (address from `oc get vmi -o wide` or `oc get vmi -o jsonpath=…`)

[`scripts/virt-ssh.sh`](scripts/virt-ssh.sh) and **`make virt.ssh.bridge`** / **`make virt.ssh.masq`** automate the same. [`e2e-virt-live-migration.sh`](scripts/e2e-virt-live-migration.sh) Phase A uses the jump for in-guest tests between the two virt-e2e VMs, `icanhazip-cudn`, and the Terraform **echo** VM. More detail: [KNOWLEDGE.md](KNOWLEDGE.md) (OpenShift Virtualization on GCP — *Ad-hoc SSH*).

## Self-Review (Mandatory)

Before ANY response containing code, analysis, or recommendations:

1. Pause and re-read your work
2. Ask yourself:
   - "What would a senior engineer critique?"
   - "What edge case am I missing?"
   - "Is this actually correct?"
3. Check the integrity of the code itself
    - syntax
    - lint
    - formatting
4. Fix issues before responding
5. Note significant fixes: "Self-review: [what you caught]"

## GCP Terraform — Verify Before Writing

This repo contains non-trivial GCP infrastructure. Several resource types have **non-obvious API constraints** that are not enforced until apply time. Before writing or modifying any GCP Terraform resource, agents **must** look up the relevant documentation using the Context7 MCP server rather than relying on memory.

**Mandatory doc lookup triggers — fetch docs before writing any of these:**

- Internal load balancers (`google_compute_region_backend_service`, `google_compute_forwarding_rule`) — balancing mode, address purpose, `all_ports`, `next_hop_ilb` routing compatibility
- VPC routes with `next_hop_ilb` — [ILB as next hop](https://cloud.google.com/load-balancing/docs/internal/ilb-next-hop-overview): address purpose restrictions, peering support, regional constraints
- `google_compute_address` `purpose` field — `SHARED_LOADBALANCER_VIP` vs plain `INTERNAL` have mutually exclusive use cases
- VPC peering (`google_compute_network_peering`) — custom route import/export behavior, limitations
- `google_compute_router` / `google_compute_router_nat` — subnet scoping, NAT IP allocation
- NCC (`google_network_connectivity_hub`, `google_network_connectivity_spoke`) — spoke limits, router appliance constraints
- Terraform `depends_on` on **modules** — defers all data sources inside that module to apply-time, not just outputs; prefer implicit dependencies via resource attribute references instead

**Known confirmed OS-level constraints (startup scripts on CentOS Stream 9 / RHEL 9):**

- `nftables.service` on CentOS Stream 9 / RHEL 9 loads `/etc/sysconfig/nftables.conf`, **not** `/etc/nftables.conf`. Writing MASQUERADE rules to `/etc/nftables.conf` and calling `systemctl enable --now nftables` leaves the running ruleset empty — the service starts successfully but loads the wrong file. Fix: write to `/etc/sysconfig/nftables.conf` AND apply immediately with `nft -f /etc/sysconfig/nftables.conf` (don't rely solely on the service restart). Verified in production April 2026.

**Known confirmed GCP API constraints (do not repeat these mistakes):**

- `google_compute_region_backend_service` with `load_balancing_scheme = "INTERNAL"` requires `balancing_mode = "CONNECTION"` on every backend — `UTILIZATION` is rejected by the API.
- `google_compute_address` with `purpose = "SHARED_LOADBALANCER_VIP"` cannot be used as a `next_hop_ilb` in a route — use a plain `INTERNAL` address (no `purpose` field).
- `depends_on = [module.foo]` on `module "bar"` causes Terraform to defer all data sources inside `module "bar"` to apply-time, making their attributes unknown at plan and breaking `for_each` key resolution. Pass outputs directly as inputs to create implicit ordering instead.
- `google_compute_route` with `next_hop_ilb` pointing to a forwarding rule in a **peered** VPC must use the forwarding rule's **IP address** (e.g. `google_compute_forwarding_rule.foo.ip_address`), **not** its `self_link`. Using `self_link` causes the GCP API to reject the route with `Next hop Ilb is not on the route's network`, even when the peering exists with `export/import_custom_routes = true`. The route must also include `depends_on` on both peering resources. Source: official `google_compute_route` Terraform provider documentation (cross-VPC peering example). Verified in production April 2026.
