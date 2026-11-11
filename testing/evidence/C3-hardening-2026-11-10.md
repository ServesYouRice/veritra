# C3 sender and rotation hardening, 2026-11-10

This is a complete service-hardening slice, not completion of C3.
`origin/agent/c3` is already in the base, and the C3-only sender commits from
`origin/agent/c3-2` are already ported. No further branch merge was needed.

The inherited uncommitted service review fixes were retained and exercised:
edits, rotations and answers share a write queue; edits refuse removal holds
and pending rotations, including after the version fetch; key replies use a
trusted current key after their delay; failed announcements remain retryable.
Tests cover unrelated-member suppression, concurrent edits/removals and
remote key delivery during an answer delay.

Ordinary edits also select the current trusted key again after their version
read (including conflict retries). A remote rotation arriving during that
read no longer leaves the edit encrypted under the previously selected key.
A regression injects that delivery during the read and checks the resulting
key ID and the peer's decrypted record.

An additional private-channel regression exercises a failed re-seal, service
restart with the same persisted store, reuse of the already delivered key,
edit refusal until rotation completes, and successful decryption by a
remaining member. A removed member holding the original key cannot open the
new record, and neither that member nor a shared-group-only outsider receives
the new private key. The codec uses the native crypto DLL; the service test's
group transport is simulated. Separate native MLS tests exercise actual
control-payload send/receive.

## Checks

- Seven focused Flutter files: 76 passed, no skips, with
  `VERITRA_CRYPTO_LIBRARY=C:/tmp/vw/wt/c3-rest/crypto/rust/target/release/private_messenger_crypto.dll`.
- `go test ./...`: passed.
- `cargo test`: 223 unit, 2 join-cost and 5 integration tests passed;
  8 existing measurement/vector tests ignored.
- `scripts/lint.ps1`: passed (Go vet, Rust fmt/clippy with warnings denied,
  Flutter analyzer and Dart formatting).
- Full `scripts/test.ps1`: passed on the final code (all seven policy
  fixture commands, Go, Rust, locked Flutter dependencies and the full
  Flutter suite: 2,403 passed, 21 existing skips).

One focused invocation incorrectly resolved the DLL path from `mobile/`;
it failed to load native crypto. The corrected absolute-path invocation
above passed all seven files.
The new key-refresh change initially lost Dart's nullable-variable promotion
inside the retry loop; the key now has an explicit non-null type, and the
corrected focused suite passes.

## Decisions and remaining work

Kept the documented defaults: private channels are hidden from non-members;
channel info is member-editable unless restricted. No new wire, schema,
migration, ABI or dependency decision. Schema 35 and migration 0067 remain
reserved and unused. Release entrypoints and all release gates are unchanged.

C3 still needs actual C4 verified-role wiring and its restriction flag;
remote-removal rotation; immediate delivery after adds; private-channel
creation/member selection/conversion; category/icon UI; moderator creation
button visibility; and plaintext-name refusal/column removal. Peers' records
continue to fail closed without verified roles. The design's recommendation
is still that admins rotate after observing remote removals; it is not built
by this slice.

Worked alone. The pre-existing `STATE.md` changes were not edited or staged.
The pre-existing review evidence is also left unmodified and unstaged.
