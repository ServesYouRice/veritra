# Third Party Notices

This project is licensed AGPL-3.0-or-later. Dependency licenses must be compatible with that license and tracked here before release.

## Direct Runtime Dependencies

| Component | Use | License | Notes |
| --- | --- | --- | --- |
| `modernc.org/sqlite` | Pure-Go SQLite driver | BSD-style / compatible notices required | Chosen to support single-binary builds without CGO. Verify exact transitive notices during release. |
| `golang.org/x/crypto` | Password hashing helpers | BSD-3-Clause | Used for password fallback hashing. |
| `github.com/SherClockHolmes/webpush-go` | RFC 8291 Web Push encryption and VAPID | MIT | Server-side optional generic wake delivery; pinned in `server/go.mod`. |
| `org.unifiedpush.android:connector` 3.3.3 | Android push distributor registration and RFC 8291 decryption | Apache-2.0 | Official connector; receives only a fixed generic wake event. |
| `com.google.crypto.tink:tink-android` 1.21.0 | Android keystore-backed Web Push key handling | Apache-2.0 | Forced to one Android artifact to avoid duplicate classes across secure storage and UnifiedPush. |
| `flutter_secure_storage` | Platform secure storage for mobile sessions | BSD-3-Clause | Direct Flutter dependency; platform packages are pulled transitively by `flutter pub get`. |
| `mobile_scanner` 5.2.3 | Device-link QR scanning | BSD-3-Clause | Direct Flutter dependency. Android uses ML Kit, iOS uses the system Vision framework, and web uses ZXing; include their applicable notices/terms in release review. |
| `web` 1.1.1 | Browser API bindings used by `mobile_scanner` | BSD-3-Clause | Transitive Flutter dependency pinned in `mobile/pubspec.lock`. |
| Flutter SDK | Mobile client framework | BSD-3-Clause | Toolchain, not vendored. |

## Reference Projects Studied, Not Copied

Signal/libsignal, OpenMLS, Matrix/Synapse/Element, SimpleX Chat, Mattermost, Zulip, Rocket.Chat, Stoat/Revolt, PocketBase, Pion, LiveKit, Caddy, UnifiedPush, ntfy, and MiroTalk were studied for architecture, deployment, crypto, licensing, and self-hosting lessons. No source code from these projects is copied into this repository.

OpenMLS dependency candidate review (2026-07-15): upstream `openmls` 0.8.1
and its optional `openmls_rust_crypto` 0.5.1 provider declare MIT. Neither is
currently linked or shipped. Their transitive licenses and Android/iOS build
artifacts still require review before they may move into runtime dependencies.

## Build and Release Dependencies

| Component | Use | License | Notes |
| --- | --- | --- | --- |
| GitHub Actions official actions | Checkout, Go setup, artifact upload, provenance attestation | MIT | Pinned to immutable commits in workflow files. |
| `subosito/flutter-action` | Pinned Flutter SDK setup in CI | MIT | Build-only; pinned to an immutable commit. |
| `anchore/sbom-action` / Syft | SPDX SBOM generation | Apache-2.0 | Release-only; pinned to an immutable commit. |

## Release Checklist

- Run dependency license scan.
- Update this file with exact versions and transitive notices.
- Preserve attribution for any permissively licensed code or assets.
- Re-check GPL/AGPL compatibility before adding copyleft dependencies.
