# W11: encrypted profiles (design)

**Status: proposed, not yet built.**

- **Package:** W11 in the `STATE.md` build plan (route "Opus designs").
- **Done when:** "A display name and photo for people, a name and photo
  for groups, all encrypted, with the key given only to contacts and group
  members."
- **Depends on:** W7 step 0 ([`../crypto.md`](../crypto.md#proposed-not-yet-built-application-payload-v2-w7),
  §1). The MLS types and sidecars used here are reserved in the W7 v2
  registry (§4, §5.7), so W11 needs no further payload version bump.
- **No ABI change.** Records are encrypted with the existing chunk AEAD
  (`pm_crypto_attachment_encrypt_chunk`). A dedicated profile AEAD
  function with its own domain label could ride along with K0's additive
  ABI v7 later.
- **Review:** an independent review approved this design with changes,
  which are applied here.

## Summary

- Each **account** has a random 32-byte profile key. Its display name and
  photo are encrypted under it as one record, which the server stores per
  account and replaces on each change.
- Each **group** has its own key and record, stored per conversation.
- Keys travel only inside MLS messages, so only people who share a
  conversation with the subject ever get them.
- Keys **rotate lazily**. A block or a departure marks a rotation as due,
  and the next write of the profile uses a new key.
- The server stores ciphertext, a version number, a key ID, sizes and
  times. It never sees a name, a photo or a key.
- Usernames stay visible to the server (they are the login and lookup
  handle). Group titles stop being visible: today `conversations.title` is
  plaintext on the server; see [Group titles today](#group-titles-today).

## What the server sees

| Seen | Not seen |
|---|---|
| Subject kind and ID (`account` / `acct_…`, `conversation` / `conv_…`) | Name, photo, keys |
| Ciphertext and its size bucket: 4 KiB (no photo) or 256 KiB (with a photo). **Whether a photo exists is therefore visible** (S15) | The photo itself |
| Server `version` (counts writes) and `key_id` (a hash of the key; a change reveals a rotation) | Who holds the key |
| Uploading account and time | |

The server already knows conversation membership, and that is all it uses
to decide who may read a record (defence in depth). Confidentiality rests
on the key.

## Subjects and limits

| Subject | Fields | Limits |
|---|---|---|
| Account profile | `name`, `photo` | Name 1–64 UTF-16 units after trimming, or `null` for a removed profile; photo optional |
| Group profile (conversation kind `group`) | `name`, `photo` | Name 1–100 UTF-16 units, or `null`; photo optional |
| DM | none | A DM shows the peer's account profile |
| Community and channel names, topics, icons | Not in W11 | C3 may reuse this mechanism; out of scope here |

A name must not contain:

- C0 or C1 control characters;
- bidi controls (U+202A–U+202E, U+2066–U+2069);
- the direction marks U+200E, U+200F and U+061C.

Receivers reject a record that breaks this (see
[Receiving](#receiving-and-caching)), so a name cannot reorder the text
around it.

Photos:

- PNG only;
- at most 512×512 pixels when received (256×256 when sent);
- at most 192 KiB;
- a whole record at most 256 KiB of plaintext.

## Keys

- **Profile key:** 32 bytes from `Random.secure()`.
- **Key ID (S7):** `hex(SHA-256("veritra-profile-key-id-v1" ‖ key)[0..16])`,
  32 lowercase hex characters. Receivers recompute it, and drop any
  received key whose `key_id` does not match.
  - Vector: key `00 01 … 1f` gives `5a7f7bb0d6bff19bebf7bfc3f05a9ed5`.
- **An account key** is created by the account's device on the first
  profile save, and replaced at the first write after a rotation becomes
  due ([Rotation](#rotation)).
- **A group key** is created by whoever first sets the group's name or
  photo (normally the creator, at creation), and is replaced the same way.
- **Keys held per subject.** A receiver keeps up to 4 keys per subject,
  keyed by `key_id`, and uses the one whose `key_id` matches the record the
  server serves.
  - **Eviction** removes the oldest first, but **never** the key that
    opens the cached record.
  - **Group keys** can come from any member. A received group key that
    does not open the record the server serves at that moment is dropped
    at once: the app fetches on key arrival. A member therefore cannot
    flood the slots with junk keys to push out the real one.

## Record format and encryption

Plaintext, in order:

1. `VPR1`, 4 bytes;
2. a big-endian u32 JSON length, then the JSON in UTF-8;
3. a big-endian u32 photo length (0 when there is no photo), then the PNG
   bytes;
4. random padding to **4 KiB** when there is no photo, or **256 KiB**
   when there is one.

The JSON has its keys in this order:

```json
{"v":1,"kind":"account","subject_id":"acct_…","revision":3,"name":"Ana","photo":{"media_type":"image/png","width":256,"height":256}}
```

- `name` and `photo` may each be `null`. A record with both `null` is a
  **removed profile** (S9).
- `kind` is exactly `account` or `conversation`. A group's record uses
  `conversation`. The same two literals are used in the AEAD context, the
  server's `subject_kind`, the local tables and `profile.updated`.
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
  where `\0` is one zero byte. It is 97 bytes for an account and 102 for
  a group; the ABI allows up to 512. Exactly:
  - an account: `veritra-profile-v1␀account␀acct_<32 hex>␀<key_id>`;
  - a group: `veritra-profile-v1␀conversation␀conv_<32 hex>␀<key_id>`.

The stored blob is `VPE1` + `nonce_prefix` + the ciphertext with its tag.

- **Binding.** The context binds the subject and the key ID. The server
  therefore cannot serve Bob's record as Ana's, or move a record to
  another key ID, without the AEAD failing.
- **Domain label.** The AEAD's built-in label stays
  `veritra-attachment-v1`. Profile and attachment keys are independent
  random keys and never shared, so the profile prefix in the context
  separates the two uses. The G25 reviewer should note this choice. The
  ABI v7 function mentioned above would remove it.

**Test vectors.** They were computed with Python `cryptography` 50.0.1
from the construction in `attachment.rs`. The build must reproduce them
through the ABI.

- key = bytes `00 01 … 1f`; key_id `5a7f7bb0d6bff19bebf7bfc3f05a9ed5`
  (derived as above)
- nonce_prefix = `01 02 03 04 05 06 07 08`, index 0
- plaintext = ASCII `veritra profile vector`
- **Account**, subject `acct_11111111111111111111111111111111`:
  - context (97 bytes) =
    `766572697472612d70726f66696c652d7631006163636f756e7400616363745f3131313131313131313131313131313131313131313131313131313131313131003561376637626230643662666631396265626637626663336630356139656435`
  - ciphertext‖tag =
    `fc7a5cd9f965944bfcbabb3b1d92aa76d7cb852c0473474d91bd81f77bc0a445926c9dd158d5`
- **Group**, subject `conv_55555555555555555555555555555555`:
  - context (102 bytes) =
    `766572697472612d70726f66696c652d763100636f6e766572736174696f6e00636f6e765f3535353535353535353535353535353535353535353535353535353535353535003561376637626230643662666631396265626637626663336630356139656435`
  - ciphertext‖tag =
    `fc7a5cd9f965944bfcbabb3b1d92aa76d7cb852c0473958f58b7673fe89ace181486b26b73e8`
- Changing the subject to the `…2222…` ID of the same kind must fail to
  decrypt.
- The first 22 bytes are the same in both vectors, because the key and
  nonce are the same; only the tag differs. Real uploads never reuse a
  nonce prefix.

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
| `ciphertext` | BLOB, 4 KiB or 256 KiB, plus 28 bytes |
| `size_bytes` | |
| `updated_by_account_id` | |
| `updated_at` | |

- The primary key is (`subject_kind`, `subject_id`).
- Rows are inline in SQLite (small, and in the normal backups). Each row
  counts toward the uploader's storage limit and write budget (D38).
- A row is deleted only with its account or conversation, and is included
  in the owner's account export (`account_store.go`).
- **Never logged:** ciphertext and key IDs.

**Who may read** (the "read rule", also used for `profile.updated`):

- **An account record:** its owner, or an account that shares a
  **current** membership with the owner, as long as neither has blocked
  the other.
- **A group record:** the group's current members.

Anyone else gets 404, never 403, so the route is not an existence oracle.

**Routes.** Every write uses `withAuth` and `withWriteBudget`, plus the
`diskLow` guard, as uploads do.

| Route | Who | Notes |
|---|---|---|
| `PUT /api/v1/profiles/account/me` | The account | Body is the raw blob. Headers: `X-Private-Messenger-Encrypted: 1`, `X-Profile-Key-Id`, and either `If-Match: "<version>"` or `If-None-Match: *` for the first write. Errors: `412 version_conflict`, `413 profile_too_large`, `400 invalid_profile` (bad magic, key ID or size not 4 KiB or 256 KiB plus overhead). Returns `{version}` |
| `GET /api/v1/profiles/account/{account_id}` | The read rule | Returns the blob, with `ETag: "<version>"` and `X-Profile-Key-Id`; `If-None-Match` gives 304 |
| `PUT /api/v1/conversations/{id}/profile` | A member with role `owner` or `admin`; conversation kind `group` only | Same headers and errors as the account PUT. This role rule is the **only** check on who wrote a group record (S12): records are not signed |
| `GET /api/v1/conversations/{id}/profile` | The read rule | As the account GET |
| `DELETE /api/v1/conversations/{id}/title` | `owner` or `admin` | Clears the legacy plaintext title ([below](#group-titles-today)) |
| `POST /api/v1/profiles/versions` | Any account | `{"account_ids":[≤200],"conversation_ids":[≤200]}` returns `{kind, id, version, key_id}` for the subjects the caller may read. Unreadable or missing subjects are left out silently |

There is **no client DELETE** of a record. A user removes a profile by
uploading an encrypted removed record (`name` and `photo` both `null`,
`revision` + 1, S9). The version history therefore stays continuous, and
receivers' rollback check keeps working.

**The sync event `profile.updated`** has the payload
`{subject_kind, subject_id, version, key_id}` and no content. It goes to
every account the read rule admits (deduplicated), and to the owner's
other devices. An app that predates W7 step 0 stops sync on this unknown
type, so W11 ships only after step 0 (P5).

## MLS payloads

These are reserved in the W7 v2 registry, with `v: 2` and a normal
padded payload. The two types are sent with `hidden: true`, so an older
app stores them without showing a row.

| Type / field | Body | Accepted when |
|---|---|---|
| `profile_key` (type) | `{"key":"<base64, 32 bytes>","key_id":"<32 hex>","version":<int>}` | Stored as a key for the **sender account's** own profile. No subject field exists, so a member cannot hand out a key "for" someone else |
| `profile_key` (sidecar on `text`, `reply`, `attachment_manifest`, `poll`) | `{"key":…,"key_id":…,"version":<int>}` | Same rule as the type |
| `group_profile_key` (type) | `{"key":…,"key_id":…,"version":<int>}` | Stored for the conversation the message arrived in; there is no subject field. Accepted from any current member, then kept only if it opens the served record (§Keys) |
| `group_profile_key` (sidecar on the same post types) | Same body | Same rule |

**Field rules:**

- `key` decodes to exactly 32 bytes.
- `key_id` equals the derived ID of `key`.
- `version` is ≥ 0.

A key that breaks them is dropped alone; the message around it is kept.

**`version` (S10).** It is the server version current when the key was
sent.

- **For account keys only,** the hint comes from the subject account
  itself, authenticated by MLS. It is therefore a **rollback floor**: a
  fetched record with `revision` below the highest hint received from that
  account is rejected.
- **For group keys it is never a floor.** Any member can send one, and a
  high value would lock everyone out.

**Why any member may relay a group key:**

- The server lets only `owner` and `admin` replace the group record.
- The key ID picks the key to use.
- A key that does not open the served record is dropped.

A hostile server, working with any key holder, could still publish fake
group content; see [Risks](#risks-and-residuals).

## Key delivery

**An account's key is sent:**

1. Once into a conversation this account **creates**, after the creation
   commit is accepted.
2. Once into a conversation this account **joins**. All the account's
   devices process the Welcome, but only one sends the key: the device
   whose device ID is lowest among the account's devices in that group
   after the commit, and only if it holds the key. When that device has no
   key, the sidecar below covers the gap.
3. As a **sidecar** on every post, when the account has a key. This is how
   members who joined after this account last sent a `profile_key` learn
   it, with no burst of messages on each join. A member who never posts
   shows by username to newcomers until it posts or changes its key.
4. At the **first write after a rotation became due**, and at the first
   profile save: into every conversation where this account may post
   ([Rotation](#rotation)).

An update that keeps the key sends **no MLS message**: the server's
`profile.updated` event makes readers re-fetch.

**A group's key is sent:**

1. By the creator, after the creation commit is accepted.
2. By the device whose commit **adds** devices (new members, or a
   member's newly linked device), right after that commit is accepted, in
   the new epoch, if it holds the key. The server withholds older-epoch
   messages from newcomers (I51), so the key must go out after the commit.
3. **As a sidecar (S13):** any device that has processed a commit adding
   devices, since its own last post in that group, attaches
   `group_profile_key` to its next post there, if it holds the key. This
   covers an adder that had no key, and an explicit send that was lost.
4. At the first group-profile write after a rotation became due.

## Rotation

**Rotation is lazy (B1).** A block or a departure only marks a rotation
as due. The next write of that profile (any edit, including removing it)
uses a new key and sends that key out.

**Why lazy is enough.** A blocked or departed account holds only the old
key. That key opens only the record it could already read while it was in
the audience. Everything written after the departure is under a new key.
On top of that, the server answers its GETs with 404 once it shares no
conversation. Re-encrypting unchanged content at once protects nothing
new.

**Why not eager.** In a 100-member community, one member leaving shrinks
the audience of the other 99. If each rotated at once:

- each would send its new key into every conversation it is in;
- every reader would then re-fetch about 99 × 98 ≈ 9.7k records, of up to
  256 KiB each, about 2 GiB of traffic for one leave;
- one account joining and leaving in a loop could make a whole community
  repeat this at will.

With lazy rotation, only the user's own edit triggers the cost: one PUT
and one envelope per conversation.

**Account key.**

- "Contact" has no stored meaning in Veritra: there is no contact list.
  This design defines the **audience** as every account that has shared a
  conversation with this account while the current key was in use. The
  device keeps the audience locally and adds the co-members each time a
  roster refreshes.
- **A rotation becomes due when either holds:**
  - this account **blocks** someone;
  - an audience member **no longer shares any conversation** with this
    account: it left or was removed, a DM was deleted, or its account was
    deleted.
- **The next write when a rotation is due:**
  1. Create a new key (its key ID is derived).
  2. Encrypt the new content with `revision` = current version + 1.
  3. `PUT` with `If-Match`.
  4. Queue `profile_key` into every current conversation where this
     account may post. **Skip** admin-only and announcement conversations
     where it may not (C2; S14), since the server would refuse those
     envelopes.
  5. Set the audience to the current co-members, and clear the due flag.
  6. Delete the old key once the sends are queued, unless it still opens
     a cached record of this account on this device.
- **On a 412,** another of the account's devices won the race. The device
  re-reads the metadata. If its own key cannot read the new key ID, it
  shows its cached profile and waits for the key over MLS.
- **Cost of the skip (S14).** An account that shares only announcement
  conversations with someone cannot deliver a new key to them. That person
  keeps seeing the last record they could open.

**Group key.**

- A rotation becomes due on an `owner` or `admin` device when it processes
  a commit that removes any device from the group, because a revoked
  device also held the key.
- The next group-profile write by such a device uses a new key:
  1. Create the key.
  2. Encrypt with `revision` + 1.
  3. `PUT` with `If-Match`.
  4. Send `group_profile_key` in the new epoch.
- **On a 412,** the device re-reads the metadata. If the `key_id` changed
  after the removal, another admin already wrote under a new key, and the
  due flag clears.

**Cost** (checked against D38, tier S):

- A write after a due rotation, for 1,000 conversations, is one PUT
  (≤ 256 KiB) and up to 1,000 `profile_key` envelopes of about 1 KiB
  each. That is about 1.3 MiB, well inside 64 MiB per hour.
- Deliveries are limited to 1,000 per minute. The normal outbox paces them
  and honours `Retry-After`, so some readers get the key minutes later.
  Until then they keep the cached profile.

## Blocking

What a block does and does not hide (S8):

- **In a DM only:** after a block, the blocked account shares no
  conversation, so the next write uses a key it never receives, and the
  server 404s its GETs.
- **In a shared group:** a block does **not** hide the profile
  cryptographically. MLS encrypts every group post to every member. The
  server filters only what the blocked account sends to the blocker
  (`ConversationRecipientsForSender`, `user_control_store.go`), not the
  reverse. So the blocked account receives the sidecar with the new key.
  The only barrier is the server's read rule, which 404s the blocked
  account's GETs. The app says so: "In groups you share, they may still
  see your profile."
- **The 404 reveals the block.** The blocked account can see it still
  shares a group but can no longer fetch the profile. This is an owner
  question below.

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
  - If the user edits the profile there before the key arrives, the edit
    uses a new key, sent as in step 4 of the rotation.
- **An account with no conversations** has no MLS path to its other
  devices. Each device edits under its own key, and the other device sees
  a key ID it cannot read until a conversation exists. This is rare; K0
  removes it.
- **Backups (D27):** the next backup plaintext version holds:
  - the account's own key;
  - the audience and the due flags;
  - every received key, with the highest version hints;
  - the cached profiles.

  See §8 of the W7 design. Profiles can be fetched again, but keys cannot,
  because the MLS messages that carried them never decrypt twice.

## Receiving and caching

**Local tables:**

- `local_profile_keys(subject_kind, subject_id, key_id, key, received_at)`,
  primary key (kind, id, key_id). At most 4 per subject; see §Keys for
  eviction.
- `local_profiles(subject_kind, subject_id, server_version, key_id, revision, name, photo_png, fetched_at, version_floor)`.
- `local_profile_state(name PK, value)`, for the own key, the audience and
  the due flags.

**A fetch happens when (S11):**

- a new key arrives;
- a `profile.updated` event shows a version above the cached one;
- the periodic check runs, at app start and every 24 hours: a batch
  `POST /profiles/versions` (200 per request), then a GET only for what
  changed.

Opening a screen never triggers a fetch.

**A fetched record is accepted only when every check passes:**

1. The AEAD opens with the key whose `key_id` equals the served
   `X-Profile-Key-Id`.
2. `kind` and `subject_id` equal what was requested.
3. `revision` equals the served `version`.
4. `revision` is ≥ the cached revision, and, for an account, ≥ its
   version floor. Otherwise the server is rolling the record back, and the
   record is ignored.
5. The name passes the rules above.

**When a fetch fails:**

- A failed check keeps the cached profile, or shows the username when
  nothing is cached.
- **A 404 also keeps the cache (S9).** A 404 can mean a block or a hostile
  server. Only a removed record clears the profile.

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
  non-empty `title` for conversation kind `group`. Community and channel
  names wait for C3.

## Build steps

1. **W7 step 0** (if not already done).
2. **Server:**
   - the migration, the `profiles` service, the routes and
     `profile.updated`;
   - tests for each read-rule case (member, ex-member, blocked in either
     direction, stranger: 404), the 412 race, the two size buckets,
     deletion with the account and with the conversation, the export, and
     no ciphertext or key ID in logs.
3. **Crypto (Dart):** `ProfileRecordCodec`, which builds the plaintext and
   the padding, derives key IDs, encrypts and decrypts through the chunk
   ABI, and runs the checks under [Receiving](#receiving-and-caching).
   Tests:
   - the vectors above and the key-ID vector;
   - a wrong subject, a wrong or underived key ID, and a revision not
     equal to the version;
   - a rollback below the cache and below the version floor;
   - an over-size photo, a bad name, and a removed record.
4. **App:**
   - turn on `profile_key`, `group_profile_key` and both sidecars in the
     codec;
   - the local tables and the backup bump;
   - the delivery triggers and the lazy rotation;
   - the photo pipeline;
   - the profile editors (own and group), and display everywhere names
     appear;
   - l10n in English and Serbian.
5. **End to end:**
   - `native_outbox_test.dart` covers the new types and sidecars.
   - **Basic:** Ana sets a name and photo; Bob sees them in the DM and in
     the group.
   - **A departure sends nothing:** Bob leaves the group they share, and
     no message is sent. Ana's next edit then uses a new key, sent to
     every conversation where she may post, and Bob cannot read it.
   - **Block, DM only:** Ana blocks Bob and edits. Bob has no new key, and
     the server answers 404.
   - **Block, shared group:** Ana blocks Bob and edits. Bob's app holds
     the new key (documented), and the server answers 404.
   - **Junk keys:** a member sends 10 junk `group_profile_key` messages,
     and the group profile still opens.
   - **Group removal:** a member removed from a group cannot fetch the
     group profile, and cannot read it after the next admin edit.

## Risks and residuals

- **A hostile server together with any key holder** can serve fake
  content (S12).
  - The holder can encrypt a fake group record, or a fake account record
    for an account whose key it holds. The server then accepts the PUT or
    serves it.
  - Who may write a group record is enforced by the server only; records
    are encrypted, not signed.
  - A fake account record needs that account's key, which only its
    audience holds.
  - C4 (signed group state) and K0 could add signatures.
  - An alternative for groups, once C4 brings ABI v7: hold the group key
    in an MLS group-context extension, so that it changes atomically with
    membership.
- **Lazy rotation** leaves the old key with departed or blocked accounts
  until the next edit. It opens only content they already saw.
- **Blocks in shared groups** do not hide a profile cryptographically
  ([Blocking](#blocking)).
- **Rollback to a record never seen** cannot be detected beyond the
  version floor: a fresh device accepts any valid revision at or above it.
- **The server learns** rotation times (`key_id` changes), update times,
  and whether a photo exists.
- **The image decoder** parses data from other users. The pre-decode
  checks limit this, but do not remove it.
- **Members who never post, and announcement-only overlaps (S14),** show
  by username, or by an older record, to some readers.

## Open questions for the owner

1. **What makes a rotation due.**
   - This design marks one due when the audience shrinks and on a block,
     and rotates at the next edit.
   - The alternative is a block only (Signal's choice).
   - Recommendation: the design as written; laziness keeps both cheap.
2. **Is it acceptable that the 404 reveals a block** to an account that
   still shares a group?
   - The alternative is to serve the record to co-members of a shared
     group even after a block. It hides nothing extra (they hold the key
     anyway) and reveals nothing.
   - Recommendation: serve it, and keep the 404 for DM-only blocks.
3. **A JPEG/WebP encoder dependency** (for example the `image` package,
   MIT) for smaller and sharper photos than PNG at 256×256. It needs the
   owner's yes, a licence review and a `THIRD_PARTY_NOTICES.md` entry. The
   design works without it.
4. **Who may edit a group's name and photo.** This design allows `owner`
   and `admin`. WhatsApp lets admins choose "all members"; that would come
   with C4's permission switches.
5. **Whether to refuse server-side group titles** once migration is done,
   for every client.
