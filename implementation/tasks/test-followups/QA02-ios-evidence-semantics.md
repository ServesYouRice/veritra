# QA02 — Separate simulator compile and signed-iOS evidence

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M7 at `3ee785d` |
| Canonical owner | T40C evidence schema; external G24 signed-device gate |
| Routing snapshot (board wins) | Design checkpoint ready; implementation blocked until approval |
| Risk | High release-evidence boundary |
| Executor | Balanced+advisor after approval |
| Advisor | Mandatory before the first edit and after adversarial fixtures |
| Depends on | Approved evidence shape; QA01 should land first |
| Blocks | Accurate iOS release evidence; G24/G25 |
| Parallel safety | Do not overlap QA01, QA10, or another release-workflow owner |

## Objective

Keep the unsigned debug simulator build as a fast compile check, while making
it impossible for that job to satisfy the signed iOS release-artifact evidence
required by G24.

## Read first

- `docs/board.md` I24 and the release evidence matrix.
- `docs/audit-consensus.md` I40 and I24/G24 boundaries.
- `implementation/tasks/G24-signed-device-evidence.md`.
- `.github/workflows/ci.yml`, `.github/workflows/release.yml`,
  `release/release-policy.json`, and all four release-evidence Python scripts.

## Confirm first

Show that `.github/workflows/ci.yml` builds iOS with
`flutter build ios --simulator --debug`, while the evidence policy/checker sees
only a successful `mobile-ios` job and no signed-iOS artifact type. If either
side has already been corrected, return `stale` or ask the coordinator to
narrow the task.

## Allowed write set

- `.github/workflows/ci.yml` and `.github/workflows/release.yml`.
- `release/release-policy.json`.
- Release-evidence Python scripts and their tests.
- Release-evidence schema/example documentation explicitly named by the
  approved design.

Never create signing material, perform signing, upload an artifact, or mark
G24/G25 complete.

## Invariants

- Simulator CI stays required as simulator CI; it is not signed-device proof.
- Signed evidence is bound to the exact candidate commit and immutable artifact
  digest/provenance selected by the advisor-approved schema.
- Missing, stale, unsigned, skipped, or wrong-platform evidence fails closed.
- No credential, device identifier, provisioning profile, or secret is stored.

## Work

1. Stop and obtain approval for the exact schema and naming. The decision must
   identify the simulator check and the separate signed-iOS artifact evidence,
   including commit and digest binding.
2. Add failing fixtures first: simulator success with no signed evidence,
   unsigned evidence, wrong commit, wrong platform/type, malformed digest, and
   skipped simulator. Add one fully valid synthetic fixture.
3. Implement only the approved schema in policy generation and validation.
4. Rename labels/job keys where needed so reports cannot describe a simulator
   build as a release-device build. Keep the actual simulator command.
5. Run QA01 and the release-readiness negative path; G24 remains externally
   pending even when this code task passes.

## Acceptance

- Simulator-only evidence cannot pass release validation.
- Valid signed-iOS evidence must match the candidate commit and approved
  artifact identity; every malformed/stale fixture fails.
- The simulator compile remains a protected required check.
- No production gate, approval, or unavailable-crypto marker is weakened.

## Required checks

```sh
python3 scripts/check-release-evidence_test.py
python3 scripts/check-ci-evidence_test.py
python3 scripts/write-release-evidence_test.py
./scripts/release-readiness.sh
./scripts/verify.sh
```

The readiness command is expected to remain blocked without real G24/G25
evidence; record that exact fail-closed result rather than substituting a pass.

## Advisor checkpoint

Ask: “What exact policy/schema fields distinguish mandatory debug-simulator CI
from signed iOS candidate evidence, and how are platform, commit, digest, and
provenance bound?” Do not edit until the coordinator records the answer.

## Handoff

Use the exact workflow handoff with `Task: QA02`. Separate “code contract
passes” from “G24 external evidence still pending.”
