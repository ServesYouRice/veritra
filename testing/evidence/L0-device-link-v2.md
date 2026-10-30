# L0 device link v2 — 2026-10-26

Status: implemented, independently agent-reviewed; full Linux verification passes.
Owner order D50: L0, W8, K2, communities. No commit, push or release performed.

## Change

- Rust ABI v7 and protocol v2: 128-bit client-generated secret; public
  SHA-256 locator; HKDF/HMAC-SHA256 safety code and separate claim/approval
  MACs. The secret and safety code never enter HTTP. Claim never sends the
  approval MAC. No added dependency.
- Transcript binds configured canonical server origin, link ID, account,
  nonce and both ordered device IDs/signing keys. QR/manual input uses one
  26-character base32 code, with optional spaces/hyphens for manual input.
- The old device refuses missing/invalid claim MACs. The new device refuses
  missing, truncated, reflected or incorrect approval MACs before returning
  a session, and pins the final account/device and server origin before
  persistence. JSON API requests refuse redirects.
- Migration 0037 retains existing sessions/devices, retires unfinished v1
  links, and stores only the opaque MACs. Existing links must be recreated.
- The disk-allocation benchmark was moved to a Unix-only test file so
  `syscall.Stat_t` no longer prevents Windows Go tests/vet from compiling.
  The reauthentication contract test now attaches its expected error handler
  before answering the request, fixing a timing-sensitive unhandled error.

Design: [`L0-device-link-v2.md`](../../docs/designs/L0-device-link-v2.md).
K2 must version its transcript when it adds a transfer key. L0 does not solve
server-inserted devices outside linking; the signed approved-device list (L1)
remains separate. Production messaging gates are unchanged.

## Passing checks on this Windows host

- `go test ./internal/storage ./internal/httpapi -run TestDeviceLink -count=1`:
  passes, including malformed MACs, single-use/expiry, migration 0036→0037,
  repeated migration, and preserved device/session identity.
- Full `go test ./...`: storage and HTTP API packages pass; app package has
  the Windows failures below. All other listed Go packages pass.
- `cargo +1.91.0-x86_64-pc-windows-msvc test --locked`: 29 unit tests and
  2 integration tests pass; 2 measurement tests intentionally ignored.
  Includes independently computed Python hashlib/hmac link vectors,
  RFC HMAC/HKDF vectors, every transcript-field mutation, secret lengths,
  FFI locator bounds, and unchanged production fail-closed checks.
- Native DLL built using `cargo build --locked`.
- Flutter: 103 tests pass across `api_contract_test.dart`,
  `native_crypto_bindings_test.dart`, `app_state_test.dart`,
  `ui_actionable_test.dart`, `settings_about_test.dart`,
  `device_link_code_test.dart`, `device_link_api_test.dart`.
  `VERITRA_CRYPTO_LIBRARY` points at the actual Windows DLL. A temporary
  loopback-only Go server ran the live contract (including enrollment,
  claim, both native derivations, approval and session completion), then
  stopped. The redirect test verifies its second server receives no request.
- `scripts/lint.ps1`: passes (Go vet/gofmt, Rust fmt/clippy, Flutter analysis
  and Dart formatting). Locked Flutter dependencies restored unchanged.

## Initial Windows full-suite limits

`scripts/test.ps1` was attempted with the installed Python interpreter
provided as `py` (the default Windows launcher cannot find it). Its release
fixture script exits during cleanup: `shutil.rmtree` cannot remove a
read-only temporary Git object (`PermissionError: WinError 5`). Directly
rerunning that script reproduces the same failure. This is not a successful
full test-script run.

The language suites were also run separately:

- Go app backup/restore tests fail syncing directories on Windows
  (`Access is denied`); related backup metrics checks also fail.
- Full Flutter tests fail deleting temporary encrypted-database directories
  while Windows still reports open handles (`errno 32`). The initial run's
  separate reauthentication fixture failure is fixed and passes in the
  final focused/live run; the full suite has not been rerun after that fix.
- Docker was initially stopped; the later Linux run below resolves the missing
  full-suite evidence.

These failures initially kept L0 verification pending. The later Linux full
suite passes. Mobile platform builds and a hand-operated QR scan were not
performed here.

## Independent review

A separate review agent designed the protocol and reviewed the Rust and
final cross-layer diff. Claude Opus was unavailable; the available inherited
model supplied this second opinion. Findings fixed: pin server origin on
both sides before sending credentials, pin completion identity before
storage, and prevent redirects forwarding the custom claim-token header.
Final review: no blocking security/correctness findings, high confidence.
This agent review does not satisfy the independent human review gate G25.

## Full Linux verification (2026-10-28)

The isolated full test and lint scripts now pass. See
[`verification-2026-10-28.md`](verification-2026-10-28.md) for scope, counts
and log hashes. This supersedes the earlier lack of a Linux fallback; the
Windows-specific failures and platform evidence limitations remain.
