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

The full L1 package remains partial: discovery when the server withholds an
entire pending conversation, incomplete-join retry/notice,
recovery-key retype/legacy confirmation UI, removed-message
UI, chains beyond the bounded limits and independent security review/demo
evidence still need work. Work is performed alone as explicitly requested;
no independent review is claimed.
