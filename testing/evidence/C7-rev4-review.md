# C7 revision 4: independent review

Reviewer: Opus, 2026-11-07, of `docs/designs/C7-channel-history.md` revision 4 (PR #112, head `f9d4055`). Verdict: NOT ready (about 75%); the removal floor and the barrier hold. Revision 5 answers each item. Re-check notes are at the end.

1 HIGH server can close exactly the full channels; repair reveals which (decision 5; Trace 1 last variant L453-458; rows 5,7). Trigger: R removed at 20; server withholds A's HS20 from B only; B's fallback HS20' rekeys alone; B's next HS reports seq 6 -> row 7 on others. Only full channels have rekey slots so only they close; admin live switch (row 5) then puts record-shaped msgs in exactly full channels (I5 leak + cheap history DoS). Minimal fix: settle rekey-vs-rekey conflicts deterministically (same seq+prev, both opened >= floor; e.g. lower hash wins; loser kept read-only). Larger: derive rekeys from MLS exporter secret at removal epoch (new ABI fn; owner/ABI review call).
2 HIGH "g above every earlier g" (L179) contradicts Trace 2 step 7 (L472): P's and Q's seq-2 records both g=2 -> fork report becomes invalid instead of row 7; duplicate rekeys become invalid instead of row 4. Fix: compare g only to the record named by prev when held; pin in vectors.
3 HIGH newcomer state undefined (L225-235, 246-252, 213-217): unsure/closed sender gives random key_c with real head -> newcomer holds head with no key, counts fresh (floor unset). Newcomer that missed a pre-join removal computes different stale_since, rejects honest rekey, next record closes (row 7). Fix: newcomer floor/removal history starts at join epoch; add "head, no key" status behaving like unsure for key use; for generations opened before join accept any close_epoch in (E_open, join_epoch].
4 MED record messages visible size class (L156-161; residuals L559): estimate history_change ~1024-1280 bucket vs short posts 256-512 (docs/crypto.md:1322-1333; estimate only). Odd count of switch-sized admin msgs predicts mode. Fix: list in "What the server still learns" or shrink record into common bucket. Compute exact VAP1 size.
5 MED row 5 "or status closed" lets old switch reopen (L193): server delays Q's lost switch-on to D until D closed; D adopts it, seals under discarded key. Fix: require X.seq > highest seq D has seen for channel; Trace 2 step 8 still passes.
6 MED device missing a record stays out of step and hands that to newcomers (L289-298): fully withheld envelope triggers nothing; unsure clears via row 3 even when clearing record is the concurrent loser; HS from lagging device is row 2 no-op for others while its newcomer got a switched-off-period key. I1 holds, I4 not. Fix: list as residual; signed g differing from reader's current generation = unsure/closed trigger; clear unsure only on a record whose epoch is after the triggering message.
7 MED moderator delete not covered (decision 7 L360-370, L519-522; C5 design L38): C5 redacts like deleteMessageEnvelope which C7 answers 409 in communities; history-route hide covers author deletes only; C5 redaction/audit shows target id -> new moderator deleting pre-join post reveals full. Fix: server-checked moderator hide + residuals row.
8 MED own proposals (L200-203): chaining a second proposal on own pending one; losing first race makes second row 7 (honest race closes). Fix: chain only from applied head; tell actor when switch loses under row 4; auto re-propose when lost to a rekey.
9 LOW-MED signatures (decision 8): inspect_commit (crypto/rust/src/mls.rs:1114-1129) compares identity only — planned check that an Update keeps signature key is required, with test. Live sig check not needed for authenticity (reference binds sha256(body) under MLS). Newcomers check signed g matches generation of key that opened body.
10 LOW C7 head/key/status writes in same local transaction as MLS state (crash otherwise loses record silently).
11 LOW revocations wait fallback jitter when committer offline; device with pending commit can send own HS at once (same in every mode).
12 LOW moves: move record has no carrier for the wrap; cap move close_epoch at stale_since.
13 LOW residuals row on held edits: server can also force unsure by stripping one body, holding edits only in full channels up to 24h.
Order: fix 1-3 first, 4-8 before build step 4 (Dart).
Verify: exact VAP1 size of history_change; vectors rows 2,4,7 with equal g; test withholding one HS from one device closes no channel; newcomer added by unsure committer; Update changing signature key refused.

## Re-check (2026-11-07, revision 5 author)

- 1, 2, 5, 6, 8, 11, 12, 13: confirmed against the revision 4 text (validity rule "g above every earlier g", rows 5 and 7, Trace 1 last variant, Trace 2 step 7).
- 3: confirmed; revision 4 gave newcomers no floor rule and no state for "head without key".
- 4: computed exactly with Dart's compact `jsonEncode` shape (ids: `conv_`/`dev_`/`chan_` + 32 hex, 48-hex action id): revision 4's `{record: base64(512), key: base64(32)}` is 1,043 bytes framed, a 1,280-byte VAP1; the smallest community post (empty text) is 280 bytes framed, a 512-byte VAP1.
- 7: confirmed; C5 (`docs/designs/C5-moderation.md:38`) redacts like `deleteMessageEnvelope`.
- 9: confirmed; `inspect_commit` (`crypto/rust/src/mls.rs:1114-1129`) compares identity only, not the signature key.
- 10: confirmed; revision 4 did not say C7 state commits with the MLS state.
