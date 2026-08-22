# G25 — Independent review and crypto activation

| Field | Contract |
|---|---|
| Consensus source | I25; SEC-03 review scope, UI-01 |
| Initial eligibility | External gate |
| Risk | Final production crypto gate |
| Executor | Independent reviewer; coordinator integrates remediation |
| Advisor | Cannot substitute for independent human/security review |
| Depends on | G24, G27 and every release blocker |
| Blocks | Replacing `UnavailableCryptoService`; removing `PM_CRYPTO_UNAVAILABLE` |
| Parallel safety | Review may inspect surfaces in parallel; one immutable candidate and one final sign-off |

## Objective

Obtain independent review of the immutable release candidate, remediate every
critical/high issue, rerun evidence and only then authorize production MLS.

## Read first

- `docs/board.md` I25 and crypto-gated UI.
- `docs/audit-consensus.md` I25/UI-01 disposition.
- `docs/crypto.md`, `SECURITY.md`, `crypto/rust/`, mobile crypto integration.
- G24 evidence and G27 advisory disposition.

## Invariants

- An LLM review is additional evidence, not the independent-review gate.
- Do not weaken or rename a gate to make readiness pass.
- Server-side plaintext, plaintext logging and unreviewed crypto fallbacks stay forbidden.

## Work

1. Give the reviewer the candidate revision, threat model, vectors, build
   instructions, ABI ownership rules and failure tests.
2. Record findings and remediation without exposing sensitive test material.
3. Fix and independently retest every critical/high finding.
4. Rerun G24 against the final reviewed commit.
5. Activate production crypto only in the final reviewed change.

## Acceptance

- Reviewer identity/engagement and immutable commit are recorded.
- Critical/high findings are closed; lower residual risks are explicitly accepted.
- Final device/release evidence matches the reviewed commit.
- Both fail-closed gates change only after all prior conditions pass.

## Required checks

Run the complete release matrix, native ABI/vector suites and
`./scripts/release-readiness.sh` against the final candidate.

