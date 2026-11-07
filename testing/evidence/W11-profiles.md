# W11 profiles: first slice (server + record codec)

Design: `docs/designs/W11-profiles.md`. Counters used: server migration 0053.
No local schema or crypto ABI change in this slice.

## Built

- `server/migrations/0053_encrypted_profiles.sql`, `internal/storage/profile_store.go`,
  `internal/httpapi/profile_handlers.go`: account and group records, read rule,
  412 version race, two size buckets, `profile.updated` (IDs and versions only),
  versions batch, legacy title clear, account delete and export.
- `mobile/lib/crypto/profile_record_codec.dart`: key id, record build and padding,
  seal and open through the existing chunk AEAD, receive checks 1-5, photo header checks.

## Checks run

- `go test ./...` in `server`: all packages pass; `go vet ./...` and `gofmt -l` clean.
- Dart (Flutter 3.44.0, native library built): `flutter test test/profile_record_codec_test.dart`
  12 of 12 pass, including the design's key-id vector and both AEAD vectors;
  `flutter analyze` no issues; `dart format --set-exit-if-changed` clean.

## Left (not in this slice)

Local schema 21 tables, MLS payload types and sidecars (`profile_key`,
`group_profile_key`), delivery and lazy rotation, photo pipeline, editors and
display, l10n, backups, end-to-end tests, group/community rename UI.

## Opus review (independent) and fixes

Blocker fixed: a name with an unpaired surrogate passed and crashed Flutter text
(now refused on seal and open; U+2028/2029/200B also refused). Also fixed: rows
count toward the writer's storage limit; `subject_kind` is no longer a closed
CHECK and the table is a plain rowid table (C3 reuse); title-clear route has the
write budget; codec validates subject IDs and ignores the floor for groups;
`If-None-Match: *` on GET gives 200. Tests added for each, and for "subject
blocks reader".

Owner question: any account can open a DM or group with any other (consent-free
creation), so the design's "send the key into a conversation" gives a stranger
the profile key. Decide before the delivery slice.
