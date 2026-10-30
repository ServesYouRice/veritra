# L0 / W8 / K2 preparation verification

An isolated Linux snapshot passed the exact `scripts/test.sh` and
`scripts/lint.sh` commands on 2026-10-28, using pinned Go 1.26.10, Rust 1.91.0
and Flutter 3.44.0. The debug native crypto library was built first and supplied
through `VERITRA_CRYPTO_LIBRARY`. Dependencies remained locked.

- All Go packages passed, including app, storage and HTTP tests.
- Rust: 51 unit tests and 2 integration tests passed; 2 measurement tests ignored.
- Flutter: 632 passed, 2 integration entry points intentionally skipped (the
  separately invoked live-contract and demo-E2E scripts). L0's live contract
  already passed separately; see its evidence.
- Go formatting/vet, Rust formatting/strict clippy, Flutter analysis and Dart
  formatting passed (156 Dart files, zero formatting changes).
- Eight chat/chat-list goldens were regenerated on the pinned Linux toolchain
  after reviewing the added starred-message/archive toolbar icons. The full
  rerun passed with those baselines. The other eight screen baselines matched.
- Independent W8 review found and fixed plaintext forward-file persistence;
  forwards now use bounded memory and ciphertext-only temporary files. Review
  also added wiping of each decrypted chunk after its consumer finishes.

Scope: L0 linking, W8 client actions, K2 native internal primitives/state
migration and v3 server enrollment. The subsequently developed migration0039
transfer resource, ABI8 and history importer are **not** covered by this run.
D52 sleeping-phone background delivery is not implemented or enabled. Platform
builds, hand-operated QR scanning and the human G25 review remain outstanding;
production release gates remain closed.

Local ignored artifacts: `build/completed-verification-results/`, original
source hashes `build/final-source-manifest.json`, isolated source volume
`veritra-check-final-clean-20261027`. After the initial snapshot, the final
checked attachment chunk-wiping fix and regenerated goldens were applied before
the successful rerun. Log SHA-256:

```
test-final.log ae68164dde37a1d674cc197c9d25937f554f8002f410b5c708d9d770fc8bffdd
lint.log       11120dfe947621d4eec484a99163d77542eacf94b024503e9080f7ea5f87b604
```
