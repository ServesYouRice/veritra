# L1 review follow-up: enrollment anchors

2026-11-11. Implementation evidence, not G25 clearance. Worked alone as
instructed. The earlier three L1 branches are ancestors of HEAD; their
Rust/server protocol is reused. No ABI, schema, migration or dependency change.

## Fixed high-priority findings

- Setup/registration write an identity-scoped activation journal before saving
  the session. Pinning errors propagate before MLS activation and before the
  session becomes available in memory. Foreground restore, background restore
  and password/passkey sign-in replay the journal before activating MLS.
- Linking downloads/verifies without pinning. The exact key from the frozen
  claim must have an add signed by the exact approver key in the frozen link
  context, and remain approved at the head. The chain is journaled before
  promotion and pinned after promotion, before exposing the session. The
  pending claim survives validation failures; the journal survives promotion
  and pin failures. No server-selected own-account TOFU retry exists here.
- The earlier review's imported-chain continuity fix remains intact.

## Real-native regressions

`VERITRA_CRYPTO_LIBRARY` is the absolute path of this worktree's
`crypto/rust/target/release/private_messenger_crypto.dll`.

Seven focused Flutter files: **99 passed, no skips**:
`l1_device_list_pins_test.dart`, `l1_device_list_store_test.dart`,
`l1_native_gate_test.dart`, `l1_device_list_native_test.dart`,
`l1_k2_transcript_test.dart`, `l1_app_state_lists_test.dart`,
`device_link_v3_flow_test.dart`.

New cases cover setup/registration journal, session, pin and MLS write failures;
pin failure continuing across cold start; interruption after a committed MLS
write and before journal cleanup; and SQLite journal/session persistence after
closing and reopening the database. A crash before the first MLS save can
require explicit recovery/relinking; it cannot authorize another anchor.

Link cases cover missing chains, unrelated genesis, wrong approver keys, and
an add signed by another valid chain member even though the actual approver
remains listed. Each refusal is repeated after restart, with no pin or active
session, then succeeds when honest service returns. A post-promotion pin-write
failure blocks restart until the journal can be pinned, then resumes offline
with the authenticated chain. Existing end-to-end link/history tests now serve
real signed lists instead of relying on best-effort anchoring.

## Checks and limitations

- `go test ./...`: passed on rerun; the first concurrent run failed in
  `internal/app`, whose isolated rerun passed (66.348 seconds).
- `go vet ./...`: passed.
- `cargo test`: 225 unit + 7 integration passed, 8 existing ignored.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `scripts/lint.ps1`: passed, including Flutter analyze and formatting.
- `scripts/test.ps1`: policy fixtures, Go and Rust passed; Flutter failed
  (2,588 passed, 119 failed, 22 skipped). Final post-merge Flutter outcomes
  are recorded in `.ai-report.md`.
  The integration merge brought screen-guard binding failures and missing
  `invalid_nonce`/`attestation_unavailable` client error mappings; these
  unrelated files have no L1 diff against `ai/integ`.

Merged local `ai/integ` (b003fb0, then 7e55bbb); resolved its sync-fake mixin
conflict while preserving L1 tests. STATE.md and CI changes are inherited
merge content; neither was authored for this follow-up. Release gates remain
unchanged.

The incomplete-package finding remains open: complete adds derived from signed
lists, recovery-key retype/legacy confirmation, removed-message UI and lifecycle
demo evidence are not delivered by this security-fix slice. Bounded-chain
limits and first-contact/withholding limits still apply. Full L1 is partial.
