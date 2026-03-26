---
description: "Interactive guidance for essential project scaffolding files"
globs: ["**/*"]
alwaysApply: true
---

# Project Scaffolding

When starting a new project or onboarding to an existing one, audit the repository for essential scaffolding files. Identify what's missing, present options to the user, and let them choose or customize before creating anything.

**Do not create files automatically** — always present what's missing and ask the user which files they want to add.

## Audit Checklist

Check for the presence of each file below. When a file is missing, explain its purpose and offer to create it using the guidance in each section.

## LICENSE

Every project should declare its license explicitly.

- Present the most common options with a short summary:
  - **MIT** — permissive, simple, widely used; allows commercial use with minimal restrictions
  - **Apache 2.0** — permissive with an explicit patent grant; preferred by many enterprises
  - **GPL-3.0** — copyleft; derivative works must also be GPL-licensed
  - **BSD-3-Clause** — permissive, similar to MIT but with a non-endorsement clause
- Ask the user to choose before creating the file
- Include the correct copyright year and holder name

## CONTRIBUTING.md

Guide external (and internal) contributors on how to participate.

Template structure:
- **How to report bugs** — link to issue tracker, what to include in a bug report
- **How to propose features** — discussion or RFC process
- **How to submit pull requests** — branch naming, commit conventions, PR checklist
- **Development setup** — prerequisites, clone, install, build, test
- **Code style** — link to relevant coding standards or linter configs
- **Code of Conduct reference** — link to `CODE_OF_CONDUCT.md`

## CODE_OF_CONDUCT.md

Sets behavioral expectations for the community.

- Offer the **Contributor Covenant** (v2.1) as the default — it is the industry standard
- Let the user customize contact information and enforcement details
- Link to it from `CONTRIBUTING.md`

## .gitignore

Every repository needs a `.gitignore`. The scaffolding rule covers universal patterns only — language-specific patterns are handled by the corresponding language rule.

### Universal patterns to include

```gitignore
# OS files
.DS_Store
Thumbs.db

# IDE and editor files
.idea/
.vscode/
*.swp
*.swo

# Editor history
.history/

# Secrets and environment files
.env
.env.local
.env.*.local

# Logs
*.log

# Build artifacts
tmp/
.cache/
```

When a language rule is also active, ensure its language-specific `.gitignore` patterns are merged into the same `.gitignore` file rather than creating separate ignore files.

## README.md

The front door of the project. Offer a template with these sections:

- **Project name** and badges (CI status, license, version)
- **Description** — one or two sentences explaining what the project does
- **Prerequisites** — required tools, runtimes, and versions
- **Installation** — step-by-step setup instructions
- **Usage** — basic examples or a quick-start guide
- **Contributing** — link to `CONTRIBUTING.md`
- **License** — short statement with link to `LICENSE`

## Makefile

Provide a consistent developer interface regardless of language or tooling.

Suggest common targets:
- `help` — list available targets with descriptions (set as default target)
- `build` — compile or bundle the project
- `test` — run the test suite
- `lint` — run linters and formatters
- `clean` — remove generated artifacts

Adapt target implementations to the detected language and build tools in the project.

## Dockerfile

Offer a basic multi-stage build template when the project is intended to be containerized.

- **Stage 1 (build)** — install dependencies, compile/build
- **Stage 2 (runtime)** — copy only the built artifact, run as non-root user
- Adapt the base images and commands to the detected language
- Include a `.dockerignore` alongside the Dockerfile

## .github/workflows/ci.yml

Offer a basic CI workflow for GitHub Actions projects.

Template should include:
- **Trigger** — on push to `main` and on pull requests
- **Jobs** — lint, test, build
- Adapt steps to the detected language and tooling
- Use pinned action versions (e.g., `actions/checkout@v4`)

## CHANGELOG.md

Track notable changes for each release.

- Use the [Keep a Changelog](https://keepachangelog.com/) format
- Sections: Added, Changed, Deprecated, Removed, Fixed, Security
- Link to [Conventional Commits](https://www.conventionalcommits.org/) as the commit convention
- Start with an `## [Unreleased]` section

## SECURITY.md

Tell users how to report vulnerabilities responsibly.

Template structure:
- **Supported versions** — which versions receive security updates
- **Reporting a vulnerability** — private disclosure instructions (email, not public issues)
- **Response timeline** — expected acknowledgment and resolution timeframes

## .editorconfig

Ensure consistent formatting across editors and contributors.

```ini
root = true

[*]
indent_style = space
indent_size = 2
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[Makefile]
indent_style = tab
```

Adjust `indent_size` based on language conventions in the project (e.g., 4 for Python and Go).
