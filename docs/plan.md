# UI Modernization Status

Date: 2026-07-04
Scope: Flutter mobile client (`mobile/`) plus the static setup notice.

This file replaces the older 2026-07-02 UI audit plan. The planned UI pass has
mostly landed; this is now a status note so it does not keep claiming completed
screens are missing.

## Implemented

- App shell uses Chats / Communities / Settings with a navigation rail on wider screens.
- Connect screen supports Owner, Sign in, Join with invite, and Link device.
- Settings includes invite creation, device list/revoke, device linking, logout, logout-other-devices, and account deletion.
- Chat list has search, refresh, new conversation flow, and conversation detail navigation.
- Chat screen fetches encrypted envelopes, marks the newest message read, and renders envelope bubbles with edited/deleted state.
- Conversation details supports adding members and retention changes.
- Communities screen can create communities and channels, and opens channel conversations.
- Search screen calls metadata-only search.
- Web setup page is a static no-JS notice that points users at crypto-capable clients.

## Still Limited

- Production crypto is not wired. `UnavailableCryptoService` still fails closed, so owner setup, invite join, device-link claim, and message send are not production-functional in the default app.
- Messages render as encrypted envelope metadata only. There is no decrypt/display path until production client crypto exists.
- The server has no list-communities, list-channels, list-members, or invite-management endpoints. The UI shows communities/channels created in the current session plus channel conversations from the conversation list.
- Chat message loading uses the first page of the server cursor API. Infinite scroll with `next_before` is still follow-up work.
- Attachments, encrypted backup restore UX, push provider management, and call media remain blocked on production crypto/provider work.

## Follow-Up Server/API Work

- Add key-distribution endpoints needed by the eventual OpenMLS integration.
- Add attachment and backup list/download endpoints for ciphertext retrieval.
- Add list endpoints for communities, channels, conversation members, and invites.
- Document and implement the intended account-deletion retention policy.

## Verification Notes

- Keep mobile tests focused on API serialization, AppState flows, and UI-safe handling of unavailable crypto.
- Full end-to-end messenger verification waits on production crypto, local key storage, and decrypt/render support.
