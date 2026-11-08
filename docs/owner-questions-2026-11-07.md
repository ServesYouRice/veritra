# Owner quiz: open bug-hunt items (2026-11-07)

Source: `.arbitra/plans/2026-10-25-e5546c4c/PROGRESS.md`. One question per
item still open. The first option is recommended. Answer with the item
number and a letter, for example `12 A`.

Already decided and ticked, so no question: TASK-039 (D68), TASK-103 (D65),
TASK-125 (D72), check 24 (D71/D73), check 37 (D70).

## Crypto and device linking

**06 (TASK-006). Who may add devices to a chat?**
Today a chat accepts a new device on its own say-so. The approved-device list (L1, D94) fixes that, but it is still being built.
- A. Keep real messaging blocked in releases until the list is checked on every add (recommended).
- B. Ship an interim rule that only accepts devices the account owner's phone already knows.
- C. Accept the current behavior in demos only, with a visible warning.

**10 (TASK-010). Device-link code: build the extra "commit first" step now?**
Linking a phone shows a short code to compare. A stronger exchange hides each side's key until both commit. Today only the docs explain the real strength.
- A. Build it together with L1, and keep the honest docs until then (recommended).
- B. Build it now on its own.
- C. Docs only, never build it.

**48 (TASK-048). Same question for the key commitment in device linking.**
This is the same fix as item 10, seen from the key side.
- A. Do it in the same change as item 10, with L1 (recommended).
- B. Do it separately and earlier.

**12 (TASK-012). Phone push address changed while the app was closed. How is it re-registered?**
If the phone's push address rotates while the app is shut, the server keeps the old one and wake-ups stop.
- A. Save the new address on the phone and send it the next time the app opens (recommended; no login secrets in native code).
- B. Let the native side upload it to the server even when the app is closed (faster, but puts session credentials in native code).
- C. Do nothing and accept missed wake-ups until the app is opened.

**check 02 (C-875dbe0d9a3f). Should the server check that a new device's key belongs to the account?**
The server accepts any key package whose name bytes look right. Only the phones can tell if the key is genuine.
- A. Leave the check to phones through L1 (the approved-device list) and add no server check (recommended; the server never holds trust).
- B. Also have the server reject packages whose signing key does not match the enrolled key.
- C. Do both, but only as a warning in logs without content.

## Accounts, recovery and abuse

**168 (TASK-168). Can a recovery link be used more than once?**
It should work once and then die. The fix overlaps the key-package cap work (TASK-216).
- A. Strictly one use; a failed attempt needs a fresh request (recommended).
- B. One successful use, but allow a few retries on typing mistakes within a few minutes.
- C. Keep the current behavior.

**170 (TASK-170). How do we stop one person from using up another person's join keys?**
A per-person daily cap of 25 already exists (D64). Many different people could still drain one target together.
- A. Add a second, smaller cap per target across all people, per day (recommended).
- B. Keep only the existing per-person cap.
- C. Require the target to have accepted a contact request first.

**201 (TASK-201). A device link approved but never finished: what happens at expiry?**
Today the half-linked device can still sign in with the password and its device secret.
- A. Cancel it at expiry and remove its keys and MLS membership (recommended).
- B. Create the device only when the link is finished, so nothing half-exists.
- C. Keep it, and show the account owner a "half-linked device" warning.

**162 (TASK-162). Password check timing: could an attacker tell if a username exists?**
Some stored password formats are checked faster than others, which can leak which account is which.
- A. Always do the same amount of work, even for unknown names, and upgrade old hashes at login (recommended).
- B. Add a short random delay instead.
- C. Accept the small difference and keep the comment as it is.

## Sync and expiry

**209 (TASK-209). Build bounded sync paging now?**
The design is decided (D92) but nothing is built. Phones with many hidden events (blocked people) re-read them on every poll. It adds a field on both server and app.
- A. Build it behind the existing scoped-sync switch, off by default (recommended).
- B. Wait until a real device shows the slowdown.
- C. Drop it.

**106 (TASK-106). Whose clock decides when a message expires?**
Today the phone trusts the expiry time the server stamps. A hostile server could keep messages longer or cut them short.
- A. The sender's signed message sets the expiry, and the phone ignores a longer server time (recommended).
- B. Keep trusting the server, and say so in the docs.
- C. Each chat sets one fixed rule that the server cannot change.

## Release checks

**130 (TASK-130). Android release check: reject an APK that only claims our signing certificate?**
A tampered APK could name our certificate in its signing block without a valid signature.
- A. Fail the release if the block names our certificate but does not verify (recommended).
- B. Warn only.

**131 (TASK-131). Release test: tie the policy and checkout to the exact release candidate?**
Today the test fixture can pass against the wrong checkout.
- A. Bind both to the candidate commit and fail on any mismatch (recommended).
- B. Keep it as is.

**132 (TASK-132). Security-audit exceptions: limit each to the exact crate and users?**
Now an ignored advisory is ignored everywhere in the dependency graph.
- A. Each exception names the crate, version range and the only allowed parents, and the check fails otherwise (recommended).
- B. Keep graph-wide ignores with a written reason.
