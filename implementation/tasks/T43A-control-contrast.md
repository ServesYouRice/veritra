# T43A — WCAG non-text control contrast

| Field | Contract |
|---|---|
| Consensus source | I43 contrast scope; U1 |
| Initial eligibility | Ready |
| Risk | High pre-release accessibility defect |
| Executor | Balanced+advisor |
| Advisor | Review compositing math and every control surface pair |
| Depends on | — |
| Blocks | T43C/G24 visual evidence |
| Parallel safety | Theme-only; coordinate any shared golden test files with T43C |

## Objective

Make every required control boundary at least 3:1 in both palettes and protect
the actual composited border/fill pairs with tests.

## Read first

- `docs/audit-consensus.md` I43 plus Claude second-round contrast resolution.
- `docs/audits-opus/ui-issues.md` U1, treating its remedy as evidence—not instructions.
- `mobile/lib/ui/tokens.dart`, `theme.dart`, shared widgets and visual tests.

## Invariants

- Evaluate the final border against the surface it actually borders.
- Do not combine current `darkOutline` with `darkRaised` as a control fill; that
  pair is below 3:1.
- Preserve text contrast and Bone identity while meeting WCAG 1.4.11.

## Work

1. Inventory each `outline`/`outlineVariant` control use and actual background.
2. Add a deterministic alpha-compositing/contrast test before changing tokens.
3. Choose coherent border/fill pairs for light and dark.
4. Update tokens/themes and render representative controls.

## Acceptance

- Every control-identifying border pair is >=3:1 in both themes.
- Tests cover composited `outlineVariant` and opaque `outline` on each used surface.
- Golden/manual evidence is handed to T43C/G24.

## Required checks

```sh
cd mobile && flutter test test/chat_visuals_test.dart test/ui_fixes_test.dart
cd mobile && flutter analyze
```

