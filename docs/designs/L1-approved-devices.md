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

Native Flutter regressions must begin with approved cached leaves, remove one
from the verified list without changing the MLS tree, and prove sends, calls
and self-updates stop. Check incoming removed verdicts and that an MLS removal
releases the hold. Run inherited Rust VDL1/key-binding tests, server signed-list
and honest-server gates, Flutter pin/store/gate tests, and repository checks.

The full L1 package remains partial: complete adds independent of the server's
device enumeration, recovery-key retype/legacy confirmation UI, authenticated
linked-device anchor failure handling, removed-message UI, long first-contact
chains and independent security review/demo evidence still need work. Work is
performed alone as explicitly requested; no independent review is claimed.
