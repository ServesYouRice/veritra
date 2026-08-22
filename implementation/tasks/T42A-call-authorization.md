# T42A — Authorized call state machine

| Field | Contract |
|---|---|
| Consensus source | I42 server scope; LOG-10/ARCH-07 |
| Initial eligibility | Ready, conditional under D03 |
| Risk | High call-scope blocker |
| Executor | Strong |
| Advisor | Required on actor/state/version model |
| Depends on | — |
| Blocks | G24 call evidence |
| Parallel safety | Server-only; may run beside native T42B after shared protocol is fixed |

## Objective

Restrict call creation/transitions/end to the initiator and explicitly invited
participants of supported conversation kinds, with stale-update protection.

## Read first

- `docs/audit-consensus.md` I42.
- `docs/audits-codex/logical-issues.md` LOG-10 and architecture ARCH-07.
- `server/internal/httpapi/call_sync_handlers.go`, call tests,
  `server/internal/webrtc/`, domain types and migration 0008.

## Invariants

- Conversation membership alone does not authorize control of another user's call state.
- Actor-specific transitions and version preconditions are enforced server-side.
- Signaling remains encrypted; server learns no call content.

## Work

1. Specify call kind, initiator, invited participant and transition matrix.
2. Add version precondition/idempotency semantics.
3. Enforce authorization in domain/service code, not only handlers.
4. Add adversarial nonparticipant, unrelated member and stale-transition tests.

## Acceptance

- Unauthorized actors cannot create/rewrite/end calls.
- Stale transitions fail deterministically; valid retries are idempotent.
- Group breadth matches the actual product, not the broad storage model.

## Required checks

```sh
cd server && go test ./internal/domain ./internal/httpapi ./internal/webrtc ./internal/storage
```

