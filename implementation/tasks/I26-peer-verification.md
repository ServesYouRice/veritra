# I26 — Verify peer identity out of band

Goal: two users can confirm they share the same MLS group state without trusting
any server-supplied value.

Read:

- MLS group/credential exposure in `crypto/rust/src/mls.rs` and the ABI
- mobile conversation details and chat screens
- `implementation/tasks/I15-device-link.md` for the SAS transcript pattern
- `implementation/archive/2026-07-26/docs/crypto-protocol.md`

Do:

1. Derive a conversation safety number on-device from the sorted member
   credentials, group ID, and epoch. Reuse I15's domain-separated transcript
   rule; never accept a server-authored comparison value.
2. Expose it as digits plus a QR payload in conversation details.
3. Let a user mark a peer verified and persist that locally only.
4. Show a clear unverified warning when the roster or credential set changes
   after verification, and require re-verification to clear it.
5. Test that a substituted credential changes the safety number, and that two
   honest devices in the same epoch always agree.

Done when: a malicious server cannot make two devices display a matching
verified state for different credential sets.

Verify:

```powershell
Push-Location mobile; flutter analyze; flutter test; Pop-Location
```

Rust vector tests must cover the derivation. Verification state is local; never
send it to the server.
