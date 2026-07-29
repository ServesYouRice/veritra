# Implementation board

Status: **NO-GO** — production crypto remains fail-closed.

## User decisions

- [x] **D01** Approved `drift` 2.34.3 + `sqlite3` 3.5.0 with the `sqlite3mc` hook and explicit ChaCha20; keep a random 256-bit hex key in device-bound `flutter_secure_storage` and fail closed if cipher/key checks fail.
- [x] **D02** Keep encrypted backup/recovery in the first production release.
- [x] **D03** Do not defer native APNs/FCM or calls; include them in the current implementation scope.
- [x] **D04** Minimize admin audit events by omitting block/member target IDs unless operationally required.
- [x] **D05** Prepare the protocol/mobile security-review evidence now; production remains fail-closed pending an independent external review.

## Ready

- None.

## Doing

- None.

## Verification queued

- None.


## Blocked

- [ ] [I25 — Independent review and release gate](tasks/I25-release-gate.md) — review packet and evidence matrix prepared; blocked on independent reviewer and I24 external checks
- [ ] [I24 — Build signed apps and run real-device checks](tasks/I24-release-builds.md) — native APNs/FCM, self-hosted TURN, and encrypted WebRTC implementation complete; Android debug APK builds; signed apps and real-device checks require external hardware/signing approval

## Backlog

- [ ] [I20 — Add identity and safety UX](tasks/I20-safety-ux.md) — excluded by user as UI-only work

## Later

- Measure before performance changes: query plans, load, soak, push fan-out.
- Profiles/avatars, local content search, desktop, multi-account, passkeys.
- Product polish: `veritra://` invite URI and QR, drafts, richer empty states.
- Encrypted extensions: link previews, voice notes, client-side import.
- Moderation reports and post-quantum readiness need a product trigger first.
- Dead-code and wrapper cleanup only after blockers; do not churn active seams.
- Native push and calls are part of the current implementation scope per D03.
- Session inventory and minimized audit-metadata changes follow D04.
- Remaining UI work is crypto-gated only: message actions, attachments, safety
  numbers, decrypted rendering, and the manual screen-reader pass on hardware.
- Out of scope: federation, Postgres, S3, NATS.

## Done

- 2026-07-29: I09, I12-I19, and I26 — completed and verified the encrypted
  local database, atomic MLS state, device-link SAS, conversation MLS flow,
  authenticated padded payloads, revocation convergence, streaming attachment
  crypto, capability-based encrypted recovery, durable outbox/sync repair, and
  out-of-band safety transcripts. Go and Rust tests, all non-UI Flutter tests,
  strict lint, and an Android debug APK build pass. UI-only I20 remains excluded.

- 2026-07-29: Remaining non-crypto UI — named DMs end to end (server DM peer
  identity, member usernames to co-members, canonical DM reuse), backward
  message pagination with preserved scroll position, member roster with
  role-gated remove and leave, block/unblock from DM details, search, and a
  Blocked accounts screen, per-conversation mute, an offline/reconnecting
  banner with sync errors separated from action errors, operation-scoped
  busy/error state so one failure no longer disables unrelated controls, a
  composer that clears on enqueue, aligned search copy and navigation,
  navigable community channel rows, in-dialog password validation, honest push
  status including iOS, and a wide-layout master-detail split. Verification
  could not be run: no Go or Flutter toolchain on the authoring machine.

- 2026-07-28: I21 — Enforced a tested single-writer process lock, one-time production setup secret lifecycle, readiness-first graceful drain, clean-host backup/restore drill, hardened deployment examples/runbook, and aligned pinned toolchains; the user-requested fresh Compose smoke remains reserved for the final pre-push gate.
- 2026-07-28: I23 — Hardened WebSocket handshakes and frame parsing, added fuzz/adversarial coverage for masking, fragmentation, bounds, control frames, UTF-8, close, lifecycle, slow clients, and proved trusted-proxy connection limits under the race detector.
- 2026-07-28: I22 — Added a migrated live-server contract suite covering every Flutter API route, typed JSON models, errors, and pagination with synthetic ciphertext; CI and aggregate tests pass.
- 2026-07-28: I11 — Bound the complete ABI v2 with typed errors, bounded secret handling, native finalization/idempotent close, and a passing Dart-to-Rust lifecycle conformance test; the app remains on the unavailable crypto service.
- 2026-07-28: I10 — Pinned Rust 1.90 mobile targets, added reproducible Android JNI/iOS XCFramework packaging with source/license metadata, linked the fail-closed ABI, and added CI symbol/build checks.
- 2026-07-28: I08 — Recommended exact Drift/SQLite3MC versions and a device-bound random-key design; documented the smaller-surface tradeoff for D01 approval.
- 2026-07-28: I07 — Made encrypted blob writes durable across file and directory sync, validated size and digest before reads, added authorized range downloads, and persisted deletion retries.
- 2026-07-28: I06 — Unified spoof-resistant HTTP/WebSocket/setup client identity, added strict enrollment and privacy-safe login backoff with bounded retry guidance, and made reference production setup fail closed.
- 2026-07-28: I05 — Added a scoped single-envelope repair endpoint and mobile sync repair-by-ID so old edits/deletes converge outside the newest page.
- 2026-07-28: I04 — Enforced unique two-account DMs and added scoped rosters plus safe group leave/removal with rank, last-owner, atomic lifecycle events, and explicit pending MLS coordination.
- 2026-07-28: I03 — Durable mutations and sync events are atomic for message edits/deletes, reactions, receipts, retention, calls, and device events; realtime publishing requires a committed event ID.
- 2026-07-28: I02 — Key-package claims now use migrated memberships transactionally; storage/API tests cover non-members, requester-device exclusion, and single-use behavior.
- 2026-07-28: I01 — Established a clean baseline; fixed the fail-closed setup notice, updated the scanner API callback, and removed the deprecated secure-storage option. Tests and lint pass; release readiness fails only at the intentional crypto gate.
- 2026-07-26: Consolidated active work; archived audits, old plans, and superseded docs.
