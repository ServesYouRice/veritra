# C4 wiring check (2026-11-07)

Question: do C1's removal proofs exist, so C4 receivers may be wired?

**No.** Grep for removal or leave proofs finds only `STATE.md` and the C4
design. `RemoveConversationMember` still takes the server's word.

Can receivers be wired under ABI 13? **No.** `CommitOutcome`
(`crypto/rust/src/mls.rs`) returns `removed_any`, `added_any`, `new_epoch`,
`root`, `removed_self`; the merge happens in Rust with no hook, and Dart
never sees the committer or the removed accounts. All five ABI pieces in the
C4 design need an ABI number; ABI 14 is L1's (#142). Needs a counter.

Built instead: record codec v2 + vector (Dart tests: 6 cases, truncation at
every byte, canonical order, bad shapes); server migration 0054 (one owner,
transfer to an admin only, self step-down) with tests including the data
fix-up of a group with two owners.

Checks run: `go test ./...` (server), `go vet ./internal/storage`,
`flutter test test/governance_codec_test.dart test/governance_test.dart`,
`flutter analyze`, `dart format --set-exit-if-changed`.
