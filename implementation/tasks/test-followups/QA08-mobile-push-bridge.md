# QA08 — Test the Flutter push platform bridge

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M3 at `3ee785d` |
| Canonical owner | T41 mobile platform readiness |
| Initial eligibility | Blocked until I41 is eligible under D03 and I36 |
| Risk | High conditional wake-contract gap; bounded Dart test scope |
| Executor | Balanced |
| Advisor | Only if the current provider interface or native protocol must change |
| Depends on | Eligible T41 claim |
| Blocks | Automated portion of T41/G24 push evidence |
| Parallel safety | Mobile push service/test only; may run beside QA06/QA07 |

## Objective

Prove the active MethodChannel/EventChannel contract for registration events,
generic wakes, pending generations, acknowledgement, malformed input, and
disposal. Do not recreate the removed background Dart isolate or local message
notifications.

## Read first

- `docs/audit-consensus.md` I41 and `implementation/tasks/T41-push-platform.md`.
- `mobile/lib/push/push_service.dart`, native channel handlers on Android/iOS,
  `mobile/test/app_state_test.dart`, and `platform_config_test.dart`.

## Confirm first

Verify no Flutter test instantiates `PlatformMobilePushService` or mocks its
two channel names. If a current suite covers every acceptance item, return
`stale`. Do not claim this while I41 is blocked.

## Allowed write set

- New `mobile/test/push_service_test.dart` and narrow test helpers.
- `mobile/lib/push/push_service.dart` only for a pure-Dart defect reproduced by
  the new test.

Do not edit Kotlin/Swift, manifests/entitlements, `app_state.dart`, push server
code, add a notification dependency, or change payload content.

## Invariants

- A wake carries no sender, name, message, conversation, endpoint, token,
  secret, or ciphertext.
- Malformed/unknown native events are ignored safely and do not throw into the
  event loop.
- Only a positive pending generation may be acknowledged.
- Tests clean up mock handlers/subscriptions so order does not affect results.

## Work

1. Install mock handlers for the exact method/event channel names and capture
   all outgoing methods/arguments.
2. Assert register, distributor selection, unregister, pending generation, and
   acknowledgement method names, argument shapes, nulls, and typed returns.
3. Inject valid endpoint/provider, wake, and unregister events and assert the
   exact Dart event types/fields.
4. Inject non-map, unknown type, missing field, wrong field type, malformed
   generation, zero/negative acknowledgement, duplicate generation, and an
   event after disposal. Assert safe behavior and no unintended native call.
5. If tests expose a provider-selection redesign rather than a bridge bug,
   stop and return `blocked` for the T41 advisor; do not invent the API.

## Acceptance

- Every public `PlatformMobilePushService` operation has channel-contract
  coverage and malformed replies fail safely.
- Event decoding accepts only complete typed endpoint/unregister events and a
  generic wake.
- Generation acknowledgement cannot run for non-positive values and its native
  result is preserved.
- Disposal cancels delivery and all mock handlers are removed.
- No contentful notification/background-isolate behavior is introduced.

## Required checks

```sh
cd mobile && flutter test test/push_service_test.dart test/app_state_test.dart test/platform_config_test.dart
cd mobile && flutter analyze
```

## Advisor checkpoint

If the smallest fix changes provider selection, wake-generation semantics, or
the native method/event schema, stop and ask the T41 advisor to approve that
contract before editing any production file.

## Handoff

Use the workflow handoff with `Task: QA08`. List event/method cases and confirm
native platform files and `app_state.dart` were untouched.

