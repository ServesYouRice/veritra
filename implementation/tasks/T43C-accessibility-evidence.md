# T43C — Responsive, semantic and visual evidence baseline

| Field | Contract |
|---|---|
| Consensus source | I43 evidence scope; UI-04/UI-05/UI-07/TEST-04; U16/U20/R6/H5 |
| Initial eligibility | Ready after affected UI tasks |
| Risk | High pre-release evidence |
| Executor | Balanced+advisor |
| Advisor | Review accessibility matrix and evidence completeness |
| Depends on | T43A, T43B; coordinate other changed UI |
| Blocks | G24 |
| Parallel safety | One owner for shared goldens/viewport matrix and design evidence |

## Objective

Create automated semantic, golden, viewport and text-scale coverage, fix the
named responsive/a11y defects, and prepare the real-device matrix.

## Read first

- `docs/audit-consensus.md` I43 and G24.
- Named source findings.
- Auth labels, `mobile/lib/ui/app_shell.dart`, shared type/widgets,
  `server/websetup/index.html`, mobile UI tests and `docs/design.md`.

## Invariants

- Authentication controls expose accessible names independent of hint behavior.
- Minimum readable type and semantic order remain usable at 200% scale.
- Automated tests do not claim TalkBack/VoiceOver/manual rendering evidence.

## Work

1. Fix semantic labels, micro text misuse, nav truncation and narrow web setup.
2. Add representative light/dark goldens and 320 px/landscape/tablet/200% tests.
3. Add semantic traversal and reduced-motion checks.
4. Bind automated evidence to the commit and prepare G24 manual checklist.

## Acceptance

- Required viewports/text scale do not clip or lose actions.
- Semantic traversal and labels pass.
- Golden evidence is commit-bound; manual/device rows remain explicitly pending until G24.

## Required checks

```sh
cd mobile && flutter test
cd mobile && flutter analyze
cd server && go test ./websetup
```

