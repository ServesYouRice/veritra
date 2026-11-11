# L1 review, 2026-11-11

Reviewed `067db28781a2d84654e1528363e988436c21ab2a..7f68fba` and the
inherited L1 paths from the three requested origin branches (all ancestors).
An independent review agent also inspected the security paths and approved
the chain-import fix. This is local implementation review, not G25 clearance.

## Fixed

`DeviceListPins.pinChain` verified only the incoming chain's internal
consistency. Its version CAS allowed a different genesis or signed fork at
the same or a higher version to replace the existing trust anchor. Imports
now require the exact stored head in their prefix and preserve conflicts.
Identical imports do not rewrite the pin. Three native tests exercise
alternate genesis chains, forks, rollback, conflicts and valid extensions.

## Still blocks full L1

- Linked-device anchoring calls `refresh` (and saves its TOFU pin) before
  checking the authenticated approver. A mismatch only logs and completion
  continues. The trusted approver must authenticate the new device's add
  before any chain is accepted; failure must survive restart without TOFU.
- Setup/registration save the session and MLS identity before pinning their
  locally signed genesis. Pin-write failures are swallowed. A later refresh
  or restart can accept a server-controlled genesis. This needs durable,
  recoverable enrollment anchoring, including failure/crash tests; merely
  throwing after those writes does not fix it.
- Complete adds still depend on server enumeration: reconcile filters
  `change.add`, and native initialization filters supplied packages. Neither
  derives the complete missing-device set from signed lists.
- Recovery-key retype and legacy-key confirmation UI, removed-message UI
  and the specified adversarial register/link/revoke/recover demo remain
  unfinished. Native tests cover the changed slice but not these lifecycles.

The assigned ABI 24, local schema 41 and migration 0074 remain unused.
The inherited code is ABI 21/local schema 34; this fix changes no persisted
format or ABI and adds no migration or dependency. Release entry points still
use `UnavailableCryptoService`; no release gate changed.

## Checks

- `go test ./...` and `go vet ./...`: pass.
- `cargo test`: 223 unit and 7 integration tests pass; 8 existing ignored.
- `cargo clippy --all-targets -- -D warnings`: pass.
- Six focused L1 Flutter test files: 67 pass, none skipped, using the supplied
  `VERITRA_CRYPTO_LIBRARY`.
- `scripts/lint.ps1`: pass (Go vet/format, Rust format/clippy, Flutter analyze
  and Dart format, 443 files unchanged).
- Full `scripts/test.ps1`: pass (policy fixtures, Go, Rust and 2,623 Flutter
  tests passed; 22 existing Flutter skips).
- `git diff --check`: pass.

The first redirected lint invocation was interrupted by Windows PowerShell
treating Cargo's successful stderr status as a terminating native error.
Running the unchanged script in a child PowerShell process passed. A redundant
redirected test invocation was stopped; the child-process run is authoritative.
