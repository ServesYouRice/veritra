# T40D — Full-stack dependency and verification policy

| Field | Contract |
|---|---|
| Consensus source | I40; TEST-09, TEST-10, TEST-11, NTH-10, NTH-12, NTH-13, R7 |
| Initial eligibility | Ready after T40A |
| Risk | Release blocker where required suites can skip; otherwise hardening |
| Executor | Balanced+advisor |
| Advisor | Review supply-chain policy and any new tool/dependency |
| Depends on | T40A |
| Blocks | G24 evidence completeness |
| Parallel safety | Coordinate workflow/script edits with T40B/T40C |

## Objective

Define fast and complete verification paths, fail release-required skips, and
cover Dart/Gradle/retracted dependencies plus retained Go/Rust scans.

## Read first

- `docs/audit-consensus.md` I40.
- `docs/audits-codex/testing-gaps.md` TEST-09/10/11.
- `docs/audits-codex/nice-to-haves.md` NTH-10/12/13.
- `docs/audits-opus/production-readiness.md` R7.
- `scripts/test.*`, `scripts/lint.*`, license/audit scripts, CI workflows,
  mobile lockfiles and `.github/dependabot.yml`.

## Invariants

- New tooling/dependencies require license and notice review.
- “No scanner exists” is not assumed; document tool limits honestly.

## Work

1. Inventory current fast/full suites and every environment skip.
2. Define canonical commands and make release-required skips fail.
3. Add lockfile-aware mobile/build dependency and retraction checks.
4. Publish useful coverage/fuzz results with risk-based thresholds.
5. Keep results bound to the candidate commit.

## Acceptance

- Fast/full commands are documented and reproducible.
- A release-required skip or retracted dependency fails CI.
- Existing Go/Rust scans remain active; coverage is retained as evidence.

## Required checks

```sh
./scripts/test.sh
./scripts/lint.sh
./scripts/license-check.sh
```
