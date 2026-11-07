# C6: reports with message franking

**Status: proposed; the commitment, the report seal (ABI 12) and the
franking v1 byte rules are built and independently reviewed (no blockers,
findings fixed, conditions G1 to G6 below). Wiring steps 2 and 3 landed on
2026-11-07 (see "Wiring outcome"): franking is on the wire and the server
carries sealed reports. Not done: storing `kf` on receive (needs a local
schema change), the community inbox key (needs C4) and the app's report
screens (step 4).** Written 2026-11-01 against `main` at `f1b4a36`. The wiring
needs an independent review before it ships (checks G1 to G6 below).

## Goal

A member reports a message and proves it is genuine: the sender really sent
exactly that text in that conversation. In a community the report goes to
moderators. From a DM or group it goes to the instance owner. Reporting is the
reporter's own act; nothing is reported automatically, and the server never
learns text it was not given.

## Why MLS alone is not enough

An MLS application message is signed by the sender, but the signature covers
the group context, so a party outside the group cannot check it, and handing
the signature over would make every message non-deniable. Franking adds a
cheap commitment instead.

## Mechanism (franking v1)

1. The sender picks a random 32-byte franking key `kf` per message.
2. `kf` travels inside the encrypted payload as the reserved top-level key
   `frank` (`{"k":"<base64 kf>"}`). Receivers store it with the message.
3. The commitment is `c = HMAC-SHA256(kf, "veritra-frank-v1" || ctx || P)`,
   each part length-prefixed. `ctx` is `conversation_id`, `sender_device_id`
   and `action_id`. `P` is the canonical payload bytes with the `frank`
   member removed (Open item 3).
4. `c` (32 bytes) rides in the envelope metadata as `frank_commit`. The
   server stores it and can neither compute nor check it.
5. A receiver recomputes `c` on receipt. A mismatch makes the payload
   `invalid` (same class as a context mismatch in the W7 receive policy), so
   a sender cannot get an unreportable message accepted.
6. To report, the reporter reveals `(envelope_id, P, kf)`. The verifier
   fetches the envelope's `frank_commit`, conversation, sender and
   `created_at` from the server and checks `c`. The sender cannot deny it
   (bound to `sender_device_id`, D25, and the server-recorded sender). The
   reporter cannot forge it: `kf` is known only to the sender and the
   recipients.
7. Deniability: there is no signature over the text, so a verifier learns
   only that the server recorded this commitment from this sender.

No server key and no stamp are needed in v1: the server's envelope row is the
evidence. Cost: a report fails once the envelope row is gone (Open item 2).

## Who verifies

- **Community (moderators).** Moderators are members of the shared group and
  can read the message themselves, so the report is a pointer plus the reveal
  and the moderator's app checks `c` locally. For a private channel whose
  group a moderator is not in, the reveal is the only source; same check.
- **DM or group (instance owner).** The owner is not a member and gets the
  reveal only.

## Transport (unresolved, owner decision)

A report body is plaintext to its receiver, so the server must not read it
unless the owner allows that.

- **A. Sealed to a recipient key.** HPKE (X25519) to a per-community moderator
  inbox key (distributed through C4 roles) or to the owner's report key. The
  report key is a separate 32-byte seed the recipient app keeps (ABI 12,
  `pm_crypto_report_key_*`); it is not the account's MLS or identity key. The
  server stores and routes ciphertext only. The HPKE seal/open calls are built
  (ABI 12); C4 is still needed for the moderator key.
- **B. Plaintext to the server over TLS.** The server checks `c` at intake and
  can reject forged reports. Simpler, but a deliberate server-side plaintext
  path for reported messages, which crosses an AGENTS.md boundary. Only the
  owner can choose it.

Recommendation: A for both.

## Server surface (built, migration 0047)

- Migration: nullable `frank_commit BLOB` (32 bytes) on the envelope table,
  write-once (a trigger aborts any later change), plus `report_inbox_keys`
  and `reports`.
- `POST /api/v1/reports` with `{conversation_id, envelope_id, key_rev, recipient_public_key,
  sealed}` (opaque `sealed`). The server checks the reporter is a member and
  the envelope is in that conversation, rate-limits through the write budget
  and a per-reporter daily cap, and never logs the body. `key_rev` and the key make a
  report sealed to a rotated key fail instead of landing in a dead inbox.
- Community reports route to the community's moderator inbox; owner reports to
  the instance owner. The B9 audit log records that a report was filed
  (report id and inbox kind), never content or the message id.
- The server copies the sender, commitment and envelope time from its own
  envelope row into the report, so they outlive the envelope (open item 2) and
  the owner, who is not a member, gets them without any envelope fetch.
- Details and the receive rule: `docs/crypto.md`, "Franking v1", "What is
  wired".

## App surface (when built)

- "Report" in the message menu, with a preview of exactly what is sent (that
  one message) and a confirm step.
- Moderator and owner screens list reports with a verified / not verified
  label from step 6.

## Build order

1. `server/internal/franking`: commit and verify (done, tested). ABI 12
   (done, review pending): `pm_crypto_report_*` HPKE seal and open,
   `pm_crypto_frank_commit`, the Dart `ReportCryptoService`, and the
   franking v1 byte rules (`docs/crypto.md`, "Franking v1") with a shared
   vector.
2. Rust/Dart: generate `kf`, add `frank` and `frank_commit`, verify on
   receive. Depends on the W7 receive policy; adds a reserved context key as C0
   did for `channel_id`. Wire change, review first. **Done 2026-11-07** except
   keeping `kf` with the received message (a local schema change).
3. Server: column, envelope field, reports route (A or B). **Done 2026-11-07**
   (A), except the community inbox key (C4).
4. App: report flow, moderator and owner inbox. Needs C4 (moderator key,
   roles) and C5 (actions on a report).

## Open items and owner questions

1. **Transport A or B** (above). Owner decision; A recommended.
2. **Retention.** Reports need the envelope row. Keep the metadata and
   `frank_commit` for a report window (30 days after delivery?) even after
   acks, or add a server stamp later?
3. **Canonical bytes.** `P` needs one fixed serialization and a franking
   vector in the W7 test vectors. Wire format: second-opinion review.
   Proposed and built (not sent): `docs/crypto.md`, "Franking v1", and
   `testing/vectors/c6-franking-v1.json`.
4. **Edits.** An edit carries its own `frank`; reporting an edited message
   reveals the original and, if wanted, the edit.
5. **Attachments.** The manifest is reportable; file bytes are not committed
   in v1. A later version can bind the manifest's file hash.
6. **False reports.** Rate limits only in v1; no automatic action.
7. **Dependencies, not edited here.** C4 (moderator key), C5 (actions), W7
   (reserved key, receive policy).
8. **Moderator inbox key distribution and rotation (C4).** Who holds the
   inbox seed, how it reaches a new moderator, and what happens when a
   moderator is removed. A removed moderator keeps the seed they already
   hold and can open any report sealed to it that they still see, so removal
   must rotate the inbox key (new seed, new public key published through C4)
   and the server must route new reports only to the new key. Reports
   already sealed to the old key stay readable by the removed moderator;
   decide whether that is acceptable or the old inbox is re-sealed.
9. **C7 hidden types** (`docs/designs/C7-channel-history.md`, decision 3).
   `history_change`, `history_sync` and `history_sync_request` are never
   franked (a `frank` member would push a record out of the 512-byte
   bucket) and send 32 random bytes as `frank_commit`, so the server cannot
   tell them apart. G5's refusal of unfranked payloads, if chosen, must
   exempt these types after decoding.

## Conditions for the wiring steps (independent review of step 1, 2026-11-06)

The review of build step 1 (`testing/evidence/C6-step1-review.md`) found no
blockers. Steps 2 and 3 must meet these before they ship; each wiring review
checks them.

- **G1. Attribution rests on an honest server row.** `c` proves the sender
  committed to this text only if the `frank_commit`, sender and conversation
  the verifier reads from the server are the ones recorded at send time. A
  malicious server could substitute them. State this in the app's report
  screens: a "verified" label that used only server-held data says so, and
  moderators who are members verify against their own MLS copy of the
  message, not only the reveal.
- **G2. Commitment context from authenticated sources only.** On receive,
  `conversation_id`, `sender_device_id` and `action_id` for `c` come from the
  authenticated MLS context and the envelope the receiver already
  validates, never from fields inside the sender's payload.
- **G3. `frank_commit` is write-once, in its own column.** Not inside
  `crypto_metadata`, and never updated after insert.
- **G4. The report's aad binds routing.** The `aad` of the sealed report
  covers the recipient inbox, `conversation_id`, `envelope_id` and the
  reporter, so a sealed report cannot be replayed into another inbox or
  attributed to another reporter.
- **G5. Decide refusal of unfranked payloads.** Once franking is on, decide
  whether a receiver treats a payload without `frank` as `invalid` or
  accepts it as unreportable, and plan the rollout across old and new
  apps.
- **G6. Duplicate JSON keys.** If a verifier other than the Dart app will
  exist, the wire rules must reject duplicate JSON keys (Dart's parser keeps
  the last one), or the two readers can disagree about `P`.

## Wiring outcome (2026-11-07)

How steps 2 and 3 meet each condition. A wiring review checks the same list.

- **G1, honest server row.** The server records the sender, commitment and
  envelope time itself when a report is filed (never from the reporter), so
  the evidence is at least as good as the envelope row. `c` still proves the
  sender committed to this text only if the server did not substitute the row
  at send time. The report screens (step 4) must say so: a "verified" label
  that used only server-held data reads "verified against what the server
  recorded", and a moderator who is a member of the shared group checks
  against their own MLS copy of the message, not only the reveal. Nothing in
  steps 2 and 3 shows a label.
- **G2, context from authenticated sources.** `_checkFranking` takes the
  conversation, sender device and action id from the envelope the receiver
  already validated, after `classify` matched them against the payload, and
  never from the payload map.
- **G3, write-once, own column.** `message_envelopes.frank_commit`, outside
  `crypto_metadata_json`, with a database trigger that aborts any update and a
  `CHECK` of 32 bytes. The one code path that rewrites an envelope in place
  (the legacy edit route) refuses franked rows; the app sends edits as new
  envelopes.
- **G4, aad binds routing.** `veritra-c6-report-aad-v1` over the inbox kind,
  inbox id, recipient public key, conversation id, envelope id and reporter
  account id (`docs/crypto.md`). Go and Dart build it from a shared vector.
  The server stores the routed inbox, key and key revision in the report row,
  so the recipient rebuilds the aad from the row. Residual: the report public
  key itself comes from the server, so a server that substitutes it can read
  reports. The report screens must show the key fingerprint; the owner's
  report key should be pinned the way the K0 recovery key is. Owner question.
- **G5, unfranked payloads.** Decided: accepted as unreportable. A franked
  payload whose commitment is missing or wrong is `invalid`. Rollout: every
  current sender is the new app, older apps and the C7 hidden types send no
  `frank` member and keep working. Switching to refusal (hidden types exempt
  after decoding) is a one-line receiver change once no old sender is left.
- **G6, duplicate JSON keys.** Not needed while the only verifier is the Dart
  app, which works on the received bytes. Required before a second
  implementation verifies reveals.

Deviations from the first design text, none of which changes the wire:

- The report body names `key_rev` and the key sealed to, and the instance owners' inbox has one
  published public key (any instance owner may publish it). Several owners
  share that key's seed by hand; per-owner copies (C5 escalations) are a
  later change if the owner wants them.
- The community moderator inbox exists in the schema and the intake route,
  but no route publishes its key until C4 says how the seed reaches
  moderators (open item 8). Until then a community report is refused with
  `report_inbox_unavailable`.
- A receiver must keep `kf` and `P` with each message to report it later. That
  needs a local schema change and is not part of this wiring (design open
  item for step 4; reported to the coordinator).
- Reports stay until a recipient dismisses them (no retention window yet),
  capped at 2000 per inbox and 20 a day per reporter. Open item 2 decides
  the window.

## Owner decisions (2026-11-01)

- Reports are sealed to the recipient's key; the server carries ciphertext only.
