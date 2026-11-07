# C7 build step 2: primitives (ABI 13)

Date 2026-11-07. Design: `docs/designs/C7-channel-history.md` revision 7.
Nothing is wired into the app, the server or the schema. **Every new ABI
piece, the exporter use first, needs the independent crypto review before
release.** This file is the brief for that review.

## What was built

- `crypto/rust/src/c7.rs`: `c7_derive` (HKDF-SHA256 through the OpenMLS
  provider), `chk_commit`, `seal`/`open` with key commitment checked first,
  slot helpers, Ed25519 verify, the generation entry, `P(N)` and the
  `history_sync` length, the full and compact history records.
- `crypto/rust/src/mls.rs`: `process_commit_with_outcome`,
  `merge_pending_commit_with_outcome`, `decrypt_with_epoch`,
  `member_signature_key`, `c7_sign`, and the signature-key check in
  `inspect_commit`.
- `crypto/rust/src/ffi.rs` and the header: ten new symbols and status -10.
- Vector `testing/vectors/c7-primitives-v1.json`.
- Dart: `NativeCryptoBindings` pins ABI 13 and adds the stateless calls
  (derive, chk_commit, seal, open, verify) and `c7KeyMismatch`.

## Checks run

- `cargo fmt`, `cargo clippy --all-targets -- -D warnings`: clean.
- `cargo test` in `crypto/rust`: 157 library tests pass (31 new), all other
  suites pass.
- The vector was re-derived without any Rust code (Python HKDF, AES-GCM,
  Ed25519 and the byte layouts): every output matched.
- Mutation check: removing the signature-key comparison from
  `inspect_commit` makes `c7_an_update_that_changes_the_signature_key_is_refused`
  fail.
- Not run: Dart analyze, format and tests (Flutter is not installed here;
  GitHub CI runs them on the PR). Go is untouched.

## Questions for the crypto reviewer

1. **Exporter use.** Label `veritra-c7-rekey-v1`, context
   `lp(group_id) | u64(new_epoch)` (u16 length), 32 bytes, taken from
   `StagedCommit::export_secret` before `merge_staged_commit` (another
   device's commit, after `inspect_commit`) or from `group.pending_commit()`
   before `merge_pending_commit` (own commit). Tests show the staged export
   equals `MlsGroup::export_secret` after the merge, for both paths, with a
   different value per group and per epoch.
2. **Root crosses the ABI.** The design says the commit call returns the root
   (D83, rev 7 finding 1), so the 32-byte root reaches Dart, which derives
   per-channel keys with `pm_crypto_c7_derive`. It is zero-on-free in Rust;
   the app must wipe it.
3. **Removal signal.** `removed_any` is "at least one Remove proposal" in the
   staged commit; `added_any` likewise. Own removal is detected with
   `StagedCommit::self_removed()` (not the `UseAfterEviction` error), and
   returns OK with no root. This crate refuses external commits
   (`Sender::Member` only), so the sibling-resync case where
   `self_removed()` is false for a commit that removes our old leaf cannot
   occur.
4. **Deviations from the design text, to approve.**
   - An extra `removed_self` flag (bit 4) instead of "removed, no root"
     alone; Dart need not infer it.
   - The merge variant returns `PM_CRYPTO_ERROR` for a group with nothing
     staged (the plain call is a silent no-op), so a caller cannot mistake a
     no-op for a non-membership commit.
   - Only the staged path reports. `pm_crypto_group_remove_member` and
     `pm_crypto_group_self_update` merge at once and report nothing; the app
     must not use them for C7 groups.
   - Seal and open take the caller's aad as one required buffer (1 to 1024
     bytes) because `borrowed()` refuses empty slices; the aad always holds
     at least the length prefixes. The channel part of the aad may be empty
     (`lp("")`).
   - The slot seal is the plain seal under `slot_key`; there is no separate
     slot call.
5. **Labels and domains.** Callers may name only `post`, `rekey-chk`, `slot`
   in derive and only the two signing domains in sign and verify. `enc` and
   `kc` stay inside seal and open. Rust prepends the signing domain.
6. **Nonce safety.** Random 96-bit nonce per seal. This rests on the rule
   that every key seals one message (post and slot keys bind `action_id`);
   the ABI cannot enforce it, so callers must derive a fresh key per
   message. A key-reuse misuse is a caller bug the primitive cannot detect.
7. **Verify** uses `verify_strict`, rejects wrong lengths with an argument
   error and returns "invalid" (not an error) for a bad signature or a
   malformed public key.
8. **Id limits.** Record and key-context ids are 1 to 64 bytes (C7 refuses
   longer); the exporter context accepts group ids up to this crate's 128 so
   commit processing never fails on a group the core accepts. The commit
   calls impose no C7 limit on other inputs.

## Effects on the plain receive path

- `inspect_commit` now also compares the signature key on an Update or
  update path, for every group, not only C7 groups. A grep of all Rust
  sources found no non-test code that rotates a signature key through an
  Update (`self_update_with_new_signer`, `NewSignerBundle`,
  `with_credential_with_key` appear only in tests), so no sender path would
  now be refused.
- The plain `process_commit` now goes through the same code as the C7 call
  and so computes, then drops (zeroized), an exporter root for every removal
  commit that keeps this device. A failure of that export would now fail a
  commit that used to apply; the export cannot fail for a staged commit that
  keeps this device in OpenMLS 0.9.2, and every removal test in the suite
  exercises it.

## Deferred (not in this step)

- Ordering-row, window and implicit-genesis vectors, and the 512-byte VAP1
  slack check (Dart-side JSON sizes): steps 3 and 4.
- The Go check of the shared vector (comes with the server step). The Dart
  test (`mobile/test/c7_primitives_test.dart`) covers the stateless calls
  and is skipped without the native library.
- A fixed-input exporter vector: OpenMLS has no way to start a group from
  fixed secrets, so the label and context bytes are in the vector and the
  root is pinned by the staged-versus-merged equality tests.
- Device-level Dart bindings (commit outcome, decrypt with epoch, member
  key, sign): step 4.
