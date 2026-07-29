# I20 — Add identity and safety UX

Goal: users can identify peers and reach the safety actions the server supports.

Read:

- mobile chat list, chat, conversation details, settings, and search screens
- authorized roster/DM responses from I04
- payload and sync state from I14/I19

Do:

1. ~~Show canonical DM peer identity and avoid duplicate DM creation.~~ Done
   2026-07-29: `peer_account_id`/`peer_username` on the conversation list,
   named DM rows and avatars, `existingDmWith` reuse.
2. ~~Add accessible block/unblock, member list, leave, and authorized remove
   actions.~~ Done 2026-07-29: roster with role-gated remove, leave, block from
   DM details and search, Blocked accounts screen, per-conversation mute.
3. Add reply/edit/delete/reaction actions only when authenticated payload
   support exists. **Remaining — blocked on I14.**
4. ~~Show concise offline/reconnecting/delivery state and accurate search
   navigation.~~ Done 2026-07-29: connection banner driven by sync outcomes,
   `syncError` split from action errors, search copy and navigation aligned
   with the API.
5. ~~Fix validation copy~~ Done 2026-07-29 (in-dialog password validation,
   mojibake, group-creation validation). Large text, keyboard, and semantics
   need the manual on-device pass tracked under I24.

Done when: widget tests cover permissions, failures, and navigation without placeholder claims.

Verify:

```powershell
Push-Location mobile; dart format --set-exit-if-changed .; flutter analyze; flutter test; Pop-Location
```

Do not expose server-authored identity as cryptographic verification.
