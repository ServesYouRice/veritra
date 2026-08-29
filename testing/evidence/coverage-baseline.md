# Coverage baseline (QA10)

Provisional measurement supporting QA10. Floors in `scripts/check-coverage.py`
call sites are still `0.0`: the gate enforces artifact presence and
parseability only. Numeric floors remain an advisor decision.

## Provenance

| Field | Value |
|---|---|
| Base commit | `9dcb8774c2ea60ac91ecbd1f51904b4868fe792d` |
| Working tree | **dirty** — measured with the call-session/optimistic-concurrency changes applied |
| Measured | 2026-08-27 |
| Go toolchain | `golang:1.25.13` container (matches `.go-version`) |
| Flutter toolchain | `ghcr.io/cirruslabs/flutter:3.44.0` container, Dart 3.12.0 |

This is **not yet a clean commit-bound baseline**. Re-measure on a frozen
commit before any floor is enforced.

## Commands

```sh
cd server && go test -race -coverprofile=coverage.out ./...
cd server && go tool cover -func=coverage.out
cd mobile && flutter test --coverage
```

## Go — 50.8% of statements

| Package | Coverage |
|---|---|
| `internal/messaging` | 88.9% |
| `internal/realtime` | 72.1% |
| `internal/config` | 69.1% |
| `internal/app` | 65.5% |
| `internal/auth` | 61.7% |
| `internal/uploads` | 53.3% |
| `internal/storage` | 51.1% |
| `internal/httpapi` | 50.6% |
| `cmd/messenger-server` | 37.6% |
| `internal/domain` | 7.4% |
| `internal/push` | 0.5% |
| `internal/cryptoapi` | 0.0% (no test binary) |
| `internal/webrtc` | no test files |
| `migrations` | no test files |
| `websetup` | no statements |

`internal/push` at 0.5% and `internal/cryptoapi` at 0.0% are the untested
high-risk services.

## Flutter — 40.42% of lines (3546/8773 over 40 files)

| Area | Coverage |
|---|---|
| `ui/theme.dart`, `ui/avatar.dart`, `push/push_service.dart`, `core/errors.dart` | 100% |
| `crypto/app_payload.dart` | 86.7% |
| `core/app_state.dart` | 69.6% |
| `core/models.dart` | 61.8% |
| `ui/widgets` | 59.5% |
| `features/chat` | 55.0% |
| `storage/local_store.dart` | 52.6% |
| `storage/encrypted_database.dart` | 46.5% |
| `sync/sync_service.dart` | 38.8% |
| `features/auth` | 33.6% |
| `storage/encrypted_database.g.dart` (generated) | 24.9% |
| `crypto/attachment_crypto.dart` | 21.1% |
| `features/settings` | 19.3% |
| `core/api_client.dart` | 15.8% |
| `ui/app_shell.dart` | 3.3% |
| `crypto/native_crypto_bindings.dart` | 0.4% |
| `features/search`, `features/communities`, `crypto/crypto_service.dart` | 0.0% |

### Scope caveats — read before choosing a floor

- **`lib/calls/` is absent from the report entirely.** LCOV only emits records
  for files a test loaded, so `calls/call_service.dart` has no coverage at all.
  A total-line floor cannot see a regression there.
- **`storage/encrypted_database.g.dart` is generated** and is 2025 of the 8773
  measured lines (23%). It depresses the total without carrying review risk.
  Decide explicitly whether to exclude it before fixing a floor.
- **4 tests skipped**: 3 native attachment-crypto tests need
  `VERITRA_CRYPTO_LIBRARY`, and the live API contract test needs
  `VERITRA_CONTRACT_BASE_URL`. CI supplies the native library, so CI's Flutter
  number will be **higher** than 40.42%.
- The measuring container's Dart (3.12.0) could not satisfy
  `flutter pub get --enforce-lockfile`; four SDK-pinned packages (`matcher`,
  `meta`, `test_api`, `vector_math`) resolved lower than the lockfile. Measured
  with a plain `flutter pub get`. Confirm CI's Flutter 3.44.0 satisfies the
  lockfile before treating this number as CI-equivalent.

## Rust

**Unmeasured.** No coverage tool is installed or approved. Adding one requires
dependency, license, and notices review first.
