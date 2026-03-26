---
description: "Universal behavioral safety rules for AI agents interacting with live systems"
globs: ["**/*"]
alwaysApply: true
---

# Agent Behavior

Universal safety and behavioral standards for AI agents operating against live systems — clusters, registries, databases, CLIs, and APIs.

## Destructive Actions

- Never delete, drop, uninstall, or overwrite resources without explicit user confirmation
- Before performing a destructive action, explain exactly what will be affected (resource names, namespace, count)
- Treat `delete`, `destroy`, `drop`, `rm`, `uninstall`, `purge`, `reset`, and `replace` as destructive verbs requiring confirmation

## MCP Tools over CLI

- Prefer MCP tool integrations when available — they provide structured input/output and are easier to audit
- Fall back to CLI only when no MCP tool exists for the operation
- When using CLI, prefer JSON or machine-readable output formats for parsing (`--output json`, `-o json`)

## Read Before Write

- Always run read/list/get operations to understand current state before mutating anything
- Verify the resource exists (or doesn't) before creating, updating, or deleting it
- Summarize what you found before proposing changes

## Dry Run

- Use `--dry-run`, `--whatif`, `plan`, `diff`, or equivalent preview flags before applying changes when the tool supports them
- Show the user the preview output and get confirmation before applying
- If the tool has no dry-run mode, describe the intended change in detail before executing

## Environment Awareness

- Verify which environment (dev, staging, production) you're operating in before running commands
- Confirm with the user if the target environment is unclear or appears to be production
- Check context, project, subscription, or profile settings to determine the active environment
- Never assume you're in a safe-to-mutate environment

## Credentials and Secrets

- Never print, log, or store credentials, tokens, or secrets in output
- Never pass secrets as CLI arguments — use environment variables, stdin, or file references
- If a command output contains secrets, redact them before displaying
- Never commit credentials to version control

## Blast Radius

- Prefer targeted operations over broad ones — `delete pod/x` not `delete pods --all`
- Scope operations to specific namespaces, projects, or resources
- Avoid wildcard selectors and `--all` flags unless the user explicitly requests them
- When operating on multiple resources, list them first and confirm the set

## Reversibility

- Understand how to undo an action before taking it
- Prefer reversible operations — `kubectl apply` over `kubectl create`, `helm upgrade --install` over `helm install`
- Warn the user when an action cannot be easily undone
- For irreversible operations, require explicit confirmation and document the rollback path if one exists
- Do not create `.backup`, `.bak`, or similar backup files — use git and editor history (e.g. Cursor's `.history/`) for reversibility
