# G24 — Signed-device release evidence

| Field | Contract |
|---|---|
| Consensus source | I24; DEP-02, TEST-04, TEST-05; R6, R12, R13, R14 |
| Initial eligibility | External gate |
| Risk | Release blocker |
| Executor | Coordinator with platform specialists |
| Advisor | Strong review of failures or waiver requests |
| Depends on | All applicable code tasks; signing/provider/TURN access |
| Blocks | G25 and release activation |
| Parallel safety | Android and iOS evidence may run separately against the same immutable commit |

## Objective

Produce signed, installable Android and iOS candidates and bind the complete
device, accessibility, push, call and restore evidence matrix to one commit.

## Read first

- `docs/board.md` I24 and release evidence matrix.
- `docs/audit-consensus.md` existing gate I24.
- `docs/audits-codex/testing-gaps.md` TEST-04/TEST-05.
- `docs/audits-opus/production-readiness.md` R6/R12/R13/R14.
- `.github/workflows/release.yml`, `docs/operations.md`.

## Invariants

- Never commit signing material, provider secrets or device identifiers.
- Generic pushes contain no sender or message content.
- Evidence from a different commit does not count.

## Work

1. Freeze the candidate commit after all code blockers pass.
2. Build signed Android/iOS candidates with pinned native crypto.
3. Generate notices, SBOM, checksums, provenance and signatures.
4. Run the board's two-device functional, push, TURN, network-change, restore,
   keyboard, TalkBack, VoiceOver, large-text and reduced-motion matrix.
5. Record platform versions, candidate digest, pass/fail and sanitized evidence.

## Acceptance

- Signed candidates install on every supported platform/version.
- Every required matrix row passes against the same candidate.
- No secret or user/message identifier appears in evidence.
- The board identifies the exact commit and artifacts.

## Required checks

Run the full release workflow and `./scripts/release-readiness.sh`; do not mark
complete while any release-required step is skipped or pending.

## Handoff

Use `implementation/WORKFLOW.md`. Attach artifact digests and the matrix; list
credentials/hardware that remain external without copying secrets.

