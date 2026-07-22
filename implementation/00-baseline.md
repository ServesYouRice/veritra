# Plan 00 — Restore a trustworthy baseline

Complete B01 and B02 before feature work. B03 is the gate. B04 is optional
developer-experience work after the baseline is green.

## B01 — Reconcile the fail-closed setup notice

Audit references: TEST-01, UI-12.

Objective:
Make the embedded setup page satisfy the committed security contract without
adding a setup form or implying that production crypto exists.

Read first:

- server/websetup/index.html
- server/websetup/websetup_test.go
- README.md setup section
- docs/deployment.md setup-token section

Steps:

1. Confirm each required phrase is absent from the page.
2. Treat the test as the intended fail-closed contract.
3. Update the page copy to explain that setup is unavailable in this build,
   the instance must remain private, placeholder/test key packages are
   forbidden, and PRIVATE_MESSENGER_SETUP_TOKEN is required for remote setup.
4. Keep the page form-free and do not add JavaScript or a browser crypto path.
5. Run the focused Go test, then the server test suite.

Acceptance:

- TestSetupNoticeFailsClosed passes unchanged unless a wording-only adjustment
  is justified and preserves every security assertion.
- The page contains no form and no owner-creation fields.
- No secret is placed in HTML, URLs, logs, or examples.

Verify:

- cd server && go test ./websetup
- cd server && go test ./...

## B02 — Fix the locked MobileScanner API usage

Audit references: TEST-02, UI-02.

Objective:
Restore Flutter compilation using the already locked mobile_scanner 7.2.1 API.

Read first:

- mobile/lib/features/auth/qr_scan_screen.dart
- mobile/pubspec.lock
- existing mobile widget tests

Steps:

1. Confirm the callback signature expected by the locked package from the
   resolved dependency source or compiler error.
2. Change only the callback shape needed by version 7.2.1.
3. Add focused coverage for the scanner error presentation if it can be
   injected without platform camera access.
4. Do not upgrade the dependency for this fix.
5. Run formatter, analyzer, and Flutter tests.

Acceptance:

- QrScanScreen compiles against the lockfile.
- Permission-denied and unsupported-device copy remains reachable.
- No dependency or lockfile changes occur.

Verify:

- cd mobile && flutter pub get --enforce-lockfile
- cd mobile && dart format --set-exit-if-changed .
- cd mobile && flutter analyze
- cd mobile && flutter test

## B03 — Run and record the canonical gates

Depends on: B01, B02.

Objective:
Establish one honest green baseline before feature work.

Steps:

1. Start from a clean dependency environment.
2. Run scripts/test.ps1 and scripts/lint.ps1 on Windows, or the matching shell
   scripts on Linux.
3. Run scripts/release-readiness.sh separately.
4. Treat the release-readiness failure for unavailable production crypto as
   expected until C13. Any other failure blocks the task.
5. Record exact tool versions and results in the task handoff. Update
   REMAINING-WORK.md only with results actually observed.

Acceptance:

- Server, Rust, and Flutter test/lint phases pass.
- Release readiness fails only for the explicit production-crypto gate.
- No test was skipped or weakened.

## B04 — Add scoped verification commands

Audit reference: NICE-11.

Objective:
Make local feedback faster without replacing the canonical aggregate gates.

Steps:

1. Inventory repeated commands in scripts/test.*, scripts/lint.*, and CI.
2. Add small documented entry points for server, crypto, mobile, contract, and
   end-to-end checks.
3. Keep pinned images, lockfiles, and aggregate nonzero exit behavior.
4. Avoid adding a task runner dependency.

Acceptance:

- Each scoped command runs independently.
- The existing aggregate commands still run every required phase.
- Documentation identifies the aggregate commands as the release gate.

