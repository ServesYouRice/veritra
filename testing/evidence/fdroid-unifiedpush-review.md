# F-Droid / UnifiedPush review, 2026-11-11

Base: `6fba07ff736030557ae87025d01474d040b15faa`; branch `ai/fdroid-unifiedpush`.

Fixed missing UnifiedPush provider filters in conversation/account targets and
message enqueue, and the worker/metrics provider list. The regression exercises
message persistence through the real queue and worker, with a fake delivery
provider; it also checks account and conversation targets and privacy of metrics.

Fixed Android provider selection after process death with durable instance-bound
registration state. Added JVM selection checks and Dart pending-rotation tests
with encrypted/keyless endpoints and no VAPID. Missing VAPID is passed as null,
as required by the [connector API](https://unifiedpush.org/kdoc/connector/org.unifiedpush.android.connector/-unified-push/register.html),
instead of an invalid empty key.

Fixed CI, demo instructions, and reproducible-build flavor/artifact selection.
CI now builds both release flavors and checks the F-Droid runtime graph for
Firebase and Google Play services. Neither release gate nor signing changed.
The exact Play output is selected for reproducibility rather than globbing
across flavors or stale artifacts.

Replaced the vacuous HTTP SSRF test with HTTPS using a trusted test certificate,
added redirect coverage, and reject off-curve recipient keys at registration.
Corrected the lifecycle test's previously invalid P-256 key. Removed the false
D107 citation: that number already belongs to the desktop update decision.
Migration 0084 is not needed: provider storage is unconstrained TEXT.
No dependency versions changed; existing connector is Apache-2.0 and server Web
Push library is MIT. Notices correctly distinguish Google Play services from
Apache-licensed Google Tink.

Independent read-only security/platform review identified routing, restart,
flavor integration, SSRF-test, and decision-number issues; the second review
accepted the fixes and identified a test cancellation race, which was fixed by
waiting for queue deletion before cancelling the worker.

Checks completed:
- Focused Go UnifiedPush/app/HTTP/metrics tests pass; provider/storage suite passes.
- `go test ./...` and `go vet ./...` pass. One concurrent full run hit an
  unchanged blob-cleanup timeout (452/520 keys); the full test script and final
  Go run passed.
- `cargo test`: 223 unit + 7 integration tests pass; 8 ignored measurements/vector printers.
- `cargo clippy --all-targets -- -D warnings` passes.
- `flutter analyze --no-pub` passes.
- `flutter test --no-pub`: 2,624 pass, 22 pre-existing conditional skips;
  VERITRA_CRYPTO_LIBRARY points to an existing library.
- Focused Flutter push/platform tests: 20 pass.
- JVM wake/endpoint rules: 60 checks pass.
- Gradle immutable-input check passes.
- `scripts/test.ps1` passes (policy fixtures, Go, Rust, Flutter).
- `scripts/lint.ps1` passes (run through a child PowerShell to avoid parent
  stderr redirection turning successful native-command output into errors).

Limits / outstanding verification:
- `flutter build apk --release --flavor fdroid --no-pub` cannot start: no Android
  SDK. Kotlin/Gradle compilation and actual flavor dependency graph remain
  unverified. No push was made, per the review instruction.
- Extra `check-demo-boundary_test.py` and `check-demo-boundary-imports_test.py`
  fail on the same two unchanged Windows/Git Bash symlink fixtures: "symlinked
  intermediate file" and "symlink to a deeper folder". Guard and fixtures are
  unchanged by this branch; the POSIX-only fixture limitation is recorded,
  rather than changing a release boundary during this review.
