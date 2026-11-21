# L1 adversarial evidence and hold UI (2026-11-21)

Branch `l1-device-list` from `42626ff`. Implementation evidence, not G25
clearance and not the independent review. No ABI, local schema, server
migration or dependency change; release gates unchanged (release entry
points still use `UnavailableCryptoService`).

## Already delivered, rechecked against the code

The STATE row listed four blockers. Two were landed by earlier slices and
are only rechecked here:

- **Durable anchors.** Setup/registration journal the signed genesis before
  the session is saved and replay it before MLS activation; linking checks
  the frozen approver's add and journals the chain before promotion
  (`069b706`, `cfdd382`; `app_state_device_list.dart`
  `_journalDeviceListAnchor`/`_resumeDeviceListAnchor`). Tests:
  `l1_app_state_lists_test.dart` journal/storage-failure/interruption
  cases. New here: `l1_device_list_store_test.dart` "an upgrade keeps pins,
  removals, conflicts, verdicts and the activation journal" upgrades a
  schema-42 file (no `frank_key`, no `pinned_at`) with live pins, a
  conflict, a removed verdict and a journal setting, and opens it twice.
- **Complete adds.** Signed-list discovery at creation and on reported
  changes, the omitted-conversation audit and the one-hour notice
  (`e9ab8ae`, `d396c6d`, `app_state_l1_joins.dart`), with the audit tests
  in `l1_app_state_lists_test.dart`.
- **Recovery retype and pre-L1 key confirmation** (`e9ab8ae`, `1db32cb`).

## New: what a held chat shows, and the conflict reset

Design: [`L1-approved-devices.md`](../../docs/designs/L1-approved-devices.md),
"Hold states and the conflict reset". A held chat names each holding
account and why, with Check again; a contact's sticky conflict can be reset
to one of the two proven branches only. Files:
`mobile/lib/core/app_state_l1_holds.dart`,
`mobile/lib/features/chat/approval_hold_banners.dart`,
`DeviceListPins.trustServedBranch` in `mobile/lib/core/device_lists.dart`,
`replaceConflictedDeviceListPin`/`readDeviceListConflicts` in
`mobile/lib/storage/device_list_sql.dart` and `local_store.dart`. Strings
in English and formal Serbian (Cyrillic and generated Latin).

## Adversarial suite

`mobile/test/l1_adversarial_test.dart`. Every client is the real OpenMLS
engine with real signed VDL1 lists and real `DeviceListPins` (verified in
Rust). Only the server is fake: it serves any statements, key packages and
commits. A "compromised member" (list check off) produces hostile commits.

| Attack | Expected | Test |
|---|---|---|
| Server injects acct_alice/dev_ghost (device row and valid key package, on no list version) | Not staged at creation, on a reported add, or after a forged v2 that adds it (signed by the ghost, or with a damaged signature); pin stays v1, no conflict | 1, first |
| A commit carries the ghost in | Applied (epoch moves, sync goes on); Carol and Alice hold the chat for that leaf alone; nothing is encrypted; its message is a hidden `unapproved:` row with no body; Alice's own device owes the group an alert at head 1; an MLS removal releases both | 1, second |
| Rollback after a signed removal | Old head alone, or an empty answer: pin stays v2, the phone stays `removed`, sends stay held. The pin store is closed and opened again, the server still rolled back: still `removed`, no approved key | 2 |
| Forged statements | A damaged v2, a v2 signed by an unlisted key, a made-up genesis: pin stays v1, not sticky, ghost unapproved. First sight of a damaged genesis pins nothing. The honest chain then carries on | 3, first |
| A stolen listed key forks the list | Sticky conflict with the proof kept; the chat is held. The reset refuses a server-made chain and leaves the conflict; the honest branch is accepted and the chat is released | 3, second |
| Removed device returns in the list | Same pair, same id with a new key, old key under a new id: a pinned peer stays at v2 with the phone `removed` and nothing approved; a first-sight viewer pins nothing | 4, first |
| Removed device returns by commit | Held as `removed` for Carol and for Alice's own device; nothing encrypted | 4, second |

`mobile/test/l1_conflict_reset_test.dart`, on the in-memory store and on
the SQLite tables: the proof is kept; a proven branch replaces the pin,
restarts the first-pin time and keeps the proof; the pinned branch may be
chosen again; refused, with the conflict unchanged: another genesis, a
third validly signed branch outside the proof, a chain shorter than the
fork, a damaged statement, an unreachable or unknown server, no conflict;
after failed resets an ordinary refresh serving a made-up chain is still a
conflict (never a first sight); the store's compare-and-swap refuses
another list identity and a pin no longer in conflict.

`mobile/test/l1_app_state_lists_test.dart`, through `AppState`: one reason
per account (conflict, unapproved, own unapproved, removed, waiting for a
pre-L1 account, checking) in severity order; Check again reads the lists
and is spaced; the reset is refused for the own account and for a made-up
chain, and a proven branch clears the conflict in every chat. A widget
test checks the banner wording, Check again, the safety-number button, the
warning dialog (cancel changes nothing), the refusal message and the
trusted state.

## Mutations

Each guard was removed in turn and the named tests run
(`l1_adversarial_test.dart`, `l1_conflict_reset_test.dart`):

| Mutation | Caught by |
|---|---|
| M1 reset skips the proof check | third branch refused (both stores) |
| M3 SQL replace ignores the conflict state | store compare-and-swap (sqlite) |
| M3m memory replace ignores the conflict state | store compare-and-swap (memory) |
| M4 SQL replace ignores the list identity | store compare-and-swap (sqlite) |
| M7 a removed pair judged approved | rollback; both removed-then-re-added tests; proven-branch reset |
| M8 add gate stages with the server's key | injected device never staged |
| M9 conflict not sticky on refresh | fork test; five reset tests |
| M10 another genesis becomes a sticky conflict | forged statements test |
| M2 reset skips the list-identity check | **not caught, by design**: a proof statement fixes its prefix through `prev_hash`, so the proof check already refuses another genesis. Kept as defence in depth |

AppState/UI mutations are listed with the checks below.

Rule checks inside Rust (no-return, one key one device, signatures) were
not mutated here: no Rust build was allowed on this machine. They are
covered by the existing Rust vector tests (`testing/vectors/l1-device-list-v1.json`).

## Not covered

- First sight is trust on first use: a viewer that never pinned an account
  accepts whatever valid chain the server shows (design, "What it does not
  give"; L2).
- Withholding: a server that never shows a signed removal keeps the device
  approved for that viewer until the own-device alert or a later fetch.
- The live demo run against the real server binary (L1-5: register, link,
  message, revoke, recover, with a ghost row written into the stopped
  server's database) was not run: it needs a Go build and the demo e2e
  harness, and disk on this machine was too tight. The Dart suite above is
  the evidence for the client rules; the server's own gates are in
  `server/internal/httpapi/device_list_test.go` and
  `server/internal/storage/device_list_gates_test.go`.
- Independent review of the reset and the banners.

## Checks

Recorded at the end of the run; see the report for exact output.
