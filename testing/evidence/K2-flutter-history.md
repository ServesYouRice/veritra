# K2 Flutter history-only storage evidence

2026-10-28. Local implementation and focused verification; independent review,
final full scripts, native handoff orchestration and read-only historical UI
remain pending. No end-to-end new-device history claim or release gate change.

Implemented schema 14 namespace, distinct history plaintext v1 codec, source
counter, atomic additive import, provenance, backup plaintext v5 and historical
timeline ordering. Design: `docs/designs/K2-flutter-history-snapshot.md`.
The root coordinator independently reviewed the format/migration/merge decisions
before implementation; a separate agent is reviewing the resulting code.

Focused Windows Flutter run: **84 passed, zero failed**, using real ABI8 debug
native DLL for attachment crypto, across:

- `k2_history_snapshot_test.dart` (20 cases)
- `w8_send_owner_test.dart` (2 cases)
- `w8_forward_attachments_test.dart` (3 real native cases)
- `w8_message_actions_test.dart`, `w8_migration_test.dart`
- `message_history_test.dart`, `message_search_test.dart`, `message_expiry_test.dart`

This run covers duplicate/unknown fields, protected-field rejection, hidden
controls, copied legacy markers, C0 shared/isolated contexts, SQLite/memory
parity, existing receiver choices, immutable identity/server-ID collisions,
body-free tombstones, expiry, local FTS, exact-repeat ledger behavior, wrong
origin, mixed provenance backup/restore, genuine schema 12/13 upgrades and
rollback/retry, and injected import-ledger failure rolling back rows and FTS.
Protected-state comparison includes a nonzero cursor, pending outgoing envelope,
session/device secret, sealed MLS state/key/counter, drafts and acceptance setting.

Forwarding review fixes additionally capture the source session/generation,
check after every plaintext await and inside queued sends, and wipe memory on
session switches. Tests switch identity after the first destination and during
memory decryption, and queue old plaintext behind another operation. No later
upload/send uses the new identity.

The approved same-device snapshot counter highwater restore refinement was added
after the 84-test run; its final narrow rerun and analysis result will be recorded
before handoff. Full scripts are coordinator-owned on an isolated Linux snapshot;
the earlier complete W8 baseline is separate evidence, not a full K2 result.

## Review fixes and resumed checks (2026-10-29)

Independent review found and the local slice now addresses:

- Authenticated edits/deletes for an absent target need durable scoped intents,
  otherwise an older import can resurrect text. The journal is coalesced and
  bounded, applies only matching actor/scope, keeps terminal deletes, and survives
  backup/restart. K2 export excludes the journal.
- Direct MLS content must reconcile copied rows. Matching identities preserve
  receiver hide/delete/live-edit state; mismatches quarantine copied evidence and
  clear copied extras. Copied server-ID shadows are removed even for an otherwise
  ignored direct duplicate. Direct-vs-direct behavior is unchanged.
- Copied identity labels cannot discard mismatched authenticated live intents
  before the actual direct target arrives.
- Restored own bubbles now show a copied-history label and no live receipt ticks.

The first resumed four-file focused run passed **38 tests, zero failures**
(29 history, 4 UI, 2 send-owner, 3 real-native forward cases). Two additional
both-store regressions for copied author/intent loss and copied server-ID shadow
were added afterward. They belong to the next complete check checkpoint.

The subsequent expanded nine-file attempt aborted with Windows Dart VM
`Out of memory`; the analyzer separately failed to start a DartWorker thread
with OS error 22. Neither is recorded as a passing check or a code assertion
finding. Formatting passed. The coordinator is serializing heavy checks and
will run the coherent source checkpoint on isolated Linux. No fixtures or
requirements were weakened to hide the resource failure.

The coordinator then granted an exclusive toolchain slot after resource use
settled. The final source checkpoint passes, serially:

```text
flutter test --no-pub --concurrency 1 test/k2_history_snapshot_test.dart
PASS: 33 tests, including both new actor/intent and server-ID shadow cases
flutter test --no-pub --concurrency 1 test/w8_ui_test.dart test/w8_send_owner_test.dart test/w8_forward_attachments_test.dart
PASS: 9 tests, using the matching real ABI8 DLL
dart analyze <history/store/UI source and these focused tests>
PASS: no issues
```

No runtime edits followed these final checks. These results supersede the lack
of a completed narrow rerun after the host exhaustion; the combined repository
Linux checkpoint remains separately coordinator-owned.

Known boundary: the store context is internal data, not an authentication
capability. Future orchestration must call import only after native verification
of the frozen origin/identity/container/handoff. Source snapshot provenance is
not retrospective original-sender MLS proof. No session/MLS/outbox/cursor/pending
pin commands are transferred. Historical descriptors do not enter D48 acceptance
or active membership caches. No plaintext temporary file is written by this slice.
