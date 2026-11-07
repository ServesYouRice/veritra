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

## Questions for the owner or reviewer

1. Row 3 on a `closed` channel: the design says `closed` shows an error until
   row 5. Taken literally, row 3 can still advance the head; this code keeps the
   status `closed`. Confirm.
2. The first `unsure` trigger says "every `full` channel"; this code leaves
   `keyless` and `closed` channels alone (they already seal random keys).
3. Exporter use and the root crossing the ABI: unchanged from step 2.
