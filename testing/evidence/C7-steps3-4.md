# C7 build steps 3 and 4 (partial)

Date 2026-11-07. Design: `docs/designs/C7-channel-history.md` revision 7.
No ABI, schema, migration or dependency change. **Every ABI 13 piece needs
the independent crypto review before release.**

## Built

- `testing/vectors/c7-ordering-v1.json` (ordering rows 1 to 7, invalid
  records, `unsure`, `keyless`, implicit genesis, windows, VAP1 slack).
- Go: `server/internal/c7vector` (re-derives `c7-primitives-v1.json` from its
  inputs; its own copy of the ordering table, windows, slack).
- Rust: three tests in `crypto/rust/src/c7_tests.rs` over the new vector.
- Dart: device calls in `native_crypto_bindings.dart`;
  `crypto/c7_history.dart`, `crypto/c7_keys.dart`;
  `AppPayloadCodec.framedLength`.

## Checks run

- `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test --lib c7`: pass.
- `go vet` and `go test ./internal/c7vector/`: pass.
- Flutter 3.44.0: `flutter pub get --enforce-lockfile`, `dart analyze`,
  `dart format --set-exit-if-changed .`, and with `VERITRA_CRYPTO_LIBRARY` set to
  the release build: `c7_device_bindings_test`, `c7_primitives_test`,
  `c7_history_test`, `app_payload_test`: pass.

## Not built (needs a local schema bump, which this package may not take)

Persistence of heads, records, keys, floors and snapshots; `history_sync`
assembly and handling; rekey at the three merge sites; targeted-action
sealing; backward walk; two-pass import; prefetch; the "from a former member"
marking in the UI; the `unsure` clearing by a slot (`slot` rule of decision 5).

## Independent review (opus-expert) and fixes

Blockers found and fixed, each with vector cases (Dart and Go both):
- B1 a `closed` channel could never recover when the live switch chains from
  the device's own head (row 3 ran first): row 3 now recovers a `closed`
  channel for a live switch or move above the highest valid `seq`.
- B2 `unsure` cleared too easily: it now keeps the highest miss epoch and
  row 3, row 5 and a slot clear it only above that epoch.
- B3 `keyless`/`closed` channels now keep the miss epoch too, so a stale
  slot cannot turn sealing back on (`keyArrived(for_epoch)`).
- B4 a create at seq ≠ 0, with a nonzero `prev`, or a non-create at seq 0
  is now invalid before the table (the vector case used a malformed create).
Also: windows test "generation is in the current period" (epochs are per
group), more vector cases (row 2 on an older kept record, row 4 below the
head seq), root copy wiped, `removedSelf` without `removed` refused.
Not fixed (design residual, owner): a valid record at seq 2^32-2 leaves no
seq for recovery; consider capping how far one record may jump.

## Also run

`scripts/test.sh` and `scripts/lint.sh` through `.claude/hooks/check.sh`
(result in the PR body).

## Questions for the owner or reviewer

1. A `closed` channel leaves `closed` only through a live switch or move
   above the highest valid `seq` (row 5, or row 3 when it also chains from the
   head). Confirm.
2. The seq-jump residual above.
3. Exporter use and the root crossing the ABI: unchanged from step 2.
