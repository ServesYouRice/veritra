# D52 native notice capture and bounded receive fences

2026-10-29, Windows x64, local debug native library. Capture remains off by
default; this evidence covers the crypto producer, not AppState activation or
Android/iOS background execution.

## Behavior

`NativeCryptoService` retains the canonical origin from successful session
activation. A `NoticeCaptureConsumer` capability enables metadata-only references
for newly decoded inbound text, replies and attachment inserts. References join
the MLS state/effects/cursor transaction. They contain owner, event, message,
sender and conversation identifiers plus timestamps; no body, attachment secret,
filename or ciphertext is copied into a reference.

Capture authorization is frozen before enqueue. Enabling capture later cannot
retroactively capture an earlier operation. Disabling or changing the captured
owner revokes that operation with `CryptoOperationCancelled`, so required
references cannot silently disappear while the cursor advances. Commit fences
run inside storage transactions and failures restore the prior native ratchet.
There is no cancellation check after a successful atomic commit.

Bounded existing-session activation cannot create missing crypto state or
complete pending enrollment. Bounded control, application and call receives keep
the original public unbounded signatures available.

## Checks

- Targeted Dart analyzer: `crypto_service.dart`, `native_crypto_service.dart`
  and `native_notice_capture_test.dart`: no issues.
- `flutter test --no-pub --concurrency 1 test/native_notice_capture_test.dart`,
  invoked through the installed Flutter tool snapshot: **8 passed, 0 skipped**.
- Native DLL SHA256:
  `cb47052648129fcca32779fe46525ed7911dad753b462e5bae466281faf79d06`.

Tests use real MLS groups and ciphertext. They cover default-off capture;
metadata-only text/reply/attachment admission; duplicate exclusion; midflight
enable; queued and commit-time disable with unchanged state/cursor and successful
retry; own-account/action/invalid/hidden/sender-mismatch/expired exclusion; and
bounded Welcome, control echo, sender mismatch, call and application-echo
cancellation/retry. The recording memory store delegates atomic commits to the
real MemoryLocalStore before observing references.

These tests do not establish phone lifecycle delivery, native OS notification
behavior, AppState policy activation, release eligibility, or SQL-specific
rollback. Those are separate integration checks owned by their respective slices.
