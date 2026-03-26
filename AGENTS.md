# AGENTS.md

This repository contains Terraform modules and a reference deployment for ILB-based CUDN routing on OpenShift Dedicated (OSD) for Google Cloud. The [terraform-provider-osd-google](https://github.com/rh-mobb/terraform-provider-osd-google) repo provides the `osdgoogle` provider, VPC/cluster modules, and WIF configuration.

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
- **Update the changelog** — For user-facing changes, add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) using Added, Changed, Deprecated, Removed, Fixed, or Security.

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
