# Independent security review brief

Production messaging stays off in release builds (`mobile/lib/main.dart`,
`PM_CRYPTO_UNAVAILABLE`, `UnavailableCryptoService`) until this review is done
and every gate in [`../STATE.md`](../STATE.md#release-gates) passes. An LLM
review cannot satisfy it. Independent reviewer: **not assigned**.

Moved here from the former `docs/board.md` on 2026-10-23; the change log of
the crypto surface since the freeze is in [`crypto.md`](crypto.md).

## Frozen design surface

- MLS 1.0 through OpenMLS 0.9.2 using
  `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
- Application marker `mls10-openmls-v1`; the server rejects other markers.
- Native ABI v6 (sender binding D25, staged membership commits D28) in
  `crypto/rust/include/veritra_crypto.h`.
- Credentials bind length-prefixed account/device identity and the MLS
  signature key. Key packages are checked against the expected account/device.
- Local state uses SQLite3MC ChaCha20 with a random 256-bit key in platform
  secure storage (Windows DPAPI and the Linux Secret Service on desktop, D26).
  MLS state, rollback counter, affected ciphertext rows, decrypted history,
  dedupe marker, and sync cursor commit atomically. Local schema v12.
- Other readable copies, all inside the same encrypted database and nowhere
  else: unsent composer drafts (`local_drafts`, W6; deleted in the transaction
  that queues the message), the full-text index of message text
  (`local_message_search`, W10; FTS5 with secure-delete, kept equal to
  `local_messages` by triggers, so an edit, delete, expiry or wipe leaves it at
  once) and the device's copy of conversation mutes. None goes in a backup
  (except history, as before), a log, a push or a request. Expired messages
  (W2) are deleted from `local_messages`, their reactions and the index; the
  expiry is the server's `expires_at`, stamped when the message was decrypted or
  first echoed, and it is not MLS-authenticated.
- Decrypted history (D22/D23) lives in `local_messages` and
  `local_message_reactions`, keyed by the authenticated
  `<sender_device_id>:<action_id>`. Edits and deletes apply only when the
  authenticated sender account matches the original. Server-visible
  `crypto_metadata` does not name the payload type.
- `VAP1` application payloads use versioned JSON padded to 256-byte classes.
  Authenticated context duplicates and verifies conversation, sender device,
  action ID, type, and version after decryption.
- Attachments and backups use independently authenticated AES-256-GCM chunks
  with unique keys/nonces. Attachment keys and content metadata travel only in
  MLS payloads. Recovery uses user-held 256-bit capability and encryption keys;
  older capabilities are invalidated.
- Membership changes (D28) are staged commits accepted only on the group's
  current epoch, bundled with their Welcome and roster change; the server
  delivers encrypted events only inside each device's join cursor.
- Revocation is pending, commit-submitted, then complete only after every
  snapshotted active device confirms processing the MLS removal.
- Device-link and peer-verification transcripts are domain-separated and
  length-prefixed. Safety hashes sort MLS credential/signature-key records and
  bind group ID and epoch.
- Push carries only `new_encrypted_event_available`; no sender or content.
- Call SDP/ICE is an authenticated MLS application payload. Media uses WebRTC
  DTLS-SRTP and operator-controlled TURN. Call lifecycle timing is visible.

## Required review surface

- `crypto/rust/src/mls.rs`, `mls/state.rs`, `attachment.rs`, `ffi.rs`, `lib.rs`
- `mobile/lib/crypto/`, `mobile/lib/storage/`, `mobile/lib/calls/`
- server MLS, message, attachment, backup, revocation, push, and call paths
- migrations 0021-0029 (MLS messages, revocations, recovery, push wake jobs,
  session lifetimes, call authorization, group membership), including
  rollback and upgrade behaviour
- Android/iOS native push and native crypto packaging
- `THIRD_PARTY_NOTICES.md`, lockfiles, CI, and release scripts
- the OpenMLS 0.9.0 → 0.9.2 upgrade and the libcrux advisory exception (G27)

## Mandatory failure cases

Test credential substitution, wrong conversation/group, unknown payload
version, padding/framing corruption, replay, duplicate/out-of-order delivery,
offline epoch gaps, wrong local database key, state rollback, interrupted
atomic commit, attachment reorder/truncation/wrong key, backup rollback/wrong
key/process death, revoked-device reconnect, stale-epoch membership commits,
malicious push payloads, plaintext call metadata, and ABI ownership/panic
failures.

The server is untrusted for confidentiality. It necessarily observes account,
device, membership, conversation, timing, ciphertext sizes, call lifecycle,
push-provider token, and attachment/backup size metadata. Anonymous routing,
federation, post-quantum protection, and hidden metadata are not claimed.

## Reviewer reproduction

```sh
./scripts/lint.sh
./scripts/test.sh
./scripts/license-check.sh
./scripts/audit-rust.sh
./scripts/build-mobile-crypto.sh android
cd mobile && flutter analyze && flutter test && flutter build apk --release
```

On macOS, also run `./scripts/build-mobile-crypto.sh ios`, an unsigned release
build, and the approved signing workflow. The release workflow generates SBOM,
checksums, and provenance only after every gate passes.

## Signed-device matrix (G24)

Every row is pending until it is run on signed builds of one frozen candidate
commit. Record sanitized platform versions and artifact digests, never device
identifiers or signing material.

| Real-device flow | Android | iOS |
|---|---|---|
| Setup, invite, DM/group | Pending hardware | Pending hardware |
| Device link and SAS | Pending hardware | Pending hardware |
| Offline catch-up and restart | Pending hardware | Pending hardware |
| Attachment and backup restore | Pending hardware | Pending hardware |
| Revocation reconnect ordering | Pending hardware | Pending hardware |
| FCM/APNs background wake | Pending credentials/hardware | Pending credentials/hardware |
| TURN call under network changes | Pending TURN/hardware | Pending TURN/hardware |
| LAN TLS with a private CA (T48B) | Pending hardware | Pending hardware |
| TalkBack/VoiceOver/large text/reduced motion | Pending hardware | Pending hardware |

### Signed artifact evidence

The release needs exactly one `signed-release` record per platform
(`veritra-mobile-artifact/1`, decision D37), built from the candidate by a
workflow other than CI, staged with its file for `release.yml`, and attested
there with `gh attestation verify`. The debug builds hosted CI makes are
recorded and checked, but never count: iOS `simulator-debug` (job
`mobile-ios`) and Android `emulator-debug` (the demo APK, job `mobile`).

| Platform | Signed file | Structural checks in `check-release-evidence.py` |
|---|---|---|
| iOS | `.ipa` | One `Payload/*.app`, iphoneos plist whose `CFBundleIdentifier` is the pinned `ios.bundle_id`, arm64 iOS Mach-O with a code signature, distribution profile (`get-task-allow=false`) whose `TeamIdentifier` is exactly the pinned `ios.team_id` and whose `application-identifier` is `<team>.<bundle>` (and `com.apple.developer.team-identifier`, when present, the team). The same zip rules as Android: no comment, one end record, no ZIP64 or multi-disk records, no duplicate entry names |
| Android | `.apk` (not `.aab`) | `org.veritra.private_messenger` (the no-namespace `package` attribute, raw string equal to the typed one, as Android reads it), not debuggable, `minSdkVersion` 24 or later (older releases verify only v1), arm64 crypto library, an APK Signature Scheme v2 block (Android 7.0-8.1 never read v3) and any v3 blocks, each with exactly one signer whose certificate SHA-256 is the pinned `android.release_certificate_sha256` (the record's `signing.certificate_sha256` must name it too) and is not the Android debug certificate. Archives a lenient parser could read differently from Android are refused: a zip comment, a second end-of-central-directory signature, ZIP64 or multi-disk records, duplicate entry names, and a manifest with a second (or late) string pool or resource map, a `manifest` element that is not the single root, or two attributes of one name or resource ID in an element |

Both bind the platform, type, candidate commit, the file's sha256 and the
provenance (workflow, job, run, source commit). A signed file with the same
digest as a debug build blocks. The checks are structural; the signed build
runs `codesign --verify` or `apksigner verify`, and the attestation proves
which workflow and commit made the file. Signing-key rotation (several
certificates) is not accepted yet.

#### Pinning the Android release certificate

`release/release-policy.json` holds `"android": {"release_certificate_sha256": null}`.
While it is null, the checker refuses every Android `signed-release` record
("pin the release certificate first"), so the release stays blocked. The
owner pins the certificate of the key that signs the G24 release APK once,
before the candidate is frozen:

1. Read its SHA-256 from a signed APK with
   `apksigner verify --print-certs app-release.apk` ("Signer #1 certificate
   SHA-256 digest"), or from the keystore with
   `keytool -list -v -keystore release.jks -alias <alias>` (the `SHA256:`
   line, with the colons removed and the letters lower-cased).
2. Write it as 64 lowercase hex characters, for example
   `"release_certificate_sha256": "3f2a…"` (all 64), in a reviewed pull
   request to `main`. Anything else (upper case, colons, a `sha256:` prefix,
   extra keys) blocks every gate.
3. Freeze the candidate after that merge. The checker reads the policy from
   the candidate tree, so the pin is part of what the approvals review.

Changing the key means changing the pin the same way.

#### Pinning the iOS team and bundle IDs

`release/release-policy.json` also holds `"ios": {"team_id": null, "bundle_id": null}`.
While either is null, the checker refuses every iOS `signed-release` record
("pin first"). The owner sets both in the same reviewed pull request as the
Android pin, before the candidate is frozen:

- `team_id`: the 10-character Apple Developer Team ID (upper-case letters
  and digits), shown under Membership in the developer account, or as
  `TeamIdentifier` in the distribution profile
  (`security cms -D -i profile.mobileprovision`).
- `bundle_id`: the app's bundle ID, `PRODUCT_BUNDLE_IDENTIFIER` of the
  Runner target (`org.veritra.privateMessenger` in the Xcode project today),
  which must also be the profile's explicit App ID; wildcard profiles fail.

A real export has not been run through these checks yet. G24 must confirm on
its first signed `.ipa` that Xcode writes no zip comment or ZIP64 records.

## Recording an approval

An approval file cannot sit in the commit it approves: it would have to
contain that commit's own SHA. So the frozen candidate is merged to `main`
first, and each approval lands later, in its own pull request, at
`release/approvals/<candidate sha>/production-crypto.json` or
`independent-review.json`:

```json
{
  "schema": "veritra-release-approval/1",
  "approval": "independent_review",
  "status": "approved",
  "reviewed_commit": "<candidate sha>",
  "reviewed_tree": "<output of: git rev-parse CANDIDATE^{tree}>",
  "reviewer": "<name>",
  "reviewer_is_author": false
}
```

`production_crypto` also has `"behavior_test": "pass"`. No other keys are
allowed. The release tag points at the candidate. `release.yml` reads the
approvals from the tip of the default branch, never from the tag or a pull
request, and `scripts/check-release-evidence.py` blocks unless:

- that tip descends from the candidate;
- each approval names the candidate and its tree;
- each approval has a non-empty `reviewer` and `reviewer_is_author` exactly
  `false`, and the `reviewer` is not the candidate commit's git author (the
  whole field equal to its name, or its email as one word of the field, as
  in `Name <email>`; ignoring case, raw and after `.mailmap`);
- the change that put each approval on `main` (a merged pull request counts
  as one change) came after the candidate and touched nothing outside
  `release/approvals/<candidate sha>/`.

The reviewer checks are self-declared: `reviewer` is free text and git
author names and emails are whatever the committer configured. They catch an
author approving under their own recorded identity, not a false name; the
real control is who may merge to `main`.

Git is read with replace refs and grafts disabled (`GIT_NO_REPLACE_OBJECTS=1`,
`GIT_GRAFT_FILE` pointed at a path that cannot exist), so local history
rewrites cannot make an unrelated commit descend from the candidate.

The published release evidence records the approvals commit and the sha256
of each approval file.

## Findings log

Record each independent finding with its ID, severity, affected revision and
file, remediation revision, reviewer retest, and residual-risk decision.
Critical and high findings are fixed and independently retested; lower ones
need an explicit residual-risk acceptance. Only then are both fail-closed
gates changed, after G24 is rerun on the final reviewed commit.

| ID | Severity | Revision / file | Remediation | Retest | Decision |
|---|---|---|---|---|---|
| — | — | — | — | — | No reviewer assigned yet |
