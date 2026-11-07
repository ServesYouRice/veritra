# B2 link previews — 2026-11-07

Status: implemented on branch `agent/b2`; Dart is verified by GitHub CI on the
pull request (Flutter is not installed where this was written). STATE.md routes
B2 to Opus review. No counter bump, no server change, no release-gate change.

## What it does

- The sender's app builds the preview before encrypting and puts it in the
  payload body as `link_preview` (`docs/crypto.md` §5.8, payload v2). Receivers
  and the server never fetch.
- Setting "Link previews" (this device): off, known sites only (default), all
  sites. Known sites are the small list `linkPreviewAllowList`.
- Fetch limits: https only, port 443, 8 s in all, 256 KiB page, 3 redirects with
  every hop re-checked against https, host and mode, `text/html` only, public
  unicast addresses only, no cookies or referrer, generic user agent.
- Tracking parameters and the fragment are stripped from the fetched and sent
  URL. The picture is re-encoded as PNG (metadata dropped), 16 KiB at most, and
  travels inline in the encrypted payload.
- Receiver keeps a preview only when its URL equals a link in the message text.
  The card shows the real host and has no tap target.

## Persistence and counters

- Stored in the existing `local_messages.format_json` under `link_preview`.
  No column, no migration, no schema bump (schema stays 18).
- ABI stays 12, server migration stays 0046.
- `history_snapshot.dart` now allows the key and re-validates it, so K2 copy
  and restore keep the card. An older build rejects a snapshot that holds one.

## Dependency

`html` 0.15.7 (MIT) with `csslib` 1.0.2 (BSD-3-Clause); `source_span` was
already in the lock. Both pinned with hashes in `mobile/pubspec.lock`, listed in
`THIRD_PARTY_NOTICES.md`.

## Tests added

`link_preview_test.dart` (URL helpers, wire validation, size budget, payload v2
switch, decoration, snapshot round trip), `link_preview_service_test.dart`
(parsing, allow-list, address policy, redirects, bounds, failures; fake
transport), `app_state_link_preview_test.dart` (send path, setting),
`link_preview_ui_test.dart` (card, chat bubble, settings tile).
