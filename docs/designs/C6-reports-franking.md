# C6: reports with message franking

**Status: proposed; the commitment, the report seal (ABI 12) and the
franking v1 byte rules are built and independently reviewed (no blockers,
findings fixed, conditions G1 to G6 below), nothing is wired.** Written
2026-11-01 against `main` at `f1b4a36`. Needs an independent security review
and the owner answers below before any wire change ships.

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

## Server surface (when built)

- Migration: nullable `frank_commit BLOB` (32 bytes) on the envelope table.
- `POST /api/v1/reports` with `{conversation_id, envelope_id, sealed}` (opaque
  `sealed`). The server checks the reporter is a member and the envelope is in
  that conversation, rate-limits through `admission`, and never logs the body.
- Community reports route to the community's moderator inbox; owner reports to
  the instance owner. The B9 audit log records that a report was filed, never
  content.

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
   did for `channel_id`. Wire change, review first.
3. Server: column, envelope field, reports route (A or B).
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

## Owner decisions (2026-11-01)

- Reports are sealed to the recipient's key; the server carries ciphertext only.
