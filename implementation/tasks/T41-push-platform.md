# T41 — Push registration and platform readiness

| Field | Contract |
|---|---|
| Consensus source | I41; LOG-09/UI-06/NTH-01/NTH-05; S12/H6 |
| Initial eligibility | Blocked, conditional under D03 |
| Risk | High when push is in release scope |
| Executor | Balanced+advisor |
| Advisor | Review provider matrix and privacy-safe diagnostics |
| Depends on | T36B |
| Blocks | G24 push evidence |
| Parallel safety | One owner for push service, native manifests and settings diagnostics |

## Objective

Make registration provider-aware, expose typed permission/registration state,
add required Android permission and provide privacy-safe test-wake diagnostics.

## Read first

- `docs/audit-consensus.md` I41.
- Named Codex/Opus findings.
- `mobile/lib/push/push_service.dart`, settings/connection UI, API client/models,
  Android manifests, iOS plist/runner integration, server push package and tests.
- Current [Android notification permission guidance](https://developer.android.com/develop/ui/views/notifications/notification-permission).

## Invariants

- FCM does not require VAPID; provider requirements remain distinct.
- Push and diagnostics never expose sender/content, endpoint, auth secret,
  message ID or ciphertext.
- Rich notification content remains deferred.

## Work

1. Model provider-specific configuration and typed states/errors.
2. Fix registration/rotation/revocation across FCM, APNs and UnifiedPush/WebPush.
3. Add Android 13+ permission and correct iOS-facing copy.
4. Add generic test wake and safe diagnostics timestamps/status.
5. Cover denied permission, missing provider and token rotation.

## Acceptance

- Provider-only and mixed configurations register/revoke correctly.
- Denials/provider errors are actionable without leaking sensitive values.
- Real-device wake matrix is ready for G24.

## Required checks

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_actionable_test.dart test/api_contract_test.dart
cd server && go test ./internal/push ./internal/httpapi
```

