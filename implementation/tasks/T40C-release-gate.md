# T40C — Positive, commit-bound release gate

| Field | Contract |
|---|---|
| Consensus source | I40; DEP-01, TEST-06, ARCH-04, R2 |
| Initial eligibility | Ready after T40A |
| Risk | High release blocker |
| Executor | Strong |
| Advisor | Required on gate design and adversarial review |
| Depends on | T40A |
| Blocks | G24/G25 |
| Parallel safety | One owner for release-readiness and publication workflow |

## Objective

Replace rename-bypassable negative greps with positive behavior and evidence
checks tied to the exact commit/artifact; publication must require them.

## Read first

- `docs/audit-consensus.md` I40.
- `docs/audits-codex/deployment-risks.md` DEP-01.
- `docs/audits-codex/testing-gaps.md` TEST-06.
- `docs/audits-codex/architecture-review.md` ARCH-04.
- `docs/audits-opus/production-readiness.md` R2.
- `scripts/release-readiness.sh`, CI/release workflows, mobile crypto wiring tests.

## Invariants

- `UnavailableCryptoService` and `PM_CRYPTO_UNAVAILABLE` stay until G25.
- A renamed symbol, skipped matrix job or unreviewed commit cannot publish.

## Work

1. Add production-wiring behavior proof, not source-name absence alone.
2. Bind protected checks, candidate commit and packaged digest.
3. Make incomplete/skipped matrices fail release publication.
4. Test the gate against intentionally broken fixtures.

## Acceptance

- Rename and skipped-job fixtures fail.
- Untested/unreviewed commits cannot publish.
- Tested commit and packaged commit/digest match.

## Required checks

```sh
./scripts/release-readiness.sh
./scripts/test.sh
```

