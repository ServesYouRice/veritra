# T31 — Lossless message outbox

| Field | Contract |
|---|---|
| Consensus source | I31; LOG-02/LOG-11/UI-02/TEST-03 message scope; L1/L10/L12/U15/U22 |
| Initial eligibility | Ready |
| Risk | Critical release blocker |
| Executor | Strong |
| Advisor | Required on capacity-before-encryption invariant and terminal recovery |
| Depends on | — |
| Blocks | T34 worker pattern |
| Parallel safety | Avoid concurrent T30B/T32 edits to `app_state.dart` and local storage |

## Objective

Guarantee that accepted send intent is durable, never evicted at capacity, and
eventually delivered or presented as explicitly recoverable terminal work.

## Read first

- `docs/audit-consensus.md` I31.
- Named Codex and Opus sections.
- `mobile/lib/core/app_state.dart`, `api_client.dart`, `local_store.dart`,
  `features/chat/chat_screen.dart`, relevant mobile tests.

## Invariants

- Check capacity before encryption or MLS advancement; never evict unsent work.
- Composer text clears only after durable acceptance.
- Only classified transient failures retry; 507 is terminal and actionable.

## Work

1. Specify durable outbox states, capacity and idempotency invariants.
2. Return typed `outbox_full` before crypto state changes.
3. Serialize flushes; persist attempts/next retry; wake on timer/connectivity.
4. Classify 401/404/409/413/422/507 and expose copy/retry/discard recovery.
5. Add 99/100/101, restart, reentrancy and composer tests.

## Acceptance

- Both enqueue paths preserve every existing item at 99/100/101.
- Retry schedule survives restart and concurrent flush calls coalesce.
- Terminal/auth errors follow policy and quota copy identifies the real remedy.

## Required checks

```sh
cd mobile && flutter test test/app_state_test.dart test/ui_actionable_test.dart test/api_contract_test.dart
```

