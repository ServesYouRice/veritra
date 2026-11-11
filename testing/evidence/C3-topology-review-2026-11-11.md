# C3 topology review, 2026-11-11

Reviewed `e9aee56d5f0999bde775512dc40ccd52a2b10be6..9500b74` on
`ai/c3-rest`, including the author's `.ai-report.md`, the C3 design and
the inherited `origin/agent/c3` history. Independent review covered MLS
ordering, privacy boundaries and the fix below.

## Fixed

Server topology could relabel an already accepted private channel as open.
Ordinary editing and community-key rotation then reused its cached contents
under the community key, exposing its name/topic/icon to community members
outside the private channel. Announcement healing could also endorse that
cached private record in the shared group.

Publication and announcement healing now require the accepted record's key
to be held in the proposed key home. Implicit cross-home publication fails
closed; interrupted rotations retain their mark. Explicit channel conversion
is still unimplemented. Initial topology authenticity remains a separate
design residual.

Two regression cases cover editing and rotation after a private-to-open
relabel. Without the guards, editing unexpectedly succeeds and rotation
returns 1 instead of 0. With the guards, neither uploads a replacement or
announces the private record in the shared group. The service suite passes
all 50 tests. An independent review found no concrete flaw in the mitigation.

## Still incomplete

- Production has no verified C4 role source; tests inject one. The channel
  info restriction flag is also absent from production role state.
- Remote/moderator removals do not trigger info-key rotation on an admin's
  device. The owner-required immediate rotation is therefore incomplete.
- Creation still sends plaintext names. Server refusal and column removal,
  channel conversion, category/icon screens and production integration
  coverage remain outstanding.
- The earlier documented unbounded key-identity tombstones remain.

Local schema remains 32; reserved schema 35 and migration 0067 are unused.
No dependency or ABI changes. `main.dart` still uses
`UnavailableCryptoService`; release messaging remains gated.

## Checks

- Narrow Go storage/domain tests and `go vet ./...`: pass.
- Full `go test ./...`: pass.
- `cargo test`: 230 passed, 8 existing ignores; clippy with warnings denied: pass.
- `cargo build --release`: pass. Full Flutter verification uses this
  worktree's release DLL, overriding the supplied DLL from another checkout.
- Initial focused C3 Flutter checks: 116 passed; new service suite: 50 passed.
- Full Flutter suite with this worktree's DLL: 2,458 passed, 21 existing skips.
- `scripts/lint.ps1`: pass, including Flutter analyze and format checks.
- `scripts/test.ps1` with redirected output stopped on expected stderr from
  the Dart retraction adversarial fixture (Windows PowerShell's
  `NativeCommandError`). The release evidence fixtures had passed. All
  remaining Python fixtures were then run directly and passed, as did the
  Go, Rust and Flutter suites listed above. The wrapper did not complete;
  its test components all passed.

The first redirected lint attempt stopped because Windows PowerShell treats
Cargo's ordinary stderr progress as a terminating `NativeCommandError` with
`*>` and `Stop`. Running the unmodified script directly passed.
