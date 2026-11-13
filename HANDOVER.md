# Handover (2026-11-12)

Rounds 6, 7 and 8 are on `main` after their PRs merge. Counters: crypto ABI 26 (25 unused), local schema 43, server migration 0093, L1 device list format 2 (D130).

## Done in round 8 (independently reviewed, findings fixed)
- **C7 full mode** (D125–D126): records, rekey, handover, targeted `history_sync` behind `PRIVATE_MESSENGER_C7_HISTORY`, newcomer import with backward walk, paging on demand, former-member labels in backups, bare realtime frames.
- **C3 channel conversion** (D127): earlier posts carry over, private to open asks first, the admin picks readers, request id on the move POST.
- **L2-3 sealed sender** (D128–D129): VOPRF tokens, a session-free post client, owner-only franking with a dedicated key in L1 format 2, proof pins on first use, report pins manual, "Send normally" choice on not-eligible. Switch `PRIVATE_MESSENGER_SEALED_SENDER` stays off.
- Research notes, not in git: `.claude/l2_dv_franking_design.md`, `.claude/l2_deniability_rethink.md` in the main checkout.

## Before turning the new switches on
- G25 independent crypto review, covering: C7 deviations 8–10, targeted delivery, import, decision 11 (move); L2-3 tokens, franking (proof sketch in `docs/crypto.md`), the review checkpoints R1–R3. A ProVerif/Tamarin model of the framing cases was not run (the tool could not be installed here).
- An end-to-end run against a real server: a C7 join with import, a channel conversion, a sealed send with the app killed mid-post, a report.
- An app release that reads `?sealed=1` on every member device; until then the server issues no tokens.
- Re-run T47 capacity: delivery now includes one sync fetch.
- Serbian strings from rounds 7–8 need a native-speaker review.

## Residuals (documented in `docs/crypto.md` and the C7 design)
- **C7:** a member can seal genuine-looking slots over a zero head (a gap, never a leak); round-robin walk fairness holds against one junk sender, not a colluding server plus several members; only the first page of a moved channel's old streams is imported; a forged move event to an unknown destination can move local rows until the next refresh.
- **L2-3:**
  - IP address and timing still identify a sender to a live operator.
  - The server can force a person to choose between sending identified and discarding.
  - Before the first proof pin, the server picks who can verify proofs.
  - Most proofs reach only owners this app pinned.
  - A device linked after tokens were issued misses up to two days of sealed posts.
  - Dev databases that ran a pre-merge sealed branch must be wiped (0090/0091 checksums changed).

## Still open from round 7
- **B6:** camera, screen share, S1, S7, Android foreground service, iOS extension, `call_id` extension, restricting `pm_crypto_group_b6_media_key` to call groups. Residuals: a server-driven remote unmute can bypass the user's mute; a call commit keeping a parent-removed member is not refused.
- **C4 residual:** another device of the leaving account can void a real leave.
- **K1:** the Kotlin and Swift second-copy code was never compiled.
- **L2-1:** an ABI 22 core reading padded blobs is untested.
- **L3:** a real SEV-SNP run; owner choices: `sev-snp-measure`, pinning AMD ARK fingerprints, which confidential-VM host.
- **Search:** a one-word community name that looks like a username is sent to the server on submit.
- **Workflows after D118:** reduce hosted CI to the platforms the dev PC cannot build.

## Release blockers outside code
G25 independent crypto review, G24 signed-device evidence, G27 upstream advisory. The owner's accounts: VPS, DNS, R2, GHCR, TURN, branch protection.
