# Handover (2026-11-11)

Rounds 6 and 7 are on `main` after their PRs merge. Counters: crypto ABI 24, local schema 40, server migration 0087 (D123).

## Done in round 7 (independently reviewed, findings fixed)
C3, C4 (succession, held commits, leave proof D118, removed-device limits D119), C5 timeouts, C6 MLS moderator keys (D120), C7 steps 3–5 server tests, L1 marker and tests, K1 phone second copy and K1-7, K0-R recovery notice, B6 voice media (demo builds), L2 padding and own-device alert, L3 attestation script.

## Open
- **C7 full mode:** records with C4 authority, per-channel chain state, generation keys, `history_sync` slots, keyless/unsure states, newcomer import and prefetch, backward walk. Then **C3 channel conversion** (C7 `move`), which depends on it.
- **L2 sealed sender** with VOPRF credentials (D122): new crypto dependency on app and server (licence check), and how sealed messages fit C6 franking.
- **B6:** camera, screen share, S1, S7, Android foreground service, iOS extension, `call_id` extension, restricting `pm_crypto_group_b6_media_key` to call groups (ABI change). Confirm on devices: a forced reconnect sends only encrypted audio; bind/rebind plays and does not crash.
- **K1 / native code:** Kotlin and Swift for the phone second copy were never compiled; build both apps and test the folder pick and iOS export.
- **L2-1:** an ABI 22 core reading padded blobs is untested.
- **L3:** real SEV-SNP run with evidence; owner choices: may `sev-snp-measure` be used, pin AMD ARK fingerprints in the repo, which confidential-VM host.
- **Search:** a one-word community name that looks like a username is sent to the server on submit; a local-only "Communities" mode would close that.

## Release blockers outside code
G25 independent crypto review, G24 signed-device evidence, G27 upstream advisory. The owner's accounts: VPS, DNS, R2, GHCR, TURN, branch protection.
