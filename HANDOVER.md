# Handover (2026-11-11), branch `ai/integ`

The work was built by Codex, Gemini and Claude agents. It is 185 commits ahead of `main` and not merged.

**Update 2026-11-11:** `ai/integ` was pushed to `main` directly. The gate failures it brought (3 server tests, 24 app tests, contract drift, gofmt, GO-2026-6859) are fixed on `fix/main-green`, with D115 (admin rekey after moderator removals) and D116 (layout on by default). The reviews below are still needed.

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
- `PRIVATE_MESSENGER_COMMUNITY_LAYOUT` is on by default (owner decision, 2026-11-11), demos included; `0` turns it off, and new communities then show placeholder names only.
- STATE.md has D115–D117 and a Round 6 row. The per-task reports are not in the repo.
- Search: a one-word community name that also looks like a username (e.g. `chess`) is still sent to the server as an account lookup; a local-only "Communities" search mode would close that.
- Review needed: the D95 franking-policy fix and the C4 role calls moved onto `NativeCryptoDevice` (`fix/app-tests`), and D115.

## Release blockers outside code
G25 independent crypto review, G24 signed-device evidence, G27 upstream advisory. Also the owner's accounts: VPS, DNS, R2, GHCR, TURN, and branch protection.
