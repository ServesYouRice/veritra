# B2 link previews — 2026-11-07

Status: merged on `main` (PR #124, `debc2bc`), verified with full local checks
passing. Opus review complete (review fixes landed). Owner approval recorded in
D89/D96. No counter bump, no server change, no release-gate change.

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
- Export drops it. A preview carries up to about 22 KiB of base64 thumbnail,
  and the K2 snapshot and the backup both cap at 64 MiB, so about 3,000
  previewed rows would have made every transfer or backup fail. Both writers
  (`_messageJson` in `history_snapshot.dart`, `_encodeBackup` in
  `local_store.dart`) remove the whole `link_preview` key from `format_json`,
  and the field when nothing else is left. That also keeps the snapshot
  readable by a build older than B2 (it allows only `entities`, `mentions`).
  A copied or restored history shows no preview cards.
- The K2 reader still accepts and re-validates the key. The backup reader does
  not look at `format_json`; a stored preview is checked when drawn.
- Residual, not fixed here: the backup's `messages` section holds cached
  server envelopes (ciphertext, which includes the thumbnail). Ciphertext
  cannot be stripped, and the cache is filled page by page as a person
  scrolls, not bounded by one small page. A very large cache of previewed
  messages could still add to the backup size. Worth measuring when K1 lands.
- Keeping previews across a transfer needs a snapshot/backup format bump, a
  coordinator decision outside this change.

## Dependency

`html` 0.15.7 (MIT) with `csslib` 1.0.2 (BSD-3-Clause); `source_span` was
already in the lock. Both pinned with hashes in `mobile/pubspec.lock`, listed in
`THIRD_PARTY_NOTICES.md`. Owner approval is not recorded in STATE.md (no
decision entry), so the merge is blocked until the owner says yes.

## Tests added

`link_preview_test.dart` (URL helpers, wire validation, size budget, payload v2
switch, decoration, snapshot round trip), `link_preview_service_test.dart`
(parsing, allow-list, address policy, redirects, bounds, failures; fake
transport), `app_state_link_preview_test.dart` (send path, setting),
`link_preview_ui_test.dart` (card, chat bubble, settings tile),
`link_preview_export_size_test.dart` (3,500 rows with 16 KiB thumbnails: the
fixture is over 64 MiB raw, and both the K2 snapshot and the backup stay under
the cap, keep entities and restore). `link_preview_test.dart` also covers that
an export has no `link_preview`, and that the reader still accepts one.
