---
description: "YAML formatting and structure conventions"
globs: ["**/*.yaml", "**/*.yml"]
alwaysApply: false
---

# YAML Standards

Standards for YAML file formatting and structure.

## Tooling

- Lint with `yamllint` using a project-level `.yamllint.yml` config
- For Kubernetes YAML, validate schemas with `kubeconform` or `kubeval`

## Formatting

- Use 2-space indentation — never tabs
- Use `.yaml` extension (not `.yml`) for consistency
- Keep lines under 120 characters
- Use block style for multi-line strings (`|` for literal, `>` for folded)
- End files with a single newline

## Structure

- Start documents with `---`
- Use consistent key ordering within similar structures
- Group related keys together with blank line separators
- Prefer flat structures over deeply nested ones (max 5 levels of nesting)

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  labels:
    app.kubernetes.io/name: my-app
```

## Values

- Use `true`/`false` for booleans — never `yes`/`no`, `on`/`off`
- Quote strings that could be misinterpreted: `"true"`, `"1.0"`, `"null"`, `"yes"`
- Use explicit types when ambiguity exists
- Represent `null` explicitly when an empty value is intentional

## Lists

- Use block sequence style (one item per line with `-`) for readability
- Use flow sequence style (`[a, b, c]`) only for short, inline lists
- Keep list items consistent in structure — all maps or all scalars

## Comments

- Use comments to explain *why*, not *what*
- Place comments on the line above the key they describe
- Use `# TODO:` and `# FIXME:` prefixes for actionable items

## Multi-Document Files

- Separate documents with `---`
- Avoid multi-document files when single-document alternatives exist
- Never use the document end marker (`...`) unless required by the parser

## Anchors and Aliases

- Use YAML anchors (`&`) and aliases (`*`) to reduce duplication
- Name anchors descriptively: `&default-resources` not `&x`
- Place anchor definitions before their first use
- Avoid complex merge keys (`<<:`) — prefer explicit repetition if clarity suffers

## Agent Behavior

- After modifying YAML files, run `yamllint` (if available) to catch syntax and formatting issues
- For Kubernetes manifests, validate against schemas with `kubeconform` before applying
