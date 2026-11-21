# Release engineering (W12 and build-plan item 7)

Everything here needs no account and no key. Nothing is signed or published.
What is measured and what is only drafted is in
[`testing/evidence/W12-release-engineering.md`](../testing/evidence/W12-release-engineering.md).
These scripts make builds; they do not release anything. The release gates
(G24, G25, G27, `scripts/release-readiness.sh`) stay in force; the one rule
here that is part of them is the crypto build record check below (D134).

## Release candidate procedure

One command, nothing secret, nothing published:

```sh
python3 scripts/release-rc.py --dry-run          # about 2 minutes (gate fixture tests included)
python3 scripts/release-rc.py --dry-run --quick  # seconds: skips the slow and network checks
python3 scripts/release-rc.py                    # the real check: exit 0 only if the gate passes
```

It prints three parts:

1. **Checks that need no secrets**, each `PASS`, `FAIL` or `SKIP` with its
   reason: toolchain alignment, the G27 advisory deadline, the demo boundary,
   pinned Gradle inputs and lock wiring, third-party notices, the Dart
   dependency policy, the Windows installer dry run (PowerShell only), and the
   fixture tests of the release gates (they prove the gates still refuse).
2. **What only the owner can supply**, each `MISSING`, `DONE` or `OWNER`
   (cannot be checked from the repository): the three signing pins, the Gradle
   lock files, the G24 matrix, the G25 and production-crypto approvals, the
   production crypto switch, signed release records, the update key, and the
   Apple, Android, Windows, push and TURN accounts. It also prints the days
   left on the G27 exceptions.
3. **`scripts/release-readiness.sh`**, unchanged, with its own output and exit
   status. That script stops at its first refusal, so the list in part 2 is
   what it would still ask for after it.

Exit status, the same with or without `--dry-run`: `1` when a check fails;
`3` when the checks pass and the release is blocked (the gate refuses, an owner
item is `MISSING`, or `--quick` skipped checks); `0` only when
`release-readiness.sh` itself exits 0, nothing is `MISSING` and nothing was
skipped by `--quick`. A blocked dry run therefore exits 3, never 0, so no
caller can read it as a release. Nothing this script prints turns a refusal of
the gate into a pass: `scripts/release-rc_test.py` fails if a refusing gate
ever yields exit 0 or the word `PASSED`. The G24 item is `DONE` only for a
`testing/evidence/G24-matrix.json` of this candidate commit with every row of
`scripts/g24-matrix.py` a recorded pass and two devices per platform (the rule
of `g24-matrix.py status`).

Full candidate order, once the owner items exist: pin the signing certificates
in a reviewed pull request; run `scripts/gradle-lock.sh write` and commit its
output; freeze the candidate commit; run `repro.yml`; build and sign on the
owner's machines; record the G24 matrix (`docs/g24-device-matrix.md`); write the
approvals (`docs/security-review.md`); tag; `release.yml` runs the gate.

## Reproducible builds

| Target | Build once | Build twice and compare | Runs on |
|---|---|---|---|
| Rust crypto library (Linux) | `scripts/repro/build.sh crypto-linux OUT` | `scripts/repro/verify.sh crypto-linux` | Linux (local) |
| Linux desktop | `scripts/repro/build.sh linux OUT` | `scripts/repro/verify.sh linux` | Linux (local) |
| Android APK (unsigned) | `scripts/repro/build.sh android OUT` | `scripts/repro/verify.sh android` | Linux, JDK 17, Android SDK + NDK 28.2.13676358 |
| macOS app (unsigned) | `scripts/repro/build.sh macos OUT` | `scripts/repro/verify.sh macos` | a Mac |
| Windows app (unsigned) | `scripts\repro\build.ps1 -OutDir OUT` | `scripts\repro\verify.ps1` | Windows, VS 2022 Build Tools |
| iOS | not reproducible by design | | Apple's signing and export add data; the signed `.ipa` is attested instead (`release.yml`) |

`verify` builds from two clean copies of the **committed** HEAD in two different
directories, so build paths, leftover files and uncommitted edits cannot hide a
difference. It exits 0 only if every file digest matches.

**Other hosts (CI).** Linux runs locally (D118). Android, Windows and macOS run
in `.github/workflows/repro.yml`, started by hand (Actions, "Reproducible
builds", Run workflow). It needs no secret and signs nothing:

- `android` builds on two runner images (Ubuntu 22.04 and 24.04); `android-compare`
  then runs `scripts/repro/compare.sh` on their digests, which is the closest CI
  gets to "a different host".
- `windows` and `macos` build twice each and upload their `SHA256SUMS` and
  `TOOLCHAIN.txt`.
- `windows-installer` builds the app and the **unsigned** installer, which proves
  `release/windows/veritra.iss` compiles.

To compare with the owner's own machine (what F-Droid does): run
`REPRO_KEEP=/some/dir scripts/repro/verify.sh android` there, download the CI
artifact, then `scripts/repro/compare.sh /some/dir/SHA256SUMS ci/keep/SHA256SUMS`.
It prints every file that differs, is missing or is extra, and exits 0 only if
there are none. `TOOLCHAIN.txt` (versions only, no paths) beside the digests
records the Rust, Flutter, JDK, NDK and build-tools versions that were used.

The workflow has not run yet: it was written without a hosted runner, so its
first run is the first evidence for these targets. `scripts/repro_test.py`
tests the guards below with fake tools (a wrong toolchain, a missing or wrong
NDK, a dirty checkout, differing digests), and that the workflow stays manual,
secret-free and pinned to the action SHAs CI already uses.

What the scripts pin (`scripts/repro/env.sh`, `build.ps1`):

- **Clock:** `SOURCE_DATE_EPOCH` = the commit's time. Never "now".
- **Toolchains:** Rust from `rust-toolchain.toml`, Flutter from `pubspec.yaml`
  (`3.44.0`), JDK 17, the Android NDK `28.2.13676358` (what Flutter 3.44.0's
  Gradle plugin uses; `ANDROID_NDK_HOME` must name it, the newest installed NDK
  is refused), Gradle from the wrapper (9.1.0, with its `distributionSha256Sum`).
  A wrong Rust, Flutter, JDK or NDK version stops the build. Rust and Dart
  dependencies come from lockfiles (`cargo --locked`,
  `flutter pub get --enforce-lockfile`). Gradle/Maven dependencies are locked
  by the next section once the lock files are generated.
- **Clean input:** `build.sh` refuses a dirty checkout and a non-empty output
  folder, and for Android accepts exactly one release APK.
- **Paths:** `--remap-path-prefix` for the checkout, cargo and rustc; fixed
  `TZ`, `LC_ALL`; no incremental builds; no build-id (Linux), `/Brepro` (Windows).
- **Release entry point only:** `lib/main.dart`. The demo entry point is never
  built by these scripts.

Known gaps (see the evidence file for what was measured):

- The Linux bundle is not reproducible yet (12 of 30 files differ: `libapp.so`
  and the C++ plugin libraries). Not investigated further here; the cause is a
  guess until one plugin is diffed.
- The SDK build-tools version is whatever is installed. `TOOLCHAIN.txt` records
  it; pin it in the owner's build image after the first real build.
- Signing changes the file. The signature is added **after** `verify`, to the
  digest-checked unsigned file. F-Droid compares the unsigned content; the
  update channel (below) checks the signed installer's digest.
- Measured so far: one host, two directories, Linux targets only. The cross-host
  check above is built, not yet run.
- The server container image is out of scope here; its determinism is not
  measured by these scripts.

## Gradle dependency locking

`mobile/android/build.gradle.kts` turns on Gradle's dependency locking for every
project (`lockAllConfigurations()`), each lockfile kept in
`mobile/android/gradle/locks/` (the Flutter plugin projects live in the pub cache,
where Gradle's default location would never be committed). It runs in Gradle's
default lock mode: a configuration with a lockfile must resolve exactly to it,
and one without resolves as before, so the wiring is inert until the files exist.

The files can only be written where Gradle can configure the real Android build
(JDK 17, Android SDK, Flutter), which this repository's authoring sessions do not
have, so they are not committed yet:

```sh
scripts/gradle-lock.sh write     # on a host with the SDK; commit mobile/android/gradle/
scripts/gradle-lock.sh check     # validate what is committed (release candidate)
```

`write` produces two things: `gradle/locks/*.lockfile` (the version of every
resolved dependency) and `gradle/verification-metadata.xml` (the sha256 of every
artifact). Both are needed: lockfiles do not cover the plugins in
`settings.gradle.kts`, the verification metadata does. Regenerate and review the
diff whenever `pubspec.lock`, a plugin version or a Gradle dependency changes;
until then a changed resolution fails the build, which is the point.

`scripts/check-gradle-locks.py` (run by `scripts/check-mobile-dependencies.sh`
and CI) fails when the wiring is removed or weakened (`LockMode.LENIENT`) or a
committed file is malformed (a dynamic version, md5/sha1-only or a catch-all
trusted artifact); `--require-files`, used by the release candidate check,
also fails while the files are missing.

## Crypto build record (D134)

The crypto build scripts write `build-info.txt` next to the library:
`source_revision` (the commit), `cargo_lock_sha256`, `source_tree_dirty` and
`rustc -Vv`. `source_tree_dirty=true` means `crypto/rust` had uncommitted or
untracked files, so the library is not exactly that commit. Release packaging
refuses such a library, and also a record that is missing or does not say
`source_tree_dirty=false` exactly once.

| Platform | Where it is refused | Checked here (Linux) |
|---|---|---|
| Android | `check-release-evidence.py`: the signed APK must carry `assets/veritra-crypto/build-info.txt` | yes, synthetic APKs |
| iOS | The Runner's "Crypto Build Record" build phase (`scripts/ios-crypto-build-record.sh`) refuses every configuration except Debug and Profile, and copies the record into the app as `veritra-crypto/build-info.txt`. `check-release-evidence.py` then requires that record in the signed `.ipa` | the script and the `.ipa` check, yes; that Xcode runs the phase and the record lands in a real signed `.ipa`, only on a Mac (CI `mobile-ios`, G24) |
| Windows | `build-windows-installer.ps1` (not with `-DryRun`) | only where PowerShell runs |
| Linux, macOS | Not gated: there is no release packaging for them yet. The record is written; a future package step must refuse it the same way | n/a |

Both the iOS phase and the evidence check use one function,
`crypto_build_info_error` in `check-release-evidence.py` (the phase calls it
with `--crypto-build-info`), so it needs `python3` on the Mac, as
`build-mobile-crypto.sh` already does. Debug and Profile builds copy whatever
record there is and never refuse; the signed `.ipa` check still catches one
that ships.

**The record must be the release commit's crypto.** For the signed APK and the
signed `.ipa`, `check-release-evidence.py` also requires, in the record:

- exactly one `source_revision` (a full commit SHA) that is in the repository
  the gate runs in (an unknown commit, a short or malformed one, or two lines
  refuse);
- that the `crypto/rust` tree at that commit is the `crypto/rust` tree at the
  release commit (`git rev-parse <recorded>:crypto/rust` equals
  `<release>:crypto/rust`, replace refs and grafts ignored). The commits may
  differ, for example a docs-only commit after the build; the crate sources,
  `Cargo.toml` and `Cargo.lock` may not;
- exactly one `cargo_lock_sha256`, equal to the SHA-256 of the release
  commit's committed `crypto/rust/Cargo.lock`.

`scripts/check-release-evidence_test.py` (`crypto_source_cases`) fails if this
guard is removed. Not covered: the Xcode phase (`--crypto-build-info`) checks
only the dirty flag, because it has no release commit to compare with (the
signed `.ipa` check does it); the Windows installer, which checks only the
dirty flag (`build-windows-installer.ps1`); and the Rust toolchain, which is
recorded (`rustc -Vv`) but not compared with `rust-toolchain.toml` at the
repository root.

## Windows installer

`release/windows/veritra.iss` is an Inno Setup 6 definition: per-user install by
default (the dialog can switch to all users), fixed `AppId` so an update replaces
the old install in place, Windows 10 or newer, Start-menu entry, optional desktop
shortcut, uninstaller, the app icon, and `CloseApplications` so a running Veritra
is closed first. It packages the folder `build.ps1` produced.
`scripts/build-windows-installer.ps1` builds it, refuses a crypto library built
from uncommitted sources (D134) and writes `SHA256SUMS`:

```powershell
.\scripts\build-windows-installer.ps1 -BuildApp                  # build the app, then an unsigned installer
.\scripts\build-windows-installer.ps1 -AppDir C:\out\app -OutDir C:\out\dist
.\scripts\build-windows-installer.ps1 -DryRun                    # print the iscc command, build nothing
```

CI builds the unsigned installer (`repro.yml`, job `windows-installer`), which
proves the definition compiles. Nothing in the repository holds a certificate.

**Owner step 1, signing.** After buying a code-signing certificate:
```powershell
.\scripts\build-windows-installer.ps1 -SignToolCommand 'signtool.exe sign /fd sha256 /tr <timestamp-url> /td sha256 /f <cert> /p <password> $f'
```
The certificate and password stay outside the repository; a hardware token or a
cloud signing service needs a different `signtool` line, which is the only thing
to change. Without it SmartScreen warns on first run. Inno Setup's license (free,
custom terms) is for the owner to check before first use; an MSIX alternative
needs a Microsoft account or a self-managed certificate.

## Update channel

Goal: an installed Windows app learns that a newer, genuine build exists, without
a vendor service and without telemetry. Android has no channel (F-Droid and Play
update themselves); Linux and macOS have none yet.

What is built (`mobile/lib/desktop/update_service.dart`, `update_installer.dart`,
`update_verifier.dart`, `update_trust.dart`; tests in
`mobile/test/update_service_test.dart`, `update_verifier_test.dart`,
`update_feed_native_test.dart`):

1. **Feed:** `update.json` plus a detached Ed25519 signature `update.json.sig`
   (64 raw bytes over `veritra-update-feed-v1` followed by the exact bytes), published as release assets at
   `updateFeedUrl`. Fields: `version`, `build`, `platform`, `arch`, `issued_at`,
   `expires_at`, `url`, `sha256`, `notes`. The owner makes both with
   `scripts/update-feed.py sign` after the installer is signed; the tool refuses
   a non-https URL, a feed valid for more than 90 days and a signature that does
   not verify. `scripts/update-feed.py keygen` makes the update key.
2. **Trust:** the **update key**, separate from the code-signing certificate;
   its public half is `updateFeedPublicKeyHex` in `update_trust.dart`. The
   signature is checked in the native library (`pm_crypto_update_feed_verify`,
   crypto ABI 27, strict Ed25519 over `veritra-update-feed-v1` followed by the
   feed bytes; `docs/crypto.md`, "Update feed signature") by
   `Ed25519UpdateSignatureVerifier`, which is used only while the key is 64
   lowercase hex characters; with the key empty the build keeps
   `FailClosedUpdateSignatureVerifier` and requests nothing. The app rejects a
   bad or missing signature, a digest mismatch, another platform or arch, a
   lower `build` (downgrade) and an expired feed (so a mirror cannot serve an
   old, validly signed file for ever).
3. **Check:** one HTTPS `GET` of the file and one of its `.sig`, with no
   cookies or credentials; redirects (GitHub serves assets from another host)
   are followed by hand, at most five, only to https, so a redirect to plain
   http is refused before it is requested. It still shows the user's IP
   address to the host (GitHub). **Owner decision (2026-11-21):** on by
   default, once at each launch, with an off switch in Settings; it starts
   only once the update key is set (fail closed until then).
4. **Install:** the Settings tile offers each step as a tap: check, then
   "Download update" (the installer, https only with redirects checked, at most
   512 MiB, a file name the app chooses, SHA-256 compared with the signed feed;
   a mismatch deletes it), then "Restart to update". Before it starts, the file
   is hashed again, so one swapped in the temporary folder before that check
   never runs; a second tap starts nothing. The hash is Windows' `certutil` by
   absolute path (`%SystemRoot%\System32\certutil.exe`), never one found on the
   search path. The installer runs `/SILENT /NORESTART /CLOSEAPPLICATIONS`,
   detached, and the app quits through the tray's Quit. Never silently, never
   without the user's tap.

   **Per-user installs only.** Between the second hash and the start there is
   a short window in which a program running as the same user could replace
   the file in that user's temporary folder. For a per-user install (Inno
   Setup's default, under `%LOCALAPPDATA%`) such a program could already
   change the installed app, so nothing is gained. An all-users install would
   start the installer through a UAC prompt as administrator, which that
   program could not otherwise reach, so there the app only reports the
   update ("Version x is available") and the user installs the signed
   installer from the release page (`isPerUserWindowsInstall`, tested).
5. **Never:** server-pushed updates, forced updates, or an update that changes
   the crypto or the server address without showing it.
6. **Messaging gate:** until G24/G25 pass there is no public release, so no
   channel is switched on. A channel never delivers a build that
   `scripts/release-readiness.sh` rejects.

**What is still missing before the channel can be switched on:**

1. **The update key:** `scripts/update-feed.py keygen --out update-key.pem`, kept
   offline and backed up by the owner; its public half goes into
   `updateFeedPublicKeyHex` in `update_trust.dart` in a reviewed pull request.
   That one change turns the channel on (checks are on by default). Open: who
   holds it and how it is backed up (a rotation would need a second key in the
   app). The key file `keygen` writes is not passphrase-protected; keep it on
   offline, encrypted storage.
2. **The signing certificate** (above), and a first real run on Windows: none
   of the installer, download, certutil or launch code has run on a Windows
   machine.
3. **The independent review (G25)** of `pm_crypto_update_feed_verify` with the
   rest of the crypto ABI, as for every ABI change.

Earlier, the app had no Ed25519 check and shipped a verifier that accepts
nothing; it still does while the key is empty, and `update_service_test.dart`
fails if that guard is removed. An earlier placeholder that returned true for
any non-empty signature is gone.

## F-Droid

`release/fdroid/org.veritra.private_messenger.yml` is a draft recipe in
`fdroiddata` format; nothing is submitted. Blockers, in order:

1. **Firebase.** Resolved: the Android app has `play` and `fdroid` product
   flavors (`distribution` dimension). The `fdroid` flavor excludes
   `firebase-messaging` completely and uses UnifiedPush only, while `play`
   retains FCM with UnifiedPush fallback, following the owner's F-Droid decision.
2. **Messaging is off in release builds** until G24/G25.
3. **Signing key.** Reproducible-build verification (F-Droid builds and compares
   with the developer's signed APK) needs the owner's APK signing key.
4. First real run: the NDK, the APK file name and the Rust bootstrap in the
   recipe are written from the code, not tested.
