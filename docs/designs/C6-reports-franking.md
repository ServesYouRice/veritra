# C6: reports with message franking

**Status: proposed; the commitment, the report seal (ABI 12) and the
franking v1 byte rules are built and independently reviewed (no blockers,
findings fixed, conditions G1 to G6 below). Wiring steps 2 and 3 landed on
2026-11-07 (see "Wiring outcome"): franking is on the wire and the server
carries sealed reports. Owner decision D95 is applied (see "D95 outcome"):
receivers keep `kf` and `P` (local schema 19), the envelope id is sealed
inside the report, one sealed copy per instance owner, owner keys pinned in
the app, 90-day or dismissed retention, unfranked payloads accepted behind a
switch. The community moderator inbox is built (2026-11-11, "Community
moderator inbox" below). Not done: the owner's way to
verify without the server learning the envelope id, and the app's report
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
- `POST /api/v1/reports` with `{conversation_id, report_id, copies:
  [{inbox_id, key_rev, recipient_public_key, sealed}]}` (opaque `sealed`; the
  envelope id is inside it, D95). The server checks the reporter is a member
  and that the copies are exactly the current recipients, rate-limits through
  the write budget and a per-reporter daily cap, and never logs the body.
  `key_rev` and the key make a report sealed to a rotated key fail instead of
  landing in a dead inbox.
- Community reports route to the community's moderator inbox; owner reports to
  the instance owner. The B9 audit log records that a report was filed
  (report id and inbox kind), never content or the message id.
- (Superseded by D95.) The first wiring copied the sender, commitment and
  envelope time from the envelope row into the report. With the envelope id
  sealed the server cannot, so a report row holds no message data; see "D95
  outcome" for what that costs verification.
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
2. **Retention.** Decided by D95 for reports: until dismissed or 90 days. An
   envelope row still goes with its message, so verification after that is
   open (see "D95 outcome", costs).
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
- **G4, aad binds routing.** `veritra-c6-report-aad-v2` (D95) over the inbox
  kind, inbox id (the owner's account id, or the community id), recipient
  public key, conversation id, report id and reporter account id
  (`docs/crypto.md`); the envelope id is sealed inside the body instead.
  Go and Dart build it from a shared vector. The server stores the routed
  inbox, key and key revision in the report row, so the recipient rebuilds the
  aad from the row. Residual: the report public key itself comes from the
  server, so a server that substitutes it can read reports. D95: the app pins
  each owner's key and refuses a changed or unpinned one; the report screens
  show the fingerprint when asking for a pin.
- **G5, unfranked payloads.** Decided: accepted as unreportable. A franked
  payload whose commitment is missing or wrong is `invalid`. Rollout: every
  current sender is the new app, older apps and the C7 hidden types send no
  `frank` member and keep working. Switching to refusal (hidden types exempt
  after decoding) is `FrankingPolicy(acceptUnfranked: false)` once no old
  sender is left (D95 built the switch, left off).
- **G6, duplicate JSON keys.** Not needed while the only verifier is the Dart
  app, which works on the received bytes. Required before a second
  implementation verifies reveals.

Deviations from the first design text, none of which changes the wire:

- The report body names `key_rev` and the key sealed to. (First wiring: the
  instance owners shared one published key. D95 replaced that with one key
  and one sealed copy per owner.)
- The community moderator inbox exists in the schema and the intake route,
  but no route publishes its key until C4 says how the seed reaches
  moderators (open item 8). Until then a community report is refused with
  `report_inbox_unavailable`.
- A receiver must keep `kf` and `P` with each message to report it later.
  Done by D95 (local schema 19), see "D95 outcome".
- Reports stay until a recipient dismisses them, capped at 2000 per inbox and
  20 a day per reporter. D95 adds the 90-day window.

## D95 outcome (2026-11-07)

Owner decision D95 applied on this branch (PR #125). What changed from the
wiring above, and what each part rests on:

- **`kf` and `P` kept (local schema 19, C6's number).** A receiver stores the
  franking key and the exact canonical bytes with each live franked message,
  plus the envelope id: table `local_frank_reveals`, written in the same
  transaction as the MLS state and cursor, removed with the message (row
  cascade, plus a trigger for delete-for-everyone and hide, which leave a
  tombstone). A message received before the upgrade, an unfranked one and an
  edit's own `frank` have none. Upgrade test: `mobile/test/c6_schema19_test.dart`.
- **`envelope_id` sealed, never in clear.** It is a field of the body sealed
  in every copy (`ReportBody`). `POST /reports` carries no envelope id; the
  aad (v2) binds the report id instead. C7's question (a newcomer reporting a
  pre-join post shows the server its channel was `full`) is answered: the
  server learns nothing about the message.
- **One sealed copy per owner.** Each instance owner publishes their own
  report key (inbox id = account id). A report carries one copy per owner
  that has published a key, and the server requires exactly that set at the
  current keys. Each owner lists and dismisses their own copy; a deleted or
  demoted owner's key and copies go. An owner who has not published a key
  gets no copy.
- **Owner keys pinned in the app.** `local_report_key_pins`, per server
  origin and owner. A report is sealed only to keys equal to their pin; a
  changed or never-pinned key is refused until a person pins it after seeing
  its fingerprint; a pinned owner the server omits is surfaced. Closes G4's
  residual (a server substituting the key) for the apps that pinned.
- **Retention.** Dismissed (deleting your copy) or 90 days after filing, by
  the retention sweeper; caps as built (20 reports a day per reporter, 2000
  copies per inbox). This answers open item 2 for reports; an envelope row
  still goes with its message (expiry, delete).
- **Unfranked payloads.** Still accepted, behind `FrankingPolicy.acceptUnfranked`
  (true). Flipping it to false refuses them, with the hidden payloads this
  app does not understand exempt (design item 9). G5's one-line change is now
  one argument.
- **Error contract.** No new code; `message_not_reportable` is gone (the
  server cannot tell). Version stays 1.

Costs, for the owner to weigh (also in `testing/evidence/C6-wiring.md`):

- The server no longer records the sender, commitment and time when a report
  is filed, no longer refuses a report of the reporter's own or an unfranked
  message, and no longer dedupes by message. The recipient's app checks the
  first two against the revealed body, and the reporter's app dedupes.
- An owner verifies a report by recomputing the commitment over the revealed
  body and comparing it with the commitment the server recorded for the
  envelope. Fetching that envelope's metadata means telling the server the
  envelope id at review time (not at filing, and only to an owner, for one
  envelope of a conversation that has a report). That route is not built;
  until it is, and once the envelope is gone, a report cannot show
  "verified against what the server recorded" (G1). Owner question.

## Step 4 outcome (report screens)

Built on branch `agent/c6` (see the pull request and
`testing/evidence/C6-step4-reports.md`):

- **Report a message.** "Report message" in the message menu of a message
  someone else sent, offered only in a build with the reviewed engine
  (`AppState.reportsAvailable`; the release gate is untouched). The screen
  shows exactly the one message that will be sent, the owners' key codes
  when a key is new or changed (a person pins it, D95), then sends one sealed
  copy per owner. A message with no proof (unfranked, older, deleted) is
  refused; a double tap files once.
- **Owner inbox.** Settings, Reports (owners only): this device's report key
  and code, the reports sent to this owner, one report at a time with the
  revealed text, and "Check against the server record". Dismiss removes the
  owner's own copy.
- **Verification** (G1). The new `GET /reports/{id}/envelope` route gives the
  recipient what the server recorded (sender, conversation, commitment); the
  app recomputes the commitment. Four results: matches the server record,
  does not match, cannot be checked (envelope gone), cannot be proven
  (unfranked). The screen says a match is only as honest as the server's
  record.
- **Seed custody, safest default.** The seed is made on the owner's device
  and kept only in the platform keystore, per server and account. It is never
  copied, backed up or sent. A second device holds no seed: it can create a
  new key (after a warning that this replaces the old one, that old reports
  open only where the old seed is, and that reporters must trust the new key)
  but cannot read reports sealed to the first device's key. Moving the seed
  between devices is left to the owner (open question below).
- **Community moderator inbox.** Shown as "not available yet" in the owner
  screen and in the report screen; it waits for C4.

Owner answers (coordinator, 2026-11-08), built: the seed is never moved
between devices (one device holds it; a second device makes a new key); a
deliberate sign-out deletes the seed after a warning on the sign-out dialog;
"already reported" is durable (local schema 27); the owner screen shows the
key the server currently lists (new route `GET /reports/inbox-keys/instance`)
and says when another device replaced this one's key.

Left: the moderator inbox (C4); the changed-key trust tap is the same as for a
new key.

## Community moderator inbox (2026-11-11)

Built on branch `ai/c4-rest` after C4's role record reached the apps. It
answers open item 8 by having no shared inbox seed at all: the D95 rule for
owners ("one key and one sealed copy per owner") is applied to moderators.

- **Keys.** Each community member may publish their own report public key as
  their moderator inbox in that community:
  `PUT /api/v1/reports/inbox-keys/community/{community_id}` (recent sign-in),
  `GET` the same path for their own. The inbox id is
  `<community id>:<account id>` (`franking.CommunityModeratorInboxID`; ids
  are `<prefix>_<hex>`, so the `:` never occurs inside one, and the result
  fits the 128-character column), kind `community`, so schema 0047 is
  unchanged and no migration was needed. The key is the account's one report
  seed on that device (the same seed and custody rules as the owner's: never
  moved, deleted on a deliberate sign-out); the aad binds kind and inbox id,
  so one key serving several inboxes cannot be confused between them.
- **Who receives a report.** The server lists the keys of the community's
  current members (`GET /reports/inbox`); it cannot know who moderates, since
  community roles are the apps' verified role record (C4). The reporter's app
  seals only to the listed keys of accounts the community's shared-group
  record ranks moderator or above (owner, admins, moderators), never to
  itself, and refuses (`communityUnavailable`) when it holds no record. A
  server that lists an extra account gets that account no copy.
- **Server check.** For a community the copies must be a non-empty,
  duplicate-free subset of the listed keys, each at its current revision and
  key; for the instance owners it stays the exact set.
- **Reading.** A copy is listed, dismissed and verified (`/envelope`) only by
  the account its inbox id names, and only while that account is still a
  member of the community. Not a server role.
- **Trust.** Moderator keys are pinned by a person exactly like owner keys
  (`ReportKeyPins`, keyed by the inbox id); a pin of one inbox is never
  reported missing from another.
- **Rotation (open item 8).** Nothing to rotate: a moderator who is demoted
  in the record, or leaves, stops receiving new copies at once (the record
  for the first, the membership filter for the second). Copies they already
  received stay readable by them until dismissed or 90 days old.
- **App.** The report screen files community reports; a moderator opens
  their inbox from the community screen (flag icon), the same screen as the
  owner's inbox with the community's routes.

Left: authenticating moderator keys over MLS (so no tap is needed to trust
them); deleting a departed moderator's copies at once; replacing the seed
from one inbox screen does not republish the account's other inboxes (a
moderator inbox then shows "replaced elsewhere" and offers to publish this
device's key; the owner inbox needs a replace); tests for the new
routes beyond the updated `TestCommunityReportsRouteToModerators`; the
independent review.

## Owner decisions (2026-11-01)

- Reports are sealed to the recipient's key; the server carries ciphertext only.
