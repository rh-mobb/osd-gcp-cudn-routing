# OSD GCP CUDN Routing — Project Timeline & Engineering Chronicle

> **Status:** Living document · Last updated: 2026-04-23 (presentation built 2026-04-23)
> **Authors:** Paul Czarkowski + Cursor AI (Sonnet) — co-generated in real time throughout the project
>
> This document is itself an artifact of the method it describes: a human-AI pair working
> together across dozens of sessions, using AI to capture institutional memory, reason about
> architecture, debug production systems, and build knowledge that persists between sessions.
> It was assembled from 110 Cursor chat sessions across two repos (45 in `tf-provider-osd-google`,
> 65 in `osd-gcp-cudn-routing`), commit history, KNOWLEDGE.md, CHANGELOG.md,
> debug logs, packet captures, and canvas artifacts.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [How This Project Was Built](#2-how-this-project-was-built)
3. [The AI Toolset](#3-the-ai-toolset)
   - 3.1 Kubernetes MCP
   - 3.2 Context7
   - 3.3 tmux MCP
   - 3.4 Wireshark MCP
   - 3.5 Canvas → HTML Artifacts
   - 3.6 References Folder (Gitignored)
   - 3.7 Project Scaffolding — Engineering the Agent's Behavior
4. [Pre-History — The Terraform Provider (Mar 4–26)](#4-pre-history--the-terraform-provider-mar-426)
5. [Week 1 — First Sessions in the New Repo (Mar 26)](#5-week-1--first-sessions-in-the-new-repo-mar-26)
6. [Week 2 — E2E Testing, Production Roadmap (Mar 27)](#6-week-2--e2e-testing-production-roadmap-mar-27)
7. [Week 3 — The Great Pivot: BGP Only (Mar 30–31)](#7-week-3--the-great-pivot-bgp-only-mar-3031)
8. [Week 4 — Architecture, Knowledge, and the Go Controller (Apr 2–9)](#8-week-4--architecture-knowledge-and-the-go-controller-apr-29)
9. [Week 5 — Operator / CRD Design, CI, and OpenShift Virt (Apr 13–16)](#9-week-5--operator--crd-design-ci-and-openshift-virt-apr-1316)
10. [Week 6 — Bare Metal, Live Migration, and the Internet Egress Mystery (Apr 17–21)](#10-week-6--bare-metal-live-migration-and-the-internet-egress-mystery-apr-1721)
11. [Week 7 — The Smoking Gun (Apr 22–23)](#11-week-7--the-smoking-gun-apr-2223)
12. [Novel Techniques and Tools](#12-novel-techniques-and-tools)
13. [Human in the Loop: Moments That Mattered](#13-human-in-the-loop-moments-that-mattered)
14. [What Was Built](#14-what-was-built)
15. [Open Threads and Future Work](#15-open-threads-and-future-work)
16. [Presentation Outline (Draft)](#16-presentation-outline-draft)
17. [Followup Questions](#17-followup-questions)
18. [References and Further Reading](#18-references-and-further-reading)

---

## 1. Project Overview

**Goal:** Enable CUDN (Cluster User-Defined Network) pod and KubeVirt VM IPs to be reachable
from a GCP VPC without SNAT, using BGP routing via GCP Network Connectivity Center (NCC) +
Cloud Router in a hub/spoke VPC topology.

**Team:** Red Hat Managed OpenShift Black Belt — Paul Czarkowski with Cursor AI.
**Partner:** Shreyans Mulkutkar (OSD GCP Product Manager).

**Cluster:** `cz-demo1` · OSD GCP · `us-central1` · OCP 4.21.x
**Reference parallel:** `czvirt` · ROSA HCP · `eu-central-1` · OCP 4.21.9

### The Customer Problem

> **Customers running OpenShift Virtualization on GCP want a way to access VMs directly
> from their own networks, without having to create Kubernetes services or use tools like
> `virtctl ssh` / `virtctl console`.**

This is both an inbound routing problem (VPC → VM, stable IP, survives live migration) and
an egress problem (VM → internet, without double-NAT through the node). OpenShift's default
behaviour SNATs pod traffic through the worker node's primary VPC IP, which means:
- VMs have no stable, externally-routable IP
- After live migration the VM moves nodes, breaking any IP-based VPC routing
- External services can't address VMs directly

The solution architecture: run FRR BGP on all worker nodes, peer them to Cloud Router via NCC
Router Appliance spokes, and use OVN-K `RouteAdvertisements` to advertise the CUDN `/16`
prefix into the VPC routing table. This gives the CUDN overlay a stable, VPC-routable IP
range that persists across live migrations.

### The Origin: A Slack Message on March 18

The external catalyst came from Shreyans Mulkutkar, the OSD GCP Product Manager, on March 18:

> *"Hi Paul, need your help in building out the AWS Route Server equivalent on GCP — i.e.
> using GCP Cloud Router. I used Claude to generate equivalent steps for OSD. Does this look
> okay? The VPC configuration proposed by Claude is not accurate — like I don't think we need
> a separate subnet in each zone. Would love to partner with you and learn along the way."*

Shreyans had seen the AWS reference implementation (`msemanrh/rosa-bgp`) by Daniel Axelrod
and asked Claude to port it to GCP. The result was a 1,126-line implementation guide
(`docs/initial-design-spec-by-claude.md`) with several fundamental architectural errors.
Paul was already planning the work and now had a PM partner and a concrete customer need.

This detail is worth noting: **Claude wrote the first draft of the implementation plan; Cursor
built the production implementation.** The two AI tools served different roles — one for rapid
prototyping and scoping, one for careful, validated, production engineering.

### What Claude Got Wrong: Draft vs Production

A detailed comparison is possible because the spec is preserved. The errors fall into two
categories: things Claude couldn't know (undocumented GCP constraints), and things Claude
should have questioned more carefully (architectural assumptions carried over from AWS).

| Aspect | Claude's Draft | What Was Actually Built |
|--------|---------------|------------------------|
| **Cloud Router architecture** | One BGP peer per zone, no NCC | NCC Router Appliance spokes required; exactly 2 Cloud Router interfaces (HA pair); every worker peers with both |
| **NCC** | Not mentioned | Core component — Cloud Router cannot peer with arbitrary GCE instances without NCC Router Appliance |
| **Subnet structure** | One subnet per zone (`osd-subnet-zone-a/b/c`) | Single regional subnet covers all zones; no per-zone subnets needed |
| **UDN topology** | `layer3` with `hostSubnet: 24` | `layer2` with `ipam.lifecycle: Persistent` — required for VM live migration to preserve IPs |
| **BGP peer selection** | 3 dedicated router node pools (one per zone) | All workers are BGP peers — subset-only causes connectivity failures for pods on non-router nodes |
| **`canIpForward`** | Not mentioned | Must be set to `true` on every worker GCE instance before adding to NCC spoke; operator reconciles this continuously |
| **`disable-connected-check`** | Not mentioned | Required in `spec.raw` FRR config because GCP workers have `/32` on `br-ex`; without it BGP stays in `Active` forever |
| **HA model** | "Only one route active, best path selection" (AWS Route Server model) | GCP uses **ECMP** — all equal-cost paths active simultaneously; fundamentally different from AWS |
| **Internet egress** | Assumes Cloud NAT works for CUDN traffic | Cloud NAT rejects CUDN IPs (not registered on NIC); required dedicated hub VPC with Linux MASQUERADE NAT VMs |
| **Controller/operator** | Manual gcloud commands throughout | Kubernetes operator with CRDs (`BGPRoutingConfig`, `BGPRouter`) to reconcile dynamic state continuously |
| **WIF authentication** | Not mentioned | Significant engineering: custom IAM role, service account, WIF binding for in-cluster GCP access |
| **`RouteAdvertisements` spec** | `podNetwork: true`, `targetVRF: prod-udn` (invalid fields) | `advertisements: [{podNetwork: {}}]`, `nodeSelector: {}` (empty required by admission) |
| **FRRConfiguration** | Single shared CR, 3 neighbors (one per zone) | Per-node CRs, 2 neighbors per node (one per Cloud Router HA interface); `disableMP: true` required |

**The deeper issue:** Claude's spec treated GCP Cloud Router like AWS VPC Route Server — a
managed BGP endpoint you peer workers directly with. GCP is different: Cloud Router in NCC
Router Appliance mode is closer to a "BGP route reflector in the cloud," and the Router
Appliance instances (workers) must be explicitly linked to NCC spokes. This architectural
difference accounts for most of the errors.

**What Claude got right:**
- Overall flow: FRR on workers → BGP → Cloud Router → VPC routes → external connectivity ✓
- FRR/OVN-K integration pattern ✓
- RouteAdvertisements concept (wrong syntax, right idea) ✓
- BGP ASN structure (65003 for workers, different ASN for Cloud Router) ✓
- Phase structure (infra → cluster → networking → UDN → verification) ✓

The spec was a useful scoping document that confirmed the approach was sound and gave Shreyans
and Paul a shared vocabulary. It just couldn't be executed as-written.

**Spoiler:** It worked. And then we spent two weeks figuring out why internet egress from CUDN
VMs was intermittently broken — with the answer turning out to be a single missing GCP VPC
firewall rule and a cross-cluster comparison with ROSA/AWS that revealed the true root cause.

---

## 2. How This Project Was Built

Every session in this project was a Cursor chat. Paul would open a new session, give context or a
task, and the AI agent would:

- Explore the codebase and docs (Kubernetes MCP, file reads)
- Write or modify Terraform, Go, Python, Bash
- Run scripts and watch for failures
- Debug live clusters via the Kubernetes MCP
- Look up vendor documentation via Context7
- Update `KNOWLEDGE.md`, `CHANGELOG.md`, and runbooks in real time

The agent had access to:
- The full repo at all times
- Kubernetes MCP (live cluster access)
- tmux MCP (terminal session management)
- Wireshark MCP (PCAP analysis)
- Context7 (library/vendor documentation lookup)
- Web search

Paul would review output, catch mistakes, redirect the agent, and push back when the direction
was wrong. The sessions show a genuine collaboration: Paul provided judgment, domain authority,
and course corrections; the AI provided memory, code generation, research synthesis, and tireless
debugging.

**110 sessions across two repos** — 45 in `tf-provider-osd-google` (Mar 4–26) where the
Terraform provider and initial ILB routing work were built, then 65 in `osd-gcp-cudn-routing`
(Mar 26–Apr 23) where BGP routing, the operator, and the internet egress investigation lived.
From scratch provider to confirmed root cause, production fix, and comprehensive documentation,
across roughly seven weeks.

---

## 3. The AI Toolset

A recurring theme in this project is the deliberate expansion of the AI's toolset as the problem
demanded. Rather than asking Paul to run commands and paste output, the agent was given direct
access to progressively more powerful tools.

### 3.1 Kubernetes MCP

Available from session 1. Used for:
- Inspecting `FRRConfiguration` CRs, `BGPRoutingConfig`, `BGPRouter` status
- Watching operator logs in real time
- Checking node labels, annotations, and readiness
- Inspecting `VirtualMachine` and `VirtualMachineInstance` status
- Running diagnostic commands via `oc debug node`

### 3.2 Context7

Used to look up live GCP and OpenShift documentation before writing Terraform resources or
operator code, preventing reliance on stale training data. Mandatory lookups included:
- `google_compute_route` with `next_hop_ilb` across VPC peering
- `google_compute_firewall` address purpose constraints
- NCC spoke limits (8 router appliance instances)
- OCP `RouteAdvertisements` admission rules
- KubeVirt binding plugin (`l2bridge` vs `bridge: {}`)

### 3.3 tmux MCP

**First used: April 23.** The catalyst came from a discussion about one of this project's
persistent frustrations: getting an AI agent to interact with VMs, especially ones behind
`virtctl`. Daniel Axelrod mentioned [Terminus-2](https://www.harborframework.com/docs/agents/terminus-2)
— a research agent that uses a single interactive tmux session as its sole interface to any
terminal environment. The design philosophy: one tool (tmux), infinite flexibility.

Paul saw that link and went looking for a tmux MCP for Cursor. One existed. It was installed
the same day — not originally for parallel debugging, but to give the agent a persistent,
flexible terminal presence similar to how Terminus-2 operates.

Once installed, the tmux MCP turned out to be ideal for the parallel debugging problem too:
the agent created a `cudn-debug` session with one pane per worker node and fanned out the
same `tcpdump` command to all five simultaneously.

This is a pattern worth naming: **follow the thread from the problem to the tool.** The
problem was AI → VM access. The reference was an agent architecture built entirely around
tmux. The solution was a tmux MCP that gave Cursor the same capability in a different form.

### 3.4 Wireshark MCP

Used to analyze the `.pcap` file captured from the hub NAT VM during the internet egress
investigation. The Wireshark MCP allowed querying the capture programmatically — counting
successful vs failed connections, identifying retransmission patterns, and confirming which
connections involved multiple SYN-ACK retransmissions (indicating the return packet hit the
wrong worker and was dropped).

Key display filters documented in `references/pcap-2026-04-23/README.md`:
```
tcp.flags.syn == 1 && tcp.flags.ack == 0 && tcp.analysis.retransmission
ip.dst == 10.100.0.7 && tcp.flags.push == 1
```

### 3.5 Canvas → HTML Artifacts

During the internet egress investigation, the AI used the Canvas skill to build interactive
React diagrams explaining the packet flows. These were saved as standalone HTML files:

- `docs/cudn-ecmp-drop-flow.html` — animated visualization of the five-step failure chain
  (CUDN VM → hub NAT → DNAT → ECMP → wrong worker → firewall drop)
- `docs/cudn-rfc1918-success-flow.html` — the working path for RFC-1918 traffic

These are shareable, self-contained HTML pages that can be embedded in presentations.

### 3.6 References Folder (Gitignored)

A deliberate architectural decision: `references/` is gitignored, used to collect external
artifacts that inform the project without cluttering the repo:
- `references/rosa-bgp/` — full clone of `rh-mobb/rosa-bgp` for comparison
- `references/pcap-2026-04-23/` — PCAP files from the NAT VM capture session
- `references/rosa-pcap/` — packet captures from the ROSA/AWS cluster comparison
- `references/OpenShift_Container_Platform-4.21-Advanced_networking-en-US.pdf`
- `references/OpenShift_Container_Platform-4.21-Virtualization-en-US.pdf`

Having the full OCP 4.21 documentation PDFs available meant the agent could look up exact
admission behavior, verify support boundaries, and cite sources directly in `KNOWLEDGE.md`.

### 3.7 Project Scaffolding — Engineering the Agent's Behavior

Perhaps the most underappreciated part of the entire project is the scaffolding layer that shaped
how the AI agent behaved at every session. Without this, each session would start from zero
behavioral assumptions. With it, the agent had a stable identity, enforced best practices, and
accumulated hard-won institutional memory that carried forward automatically.

**The rules in this project come from [Project Keel](https://github.com/paulczar/keel) —
Paul's own open source project** ([tech.paulcz.net/keel](https://tech.paulcz.net/keel/)).
Keel is a Hugo-powered CMS that implements the [AGENTS.md open standard](https://agentmdx.com)
(Linux Foundation-backed, supported by OpenAI Codex, GitHub Copilot, Google Jules, and Cursor)
as a centralized, version-controlled source of truth for AI coding rules. Write rules once as
Markdown; sync them to any project in any AI tool format.

This creates a recursive quality to the project's story: Paul built the scaffolding system that
makes AI agents disciplined, then used it to validate the approach on a hard, real engineering
problem. The keel rules in `.agents/rules/keel/` are not bespoke to this project — they were
authored in a separate repo and synced in, meaning every project Paul works on benefits from
lessons learned here.

#### AGENTS.md — The Agent's Constitution

`AGENTS.md` is the first document every Cursor agent reads in this repository. It tells the agent:

- **What the project is** — a concise technical summary of the architecture, key components, and
  what's archived vs. active. This means the agent never needs to re-discover the system structure.
- **What it must always do** — keep docs up to date, update the changelog, maintain `KNOWLEDGE.md`
- **How to debug** — "use the tools available in the environment... gather evidence before changing
  code or configuration. Prefer a short, targeted investigation that confirms root cause over
  speculative edits."
- **How to review its own work** — the self-review section

The debugging and self-review sections are worth examining in detail because they directly address
the failure modes that caused the most friction in this project.

**The Debugging Section:**

> When investigating failures or unexpected behavior, agents should use the tools available in the
> environment (MCP integrations, CLIs, cluster/API clients, logs, tests, and repository search) to
> gather evidence **before** changing code or configuration. Prefer a short, targeted investigation
> that confirms root cause over speculative edits.

This single paragraph prevented countless wasted edit-apply-debug cycles. Left to default behavior,
an AI agent will often try a "plausible fix" based on the symptom. This rule forced the agent to
reach for Kubernetes MCP, logs, and tcpdump first.

**The Self-Review Section:**

> Before ANY response containing code, analysis, or recommendations:
> 1. Pause and re-read your work
> 2. Ask yourself: "What would a senior engineer critique?" / "What edge case am I missing?" / "Is this actually correct?"
> 3. Check the integrity of the code itself — syntax, lint, formatting
> 4. Fix issues before responding
> 5. Note significant fixes: "Self-review: [what you caught]"

This created a visible quality gate. In multiple sessions the agent produced output with
"Self-review: [issue it caught]" notes — errors and edge cases it found and fixed before they
were ever shown to Paul. This is a productivity multiplier: the human only reviews already-
self-reviewed work.

**The GCP Constraints Section:**

`AGENTS.md` also encodes hard-won GCP API constraints that caused real apply-time failures during
the project. Once discovered, they were written directly into the agent's always-read rules so
they could never be repeated:

- `google_compute_address` with `SHARED_LOADBALANCER_VIP` cannot be used as `next_hop_ilb`
- `depends_on = [module.foo]` defers all data sources inside that module to apply-time (breaks `for_each`)
- `google_compute_route` with `next_hop_ilb` in a peered VPC must use IP address, not `self_link`
- `nftables.service` on RHEL 9 loads `/etc/sysconfig/nftables.conf`, not `/etc/nftables.conf`

This is institutional memory encoded as agent behavior rules. Every new session benefits from every
mistake made by every previous session — without needing to read the full history.

#### Keel Rules — Layered Coding Standards

The `.agents/rules/keel/` directory contains a layered rule system that activates based on file
glob patterns:

| Rule file | Globs | Key content |
|-----------|-------|-------------|
| `agent-behavior.md` | `**/*` (always) | Destructive action confirmation, read-before-write, dry-run, blast radius, reversibility |
| `base.md` | `**/*` (always) | Code quality, error handling, git practices, dependency management, testing standards |
| `terraform.md` | `**/*.tf` etc. | `fmt`/`validate`/`tflint`, file organization, `for_each` over `count`, `moved` blocks, `sensitive = true` |
| `yaml.md` | `**/*.yaml` etc. | YAML formatting, indentation, quoting conventions |
| `markdown.md` | `**/*.md` | Writing conventions, header hierarchy, table formatting |

The key design: rules are not global noise. `terraform.md` only activates when the agent is
editing `.tf` files. `markdown.md` only activates for `.md` files. This keeps context relevant.

**The `agent-behavior.md` rule** is the safety layer for live systems. Its key constraints:

- *Destructive Actions* — never delete resources without explicit confirmation; treat `delete`,
  `destroy`, `drop`, `rm`, `purge` as verbs requiring confirmation
- *Read Before Write* — always list/get current state before mutating
- *Dry Run* — use `--dry-run` / `terraform plan` and show the output before applying
- *Blast Radius* — prefer targeted operations; avoid wildcard selectors and `--all` flags
- *Environment Awareness* — confirm which environment (dev vs. production) before commands

This rule was the reason the agent never accidentally tore down a production cluster by being
"helpful."

#### ARCHITECTURE.md — The Canonical Truth

`ARCHITECTURE.md` is the stable, authoritative reference for the system design. The distinction
from `KNOWLEDGE.md` is explicit and important:

> Architecture docs stay curated and stable; `KNOWLEDGE.md` holds evidence, uncertainty, and
> institutional memory for humans and agents between sessions.

`ARCHITECTURE.md` describes what the system is designed to do. `KNOWLEDGE.md` describes what was
discovered. The two have different update cadences: architecture changes are deliberate design
decisions; knowledge changes whenever new evidence arrives.

#### The Full Scaffolding Stack

```
AGENTS.md
├── Project description (what the system is)
├── Agent responsibilities (docs, changelog, KNOWLEDGE.md)
├── Debugging section (evidence before edits)
├── Self-review section (quality gate)
└── GCP constraints (hard-won API rules)

.agents/rules/keel/
├── agent-behavior.md    (safety: destructive actions, blast radius)
├── base.md              (code quality, git, security)
├── terraform.md         (fmt, validate, for_each, state, security)
├── yaml.md              (formatting)
└── markdown.md          (writing conventions)

ARCHITECTURE.md          (stable canonical design)
KNOWLEDGE.md             (evidence, uncertainty, institutional memory)
CHANGELOG.md             (user-facing changes)
```

The practical effect: an AI agent picking up this project in a fresh session doesn't need to be
re-briefed on what GCP constraints are known, what quality standards apply, what the debugging
process is, or how to structure Terraform. All of that is loaded automatically. The human's job
is reduced to the things only a human can do: judgment, priorities, and course corrections.

---

## 4. Pre-History — The Terraform Provider (Mar 4–26)

> *This phase took place in a separate repo: `tf-provider-osd-google`, which became the
> upstream provider [`rh-mobb/terraform-provider-osd-google`](https://github.com/rh-mobb/terraform-provider-osd-google).
> On March 26, the CUDN routing work was extracted into the `osd-gcp-cudn-routing` repo
> you are reading now. The 45 sessions from that origin repo are available in Cursor history
> under the `tf-provider-osd-google` workspace.*

### The "One-Shot Provider" Story

Before the first session started, Paul had wanted a Terraform provider for OSD on GCP for a
long time. No one had built one. He decided to build it himself — and used the experience as a
proving ground for the joint engineering approach.

The setup was deliberate and methodical:

1. **Keel scaffolding first.** The repo started with keel rules already in place — `AGENTS.md`,
   `agent-behavior.md`, `base.md`, `terraform.md`, `go.md`. The agent had behavioral standards,
   code quality rules, and safety constraints from session one. No bootstrapping required.

2. **References folder as context injection.** Rather than relying on the agent's training data
   for OCM API knowledge (which would be outdated and incomplete), Paul cloned the authoritative
   sources directly into `references/`:
   - `references/terraform-provider-rhcs/` — Red Hat's official ROSA TF provider (structural template: resource schemas, state management, subsystem test patterns)
   - `references/ocm-sdk-go/` — The Go SDK used to call the OCM API (builder types, client methods, type aliases)
   - `references/ocm-cli/` — Source for the `ocm` CLI (field semantics, validation rules)
   - `references/OCM.json` — OpenAPI 3.0 spec for the OCM Cluster Management API (153 endpoints, exact field shapes and enums)
   - `references/terraform-google-osd/` — Terraform modules for the GCP-side infrastructure

   With these references available, the agent could look up the *exact* OCM API shape, cross-reference
   the RHCS provider's patterns, and produce correct code without hallucinating outdated API fields.

3. **One-shot execution.** With scaffolding in place and references loaded, the agent produced
   a working `osdgoogle_cluster` resource — WIF, PSC, OCM lifecycle, machine pools — in a
   remarkably compressed number of sessions. For a Terraform provider of this complexity
   (custom API integration, Workload Identity Federation, Private Service Connect networking,
   Terraform Registry publishing), this would normally be weeks of solo engineering work.

**Why this matters for the presentation:** The references-folder technique is reusable on any
project. The principle: *don't prompt the AI from memory — give it the authoritative source*.
Cloning the upstream SDK, provider, and API spec into a gitignored folder takes 10 minutes and
qualitatively changes what the agent can produce. The RHCS provider became the structural
template; the OCM SDK became the API reference; the OpenAPI spec became the ground truth for
field names and enums. The agent never had to guess.

This project was then the proving ground for that same approach applied to a harder problem:
not "build a provider" but "debug a production networking issue where the root cause is
unknown."

### Session: [I want to write a Terraform provider for OSD on GCP](d02cec6c-27fa-465f-a7d7-a1e7d5ff15ac)
**2026-03-04/05 · tf-provider-osd-google**

The true beginning of the project. Paul starts from scratch — keel scaffolding already
in place, references/ loaded with OCM SDK and RHCS provider source.

The agent produces a detailed implementation plan covering:
- WIF (Workload Identity Federation) support
- PSC (Private Service Connect) networking
- OCM API integration for cluster lifecycle
- Machine pool management

This pattern — propose plan, approve, execute — repeats throughout the project.

### External trigger: Slack message from Shreyans (Mar 18) · tf-provider-osd-google

While the provider was being built, Shreyans Mulkutkar (OSD GCP PM) sent Paul a Slack message
asking for help building the AWS Route Server equivalent on GCP. He had already asked Claude
to generate a GCP-specific implementation guide based on the ROSA BGP reference — a 1,126-line
document that had the right idea but wrong details (unnecessary per-zone subnets, inaccurate
Cloud Router architecture).

Paul: *"I've been planning on taking a run at it, just haven't had time yet."*
Shreyans: *"Would love to partner with you and learn along the way."*

This conversation crystallized the scope: this was a real customer need with PM support, not
just a personal engineering exercise. It also introduced the `msemanrh/rosa-bgp` reference
repo (Daniel Axelrod's work) which became `references/rosa-bgp/` in this project.

### Sessions: Provider iteration (Mar 9–16) · tf-provider-osd-google

Across ~25 sessions, the provider takes shape:
- `osdgoogle_cluster` resource with WIF + PSC support
- `osdgoogle_wif_config` data source
- `osdgoogle_cluster_admin` resource (htpasswd IDP + admin user)
- Machine pool resources with zone-aware scheduling
- `osdgoogle_machine_types` / `osdgoogle_regions` data sources
- Publishing to the Terraform Registry under `rh-mobb/osd-google`

Several real-world API constraints discovered and fixed:
- WIF pools can't be re-created (409 already exists) — soft-delete lifecycle handling
- Machine API uses `roles/iam.workloadIdentityUser` with `principal://` format (not `principalSet://`)
- Terraform two-pass apply needed: cluster creation before routing modules can read subnet outputs

### Session: [Plan for Terraform modules](8ff99c60-42d4-4b94-8321-2f92cbe5ab68)
**2026-03-12 · tf-provider-osd-google**

The provider matures from raw resources to reusable modules: `osd-wif-config`, `osd-cluster`,
and `osd-vpc`. This is when the idea of composable building blocks takes root — the same
module philosophy that later becomes `osd-hub-vpc`, `osd-spoke-vpc`, `osd-bgp-routing` in
this repo.

### Session: [First ILB routing example runs](4032398f-a620-4f79-a570-c94777dc035c)
**2026-03-23 · tf-provider-osd-google**

`make example.cluster_ilb_routing` — the first attempt to run the ILB-based CUDN routing
example inside the provider repo. The ILB approach had been designed as an alternative to BGP:
use a GCP Internal passthrough NLB as a VPC route next-hop to direct CUDN-bound traffic to
router worker nodes, without needing Cloud Router or BGP at all.

This is the start of what would eventually become `archive/cluster_ilb_routing/`.

### Session: [BGP feasibility assessment](50ce0921-5623-462f-b033-1e9b39078cf5)
**2026-03-24 · tf-provider-osd-google**

A pivotal session. Paul has a document called `references/propose-bgp-gcp-osd.md` — a proposal
for adapting the `rh-mobb/rosa-bgp` pattern (FRR + AWS Route Server) to GCP using NCC +
Cloud Router. He asks the agent to assess feasibility.

The agent reads the proposal, the full `rosa-bgp` reference repo, and GCP Cloud Router
documentation. Its conclusion is nuanced:

> **BGP is technically feasible but operationally complex.** The key blocker is `canIpForward`
> on OSD-managed GCE instances — the OSD installer sets it to `false` and there's no documented
> way to configure it pre-creation. The agent recommends the **ILB approach as more practical**:
> no Cloud Router, no NCC, no FRR, native GCP health-check failover, static routes only.

This is historically interesting: the agent recommended ILB over BGP, which is why ILB came
first. Paul accepted this and proceeded with ILB — then later decided BGP was the right
long-term architecture anyway.

Paul probes the alternatives:
- *"So to confirm, a GCP instance needs canIpForward set at the instance level as well as the OS?"* — Yes.
- *"Can you think of any alternatives that would give us a similar result?"* — ILB as next-hop (recommended), dedicated router VMs, GENEVE overlay extensions.
- *"OVN uses GENEVE protocol for its pod network — is there any way we could utilise that?"* — No practical path for external routing.

### Session: [ILB routing debugging](de9978b0-1c35-4717-a918-ecdd74321440)
**2026-03-25 · tf-provider-osd-google**

The ILB routing example hits its first real deployment errors: WIF pool already-exists conflicts,
two-pass apply ordering issues, missing worker instances on the first apply. These are debugged
and resolved, leaving the ILB path in a working state.

### Session: [The Split — extract to own repo](a45d463a-60e1-466b-87ca-95a6a9286545)
**2026-03-26 12:08 · tf-provider-osd-google**

**The founding moment of this repository.**

Paul: *"I have built out an example terraform and a module that shouldn't really be in this
repo. I want to move them to their own repo. I've created a blank git repo in
`/references/osd-gcp-cudn-routing`."*

The agent plans and executes the migration:
- `examples/cluster_ilb_routing` → `cluster_ilb_routing/` (no `/examples/` prefix)
- `modules/osd-ilb-routing` → `modules/osd-ilb-routing/`
- `AGENTS.md` and `.agents/` copied over
- Updated to reference upstream modules from `github.com/rh-mobb/terraform-provider-osd-google`
- Apache license, Makefile, README added
- CHANGELOG initialized

The session runs into issues mid-execution (complex file moves in a plan-then-execute session),
but the result is a standalone repository with a clean starting point.

**Four minutes later** (12:11), Paul opens the new repo in Cursor for the first time.

---

## 5. Week 1 — First Sessions in the New Repo (Mar 26)

### Session: [Explore and summarize this project](9e33647d-4c2b-4b00-bbb2-63cedcbeafcb)
**2026-03-26 12:11**

The first session in `osd-gcp-cudn-routing`. Paul hands the agent the freshly extracted repo
and asks it to explore and summarize. The agent reads the structure — the ILB module, the
`cluster_ilb_routing/` stack, the Makefile — and produces an initial summary.

At this point the repo had:
- A working ILB-based CUDN routing module (just migrated from the provider repo)
- No BGP module yet
- The `ILB-vs-BGP.md` comparison document as a planning artifact

### Session: [Plan BGP routing alongside ILB](f8a56dbf-2950-4467-bb8d-717a103131b2)
**2026-03-26 15:08**

Paul asks for a plan to implement BGP routing alongside the existing ILB approach. The agent
produces a comparison and a phased implementation plan. The ILB vs BGP trade-off document
(`ILB-vs-BGP.md`) begins to take shape.

### Session: [Review BGP example code](954eaf7f-7153-4536-8e03-9a3284cc368e)
**2026-03-26 15:22**

Code review session: syntax, formatting, DRYness, best practices for the early BGP Terraform.
Several issues found and fixed around the Cloud Router interface design.

### Session: [NCC spoke error during deploy](eea06b09-82b4-4399-8097-78860f73c7df)
**2026-03-26 15:55**

First real deployment attempt hits an error waiting for the NCC spoke to create. Root cause:
`canIpForward` not yet enabled on workers before attempting to add them to the NCC spoke.
GCP rejects the spoke if any linked instance has `canIpForward=false`.

> **KNOWLEDGE:** GCP API requires `canIpForward=true` on all instances before they can be
> added to an NCC Router Appliance spoke. This constraint is not obvious from the docs.

### Session: [Invalid BGP peer configuration](39ed2df0-5b4a-48c6-a260-d3b19a3c5969)
**2026-03-26 16:12**

Second error: `Error 400: Invalid resource usage` when creating the BGP peer on Cloud Router.
Root cause discovered: the Cloud Router was configured with one interface per worker with
mutual `redundant_interface` references — this fails with "does not have a redundant interface."
The correct architecture is exactly **two** interfaces (primary + HA pair), with every worker
peering to both.

This was an important architectural correction that shaped all subsequent work.

### Session: [First live BGP — no networking](0332c033-e047-41da-9155-36a5a0d5abd2)
**2026-03-26 17:05**

First successful `make bgp-apply`. Cluster is up, test pods deployed — but they can't reach
the echo VM. Paul shows the pod IP assignment and asks the agent to debug via the Kubernetes MCP.

The agent inspects `FRRConfiguration` CRs, checks BGP peer status, looks at OVN-K annotations
to find the actual CUDN IP (not in `status.podIPs` — it's in `k8s.ovn.org/pod-networks`).

Key early insight: pods were on non-router nodes. The router selection logic only picked 2-3
workers, and pods landed on workers without BGP sessions. This was the first signal that "all
workers need to be peers."

---

## 6. Week 2 — E2E Testing, Production Roadmap (Mar 27)

### Session: [Write shared e2e test](c44050d8-5b00-4d22-a3ee-75f49bb23492)
**2026-03-27 08:42**

Paul asks for a shared e2e test covering pod→VM ping + curl (IP verification) and VM→pod in
both directions. This produces `scripts/e2e-cudn-connectivity.sh` and a companion
`deploy-cudn-test-pods.sh`, both designed to work for both ILB and BGP stacks.

### Session: [Slack announcement](e1adbbf8-ac1d-4f5c-8fca-41dac18666d4)
**2026-03-27 08:47**

A brief but significant session: Paul asks for a short Slack message to introduce the project
to the team. This marks the transition from internal exploration to community visibility.

### Session: [Production roadmap](13e49839-068b-413f-b20b-2e7b926aad8b)
**2026-03-27 12:33**

Paul: *"I want to focus on the BGP example and figure out making it production ready. Come up
with a plan."* The agent proposes a phased production roadmap. Paul pushes back:

> *"the Production roadmap doc you're creating should include a list of tasks with checkboxes
> when they're done, it should group them and suggest when we should do a full e2e test before
> moving on so we don't get to a spot where we have too many variables, however a full e2e test
> including creation and destroy is about 2 hours, so we don't want to have to do it too many times."*

This produces `cluster_bgp_routing/PRODUCTION-ROADMAP.md` — a phased checklist with explicit
e2e test gates, acknowledging the 2-hour cost of a full cycle.

---

## 7. Week 3 — The Great Pivot: BGP Only (Mar 30–31)

### Session: [README quick start doesn't show controller](69020650-5bb1-4bcb-bf19-95dffc9ecb13)
**2026-03-30 11:04**

Paul notices the BGP README's quick start doesn't reference the new controller. Documentation
catch — the controller was being developed but docs hadn't been updated. Fixed.

### Session: [Controller branch kickoff](74bc0930-f4ec-4c3e-bd36-10d4c3fb7746)
**2026-03-30 16:28**

*"I created a branch for us to build a controller to take on the dynamic pieces of the
configuration like NCC spokes, BGP peers, and FRRConfiguration CRs."*

This is the moment the architecture crystallizes: Terraform handles static infrastructure;
a Kubernetes controller handles dynamic, per-node resources. The Python controller
(`controller/python/`) is started here.

### Session: [GCP IAM for the controller](6c1b6d7e-58f8-417e-8f1d-dc881b1ed00e)
**2026-03-30 16:59**

Paul asks whether the controller's GCP permissions are being created by Terraform. Yes — the
`modules/osd-bgp-controller-iam/` module creates a custom role, dedicated service account, and
Workload Identity Federation (WIF) binding. Several WIF-related bugs surface and are fixed here.

### Session: [Controller logs — debugging reconciliation](e4201491-36fc-4a81-80e0-705fb825603f)
**2026-03-31 10:13**

The Python controller is running in-cluster. Its logs show reconciliation starting but failing.
The agent reads the logs, identifies issues with `clear_peers` being a no-op (proto3 omitting
empty repeated fields), and switches from `PATCH` to `PUT` (`update()`) for the Cloud Router
BGP peers.

> **KNOWLEDGE:** `RoutersClient.patch()` with an empty `bgp_peers` list is silently ignored
> by the GCP API (proto3 omits empty repeated fields). Use `RoutersClient.update()` (PUT) to
> replace the full resource.

### Session: [Archive ILB — BGP only from here](84daac30-e233-4c73-9c69-c6a8386fe74e)
**2026-03-31 10:40**

**The Great Pivot.** Paul: *"Archive all the ILB stuff to an /archive folder. We're going to
exclusively focus on BGP from now on. Don't touch any BGP stuff."*

The agent moves the ILB module, cluster stack, comparison doc, and scripts to `archive/`.
All documentation is updated to present BGP as the only active path.

This was a decisive moment of project clarity — rather than maintaining two parallel approaches,
commit fully to the better one.

### Session: [Update production docs](81013c99-4c25-441c-9397-e35528b14961)
**2026-03-31 11:10**

Paul asks to update the production documents to reflect the current state after ILB archival.
`PRODUCTION.md` is consolidated, phased checklist updated, and the single root `PRODUCTION.md`
is created from the former cluster-specific one.

### Session: [Debugging BGP controller — FRR not merging](930539d6-730b-4667-8451-132af0d958de)
**2026-03-31 12:03**

BGP controller is running, but Cloud Router shows `numLearnedRoutes: 0` for the CUDN CIDR.
The agent finds the issue: `disableMP: true` was omitted from the FRR neighbors in the
controller output. When `disableMP` is false (default), OVN-K's `RouteAdvertisements` stays
in `Not Accepted` state with `DisableMP==false not supported`.

> **KNOWLEDGE:** FRRConfiguration neighbors must set `disableMP: true` on Cloud Router neighbors,
> otherwise OVN-K rejects the merge with its generated FRR CRs.

### Session: [Run debug-gcp-bgp script](becaf8ae-ddda-441d-8f90-3e0c405ece45)
**2026-03-31 13:18**

*"Run the debug-gcp-bgp script."* The agent runs `cluster_bgp_routing/scripts/debug-gcp-bgp.sh`
end-to-end via the Kubernetes MCP and reports back on Cloud Router peer status, NCC spoke state,
VPC routes, and firewall rules. A useful pattern established: run the diagnostic script, report
findings, then iterate.

### Session: [Implement Phase 1 of fix-bgp-ra.md](84411d8d-7666-4e8d-82a6-2530e513cb46)
**2026-03-31 13:42**

The `references/fix-bgp-ra.md` document had been written as a debugging plan. Phase 1 is
executed: set router node labels, apply `RouteAdvertisements` with the correct `nodeSelector`,
list `FRRConfiguration` CRs, run `debug-gcp-bgp.sh`.

An important discovery here: OVN-K validating admission **rejects** any non-empty `nodeSelector`
on `RouteAdvertisements` when `advertisements` includes `PodNetwork`. This closes off one
proposed workaround.

> **KNOWLEDGE (verified):** `RouteAdvertisements` with `PodNetwork` requires `nodeSelector: {}`.
> A non-empty selector is rejected at admission: *"If 'PodNetwork' is selected for advertisement,
> a 'nodeSelector' can't be specified as it needs to be advertised on all nodes."*

### Session: [Multi-AZ cluster, 6 nodes](2d394df9-bb1e-466c-a76f-4c8eed86fe78)
**2026-03-31 13:55**

Terraform updated to a multi-AZ cluster with 6 nodes in the default machine pool. This ensures
the e2e tests cover the realistic case where pods land on workers in different AZs.

### Session: [Controller vs configure-routing.sh — are they the same?](68a9e606-bbf3-41ff-b0fc-bcedba2367f8)
**2026-03-31 15:16**

Paul asks a sharp architectural question: *"Does the configure-routing script and the controller
do the same thing?"* The answer: partly. `configure-routing.sh` handles one-time OpenShift
setup (FRR enable, CUDN CR, RouteAdvertisements). The controller handles dynamic per-node
resources (canIpForward, NCC spoke membership, Cloud Router peers, FRRConfiguration CRs).
They are complementary, not redundant.

---

## 8. Week 4 — Architecture, Knowledge, and the Go Controller (Apr 2–9)

### Session: [KNOWLEDGE.md and ARCHITECTURE.md from scratch](edb3bf90-8e4f-4afd-b265-976f60c9bfcf)
**2026-04-02**

This is one of the most important sessions of the project. Paul: *"Based on everything we know
from the KNOWLEDGE.md and ARCHITECTURE.md documents as well as the documents found in
/references and any other research you need to do... write a dummies guide to OpenShift and BGP."*

The agent synthesizes everything — GCP constraints, OVN-K behavior, FRR architecture, Slack
thread insights — into a standalone educational guide (`docs/bgp-cudn-guide.md`) and alongside
that creates the canonical `ARCHITECTURE.md`.

A key follow-up correction from Paul: *"The guide should not reference implementation details
of this project, it's a standalone resource."* The agent revises to make it a genuinely
educational document independent of this repo.

This session also seeds the first `KNOWLEDGE.md` — the living assumptions/facts log.

### Session: [Slack thread: all-nodes-as-peers insight](38ade043-4210-487a-86c4-6b5738f41050)
**2026-04-03**

Paul brings in a Slack thread from Daniel Axelrod: pods on non-router nodes can't receive
traffic from outside the cluster. The solution: **all workers need to be BGP peers**, not just
a subset. The OVN overlay alone doesn't forward inbound traffic to pods on non-router nodes
the way initially assumed.

Paul also clones `references/rosa-bgp` for comparison at this point.

Paul then initiates the formal KNOWLEDGE.md with: *"Let's create a file called KNOWLEDGE.md
that lists all the things we know as factual... and all the things we think or assume... From
there we can build a definitive ARCHITECTURE.md."*

This is the birth of the confidence-scored assumptions system.

### Session: [Check docs are correct](0e145215-c304-4007-b33e-4be95f0ad506)
**2026-04-03**

Documentation audit — the quickstart and README are verified against the actual current state
of the codebase after several weeks of iteration.

### Session: [Where is the admin password set?](3a200375-cd86-4ead-baba-3950cc43ff83)
**2026-04-09**

A quick operational question: where in Terraform is the cluster admin password configured?
The agent traces through `osd-cluster` module outputs. Small session but representative of the
frequent "where does this live?" exploratory queries.

---

## 9. Week 5 — Operator / CRD Design, CI, and OpenShift Virt (Apr 13–16)

### Session: [Which make target runs the controller IAM?](a90f68de-4748-4048-848a-17bc65021c44)
**2026-04-13**

Operational question: `make iam.init` / `iam.apply` / `iam.destroy`. Leads to discovering
that the Makefile target naming had drifted from the README.

### Session: [Enable nested virt on both controllers](ddaa8ed8-a6a7-4eca-b0e6-ae3f3ed1031b)
**2026-04-13**

Both the Go and Python controllers get a new feature: `ENABLE_GCE_NESTED_VIRTUALIZATION` flag.
This enables `advancedMachineFeatures.enableNestedVirtualization` on worker GCE instances,
required for running OpenShift Virt on non-baremetal workers (unsupported by OSD, but useful
for lab topologies).

### Session: [make destroy works without a deployed cluster](aa9b8bf3-d3eb-4793-a95a-83495c9f28b0)
**2026-04-14**

`make destroy` was failing if the cluster wasn't deployed. Paul hits the error, reports it,
the agent fixes the script to handle absent Terraform outputs gracefully.

### Session: [Google soft-deletes WIF roles after a week](58b6a07b-013b-4f03-bdcd-f5322872cfb9)
**2026-04-14**

Paul surfaces a real operational problem: *"Google soft deletes some resources after about a
week, so if you go a week without using it, IAM custom roles are soft-deleted and you can't
apply."* The agent writes `scripts/gcp-undelete-wif-custom-roles.sh` and a Makefile target
`wif.undelete-soft-deleted-roles`, plus a detailed RFE document for the upstream provider.

### Session: [Self-signed TLS on cluster API](5be3be67-097b-4423-b303-d0fff67286ec)
**2026-04-14**

`oc login` failing because the API uses a self-signed cert. The agent updates `bgp-apply.sh`
to retry `oc login` with `--insecure-skip-tls-verify` as the default, with an override to
wait for a properly-signed cert.

### Session: [GitHub Actions for controller images](d40d80c6-98fa-49df-90b4-d6b5f79dce13)
**2026-04-14**

Paul: *"Can we have a GitHub Action to compile and release Docker images to GitHub Container
Registry for both the Python and Go controllers on merge to main?"*

`.github/workflows/publish-controller-images.yml` is created, building both containers and
pushing to `ghcr.io/rh-mobb/osd-gcp-cudn-routing/bgp-controller-go` and `-python` with
`latest`, branch, and `sha-<git>` tags.

### Session: [UBI Dockerfile for Go controller](cdd265c9-c6fa-4665-a37e-457d0b14ca43)
**2026-04-14**

Paul: *"We should use the Red Hat UBI for Golang for this."* The Dockerfile is updated to use
`registry.access.redhat.com/ubi9/ubi:latest` with `yum install go-toolset` (gives Go 1.25)
and `ubi9/ubi-minimal:9.5` as the runtime base with `ca-certificates`.

### Session: [Go controller image build fails in GitHub Actions](821a4100-8315-480e-a8ec-d8fb8a401f68)
**2026-04-14**

The Go controller GitHub Action fails on `buildx`. The agent diagnoses and fixes the issue in
the workflow file.

### Session: [Deploy Go controller from GHCR](7ca9a1ed-70b1-4a16-9c0d-a80e69c3825c)
**2026-04-15**

The Go controller is now published to GHCR. `make create` is updated to pull the prebuilt
image by default, with `make dev` for in-cluster binary builds during iteration.

### Session: [Debug BGP e2e failure via MCP](6f44639c-76d9-45a9-913f-8a91cb9012f2)
**2026-04-15**

*"Run debug-gcp-bgp.sh and tell me why the BGP e2e test is failing — both ping and curl."*

The agent runs the debug script, then Paul redirects: *"Debug the OpenShift side using the MCP
or oc CLI. Start by looking at the controller logs."*

The controller logs show reconciliation errors. The agent uses the Kubernetes MCP to look at
BGPRoutingConfig status, BGPRouter objects, and controller logs simultaneously — a good example
of using MCP for multi-resource diagnosis.

### Session: [Plan: Go controller → full operator with CRDs](824f589e-6aec-4d0c-9962-3ddf7db332a7)
**2026-04-15**

Paul: *"Come up with a plan to turn the Go controller into a full-on operator with CRDs to
configure it, and status."*

The agent proposes a design with two CRDs:
- `BGPRoutingConfig` (singleton `cluster`) — replaces ConfigMap/env-var surface
- `BGPRouter` (per elected node) — reports per-node health

Paul probes the design: *"How would the operator clean it up? Would we set spec to {} or have
a spec.enabled: true|false?"* The answer: a `spec.suspended` field for temporary disable, plus
a finalizer on `BGPRoutingConfig` for full teardown on deletion.

This design conversation is a good example of the AI generating a proposal and the human
iterating on the interface design.

### Session: [Live migration: what happens to BGP?](5b6d4a0e-a158-4628-9f26-f5c2e8884660)
**2026-04-16**

A conceptual question before coding: *"What happens to the BGP networking for an OpenShift Virt
VM when it is live migrated to another host? Will the networking work through the whole event,
or will it have a brief outage, and why?"*

The answer is nuanced: Layer2 CUDN with `ipam.lifecycle: Persistent` preserves the VM's IP.
Traffic to the VM's IP continues to arrive via ECMP at whatever BGP worker receives it, then
OVN Geneve-tunnels to the VM's actual node. There is no BGP reconvergence during migration
because the CUDN prefix is advertised by all workers — the IP just lives on a different node
after migration.

> **KNOWLEDGE:** Layer2 + `ipam.lifecycle: Persistent` is required for VM live migration.
> Default pod network traffic IS interrupted during live migration (this is a key motivator
> for CUDN).

### Session: [Operator permissions investigation](aa67fe54-6338-4cd8-8f4d-b181cc557d38)
**2026-04-16**

*"The operator is running but it seems to be having permissions issues. Dig into it using MCP.
Don't fix anything, just report back."*

The agent uses the Kubernetes MCP to read operator logs, then inspects GCP IAM bindings. The
issue: the transition from controller to operator added a new GCP API call that the existing
custom role didn't include. Specifically `networkconnectivity.operations.get` was missing —
the controller SA could create spokes but couldn't poll the long-running operation.

Paul: *"Do we fix this in Terraform?"* Yes — the custom role permissions are updated in
`modules/osd-bgp-controller-iam/`.

Paul follows up: *"Okay done, and it seems to be working, check the operator logs now."* The
agent confirms the operator is now reconciling successfully.

### Session: [Archive controllers, focus on operator](b7148c27-bb72-4818-b4ba-a460d5610e80)
**2026-04-16**

*"I've confirmed the operator works. Let's archive the controllers to an archive/ directory and
update all documentation to focus on the operator."*

Go and Python controllers moved to `archive/controller/`. All READMEs, `ARCHITECTURE.md`,
`KNOWLEDGE.md`, `PRODUCTION.md`, and `AGENTS.md` updated.

This is the second major architectural consolidation: first ILB→BGP only, now
controller→operator only.

### Session: [Deploy OpenShift Virt script](68b3745a-0cd3-4387-86a2-c83f470719df)
**2026-04-16**

Paul wants a script and Makefile target to deploy OpenShift Virt with RWX storage. The agent
reads the GCP storage guide, creates `scripts/deploy-openshift-virt.sh` handling:
- Hyperdisk pool creation with correct IOPS/throughput
- StorageClass + VolumeSnapshotClass
- CNV OLM subscription with proper wait logic
- HyperConverged CR

Several API quirks discovered: `--performance-provisioning-type=advanced` is required for
Hyperdisk pool creation; the OLM wait must check `status.currentCSV` not just `installedCSV`.

The script gets stuck — Paul pastes the error and the agent diagnoses that it's waiting on the
wrong condition. Fixed.

### Session: [Does publish-operator-image action exist?](9b69502b-45b4-4b76-b823-47d5877a7089)
**2026-04-16**

Quick audit: does the GitHub Action for the operator image publish on merge to main? The agent
checks `.github/workflows/` — yes, it was added correctly.

### Session: [How does make destroy clean up the routing CR?](45322e73-bdfa-4f3b-9270-6e0462ede313)
**2026-04-16**

Design question: `make destroy` must clean up the `BGPRoutingConfig` CR so the finalizer runs
(triggering Cloud Router peer removal, NCC spoke cleanup, FRR CR deletion) before Terraform
destroys the static infra. The script is updated to delete the CR and wait for finalizer
completion before proceeding.

### Session: [Detailed operations guide](08dfd7e3-8ae6-456b-b591-3896621f09f9)
**2026-04-16**

*"We have the quickstart, but we should probably have a more detailed guide that shows all of
the steps."* Produces `docs/bgp-cudn-guide.md` — a comprehensive walkthrough from zero to
running e2e tests including manual verification steps.

---

## 10. Week 6 — Bare Metal, Live Migration, and the Internet Egress Mystery (Apr 17–21)

### Session: [Bare metal + multi-AZ secondary pool](6a6fa23c-5f3f-49b8-8e30-1b98a299d5f6)
**2026-04-17**

*"We're now deploying two bare metal nodes in a single AZ as a secondary machine pool."*

Bare metal workers are required for OpenShift Virt KVM. `cluster_bgp_routing` is updated with
`create_baremetal_worker_pool = true` (default) provisioning `c3-standard-192-metal` instances.
The storage scripts are updated to use the correct zone for Hyperdisk pools.

### Session: [Add debugging guidance to AGENTS.md](5b3fa748-2408-4876-8d30-8cf277f7d78a)
**2026-04-17**

Paul: *"Add to AGENTS.md that when we're debugging we should use the tools available to us —
MCPs, CLIs, etc. — to investigate before attempting to fix something blindly."*

This becomes a standing rule in `AGENTS.md`: *"When investigating failures or unexpected
behavior, agents should use the tools available in the environment (MCP integrations, CLIs,
cluster/API clients, logs, tests, and repository search) to gather evidence before changing
code or configuration."*

### Session: [Cluster upgrade blocked by BGP](d6a2d694-815b-4a2b-87aa-37792cf7ac56)
**2026-04-18**

A new operational problem surfaces: *"When we try to upgrade a cluster or do something else
that requires replacing a node we get: BGP preventing drain on GCP."*

GCP rejects instance deletion while a Cloud Router BGP peer still references it. The operator
removes peers only after the Kubernetes Node disappears — but Machine API deletes the GCE
instance first.

The suggested solution is an OpenShift Machine `preTerminate` lifecycle hook. Paul: *"Is what
we're planning the same thing?"* Yes, and the plan is written to `TODO.md` for future
implementation. The fix is non-trivial: a node finalizer won't work (the hook fires too late);
the correct approach is watching `Machine` objects for `DeletionTimestamp` and removing BGP
peers before the GCE instance is deleted.

### Session: [VM e2e test with live migration](6c89f518-7864-40c5-bd22-3e112a75cfdd)
**2026-04-20**

Paul wants a comprehensive VM e2e test:
1. Deploy CentOS Stream 9 VM from template
2. Deploy icanhazip clone
3. Ping and curl the VM
4. Live migrate to another host, ping/curl again
5. Run a sustained ping **during** live migration, report packet loss
6. Same for curl

This produces `scripts/e2e-virt-live-migration.sh` — a thorough test harness with cloud-init
configuration, SSH key generation, VM readiness waiting, and the three-phase migration test.

> **KNOWLEDGE:** `ipam.lifecycle: Persistent` preserves IPs across live migration.
> Traffic via the pod default network (masquerade) IS interrupted; CUDN traffic is not.

### Session: [virt.destroy-storage should kill VMs first](79cd415b-6aee-4b81-b320-6b9d80e93798)
**2026-04-20**

*"Does make virt.destroy-storage destroy all VMs first? If not it should."*

`scripts/destroy-openshift-virt-storage.sh` is updated to delete all VMs and wait for VMI
teardown before attempting to delete PVCs (otherwise GCP disks are still attached and the
delete fails with a "storage pool is already being used by disk" error).

### Session: [VMs can't curl google — but pods can](e50dcfcf-164c-4aa0-8e23-8a9b2c6b3e12)
**2026-04-21 07:03**

**The beginning of the most technically interesting investigation of the project.**

*"I have two VMs in the cudn1 namespace, one with bridge, one with masq networking. Neither of
them can curl google, but the netshoot-cudn pod in the same namespace can curl google."*

The agent uses MCP to inspect VM state, routes, and network configuration. Paul shows the
console output — the masq VM can ping `8.8.8.8`, the bridge VM cannot. This divergence looks
significant.

> ⚠️ **HUMAN IN THE LOOP:** Paul provides live console output from both VMs, crucial evidence
> the agent couldn't obtain directly from the MCP.

The agent hypothesizes: masquerade binding SNATs to the worker VPC IP, giving the VM a path
through Cloud NAT. The bridge VM's CUDN IP isn't registered on the NIC, so Cloud NAT drops it.

Paul: *"Can we run the netshoot image as a DaemonSet on all worker nodes and then test each
one for curl google.com?"* This confirms pods on worker nodes can reach the internet — the
issue is specific to CUDN IPs.

A tentative hypothesis: `routingViaHost: true` + host nftables MASQUERADE might solve it.

### Session: [Knowledge management system](23bd8e0a-cdc8-449f-b0ec-b065d780b1a1)
**2026-04-21 09:29**

A significant meta-session about the project's knowledge management:

*"I want to manage our knowledge better. As we learn things or make assumptions we should
document them in KNOWLEDGE.md along with a confidence score. This should work alongside our
documentation, not replace them. This will help us retain context between agents."*

This formalizes the confidence scoring system that had been evolving:
- **95–100%:** Verified (cite source)
- **70–94%:** Strong inference
- **40–69%:** Working hypothesis
- **Under 40%:** Speculative

`AGENTS.md` is updated with mandatory rules for when to update `KNOWLEDGE.md`.

### Session: [NAT gateway plan discussion](a8c7ddd0-7f7d-4c47-ab2b-e3a63a384f06)
**2026-04-21 15:02**

A critical direction-setting conversation. The agent had drafted `docs/nat-gateway.md` as a
plan involving secondary VPC subnet ranges to get Cloud NAT to accept CUDN sources.

Paul probes: *"Rather than creating a secondary VPC subnet for 10.100.0.0/16 to try to get
Cloud NAT to know about our CUDN... could we use an alias range? Or would that give us the
same behaviour?"*

**HUMAN IN THE LOOP — Major course correction:**
After the agent explains the trade-offs, Paul makes a decisive call: *"Do nothing."*
Then follows up: *"We have no control over tags for the managed resources, and OSD on GCP
doesn't create any useful tags, it uses labels, so I think using tags to determine static
routes is going to be a problem."*

This shut down the NAT gateway approach entirely and was exactly right — the later investigation
would reveal the issue wasn't even about Cloud NAT at all.

---

## 11. Week 7 — The Smoking Gun (Apr 22–23)

### Session: [Two VM virt e2e test](2364bc8f-e260-4946-bef5-e6c1c4be25cf)
**2026-04-22**

*"I want to go back to having the virt e2e test create two VMs, the l2bridge one as well as a
masq one."*

During this session an interesting observation: the masq VM can ping `8.8.8.8`, the bridge VM
cannot. This reinforces the earlier masquerade-vs-bridge hypothesis.

**HUMAN IN THE LOOP:** Paul spots the agent heading toward an EgressIP discussion:
*"Stop talking about EgressIP — we're not using it."* Direct course correction. The agent
refocuses on the actual investigation path.

### Session: [Clean up network — gcloud command error](0d755e38-c81a-4fdd-b5b2-52911a4bc42a)
**2026-04-23 06:35**

Network teardown for a new cluster deploy. Paul hits a wrong gcloud command suggestion from
the agent:

> *"You need to validate commands in the docs before giving them to me."*
>
> ```
> ERROR: (gcloud.compute) Invalid choice: 'firewalls'.
> Maybe you meant: gcloud compute firewall-rules
> ```

A direct and fair correction. The agent should have used `gcloud compute firewall-rules`,
not `gcloud compute firewalls`. Documented as a process improvement: always validate CLI
syntax before presenting to the user.

### Session: [Main debug session — internet egress](1b1d3247-26ad-4c80-95b8-e001bab35ce1)
**2026-04-23 08:00**

A new cluster (`cz-demo1`) is deployed. The virtctl console fix is resolved (version mismatch
→ need `v1.7.2` virtctl). SSH to VMs is established via the `virt-ssh.sh` helper.

**The `virtctl ssh` problem:** `virtctl ssh` does not work for VMs on CUDN networks — it relies
on the default pod network for its tunnel. Daniel Axelrod surfaced this in Slack, noting his
pattern for accessing CUDN VMs on ROSA: `kubectl exec` into a `netshoot` pod on the same
namespace, then SSH from there using the VM's CUDN IP. This exec-then-SSH pattern became the
`virt-ssh.sh` helper script:

```bash
# netshoot jump pod → VM's CUDN IP
kubectl exec -n <ns> <netshoot-pod> -- ssh -i /tmp/key fedora@<cudn-vm-ip>
```

Without this, the AI agent had no practical way to get a shell inside a running CUDN VM to
run connectivity tests. Daniel's pattern unlocked the entire VM-level debugging workflow.

The groundwork is laid for the big debugging session to follow.

### Session: [ROSA BGP comparison](a0bf5116-cfab-408c-af6b-8934c0e61f49)
**2026-04-23 09:01**

Paul notices the ROSA BGP reference uses `binding.name: l2bridge` (the newer binding plugin
style) while our virt-e2e script used `bridge: {}` (the classic style). He asks: are we
accidentally comparing different networking modes?

The agent explains: our two VMs deliberately test different modes (`bridge: {}` vs
`masquerade: {}`). Paul: *"Can we update ours to use the newer binding like rosa-bgp? Just to
remove any potential differences or red herrings."*

The `bridge: {}` VM is updated to `binding.name: l2bridge`.

Paul also asks for a networking test plan. This produces `docs/networking-validation-test-plan.md`
and `scripts/networking-validation-test.sh` — a comprehensive test harness integrating both
CUDN and virt e2e tests.

### Session: [BRIEFING.md + tmux MCP + tcpdump + Wireshark](4f95da36-6283-4bb9-9160-1b7d5a59d568)
**2026-04-23 12:51**

**The central investigation session of the project.**

Paul brings in a Slack conversation from Daniel Axelrod about ROSA BGP behavior, including a
thread with the OCP Networking team about VM live migration and connectivity flapping.

The agent is given a rich set of context from the ROSA deployment. Paul mentions Daniel has
long-running pings to Google from CUDN VMs on ROSA that succeed, but on GCP they fail ~80%
of the time.

**Key intervention — Paul asks the right question:**

> *"If all traffic goes back to one node on ROSA and gets forwarded via OVN-K, then it suggests
> that they don't have the same untrusted non-RFC-1918 traffic problem?"*

This is the hypothesis that eventually cracks the case open. If ROSA's Route Server uses
single-active routing (only one worker as the next-hop), then internet return packets always
go to that one worker — and if OVN-K is the issue, it should still fail on ROSA.

But Daniel reports 100% success on ROSA. So either the OVN-K hypothesis is wrong, or ROSA
has something that bypasses the problem.

**Novel tool: tmux MCP.**

The agent installs and configures the tmux MCP. A `cudn-debug` session is created with
5 panes — one per BGP worker. The same tcpdump command is fanned out to all nodes
simultaneously:

```bash
oc debug node/<worker> -- tcpdump -i br-ex -c 100 host 10.100.0.7
```

Results: **0 packets on every interface** (`br-ex`, `ens4`, `any`, `ovn-k8s-mp1`).

> **KNOWLEDGE (verified):** OVS kernel datapath is invisible to standard tcpdump/libpcap.
> `ens4` is registered as an OVS port. OVS's `rx_handler` intercepts packets before `AF_PACKET`.
> Traffic entering the OVS datapath never reaches the Linux socket layer.

**Packet capture from the hub NAT VM.**

Unable to observe drops on workers, the agent captures instead on the hub NAT VM's GRE tunnel
interface (`gif0`) — where DNAT'd return packets are visible before re-entering the spoke.

The capture shows: **all 50 outbound SYNs arrive at the NAT VM**, and **all 50 SYN-ACKs are
correctly DNAT'd and forwarded back**. The NAT VM is not the failure point.

The Wireshark MCP analyzes the PCAP file. Failed connections show 2 SYN retransmissions — the
return packet arrived at the wrong worker and was dropped. Partially recovered connections show
1 retransmission then success — the second SYN-ACK happened to hit the correct worker.

**Original hypothesis: OVN-K `ct_state=!est` drops.**
Consistent with the pattern. But not directly proven.

Paul asks: *"In /references/rosa-pcap I have a ton of packet captures from AWS. See if you can
use it to help validate the issue/fix on ROSA."*

**The ROSA comparison.**

The agent in a parallel session (55a3d9d1) conducts a thorough investigation on the ROSA cluster
— running identical curl tests, inspecting OVN ACLs, comparing OVS flows, checking conntrack.

Finding: both clusters run **OCP 4.21.9** with **identical OVS br-ex flows** and **identical
OVN ACLs**. OVN-K cannot be the differentiator.

But ROSA has 100% internet egress success. GCP has ~22%.

**THE SMOKING GUN:**

Paul (via the agent): *"Is there any fundamental GCP firewall rule difference?"*

The agent inspects GCP VPC firewall rules for the spoke VPC. The `cz-demo1-hub-to-spoke-return`
rule allows inbound from `src=10.20.0.0/24` (the hub NAT VMs' subnet) — but internet return
traffic has `src=34.x.x.x`. There is **no rule** allowing arbitrary internet source IPs inbound
to spoke workers.

Meanwhile on ROSA: `rosa-virt-allow-from-ALL-sg` — a security group attached to every BGP
baremetal worker with a single rule: `proto=-1, src=0.0.0.0/0`. **Allow everything.**

> **This is exactly what allows ROSA's 100% success rate, and what GCP is missing.**

With GCP's stateful firewall, an internet return packet (`src=34.x.x.x`) arriving at a worker
that **did not originate the connection** has no matching tracked session. The firewall silently
drops it.

The ~22% success rate on GCP matches ECMP theory: with 5 BGP workers (10 equal-cost paths via
2 Cloud Router interfaces each), only ~1/5 connections return to the originating worker and
survive the stateful firewall.

**The fix:**

```hcl
resource "google_compute_firewall" "cudn_egress_return" {
  name    = "${var.cluster_name}-cudn-egress-return"
  network = google_compute_network.spoke_vpc.self_link

  allow { protocol = "all" }
  source_ranges = ["0.0.0.0/0"]
  priority      = 800
}
```

Applied to the spoke VPC. Result: **50/50 = 100% internet egress immediately.**

The fix is codified as `enable_cudn_egress_return = true` (default false) in
`modules/osd-spoke-vpc`.

**Canvas artifacts from this session:**

Paul: *"How do we share this canvas? Can we turn it into an HTML file or something?"*

The agent generates two standalone HTML files:
- `docs/cudn-ecmp-drop-flow.html` — animated five-step failure chain diagram
- `docs/cudn-rfc1918-success-flow.html` — working RFC-1918 path for contrast

Paul: *"Create a report about everything we did in this session, including things like installing
and switching to the tmux MCP."*

This produces `docs/cudn-internet-egress-report-2026-04-23.md` — a comprehensive investigation
report that Paul can share internally.

### Session: [ROSA egress testing](55a3d9d1-a355-4ee0-ac16-887da3a44aff)
**2026-04-23 13:16**

The agent runs a parallel investigation on the ROSA/AWS cluster using `docs/agent-prompt-rosa-egress-testing.md`
— a detailed prompt that Paul wrote to give a fresh agent session all the context it needed.

This session:
- Deploys two test VMs on ROSA
- Runs the same 50-curl internet egress test
- Inspects OVS flows and OVN ACLs for comparison with GCP
- Discovers `rosa-virt-allow-from-ALL-sg`
- Produces `ROSA_KNOWLEDGE.md` and `docs/debug-internet-egress-rosa-2026-04-23.md`

> **Correction of the original hypothesis:** Earlier analysis attributed GCP drops to OVN-K
> `ct_state=!est` inside the OVS pipeline. This was an inference from the retransmission
> pattern — plausible but never directly observed. The cross-cluster comparison proves OVN-K
> is not the differentiator: both clusters have identical flows and ACLs. The drop is at the
> GCP VPC firewall layer, not inside OVN-K.

---

## 12. Novel Techniques and Tools

### 11.1 Confidence-Scored Knowledge Base

`KNOWLEDGE.md` is updated throughout the project with facts, assumptions, and hypotheses — each
with a confidence score. This allows:
- Later sessions to pick up exactly where previous ones left off
- Distinguishing verified behavior from working hypotheses
- Tracking when hypotheses are proved or disproved

When the OVN-K hypothesis was disproved, it was marked **RESOLVED** with the correction noted.
This is the kind of institutional memory that typically lives only in people's heads.

### 11.2 tmux MCP for Parallel Node Debugging

The origin of this technique is a direct line from problem to solution. The persistent
frustration in this project was getting an AI agent to interact with VMs, particularly
VMs hidden behind `virtctl` on a CUDN network. While discussing this problem, Daniel Axelrod
pointed to [Terminus-2](https://www.harborframework.com/docs/agents/terminus-2) — Harbor's
reference agent implementation that uses a **single interactive tmux session** as its entire
interface to a terminal environment. Terminus-2's design philosophy: one tool (tmux), full
flexibility to reach anything reachable from a terminal.

Paul saw that and went looking for a tmux MCP for Cursor. One existed. Installed same day.

The tmux MCP then turned out to solve two problems at once:

1. **Agent → VM access:** persistent terminal sessions the agent could navigate freely
2. **Parallel node debugging:** a named session (`cudn-debug`) with 5 panes — one per BGP
   worker — allowing the same `tcpdump` command to fan out to all nodes simultaneously

The parallel debugging use is what produced the "all interfaces = 0 packets" finding across
all five workers at once, rather than sequentially.

**The meta-lesson:** The path from problem to tool ran through an adjacent research area
(AI agent architecture), not the obvious debugging toolbox. Paul's habit of cross-referencing
across domains — and asking "does something like that exist for Cursor?" — is a human judgment
call the AI cannot make on its own.

### 11.3 Wireshark MCP + PCAP Analysis

The Wireshark MCP allowed programmatic analysis of the hub NAT VM capture without opening a GUI.
The agent could query: "how many connections had retransmissions?" and "what's the breakdown of
success vs timeout?" This turned 213 raw packets into a structured finding.

The PCAP files are preserved in `references/pcap-2026-04-23/` with a README documenting the
environment, filters, and key conclusions — so any future engineer (or AI) can re-analyze them.

### 11.4 Canvas → HTML for Shareable Diagrams

The Canvas skill generated interactive React-based flow diagrams that were then exported as
standalone HTML files. This means:
- No special tooling needed to view them
- Can be embedded in Confluence, email, or presentations
- Self-contained with animations

Future presentation work can build directly on these HTML artifacts.

### 11.5 Agent Prompt Engineering

Paul wrote `docs/agent-prompt-rosa-egress-testing.md` — a 462-line document that serves as a
complete briefing for an AI agent to pick up the ROSA investigation with full context. This
represents a sophisticated use of AI: human-authored prompt engineering to bootstrap a fresh
agent session with institutional memory.

The practice of writing explicit agent prompts (rather than relying on ambient context) is a
reusable pattern for delegating complex investigations.

### 11.6 References Folder as Context Injection

The `references/` pattern appears in both repos in this project, but for different purposes
and at very different scales.

**In `tf-provider-osd-google`: authoritative source injection**

Before writing a single line of provider code, Paul cloned the full authoritative context
into `references/`:
- `references/terraform-provider-rhcs/` — RHCS provider as structural template
- `references/ocm-sdk-go/` — exact Go types and builder patterns the provider would use
- `references/ocm-cli/` — field semantics and validation rules from the official CLI
- `references/OCM.json` — OpenAPI 3.0 spec for the OCM API (153 endpoints, exact field shapes)
- `references/terraform-google-osd/` — GCP-side infrastructure modules

With these available, the agent could produce correct code on the first attempt: exact OCM
API field names from the spec, correct builder patterns from the SDK, correct resource
structure from the RHCS template. No hallucinated API fields. No outdated endpoint paths.
A working, published Terraform provider in a compressed timeframe.

**The technique:** *don't prompt the AI from memory — give it the authoritative source.*
10 minutes of `git clone` transforms the quality of what the agent can produce.

**In `osd-gcp-cudn-routing`: artifact and evidence store**

The same folder serves a different purpose here — storing external artifacts that inform
the project without cluttering the repo:
- `references/rosa-bgp/` — full clone of Daniel Axelrod's ROSA reference for comparison
- `references/pcap-2026-04-23/` — PCAP files from the internet egress investigation
- `references/rosa-pcap/` — ROSA comparison captures
- OCP 4.21 documentation PDFs for exact admission behavior and version constraints

Both uses share the same principle: keep external context *near* the code, gitignored so it
doesn't pollute the repo, available so the agent never has to guess.

### 11.7 BRIEFING.md as Executive Summary

`BRIEFING.md` is a living executive summary of the internet egress findings, written for a
technical but non-expert audience. It was updated iteratively as the investigation progressed
and the original OVN-K hypothesis was overturned.

The pattern of maintaining a "briefing document" separate from detailed technical logs is
valuable for stakeholder communication and on-boarding.

### 11.8 AI Scaffolding — Encoding Behavior, Not Just Prompts

The most durable engineering work in this project may not be the Terraform modules or the Go
operator — it's the scaffolding that shaped how the AI behaved at every session. That
scaffolding comes from **[Project Keel](https://github.com/paulczar/keel)**, Paul's own open
source project for standardized AI coding rules. The rules in `.agents/rules/keel/` are
authored in a central Hugo-powered CMS and synced into projects — meaning every project Paul
works on inherits the lessons from every previous one.

The key insight: **AI agents are only as disciplined as their environment forces them to be.**
Without explicit rules, an agent will:
- Attempt plausible fixes without evidence
- Skip formatting and validation
- Forget API constraints it encountered two sessions ago
- Take destructive actions without confirming scope
- Never self-review before responding

The scaffolding in this project solved each of these failure modes deliberately:

| Failure mode | Scaffolding solution |
|---|---|
| Speculative edits without evidence | `AGENTS.md` debugging section: "gather evidence before changing code" |
| Unreviewed output | `AGENTS.md` self-review: "What would a senior engineer critique?" |
| Repeated GCP API mistakes | `AGENTS.md` GCP constraints section: hard-won rules encoded permanently |
| Unsafe destructive actions | `agent-behavior.md`: read-before-write, dry-run, blast radius, confirmation |
| Poor Terraform quality | `terraform.md`: `fmt`/`validate`/`tflint` after every change, `for_each` over `count` |
| Stale architectural assumptions | `ARCHITECTURE.md` + `KNOWLEDGE.md` with confidence scores |
| Lost institutional memory between sessions | `KNOWLEDGE.md` updated every session by rule |

The result is an agent that a senior engineer would feel comfortable handing a ticket to. Not
because the AI is "smart enough," but because the environment makes it disciplined.

**The presentation angle**: show an unscaffolded agent response vs. a scaffolded one on the same
prompt. The difference is dramatic: one produces confident but wrong Terraform; the other says
"before I write this, let me check the Context7 docs for `google_compute_route` with
`next_hop_ilb` because there's a known constraint..."

---

## 13. Human in the Loop: Moments That Mattered

The AI could propose, implement, and debug. But the human made the calls that mattered.
These are the moments where Paul's intervention changed the direction of the project.

A recurring theme: the AI is good at executing within a defined direction; the human is
essential for **setting** that direction, knowing when it's wrong, and asking the question
that cracks the problem open.

### 13.0 "Use BGP Anyway" (Mar 24 — tf-provider-osd-google)

On March 24, Paul asked the agent to assess whether BGP routing was feasible for OSD on GCP.
The agent's recommendation: **use ILB instead** — simpler, no Cloud Router, native GCP health
checks, well-documented. BGP was described as technically feasible but operationally complex.

Paul proceeded with ILB first — but eventually reversed course and committed to BGP exclusively
(the March 31 "Great Pivot"). The agent's ILB recommendation wasn't wrong; it was a reasonable
tactical answer. But Paul's longer-term judgment was that BGP was the architecturally correct
answer for stable pod IP reachability across VPC peering, live migration, and scale.

**What this shows:** The AI can assess feasibility and trade-offs, but the human makes the
strategic call about which path to invest in. The agent gave an excellent tactical recommendation;
the human had a better architectural vision.

### 13.1 "Do Nothing" (Apr 21)

When the agent proposed a complex Cloud NAT workaround involving secondary subnet ranges and
alias IPs, Paul said: *"Do nothing."* This was the right call — the problem wasn't Cloud NAT
at all, and the workaround would have been a false path.

**What this prevented:** days of work on a `docs/nat-gateway.md` implementation that would
never have worked.

### 13.2 "Stop Talking About EgressIP" (Apr 22)

The agent kept circling back to EgressIP as a potential solution. Paul: *"Stop talking about
EgressIP — we're not using it."* Clear boundary setting. EgressIP for Layer2 UDN is documented
as unsupported in OCP 4.21, and the agent was burning cycles on a dead end.

### 13.3 "Validate Commands Before Giving Them to Me" (Apr 23)

After an incorrect `gcloud compute firewalls` command (should be `gcloud compute firewall-rules`),
Paul gave direct feedback. This pushed the agent to be more careful about CLI syntax validation.

### 13.4 The ROSA Comparison Hypothesis (Apr 23)

Paul's question — *"If all traffic goes back to one node on ROSA and gets forwarded via OVN-K,
then it suggests they don't have the same untrusted non-RFC-1918 traffic problem?"* — is what
led to the cross-cluster comparison that cracked the investigation open.

The agent had been investigating the GCP side in isolation. Paul's insight was to question the
fundamental assumption by comparing with a working system.

### 13.5 "Is It a GCP Stateful Firewall?" (Apr 23)

The question that revealed the smoking gun. Rather than accepting the OVN-K `ct.est` hypothesis,
Paul asked the agent to look at the GCP VPC firewall rules. The agent found `cz-demo1-hub-to-spoke-return`
only covered `src=10.20.0.0/24`, and no rule covered internet-sourced IPs.

**What if Paul hadn't asked this?** The investigation might have continued trying to instrument
OVN-K internals with eBPF or OVS mirrors — which would eventually reveal the same truth, but
much later.

### 13.6 Archiving ILB (Mar 31)

The decisive move to drop ILB and go BGP-only. The agent had been maintaining both paths.
Paul made the call: archive ILB, commit to BGP. This simplified everything that followed.

### 13.7 `routingViaHost: true` — Fast Feedback Loop (Apr)

A brief but instructive moment: the agent suggested setting `routingViaHost: true` as a
potential fix for a routing issue. Paul tried it. CUDN routing broke entirely. Paul reported
back immediately; the agent reverted and documented the constraint.

The story here is the speed of the loop, not the mistake. Human tries it → confirms it's wrong
→ reports back → agent updates KNOWLEDGE.md → future sessions never suggest it again. The whole
cycle took minutes, not hours. This is what the fast feedback loop between human and AI looks
like in practice: the human de-risks by testing, the AI de-risks by updating its knowledge.

### 13.8 "Use the MCP, Don't Fix Blindly" (Apr 17)

After a few sessions where the agent proposed fixes before fully investigating, Paul added
an explicit rule to `AGENTS.md`: use MCP tools to investigate before changing code. This
improved the quality of subsequent debugging sessions significantly.

### 13.8 Daniel Axelrod — The External Human in the Loop

Daniel Axelrod (Red Hat, building the equivalent AWS/ROSA BGP implementation) deserves
explicit recognition as an external "human in the loop" who influenced this project at three
critical points — not through formal review, but through Slack conversations Paul brought into
the agent's context.

**1. All workers as BGP peers (Apr 3)**

Daniel shared a finding from his ROSA work: if only a subset of workers are BGP peers, pods on
non-router nodes can't receive inbound traffic. The OVN overlay alone doesn't solve this.
This architectural insight — *every worker must be a BGP peer* — changed the fundamental
design from a "dedicated router pool" model to "all workers as peers." It saved weeks of
investigating why traffic was reaching some pods but not others.

**2. `virtctl ssh` doesn't work for CUDN VMs (Apr 23)**

Daniel mentioned his pattern for accessing CUDN VMs on ROSA: `kubectl exec` into a `netshoot`
pod, then SSH to the VM's CUDN IP from there. `virtctl ssh` relies on the default pod network
and fails for VMs on user-defined networks. This became the `virt-ssh.sh` helper and was the
only practical way to get a shell inside a CUDN VM for connectivity testing. Without it, the
entire VM-level debugging workflow would have been blocked.

**3. The Terminus-2 reference → tmux MCP (Apr 23)**

While discussing the problem of getting an AI agent to interact with CUDN VMs behind `virtctl`,
Daniel linked to [Terminus-2](https://www.harborframework.com/docs/agents/terminus-2) — a
research agent that uses a single tmux session as its sole interface to any terminal
environment. Paul saw the link, looked for a tmux MCP for Cursor, found one, and installed it
the same day. The tmux MCP then solved both the original VM-access problem and the parallel
node debugging problem, directly enabling the "0 packets on every interface" finding across
all five workers simultaneously.

**The pattern:** Daniel wasn't giving Paul direct advice — he was just narrating his own work.
Paul's habit of reading those narrations carefully and asking "can I do something with that?"
is a skill that amplified the quality of the AI's work. The AI can only use context it's given;
the human decides what context is worth surfacing.

---

## 14. What Was Built

A production-quality reference implementation for CUDN BGP routing on OSD/GCP:

### Infrastructure (Terraform)
- `modules/osd-hub-vpc` — Hub VPC with NAT VM MIG, internal NLB, nftables MASQUERADE
- `modules/osd-spoke-vpc` — Spoke VPC with OSD cluster subnets, VPC peering, `0.0.0.0/0 → hub ILB`
- `modules/osd-bgp-routing` — NCC hub, Cloud Router, Cloud Router interfaces (HA pair)
- `modules/osd-bgp-controller-iam` — GCP service account, custom role, WIF binding
- `cluster_bgp_routing/` — Complete reference deployment: hub + spoke VPCs + OSD cluster + BGP

### Operator (Go)
- `operator/` — CRD-based Kubernetes operator (`routing.osd.redhat.com/v1alpha1`)
  - `BGPRoutingConfig` — singleton cluster-scoped CR for all routing config
  - `BGPRouter` — per-node status CR with per-condition health reporting
  - Finalizer-based cleanup, `spec.suspended` for temporary disable
  - `observedGeneration` tracking, printer columns
  - `canIpForward` reconciliation, NCC spoke management (multi-spoke for >8 workers)
  - Cloud Router BGP peer management
  - Per-node `FRRConfiguration` CR creation

### Scripts
- `scripts/bgp-apply.sh` — full orchestration: WIF → Terraform → oc login → configure-routing
- `scripts/bgp-deploy-operator-incluster.sh` — operator IAM, CRDs, RBAC, BGPRoutingConfig, rollout
- `scripts/configure-routing.sh` — one-time OpenShift setup (FRR enable, CUDN, RouteAdvertisements)
- `scripts/e2e-cudn-connectivity.sh` — CUDN e2e: pod↔VM ping + curl with body verification
- `scripts/e2e-virt-live-migration.sh` — VM e2e: deploy, migrate, measure packet loss
- `scripts/deploy-openshift-virt.sh` — OpenShift Virtualization + Hyperdisk storage
- `scripts/destroy-openshift-virt-storage.sh` — teardown with VM cleanup ordering
- `scripts/networking-validation-test.sh` — combined CUDN + virt test harness
- `scripts/virt-ssh.sh` — SSH to CUDN VMs via netshoot jump pod
- `scripts/debug-gcp-bgp.sh` — GCP BGP diagnostic script
- `scripts/gcp-undelete-wif-custom-roles.sh` — handles GCP soft-deleted WIF roles

### Documentation
- `ARCHITECTURE.md` — canonical architecture document
- `KNOWLEDGE.md` — confidence-scored facts and assumptions (65+ entries)
- `ROSA_KNOWLEDGE.md` — AWS/ROSA-specific findings
- `BRIEFING.md` — executive summary of internet egress findings
- `TODO.md` — Machine preTerminate hook implementation plan
- `docs/bgp-cudn-guide.md` — comprehensive operations guide
- `docs/networking-validation-test-plan.md` — test plan for all connectivity scenarios
- `docs/debug-internet-egress-2026-04-23.md` — full debug session log
- `docs/debug-internet-egress-rosa-2026-04-23.md` — ROSA comparison session log
- `docs/cudn-internet-egress-report-2026-04-23.md` — investigation summary report
- `docs/cudn-ecmp-drop-flow.html` — animated packet flow diagram (failure case)
- `docs/cudn-rfc1918-success-flow.html` — animated packet flow diagram (success case)
- `docs/agent-prompt-rosa-egress-testing.md` — agent bootstrap prompt for ROSA investigation
- `references/pcap-2026-04-23/README.md` — PCAP index and analysis

### CI
- `.github/workflows/publish-operator-image.yml` — operator image to GHCR on merge to main

---

## 15. Open Threads and Future Work

### 14.1 Machine preTerminate Hook (TODO.md)

When a worker is replaced during an OSD upgrade, GCP rejects the instance deletion while a
Cloud Router BGP peer still references it. The fix requires watching `Machine` objects for
`DeletionTimestamp` and removing BGP peers before the GCE delete is attempted.

Design documented in `TODO.md`. Not yet implemented.

### 14.2 OKEP-5094 — Layer2TransitRouter

The current internet egress limitation (CUDN pods cannot reliably reach the internet) is
a fundamental architecture constraint in OCP 4.21. OKEP-5094 introduces EgressIP support
for Layer2 primary UDN via a transit router topology.

- Upstream PRs merged: September–November 2025
- Target release: OCP 4.22 (not GA as of April 2026)
- OSD/ROSA availability: not confirmed

### 14.3 Dedicated Routing Nodes

Today all non-infra workers are BGP peers. A future direction is a separate node pool used
only for forwarding and BGP, so cluster scaling doesn't directly imply NCC spoke and peer churn.
Noted in `README.md` as intent, no implementation timeline.

### 14.4 AWS/ROSA CUDN Internet Egress

The ROSA internet egress investigation confirms that ROSA/AWS CUDN egress works (100%) due to
`rosa-virt-allow-from-ALL-sg`. The GCP fix (`cudn_egress_return` firewall rule) is analogous.

The BRIEFING.md prediction that ROSA would also fail was incorrect — the VPC firewall layer,
not OVN-K, was the differentiator.

However, **ROSA with Route Server single-active FIB** means all internet return traffic goes
to one worker (the active BGP next-hop). If VMs are on non-BGP-router nodes, they rely on
OVN overlay forwarding from the active node to reach them. This path is confirmed working
(Layer2 broadcast domain handles it), but a VM on the same AZ as the active BGP node has
better direct routing.

---

## 16. Presentation Outline

> **Status: Built.** The presentation is implemented as a Slidev project at `presentation/` in this repo.
> Run `cd presentation && npm run dev` to view it locally. It deploys automatically to GitHub Pages
> on push to `main` via `.github/workflows/deploy-presentation.yml`.
>
> Slidev features used: Red Hat brand theme (`styles/index.css`), auto-registered Vue components
> (`RhTwoColumn`, `RhTable`, `SpectrumDiagram`, `PacketFlowEcmp`, `PacketFlowSuccess`, `Timeline`),
> Mermaid diagrams, and CSS-animated SVG packet flow components (replacing the standalone HTML artifacts).
>
> **Speaker notes:** All ~50 slides have speaker notes (HTML comment blocks), written in first person
> as speaking guidance for Paul. View them in Slidev presenter mode (`npm run dev`, press `p`).
>
> **Image generation pending:** 4 slides have `<!-- IMAGE REQUEST: -->` comments for Gemini/AI-generated
> images (TF provider fuel diagram, Keel layer model, context degradation cliff graph, tmux 5-pane mockup).

**Title:** Joint Engineering with AI: How We Built and Debugged a Production BGP Routing System

**Audience:** Technical practitioners; developers, platform engineers, and SREs familiar with Kubernetes and/or cloud infrastructure

**Format:** ~40 minutes, ~50 slides (no live demo required — animated diagrams are embedded)

**Central thesis:** AI is most powerful not as a code generator ("vibe coding") but as a joint
engineering partner — one that investigates before guessing, accumulates institutional memory,
and forces you to articulate your thinking. The human's role shifts from writing code to
providing judgment, domain authority, and asking the right questions at the right time. The
foundation that makes this possible is good scaffolding: [Project Keel](https://github.com/paulczar/keel)
is the open source tool built to provide exactly that.

---

**Context / Stage Setting (~5 min) — slides added 2026-04-23**

These slides were added after the initial outline to ground the audience in the problem domain
before the engineering story begins.

- **What Is OpenShift Dedicated on GCP?** — brief explainer with Mermaid architecture diagram
  (customer VPC, worker nodes, control plane, Cloud NAT, GCP LB). Two-column layout.
- **The Customer Problem** — ASCII before/after: SNATed worker IP vs direct CUDN VM IP.
  Three pain points: no stable routable IP, breaks on live migration, can't address VMs directly.
- **Why This Hadn't Been Done on GCP** — `RhTable` comparing on-prem (done ✓), AWS ROSA (demoed ✓),
  GCP OSD (not done ✗). Note on NCC Router Appliance as the non-obvious missing piece.
- **One More Thing: Paul Doesn't Know BGP** — "I can barely spell BGP" quote. Two-column split
  of what Paul brought (platform knowledge, live cluster) vs what the AI brought (BGP expertise,
  GCP NCC API, reading OCM OpenAPI specs). Sets up the human/AI collaboration frame.

---

**Section 1 — What Is Joint Engineering? (5 min)**

This section sets the frame for everything that follows. It answers: *what kind of AI use are
we talking about?*

- **Vibe coding vs. joint engineering**
  - Vibe coding: generate code, paste it in, hope it works, iterate blindly
  - Joint engineering: shared context, accumulated knowledge, evidence-based debugging, mutual accountability
- **The spectrum of AI use**
  - *Code autocomplete* → *chat assistant* → *agent with tools* → **joint engineering partner**
- **What changes when you treat AI as a partner, not a tool**
  - The AI maintains state across sessions (via KNOWLEDGE.md, AGENTS.md, ARCHITECTURE.md)
  - The AI investigates before guessing (debugging section of AGENTS.md)
  - The AI reviews its own work before showing it to you (self-review section)
  - You provide what only a human can: judgment, priorities, domain authority, the right question
- **What this talk is**
  - A 7-week case study: one human + one AI, building a production BGP routing system for
    OpenShift Virtualization on GCP from scratch — including a deep multi-day debugging
    investigation with packet captures, live cluster inspection, and a final smoking-gun discovery
  - *Not* a success story about AI being smart. A story about building an environment where
    AI can be disciplined.
- *Slide: the spectrum diagram — vibe coding on the left, joint engineering on the right*
- *Slide: "what the human does" vs "what the AI does" — a two-column table*

**Section 2 — The Origin Story (5 min)**
- **The TF provider: a story unto itself**
  - Paul had wanted a Terraform provider for OSD on GCP for a long time. No one had built one.
    He decided to build it himself — using it as a proving ground for joint engineering.
  - Setup: keel scaffolding first. Then `references/`: RHCS TF provider source, OCM SDK,
    OCM CLI, OCM OpenAPI spec (153 endpoints), GCP OSD modules. All cloned locally.
  - Result: a working, published Terraform provider in a compressed number of sessions —
    for something that would normally be weeks of solo engineering
  - **The principle proven:** don't prompt from memory — give the agent the authoritative source
  - *Slide: references/ folder contents → what each enabled the agent to do*
- **The BGP routing project grows from the provider**
  - Shreyans (OSD GCP PM) + Claude generate a 1,126-line GCP BGP implementation guide (Mar 18)
    - Right idea, fundamental architectural errors — treated GCP like AWS
    - Missing: NCC, `canIpForward`, `disable-connected-check`, hub/spoke VPC, operator
    - Paul: "I've been planning on taking a run at it"
  - Same pattern: keel scaffolding + references/ folder + joint engineering
- Claude = scoping tool; Cursor = production engineering tool
- *Slide: before/after comparison table (Claude draft vs what was built)*
- *Key framing: Claude confirmed the approach was sound; Cursor made it correct*

**Section 3 — Scaffolding the Agent (5 min)**
- The difference between a helpful AI and a disciplined engineer is the scaffolding
- **[Project Keel](https://github.com/paulczar/keel)** — Paul's open source tool for standardized
  AI coding rules ([tech.paulcz.net/keel](https://tech.paulcz.net/keel/))
  - Implements the [AGENTS.md open standard](https://agentmdx.com) (Linux Foundation, supported by
    Codex, Copilot, Jules, Cursor)
  - Hugo-powered CMS: author rules once as Markdown, sync to any project in any AI tool format
  - Rules live in Git, are reviewed via PRs, have full audit history
  - *The meta-story: Paul built the scaffolding tool, then used it to prove the concept here*
- `AGENTS.md` in this project: the agent's constitution — project identity, responsibilities, hard rules
  - *Highlight: the debugging section ("evidence before edits")*
  - *Highlight: the self-review section ("what would a senior engineer critique?")*
  - *Highlight: the GCP constraints section — institutional memory encoded as rules, never repeated*
- Keel rules: layered, glob-scoped coding standards
  - `agent-behavior.md` (always): destructive action confirmation, blast radius, read-before-write
  - `terraform.md` (`.tf` files only): `fmt`/`validate`, `for_each` over `count`, no `-auto-approve`
  - *Key design: rules activate only for relevant file types — context stays focused, not noisy*
- **When scaffolding is missing: the `depends_on` footgun**
  - `depends_on = [module.spoke]` deferred all data sources to apply-time, breaking `for_each` key
    resolution at plan — a common human mistake, but a "bug" when an AI produces it
  - Root cause: no rule enforcing "prefer implicit dependencies; never `depends_on` on modules"
  - Fix: the constraint was written into `AGENTS.md` and `terraform.md` — never repeated
  - *Key framing: AI coding mistakes are often scaffolding gaps, not model failures. Fix the rules, not the model.*
- **The GCP "things it doesn't tell you" list** — encoded in AGENTS.md once discovered:
  - `self_link` vs `ip_address` for cross-VPC ILB next hop (API rejects self_link silently)
  - `SHARED_LOADBALANCER_VIP` address purpose incompatible with `next_hop_ilb` routes
  - `nftables.service` on RHEL 9 loads `/etc/sysconfig/nftables.conf`, not `/etc/nftables.conf`
    — NAT VMs started cleanly but with empty rulesets; quickly caught by human+AI working together
  - *Framing: each of these is a one-time mistake that becomes a permanent rule for all future sessions*
- `ARCHITECTURE.md` vs `KNOWLEDGE.md`: stable design vs living evidence
- *Slide: "What happens without scaffolding" vs "with scaffolding" — same prompt, different behavior*
- *Slide: the Keel rule layering model — keel defaults → org standards → local overrides*
- *Key framing: you're not prompting an AI — you're engineering an environment. Keel is the tool for that.*

**Setup Aside — Practical Joint Engineering Toolchain**

*A 2-minute sidebar based on ["How to Make Claude Less Dumb"](https://www.youtube.com/watch?v=-O6MEtleOdA) — practical setup advice that applies beyond Claude Code:*

- **The context degradation problem**: the longer a session runs, the more the AI "forgets" earlier
  constraints and starts hallucinating. Context degrades noticeably past ~50% of the context window.
  - Rule: don't let context exceed 50%. Start a fresh session rather than continuing a poisoned one.
  - Tool: `npx cc-status-line@latest` — adds a status bar showing model, context %, session cost
- **Sub-agents for large tasks**: instead of doing everything in one long context, dispatch sub-agents
  (coders, reviewers, testers) that each run in their own context window and report back. Superpowers
  plugin enables the brainstorm → write-plan → execute-plan workflow exactly this way.
- **The workflow that scales**: brainstorm (explores context, proposes approaches) → write-plan
  (detailed implementation plan) → execute-plan (sub-agents execute in isolation)
- **Skills for repetitive tasks**: identify things you do often and encode them as skills — the
  same principle as keel rules, but for workflows rather than code standards
- *Slide: context % graph — the 50% cliff where quality degrades*
- *This talk is itself an example: many of the 110 sessions deliberately started fresh to avoid
  context poisoning*

**Section 4 — How We Worked (5 min)**
- 110 sessions, 7 weeks, two repos, one human + one AI
- Started by building a Terraform provider from scratch; routing was an emergent sub-project
- The tools: Kubernetes MCP, Context7, tmux MCP, Wireshark MCP, Canvas
- The discipline: investigate before fixing; update KNOWLEDGE.md; validate commands
- *Timeline graphic: sessions mapped to milestones across both repos*
- *The ILB-first / BGP-wins story: agent recommended the safe path, human took the right one*
- **CI from the start**: GitHub Actions + UBI Dockerfile — not an afterthought, part of the
  engineering discipline from the beginning; shows what "joint engineering" looks like end-to-end

**Section 5 — The Knowledge System (5 min)**
- KNOWLEDGE.md: confidence scores, hypothesis tracking, RESOLVED status
- Why this matters: context persists between sessions; hypotheses are falsifiable
- Example: the OVN-K `ct.est` hypothesis — written, tested, corrected
- **The bridge-vs-masquerade false lead**: early testing showed masquerade VMs appeared to work
  while bridge VMs failed. Turned out to be coincidental ECMP hits — not a structural difference.
  KNOWLEDGE.md documented the correction, so future sessions couldn't rediscover the false lead.
  This is the "KNOWLEDGE.md saved us" story: a confident-looking data point that was simply wrong.
- *Table: hypothesis lifecycle from assumption to verified/invalidated*

**Section 6 — Novel Debugging Techniques (10 min)**
- tmux MCP: fanning tcpdump across 5 workers simultaneously
  - *Screenshot/demo: tmux session with 5 panes*
- Wireshark MCP: querying PCAPs programmatically
  - *Screenshot: Wireshark output with retransmission filter*
- The invisible OVS datapath: why tcpdump shows nothing on OVN-K workers
  - *Diagram: OVS rx_handler vs AF_PACKET*
- Canvas → HTML: animated packet flow diagrams as shareable artifacts
  - *Live HTML demo: cudn-ecmp-drop-flow.html*

**Section 7 — The Investigation: Finding the Smoking Gun (10 min)**
- The symptom: ~22% internet egress success from CUDN VMs on GCP
- First hypothesis: OVN-K `ct_state=!est` drops (consistent with data)
- The ROSA comparison: identical OCP version, identical OVN flows, 100% success
  - *Paul's question: "If ROSA uses single-active routing, why does it still work?"*
- The cross-cluster inspection: ROSA has `rosa-virt-allow-from-ALL-sg`
- Paul's question that cracked it: "Is it the GCP stateful firewall?"
- The answer: `cz-demo1-hub-to-spoke-return` only covers `src=10.20.0.0/24`
- The fix: one Terraform resource, one VPC-wide `allow 0.0.0.0/0` rule
- Verification: 50/50 = 100% immediately
- *Diagram: before/after firewall rule flow*

**Section 8 — Human in the Loop (5 min)**
- "Do nothing" — stopping a false path
- "Stop talking about EgressIP" — boundary setting
- "Is it the GCP stateful firewall?" — the right question at the right time
- "Validate commands before giving them to me" — quality feedback
- The ROSA comparison hypothesis — domain judgment that AI couldn't supply
- **Daniel Axelrod: the external human in the loop**
  - Slack narration → all-workers-as-peers architectural change
  - Slack narration → exec-then-SSH unlocked VM debugging
  - Terminus-2 link (tmux-as-agent-interface) → tmux MCP installed same day
- *Pattern: the AI uses context you give it; the human decides what context is worth surfacing*
- *Pattern: expert practitioners drop high-signal hints in casual conversation — learn to hear them*

**Section 9 — What We Produced (3 min)**
- Complete production reference (Terraform + Operator + Scripts + Docs)
- CI pipeline, automated testing, comprehensive knowledge base
- Shareable artifacts: HTML diagrams, PCAP analysis, BRIEFING.md
- This presentation — co-generated, built on the project's own artifacts

**Section 10 — Takeaways: Joint Engineering in Practice (2 min)**
- **Joint engineering, not vibe coding** — shared context, evidence-based debugging, mutual accountability
- **Scaffold first** — `AGENTS.md` + keel rules + `ARCHITECTURE.md` before writing any code; this is what separates a disciplined partner from an autocomplete
- **Give the AI access to the systems it's reasoning about** — MCP tools (Kubernetes, tmux, Wireshark, Context7) are force multipliers; without them the agent is blind
- **Manage knowledge deliberately** — `KNOWLEDGE.md` with confidence scores retained context and institutional memory across 65 sessions; hypotheses are falsifiable and tracked
- **The human's irreplaceable role** — judgment, direction, domain authority, cross-domain pattern recognition, asking the right question at the right time
- **Patterns to steal**: scaffolding stack · tmux MCP for parallel debugging · canvas→HTML artifacts · exec-then-SSH for CUDN VMs · agent prompt as a handoff document · cross-referencing adjacent research areas (Terminus-2 → tmux MCP)
- *Closing slide: "You're not prompting an AI. You're engineering an environment — and working inside it together."*

---

## 17. Followup Questions

*All items resolved 2026-04-23. Decisions recorded below.*

| # | Topic | Decision | Where integrated |
|---|-------|----------|-----------------|
| 1 | `routingViaHost: true` experiment | Include as fast-feedback-loop example | Section 13.7 (Human in the Loop) |
| 2 | nftables.conf path bug | Include — human+AI assumption correction, quickly resolved together | Presentation Section 3 (Scaffolding / GCP constraints list) |
| 3 | `depends_on` Terraform footgun | Include — "AI mistakes are scaffolding gaps, not model failures" | Presentation Section 3 (Scaffolding) |
| 4 | `self_link` vs `ip_address` GCP bug | Include in "things GCP doesn't tell you" list | Presentation Section 3 (Scaffolding / GCP constraints list) |
| 5 | `ebgpMultiHop` rejection | Skip — too in-the-weeds | — |
| 6 | BGP dummies guide | Keep in repo; mention as shareable artifact in "What Was Built" | Section 14 already covers `docs/bgp-cudn-guide.md` |
| 7 | Daniel Axelrod / Slack threads | Complete — three contributions fully documented in Section 13.9 | Section 13.9 |
| 8 | Bridge vs masquerade false lead | Include — "KNOWLEDGE.md saved us" story | Presentation Section 5 (Knowledge System) |
| 9 | GitHub Actions + UBI Dockerfile | Include — shows full engineering discipline, not just debugging | Presentation Section 4 (How We Worked) |
| 10 | "All workers as peers" discovery | Already covered via Daniel's section — no dedicated slide needed | Section 13.9 |
| 11 | Self-review section origin | Leave as-is — project-specific AGENTS.md addition is fine | — |

---

---

## 18. References and Further Reading

- **[Project Keel](https://github.com/paulczar/keel)** ([tech.paulcz.net/keel](https://tech.paulcz.net/keel/)) —
  Paul's open source project for standardized AI coding rules. Implements the AGENTS.md open standard
  as a Hugo-powered CMS. Write rules once as Markdown; sync them to any project in any AI tool format
  (Cursor, Claude Code, GitHub Copilot, Windsurf, Codex). The keel rules in this project's
  `.agents/rules/keel/` directory are sourced from here. Install as a Cursor plugin with one command:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/paulczar/keel/main/scripts/install-plugin.sh | bash -s -- --clone https://github.com/paulczar/keel
  ```

- **["How to Make Claude Less Dumb"](https://www.youtube.com/watch?v=-O6MEtleOdA)** — practical Claude Code
  setup guide covering context management (50% rule), the Superpowers brainstorm→write-plan→execute-plan
  workflow, sub-agents for large tasks, sequential thinking MCP, Context7, and building custom skills.
  Primary reference for the "Setup Aside" in the presentation.

- **[Terminus-2](https://www.harborframework.com/docs/agents/terminus-2)** — Harbor's reference agent
  implementation that uses a single tmux session as its entire interface. Mentioned by Daniel Axelrod
  as a reference for AI agent VM access; led directly to the tmux MCP adoption in this project.

- **[`msemanrh/rosa-bgp`](https://github.com/msemanrh/rosa-bgp)** — Daniel Axelrod's ROSA/AWS BGP
  routing reference implementation. The AWS counterpart to this project; cloned into `references/rosa-bgp/`
  for comparison. Its architecture (all workers as BGP peers) directly influenced this project.

- **`docs/initial-design-spec-by-claude.md`** — The original 1,126-line implementation guide generated by
  Claude at Shreyans Mulkutkar's request (Mar 18). Preserved as a comparison point illustrating the
  difference between AI-for-scoping and AI-for-production-engineering.

- **`docs/agent-prompt-rosa-egress-testing.md`** — 462-line agent briefing document, an example of
  human-authored prompt engineering to hand off a complex investigation to a fresh AI session.

- **`references/pcap-2026-04-23/README.md`** — PCAP analysis from the internet egress investigation,
  documenting capture methodology, key Wireshark filters, and findings.

- **[ambient-code/reference — Self-Review Reflection pattern](https://github.com/ambient-code/reference/blob/main/docs/patterns/self-review-reflection.md)** —
  Source of the self-review section in `AGENTS.md` ("what would a senior engineer critique?"). The
  [ambient-code project](https://ambient-code.ai) ([github.com/ambient-code](https://github.com/ambient-code))
  is a broader resource on AI-first engineering practices, treating engineers as "code shepherds"
  who orchestrate agentic teams rather than writing code line by line. Recommended reading alongside
  this project as a complementary framing for joint engineering.

---

*This document was co-generated by Paul Czarkowski and Cursor AI (Sonnet) on 2026-04-23,
synthesizing 65 chat sessions, all repository commits, KNOWLEDGE.md, CHANGELOG.md, debug
logs, packet captures, and canvas artifacts. It is intended as the foundation for a
conference/talk presentation on engineering with AI in complex infrastructure contexts.*
