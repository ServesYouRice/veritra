# T43C — Responsive, semantic and visual evidence baseline

| Field | Contract |
|---|---|
| Consensus source | I43 evidence scope; UI-04/UI-05/UI-07/TEST-04; U16/U20/R6/H5 |
| Routing snapshot (board wins) | Implementation present; checks/evidence pending |
| Risk | High pre-release evidence |
| Executor | Balanced+advisor |
| Advisor | Review accessibility matrix and evidence completeness |
| Depends on | T43A, T43B; coordinate other changed UI |
| Blocks | G24 |
| Parallel safety | One owner for shared goldens/viewport matrix and design evidence |

## Objective

Verify the implemented semantic, viewport, and text-scale coverage; add only
the still-missing visual evidence and prepare the real-device matrix.

## Read first

- `docs/audit-consensus.md` I43 and G24.
- Reconciled source IDs UI-04/UI-05/UI-07/TEST-04/U16/U20/R6/H5.
- Auth labels, `mobile/lib/ui/app_shell.dart`, shared type/widgets,
  `server/websetup/index.html`, mobile UI tests and `docs/design.md`.

## Invariants

- Authentication controls expose accessible names independent of hint behavior.
- Minimum readable type and semantic order remain usable at 200% scale.
- Automated tests do not claim TalkBack/VoiceOver/manual rendering evidence.

## Work

1. Confirm the current tests cover semantic labels, 320 px, landscape/tablet,
   200% text scale, traversal, and reduced motion; do not redo passing work.
2. Run every required check and fix only failures within this contract.
3. Add representative light/dark goldens if they are still absent.
4. Bind automated evidence to the commit and prepare the G24 manual checklist.

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
