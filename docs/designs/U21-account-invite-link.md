# U21: one link for an account invitation

Status 2026-11-14. UI audit card U21, owner decision D131 ("one invite link
carries the server and the code; typing stays as a fallback"). Client only:
no server, wire, schema or crypto change.

## The link

```
<server origin>/invite#v1.<invite code>
```

- `server origin` is the canonical origin of the server that minted the code
  (`canonicalizeServerOrigin`: lower-case scheme and host, no default port, no
  path). It must pass the build's transport policy: HTTPS, or plain HTTP to a
  loopback host in demo builds only (D12).
- The path is exactly `/invite`. C1 group and community invitations use
  `/join#v2.…` ([C1-invite-format](C1-invite-format.md)); the two parsers
  never accept each other's links, so a link has one meaning.
- The fragment is `v1.` and the code exactly as the server issued it
  (`domain.NewInviteCode`: 16 random bytes, unpadded base32, 26 characters).
  The parser accepts 8 to 128 characters of `A-Z a-z 0-9 _ -`, so the
  fragment never needs percent-decoding, and keeps the case: the server
  compares the code exactly.
- `v1.` leaves room for a later format without guessing from the shape.

Code: `mobile/lib/core/account_invite_link.dart`
(`AccountInviteLink.tryParse`, `AccountInviteLink.forInvite`).

## Why the code goes after the `#`

The same rule as C1 (D90): a fragment is never sent in an HTTP request. If
the link is opened in a browser, tapped in a chat app or fetched by a link
previewer, the code does not reach that server's access log, a proxy or a
`Referer` header. The app sends the code only where it did before: in the
body of `POST /api/v1/register/enrollment` and `POST /api/v1/register`.

What it does **not** do: hide the code from the Veritra server. Unlike a C1
secret, an account invite code is minted and stored by the server
(`invites.code`), which must check it. The fragment protects it from third
parties, not from the server.

## Parsing rules

`tryParse` trims the input, refuses more than 512 characters, and returns
null unless: the scheme is `http` or `https` with a host; there is no user
info and no query; the path is exactly `/invite`; the origin is canonical
and allowed by the transport policy; and the fragment is `v1.` plus a code of
the charset above. A failure never repeats the input (no code in an error
text), and `toString()` is redacted.

## The link chooses the server

A C1 link is accepted only for the server the person is signed in to. An
account invitation is used before there is any account, so the link supplies
the server. The person sees it before anything is sent:

1. Step 1 parses the link and fills the server address and code. Only the
   existing setup probe (`GET /api/v1/setup/status`) reaches the server.
2. Step 2 names the server ("Joining chat.example.org", with Change) above
   the username and password fields. Nothing else is sent to that origin
   until Join is tapped.

A link to a server the person did not expect is the same risk as an address
someone tells them to type; naming the server on step 2 is the check.

## Making and sharing the link

The invitations page (Settings) builds the link from the session's server
and the code, and offers Copy link and a QR code (the existing `qr_flutter`
dependency) beside Copy code. The joiner pastes the link or scans the QR
(phones; desktop has no camera scanner and pastes).

## Not built

- No operating-system link handling (Android App Links, iOS Universal Links,
  a `veritra://` scheme): the person pastes or scans. Opening the link in a
  browser reaches `/invite` on the server, which answers 404; a small landing
  page there ("open Veritra and paste this link") would be a server change.
- A pasted C1 group link (`/join#v2.…`) gets the plain "not an invite link"
  message; a message that explains the difference is a possible follow-up.
