# Veritra — state

The single record of where the project stands: what works, what is left, the
standing decisions and the release gates. It replaces `docs/board.md`,
`docs/audit-consensus.md` and `implementation/REMAINING_WORK.md`, which remain
in Git history at `d2d9eb8`. Evidence lives in [`testing/evidence/`](testing/evidence/).

**Updated 2026-10-23.**

## At a glance

| Area | State |
|---|---|
| 🔒 Public release | 🔴 **NO-GO by design.** Messaging stays off in release builds until the independent crypto review (G25) and signed-device evidence (G24) pass |
| 🧪 Local demos (real encryption, labelled "unreviewed") | 🟢 Work: server + Linux app run here; Android, iOS, Windows, macOS build in CI |
| 🧰 Local work queue | 🟢 Done, including the 2026-10-23 open-work round. What is left needs the owner or outside parties; see [Open work](#open-work) |
| 🚀 First deployment (k3s, handbook plan) | 🟡 Repo side ready; needs the owner's accounts (see [Deployment](#deployment)) and branch protection on GitHub |
| ✅ Checks | 🟢 Go, Rust, Flutter, contract, demo e2e, release-policy fixtures pass; CI runs on every PR |
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
and keep each change small.

| Item | What | Notes |
|---|---|---|
| T42B | Native incoming-call lifecycle (CallKit, PushKit, Android Telecom) | Deferred by D16/D20; design in [`docs/call-platform-design-proposal.md`](docs/call-platform-design-proposal.md) needs the owner's approval when it starts |
| Long soak and tier M on real hardware | The 2-hour soak was not run here (shared CPU); tier M was rerun on a quieter shared host | Run `scripts/capacity.sh` on the owner's host |
| Deploy, untested here | Rollback across a schema change, a live R2 restore, cert-manager issuance, Flux reading the real `infra` repo | Try on the first real deployment |
| Serbian review | `mobile/lib/l10n/app_sr.arb` is a machine-assisted draft | A native speaker reviews the Cyrillic file; `scripts/l10n-sr-latn.py` regenerates the Latin one. Android notification text and the iOS camera prompt are native strings and stay English |
| Android release certificate | The policy refuses every Android signed-release record until `android.release_certificate_sha256` is pinned | Pin it once the release key exists ([`docs/security-review.md`](docs/security-review.md)) |
| Branch protection | `main` and `v*` tags are unprotected, so the approval design's "protected default branch" does not hold yet | Owner: protect `main` and `v*` tags and require code-owner review (`.github/CODEOWNERS` covers `release/approvals/`) |
| Unbuilt platform code | The backup-exclusion XML and Swift were read, not built; the APK checker is tested only on synthetic APKs | Build in CI or on a Mac; check against a real signed APK |
| Sync bounds per page | The sync handler still calls `SyncBounds` on every page: about 250-280 ms per page for a group whose edges are a blocked sender's run (40k events) | Stored bounds (a schema change), or compute them only for the 409 answer (the app ignores them in a 200) |
| Hidden tail on every poll | The page after the last visible event re-reads every hidden event behind it (removed device, blocked sender: about 200-300 ms at 40k hidden events per poll). Older than this round; the old single scan read more | Return a next cursor (the last row read) in the sync response; needs an API change on both sides |
| Full disk during setup | A disk that fills before the migration starts still shows the wrong-key message | Pre-existing; nothing is lost |

## Release gates

These stay closed until each passes. Never remove `PM_CRYPTO_UNAVAILABLE` or
replace `UnavailableCryptoService` before G25.

| Gate | What it needs | State |
|---|---|---|
| **G24** signed-device evidence | Signed Android/iOS builds of one frozen commit; the two-device matrix in [`docs/security-review.md`](docs/security-review.md#signed-device-matrix-g24) | ⏳ Needs devices, signing accounts, push credentials, a TURN server |
| **G25** independent review | A human reviewer with the brief in [`docs/security-review.md`](docs/security-review.md); fix and retest critical/high findings | ⏳ No reviewer assigned |
| **G27** upstream advisory | RUSTSEC-2026-0330/0331 (libcrux-kem, locked but never built) are excepted until **2026-12-31** | ⏳ Waits for an `openmls_rust_crypto` release on hpke-rs 0.8 (0.6.0 is still the latest) |

`scripts/release-readiness.sh` stays blocked until all three pass.

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
| D29 | G27 exceptions for RUSTSEC-2026-0330/0331 until 2026-12-31 |
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
| **D41** (2026-10-23) | Android release evidence mirrors D37: exactly one `android` `signed-release` APK (v2/v3 signature, one signer matching the pinned certificate, not debuggable), attested outside CI; `emulator-debug` records are checked but never count |
| **D42** (2026-10-23, owner) | Second language: Serbian. Cyrillic `sr` is the reviewed source; Latin `sr_Latn` is generated from it |

## Roadmap

1. **Phase 1 — mobile** (Android, iOS): demo works; release waits for G24/G25.
2. **Phase 2 — desktop** (Windows, Linux, macOS): additional Flutter targets
   in this repo; built in CI; packaging, signing and update channels are open.
3. **Phase 3 — embedded chat**: a client SDK ([`docs/sdk.md`](docs/sdk.md)),
   end-to-end encrypted (D19). No server-plaintext widget, ever.

## Recommended next

The gaps worth filling, most valuable first. All are recommendations until the
owner picks them.

1. **Book the independent crypto review.** It gates every release. NLnet's
   open call for privacy work closes **2026-11-03** and may fund it.
2. **First real deployment** on the handbook's platform, with a restore from
   R2 tried before anyone relies on it.
3. **Run the demos on emulators** (Android) and a Mac (iOS, macOS) once each;
   only Linux has been run by hand.
4. **Product features the handbook promotes** (now required work, not
   "maybe later"): passkeys, multiple accounts, profiles and avatars, local
   (on-device) message search, link previews, voice notes, moderation
   reports, drafts, and post-quantum readiness when OpenMLS ships a reviewed
   PQ suite.
5. **Call UI** for one-to-one calls in release builds (server side exists;
   demo calls are foreground-only) and the native call lifecycle (T42B).
6. **Release engineering:** signed, reproducible builds for Play, the App
   Store, F-Droid and desktop, produced locally.
7. **Optional storage backends** (PostgreSQL, S3-compatible) behind the
   existing interfaces, for larger instances.
8. **A native-speaker review** of the Serbian translation.

## Stays out

Server-side plaintext of any kind, message-content search on the server,
telemetry and analytics, NATS, and federation (unless the owner makes it a
product goal).
