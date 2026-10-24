# W11: encrypted profiles (design)

**Status: proposed, not yet built.**

- **Package:** W11 in the `STATE.md` build plan (route "Opus designs").
- **Done when:** "A display name and photo for people, a name and photo
  for groups, all encrypted, with the key given only to contacts and group
  members."
- **Depends on:** W7 step 0 ([`../crypto.md`](../crypto.md#proposed-not-yet-built-application-payload-v2-w7),
  §1). The MLS types used here are reserved in the W7 v2 registry, so W11
  needs no further payload version bump.
- **No ABI change.** Records are encrypted with the existing chunk AEAD
  (`pm_crypto_attachment_encrypt_chunk`).

## Summary

- Each **account** has a random 32-byte profile key. Its display name and
  photo are encrypted under it as one record, which the server stores per
  account and replaces on each change.
- Each **group** has its own random key and record, stored per
  conversation.
- Keys travel only inside MLS messages, so only people who share a
  conversation with the subject ever get them.
- The server stores ciphertext, a server version number, a random key ID,
  sizes and times. It never sees a name, a photo or a key.
- **What changes for the server:** usernames stay visible to it (they are
  the login and lookup handle), but group titles stop being visible. Today
  `conversations.title` is plaintext on the server; see
  [Group titles today](#group-titles-today).

## What the server sees

| Seen | Not seen |
|---|---|
| Subject kind and ID (`account` / `acct_…`, `conversation` / `conv_…`) | Name, photo, keys |
| Ciphertext and its size bucket (4, 64, 128 or 256 KiB) | Whether a photo exists, beyond the size bucket |
| Server `version` (counts writes) and `key_id` (random; a change reveals a key rotation) | Who holds the key |
| Uploading account and time | |

The server already knows conversation membership, and that is all it uses
to decide who may read a record (defence in depth). Confidentiality rests
on the key.

## Subjects and limits

| Subject | Fields | Limits |
|---|---|---|
| Account profile | `name`, `photo` | Name 1–64 UTF-16 units after trimming; photo optional |
| Group profile (`kind == group`) | `name`, `photo` | Name 1–100 UTF-16 units; photo optional |
| DM | none | A DM shows the peer's account profile |
| Community and channel names, topics, icons | Not in W11 | C3 may reuse this mechanism; out of scope here |

A name must not contain C0 or C1 control characters or bidi controls
(U+202A–U+202E, U+2066–U+2069). Receivers reject a record that breaks this
(see [Receiving](#receiving-and-caching)), so a name cannot reorder the
text around it.

Photos:

- PNG only;
- at most 512×512 pixels when received (256×256 when sent);
- at most 192 KiB;
- a whole record at most 256 KiB of plaintext.

## Keys

- **Profile key:** 32 bytes from `Random.secure()`.
- **Key ID:** 16 random bytes as 32 lowercase hex characters. It is not
  derived from the key, so it reveals nothing about the key.
- **An account key** is created by the account's device on the first
  profile save, and replaced on [rotation](#rotation).
- **A group key** is created by whoever first sets the group's name or
  photo (normally the creator, at creation), and replaced on rotation.
- **Receivers keep up to 4 keys per subject**, keyed by `key_id`, and use
  the one whose `key_id` matches the record the server serves. Keys that
  arrive in a different order therefore need no tie-break: the server's
  current `key_id` picks one.

## Record format and encryption

Plaintext, in order:

1. `VPR1`, 4 bytes;
2. a big-endian u32 JSON length, then the JSON in UTF-8;
3. a big-endian u32 photo length (0 when there is no photo), then the PNG
   bytes;
4. random padding up to the smallest bucket that fits: 4 KiB, 64 KiB,
   128 KiB or 256 KiB.

The JSON has its keys in this order:

```json
{"v":1,"kind":"account","subject_id":"acct_…","revision":3,"name":"Ana","photo":{"media_type":"image/png","width":256,"height":256}}
```

- `photo` is `null` when there is no photo.
- `kind` is `account` or `group`.
- `subject_id` is the account or conversation ID.
- **`revision`** must equal the server `version` this upload will become:
  the `If-Match` version plus 1, or 1 for the first upload. It binds the
  server's version number to authenticated content.
- Unknown JSON fields are ignored, so a later `about` field needs no bump.

Encryption, using the existing attachment chunk AEAD (AES-256-GCM,
`crypto/rust/src/attachment.rs`):

- `key` = the profile key;
- `nonce_prefix` = 8 fresh random bytes for every upload;
- `chunk_index` = 0;
- `context` = UTF-8 of `"veritra-profile-v1\0" + kind + "\0" + subject_id + "\0" + key_id`,
  about 100 bytes (the ABI allows up to 512).

The stored blob is `VPE1` + `nonce_prefix` + the ciphertext with its tag.
The context binds the subject and the key ID. The server therefore cannot
serve Bob's record as Ana's, or move a record to another key ID, without
the AEAD failing. The AEAD's built-in domain label stays
`veritra-attachment-v1`. Profile and attachment keys are independent
random keys and never shared, so the profile prefix in the context
separates the two uses. A dedicated ABI function with its own label would
be cleaner, but would need ABI v7. The G25 reviewer should note this
choice.

**Test vector.** It was computed with Python `cryptography` 50.0.1 from
the construction in `attachment.rs`. The build must reproduce it through
the ABI.

- key = bytes `00 01 … 1f`
- nonce_prefix = `01 02 03 04 05 06 07 08`, index 0
- subject `acct_11111111111111111111111111111111`, kind `account`,
  key_id `0123456789abcdef0123456789abcdef`
- context (97 bytes) =
  `766572697472612d70726f66696c652d7631006163636f756e7400616363745f3131313131313131313131313131313131313131313131313131313131313131003031323334353637383961626364656630313233343536373839616263646566`
- plaintext = ASCII `veritra profile vector`
- ciphertext‖tag =
  `fc7a5cd9f965944bfcbabb3b1d92aa76d7cb852c04739c5201dbd239ccdf8504a3c24810043b`
- Changing the subject to `acct_2222…` must fail to decrypt.

## Photos

The photo is made on the device, with no new dependency:

1. Pick an image.
2. Decode it with `dart:ui` (`instantiateImageCodec`).
3. Crop it to a centred square, scaled to 256×256.
4. Encode it with `Image.toByteData(format: ImageByteFormat.png)`.
5. If the PNG is over 192 KiB, retry at 192×192, then at 128×128.

Re-encoding drops EXIF data, including GPS location. Original bytes are
never uploaded.

A received photo is untrusted input to an image decoder. Before decoding:

- check the PNG signature;
- read the IHDR width and height: both must be ≤ 512 and equal the JSON
  `width` and `height`;
- check that the byte length is ≤ 192 KiB.

Then decode with `targetWidth`/`targetHeight` ≤ 256. A failure means no
photo, never an error screen.

## Server storage and routes

The domain logic lives in a `profiles` service behind the storage
interface, not in handlers (`AGENTS.md`).

**The new table** (`encrypted_profiles`, a migration):

| Column | Notes |
|---|---|
| `subject_kind` | `account` or `conversation` |
| `subject_id` | |
| `version` | INTEGER, starts at 1, +1 per write |
| `key_id` | 32 hex characters |
| `ciphertext` | BLOB, ≤ 256 KiB + 32 |
| `size_bytes` | |
| `updated_by_account_id` | |
| `updated_at` | |

- The primary key is (`subject_kind`, `subject_id`).
- Rows are inline in SQLite (small, and in the normal backups). Each row
  counts toward the uploader's storage limit and write budget (D38).
- A row is deleted with its account or conversation, and included in the
  owner's account export (`account_store.go`).
- **Never logged:** ciphertext and key IDs.

**Routes.** Every write uses `withAuth` and `withWriteBudget`, plus the
`diskLow` guard, as uploads do.

| Route | Who | Notes |
|---|---|---|
| `PUT /api/v1/profiles/account/me` | The account | Body is the raw blob. Headers: `X-Private-Messenger-Encrypted: 1`, `X-Profile-Key-Id`, and either `If-Match: "<version>"` or `If-None-Match: *` for the first write. Errors: `412 version_conflict`, `413 profile_too_large`, `400 invalid_profile` (bad magic, key ID or size). Returns `{version}` |
| `DELETE /api/v1/profiles/account/me` | The account | Clears `ciphertext` and `key_id`, **keeps `version`** as a tombstone (+1). The next PUT continues from it with `If-Match`, so that receivers' rollback check (revision ≥ cached) still holds. GET then answers 404. `If-None-Match: *` applies only when no row ever existed. The group route behaves the same way |
| `GET /api/v1/profiles/account/{account_id}` | The owner, or an account sharing a **current** membership with the owner, with no block in either direction. Otherwise 404, never 403, so the route is not an existence oracle | Returns the blob, with `ETag: "<version>"` and `X-Profile-Key-Id`; `If-None-Match` gives 304 |
| `PUT /api/v1/conversations/{id}/profile` | A member with role `owner` or `admin` (defence in depth); `kind == group` only | Same headers and errors as the account PUT |
| `GET /api/v1/conversations/{id}/profile` | Current members | As the account GET |
| `DELETE /api/v1/conversations/{id}/title` | `owner` or `admin` | Clears the legacy plaintext title ([below](#group-titles-today)) |
| `POST /api/v1/profiles/versions` | Any account | `{"account_ids":[≤200],"conversation_ids":[≤200]}` returns `{kind, id, version, key_id}` for the subjects the caller may read. Unreadable or missing subjects are left out silently |

**The sync event `profile.updated`** has the payload
`{subject_kind, subject_id, version, key_id}` and no content. It goes:

- for an account: to the owner's other devices and to every account that
  shares a conversation with the owner, deduplicated;
- for a group: to its members.

An app that predates W7 step 0 stops sync on this unknown type, so W11
ships only after step 0.

## MLS payloads

These are reserved in the W7 v2 registry, with `v: 2` and a normal
padded payload.

| Type / field | Body | Accepted when |
|---|---|---|
| `profile_key` (type) | `{"key":"<base64, 32 bytes>","key_id":"<32 hex>","version":<int>}` | Stored as a key for the **sender account's** own profile. No subject field exists, so a member cannot hand out a key "for" someone else. `version` is a hint only (the server version at send time) |
| `profile_key` (sidecar field on `text`, `reply`, `attachment_manifest`, `poll`) | `{"key":…,"key_id":…}` | Same rule as the type |
| `group_profile_key` (type) | `{"key":…,"key_id":…,"version":<int>}` | Stored for the conversation the message arrived in; there is no subject field. Accepted from any current member |

Why any member may relay a group key:

- The server lets only `owner` and `admin` replace the group record.
- The key ID picks the key to use.
- A wrong key just fails the AEAD.

Even an honest key holder could, with a hostile server, publish fake group
content; see [Risks](#risks-and-residuals). A key's own field rules: `key`
decodes to exactly 32 bytes, `key_id` matches `^[0-9a-f]{32}$`, and
`version` is ≥ 0. A key that breaks them is dropped alone; the message
around it is kept.

## Key delivery

**An account's key is sent:**

1. Once into a conversation this account **creates**, after the creation
   commit is accepted.
2. Once into a conversation this account **joins**, when its device
   processes the Welcome. This does not apply to a device that was just
   linked, which has no key yet (see [Own devices](#own-devices)).
3. As a **sidecar** on every post, when the account has a key. This is how
   members who joined after this account last sent a `profile_key`
   learn it, with no burst of messages on each join. A member who never
   posts shows by username to newcomers until it posts or rotates.
4. Into **every** conversation on [rotation](#rotation), and when the
   first profile is saved (which is a rotation from "no key").

An update that keeps the key sends **no MLS message**: the server's
`profile.updated` event makes readers re-fetch.

**A group's key is sent:**

1. By the creator, after the creation commit is accepted.
2. By the device whose commit **adds** devices (new members, or a
   member's newly linked device), right after that commit is accepted, in
   the new epoch, if it holds the key. The server withholds older-epoch
   messages from newcomers (I51), so the key must go out after the commit.
3. On rotation.

## Rotation

**Account key.**

"Contact" has no stored meaning in Veritra: there is no contact list. This
design defines the **audience** as every account that has shared a
conversation with this account while the current key was in use. The
device keeps the audience locally and adds the co-members each time a
roster refreshes.

Rotation is due when either holds:

- this account **blocks** someone. The rotation then runs at once;
- an audience member **no longer shares any conversation** with this
  account: it left or was removed, a DM was deleted, or its account was
  deleted. The rotation is debounced to at most once an hour, and runs at
  the next start if the app was closed.

The rotation:

1. Create a new key and key ID.
2. Re-encrypt the current name and photo with `revision` = current
   version + 1.
3. `PUT` with `If-Match`.
4. Queue `profile_key` into every current conversation.
5. Set the audience to the current co-members.
6. Delete the old key once the sends are queued.

On a 412, another of the account's devices won the race. The device
re-reads the record's metadata. If its own key cannot read the new key ID,
it shows its cached profile and waits for the key to arrive over MLS.

**Group key.** Rotation is due when this device processes a commit that
removes any device from the group, because a revoked device also held the
key.

- Any `owner` or `admin` device with a rotation due rotates:
  1. Create a new key.
  2. Re-encrypt with `revision` + 1.
  3. `PUT` with `If-Match`.
  4. Send `group_profile_key` in the new epoch.
- On a 412, a device re-reads the metadata. If the `key_id` changed after
  the removal, someone else rotated, and the due flag clears.
- Other devices need no flag; they simply receive the new key.

**Cost** (checked against D38, tier S):

- A full rotation for 1,000 conversations is one PUT (≤ 256 KiB) and 1,000
  `profile_key` envelopes of about 1 KiB each. That is about 1.3 MiB,
  well inside 64 MiB per hour.
- Deliveries are limited to 1,000 per minute. The normal outbox paces them
  and honours `Retry-After`, so some readers see the new key minutes
  later. Until then they keep the cached profile.

## Own devices

Profile keys are account-level, but Veritra has no account-level key until
K0.

- **Existing own devices** learn keys like anyone else. A `profile_key`
  type or sidecar sent by the account's other devices is stored as this
  account's own key: MLS delivers every message to all of the account's
  devices except the sender.
- **A newly linked device:**
  - When the link's commits are accepted, the existing device sends one
    `profile_key` into the most recently active conversation the new
    device belongs to. One is enough, since own devices accept the key
    from any conversation.
  - Until the key arrives, the new device shows the account's username.
  - If the user edits the profile there before the key arrives, that is a
    rotation: a new key, sent to every conversation.
- **An account with no conversations** has no MLS path to its other
  devices. Each device edits under its own key, and the other device sees
  a key ID it cannot read until a conversation exists. This is rare; K0
  removes it.
- **Backups (D27):** the account's own key, its audience, every received
  key, and the cached profiles go into the next backup plaintext version
  (§8 of the W7 design). Profiles can be fetched again, but keys cannot,
  because the MLS messages that carried them never decrypt twice.

## Receiving and caching

**Local tables:**

- `local_profile_keys(subject_kind, subject_id, key_id, key, received_at)`,
  primary key (kind, id, key_id). At most 4 per subject; the oldest goes
  first.
- `local_profiles(subject_kind, subject_id, server_version, key_id, revision, name, photo_png, fetched_at)`.
- `local_profile_state(name PK, value)`, for the own key, the audience and
  pending rotations.

**A fetch happens when:**

- a new key arrives;
- a `profile.updated` event shows a version above the cached one;
- a chat or member list opens with profiles more than 24 hours old. The
  app first asks `POST /profiles/versions` in batches of 200, then GETs
  only what changed.

**A fetched record is accepted only when every check passes:**

1. The AEAD opens with the key whose `key_id` equals the served
   `X-Profile-Key-Id`.
2. `kind` and `subject_id` equal what was requested.
3. `revision` equals the served `version`.
4. `revision` is ≥ the cached revision. Otherwise the server is rolling
   the record back, and the record is ignored.
5. The name passes the rules above.

If any check fails, the cached profile stays, or the username shows when
nothing is cached.

**Cleanup:**

- Blocking an account deletes its cached profile and keys.
- When no conversation is shared with an account any more, its profile
  and keys are deleted (data minimisation).
- Leaving a group deletes the group's.

## Display and impersonation

A display name is self-chosen and not verified.

- **Shown everywhere:** the display name, or the username when there is
  none. In a group, the sender line shows the display name.
- **Shown with the username** (`Ana (@ana)`): the profile sheet, the
  member list, the safety-number screen, and anywhere a name and a
  verification appear together.
- **Never used as identity:** a profile name never replaces the account ID
  in a safety-number transcript or a verification record.

## Group titles today

`conversations.title` is server plaintext. It is set at creation, and
there is no route to change it.

- **New groups** after W11: the app sends no `title`. The name goes into
  the encrypted group profile.
- **Existing groups:** the first `owner` or `admin` device that opens a
  group with a server title and no encrypted profile migrates it:
  1. Create the profile with the title as its name.
  2. PUT it.
  3. Send the key.
  4. Call `DELETE /conversations/{id}/title`.

  Until the migration, the app shows the server title as a fallback.
- **A later step,** once groups have migrated: the server refuses a
  non-empty `title` for `kind == group`. Community and channel names wait
  for C3.

## Build steps

1. **W7 step 0** (if not already done).
2. **Server:**
   - the migration, the `profiles` service, the routes and
     `profile.updated`;
   - tests for each ACL rule (member, ex-member, blocked, stranger: 404),
     the 412 race, the size limits, deletion with the account and with the
     conversation, the export, and no ciphertext in logs.
3. **Crypto (Dart):** `ProfileRecordCodec`, which builds the plaintext and
   the padding, encrypts and decrypts through the chunk ABI, and runs the
   checks under [Receiving](#receiving-and-caching). Tests: the vector
   above, a wrong subject, a wrong key ID, a revision not equal to the
   version, a rollback, an over-size photo, and a bad name.
4. **App:**
   - turn on `profile_key`, the sidecar and `group_profile_key` in the
     codec;
   - the local tables and the backup bump;
   - the delivery and rotation triggers;
   - the photo pipeline;
   - the profile editors (own and group), and display everywhere names
     appear;
   - l10n in English and Serbian.
5. **End to end:**
   - `native_outbox_test.dart` covers the new types;
   - a demo test: Ana sets a name and photo; Bob sees them in the DM and
     the group;
   - Ana blocks Bob and changes her name; Bob's app cannot read the new
     record;
   - a member removed from a group cannot fetch the group profile, and
     cannot read the rotated key.

## Risks and residuals

- **A hostile server together with any key holder** can serve fake
  content. The holder can encrypt a fake group record, or a fake account
  record for an account whose key it holds. The server then accepts the
  PUT or serves it. Records are encrypted, not signed. A fake account
  record needs that account's key, which only its audience holds. C4
  (signed group state) and K0 could add signatures.
- **Rollback to a record never seen** cannot be detected: a fresh device
  accepts any valid revision. It is detected once a newer revision is
  cached.
- **The server learns** rotation times (`key_id` changes), update times
  and size buckets.
- **The image decoder** parses data from other users. The pre-decode
  checks limit this, but do not remove it.
- **A member who never posts** shows by username to people who joined
  after its last `profile_key`.

## Open questions for the owner

1. **What counts as "contact removal" for rotation.**
   - This design rotates when the audience shrinks, debounced hourly, and
     at once on a block.
   - The cheaper choice is to rotate on block only (Signal does this).
     Someone who leaves a shared group would then still read future
     changes, while the server still lets them fetch, which it does not
     once they share no conversation.
   - Recommendation: the design as written.
2. **A JPEG/WebP encoder dependency** (for example the `image` package,
   MIT) for smaller and sharper photos than PNG at 256×256. It needs the
   owner's yes, a licence review and a `THIRD_PARTY_NOTICES.md` entry. The
   design works without it.
3. **Who may edit a group's name and photo.** This design allows `owner`
   and `admin` (enforced by the server, checked by the apps). WhatsApp
   lets admins choose "all members"; that would come with C4's permission
   switches.
4. **Whether to refuse server-side group titles** once migration is done,
   for every client.
