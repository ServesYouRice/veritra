# B1 voice notes — 2026-11-10

Status: merged on `main` (PR #122, `a5335cd`), verified with full local checks
passing. No counter bumped: ABI 12, local schema 18, migration 0046 unchanged.
No server change.

## What it does

- Recording: `VoiceRecorderController` in `voice_recorder.dart` with
  `VoiceRecorderBar` above composer. Records AAC (`audio/mp4`, .m4a) at 64 kbit/s
  mono, with uncompressed WAV fallback. Hard duration cap of 10 minutes stops
  recording automatically. Discard deletes the temporary recording immediately.
- Attachment pipeline: Finished recording is placed in composer attachments tray
  and uploaded as a standard encrypted chunked attachment (AES-256-GCM, 1 MiB
  chunks) with attachment manifest inside the MLS message.
- Inline playback: `VoiceNoteTile` in `voice_notes.dart` plays audio inline in the
  message bubble with progress indicator, elapsed/total duration, and single-note
  concurrency (playing one note pauses any currently active note).
- Privacy & boundaries: Ephemeral decrypted audio copy is stored in app private
  cache and deleted immediately when playback finishes or tile is disposed.
  Transcription is on-device only; no server-side audio processing, search, or
  transcription service exists.

## Dependency

Approved by owner in D89 (`STATE.md`): `record` plugin, listed in
`THIRD_PARTY_NOTICES.md`.

## Checks

- `mobile/test/voice_notes_test.dart`: 11/11 tests passed (recording state,
  tray handoff, permission denial, cancellation/discard, auto-stop at duration
  limit, inline playback lifecycle, cleanup of decrypted file).
- `flutter analyze` in `mobile/`: No issues found.
- Full `flutter test`: 2,608/2,608 tests passed.
