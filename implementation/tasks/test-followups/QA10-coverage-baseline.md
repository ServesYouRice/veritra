# QA10 — Establish a coverage baseline and approved regression ratchet

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M6 at `3ee785d` |
| Canonical owner | T40D verification policy; T47 measurement/targets |
| Routing snapshot (board wins) | Measurement may start; enforcement needs advisor approval |
| Risk | Medium signal quality; high if made release-required incorrectly |
| Executor | Balanced+advisor; Fast may collect the read-only baseline only |
| Advisor | Required to choose thresholds and before any Rust coverage tool |
| Depends on | Stable QA01/QA02 workflow ownership |
| Blocks | Evidence-backed coverage regression policy, not invariant tests |
| Parallel safety | Do not overlap QA01/QA02 or another CI/verification owner |

## Objective

Measure commit-bound Go/Flutter coverage, identify untested high-risk packages,
then implement only an advisor-approved regression ratchet. Evaluate Rust
coverage separately and do not add tooling without dependency/license review.

## Read first

- `docs/audit-consensus.md` I40/I47 and T40D/T47 contracts.
- `.github/workflows/ci.yml`, `scripts/verify.sh`, Go/Flutter coverage outputs,
  Rust toolchain policy, and `THIRD_PARTY_NOTICES.md`.
- QA01/QA02 status and current workflow ownership.

## Confirm first

Verify CI uploads Go and Flutter coverage but enforces no total/package/file
regression floor, and that Rust produces no coverage artifact. If a current
ratchet and Rust artifact already exist, return `stale` with their checks.

## Allowed write set

- New standard-library coverage parser/fixture tests under `scripts/`.
- `.github/workflows/ci.yml` and `scripts/verify.sh` after advisor approval.
- `testing/evidence/coverage-baseline.md` for commit/toolchain-bound numbers.
- Rust workflow/tool manifests only after explicit dependency/license approval.

Do not modify product tests/code to inflate percentages, edit coverage output,
exclude difficult files without review, or touch dependency policy scripts.

## Invariants

- Coverage is a regression signal, never a substitute for security, protocol,
  recovery, device, or release-evidence tests.
- Baselines name commit, toolchain, command, scope, and skipped/generated files.
- Missing/malformed coverage data fails an enforced gate; it cannot become zero
  or pass silently.
- Thresholds come from measured data and risk, not an arbitrary round number.
- New Rust tooling requires license/notices/security review first.

## Work

1. Run current Go race coverage and Flutter coverage at an immutable commit.
   Record total plus high-risk package/file results (storage, HTTP, push,
   realtime, mobile crypto, storage, API, push, and calls).
2. Record the reproducible baseline in
   `testing/evidence/coverage-baseline.md`; list Rust as unmeasured rather than
   inventing a value.
3. At the advisor checkpoint, propose total and selected package/file floors
   with a small non-flaky margin and a policy for deliberate baseline changes.
4. After approval, add a dependency-free parser/ratchet with fixtures for valid,
   below-floor, missing, malformed, renamed/missing target, and locale/ordering
   cases. Wire it to full verification and CI.
5. Evaluate Rust coverage tools against the pinned toolchain. If approval is
   absent, create a blocked handoff item; do not install one. If approved, add
   its artifact and fixture-backed fail behavior in the same policy style.

## Acceptance

- A reproducible commit-bound baseline exists for Go and Flutter.
- Approved floors fail a controlled regression and fail on missing/malformed
  input while current coverage passes.
- Baseline changes are explicit reviewable edits, not automatic ratcheting.
- Rust is either measured by an approved/pinned/noticed tool or recorded as an
  exact dependency-review blocker.
- Existing invariant suites and release gates remain required.

## Required checks

```sh
cd server && go test -race -coverprofile=coverage.out ./...
cd server && go tool cover -func=coverage.out
cd mobile && flutter test --coverage
python3 scripts/check-coverage_test.py
./scripts/verify.sh
```

Use the final approved script name if the advisor chooses a different one.
Run Rust coverage only after its tooling checkpoint.

## Advisor checkpoint

Send measured totals and high-risk package/file values, uncovered critical
services, proposed floors/margin, fixture behavior, and any Rust tool/license
impact. Ask which floors are justified and whether they are release-required
or informational.

## Handoff

Use the workflow handoff with `Task: QA10`. Include the baseline commit and
commands, but keep the user-facing summary short; state Rust status explicitly.
