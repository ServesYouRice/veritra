# C6: reports with message franking

**Status: proposed; only the commitment primitive is built.** Written
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
  inbox key (distributed through C4 roles) or to the owner's account key. The
  server stores and routes ciphertext only. Needs an HPKE seal/open call in
  the Rust ABI (a crypto change) and C4 for the moderator key.
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

1. `server/internal/franking`: commit and verify (done, tested).
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
4. **Edits.** An edit carries its own `frank`; reporting an edited message
   reveals the original and, if wanted, the edit.
5. **Attachments.** The manifest is reportable; file bytes are not committed
   in v1. A later version can bind the manifest's file hash.
6. **False reports.** Rate limits only in v1; no automatic action.
7. **Dependencies, not edited here.** C4 (moderator key), C5 (actions), W7
   (reserved key, receive policy).
