# C3 channel creation availability, 2026-11-11

Status: complete creation-entry slice; C3 remains partial.

## Change

- Community refresh reads the viewer's roster role and exposes New channel
  only to owners and admins. This includes legacy communities. Unknown rights,
  failed roster reads and failed community listings hide the entry.
- Refresh immediately invalidates the previous hint. Request ordering and
  session ownership prevent stale replies from restoring it. Removed
  communities lose their hints; a newly created community refreshes its rights
  automatically.
- The hint controls UI availability only. Existing server authorization and
  the dialog's roster check remain; encrypted info still requires verified C4
  roles and never trusts this hint.
- Added eleven regressions covering all four roles, both layouts, demotion,
  promotion, failures, overlapping refreshes, session replacement, missing
  membership, community removal and creation.

## Verification

- Three focused creation/editor test files: 26 passed. Existing app info
  integration tests: 8 passed. Used this worktree's absolute release DLL path
  in `VERITRA_CRYPTO_LIBRARY` for the final focused runs.
- `scripts/lint.ps1`: pass (Go vet, Rust fmt and clippy with warnings denied,
  Flutter analyze, Dart formatting).
- `scripts/test.ps1`: pass, including policy fixtures, `go test ./...`,
  Rust tests (230 passed, 8 existing ignores), and the full Flutter suite
  (2,438 passed, 21 existing skips).
- The first full-script attempt stopped because PowerShell redirection treated
  an expected adversarial fixture stderr line as a terminating error. Retried
  with redirection outside PowerShell, without source changes to the checks.

## Scope

Inspected remote branches and logs before implementation. `origin/agent/c3`
is already an ancestor; the six `origin/agent/c3-2` sender/fetch commits were
already ported. No duplicate merge was needed.

Selected the documented owner/admin creation rule. Worked alone as requested.
No dependencies, ABI, release gates or STATE.md changes. Schema 35 and server
migration 0067 remain unused; this UI slice needs no counter change.

Remaining C3 work: production verified C4 roles and restriction flag,
remote-removal rotation, immediate key delivery after adds, conversion UI,
categories/icons, and plaintext-name refusal/column removal. Peer info
acceptance remains closed without verified roles.
