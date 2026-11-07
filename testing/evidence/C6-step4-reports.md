# C6 step 4: report screens (evidence)

Package C6 "Reports" step 4, branch `agent/c6`. No counter bumps (crypto ABI
13, local schema 20, migrations to 0050 stay as on main).

## What changed

- Server: `GET /api/v1/reports/{id}/envelope?envelope_id=` (recipient of that
  copy only, envelope of the report's conversation only, read-only, no
  logging). Test: `TestReportEnvelopeRecordGoesToTheCopyHolderOnly`.
- App: `ApiClient` report calls, `core/report_models.dart`,
  `core/report_seed_store.dart` (keystore custody), `core/reports_service.dart`
  (pin, seal, file, open, verify, dismiss), `AppState.reportsService`,
  `features/reports/*` (report screen, owner inbox), the message-menu action,
  the Settings entry, English and Serbian strings (Latin regenerated).
- `main_demo.dart` passes `SecureReportSeedStore`. `main.dart` (release) is
  untouched; `UnavailableCryptoService` still refuses and reporting is not
  offered there.

## Checks run

- Go: `go vet`, `go test ./internal/httpapi ./internal/storage` pass.
- Flutter 3.44.0: `flutter pub get --enforce-lockfile`, `flutter analyze` (no
  issues), `dart format --set-exit-if-changed .` (0 changed).
- `test/c6_reports_service_test.dart` (real native seal, ABI 13 library built
  with `cargo build --release`, `VERITRA_REQUIRE_NATIVE_CRYPTO=1`): pin,
  file, open, verify, dismiss; forged key mismatches; changed key refused;
  other-key and tampered copies do not open; community and unreportable
  messages refused; key custody and second-device replace.
- `test/c6_report_screens_test.dart`: both screens.

## Independent review (opus-expert) and fixes

Fixed: seed store now uses the repo's keystore options (no reset on error,
first-unlock-this-device, login keychain on macOS); the preview is built from
the kept proof `P`, not the edited message; a failed key replace restores the
old seed and the warning says old reports are lost on this device; verification
checks context first, shows the sender only on a match, and refuses a report
whose sender is the reporter; replies are readable; the envelope route honours
`expires_at` and the 90-day window; attachment wording says the file key is sent.

Left: after a second device replaces the key the first device still shows its
old code (needs a route that returns an owner their own key); the seed is not
deleted on sign-out; "Trust" for a changed key is the same tap as for a new one.

Native tests need `VERITRA_CRYPTO_LIBRARY=<repo>/crypto/rust/target/release/libprivate_messenger_crypto.so`.
