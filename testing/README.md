# Testing audit inputs

> **Status:** The original files here are unverified source reports, not an
> executable backlog. They contain stale claims and invalid commands. Use the
> reviewed [testing follow-up task pack](../implementation/tasks/test-followups/README.md)
> for work assignments. `docs/board.md` and `docs/audit-consensus.md` remain
> authoritative.

## Start here

1. Read the short [review outcome](review_findings.md).
2. A coordinator selects one eligible QA contract from the
   [task pack](../implementation/tasks/test-followups/README.md).
3. The executor confirms the gap on current `HEAD`, stays inside its allowed
   write set, runs every check, and returns the required handoff.

## Original reports

These are retained as audit provenance only. Do not use their task status,
commands, model names, or orchestration plan without reconfirming them.

| Area | Source report |
|---|---|
| Crypto | [crypto_testing_gaps.md](crypto_testing_gaps.md) |
| Server | [server_testing_gaps.md](server_testing_gaps.md) |
| Mobile | [mobile_testing_gaps.md](mobile_testing_gaps.md) |
| End to end | [e2e_integration_gaps.md](e2e_integration_gaps.md) |
| Old traceability | [task_test_traceability_matrix.md](task_test_traceability_matrix.md) |
| Superseded orchestration | [orchestration_plan.md](orchestration_plan.md) |

## Boundaries every test task preserves

- Server message/attachment bodies stay ciphertext-only.
- Logs never contain message text, bodies, secrets, tokens, or ciphertext.
- `PM_CRYPTO_UNAVAILABLE` and `UnavailableCryptoService` fail closed until G25.
- Push remains generic, with no sender or message content.
- Mobile MLS state/cursor/message commits remain atomic.
- Simulator or inspection evidence is never presented as signed-device/runtime
  evidence.
