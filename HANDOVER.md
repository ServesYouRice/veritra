# Handover (2026-11-11), branch `ai/integ`

The work was built by Codex, Gemini and Claude agents. It is 185 commits ahead of `main` and not merged.

**First:** run `.claude/hooks/check.sh`. The last rounds skipped tests and reviews on the owner's instruction. Then fix what fails, get the reviews below done, and open a PR to `main`.

Counters: crypto ABI 22, local schema 36, server migration 0084.

## Never tested or reviewed (second-opinion areas in AGENTS.md)
- C3 (key by MLS epoch, plaintext-name refusal, migration 0082)
- C7 server routes (migrations 0083 and 0084, flag `PRIVATE_MESSENGER_C7_HISTORY` off) and the Dart step 4/5 slice; its tests are written but never run
- C4 (commit receive staging, removal proofs), C5 and C6 (per-moderator sealed reports)
- L1 (complete-adds audit, join notice, recovery-key retype)
- K1-6 (VBK2 and token route retired, migration 0081)
- B6 (ABI 22, rooms, LiveKit tokens; Opus review was stopped part-way)

## Open items
- C7: records, generation keys, key handover in history_sync, keyless/unsure, newcomer import and prefetch. These were waiting for C4, which has now landed.
- C3: channel conversion (C7 `move`).
- C4: server succession after an election is won.
- C5: apps do not refuse a timed-out member's post; only the server does.
- C6: moderator keys need a manual trust tap instead of MLS authentication; a departed moderator keeps copies already received.
- L1: a marker on messages from a removed device; tests for the four new flows.
- K1: the second copy on Android and iOS; K1-7 recover-and-restore e2e.
- B6: media transport (`livekit_client` needs licence review) and the demo factory that sets `AppState.roomSession`.
- L2: padding (needs an ABI bump), sealed sender, own-device alert. L3: `verify-attestation.sh` and a tested confidential-VM recipe.
- Owner decision: with `PRIVATE_MESSENGER_COMMUNITY_LAYOUT` off (the default, and in demos), new communities show placeholder names only.
- STATE.md is not updated for this round. The per-task reports are not in the repo.

## Release blockers outside code
G25 independent crypto review, G24 signed-device evidence, G27 upstream advisory. Also the owner's accounts: VPS, DNS, R2, GHCR, TURN, and branch protection.
