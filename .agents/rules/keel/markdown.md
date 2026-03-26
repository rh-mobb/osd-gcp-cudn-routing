---
description: "Markdown writing conventions for .md files"
globs: ["**/*.md"]
alwaysApply: false
---

# Markdown Standards

Standards for writing and formatting Markdown files.

## Tooling

- Lint with `markdownlint` (CLI or editor extension) using a `.markdownlint.yml` config
- Check links with `markdown-link-check` or `lychee` to catch broken references

## Structure

- Start every document with a single H1 heading
- Use heading levels sequentially — never skip from H2 to H4
- Separate sections with a single blank line before each heading
- Write one sentence per line to produce cleaner diffs and easier reviews
- Keep documents focused on a single topic; split large documents into multiple files

## Formatting

- Use `**bold**` for emphasis on key terms and UI labels
- Use `*italic*` sparingly — for titles, introducing new terms, or subtle emphasis
- Use backticks for inline code, filenames, CLI commands, and config keys
- Use `---` for horizontal rules only to separate major document regions — prefer headings instead
- Avoid HTML in Markdown unless there is no Markdown equivalent

## Lists

- Use `-` as the unordered list marker — not `*` or `+`
- Indent nested lists by 2 spaces
- Use ordered lists (`1.`) only when sequence matters
- Use task lists (`- [ ]`) for actionable checklists
- Keep list items parallel in grammatical structure

## Code Blocks

- Always specify the language identifier on fenced code blocks

````markdown
```yaml
key: value
```
````

- Keep code examples concise and focused on the point being made
- Use inline backticks for short references; use fenced blocks for multi-line code
- Avoid screenshots of code — use text-based code blocks for accessibility and searchability

## Links and Images

- Use relative paths for links within the same repository
- Use descriptive link text — never use "click here" or bare URLs

```markdown
See the [contributing guide](CONTRIBUTING.md) for details.
```

- Add meaningful alt text to all images
- Prefer SVG or text-based diagrams over raster images when possible
- Place large images in a dedicated `assets/` or `images/` directory

## Tables

- Use tables for structured, columnar data — not for layout
- Align columns with pipes for readability in source
- Keep tables simple; if a table exceeds 4–5 columns, consider an alternative format
- Use left-alignment (default) unless numeric data benefits from right-alignment

```markdown
| Name   | Type   | Default |
|--------|--------|---------|
| port   | int    | 8080    |
| debug  | bool   | false   |
```

## Frontmatter

- Use YAML frontmatter delimited by `---` — not TOML (`+++`)
- Keep metadata minimal: include only fields that tooling or templates actually consume
- Use consistent key names across all documents in a project

## Agent Behavior

- After modifying Markdown files, run `markdownlint` (if available) to catch formatting issues
- Verify that links to other files use correct relative paths
