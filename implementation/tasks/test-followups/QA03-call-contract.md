# QA03 — Repair and prove the mobile/server call contract

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M1 at `3ee785d` |
| Canonical owner | T42A protocol verification; coordinate T42B without native work |
| Routing snapshot (board wins) | Ready only after the coordinator claims a T42A verification follow-up |
| Risk | High conditional call blocker |
| Executor | Balanced+advisor |
| Advisor | Required on client session/version ownership before service edits |
| Depends on | Implemented T42A server contract |
| Blocks | T42B activation and G24 call evidence |
| Parallel safety | One owner for mobile call model/API/service and live call contract |

## Objective

Make the Flutter model and API honor the server's invited-participant and
versioned-CAS call schema, and prove create/transition/retry/stale/end behavior
against the live Go server.

## Read first

- `docs/audit-consensus.md` I42 and its T42A implementation note.
- `implementation/tasks/T42B-native-call-lifecycle.md` and its unapproved
  design status.
- `server/internal/httpapi/call_sync_handlers.go`,
  `server/internal/storage/call_authorization_test.go`, and the call domain
  response type.
- `mobile/lib/core/models.dart`, `mobile/lib/core/api_client.dart`,
  `mobile/lib/calls/call_service.dart`, `mobile/test/api_contract_test.dart`,
  and `scripts/test-api-contracts.sh`.

## Confirm first

Verify all three facts: the server rejects `expected_version <= 0`,
`CallSession` omits `version`/`invited_account_id`, and `transitionCall` omits
`expected_version`. If any fact is false, stop and return `stale` with the
current contract.

## Allowed write set

- The three mobile call/model/API files named above.
- `mobile/test/api_contract_test.dart` and a focused new call test if useful.
- `server/internal/httpapi/api_test.go` only for missing HTTP assertions.
- `scripts/test-api-contracts.sh` only if its existing live path cannot execute
  the new test.

Do not edit native iOS/Android code, permissions, manifests, push payloads,
signaling encryption, or crypto availability gates.

## Invariants

- The server's actor/state/version model stays authoritative and fail-closed.
- Every mutation sends the version of the session it intends to replace.
- A retry is accepted only under existing server idempotency semantics; a
  distinct stale mutation fails deterministically.
- Signaling metadata remains opaque ciphertext and is never logged.

## Work

1. Add focused model parsing tests for every server-required call field and
   malformed/missing version behavior.
2. Add a required positive `expectedVersion` to the Dart transition request and
   assert the exact JSON body in a client-level test.
3. At the advisor checkpoint, choose the smallest explicit ownership rule for
   the latest `CallSession` in `NativeCallService`. Do not hide missing state by
   defaulting the version to zero or one.
4. Update accept, reject, signal, and end paths to use/replace the latest
   returned session consistently.
5. Extend the live contract with a two-account DM: create, assert invitee and
   version, authorized answer, idempotent retry, rejected stale transition,
   end, and final model round-trip. Include an unauthorized actor assertion if
   the Go HTTP suite does not already exercise it.

## Acceptance

- No mobile transition can omit or invent `expected_version`.
- Call responses round-trip `version` and `invited_account_id` exactly.
- The live Go/Dart contract passes valid retry and rejects stale/unauthorized
  transitions with the expected typed server code.
- No T42B native capability or crypto-gated UI is activated.

## Required checks

```sh
cd server && go test ./internal/httpapi ./internal/storage
cd mobile && flutter test test/api_contract_test.dart
./scripts/test-api-contracts.sh
cd mobile && flutter analyze
```

The standalone Dart test may skip without its live-server environment; the
task is not complete unless `test-api-contracts.sh` executes the call path.

## Advisor checkpoint

Before changing `NativeCallService`, show every mutation call site and propose
where the current session/version lives. Ask for stale-event and concurrent
signal counterexamples. Stop if the answer requires the unapproved native T42B
design.

## Handoff

Use the exact workflow handoff with `Task: QA03`. State the tested state/version
sequence and confirm native platform files were untouched.
