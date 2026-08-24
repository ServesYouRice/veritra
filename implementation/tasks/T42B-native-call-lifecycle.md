# T42B — Native incoming and active call lifecycle

| Field | Contract |
|---|---|
| Consensus source | I42 platform scope; R13/R14 |
| Routing snapshot (board wins) | Design approval required; conditional under D03 |
| Risk | High call-scope blocker |
| Executor | Strong |
| Advisor | Required before choosing native architecture and before entitlements/permissions |
| Depends on | Explicit platform design approval; coordinate T42A protocol |
| Blocks | G24 call evidence |
| Parallel safety | One owner for iOS/Android native call integration and manifests |

## Objective

Implement a documented native incoming/active-call path that survives supported
background states and obeys current iOS/Android policy without contentful push.

## Read first

- `docs/audit-consensus.md` I42 and reconciled source IDs R13/R14.
- `mobile/lib/calls/call_service.dart`, push service, Android manifest/native
  runner, iOS plist/Runner and platform tests.

## Invariants

- Push contains no sender name or message/call content; fetch/decrypt locally after wake.
- If PushKit is chosen, report via CallKit as current Apple policy requires.
- Declare only foreground-service types/permissions the final Android design uses.

## Work

1. Write a short approved design for incoming, active, terminated and denied states.
2. Implement native lifecycle and permission handling on both platforms.
3. Integrate local encrypted signaling fetch after generic wake.
4. Test denied permissions, background/terminated, lock screen and network change.

## Acceptance

- Platform lifecycle is documented and policy-compliant.
- Automated platform config tests pass; G24 real-device/TURN matrix is executable.
- No push/log content leaks identity or call payload.

## Required checks

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_actionable_test.dart
```
