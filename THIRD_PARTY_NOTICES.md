# Third Party Notices

This project is licensed AGPL-3.0-or-later. Dependency licenses must be compatible with that license and tracked here before release.

## Direct Runtime Dependencies

| Component | Use | License | Notes |
| --- | --- | --- | --- |
| `modernc.org/sqlite` | Pure-Go SQLite driver | BSD-style / compatible notices required | Chosen to support single-binary builds without CGO. Verify exact transitive notices during release. |
| `golang.org/x/crypto` | Password hashing helpers | BSD-3-Clause | Used for password fallback hashing. |
| `github.com/SherClockHolmes/webpush-go` | RFC 8291 Web Push encryption and VAPID | MIT | Server-side optional generic wake delivery; pinned in `server/go.mod`. |
| `org.unifiedpush.android:connector` 3.3.3 | Android push distributor registration and RFC 8291 decryption | Apache-2.0 | Official connector; receives only a fixed generic wake event. |
| `com.google.firebase:firebase-messaging` 25.0.1 | Native Android FCM wake delivery | Apache-2.0 | Exact dependency; data is restricted to a fixed generic wake. Firebase/Google service terms apply when enabled. |
| `flutter_webrtc` 1.6.2+hotfix.3 | Native Android/iOS WebRTC audio/video and DTLS-SRTP media | MIT | Exact Flutter dependency from the verified flutter-webrtc.org publisher; bundles platform WebRTC components whose notices are included by release packaging. |
| `com.google.crypto.tink:tink-android` 1.21.0 | Android keystore-backed Web Push key handling | Apache-2.0 | Forced to one Android artifact to avoid duplicate classes across secure storage and UnifiedPush. |
| `flutter_secure_storage` | Platform secure storage for mobile sessions | BSD-3-Clause | Direct Flutter dependency; platform packages are pulled transitively by `flutter pub get`. |
| `drift` 2.34.4 | Typed transactional mobile persistence and schema migrations | MIT | Direct Flutter dependency; used only over the encrypted SQLite3MC connection. |
| `sqlite3` 3.5.2 | Native SQLite bindings and verified build-hook artifacts | MIT | Configured with the `sqlite3mc` hook; system SQLite fallback is not used. |
| SQLite3 Multiple Ciphers | ChaCha20-Poly1305 encryption for the mobile database | MIT | Bundled through `sqlite3` 3.5.2 build hooks; the cipher is selected and verified explicitly before schema access. |
| `path_provider` 2.1.6 | Private application-support database location | BSD-3-Clause | Direct Flutter dependency maintained by flutter.dev. |
| `ffi` 2.2.0 | Dart bindings for the reviewed native MLS ABI | BSD-3-Clause | Direct Flutter dependency pinned in `mobile/pubspec.lock`. |
| `qr_flutter` 4.1.0 | Device-link QR rendering | BSD-3-Clause | Direct Flutter dependency pinned in `mobile/pubspec.lock`. |
| `mobile_scanner` 7.4.2 | Device-link QR scanning | BSD-3-Clause | Direct Flutter dependency. Android uses ML Kit, iOS uses the system Vision framework, and web uses ZXing; include their applicable notices/terms in release review. |
| `web` 1.1.1 | Browser API bindings used by `mobile_scanner` | BSD-3-Clause | Transitive Flutter dependency pinned in `mobile/pubspec.lock`. |
| `file_selector` 1.1.0 | Picking a file to send as an encrypted attachment, and choosing where to save one on desktop | BSD-3-Clause | Direct Flutter dependency maintained by flutter.dev; its platform packages (`file_selector_android`, `_ios`, `_linux`, `_macos`, `_windows`, `_web`, `_platform_interface`) and `cross_file` 0.3.5+5 come with it. The file is encrypted on the device before upload. |
| `desktop_drop` 0.8.4 | Dropping files onto the chat window on desktop to attach them | Apache-2.0 | Direct Flutter dependency, exact version (0.9.x needs Flutter 3.47). Desktop only; the dropped files are encrypted on the device before upload. Brings `cross_file` and `universal_platform` 1.1.0 (MIT). |
| `pasteboard` 0.6.0 | Pasting images and files from the system clipboard into the composer | Apache-2.0 | Direct Flutter dependency, exact version. Reads the clipboard only on an explicit paste. Brings `dbus` 0.7.15 (MPL-2.0, Linux only; file-level copyleft, no source changes made, compatible with AGPL-3.0-or-later), `uuid` 4.6.0 (MIT) and `xml` 7.0.1 / `petitparser` 7.0.2 (MIT) as transitive dependencies pinned in `mobile/pubspec.lock`. |
| `open_filex` 5.0.0 | Opening a decrypted non-image attachment in another app on phones | BSD-3-Clause | Direct Flutter dependency, exact version. The file is decrypted to a temporary file in the app cache and deleted afterwards and at startup. |
| `http` 1.6.0 | HTTP client pulled in by the `file_selector` packages | BSD-3-Clause | Transitive Flutter dependency pinned in `mobile/pubspec.lock`; the app does not use it. |
| `tray_manager` 0.5.3 | Desktop tray icon and menu (Open, Quit) so the app keeps syncing with the window closed | MIT | Direct Flutter dependency, exact version; 0.6 and later need Flutter 3.47. Brings `menu_base` 0.1.1 (MIT) and `shortid` 0.1.2 (BSD-3-Clause). Linux needs `libayatana-appindicator3` at run time. No network use. |
| `window_manager` 0.5.2 | Hide-to-tray on close, show/focus, and window focus state on desktop | MIT | Direct Flutter dependency, exact version. Brings `screen_retriever` 0.2.2 (MIT) and its platform packages. No network use. |
| `local_notifier` 0.1.6 | Windows toast (and Linux/macOS) notifications built on the device after decryption | MIT | Direct Flutter dependency, exact version. Brings `uuid` 4.6.0 (MIT). Creates a Start menu shortcut on Windows, which toasts need. Linux needs `libnotify`. No network use. |
| `aes-gcm` 0.11.1 | Authenticated encryption for platform-wrapped MLS state, attachment, and backup chunks | Apache-2.0 OR MIT | Exact version pinned; does not replace MLS message protection. |
| `openmls` 0.9.2 | MLS 1.0 group state and message processing | MIT | Exact version pinned in `crypto/rust/Cargo.lock`; sensitive debug features are disabled. |
| `openmls_basic_credential` 0.6.0 | Basic MLS credential signing keys | MIT | Exact version pinned; used to bind the application device identity to MLS credentials. |
| `openmls_rust_crypto` 0.6.0 | RustCrypto provider for OpenMLS | MIT | Exact version pinned; native provider core only, pending platform-secure persistence review. |
| `openmls_traits` 0.6.0 | OpenMLS provider and storage traits | MIT | Exact version pinned. |
| `sha2` 0.11.1 | SHA-256 enrollment key-package commitment | Apache-2.0 OR MIT | Exact version pinned; used only to bind the public key package into the signed enrollment proof. |
| `tls_codec` 0.5.0 | RFC 9420 TLS presentation-language encoding | MIT | Exact version pinned for MLS transport serialization. |
| Flutter SDK | Mobile client framework | BSD-3-Clause | Toolchain, not vendored. |

## Mobile Localization Dependencies

Added for T44C (localization scaffolding). The Serbian translation added no further dependency.

| Component | Use | License | Notes |
| --- | --- | --- | --- |
| `flutter_localizations` (Flutter SDK 3.44.0) | Material/Cupertino/Widgets localizations and locale-aware date formatting | BSD-3-Clause | Part of the Flutter SDK (`sdk: flutter`); not fetched from pub.dev. |
| `intl` 0.20.2 | Message lookup and plural/date formatting used by the generated `mobile/lib/l10n` code | BSD-3-Clause | Direct Flutter dependency pinned to the exact version `flutter_localizations` requires in Flutter 3.44.0; maintained by dart.dev. Its `path` dependency was already in the lock. |

## Generated Data

| Data | Use | License | Notes |
| --- | --- | --- | --- |
| Unicode character names and the Emoji property (Unicode 15.0, read from Perl 5.38) | `mobile/lib/features/chat/emoji_data.dart`: the emoji list of the reaction picker, with searchable names | Unicode License v3 | Generated by `scripts/gen-emoji-data.py`; not a dependency. The Unicode copyright notice and permission notice apply to the names. |
| ISO 3166-1 alpha-2 country names (tzdata `iso3166.tab`) | The same file: flag names for search | Public domain | Same generator. |

### Unicode License v3

The character names and emoji properties above are from the Unicode Character Database and are used under this notice:

```
COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2025 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

## Reference Projects Studied, Not Copied

Signal/libsignal, OpenMLS, Matrix/Synapse/Element, SimpleX Chat, Mattermost, Zulip, Rocket.Chat, Stoat/Revolt, PocketBase, Pion, LiveKit, Caddy, UnifiedPush, ntfy, and MiroTalk were studied for architecture, deployment, crypto, licensing, and self-hosting lessons. No source code from these projects is copied into this repository.

OpenMLS dependency review (2026-09-24, OpenMLS 0.9.0 / hpke-rs 0.7; patch
update to OpenMLS 0.9.2 and sha2 0.11.1 on 2026-10-23, same graph and
licenses, for GHSA-gc79-23g3-8g52, GHSA-p276-g3f3-wwgh and GHSA-94v4-rg25-x625): the
locked graph contains 205 third-party packages. Every package declares a
license. The observed SPDX expressions are MIT, Apache-2.0, ISC, BSD-1-Clause,
BSD-2-Clause, BSD-3-Clause, MPL-2.0, Unicode-3.0, LLVM-exception,
LGPL-2.1-or-later, Unlicense, and dual-/multi-license alternatives that include
MIT or Apache-2.0. `cargo audit` reports no vulnerabilities and needs no
exceptions. The post-quantum crates (`ml-kem`, `ml-dsa`, `x-wing`) compile but
stay unreachable while the classical suite is pinned, and `crabgrind` builds
only under `cfg(valgrind_ct_test)`. No sensitive OpenMLS debug feature is
enabled. Preserve the generated SPDX SBOM and upstream license texts with
releases; Android/iOS artifact review remains required before enabling the
mobile ABI.

Go dependency review (2026-07-29): `go-licenses` reported MIT licenses for
`webpush-go`, `go-humanize`, `golang-jwt/jwt`, and `modernc.org/libc`, and
BSD-3-Clause licenses for `google/uuid`, `bigfft`, `golang.org/x/crypto`,
`golang.org/x/sys`, `modernc.org/memory`, and `modernc.org/sqlite`.
`modernc.org/mathutil` 1.7.1 was not classified by the scanner; its packaged
license and source header were reviewed manually and are BSD-3-Clause.

## Build and Release Dependencies

| Component | Use | License | Notes |
| --- | --- | --- | --- |
| GitHub Actions official actions | Checkout, Go setup, artifact upload, provenance attestation | MIT | Pinned to immutable commits in workflow files. |
| `subosito/flutter-action` | Pinned Flutter SDK setup in CI | MIT | Build-only; pinned to an immutable commit. |
| `anchore/sbom-action` / Syft | SPDX SBOM generation | Apache-2.0 | Release-only; pinned to an immutable commit. |
| `drift_dev` 2.34.5 | Generates checked Drift table and query bindings | MIT | Development-only; generated source is committed for reproducible builds. |
| `build_runner` 2.15.1 | Runs Dart source generation | BSD-3-Clause | Development-only and pinned for the Flutter 3.44/Dart toolchain. |

## Release Checklist

- Run dependency license scan.
- Update this file with exact versions and transitive notices.
- Preserve attribution for any permissively licensed code or assets.
- Re-check GPL/AGPL compatibility before adding copyleft dependencies.
