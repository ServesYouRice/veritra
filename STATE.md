# Veritra — state

The single record of where the project stands: what works, what is left, the
standing decisions and the release gates. It replaces `docs/board.md`,
`docs/audit-consensus.md` and `implementation/REMAINING_WORK.md`, which remain
in Git history at `d2d9eb8`. Evidence lives in [`testing/evidence/`](testing/evidence/).

**Updated 2026-10-31.**

## At a glance

| Area | State |
|---|---|
| 🎯 Current focus | Safer device linking (L0), then message actions (W8), history on a new device (K2), and communities (D50). Order and packages: [Build plan](#build-plan) |
| 🔒 Public release | 🔴 **NO-GO by design.** Messaging stays off in release builds until the independent crypto review (G25) and signed-device evidence (G24) pass |
| 🧪 Local demos (real encryption, labelled "unreviewed") | 🟢 Work: server + Linux app run here; Android, iOS, Windows, macOS build in CI |
| 🧰 Local work queue | 🟡 Build plan round 1 (2026-10-24) landed W2, W5, W6, W8 step 0, W9, W10, B4, B8, B9 and four designs; L0 implemented and verified; W8 client actions pass full Linux checks; the Linux muted-mention notice works end to end, and the phone path (D52) is wired in Dart but stays switched off. K2 has a read-only copied-history view and a verified download client; the transfer itself is not wired yet. Bug hunt (2026-10-25 plan): 106 of 227 tasks fixed (crypto, server HTTP and storage, mobile UI); crypto core now ABI 9. W1, W3, W4 wait for a run on a real Windows desktop. See [Build plan](#build-plan) and [Open work](#open-work) |
| 🚀 First deployment (k3s, handbook plan) | 🟡 Repo side ready; needs the owner's accounts (see [Deployment](#deployment)) and branch protection on GitHub |
| ✅ Checks | 🟢 2026-10-31, after merging the bug-hunt, W8, K2 and ABI 9 work: full Linux `scripts/test.sh` and `scripts/lint.sh` pass on 5cc0624 (1,106 Flutter tests; 1,109 after the key-refresh review fix, all 17 Go packages, 75 Rust unit + 2 integration tests), and `go test -race ./...` passes. Windows desktop and phone runs still open. Earlier: [2026-10-30 checkpoint](testing/evidence/checkpoint-2026-10-30.md), [`verification`](testing/evidence/verification-2026-10-28.md) |
| 🌐 Languages | 🟡 English, and Serbian (Cyrillic and Latin) awaiting a native-speaker review |

```
Demo foundation     ██████████  done
Offline use         ██████████  done
Linux app           ██████████  built and run against the demo server
Windows / macOS     ██████░░░░  build in CI; never run by hand
Android / iOS       ██████░░░░  build in CI; need an emulator/simulator run
Server hardening    █████████░  done; first real deployment pending
Client SDK (phase 3)██░░░░░░░░  outline only (docs/sdk.md)
```

## Done

The former audit queue (I29–I51) is implemented and checked, apart from the
items under [Open work](#open-work).
The runtime sweep on 2026-10-23 ([`verification-2026-10-23.md`](testing/evidence/verification-2026-10-23.md))
added tests for the acceptance criteria that had none and fixed what they found.

| Work | Result | Evidence |
|---|---|---|
| OpenMLS 0.9.0 → **0.9.2** | Fixes GHSA-gc79-23g3-8g52, GHSA-p276-g3f3-wwgh, GHSA-94v4-rg25-x625 | `cargo test`, `scripts/audit-rust.sh` |
| Go/Dart/CI dependency bumps | x/crypto 0.58, sqlite 1.60.1, drift_dev 2.35.1, actions | CI |
| T37C passwords and sessions | Argon2id, rehash on login, idle 14 d / absolute 30 d, token rotation at reauth | [`T37C-password-sessions.md`](testing/evidence/T37C-password-sessions.md) |
| T49 miss 6 | Range downloads verify only the chunks they serve: 69 ms → 41 µs for 64 KiB of a 100 MiB blob | [`benchmarks-t49.md`](testing/evidence/benchmarks-t49.md) |
| T49C mobile | 500-message burst 14.7 s → 2.6 s (with the index below); opening a chat 1.7 s → 0.3 s | [`benchmarks-t49c.md`](testing/evidence/benchmarks-t49c.md) |
| Verification sweep | I29–I38 tests added; retention metric and Caddy log leaks fixed; QA01/QA04 verified | [`verification-2026-10-23.md`](testing/evidence/verification-2026-10-23.md) |
| Sync retry | A rate-limited catch-up honours `Retry-After` (was up to 2 min stalled) | `mobile/test/sync_recovery_test.dart` |
| Reauth | A mistyped password in the reauth prompt no longer signs the user out | `mobile/test/app_state_test.dart` |
| T47 observability | Capacity contract with host tiers S/M, privacy-safe metrics (writer wait, disk, data size, backup age, drill result, push timing), a load tool (`scripts/capacity.sh`, `cmd/veritra-load`), alert rules with promtool tests. Tier S passes at 4 msgs/device/min | [`T47-capacity.md`](testing/evidence/T47-capacity.md) |
| T49D admission limits | Per-account limits enforced in the writer transaction: storage, blobs, devices, members, conversations, deliveries per minute, write MiB per hour; a write guard answers 507 when the disk is nearly full | [`T47-capacity.md`](testing/evidence/T47-capacity.md) |
| T46 deploy smoke + k3s rehearsal | Hardened Compose smoke (`scripts/smoke-deploy.sh`, also run by the release command) and a throwaway k3s cluster: deploy, upgrade, rollback, backup, restore drill, full restore. Fixed TURN URL restart loop, VAPID subject, Traefik redirect, Caddy duplicate headers; `GOMEMLIMIT` set | [`T46-deploy-smoke.md`](testing/evidence/T46-deploy-smoke.md) |
| QA02 iOS evidence schema | Simulator CI stays required but can never count as signed-iOS evidence; signed records bind platform, type, commit, digest and attested provenance | [`QA02-ios-evidence.md`](testing/evidence/QA02-ios-evidence.md) |
| Mobile cache index (local schema 9) | Receiving a message with 10k cached rows 23 ms → 5 ms; the upgrade is now one transaction | [`benchmarks-t49c.md`](testing/evidence/benchmarks-t49c.md) |
| Sync from mid-history (capacity tier M) | `ListSyncEvents` merges per-conversation chains and stops after a page of visible events: 172 ms → 2.1 ms per mid-history page; paging past hidden runs is linear (40k events: 16 s → 0.9 s). Tier M now rates 4 msgs/device/min with cold catch-ups (was 2) | [`benchmarks-t49.md`](testing/evidence/benchmarks-t49.md), [`T47-capacity.md`](testing/evidence/T47-capacity.md) |
| Aborted downloads | A download cut by an integrity failure keeps its `http_request` line (`outcome=aborted`) and counts in `veritra_http_aborted_requests_total` | `server/internal/app/aborted_request_test.go` |
| Shared address | Signed-in requests have per-account budgets at an address (D39), so one household member no longer starves the others | [`docs/operations.md`](docs/operations.md#credential-abuse-controls) |
| T49C-1 scoped rebuilds | One state change with a chat open rebuilt 1,233 elements; now 0. A new message in the open chat rebuilds the chat only (352). Release-gate lines unchanged | [`benchmarks-t49c.md`](testing/evidence/benchmarks-t49c.md) |
| T49C-4 tab state | Chat-list offset, unsent drafts and reply targets survive tab switches; drafts stay in memory only | `mobile/test/tab_state_test.dart` |
| T49C-3 snapshot writes | Unchanged rewrite of 10k cached rows 286 ms and 7.3 MiB WAL → 163 ms and nothing written; schema stays 9 | [`benchmarks-t49c.md`](testing/evidence/benchmarks-t49c.md) |
| Local DB upgrade failures | A full disk (`upgradeStorageFull`) and other upgrade errors (`upgradeFailed`) get their own messages; a repeated failure offers the confirmed quarantine reset, so no one is stuck | `mobile/test/app_state_test.dart`, [`docs/crypto.md`](docs/crypto.md) |
| Device transfer | Android `dataExtractionRules`/`fullBackupContent` exclude app data; iOS excludes the database files from backup before and after each open. Not built here (no Android SDK, no Xcode) | `mobile/test/platform_config_test.dart` |
| I31 native outbox | Every payload type goes outbox → HTTP → native decrypt on a second member; fails (not skips) in CI without the library | `mobile/test/native_outbox_test.dart` |
| Release approvals | Approvals live in `release/approvals/<candidate>/`, read from the default-branch tip, landing alone after the candidate (D40) | [`release-approvals-android-i31.md`](testing/evidence/release-approvals-android-i31.md) |
| Android signed release | One Android `signed-release` APK required (D41); CI's APK is `emulator-debug` and never counts; refused until the release certificate is pinned | same |
| T44C Serbian | `app_sr.arb` (Cyrillic, formal "ви") and a generated `app_sr_Latn.arb`; a check keeps them in step | [`docs/design.md`](docs/design.md) |
| Dependency fixes | intl held at 0.20.2 for Flutter 3.44.0 (the #90 bump broke `flutter pub get`); ctutils 0.4.5 for RUSTSEC-2026-0385 | CI |

Earlier work (I01–I28, the Stage 0–5 demo work, T43C, T44A–C, T46 base,
T48A/B, T49A/B misses 1–5) is recorded in Git history and in the evidence
files.

## Open work

Local work that needs no outside party. Pick one, confirm it against the code,
and keep each change small. Missing product features are packages in the
[Build plan](#build-plan).

| Item | What | Notes |
|---|---|---|
| T42B | Native incoming-call lifecycle (CallKit, PushKit, Android Telecom) | Deferred by D16/D20; design in [`docs/call-platform-design-proposal.md`](docs/call-platform-design-proposal.md) needs the owner's approval when it starts |
| Long soak and tier M on real hardware | The 2-hour soak was not run here (shared CPU); tier M was rerun on a quieter shared host | Run `scripts/capacity.sh` on the owner's host |
| Deploy, untested here | Rollback across a schema change, a live R2 restore, cert-manager issuance, Flux reading the real `infra` repo | Try on the first real deployment |
| Serbian review | `mobile/lib/l10n/app_sr.arb` is a machine-assisted draft | A native speaker reviews the Cyrillic file; `scripts/l10n-sr-latn.py` regenerates the Latin one. Android notification text and the iOS camera prompt are native strings and stay English |
| Signing pins | The policy refuses every signed-release record until its pins are set: `android.release_certificate_sha256`, `ios.team_id`, `ios.bundle_id` | Pin them once the signing accounts and keys exist ([`docs/security-review.md`](docs/security-review.md)) |
| Branch protection | `main` and `v*` tags are unprotected, so the approval design's "protected default branch" does not hold yet | Owner: protect `main` and `v*` tags and require code-owner review (`.github/CODEOWNERS` covers the release policy, approvals, workflows and gate scripts) |
| Unbuilt platform code | The backup-exclusion XML and Swift were read, not built; the APK checker is tested only on synthetic APKs | Build in CI or on a Mac; check against a real signed APK |
| Sync bounds per page | The sync handler still calls `SyncBounds` on every page: about 250-280 ms per page for a group whose edges are a blocked sender's run (40k events) | Stored bounds (a schema change), or compute them only for the 409 answer (the app ignores them in a 200) |
| Hidden tail on every poll | The page after the last visible event re-reads every hidden event behind it (removed device, blocked sender: about 200-300 ms at 40k hidden events per poll). Older than this round; the old single scan read more | Return a next cursor (the last row read) in the sync response; needs an API change on both sides |
| Full disk during setup | A disk that fills before the migration starts still shows the wrong-key message | Pre-existing; nothing is lost |
| Clone-restore twin | Resolved 2026-10-31 by D71/D73: backups carry no token, device secret or MLS state, so a restore cannot clone a device; it finishes by device link. Old-format backups drop those parts on restore. Residual: v5 backup files saved before this change still hold the token, device secret and MLS state for anyone who can decrypt them; users should make a fresh backup after upgrading and delete old copies | Prompt for a fresh backup after upgrade |
| Re-sign-in replays history | Fixed 2026-10-31: sign-in as the same account and device keeps the sync cursor when MLS state is present; a new identity or a wiped store still starts at 0. Before, sign-in reset it to 0: after an I45 restore whose session was revoked, the replay stopped sync under I33 ("sync stopped"). A normal session expiry or sign-out hit it too: with 200 or more retained events, sync refetched the first page forever and republished a key package each pass. Since the cursor is now kept, a device signed out longer than event retention gets `device_recovery_required` at sign-in, but only when retention pruned an event it could have been sent. Fixed 2026-10-31 (migration 0044, prune watermarks): the old server check took other accounts' events in the id gap for missed ones, so a quiet single-device account was refused and could only relink ([`docs/crypto.md`](docs/crypto.md), change log) | Tests: `mobile/test/sync_recovery_test.dart` (including sign-in receiving the 409), `server/internal/storage/sync_prune_marks_test.go`, and the demo e2e now signs out, restores and signs in again. Left: a replayed event that is already marked applied is skipped without moving the cursor; nothing resets the cursor behind its markers any more. Still conservative: a pruned event from a blocked sender, a late message from before the device's first epoch, or a plain event (membership, reaction, receipt) from before the account was added to that conversation expires the cursor. The last needs a per-membership join cursor to fix (schema change); cursors into ids pruned before 0044 keep the old check, which refuses every device whose last event is older than the oldest kept at the upgrade (demo databases only). A blocked sender writing into a DM can get an otherwise quiet blocker refused, since hidden events do not move the cursor; the fix is the next cursor in "Hidden tail on every poll". Independent review of 0044 done 2026-10-31: no blockers; its doc and test points are fixed |
| Banner hides backup restore | `connection_banner.dart` never shows the `restoreBackup` choice in `SyncRecovery.choices`, so a single-device account whose cursor really expired can only relink, which needs another device. Not fixed; older than the 0044 work | Add the restore action to the banner (the choice is already in the recovery record) |
| Windows verification blockers | Full test suite cannot pass on this Windows host: release fixtures cannot delete read-only Git objects, app backup tests fail directory fsync, Flutter database fixtures fail cleanup with open handles | The isolated Linux full suite passes; Windows-specific issues remain. Details in [`L0 evidence`](testing/evidence/L0-device-link-v2.md) |
| Bug hunt, not done | Plan `.arbitra/plans/2026-10-25-e5546c4c/`: 106 of 227 fixed. Not started: TASK-011–022 (push bridge, calls), 026–058 (app state, MLS outbox, sync), 079–085, 093–157 (tests, release scripts, restore, CLI, load tool). D53–D56 now answer the questions behind 021, 022, 032/058 and 044 | Skipped with reasons in `PROGRESS.md`: 162, 164, 168, 170, 172, 201, 209; 006, 010, 048 wait for L1. 024 and 061 leftovers fixed 2026-10-31 (backup resume restarts once from byte 0; sign-out fences) |
| Server follow-ups from the bug hunt | `reconcileBlobDeletions` has no time budget; `PruneExpiredContent` does not check `rows.Err`; `SyncBounds` counts expired hidden events. Push target rejections are counted in memory, so a restart only delays retiring a dead target; an FCM project misconfiguration retires subscriptions after 24 h (operators watch the `abandoned` rate). With TASK-204, device-less clients of one account share one backup counter | Small; none blocks |
| MLS key refresh | Built 2026-10-31: each device self-updates a conversation after 100 sent messages, after 7 days with activity, and once soon after joining (jittered; foreground only; D28 staged commits). The server accepts update-only commits from active roster devices, at most one per device per conversation per hour (`PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES`, migration 0043), and answers 409 while a revocation or removal is pending. No ABI bump: an empty change list to `pm_crypto_group_stage_commit` stages the path-only commit; older libraries refuse it. Trust model: "update only" is the sender's declaration, as Added/Removed are today; L1 is the real check | Independent Opus review done; its blocker (a pre-storage 429 on a retried bundle dropped an accepted commit) and follow-ups fixed. Left: add-only commits still carry no path; a join noticed during a background wake waits for the normal spread |
| Research round 2 follow-ups | Decided D60–D63. Done 2026-10-31: attachment size padding (Signal buckets, manifest v2; older apps refuse to open padded files) and post-quantum TLS on the k3s Traefik edge (TLSOption `veritra`; needs Traefik ≥ 3.5, check with a live handshake after the first deploy). Not yet in a package: keep disappearing messages out of K1 backups, AI-assistant screen guard (Android), the app's own PQ TLS (waits for Flutter) | Notes in `research_notes/2026-10-31-deep-*.md` (not committed) and the "Veritra Security Deep Dive" page |
| Sign-out and roster fixes (2026-10-31 reviews) | Fixed: sign-out now revokes the token on the server (it never did: the client was closed before the logout call); a revocation whose coordinator left or was revoked moves to another member device; a deleted account's devices are queued for removal from every group; a server-route delete hides the message's earlier ciphertext from sync. Review follow-ups also fixed: no revocation is queued for a conversation without an MLS group, stale rows are dropped and name no coordinator, one bad revocation no longer fails a client's whole sync pass, and a revoked or deleted device no longer holds a revocation open. Left: a revocation can stop at `commit_submitted` when an account that must confirm it only leaves the conversation (nothing depends on it yet, `docs/crypto.md`); the app deletes with an encrypted action, so the server keeps that message's ciphertext until expiry or event retention | Making the server drop it would tell the server which messages are deletes (new metadata): owner decision if wanted |
| Owner questions from the designs | Answered: K0 (D49, D57), L0 (D50), W7 pins (D58) and mentions (D52), W11 group editors (D59), C0 channel IDs (D51). Still open, built on the written defaults: W7 archive behaviour (stays archived); W11 rotation trigger, 404 revealing a block, refusing plaintext group titles; C0 own group for busy channels | Listed in each design's open questions |

## Release gates

These stay closed until each passes. Never remove `PM_CRYPTO_UNAVAILABLE` or
replace `UnavailableCryptoService` before G25.

| Gate | What it needs | State |
|---|---|---|
| **G24** signed-device evidence | Signed Android/iOS builds of one frozen commit; the two-device matrix in [`docs/security-review.md`](docs/security-review.md#signed-device-matrix-g24) | ⏳ Needs devices, signing accounts, push credentials, a TURN server |
| **G25** independent review | A human reviewer with the brief in [`docs/security-review.md`](docs/security-review.md); fix and retest critical/high findings | ⏳ No reviewer assigned |
| **G27** upstream advisory | RUSTSEC-2026-0330/0331 (libcrux-kem, locked but never built) and RUSTSEC-2026-0387 (crypto-bigint 0.5.5 in the NIST-curve code; Veritra's X25519/Ed25519 suite never runs it) are excepted until **2026-12-31** | ⏳ Waits for an `openmls_rust_crypto` release on hpke-rs 0.8 (0.6.0 is still the latest) |

`scripts/release-readiness.sh` stays blocked until all three pass.

Also before any release: every client runs crypto ABI 9 and mixed ABI versions are refused. An ABI-8 committer that adds a duplicate identity would fork a group and stall ABI-9 receivers under I33 ([`docs/crypto.md`](docs/crypto.md), change log, ABI 9).

## Deployment

Plan from the owner's hosting handbook: single-node k3s on an OVH VPS, a
private `infra` repo that Flux applies, images built locally and pinned by
digest, Traefik + cert-manager, Veritra DNS-only (not through Cloudflare's
proxy), one replica with `Recreate`, the data directory backed up to R2.

| Piece | State |
|---|---|
| Kubernetes base (`deploy/kubernetes/base`) | ✅ One replica, `Recreate`, non-root, read-only root, no service-account token, network policy, backup and restore-drill CronJobs |
| Local release command (`scripts/release-image.sh`) | ✅ Checks, govulncheck, cargo audit, Trivy, push by digest, writes the digest into `infra` |
| Off-host backups to R2 | ✅ Built; first restore from R2 still to be tried |
| Monitoring examples | ✅ Alert rules (backup age, failed drill, disk, WAL, OOM, write refusals, provider failures, certificates) with promtool tests, private metrics scrape, keep-list for a hosted free tier |
| Hardened smoke and k3s rehearsal | ✅ Passed with stand-ins (MinIO for R2, a local coturn); Flux example in `deploy/kubernetes/examples/` |
| **Needed from the owner** | OVH VPS and its firewall, Cloudflare account, domain and a DNS-only record, a Cloudflare DNS token for cert-manager, an R2 bucket with a lock and a per-bucket token, the age key, a GHCR token with `write:packages`, where coturn runs, **one permanent hostname** (clients bind device identity to it), and GitHub branch protection for `main` and `v*` tags with code-owner review |

Details: [`docs/operations.md`](docs/operations.md).

## Standing decisions

Recorded decisions that still apply. Full wording of D01–D30 is in Git history
(`docs/board.md` at `d2d9eb8`).

| ID | Decision |
|---|---|
| D01 | Local database: Drift + SQLite3MC (ChaCha20), random 256-bit key in device-bound secure storage; fail closed on key or cipher failure |
| D02/D27 | Encrypted backup and recovery ship in the first release; backups include decrypted history |
| D03/D16 | Native push and calls are in scope; demos use in-app foreground calls only |
| D04 | Minimal admin audit events |
| D05/D20 | Production stays fail-closed until an independent external review; review, signing and device evidence wait until all three phases are done |
| D06/D10/D21 | One product, one repo, three phases; local demos first on Android, iOS, Windows, Linux; the Flutter app in `mobile/` serves every platform; desktop is never a fork |
| D11/D12 | Demo builds use the real MLS path only via `main_demo.dart`, labelled "Demo · unreviewed crypto"; `http://` only for loopback |
| D14/D15 | Go: latest 1.26 patch (1.26.10). Flutter 3.44.0; `sqlite3` held at 3.5.x until the Flutter pin moves |
| D18 | Coverage floors only move up (Go 50%, Flutter 43%; measured 60%) |
| D19 | Embedded chat stays end-to-end encrypted, so phase 3 ships a client SDK |
| D22/D23/D25 | Message actions are MLS payloads; decrypted text persists at decrypt time; sender credential bound to the envelope (ABI v5) |
| D26 | Desktop key storage: Windows DPAPI, Linux Secret Service |
| D28 | Membership changes are staged commits accepted only on the current epoch (ABI v6) |
| D29 | G27 exceptions for RUSTSEC-2026-0330/0331 until 2026-12-31; RUSTSEC-2026-0387 added on 2026-10-24 (owner) to the same deadline |
| D30 | `flutter_localizations` + `intl` 0.20.2 for localization |
| **D31** (2026-10-23, owner) | Keep GitHub Actions as a free safety net for checks; deploying stays local (release command → `infra` → Flux) |
| **D32** (2026-10-23, owner) | Board, consensus and task queue replaced by this file; review brief moved to `docs/security-review.md` |
| **D33** (2026-10-23, handbook) | The governing principle in `AGENTS.md` applies. Optional PostgreSQL / S3-compatible backends are allowed behind the existing interfaces (SQLite + local files stay the default). NATS stays out. Federation stays out unless the owner makes it a goal |
| **D34** (2026-10-23) | Passwords: Argon2id m=64 MiB, t=2, p=1, at most 3 at once; bcrypt hashes upgrade on login. Sessions: idle 14 d, absolute 30 d, rotation at reauth with a 2-minute grace. Supersedes D17 |
| **D35** (2026-10-23) | OpenMLS 0.9.2 (security patch over D13's 0.9.0) |
| **D36** (2026-10-23) | Blob integrity: a SHA-256 per 64 KiB chunk recorded at upload; reads verify only the chunks they serve; old blobs get a full check once |
| **D37** (2026-10-23) | Release policy v2: exactly one `ios` `signed-release` record from a workflow other than CI, verified by `gh attestation verify`; `simulator-debug` records are checked but never count |
| **D38** (2026-10-23) | Admission limit defaults (tier S): 512 MiB and 10,000 blobs per account, 10 devices, 100 members per conversation, 1,000 conversations per account, 1,000 deliveries per minute, 64 MiB written per hour; instance storage = volume × 0.9 / (backups + 3), at most 10 GiB. All set with `PRIVATE_MESSENGER_LIMIT_*` |
| **D39** (2026-10-23) | Request budgets: a request with a session token is admitted on the address's signed-in budget (1,200/min) and then charged to its account at that address (240/min); a token that does not resolve is charged to the general per-address budget (240/min); credential (10) and enrollment (5) routes, and the public health and setup routes, always use address budgets. Account buckets have their own table. All set with `PRIVATE_MESSENGER_RATE_LIMIT_*` |
| **D40** (2026-10-23) | Release approvals: `release/approvals/<candidate>/{production-crypto,independent-review}.json`, read from the default-branch tip that contains the candidate; each lands alone after it; git is read without replace refs or grafts; manifest schema 3 |
| **D41** (2026-10-23) | Android release evidence mirrors D37: exactly one `android` `signed-release` APK (v2 and v3 signatures, one signer matching the pinned certificate, `minSdkVersion` ≥ 24, not debuggable), attested outside CI; `emulator-debug` records are checked but never count. iOS records also need the pinned team and bundle IDs. APK and IPA zips are refused on comments, duplicate names or a second end record |
| **D42** (2026-10-23, owner) | Second language: Serbian. Cyrillic `sr` is the reviewed source; Latin `sr_Latn` is generated from it |
| **D43** (2026-10-24, owner) | First focus: one-to-one and group chats on Windows. It orders the work only; the release gates and D11/D12 still hold |
| **D44** (2026-10-24, owner) | Communities work like Discord, and Veritra covers the basic features of both WhatsApp and Discord, with privacy first: everything stays end-to-end encrypted and [Stays out](#stays-out) still holds. A gap study sets the list |
| **D45** (2026-10-24, owner) | Work runs on Claude Sonnet 5.5, which hands work to Claude Opus 5.5 when it is unsure or when a mistake would be costly (`AGENTS.md`, Model routing). The [Build plan](#build-plan) lists every missing feature as a package with its route |
| **D46** (2026-10-24, owner) | New plugins approved: `tray_manager`, `window_manager`, `local_notifier`, `desktop_drop`, `pasteboard`, `open_filex` (pins and notices in `pubspec.yaml`, `THIRD_PARTY_NOTICES.md`). RUSTSEC-2026-0387 excepted under G27 |
| **D47** (2026-10-24) | W5 stores delivery cursors and a shared read cursor on the server (migration 0035): when a member's device last caught up in a conversation, only in conversations of ≤ 20 members, never in channels. Turning read receipts off freezes the shared cursor |
| **D48** (2026-10-24, coordinator, owner may veto) | A block hides receipts and delivery state in both directions. DMs and groups from strangers are requests. A fresh device (link, reinstall, restore) accepts only conversations it created; an upgrade accepts what existed. Drafts survive a session expiry and are wiped on sign-out or reset |
| **D49** (2026-10-25, owner) | K0 answers: recovery after losing every device needs the password **and** the recovery key; a recovery waits (and can be cancelled from an active device) when a device was active recently; automatic backups are on by default. The generated emoji data (Unicode License v3) is accepted |
| **D50** (2026-10-26, owner) | Build order: safer device linking (L0), then message actions (W8), history on a new device (K2), then communities (C1-C8). Keep each package complete and checked; prerequisites and release gates still apply. |
| **D51** (2026-10-26, owner) | Community posts may carry a server-visible channel ID for posting rules and retention. Post content and channel names remain end-to-end encrypted. This settles C0's metadata question; the shared-group layout and its sync-isolation prerequisite still need implementation. |
| **D52** (2026-10-27, owner) | Muted chats on phones may receive generic, silent wakeups so mention alerts can be decided locally after decryption. Never make the server mention-aware. Native wake behavior and lifecycle handling must support silence before this is enabled. |
| **D53** (2026-10-31, owner) | iOS pushes for new encrypted events are visible alerts with a fixed, generic localized text ("New message"; no sender, no content), so delivery does not depend on background execution (bug-hunt Q-1, TASK-022) |
| **D54** (2026-10-31, owner) | A peer's application message or call signal that can never be decrypted is committed past with a visible "couldn't unlock this message" placeholder; sync continues for everything else. MLS control messages keep I33's fail-closed rule until a group-fork analysis says otherwise (bug-hunt Q-001 of section 6ba03bc2, TASK-032/058) |
| **D55** (2026-10-31, owner) | No real users yet, so restore drops the legacy VBK1 backup format once the authenticated format ships; no compatibility path (bug-hunt Q-001 of section c6ed5c69, TASK-044) |
| **D56** (2026-10-31, owner) | Calls relay through TURN by default (`iceTransportPolicy: relay`); a user setting may allow direct connections, with a plain warning that the other side then sees their address (bug-hunt Q-2, TASK-021) |
| **D57** (2026-10-31, owner) | K0 recovery key: a random key is the default, and users may choose a passphrase instead. The passphrase path needs Argon2id on the client (a new crate: licence review and `THIRD_PARTY_NOTICES.md` entry before it lands) and a strength floor. Clone-restore is retired once K2 ships |
| **D58** (2026-10-31, owner) | Pins: in groups any member may pin by default, up to 50 pins per chat; a group's admins may restrict pinning to admins and moderators. Supersedes W7's "moderators only, 3 pins" default |
| **D59** (2026-10-31, owner) | Group permissions are open by default and admins may restrict them: any member may change a group's name and photo unless the group's admins limit it to admins. The same rule applies to other group settings (see D58 for pins). Supersedes W11's "owner and admin only" default |
| **D60** (2026-10-31, owner) | Typing, read state and "who reacted" move inside MLS as encrypted application messages, so the server no longer sees them. Reverses D47's server-visible read cursors and typing events once built; Opus designs (MLS ordering, sync, migration) |
| **D61** (2026-10-31, owner) | K2's history-transfer key uses hybrid X-Wing (X25519 + ML-KEM-768) from the first release, so the handoff format never ships classical-only. The server's 32-byte `TransferPublicKey` check and `MAX_HANDOFF` change with it |
| **D62** (2026-10-31, owner) | Post-quantum MLS groups (X-Wing suite in the pinned OpenMLS, `openmls_rust_crypto` feature only) are built and measured behind a switch that stays off until the IETF code point is final and an independent review passes. Never marketed as "quantum-proof" |
| **D63** (2026-10-31, owner) | The K0 passphrase option (D57) stays free-form. Because the server can test guesses offline, the passphrase path uses heavy Argon2id, a strength floor, refuses the account's login password, and tells the user plainly that a weak passphrase can be guessed by whoever holds the server data |
| **D64** (2026-10-31, coordinator; bug hunt TASK-216) | Key-package claims are capped per claimer: one account may claim at most 25 packages of one target device per 24 h (`PRIVATE_MESSENGER_LIMIT_KEY_PACKAGE_CLAIMS_PER_TARGET`, 1–50); the target's own account is exempt. Creating a group past the cap answers 429 `key_package_claim_limit` and takes nothing; adding devices to an existing group skips a capped device, which stays listed so another member (or its own account) adds it later. Accepted cost: one account creating more than 25 groups a day with the same device gets 429. Residual: two accounts can still empty a 50-package pool in a day; invites limit account creation. Follow-up: the 3-minute client fallback lets every member retry a skipped device at once and burn packages; add jitter |
| **D65** (2026-10-31, owner; bug hunt) | Drafts: a debounced, unsaved draft is flushed at sign-out and session expiry before data is cleared (TASK-103). |
| **D66** (2026-10-31, owner; TASK-038) | A backup restore whose restored session the server rejects (401) counts as a failed restore, not a success (VAL-053). |
| **D67** (2026-10-31, owner; TASK-054 Q-004) | The server may tell the client whether a DM already existed (e.g. 200 existing vs 201 created) so the app never builds a second MLS group for it. |
| **D68** (2026-10-31, owner; TASK-039 Q-001) | After a member removal, application sends to that conversation are held until the MLS removal commit is applied. |
| **D69** (2026-10-31, owner) | iOS D53 visible alert is for new messages only; reactions and edits stay silent wakes. |
| **D70** (2026-10-31, owner; C-c7c5faecddbb) | Sealed MLS state is redesigned now (per-group, incremental sealing; new state format) instead of raising caps. Needs an Opus design first; FFI/format change allowed for this. |
| **D71** (2026-10-31, owner; C-7121f7bb1452) | Backups no longer carry the bearer token (and device-cloning credentials); a restore finishes with a password sign-in. |
| **D72** (2026-10-31, owner) | Windows restore: the password-file ACL is not checked; the docs note is enough. Releases build only from `main`. Gradle distribution checksum stays a warning. Load-tool delivery deadline stays 30 s. |
| **D73** (2026-10-31, owner; D70 O1) | Backups also drop the MLS/crypto state (with D71): a restored device keeps history but re-joins group key exchange instead of cloning the old device. |
| **D74** (2026-10-31, owner; D70 O2) | A Welcome whose key package expired or was pruned is skipped with an "ask to be re-added" notice; sync keeps going. |
| **D75** (2026-10-31, owner) | Order: the D70 sealed-state redesign (ABI 10) lands before K2's crypto changes. |
| **D76** (2026-10-31, owner; D69 follow-up) | iOS quiet reactions/edits: the phone decides — an iOS Notification Service Extension decrypts and drops reaction/edit alerts. No cleartext kind hint to the server. Needs Apple's notification-filtering entitlement and MLS state shared with the extension, so it lands after the D70 redesign. `serde_json` (MIT/Apache-2.0) is approved as a direct crypto dependency; list it in THIRD_PARTY_NOTICES. |
| **D77** (2026-10-31, owner) | Until K0's recovery enrollment (password + recovery key) exists, a backup restore finishes only by linking from another signed-in device; someone who lost every device cannot restore yet. K0 recovery enrollment is the next follow-up. D66 no longer applies: a restore no longer brings back a server session. |
| **D78** (2026-10-31, owner; K0 recovery design `docs/designs/K0-recovery-enrollment.md`) | O1: keep the 15-minute I45 backup window until K1. O2: add `ed25519-dalek` (BSD-3) as a direct crypto dependency for the recovery-key proof. O3: 7-day activity window, 7-day wait, 50 failures/day per username. O4: the passphrase option comes after K1. |
| **D79** (2026-10-31, owner; K0 review) | The recovery failure cap (50/day) counts only right-password-wrong-recovery-key attempts, keyed by account or decoy id, answers the same 401 over the cap, and warns the account's devices that the password appears leaked. |

## Roadmap

1. **Phase 1 — mobile** (Android, iOS): demo works; release waits for G24/G25.
2. **Phase 2 — desktop** (Windows, Linux, macOS): additional Flutter targets
   in this repo; built in CI; packaging, signing and update channels are open.
3. **Phase 3 — embedded chat**: a client SDK ([`docs/sdk.md`](docs/sdk.md)),
   end-to-end encrypted (D19). No server-plaintext widget, ever.

## Recommended next

The owner picked the build plan's order (D43, D44); the other items are
recommendations until the owner picks them.

1. **Owner order (D50):** L0 device linking, W8 message actions, K2 new-device history, then communities. Other Windows packages remain open.
2. **Book the independent crypto review.** It gates every release. NLnet's
   open call for privacy work closes **2026-11-03** and may fund it.
3. **Build plan, phase 2:** communities like Discord (C0-C8).
4. **First real deployment** on the handbook's platform, with a restore from
   R2 tried before anyone relies on it.
5. **Run the demos on emulators** (Android) and a Mac (iOS, macOS) once each;
   only Linux has been run by hand.
6. **Build plan, phase 3:** the remaining basics (B1-B9).
7. **Release engineering:** signed, reproducible builds for Play, the App
   Store, F-Droid and desktop, produced locally.
8. **Post-quantum readiness** when OpenMLS ships a reviewed PQ suite.
9. **Optional storage backends** (PostgreSQL, S3-compatible) behind the
   existing interfaces, for larger instances.
10. **A native-speaker review** of the Serbian translation.

## Build plan

Every feature the 2026-10-24 status review and gap study found missing, as
packages in build order, overridden by D50. Pick the first open package whose dependencies are
done, confirm it against the code, and build it as one complete change. A
package is done when its line is true, its tests pass, and `scripts/test` and
`scripts/lint` pass (or CI is green on the PR where a toolchain is missing
locally); then mark it ✅ here. Each line says what the user gets,
so a package can be checked without reading its code.

Route says who does what (D45; `AGENTS.md`, Model routing):

| Route | Meaning |
|---|---|
| **Sonnet** | Sonnet builds it and hands work to Opus only if it becomes unsure |
| **Opus review** | Sonnet builds it; Opus reviews the change before it lands, because it is a second-opinion area in `AGENTS.md` |
| **Opus designs** | Opus writes the design first (in the PR, or in `docs/crypto.md` for anything that changes the protocol), Sonnet builds it, Opus reviews it |
| **Owner first** | The owner says yes before work starts: a new dependency, an account, or a product choice |

Whatever the route, a package that turns out to need a new dependency (a
Flutter plugin, a Go module, a crate) waits for the owner's yes on that
dependency, with the licence review and `THIRD_PARTY_NOTICES.md` update that
`AGENTS.md` asks for.

### Phase 1: chats on Windows (D43)

| ID | Package | Done when | Route |
|---|---|---|---|
| W1 🟡 | Windows run | The demo flow (owner, invite, DM, reply, edit, react, delete) runs on a Windows CI runner, and the owner has run it once by hand | Sonnet; the owner does the hand run — CI part done 2026-10-24: `scripts/test-demo-e2e.ps1` in the `desktop-windows` job; the owner's hand run is still open |
| W2 ✅ | Disappearing messages leave devices | An expired message is gone from the local database, the chat and the chat list on every device, also after an offline restart. Today the app reads `expires_at` but never deletes its own copy | Opus review — 2026-10-24, local schema 10; Opus-reviewed, review fixes in |
| W3 🟡 | Windows notifications | A message arriving while the window is in the background raises a Windows notification, made on the device after decryption; muted chats stay quiet; a setting hides the preview | Owner first (new plugin), then Sonnet — 2026-10-24 with `local_notifier` (owner approved); toasts not yet seen on a real Windows desktop |
| W4 🟡 | Tray and one window | Closing the window keeps the app syncing from the tray; opening it again shows the running window instead of an error | Sonnet — 2026-10-24 with `tray_manager`/`window_manager`; single instance in the Windows runner |
| W5 ✅ | Ticks and typing | Sent, delivered and read ticks and a typing line in DMs and small groups, from what the server already stores; one switch turns your own read receipts off | Sonnet — 2026-10-24, server migration 0035; Opus-reviewed, ticks only in conversations of ≤ 20 members |
| W6 ✅ | Reactions, mute, drafts | Any emoji can react; mute for 8 hours, 1 week or always; drafts survive a restart, kept in the encrypted local database | Opus review — 2026-10-24, local schema 11, server migration 0036; Opus-reviewed, review fixes in |
| W7 ✅ | Message actions design | One payload design for formatting, mentions, forward, pin, polls and other "messages about a message", recorded in `docs/crypto.md` with its payload version | Opus designs — designed 2026-10-24 in `docs/crypto.md` (payload v2), reviewed; step 0 (receive policy) built and Opus-reviewed |
| W8 🟡 | Message actions | Formatting, @mentions that alert even in a muted chat, forward with a label and limits, pin with an expiry, star, delete for me, archive and pinned chats, all on the W7 design | Client actions implemented and full Linux checks pass. Linux: a muted chat's mention notifies after decryption (end-to-end test). Phones (D52): notice decisions and background catch-up wired in Dart behind the guard, still switched off; native capture and platform runs open. Pins follow D58 (50 per chat); the admin-only pin switch waits for C4. See [`W8 evidence`](testing/evidence/W8-message-actions.md) |
| W9 ✅ | Desktop feel | Right-click menus, shortcuts (Esc, Up to edit, Ctrl+F), drag-and-drop and paste of files, several files per send | Sonnet — 2026-10-24 with `desktop_drop`/`pasteboard`; several files go as consecutive messages |
| W10 ✅ | Search on the device | Search finds message text this device holds, through an index inside the encrypted local database; nothing reaches the server | Opus review — 2026-10-24, local schema 12, FTS5 inside the encrypted database; Opus-reviewed, review fixes in |
| W11 ✅ | Profiles | A display name and photo for people, a name and photo for groups, all encrypted, with the key given only to contacts and group members | Opus designs — designed 2026-10-24 in `docs/designs/W11-profiles.md`, reviewed |
| K0 ✅ | One long-lived key | One reviewed design for the key that automatic backups, history on a new device, community history and search over old messages all rely on, so they do not end up with four key schemes | Opus designs — designed 2026-10-24 in `docs/designs/K0-long-lived-key.md`, reviewed; owner questions open |
| K0-R 🟡 | Recovery when every device is lost | Password + recovery key enrolls a new device after a 7-day wait (D77–D79) | Design `docs/designs/K0-recovery-enrollment.md`. 2026-11-01: R2 server (migration 0045, routes, D79 cap, decoys) built and Opus-reviewed, no blockers. Known limit: in legacy (pre-I51) groups a recovered device can again be picked to coordinate or confirm a revocation after retention prunes older MLS messages (docs/crypto.md change log). Deferred: account-level push wake at claim (cancels/claims reach devices on next sync). Left: R1 Rust proof + known-answer vector checked by a Go test, R3 setup screen, R4 recovery flow, R5 review |
| D70 🟡 | Per-group sealed state | Sealing cost grows with one group, not all groups; no total state cap | Design `docs/designs/D70-per-group-sealed-state.md`. S1 Rust storage, S2 schema 16, S3 format 4/ABI 10 + app wiring built and Opus-reviewed (no blockers). S4 built and Opus-reviewed (key-package pruning after a caught-up sync, leave drops the group and its queued messages, -8 `recordLimit` stop that offers to leave). S5 backups done: under D73 no format change; tests show a backup holds no root or record and a restore over a device with records leaves none. Left: evidence; follow-up: a leave racing an in-flight pass that then applies an older add-Welcome keeps the group (record the cursor at leave and skip older Welcomes). Owner check: D74's skip also covers a Welcome naming a key package this device never held |
| K1 | Automatic backups | After saving one recovery key once, the app backs up daily without a tap, replaces the old copy, asks now and then to confirm the key, and can keep a second copy where the user picks | Opus designs (after K0) |
| K2 🟡 | History on a new device | A newly linked device receives the old device's history as one encrypted bundle, or restores it from a backup | Reviewed live-transfer design; internal native primitives/state migration and v3 server enrollment checked. Temporary transfer resource0039 independently reviewed; full Go/race/vet pass. History-only importer schema14/backup5 and ABI8 controls/streams have focused checks and review fixes. 2026-10-31: read-only copied-history view and the transfer download client (HTTPS only, digest checked, partial file deleted on a mismatch) built and tested. Left, in order: encrypted pending-enrollment storage (local schema 17; 16 is taken by D70 S2), NativeCryptoService K2 orchestration on ABI 10, v3 link screens, two-device runs, review. See [`K2 client flow`](testing/evidence/K2-client-flow.md) |
| W12 | Windows release path | A signed Windows installer, an update channel, and a documented HTTPS setup so a second PC can connect | Owner first (signing account) |
| L0 🟢 | Device link v2 | The safety code and a link-confirmation tag are keyed by a secret that travels only in the QR or typed code, so a server cannot substitute the new device; the old device refuses a missing tag. Needed before K2 or anything gated on link approval. Brief and option A (code derived from the secret) in the 2026-10-24 review notes of `docs/designs/K0-long-lived-key.md` | Independent agent design/review; implemented 2026-10-26 (ABI v7, migration 0037). Focused/live checks and full Linux test/lint pass; Windows-specific cleanup/fsync issues remain. See [`L0 evidence`](testing/evidence/L0-device-link-v2.md) |
| L1 | Approved-device list | Existing devices sign the list of approved devices and other members check it before adding one, so a server cannot add a hidden device to an account (today it can; it then reads new messages, never history) | Opus designs (after L0); owner scope |

### Phase 2: communities like Discord (D44)

| ID | Package | Done when | Route |
|---|---|---|---|
| C0 ✅ | Community group layout | A recorded decision, with a measured join cost, on how communities map to MLS groups. The gap study recommends one shared group for open channels plus one per private channel | Opus designs — decided 2026-10-24 in `docs/designs/C0-community-groups.md` with measured cost in `testing/evidence/C0-community-groups.md` |
| C1 | Join and manage members | For groups and communities: invite links whose secret stays after the `#`, join requests an admin approves, leave, remove, rename, and member lists with usernames, all in the app | Opus review |
| C2 | Admin-only posting | In announcement channels and in groups set to admins only, only allowed roles can post: members' apps drop other posts and the server refuses them | Opus review |
| C3 | Private channels and community info | Channels only some roles can see; community, channel and category names, topics and icons stored encrypted, so the server sees IDs only | Opus designs |
| C4 | Custom roles | Roles with permission switches and per-channel overrides, kept in each group's encrypted state and checked by every app | Opus designs |
| C5 | Moderation | Kick, ban with no rejoin, timeout, slow mode, admins deleting others' messages (in groups too), an audit log, and pausing invites | Opus review |
| C6 | Reports | A member reports a message with a proof that it is genuine (message franking): in a community to its moderators, and from a DM or group to the instance owner | Opus designs |
| C7 | History for new members | Each channel sets at creation whether newcomers read old posts; members hand over a channel history key; a new key when someone leaves; posts are signed | Opus designs (after K0, C0) |
| C8 | Bigger communities | The 100-member limit rises in steps, each with a measurement in `testing/evidence/` | Sonnet |

### Phase 3: the remaining basics

| ID | Package | Done when | Route |
|---|---|---|---|
| B1 | Voice notes | Record, send as an encrypted file and play inline; any transcript is made on the device | Owner first (recorder plugin) |
| B2 | Link previews | The sender's app makes the preview and sends it inside the encrypted message; receivers and the server never fetch it; off for unknown sites by default | Opus review |
| B3 | Polls | Polls and votes as encrypted messages on the W7 design; apps count the votes | Sonnet |
| B4 ✅ | Files | Several files per send, a size cap the operator sets, and phones open more than images | Sonnet — 2026-10-24 with `open_filex`; `PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB` |
| B5 | One-to-one calls | A call screen in demo builds on the existing call service, with media through the relay by default to hide addresses | Opus review |
| B6 | Group calls and voice rooms | Encrypted voice rooms and screen share modelled on Discord's DAVE: MLS keys, SFrame frames, a forwarding server that cannot read them | Opus designs |
| B7 | Passkeys and accounts | Passkey sign-in and an in-app account switcher | Opus designs |
| B8 ✅ | Safe defaults | Messages from strangers wait as requests, and nothing from them downloads by itself | Sonnet — 2026-10-24, DMs and groups from strangers; acceptance is per device; Opus-reviewed |
| B9 ✅ | Admin screen | Owners list and suspend accounts and read the audit log, on the existing admin API | Opus review — 2026-10-24; Opus-reviewed |

### Later

| ID | Package | Done when | Route |
|---|---|---|---|
| L1 | More features | Threads and forums, events, bots, stickers and GIFs, stories, broadcast channels, scheduled messages, translation: each becomes its own package when picked | Per package |
| L2 | Server learns less | Padded message sizes, fewer address and time logs, sealed-sender delivery, reproducible signed server builds | Opus designs |
| L3 | Confidential-cloud mode | A server proof hook, switched off, then an optional documented setup that never claims to be operator-proof | Opus designs |

## Stays out

Server-side plaintext of any kind, message-content search on the server,
telemetry and analytics, NATS, and federation (unless the owner makes it a
product goal).
