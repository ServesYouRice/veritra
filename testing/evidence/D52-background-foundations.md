# D52 background foundations - 2026-10-29

Implemented and narrowly checked; the phone worker is **not integrated or
enabled**. Native cold execution and subscription opt-in remain disabled.
The private notification outbox and main/AppState bootstrap/worker are pending.

## Strict existing state

SecureLocalStore can open in existing-only mode, captured once before any
asynchronous directory lookup. It refuses absent profile/database/key, reset
journals, legacy records, missing migration completion and noncurrent schema.
Only actual UI attachment may enable initialization for a later open.

The strict SQLite isolate uses READWRITE without CREATE and checks the keyed
schema before WAL setup. It cannot recreate a file deleted after preflight.
Opening is deferred until after Drift's isolate handshake. Failed-open cleanup
must absorb the already-cleaned opener error so isolate shutdown completes;
an initial test exposed that hang, and the corrected failure path passes.
Post-open marker/keychain-check failures close the connection before propagating.
No key generation, reset completion, legacy import or schema migration runs.

Tests inject a directory provider. The default path_provider native method may
ensure an empty application support base exists; these tests do not claim that
the OS never creates that empty base directory. They prove no new protected
profile/database/key and no repair/migration of unavailable state.

## Bounded work and atomic fence

BackgroundWakeRunner binds one exact owner to one native permit, uses a
monotonic deadline that native validation can only shorten, rejects overlapping
runs and refuses ACK success for incomplete/non-durable decisions. Read-only
validation RPC waits are bounded. Cancellation closes registered job-owned HTTP
clients and drains atomic work; it never force-times-out a database transaction
or destroys an active native device. The real HTTP test stalls a loopback
response and proves cancellation closes that connection.

NativeCryptoService exposes separate bounded receive/activation methods. A
captured operation fence runs in its queue and the storage transaction; pending
enrollment cannot create initial state on this path. Revocation after SQLite
state/history writes rolls the entire transaction back, restores the native
ratchet, and permits the same ciphertext to decrypt on retry. No guard restores
old native state after a successful SQL commit.

Notice policy additionally refuses copied rows, timestamp substitution and
far-future creation times. The phone-only option permits generic attachment
notices with no manifest preview or mute override; desktop defaults are unchanged.

## Executed checks

Pinned Windows Flutter/Dart, with the real matching ABI8 debug DLL:

```text
flutter test --no-pub --concurrency 1 --timeout 10s test/background_existing_store_test.dart
PASS 7
flutter test --no-pub --concurrency 1 test/background_wake_runner_test.dart test/message_notice_policy_test.dart test/k2_native_streams_test.dart
PASS 18 (includes reviewed malformed-native-result wiping regression)
flutter test --no-pub --concurrency 1 test/receive_policy_test.dart
PASS 29 (memory + SQLite, including real MLS cancellation/rollback/retry)
flutter analyze
PASS, no issues
python scripts/l10n-sr-latn.py --check
PASS
```

The dependency lock is unchanged. The original full Linux baseline is recorded
in verification-2026-10-28.md; these newer combined slices still require full
repository test/lint and native platform/lifecycle verification. No release
gate, production crypto constructor or dependency was added.
