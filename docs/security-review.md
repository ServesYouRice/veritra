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
  dedupe marker, and sync cursor commit atomically. Local schema v8.
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
| iOS | `.ipa` | One `Payload/*.app`, iphoneos plist, arm64 iOS Mach-O with a code signature, distribution profile (`get-task-allow=false`) |
| Android | `.apk` (not `.aab`) | `org.veritra.private_messenger`, not debuggable, arm64 crypto library, an APK Signature Scheme v2/v3 block with exactly one signer whose certificate SHA-256 equals the record's `signing.certificate_sha256` and is not the Android debug certificate |

Both bind the platform, type, candidate commit, the file's sha256 and the
provenance (workflow, job, run, source commit). A signed file with the same
digest as a debug build blocks. The checks are structural; the signed build
runs `codesign --verify` or `apksigner verify`, and the attestation proves
which workflow and commit made the file. Signing-key rotation (several
certificates) is not accepted yet.

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
- the change that put each approval on `main` (a merged pull request counts
  as one change) came after the candidate and touched nothing outside
  `release/approvals/<candidate sha>/`.

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
