---
name: ui-audit
description: Audit a site's UI for missing pages and outdated patterns, then modernize it safely. Use when asked to audit, review, refresh, or modernize the UI, find missing pages, or bring styles up to current standards.
---

# UI Audit & Modernization

A repeatable workflow for auditing a **web/HTML** UI and modernizing it without
breaking what works. Follow the phases in order; do not skip verification.

Not for native app UI (Flutter, SwiftUI, Compose) — Phases 2–4 assume routes,
CSS, and a DOM.

## Phase 0 — Orient before touching anything

1. Read `AGENTS.md` (or `CLAUDE.md` if that is the pointer) and the repo's
   work tracker. Do not sweep every `*.md` in the repo; superseded audits are
   context bloat and re-reporting a fixed finding is worse than silence.
2. Inventory the UI surface: routes/pages, shared components and layouts, the
   global stylesheet, the content schema, and the test suite. Read the files
   you will actually touch; list the rest.
3. Establish a green baseline before changing code: the repo's check, build,
   and test commands. If the baseline is red, report that first and stop.

## Phase 1 — Record the plan where the repo already tracks work

**Do not create a `plan.md`, an audit file, or any other new tracking file.**
Repos accumulate these faster than they retire them.

- If the repo has a board or task directory (for example
  `docs/board.md`), add one card in that format and stop.
- Otherwise put the plan in your reply to the user, not on disk.

Either way the plan is four short parts: state of the UI in 2–3 sentences; a
missing-surfaces table ("feature already implemented" → "missing surface" →
"fix"); the outdated patterns found with the specific modern replacement for
each (name the CSS feature, not just "modernize"); and the order of work with
its verification.

## Phase 2 — Find missing pages (features without a surface)

Hunt for data and code that exists with no navigable page. Systematic checks:

- **Taxonomy detail pages without an index**: `/tags/[tag]/` exists but
  `/tags/` 404s. Every `[param]` route should have a sibling `index`.
- **Schema fields with no page**: a `category`/`author`/`series` field in the
  content schema that never became a route. If a page shows the value as
  plain text (not a link), the listing page is probably missing.
- **Feeds/endpoints never linked**: `rss.xml` served but only referenced in a
  `<link>` head tag — a human can't find it.
- **No footer**: if the site has no footer, the missing-links problem is
  usually site-wide. Add one (brand, nav columns, feed, copyright).
- **Author with no about page**: `SITE_AUTHOR`, JSON-LD `Person`, meta author
  — but no `/about/`.

Follow-through checklist for every page you add (do all of these, not some):

- [ ] Add to header nav and/or footer so it is reachable
- [ ] Add to the sitemap (respect existing thin-page rules, e.g. noindex +
      sitemap-exclude listings backed by fewer than 2 entries)
- [ ] Turn plain-text mentions of the entity into links (category names,
      tag names)
- [ ] Set canonical path, title, description on the page
- [ ] Extend the test suite (see Phase 4)
- [ ] Derive page content from the content collection — never hardcode
      counts or labels that a new post would invalidate

## Phase 3 — Modernize the CSS/UI

Rewrite, don't patch, the global stylesheet — but **preserve the visual
identity** (palette, typography voice, layout character) and every
progressive-enhancement pattern (real links, CSS-only nav toggles, no-JS
fallbacks). Modernization means better foundations, not a redesign.

The checklist of modern replacements (all Baseline-supported):

| Outdated pattern | Modern replacement |
|---|---|
| Flat selector lists | Native CSS nesting |
| hex/rgba colors | `oklch()` tokens; `oklch(from var(--x) l c h / a)` for derived tints |
| Fixed px/rem sizes + breakpoint overrides | `clamp()` fluid type/space scale in `:root` |
| `width/height/left/top/margin-left` | Logical properties (`inline-size`, `inset-inline-start`, `margin-block`, …) |
| Ragged headings/prose | `text-wrap: balance` (headings), `text-wrap: pretty` (prose) |
| `repeat(3, 1fr)` grid + media queries | `repeat(auto-fill, minmax(min(100%, Npx), 1fr))` |
| Viewport media queries for component layout | Container queries (`container-type: inline-size` + `@container`) |
| Hand-rolled modal (focus trap, Escape handler, backdrop div, `body{overflow}` JS) | Native `<dialog>` + `showModal()`, `::backdrop`, `cancel`/`close` events, `body:has(dialog[open]){overflow:hidden}` |
| JS entry animations for menus | `@starting-style` + `transition-behavior: allow-discrete` |
| No page transitions | CSS-only `@view-transition { navigation: auto }` inside `prefers-reduced-motion: no-preference` |
| `::-webkit-scrollbar` | `scrollbar-width` / `scrollbar-color` / `scrollbar-gutter` |
| `clip: rect(0,0,0,0)` | `clip-path: inset(50%)` |

`<dialog>` conversion notes (the risky one — be precise):

- Default closed state is UA `display:none`; put your `display: grid` under
  `&[open]`, never on the bare selector.
- `showModal()` gives top layer, focus containment, Escape, and focus
  restore — delete the manual trap and `document` keydown Escape handler.
- Backdrop clicks arrive on the dialog element itself: close when
  `event.target === dialog`.
- Intercept `cancel` (`preventDefault()`) if you have an animated close;
  put all cleanup in the `close` event so every close path shares it.
- Keep `aria-labelledby` on the dialog; remove `role="dialog"`/`aria-modal`
  from inner wrappers.

Always keep the `prefers-reduced-motion: reduce` kill switch and any
`pointer: coarse` performance carve-outs; extend them to your new effects
(`::backdrop` blur, view transitions).

## Phase 4 — Verify like you mean it

1. `npm run check` → 0 errors, `npm run build` → page count should grow by
   exactly the pages you added, then run Playwright.
2. In this environment the repo's pinned Playwright may not match the
   pre-installed browser. Do NOT run `playwright install`. Create an
   untracked wrapper config in the repo root (module resolution fails
   outside it), add it to `.git/info/exclude`, and pass `--config`:

   ```ts
   // pw.local.config.ts
   import { defineConfig } from "@playwright/test";
   import baseConfig from "./playwright.config.ts";
   export default defineConfig(baseConfig, {
     use: { ...baseConfig.use, launchOptions: { executablePath: "/opt/pw-browsers/chromium" } }
   });
   ```

3. New tests for every new page: heading renders, a representative link
   navigates, nav marks `aria-current`, sitemap contains the new routes.
   Derive expected counts from the content directory in the spec — never
   hardcode numbers a new post would break.
4. Adding a footer duplicates link names ("Stories" now in nav AND footer):
   scope existing `getByRole("link")` assertions to `.main-nav` or they fail
   strict mode.
5. **Screenshot review is mandatory.** Build, `npm run preview`, screenshot
   desktop + mobile + each new page + open modal, and actually look at them.
   This catches what tests can't: in this repo it caught "Dolomites /
   Dolomites" duplicate labels that every test passed over. Look
   specifically for: duplicated text, elements peeking past viewport edges,
   broken spacing, contrast problems.

## Phase 5 — Land it

- Commit in logical units: missing pages → modernization. Each message says
  why, not just what.
- Leave no scaffolding behind. Any temporary config or note you created gets
  deleted or `.git/info/exclude`d before you finish. Ask before deleting
  anything you did not create.
- Update the board card you opened in Phase 1; do not write a completion
  report file.
- Report to the user in short, plain sentences (see AGENTS.md): what was
  missing, what was added, what was modernized, proof it passes.
