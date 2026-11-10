# B7 passkeys: evidence

Package B7, design `docs/designs/B7-passkeys.md`, owner defaults D93.

## S1 and S2: server (this change)

- Migration `0057_passkeys.sql` (tables only; an older binary ignores them).
- Go library `github.com/go-webauthn/webauthn` v0.18.2 (D89), with the
  transitive modules listed in `THIRD_PARTY_NOTICES.md`; licences checked in
  the module cache (BSD-3-Clause, MIT, Apache-2.0 for `go-tpm`).
- Tests in `server/internal/httpapi/passkey_test.go` use a software
  authenticator written in the test (ES256 and Ed25519, attestation `none`,
  Android app origin). They cover: register and sign in; wrong device
  secret, unknown device, revoked device and suspended account (same 401);
  wrong user handle; another account's credential and instance-unique
  credential IDs; replayed, expired and single-use ceremonies; two concurrent
  finishes (exactly one session); a passkey deleted and a device secret
  changed between verification and the writer transaction; backup
  eligibility change refused, backup state stored; sign-count regression
  refused and audited, synced passkeys (count 0) accepted; no `recent_auth_at`
  after a passkey sign-in and `recent_auth_required` on every
  `withRecentAuth` route; registration refused without recent auth; shared
  backoff with the password path and no lock-out by strangers; the 10-passkey
  limit, rename, delete, audit and sync events (row ID only); the
  4-ceremony cap and device-revoke cleanup; account deletion cleanup;
  well-known files, setup status and the off-by-default 404/503.
- `config` tests: startup refuses a port, an IP, `localhost`, `http` and a
  host without a dot; app lists are parsed and validated.
- `account_recovery_test.go`: K0 completion deletes passkeys, the handle and
  open ceremonies (S2, O5 default).
- Account export lists passkey name and times only.

# B7 passkeys and accounts — integration evidence

2026-11-09, Windows, branch `ai/b7-passkeys`, base
`6a62e3c68bdabc7f3854795246cc516ce5d00513`.

## Scope and source

Ported PR #169 from `origin/agent/b7-phone`: `bbb728d`, `4516cfa`,
`098c43b` and its review fixes `691c615`. The later K0 test-date change was
already superseded on this base (2099 rather than 2030), so it was skipped.
Preserved current profiles, reporting, automatic backups and phone notices
when resolving the overlapping AppState, demo entry point and settings code.

S1–S2 were already on the base (server migration `0057_passkeys.sql`). This
port adds no schema, server migration or ABI number. `STATE.md` is unchanged.

## Additional integration fixes

- A cold demo wake selects only the protected registry's active account.
  The native bound profile must match it; unreadable registry state opens
  no background runtime. Every demo account retains the existing phone
  notice build switch and binds/uninstalls its own wake worker.
- Desktop preview preferences are actually wired per slot. A new slot
  copies the primary choice before the primary can be removed. Late settings
  reads after teardown stay silent.
- C6 report seeds use slot-specific keystore names; the primary retains its
  existing names. Removing a slot erases its seeds and preferences only.
- Switching waits for serialized native crypto disposal and desktop teardown.
  Old desktop notifications are closed, and late notification work is refused.
  Failed desktop startup closes the attempted runtime before rollback.
- Added the passkey entitlement fixtures to the Windows test script and
  documented the matching Apple entitlement/Dart-domain build inputs.
- Removed a trailing blank line in the base's `recovery_bound_test.go` that
  prevented the required gofmt check from passing.

## Checks

- `flutter pub get --enforce-lockfile`: passed with the port's pinned plugin
  family and existing dependency notices.
- B7 passkey, slot, host, screen, isolation and wake tests: passed. Extra
  regression tests cover report-seed erasure, copied privacy settings,
  native-handle drain, desktop-start rollback and delayed notices/settings.
- `flutter analyze`: passed; Dart formatting passed.
- Full `flutter test` with `VERITRA_CRYPTO_LIBRARY` naming this worktree's
  absolute Windows DLL: 2,599 passed, 22 skipped in the final script run.
- `go test ./...`, `go vet ./...`: passed.
- `cargo build --release`, `cargo test`, `cargo clippy --all-targets -- -D warnings`:
  passed (223 Rust unit tests and 7 integration tests; measurement/vector
  generators remain ignored).
- `scripts/lint.ps1`: passed.
- `scripts/check-demo-boundary.sh`: passed, using the repository's Python
  shim helper on Windows. Release slots retain `UnavailableCryptoService`.
- `scripts/license-check.sh`, passkey entitlement fixtures (4 tests), Serbian
  Latin generation check and `git diff --check`: passed.
- Final `scripts/test.ps1`: passed (policy fixtures, Go, Rust and all Flutter tests).

The added `demo_e2e_test.dart` B7 case passed against a freshly built Go
server on loopback and the real Windows OpenMLS DLL. One AccountHost creates
two accounts, switches back and forth, receives messages sent while paused,
and keeps the second account's draft out of the first. The test waits for
server acceptance before pausing a sender: a durable queued send is not yet
an upload. It runs through the existing demo e2e scripts, without CI changes.

## Decisions and remaining evidence

D93/O1–O10 retained: fixed compiled Apple hosts, Linux password-only,
password-only recent auth and K0 claims, passkey deletion on K0 completion,
operator opt-in, paused inactive accounts, five accounts, passwords retained,
and a same-server linkability warning. No release gate was changed.

S7 remains open: a Windows Hello hand run and signed Android/iOS passkey
ceremonies/associations on devices. Apple builds cannot be exercised on this
Windows host. No new platform CI evidence, independent review, signing or
release approval is claimed. Work was performed alone as requested; the
original branch's review fixes are preserved. No push or PR change was made.

## Independent review fixes (2026-11-09)

Reviewed the port against `6a62e3c68bdabc7f3854795246cc516ce5d00513`
with an independent credential/storage and lifecycle review agent.

- Primary-account removal left interrupted attachment ciphertext and
  plaintext working files behind. Removal now uses the orphan sweeper's
  exact filename allowlist, without its age guard, and propagates deletion
  failures to the removal journal. The disk regression includes all four
  working-file forms, a fresh plaintext partial, an unrelated file and a
  sibling account's attachment and database.
- Push setup and endpoint registration could complete after teardown took
  its subscription snapshot. A separate push generation now fences starts
  and events, outstanding setup/registration is drained with a timeout,
  and late server/native registrations are removed. Uncertain teardown
  still requires the existing switch-anyway confirmation. Cancelling the
  switch waits for old registrations before restarting push.
- A native wake-uninstall failure no longer skips the cancelled worker's
  atomic drain. The drain runs in `finally`.
- A B7 build-plan edit in `STATE.md` was already present on takeover. It
  was left untouched and excluded from the completion commit. No schema,
  server migration or ABI change; the supplied reservations are unused.

The live demo script passed both tests on repeat, using the local Go build
and this worktree's Windows OpenMLS DLL. Its first run passed the B7 case
but failed the existing device-link approval assertion at
`demo_e2e_test.dart:323`. The unchanged K2/device-list path was independently
inspected; the transient cause remains unknown. No link validation was
relaxed to obtain the repeat pass.

## Takeover verification (2026-11-10)

Worked alone, preserving the existing port commits and finishing the
previously uncommitted lifecycle fixes above. Compared the remote phone
branch and retained its implementation and review fixes.

The broader live demo reproduced the device-link approval failure twice.
A temporary exception-type/stack diagnostic located it in `pinOwnStep`:
sync can verify and pin the server-accepted statement before the approval
POST returns. Pinning the exact same signed bytes is now a no-op. Different
bytes still go through native verification. The native-backed regression
checks both the no-op and rejection of an altered statement without changing
the pin. The diagnostic was removed.

- Focused B7 tests: 108 passed; native device-list pin tests: 17 passed.
- Final `scripts/test.ps1` passed: policy fixtures, Go, Rust and the full
  Flutter suite (2,604 passed, 22 skipped), with the absolute native DLL path
  pointing into this worktree. `git diff --check` passed.
- Both live Go/OpenMLS demo tests passed after the fix, including account
  switching, device approval and linked-device convergence.
- `go test ./...`, `go vet ./...`, `cargo test`, `cargo build --release`,
  and `scripts/lint.ps1` passed. Clippy runs with all targets and warnings
  denied; Flutter analysis and formatting passed.
- Demo/release boundary check passed. Release messaging remains gated.

PowerShell's in-process output redirection treats expected native stderr as
an exception. The script reruns use outer `cmd /c` redirection. Concurrent
Flutter test commands also hit a native-assets file lock; those checks were
rerun after the full suite released it.

No new dependency, counter, CI, remote branch or release-policy change.
D93 defaults remain in effect. S7 hardware/signing evidence stays open.
