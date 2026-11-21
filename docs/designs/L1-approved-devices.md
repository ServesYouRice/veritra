# L1 approved devices: integration and current-list judgments

This package reuses the signed VDL1 protocol and implementation from
`origin/agent/l1-core`, `origin/agent/l1-server` and
`origin/agent/l1-3-mobile`, all already ancestors of this worktree's base.
The normative format, signing rules, recovery and trust-on-first-use limits
remain in [the original design](L1-approved-device-list.md).

## Tested slice

An approval verdict is a cache, not permanent authority. Before encrypting an
application payload, call signal or self-update, rejudge every current MLS
leaf against its account's latest locally verified pin. Refresh lists through
the existing per-account rate limit and bounded group network budget. Do the
same before deciding an incoming sender's verdict and after membership changes.
Keep the Welcome participant check and the local device's existing self-key
check. Never use a server roster or pending-change response to clear a hold.

A signed removal changes a previously approved leaf to `removed`. While that
leaf remains in the MLS tree, hold outgoing encryption. An MLS removal clears
the hold. Existing policy continues to display incoming messages from formerly
approved devices; never-approved or conflicting senders remain hidden. Sync
and removal commits continue while held. A server withholding a signed removal
can delay its discovery; this slice does not provide key transparency.

No wire format, ABI or database structure changes are needed for this slice.
Do not consume the assigned ABI 24, local schema 41 or migration 0074 merely
to rename existing working structures. No dependencies or release gates change.

## Verification and remaining work

### Signed-list add discovery (2026-11-11)

For conversation creation and each pending membership change, read the
conversation's member accounts, refresh their verified lists, and derive
candidate devices from those lists. Subtract identities already in the native
MLS tree (or this device before group creation). Do not use the server's add
array or claim-all response as the device inventory. Claim packages by these
explicit device IDs. Reject returned packages for unrequested account/device
pairs or repeated device IDs; partial answers may stage the available devices.
The native add gate still binds each package to the currently pinned key.
Each batch is capped at the existing 256-change bundle limit. The server's
explicit-claim route also permits current member devices before any group
roster or legacy MLS message exists, matching first-bundle authorization.
After initialization, it still requires an active MLS leaf. It verifies the
requester's device belongs to the authenticated account and is not revoked.

Discovery shares the existing bounded list-refresh policy: a group network
budget and per-account timeout, then stored verified pins only. Missing lists
and conflicts authorize no adds; removals remain possible. An existing leaf
with a different key is never added again under the same identity; the approval
hold handles it. No ABI, schema, migration or dependency change is required.

This slice covers omitted devices in a reported pending conversation and at
creation. Detecting an entirely omitted pending conversation, retries when no
reported change remains, and the one-hour incomplete-join notice remain open.
The account membership roster itself still belongs to C1/C4; this does not
turn the server's account roster into cryptographic authorization.

### Complete adds without a reported change (2026-11-11)

A server can omit a conversation from `GET /mls/pending-changes` entirely, so
discovery cannot run only on reported changes. After each catch-up, the app
audits conversations it holds a group for that the last pending-change read
did not report: at most 8 per pass, each at most every 15 minutes, oldest
first. An audit runs the same signed-list discovery as above. A gap must last
the reconcile fallback (3 minutes) before this device claims and stages,
which gives an honest server's pending change and its coordinator the first
turn. Two devices that act together race on the epoch; the loser's bundle is
refused and dropped as today, at a cost of one claimed package per missing
device. A failed audit waits a full interval. The server refuses a whole
explicit claim (403) when one named device is revoked or off its head. A
stale pin can still list such a device until repair, so on a 403 each device
is claimed alone, and refused ones are skipped. One such device therefore
cannot keep its siblings out. The audit runs on catch-up,
with no timer of its own.

Review fixes (2026-11-11). A reported change counts as covered only once
its discovery has finished in that pass. A change listed at a stale epoch,
still backing off, or waiting for its coordinator therefore does not keep
the audit away from its group. Discovery examines the server's member
accounts and also every account that already holds a leaf in the local
tree, so a server that leaves an account off the member list cannot hide
that account's new devices. An account the change removes, and that the
member list no longer names, is left out: a departing account never gains
a device. A device revoke keeps its account, so the siblings still join.

### Incomplete-join notice (2026-11-11)

Each discovery pass that completes (reported change or audit) records, per
conversation, the accounts that have an approved device outside the tree.
Only the tree resolves a gap. A claimed package or a staged commit does not,
because the server may refuse the bundle or never sequence it. The first time a gap was seen is kept and persisted in
settings (`l1.missing_joins`, conversation, then account, then milliseconds).
A restart therefore cannot reset the clock. A pass that finds an account
complete clears it, and a failed discovery leaves the record unchanged.
After 1 hour the chat shows "Some of <name>'s devices haven't joined yet".
Missing or conflicting lists authorize no adds and produce no notice; the
approval hold and the list states cover those. No schema change is needed.

### Recovery retype and pre-L1 recovery-key confirmation (2026-11-11)

The held seed can be gone (an unreadable pending state), or the head's
recovery key can differ from it. In either case `pm_crypto_l1_sign_recovery`
refuses and K0-R completion posts nothing. A recovered device whose own
verified pin does not list it then shows "Type your recovery key again to
finish recovery" in Settings. The typed key is decoded and passed as entropy
to the same native call, which still checks the body, the chain step and the
head's recovery key. Nothing derived from it is kept, and the entropy is
wiped after the call. The signed statement goes through the existing
store-then-post retry path. Review fix: a `device_list_conflict` answer
means another version landed first. If the refreshed head does not name
this device, and the stored statement's `prev_hash` is not the head's list
hash, the stored statement can never be taken. It is then dropped, so the
retype prompt returns and the next statement is signed on the current
head. A stored statement that still chains on the head is kept.

An account whose verified head names no recovery key, while the server
reports one configured, has a pre-L1 key, and recovery is refused for it. In
that case Settings shows "Confirm your recovery key to keep recovery
working". The typed key's `rk_id` is compared in constant time with the
server's, and a mismatch sends nothing. On a match, the app sends
`PUT /account/recovery-key` with the same `rk_auth_pub` and `rk_id` and a
change-5 version naming `rk_list_pub`, with recent auth. The same `rk_id`
keeps K1 backups. This reuses existing routes and calls, and needs no
counter.

### Durable enrollment anchors (review follow-up)

Before saving a new setup/registration session, write its locally signed
genesis to an encrypted, identity-scoped activation journal. After saving the
session, replay that journal into the pin store before activating MLS or
publishing the session in memory. Cold start and background restore replay
the same journal before activation. Pin-write errors stop activation and keep
the journal; they never authorize own-account TOFU. Clear the journal only
after the pin and MLS activation succeed. This uses existing settings storage.

For linking, retain the frozen pending enrollment until journaled promotion.
Download and verify the complete chain without persisting it. Require the
new device's exact key to be currently approved, and its original add to be
signed by the exact approver key in the frozen authenticated link context.
Presence of both keys somewhere in the chain is insufficient. Journal the
validated chain before promotion, replay it after promotion (which can clear
old identity pins), and only then expose the session. Failed downloads,
validation, journal writes or pin writes cannot activate the linked device.
An interruption leaves either the pending claim or the activation journal
for retry; neither retry uses own-account TOFU.

### Imported-chain continuity (2026-11-11 review)

Whole-chain verification proves internal consistency, not permission to
replace an existing trust anchor. When importing a chain into an account
that already has a pin, require the exact pinned statement at its version.
Reject shorter chains, alternate genesis chains, forks and sticky conflicts.
An identical head is a no-op; a valid extension still uses the store's
compare-and-swap write. Test these rules with real native signatures.

### Locally signed genesis (2026-11-11)

After setup or registration succeeds, pin the genesis this device signed
without first asking the server whether a list exists. An empty, missing or
unavailable server response cannot authorize discarding the local trust
anchor. Later refreshes may advance only from that genesis. This also means
an old server that ignores the submitted genesis cannot silently move the
new account onto a different chain; the server must accept the signed chain
before list-dependent operations can proceed. Existing accounts with no
locally signed genesis still use the migration review flow.

Test both setup and invitation registration with real native signatures:
the server withholds the list, then serves an attacker-signed genesis. The
original pin must persist and the attacker must stay unapproved. Check a
failed list read as well. This changes no wire format or storage structure.
The enrollment-anchor follow-up below adds a write-ahead journal so a crash
or storage failure between the writes cannot cause own-account TOFU. A crash
before the first MLS identity save can still require explicit relinking.

### Long chains (2026-11-11)

Separate the native batch limit (256 statements per chain call) from the
client download limit (4,096 statements per refresh). Verify the first batch
with the native chain verifier, then each remaining statement with the native
step verifier and the complete accumulated pair history. The native history
limit (1,024 pairs) still applies. Use this same verification for first contact,
authenticated chain import and fork proofs. Persist a first-contact pin only
after the entire downloaded chain verifies. Pinned catch-up keeps its existing
rule: a bad signed step stops advancement at the last verified prefix.

Downloads remain bounded, sequential and paginated; reject gaps, false final
heads, empty continuation pages and chains over the download limit. Network
failure leaves the previous durable pin intact. No ABI, schema or migration
change is needed: this composes existing native verification calls. Chains
beyond the download/history limits still fail closed and need a later streaming
design; the new limit is not a claim of unbounded chain support.

Native Flutter regressions must begin with approved cached leaves, remove one
from the verified list without changing the MLS tree, and prove sends, calls
and self-updates stop. Check incoming removed verdicts and that an MLS removal
releases the hold. Run inherited Rust VDL1/key-binding tests, server signed-list
and honest-server gates, Flutter pin/store/gate tests, and repository checks.

### Removed-sender mark (2026-11-11, local schema 40)

The receive path records the sender leaf's verdict on the stored row:
`local_messages.sender_removed` is set when the verdict is `removed`. The
chat shows "Sent from a device <name> removed" (or "Sent from a device you
removed") above the text, in DMs too, and the bubble's spoken label says the
same. An edit from a removed leaf sets the mark on its target; an approved
edit leaves an earlier mark. History snapshots carry the mark as an optional
`senderRemoved: true`. The upgrade adds the column first in the upgrade
transaction (older steps read through the current rows) and is idempotent.
Not covered: a deferred edit from a removed leaf (target not yet here) is
applied unmarked when its target arrives; reactions are not marked.

Flow tests (2026-11-11). `mobile/test/l1_app_state_lists_test.dart` uses
the native engine to cover:
- the audit: explicit claim, fallback wait, 8 per pass, 15-minute
  interval, and the per-device fallback on a 403;
- the review fixes: a stale-epoch change, an account left off the member
  list, and a stored recovery statement past the head;
- the notice across restarts: a refused bundle keeps the gap, and clocks
  of another identity are ignored;
- the retype with a right key and a wrong key;
- the pre-L1 confirmation: mismatch, recent auth, and change 5 with the
  same `rk_id`.

Seven code mutations (the three fixes, the gap rule, the 403 fallback, the
batch size and the owner check) were each caught by the matching test.

### Hold states and the conflict reset (2026-11-21)

The approval hold was enforced but not explained: a held chat only showed
an error when a send failed. The chat now shows one banner per account
that holds it, read from the stored leaf verdicts and that account's pin
(local reads only, at chat open, after every sync pass and when a send is
refused by the hold). The most
serious reason wins: conflict (the pin is in conflict), never approved,
removed, waiting (no pin, and the last fetch found no list: an account
from before L1), checking. The own account is worded apart ("A device you
didn't approve was added to this chat"). "Check again" fetches the held
accounts' lists past the one-minute limit (at most every 5 seconds per
chat, each fetch bounded at 10 seconds) and judges the group again. A
banner never approves anything: only a verified pin or an MLS removal
releases the hold, as before.

A contact's conflict is sticky, and until now nothing could clear it. The
design says the person clears it after comparing safety numbers, and the
app "re-pins from that branch's version 1". Done naively (drop the pin,
fetch again) that is trust on first use under the server's choice, which
the 2026-11-08 owner decision rejected for chains from another genesis. So
the reset is narrower, and has two steps so the person confirms exactly
what is pinned:

- `prepareServedBranch` reads and verifies the branch the server shows,
  applies the rules below and writes nothing. It counts the devices the
  branch lists that were not on the list as pinned before the conflict (a
  device the pinned branch removed counts as new). While the conflict
  lasts every device of the account is held, so trusting even the pinned
  branch releases devices; the count is the change from the list before
  the conflict, which is what the person last had confirmed. The warning is shown only after
  this, and states that count: trusting the list approves them, and they
  can be added to chats. A refused branch shows "nothing changed" without
  a warning.
- `commitServedBranch` pins exactly the prepared chain, never one fetched
  after the confirmation, so a server that switches branch while the
  dialog is open changes nothing. It checks every kept fork proof again
  (one recorded meanwhile must hold too), and the store's compare-and-swap
  writes only while the stored pin is still the conflicted head the plan
  was made from.

The rules:

- Only another account's list. The own list is its own authority; a fork
  there keeps today's error.
- The whole served chain is fetched and verified first (native chain and
  step checks, as at first sight). Only then does one compare-and-swap
  replace the pin, and only while the stored pin is still in `conflict`
  with the same list identity and the same conflicted head. Any failure leaves the conflict exactly as
  it was; the account is never left without a pin, so a later refresh can
  never become a first sight.
- The chain must have the pinned list identity and, at every version a
  fork proof was kept for, carry one of that proof's two statements. A
  statement fixes its whole prefix through `prev_hash`, so the reset can
  only choose between the two branches a listed key actually signed. A
  server holding no listed key gains nothing from it. One holding a stolen
  listed key made the second branch, and can serve it at reset time: the
  person may then accept the thief's branch. That is the human decision
  the design leaves them, which is why the warning asks the contact to
  check their devices first.
- At the conflicted head's own version the chain must carry that head, or
  a statement a proof recorded at exactly that version names (review,
  2026-11-21). A proof can lag the head: a refresh that found the fork at
  version v writes the conflict state on whatever head is stored, and a
  forced refresh racing it can have moved the pin to v + n meanwhile. The
  proof at v alone would accept the pinned branch cut back to v (a
  rollback that approves again what v + 1 .. v + n removed) or a branch
  forked between v and the head. With the rule a lagging proof allows only
  the pinned head and what grows from it, and no reset ever pins below the
  conflicted version. Rows the earlier code wrote are covered the same way.
- The warning also says when the branch names another recovery key than
  the conflicted pin. A change 5 by a listed key can set one without
  listing any new device, and the recovery key can later sign a recovery
  version that replaces every device; a count of 0 alone would understate
  that.
- The proofs are kept. The first-pin time restarts (review M2: a re-pin is
  a new first sight for report verdicts). Stored L2-5 alerts stay and are
  judged against the new pin as usual. Held chats are judged again.

What the person is told is honest about the limit: matching safety numbers
show that both see the same devices in the chat (the number comes from the
shared MLS tree), not which list branch is real. The warning asks them to
have the contact check and remove devices they don't recognise first.
Without a listed key's second signature there is no conflict to reset; a
contact who keeps a stolen device listed is outside what L1 can fix.

No ABI, schema, migration or dependency change: the existing pin and
proof tables suffice.

### Adversarial evidence (2026-11-21)

`mobile/test/l1_adversarial_test.dart` runs real OpenMLS clients that sign
real lists and keep real pins against a hostile fake server, covering a
server-injected device, rollback, forged signatures (and a real fork with
the reset) and a removed device coming back.
`mobile/test/l1_conflict_reset_test.dart` pins every reset rule on both
stores. Results and the mutations each test catches are in
[`L1-adversarial.md`](../../testing/evidence/L1-adversarial.md).

The full L1 package remains partial. Still to do:
- chains beyond the bounded limits (they fail closed);
- the live demo run against the real server binary (a ghost row and key
  package written into the stopped server's database), which needs a Go
  build and the e2e harness;
- the independent security review, which must include the conflict reset.

No independent review is claimed.
