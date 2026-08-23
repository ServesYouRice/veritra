# QA01 — Execute and extend release-policy fixture tests

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M4 at `3ee785d` |
| Canonical owner | T40C positive release gate; T40D verification policy |
| Initial eligibility | Ready only after the coordinator claims an I40 checks follow-up |
| Risk | High release-gate regression |
| Executor | Balanced+advisor |
| Advisor | Required before changing required-check semantics or evidence fields |
| Depends on | Current T40C/T40D implementation |
| Blocks | Trustworthy I40 evidence; G24/G25 |
| Parallel safety | Do not overlap QA02 or QA10, or another workflow/script owner |

## Objective

Make every existing offline release-policy test run in local fast/full checks
and CI, then add isolated fixture coverage for CI-run selection and release
manifest construction.

## Read first

- `docs/audit-consensus.md` I40 and the T40C/T40D implementation notes.
- `implementation/tasks/T40C-release-gate.md` and
  `implementation/tasks/T40D-dependency-verification.md`.
- `scripts/check-release-evidence*.py`, `scripts/check-dart-retractions*.py`,
  `scripts/check-ci-evidence.py`, `scripts/write-release-evidence.py`.
- `.github/workflows/ci.yml`, `scripts/test.ps1`, `scripts/test.sh`, and
  `scripts/verify.sh`.

## Confirm first

Verify that `check-release-evidence_test.py` and
`check-dart-retractions_test.py` are not invoked by CI or any canonical test
runner, and that no dedicated `check-ci-evidence_test.py` or
`write-release-evidence_test.py` exists. If that is no longer true, return
`stale` with the exact paths and do not edit.

## Allowed write set

- The four policy scripts and their `*_test.py` files.
- `.github/workflows/ci.yml`.
- `scripts/test.ps1`, `scripts/test.sh`, and `scripts/verify.sh`.

Do not edit dependency checkers, release approvals, product code, or the set of
required CI jobs without advisor approval. Add no Python package dependency.

## Invariants

- Tests are offline, deterministic, and use only the Python standard library.
- A missing interpreter or skipped test is visible and fails a required path.
- Refactoring for testability cannot loosen validation or add a network bypass.
- Fixtures contain synthetic commits, identities, digests, and secrets only.

## Work

1. Run the two existing adversarial scripts directly and record their result.
2. Add offline tests for CI evidence selection: malformed payload, wrong commit,
   incomplete/skipped jobs, multiple candidate runs, and one complete exact-run
   success. Stub/refactor the GitHub query boundary; never call GitHub.
3. Add offline tests for manifest construction: missing/malformed inputs,
   approval-shape failure, commit propagation, job propagation, toolchain value,
   image/digest propagation, and one valid manifest.
4. Wire all four fixture suites into Windows and POSIX fast tests, the full
   verifier, and an explicit CI step. Keep one obvious command as the source of
   truth if a small dispatcher avoids duplication.
5. Prove a fixture failure makes each wrapper/CI command fail non-zero.

## Acceptance

- All four fixture suites run automatically and cannot silently skip.
- Every listed negative fixture fails and the valid fixture passes.
- Tests perform no network access and leave no repository files behind.
- Existing release policy, required jobs, and fail-closed activation are
  unchanged unless the advisor explicitly approved a necessary correction.

## Required checks

```sh
python3 scripts/check-release-evidence_test.py
python3 scripts/check-dart-retractions_test.py
python3 scripts/check-ci-evidence_test.py
python3 scripts/write-release-evidence_test.py
./scripts/test.sh
./scripts/verify.sh
```

Run the PowerShell test wrapper on Windows as well. If a required toolchain is
unavailable, report `blocked`; do not call the task complete from Python-only
results.

## Advisor checkpoint

Before any validation/evidence field or required job changes, send the advisor
the current rule, proposed change, negative fixtures, and bypass analysis. Ask
whether the change preserves commit-bound positive evidence.

## Handoff

Use the exact handoff block in `implementation/WORKFLOW.md` with `Task: QA01`.
Name all four automatic invocation points and every unavailable check.

