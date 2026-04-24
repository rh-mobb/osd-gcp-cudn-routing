# AGENTS.md — Slidev presentation

This folder holds the **Joint Engineering with AI** deck: [Slidev](https://sli.dev/) (`slides.md`), Vue components under `components/`, theme CSS in `styles/index.css`, and static assets in `public/`. The repo root [AGENTS.md](../AGENTS.md) still applies for global rules.

## Changelog

**Do not** add entries to the repository root [CHANGELOG.md](../CHANGELOG.md) for work confined to `presentation/` (slides, Vue components under this folder, `styles/`, `public/`). Slide and deck edits are not product releases; keep [CHANGELOG.md](../CHANGELOG.md) focused on infrastructure, operator, and shipped docs outside this deck.

## Terminology (this deck)

Prefer **agent environment** (or **rules + references**) over **scaffolding** in slide copy. In many shops *scaffolding* implies codegen or app bootstrapping (e.g. Rails, `create-vite`). Here we mean **AGENTS.md**, **Keel-synced rules**, **references/**, and architecture docs—the same idea as the tagline *“engineering an environment.”*

## Run locally

- From the **repository root**: `make presentation` — installs npm deps if needed, starts the dev server, and opens the browser (default port is often **3030**; if that port is busy, Slidev picks the next free port — watch the terminal output).
- Directly in this directory: `npm install` then `npm run dev`.
- Production build: `make presentation.build` (output: `presentation/dist/`).

Slide URLs look like `http://localhost:3030/<slide-no>` (e.g. slide 2 → `/2`).

## What to edit

| Area | Purpose |
|------|---------|
| `slides.md` | All slide content, frontmatter, Mermaid blocks, speaker notes (`<!-- ... -->`) |
| `components/*.vue` | Reusable visuals (tables, diagrams, packet animations) |
| `styles/index.css` | Red Hat theming; global fixes (e.g. Goto dialog quirk) |
| `public/` | Images and other static files |

When narrative or slide inventory changes in a way that matters to the project story, keep [docs/project-timeline-2026.md](../docs/project-timeline-2026.md) aligned (per repo `AGENTS.md`).

## Review workflow (mandatory for slide changes)

Do **not** judge slides from Markdown alone. Layout, overflow, and contrast only show up in the browser.

1. **Start or reuse the dev server** so the deck is live at a known URL.
2. **Open the slide** in a browser (navigate to `/N` for slide number `N`).
3. **Capture a screenshot** of the viewport (full slide area). Use the IDE browser tools or an equivalent when available.
4. **Evaluate** using the screenshot plus the source:
   - Is anything clipped or overlapping (titles, code, Mermaid, tables)?
   - Is hierarchy clear (one main idea per slide where intended)?
   - Do fonts, spacing, and the red accent read well at slide scale?
   - Do diagrams or animations still make sense next to the spoken story?
5. **Propose concrete improvements** (copy edits, `text-sm` / spacing classes, splitting a slide, simplifying a diagram). Prefer the smallest change that fixes the issue.
6. **Ask the human for feedback** before sweeping restyles or large restructures — slides are subjective; confirm direction after one or two fixed examples.

Repeat for **every slide you materially change**, not only the first one.

## Slidev-specific notes

- **` ```mermaid ` blocks must live in normal slide Markdown**, not inside arbitrary Vue component slots (e.g. `<RhTwoColumn><template #right>`). Slot content is not passed through the Mermaid transform, so you get a raw code fence. Use Slidev’s built-in [`two-cols` layout](https://sli.dev/builtin/layouts#two-cols) with a `::right::` divider, or keep the diagram outside the custom component. For complex topology, a **PNG/SVG under `public/`** (e.g. `<img src="/my-diagram.png" class="max-w-full object-contain …" />`) often fits the slide more reliably than dense Mermaid.
- **Speaker notes** live in HTML comment blocks under each slide in `slides.md`.
- **`g` (Goto)** opens a jump dialog; if a stray list ever appears on the right edge when the dialog is “closed”, see the `#slidev-goto-dialog` rule in `styles/index.css`.
- **Custom CSS** is loaded via `styles/index.css` (Slidev convention). Scope slide typography under `.slidev-layout` when changing tags so the presenter UI is unaffected.
- After dependency or Slidev upgrades, run `npm run build` and fix any reported errors before declaring the deck ready.

## Self-review

Before handing off slide work: re-read the edited markdown, confirm the dev server shows no errors, and if you changed layout or visuals, **screenshot-check** at least the affected slides using the workflow above.
