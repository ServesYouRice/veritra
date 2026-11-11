# C3 creation UI follow-up — 2026-11-10

Scope: a tested creation/member-selection slice, not completion of C3.
`origin/agent/c3` is already an ancestor; the inherited c3-2 sender work is
present. The review's build-log removal is already committed at `1609abc`.

Changed the shared-layout community creation action to open a modal with an
open/private switch and a picker of existing members. The creator is omitted
from the picker. The loaded server roster limits creation UI to owners and
admins; it is never used to authorize received info records. Partial add
failures retain the created channel and retry only unsuccessful additions.
Session changes stop subsequent additions. Private membership visibility is
disclosed in English, Serbian Cyrillic and Serbian Latin.

Legacy communities retain their existing creation form, because their layout
joins every community member to a channel. No selective privacy is promised
there. The shared-layout default remains open. Existing MLS reconciliation,
info publishing and request-based key delivery remain in use.

Checks:

- 44 focused Flutter tests passed, including six creation-modal tests and a
  new native-codec integration test verifying private creation chooses its
  own conversation and uses a different info key from the community.
- Final legacy-form error handling: Flutter analyze and 16 focused UI tests
  passed after the adjustment.
- `go test ./...` and `go vet ./...`: passed.
- `cargo test`: 230 passed, 8 existing ignores; clippy with all targets and
  warnings denied: passed.
- `scripts/lint.ps1`: passed (Go vet, Rust fmt/clippy, Flutter analysis and
  Dart formatting). Final adjusted Dart file's format check also passed.
- `scripts/test.ps1`: passed end to end: policy fixtures, Go, Rust and
  2,410 Flutter tests, with 21 existing Flutter skips.

Native Flutter checks used
`C:/tmp/vw/wt/c3-rest/crypto/rust/target/release/private_messenger_crypto.dll`
with `VERITRA_REQUIRE_NATIVE_CRYPTO=1`.

Remaining: conversion UI, category/icon UI, C4 verified-role wiring and its
restriction flag, remote-removal rotation, immediate add-key delivery,
plaintext-name refusal and column removal, and moderator creation-entry
visibility (the modal itself refuses moderators). Schema 35 and migration
0067 remain reserved and unused. Existing plaintext creation names remain
until that coordinated migration; peer info acceptance stays closed without
verified roles. Release gates and STATE.md are unchanged. No dependencies,
ABI changes, pushes, PRs or CI changes.
