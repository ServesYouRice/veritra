# C6 wiring, steps 2 and 3 (2026-11-07)

Note: the first sections describe the wiring as first built. Owner decision
D95 changed the report route, the aad and the tests named for it (v2 aad, no
envelope id in clear, one copy per owner, no server-side snapshot) and
answered its owner questions; read "D95" at the end for the current state.

Scope: franking on the send and receive path, and the server side of reports
(migration 0047). No ABI, payload version or local schema change.

## What changed

- Server: `message_envelopes.frank_commit` (write-once, own column), tables
  `report_inbox_keys` and `reports`, routes under `/api/v1/reports`
  (`server/internal/httpapi/report_handlers.go`,
  `server/internal/storage/report_store.go`), `franking.ReportAAD`.
- Mobile: `MessageEnvelope` and `ReceivedMessageEnvelope` carry `frankCommit`
  (a JSON field of the envelope blobs already stored, so no schema change);
  `NativeCryptoService.encryptPayload` writes every message with
  `encodeFranked` and sends the commitment; `_processApplicationMessage` runs
  `_checkFranking` after `classify`; `reportAad` builds the report aad.
- Vector: `testing/vectors/c6-report-aad-v1.json` (Go and Dart check it).
- Docs: `docs/crypto.md` "Franking v1" (What is wired) and change log;
  `docs/designs/C6-reports-franking.md` "Wiring outcome".

## Conditions

| | How it is met | Test |
|---|---|---|
| G1 | server copies sender, commitment and envelope time into the report row; the design text says what a label may claim (screens are step 4) | `TestReportToInstanceOwnerFromGroup` (snapshot, survives envelope deletion) |
| G2 | commitment context is the envelope's ids after `classify` matched the payload | `receive_policy_test.dart` "a franked message must match the envelope commitment" (rebound action id is invalid) |
| G3 | own column, `CHECK` 32 bytes, abort trigger, edit route refuses franked rows, retry must repeat it | `TestFrankCommitIsStoredOnceInItsOwnColumn`, `TestReportsMigrationUpgradesExistingEnvelopes` |
| G4 | aad over inbox kind, id, recipient key, conversation, envelope, reporter; a report names the key it sealed to, so a key revision that restarts after an owner is deleted cannot misroute it | `TestReportAADVector`, `TestReportAADBindsEveryField`, `c6_report_crypto_test.dart` "report aad", `TestReportToARepublishedKeyIsRefusedAtTheSameRevision` |
| G5 | decided: unfranked accepted as unreportable; franked with missing or wrong commitment invalid | `receive_policy_test.dart`, `native_crypto_service_test.dart` "every message is franked" |
| G6 | not applicable while the Dart app is the only verifier (recorded in the design) | none |

## Checks

Run locally (Linux, Go 1.x of the repo): `go vet ./...` clean, `go test ./...`
all packages ok (includes the new report, migration and aad tests).
`dart format --set-exit-if-changed` over `mobile/lib` and `mobile/test` with
the Dart 3.13 SDK and language version 3.4 (as CI): clean.

Not run locally: `flutter analyze` and `flutter test` (no Flutter toolchain).
The Dart tests above have not run anywhere yet: the GitHub CI mobile,
mobile-ios and desktop-* jobs fail at `flutter pub get --enforce-lockfile`
on this head and on main (`intl 0.20.3` in `mobile/pubspec.yaml` against the
`0.20.2` that Flutter 3.44.0's `flutter_localizations` pins). Until a fix for
that lands on main and this branch is rebased with the mobile job green, the
Dart side of C6 is unverified. A review found two Dart failures that this gap
hid (fake bindings without `frankCommit`; 11 unmapped server error codes); both
are fixed here but still await a green CI run.
The demo e2e job is known to time out waiting for sync on several branches.

## Not wired (blockers for later steps; items 1 is closed by D95, see the end)

1. Receivers do not keep `kf` and the exact `P` with each message. Reporting
   needs them, and the local message store has no place for them: a local
   schema change (the next number is the coordinator's to reserve).
2. The community moderator inbox key has no publish route until C4 defines
   how the seed reaches moderators (design item 8). Community reports are
   refused with `report_inbox_unavailable` until then (tested).
3. Report screens, the seal call from the app, and the "verified against
   what the server recorded" label (build step 4).

## Owner questions

- Accept unfranked payloads for now (G5), or refuse once all senders are new?
- Report retention window (design item 2): today reports stay until
  dismissed, capped at 2000 per inbox and 20 a day per reporter.
- Pin the instance owners' report key (like the K0 recovery key) so the
  server cannot substitute it?
- One shared owner inbox key, or one copy per owner as C5 escalations do?
- C7 left this to C6: `POST /api/v1/reports` carries `envelope_id` in clear,
  so a newcomer reporting a pre-join post shows the server that its channel
  was `full` then. Move the envelope id inside the sealed body for community
  reports, or hide the report action on pre-join posts?
- The independent wiring review (G1 to G6) the design asks for has not
  happened; no review agent was available to this work.

## D95 (2026-11-07): schema 19, sealed envelope id, per-owner copies, pins

Scope: owner decision D95 (STATE.md, PR #135) applied to this branch. Local
schema 19 (C6's reserved number), migration 0047 edited in place (it is not
merged; no deployed database has it), no ABI, payload-version or
error-contract change. `message_not_reportable` is removed from the server and
the Dart error map (the server cannot tell any more).

| D95 point | Where | Test |
|---|---|---|
| receiver keeps `kf` and the exact `P` | `local_frank_reveals`, written with the MLS transition (`MlsStateTransition.frankReveals`) | `c6_schema19_test.dart` "kf, the exact P and the envelope id come back byte for byte"; `receive_policy_test.dart` "a franked message must match the envelope commitment" (the kept bytes recompute the sender's commitment; refused messages keep nothing) |
| upgrade test 18 to 19 | `onUpgrade` `from < 19` | `c6_schema19_test.dart` "upgrade from schema 18" (existing message kept, no reveal for it, tables and trigger present, a later message keeps one) |
| P1: a reveal never stalls sync | row written only if the message row is live, a refused reveal is skipped | "an edit, a reaction or an unknown row writes nothing and the cursor still advances", "already expired", "a reveal that the table would refuse is skipped" |
| text is gone when the message is | cascade plus tombstone trigger | "delete for everyone", "hiding", "expiry purges it", "a full reset", "an identity change" |
| `envelope_id` sealed, never in clear | `ReportBody`, `POST /reports` has no envelope field, `reports` has no such column | `c6_report_body_pins_test.dart` "each owner opens only its copy, and the envelope id is not in the clear"; Go `TestReportToEveryInstanceOwnerFromGroup` (no column, no field in the response) |
| aad v2 | `franking.ReportAAD`, `reportAad`, `testing/vectors/c6-report-aad-v2.json` | `TestReportAADVector`, `TestReportAADBindsEveryField`, `c6_report_crypto_test.dart` "report aad" |
| one sealed copy per owner | per-owner `report_inbox_keys` (inbox id = account id), one `reports` row per copy | `TestReportToEveryInstanceOwnerFromGroup` (missing owner, duplicate, stale revision, wrong key, non-owner inbox, per-owner list and dismissal), `TestOwnerLeavingDropsItsKeyAndCopies`, `TestReportToARepublishedKeyIsRefusedAtTheSameRevision` |
| owner key pinned in the app | `local_report_key_pins`, `ReportKeyPins` | `c6_report_body_pins_test.dart` "pinned owner report keys" (unpinned, changed, server-added owner, missing owner, per origin) |
| 90-day or dismissed retention | `PruneReports` in the retention sweeper, `ListReports` hides older copies, `DELETE` removes the caller's copy | `TestReportsArePrunedAfterNinetyDays`, the "older than 90 days" step of the Go route test |
| unfranked accepted behind a switch | `FrankingPolicy(acceptUnfranked: true)` | `receive_policy_test.dart` "the switch that refuses unfranked payloads (D95)" (both store variants: refused as an invalid row, sync moves on, hidden unknown types exempt, franked kept) |

### Checks

Go (local): `go vet ./...`, `go test ./...` (see the PR for the final run).
Dart (local, Flutter 3.44.0 / Dart 3.12.0 with the native library built from
this branch, `VERITRA_REQUIRE_NATIVE_CRYPTO=1`): `dart format
--set-exit-if-changed .` clean, `flutter analyze` clean, the new and changed
tests above pass. CI on the PR is the check of record.

### Costs and owner questions that D95 leaves

1. **Verification by an owner.** With the envelope id sealed the server cannot
   snapshot the sender, commitment and time when a report is filed (G1 now
   rests on the envelope row still existing), cannot refuse a report of the
   reporter's own or an unfranked message, and cannot dedupe by message.
   Recipients check the first two against the revealed body, and the
   reporter's app dedupes. An owner who opens a copy knows the envelope id and
   needs the envelope's sender, commitment and time: a route that returns them
   for one envelope of a conversation with a report would tell the server the
   envelope id at review time (not at filing). Not built; until it is a report
   cannot show "verified against what the server recorded". Build it, or accept
   the reporter's claimed values as unverified?
2. **Edits.** A reveal is kept for the message as first received; an edit's own
   `frank` is not stored. Reporting reveals the original (design item 4).
3. **Deleted evidence.** A sender who deletes a message for everyone removes
   the reveal from every receiver, so it can no longer be reported afterwards.
   Keep the reveal for a short window after a delete, or accept?
4. **Owner key custody.** The owner's own report seed storage and key
   publication (and the first pin of an owner's own key on a second device)
   belong to the report screens (step 4).

