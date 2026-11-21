# Release engineering (W12 and build-plan item 7)

Everything here needs no account and no key. Nothing is signed or published.
What is measured and what is only drafted is in
[`testing/evidence/W12-release-engineering.md`](../testing/evidence/W12-release-engineering.md).
The release gates (G24, G25, G27, `scripts/release-readiness.sh`) are untouched:
these scripts make builds, they do not release anything.

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

Exit status: `1` when a check fails (also in `--dry-run`); `3` when the checks
pass and the release is blocked; `0` only when `release-readiness.sh` itself
exits 0 and nothing is `MISSING`. With `--dry-run` a blocked release also exits
0, and the last line still says `RELEASE BLOCKED`. Nothing this script prints
turns a refusal of the gate into a pass: `scripts/release-rc_test.py` fails if
a refusing gate ever yields exit 0 or the word `PASSED`.

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

## Windows installer

`release/windows/veritra.iss` is an Inno Setup 6 definition: per-user install by
default, fixed `AppId` so updates replace the old install, Start-menu entry,
optional desktop shortcut, uninstaller. It packages the folder
`build.ps1` produced.

Build with `scripts\build-windows-installer.ps1` (or `release\windows\build.ps1`):
```powershell
# Build unsigned installer (default)
.\scripts\build-windows-installer.ps1

# Specify build inputs and outputs
.\scripts\build-windows-installer.ps1 -AppDir C:\out\app -AppVersion 0.1.0 -OutDir C:\out\dist

# Dry-run check (no iscc needed)
.\scripts\build-windows-installer.ps1 -DryRun
```

**Owner step (signing placeholder):** signing. After the owner buys a code-signing
certificate, pass `-SignToolCommand` to the build script:
```powershell
.\scripts\build-windows-installer.ps1 -SignToolCommand 'signtool.exe sign /fd sha256 /tr <timestamp-url> /td sha256 /f <cert> /p <password> $f'
```
The certificate and password stay outside this repository. Without signing, Windows
SmartScreen warns on first run; that is expected for the unsigned draft.

Open questions for the owner: Inno Setup's license (free, custom terms) is
checked by the owner before first use; an MSIX alternative would need a
Microsoft account or a self-managed certificate.

## Update channel (design note, nothing built)

Goal: a user's installed desktop app learns that a newer, genuine build exists,
without a vendor service and without telemetry.

1. **Where:** a static `update.json` on the GitHub release (or the user's own
   server), plus a **detached** signature file `update.json.sig` over the exact
   bytes. Fields: `version`, `build`, `platform`, `arch`, `issued_at`,
   `expires_at`, `url`, `sha256`, `notes`.
2. **Trust:** signed with an **update key**, separate from the Windows
   code-signing certificate; its public key is compiled into the app. Rejected:
   a bad signature, a digest mismatch, a different platform or arch, a lower
   `build` (downgrade), and a file past `expires_at` (stops a mirror serving an
   old but validly signed file forever).
3. **Check:** one HTTPS `GET` of the file with no identifiers or cookies. It
   still shows the user's IP address and the app's User-Agent to the host
   (GitHub). **Owner decision:** on by default (daily, with an off switch), or
   off until the user opts in. Opt-in is the more private choice; default-on
   updates more users.
4. **Install:** the app downloads the installer, checks the digest, shows
   "Version X is ready, restart to update", and starts the signed installer in
   silent mode. Never silently, never without the user's click.
5. **Never:** server-pushed updates, forced updates, or an update that changes
   the crypto or the server address without showing it.
6. **Messaging gate:** until G24/G25 pass there is no public release, so no
   channel is switched on. A channel never delivers a build that
   `scripts/release-readiness.sh` rejects.
7. **Android and F-Droid:** F-Droid and Play update themselves; the app has no
   update check on Android.

Needs an owner decision (a key, so not mine): who holds the update signing key
and how it is backed up (rotation would need a second key in the app).

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
