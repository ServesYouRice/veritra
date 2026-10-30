# D52 server subscription capability - 2026-10-28

Status: server slice implemented and focused checks pass. Independent review
and Linux confirmation are pending. No client advertises this capability;
native silent/background coordinator readiness and phone evidence remain
required before enabling it. This does not complete mobile mention notices.

Migration 0040 adds subscription-scoped `notification_mode`, defaulting to
`legacy_generic`, with the other accepted value `local_decrypt_v1`. HTTP
registration returns the accepted mode. Omitted registration resets legacy
even on endpoint/key upsert; explicit empty/null/unknown/non-string values
reject. Opt-in registration transactionally requires an actual matching,
unrevoked device and active account. Legacy callers retain their wrapper.

Enqueue, claim and immediate pre-send refresh permit muted wakes only for
the current subscription's opt-in mode. Existing membership/block/disabled/
revocation conditions stay conjunctive. An in-flight downgrade cannot emit
a muted legacy wake. Mode propagates through the actual app worker and
self-test target refresh. Self-test results identify mode and, for opt-in,
`presentation:none`; acceptance is not evidence of a displayed notice.

All provider opt-in payloads are exactly the generic v2 event with
`presentation:none`. Legacy v1 stays unchanged. FCM remains data-only/normal
priority, APNs retains only `aps.content-available`/background/priority 5,
and WebPush retains encrypted transport. Unknown internal modes fail closed.
No sender/conversation/mention/content/ciphertext fields are introduced.

Frozen runtime files: new `domain/push_mode.go`, migration0040, plus narrow
edits to storage subscription/wake methods, HTTP registration/self-test,
app provider call and push provider payload selection. New tests named
`push_notification_mode_test.go` in storage/HTTP/app and
`push/notification_mode_test.go`. No dependency/mobile/Rust/STATE edits.

Checks from `server`, Windows:

```text
go test -p 1 ./internal/push ./internal/storage ./internal/httpapi ./internal/app -run 'TestNotificationMode|TestPushNotificationMode|TestPushRegistration|TestTestPush|TestTimedMute' -count=1
PASS (push0.997s/storage1.497s/HTTP1.908s/app1.773s)

go test -p 1 ./internal/push ./internal/storage ./internal/httpapi ./internal/app -count=1
push PASS1.203s; storage PASS36.296s; HTTP PASS24.204s
app FAIL: Windows filesystem capacity metrics absent in
TestAlertRulesReferenceExportedMetricsAndRunbooks and
TestCapacityMetricsAreAggregateAndClosedLabelled
```

The full run preceded the final opt-in registration device/account tightening;
the final focus above includes that change. App worker tests pass. No platform
test policy was changed to hide the full Windows failure. Linux full app
confirmation belongs to the coordinator.

Tests cover same-account second-device legacy isolation, omitted upsert,
current mode at queue/claim/refresh, downgrade before claim/send, preserved
block/membership/disabled/revoked checks, privacy-safe worker metrics/logs,
registration/device/account guards and silent self-test semantics. Provider
tests inspect FCM/APNs requests and independently decrypt the actual WebPush
body to assert its exact allowlist. Existing rate policy stays unchanged.

Independent coordinator review found no blocking issue in mode validation,
transactional device binding, omitted-field downgrade, current-mode resolution
or provider payload selection. Independent Linux checks (pinned Go 1.26.10)
pass on the frozen migration0040 server snapshot:

```text
go test -p 1 ./... -count=1
PASS (all packages, including app filesystem metrics tests)
go test -race -p 1 ./internal/push ./internal/storage ./internal/httpapi ./internal/app -run 'TestNotificationMode|TestPushNotificationMode|TestPushRegistration|TestTestPush|TestTimedMute' -count=1
PASS (push1.182s/storage7.345s/httpapi5.583s/app4.531s)
gofmt -l . && go vet ./...
PASS (no formatting output)
```

Ignored local logs: `build/silent-verification-results/`. This confirms the
server capability only. Native lifecycle and bounded Dart decryption/notification
work remain separate; existing clients still register in legacy mode.
