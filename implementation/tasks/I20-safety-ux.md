# I20 — Add identity and safety UX

Goal: users can identify peers and reach the safety actions the server supports.

Read:

- mobile chat list, chat, conversation details, settings, and search screens
- authorized roster/DM responses from I04
- payload and sync state from I14/I19

Do:

1. Show canonical DM peer identity and avoid duplicate DM creation.
2. Add accessible block/unblock, member list, leave, and authorized remove actions.
3. Add reply/edit/delete/reaction actions only when authenticated payload support exists.
4. Show concise offline/reconnecting/delivery state and accurate search navigation.
5. Fix validation copy and test large text, keyboard, and semantics.

Done when: widget tests cover permissions, failures, and navigation without placeholder claims.

Verify:

```powershell
Push-Location mobile; dart format --set-exit-if-changed .; flutter analyze; flutter test; Pop-Location
```

Do not expose server-authored identity as cryptographic verification.
