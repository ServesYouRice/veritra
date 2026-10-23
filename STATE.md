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
| 🧰 Local work queue (former `implementation/`) | 🟢 Done. See [Open work](#open-work) for what is left |
| 🚀 First deployment (k3s, handbook plan) | 🟡 Repo side ready; needs the owner's accounts (see [Deployment](#deployment)) |
| ✅ Checks | 🟢 Go, Rust, Flutter, contract, demo e2e, release-policy fixtures pass; CI runs on every PR |

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
rows marked in progress below and the items under [Open work](#open-work).
The runtime sweep on 2026-10-23 ([`verification-2026-10-23.md`](testing/evidence/verification-2026-10-23.md))
added tests for the acceptance criteria that had none and fixed what they found.

| Work | Result | Evidence |
|---|---|---|
| OpenMLS 0.9.0 → **0.9.2** | Fixes GHSA-gc79-23g3-8g52, GHSA-p276-g3f3-wwgh, GHSA-94v4-rg25-x625 | `cargo test`, `scripts/audit-rust.sh` |
| Go/Dart/CI dependency bumps | x/crypto 0.58, sqlite 1.60.1, drift_dev 2.35.1, actions | CI |
| T37C passwords and sessions | Argon2id, rehash on login, idle 14 d / absolute 30 d, token rotation at reauth | [`T37C-password-sessions.md`](testing/evidence/T37C-password-sessions.md) |
| T49 miss 6 | Range downloads verify only the chunks they serve: 69 ms → 41 µs for 64 KiB of a 100 MiB blob | [`benchmarks-t49.md`](testing/evidence/benchmarks-t49.md) |
| T49C mobile | 500-message burst 14.7 s → 3.8 s; opening a chat 1.7 s → 0.3 s | [`benchmarks-t49c.md`](testing/evidence/benchmarks-t49c.md) |
| Verification sweep | I29–I38 tests added; retention metric and Caddy log leaks fixed; QA01/QA04 verified | [`verification-2026-10-23.md`](testing/evidence/verification-2026-10-23.md) |
| Sync retry | A rate-limited catch-up honours `Retry-After` (was up to 2 min stalled) | `mobile/test/sync_recovery_test.dart` |
| Reauth | A mistyped password in the reauth prompt no longer signs the user out | `mobile/test/app_state_test.dart` |
| T47 observability | _in progress_ | |
| T49D admission limits | _in progress_ | |
| T46 deploy smoke + k3s rehearsal | _in progress_ | |
| QA02 iOS evidence schema | _in progress_ | |
| Mobile cache index (local schema 9) | _in progress_ | |

Earlier work (I01–I28, the Stage 0–5 demo work, T43C, T44A–C, T46 base,
T48A/B, T49A/B misses 1–5) is recorded in Git history and in the evidence
files.

## Open work

Local work that needs no outside party. Pick one, confirm it against the code,
and keep each change small.

| Item | What | Notes |
|---|---|---|
| I31 | A test that sends MLS payloads through the real native library from the outbox | Only gap left in the sweep |
| T49C-1 | The whole app rebuilds on every state change (1,233 elements with a chat open) | Needs a scoped listener in `main.dart`; touches the release-gate file, so review the gate lines stay as they are |
| T49C-3 | The cached ciphertext snapshot is rewritten in full on restore/open | Storage design change |
| T49C-4 | Chat-list scroll position, an unsent draft and the reply target are lost when switching tabs (wide layout) | Recommended: keep them |
| T44C | A second app language | English only today; needs a native-speaker review |
| T42B | Native incoming-call lifecycle (CallKit, PushKit, Android Telecom) | Deferred by D16/D20; design in [`docs/call-platform-design-proposal.md`](docs/call-platform-design-proposal.md) needs approval when it starts |
| Downloads | An aborted download (integrity failure mid-stream) skips the normal request log line and metrics | A `blob_integrity_failed` warning is still logged |

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
| Monitoring examples | ✅ Alert rules and private metrics scrape; T47 adds more (in progress) |
| Hardened smoke and k3s rehearsal | _in progress_ |
| **Needed from the owner** | OVH VPS, Cloudflare account and domain, an R2 bucket with a lock and a per-bucket token, the age key, a GHCR token with `write:packages`, and **one permanent hostname** (clients bind device identity to it) |

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
8. **A second app language**, reviewed by a native speaker.

## Stays out

Server-side plaintext of any kind, message-content search on the server,
telemetry and analytics, NATS, and federation (unless the owner makes it a
product goal).
