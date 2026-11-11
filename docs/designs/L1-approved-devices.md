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
This slice does not make the session, MLS identity and genesis pin one atomic
write; a crash or local storage failure between those writes remains open.

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

The full L1 package remains partial: complete adds independent of the server's
device enumeration, recovery-key retype/legacy confirmation UI, authenticated
linked-device anchor failure handling, removed-message UI, chains beyond the
bounded limits and independent security review/demo evidence still need work. Work is
performed alone as explicitly requested; no independent review is claimed.
