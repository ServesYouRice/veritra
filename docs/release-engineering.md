# Release engineering (W12 and build-plan item 7)

Everything here needs no account and no key. Nothing is signed or published.
What is measured and what is only drafted is in
[`testing/evidence/W12-release-engineering.md`](../testing/evidence/W12-release-engineering.md).
The release gates (G24, G25, G27, `scripts/release-readiness.sh`) are untouched:
these scripts make builds, they do not release anything.

## Reproducible builds

| Target | Build once | Build twice and compare | Runs on |
|---|---|---|---|
| Rust crypto library (Linux) | `scripts/repro/build.sh crypto-linux OUT` | `scripts/repro/verify.sh crypto-linux` | Linux |
| Linux desktop | `scripts/repro/build.sh linux OUT` | `scripts/repro/verify.sh linux` | Linux |
| Android APK (unsigned) | `scripts/repro/build.sh android OUT` | `scripts/repro/verify.sh android` | Linux, JDK 17, Android SDK + NDK |
| macOS app (unsigned) | `scripts/repro/build.sh macos OUT` | `scripts/repro/verify.sh macos` | a Mac |
| Windows app (unsigned) | `scripts\repro\build.ps1 -OutDir OUT` | `scripts\repro\verify.ps1` | Windows, VS 2022 Build Tools |

`verify` builds from two clean copies of the **committed** HEAD in two different
directories, so build paths, leftover files and uncommitted edits cannot hide a
difference. It exits 0 only if every file digest matches.

What the scripts pin (`scripts/repro/env.sh`, `build.ps1`):

- **Clock:** `SOURCE_DATE_EPOCH` = the commit's time. Never "now".
- **Toolchains:** Rust from `rust-toolchain.toml`, Flutter from `pubspec.yaml`
  (`3.44.0`), JDK 17, Gradle from the wrapper (9.1.0). A wrong Rust, Flutter or
  JDK version stops the build. Rust and Dart dependencies come from lockfiles
  (`cargo --locked`, `flutter pub get --enforce-lockfile`). Gradle/Maven
  dependencies are **not** locked and the Gradle wrapper has no checksum yet:
  both are open for the first real Android build.
- **Clean input:** `build.sh` refuses a dirty checkout and a non-empty output
  folder, and for Android accepts exactly one release APK.
- **Paths:** `--remap-path-prefix` for the checkout, cargo and rustc; fixed
  `TZ`, `LC_ALL`; no incremental builds; no build-id (Linux), `/Brepro` (Windows).
- **Release entry point only:** `lib/main.dart`. The demo entry point is never
  built by these scripts.

Known gaps (see the evidence file for what was measured):

- A reproducible build is only as stable as the toolchain it pins. The Android
  Gradle-side NDK is pinned by Flutter 3.44.0, but the Rust library uses
  `ANDROID_NDK_HOME` or else the newest installed NDK, and the SDK build-tools
  version is whatever is installed. Set all three explicitly. For the
  first real build, record it and pin it in the owner's build image.
- Signing changes the file. The signature is added **after** `verify`, to the
  digest-checked unsigned file. F-Droid compares the unsigned content; the
  update channel (below) checks the signed installer's digest.
- Measured so far: one host, two directories. F-Droid's check needs the same
  result on a different host; that is not shown.
- The server container image is out of scope here; its determinism is not
  measured by these scripts.

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
