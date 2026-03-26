---
description: "Best practices and rules for Terraform infrastructure as code"
globs: ["**/*.tf", "**/*.tfvars", "**/*.tfvars.json"]
alwaysApply: false
---

# Terraform Standards

Standards for Terraform infrastructure as code.

## Tooling

- Run `terraform fmt` on all files — no exceptions
- Run `terraform validate` before every plan
- Use `tflint` with provider-specific rulesets for static analysis
- Use `checkov` or `trivy` for security scanning

## File Organization

Two common conventions exist. Pick one per project and be consistent — an org or local rule can enforce which.

**Standard convention** — community default, familiar to most contributors:

```
├── main.tf             # Primary resources
├── variables.tf        # Variable definitions
├── outputs.tf          # Output values
├── providers.tf        # Provider and backend configuration
├── data.tf             # Data sources
├── locals.tf           # Local values
└── versions.tf         # Required versions and providers
```

**Numbered convention** — explicit ordering, clearer at a glance in large roots:

```
├── 00-providers.tf     # Provider and backend configuration
├── 01-variables.tf     # Variable definitions
├── 02-data.tf          # Data sources
├── 03-network.tf       # Network resources
├── 04-compute.tf       # Compute resources
├── 05-storage.tf       # Storage resources
├── 20-outputs.tf       # Output values (always last)
```

The numbered convention works well when a root module has many resource files and the reading order matters. The standard convention is simpler for small modules. Either way:

- Use lowercase with underscores: `database_cluster.tf` not `db.tf`
- Group by resource type or function, not by provider
- Keep related resources in the same file

## Provider Configuration

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

- Pin provider versions with `~>` to allow patch updates only
- Specify `required_version` to prevent running with incompatible Terraform versions
- Commit `.terraform.lock.hcl` for reproducible builds across environments

## Variables and Outputs

```hcl
variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "Cluster name must contain only lowercase letters, numbers, and hyphens."
  }
}
```

- Always include `description` for all variables and outputs
- Use `sensitive = true` for secrets — Terraform redacts them from plan output
- Use `validation` blocks to catch bad input before plan/apply
- Use `nullable = true` with `default = null` for optional variables

## Resource Naming

- Use descriptive logical names: `azurerm_virtual_network.main` not `azurerm_virtual_network.vnet1`
- Lowercase with underscores — follow Terraform conventions
- Use `this` for the primary resource when a module creates one resource of a given type

## Iteration and Conditionals

- Prefer `for_each` over `count` — resource addresses are stable when items are added/removed
- Use `count` only for simple boolean toggles (`count = var.enabled ? 1 : 0`)
- Avoid complex `for` expressions in resource blocks — extract to `locals`

## Dependencies

- Prefer implicit dependencies (resource references) over `depends_on`
- When `depends_on` is necessary, add a comment explaining why
- Never use `depends_on` on modules unless there's a hidden side-effect dependency

## Lifecycle Rules

- Use `create_before_destroy` for resources that can't tolerate downtime during replacement
- Use `prevent_destroy` sparingly — only on truly irreplaceable resources (databases, storage)
- Use `ignore_changes` for attributes managed outside Terraform (e.g., autoscaler-managed replica counts)

## Error Handling

Use `precondition` and `postcondition` blocks for clear, actionable error messages:

```hcl
resource "azurerm_linux_virtual_machine" "app" {
  # ...

  lifecycle {
    precondition {
      condition     = var.vm_size != "Standard_B1s" || var.environment == "dev"
      error_message = "Standard_B1s is only allowed in dev. Current environment: ${var.environment}"
    }
  }
}
```

Use `check` blocks for continuous validation of infrastructure assumptions:

```hcl
check "api_health" {
  data "http" "api" {
    url = "https://${azurerm_linux_virtual_machine.app.public_ip_address}/health"
  }

  assert {
    condition     = data.http.api.status_code == 200
    error_message = "API health check failed after deploy"
  }
}
```

## State Management

- Always use remote state with locking for shared environments
- Never commit state files — add `*.tfstate` and `*.tfstate.*` to `.gitignore`
- Use separate state files (not just workspaces) for full environment isolation
- Use `terraform state list` to audit what Terraform manages

## Refactoring

Use `moved` blocks to rename or restructure resources without destroying and recreating:

```hcl
moved {
  from = azurerm_resource_group.old_name
  to   = azurerm_resource_group.new_name
}
```

Use `import` blocks (Terraform 1.5+) to bring existing infrastructure under management:

```hcl
import {
  to = azurerm_resource_group.main
  id = "/subscriptions/.../resourceGroups/my-rg"
}
```

## Modules

```
modules/my-module/
├── main.tf
├── variables.tf
├── outputs.tf
└── versions.tf
```

- Pin module versions from registries: `version = "~> 5.0"`
- Keep module interfaces small and focused
- Document all inputs and outputs with `description`
- Use consistent variable naming across modules

## Security

Terraform-specific security practices (general secrets/least-privilege guidance is in the base rule):

- Mark sensitive variables and outputs: `sensitive = true`
- Use secret management integration (Vault, cloud secret managers) rather than `TF_VAR_` environment variables for production secrets
- Run `checkov` or `trivy` in CI to catch misconfigurations before apply
- Document checkov skips inline with the reason:

```hcl
resource "azurerm_storage_account" "public" {
  # checkov:skip=CKV_AZURE_35:Intentionally public for static web content
  # ...
}
```

## Resource Tagging

Define a common tag map in `locals` and apply it consistently:

```hcl
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }
}
```

Use provider-level default tagging when available (e.g., AWS `default_tags`, Azure `default_tags`) to ensure no resource is missed.

## Agent Behavior

Behavioral guidance for AI agents writing or modifying Terraform configurations:

- Always run `terraform fmt` and `terraform validate` after modifying `.tf` files
- Run `terraform plan` and present the output before applying — never run `terraform apply` without user confirmation
- Never use `-auto-approve` unless explicitly instructed
- Before `terraform import` or `terraform state rm`, show the current state and explain the impact
- When generating new resources, include all required arguments — do not rely on provider defaults for security-relevant settings (e.g., encryption, public access)
- Prefer `moved` blocks over manual state manipulation for renames and refactors

## .gitignore

```gitignore
# Terraform
*.tfstate
*.tfstate.*
.terraform/
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
*.tfvars
!example.tfvars
```

Note: **commit** `.terraform.lock.hcl` — it ensures reproducible provider versions across environments.
