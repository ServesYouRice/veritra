# C6 wiring, steps 2 and 3 (2026-11-07)

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

Not run locally: `flutter analyze` and `flutter test` (no Flutter toolchain);
the Dart tests above run in the GitHub CI mobile job with the native library.
The demo e2e job is known to time out waiting for sync on several branches.

## Not wired (blockers for later steps)

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
