# Release approvals, Android signed-release evidence, I31 native outbox

Date: 2026-10-23. Base: `138891c`. Python 3, standard library only. G24 and
G25 stay pending; release readiness stays blocked.

## Release approvals

An approval file cannot name the SHA of the commit that contains it, so the
old rule (`reviewed_commit` = candidate, file in the candidate) could never
pass. Policy and manifest move to schema 3.

- Approvals live at `release/approvals/<candidate>/production-crypto.json`
  and `independent-review.json` (`veritra-release-approval/1`, exact keys,
  including `reviewed_tree` = the candidate's git tree).
- `release.yml` fetches the default branch, resolves its tip once (the
  approvals commit) and passes it to every gate. It never reads the tag or a
  pull request ref.
- The checker reads each approval from git at that commit and blocks unless
  the commit descends from the candidate and is not the candidate.
- The change that landed each approval (first-parent, so a merged pull
  request is one change) must come after the candidate and touch nothing
  outside `release/approvals/<candidate>/`.
- Git is read with `--no-replace-objects`.
- The manifest records the approvals commit and each file's path, sha256 and
  record; the final gate compares them with git exactly.

Fixtures (`check-release-evidence_test.py`) build a real git repository:

- **Accepted:** the approval commit, later unrelated work, a merged pull
  request, approvals in two separate changes, and the preflight alone.
- **No usable approvals commit:** missing, malformed, unknown, the candidate
  itself, or a sibling line.
- **Not on the protected tip:** a pull request head, including a replace ref
  that points the tip at it.
- **Wrong approval:** another commit's approval or path, wrong tree, swapped
  approval kinds, each content field, extra or missing keys, invalid JSON,
  too large.
- **Wrong landing:** smuggled in a code change, a merged PR with code, a
  later edit with code, landed before the candidate.
- **Manifest and policy:** manifest tampering, a schema 2 manifest, policy
  tampering.

## Android signed release

Mirrors D37. The policy requires exactly one `android` `signed-release`
record next to the iOS one; `debug_ci_jobs` replaces `simulator_ci_jobs`.
The `mobile` job's demo APK is recorded as `emulator-debug` and uploaded next
to the APK; it is checked, never counted.

A signed record names an `.apk` (not `.aab`). Its bytes must match the
digest and, structurally:

- be `org.veritra.private_messenger`;
- not be debuggable (anything but a literal false counts as debuggable);
- ship `lib/arm64-v8a/libprivate_messenger_crypto.so`;
- carry an APK Signature Scheme v2/v3 block, right before the central
  directory, with exactly one signer whose leaf certificate SHA-256 equals
  `signing.certificate_sha256` and is not the Android debug certificate.

Provenance must not be `ci.yml`, job `mobile` or the CI run. `release.yml`
runs `gh attestation verify` on it as on the `.ipa`.

Fixtures cover:

- **Accepted:** v2+v3, v2 only, v3 only, an explicit `debuggable=false`, and
  an emulator record alongside.
- **Debug builds:** emulator-only, an emulator record relabelled, debug bytes
  behind a perfect record, the debug key, debuggable (also as a reference
  or an int), and a digest equal to a debug build.
- **Unsigned:** no block, v1 only, a block without v2/v3, or an unsigned
  status.
- **Certificate:** a mismatched fingerprint (one or both schemes), two
  signers or none, a malformed fingerprint, malformed blocks, an empty
  certificate, a shifted central directory.
- **Wrong file:** another app, no crypto library, no dex, a text manifest, a
  truncated manifest, not a zip, an `.ipa` renamed.
- **Record:** file name, digest, commit, build and type binding, provenance,
  bad emulator records, and the `mobile` job skipped.

Not validated on a real APK: there is no Android SDK here, and f-droid.org
and dl.google.com are blocked by the sandbox egress policy. G24 must run the
checker on its first signed APK and compare with `apksigner verify
--print-certs`.

Mutation check: 16 single mutations of the approval code, 24 of the Android
code and 1 of the replace-ref guard. Each one made the suite fail.

## I31: MLS payloads from the outbox through the native library

`mobile/test/native_outbox_test.dart`. Both tests passed 3/3 in repeated
runs.

1. AppState on NativeCryptoService.
   - Its MLS outbox posts the commit bundle.
   - Its outbox posts text, reply, edit, reaction and delete with the real
     `ApiClient` over HTTP to a loopback stand-in server.
   - A second native member joins from the Welcome and decrypts the exact
     bytes the server got.
   - The server sees ciphertext only and one metadata shape.
2. The MLS-payload enqueue path at the bound.
   - With 99 queued, the 100th reaction is encrypted once.
   - The 101st is refused before `encryptPayload` and the MLS state does not
     move. Removing AppState's capacity check makes this fail.

It skips only when `VERITRA_CRYPTO_LIBRARY` is unset outside CI. With
`CI=true` it fails instead. CI's `mobile` job already sets the library.

## Results

| Check | Result |
|---|---|
| `check-release-evidence_test.py`, `write-release-evidence_test.py`, `check-ci-evidence_test.py`, `check-dart-retractions_test.py`, `check-coverage_test.py` | pass |
| `./scripts/release-readiness.sh` | blocked as expected (no approvals commit after the candidate) |
| `flutter test` native outbox (+ `native_crypto_service`, `mls_outbox`, `outbox_delivery`) with the Linux library | pass |
| `flutter analyze`, `dart format --set-exit-if-changed .` | pass |

`flutter pub get --enforce-lockfile` fails on `main` at `138891c`. The
dependabot bump to `intl 0.20.3` conflicts with Flutter 3.44.0, which pins
`intl 0.20.2` through `flutter_localizations` (D30). The Flutter checks above
ran with that bump reverted locally; the revert is not committed.
