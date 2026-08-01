# Veritra design

Proposals for how the app should look. **Nothing here is wired into the build
yet** — this folder is ideas and mockups, pending a decision.

## Start here

Open [`preview.html`](preview.html) in a browser.

It renders **five** versions of the same three screens — Chats, Conversation,
Connect. The first row is what ships today; the four below are proposed
directions. There is a light/dark toggle at the top right; every direction is
tuned for both.

Pick a direction by looking, then read the rest.

## The problem

The app is stock Material 3 with the defaults left on.

| | Today |
| --- | --- |
| Colour | One teal seed, `#126f7a`, auto-expanded by `ColorScheme.fromSeed` |
| Typography | **None.** No `TextTheme` at all — every screen is default Roboto at default sizes |
| Assets | **None.** No fonts, no images; launcher icons are still stock Flutter |
| Brand | Ignored. `docs/branding/` has a full identity the app never uses |
| Layout | Every screen is `Card` + `ListTile` + `Divider` + chevron |

The worst single thing is the conversation screen: every bubble renders an
identical `🔒 Encrypted message` row, so a chat is a stack of identical grey
blocks. Compare the first two rows in the preview.

The teal is not even intentional — `mobile/lib/ui/theme.dart:6` says it was
"kept from the original prototype".

## Files

| File | What it is |
| --- | --- |
| [`preview.html`](preview.html) | **The main thing.** Five looks, three screens each, light + dark |
| [`directions.md`](directions.md) | The four palettes side by side, with a recommendation |
| [`redesign.md`](redesign.md) | Token system + what changes on each screen |
| [`implementation.md`](implementation.md) | How it lands in Flutter, once a direction is picked |

`redesign.md` applies to **whichever** direction is chosen — the layout work is
shared, only the skin differs.

## Recommendation in one line

**Direction A · Ink** — it is the only one that already matches the brand in
`docs/branding/concept-06/`, and dark-first suits a privacy product.

## Scope

The Flutter app in `mobile/lib/`, plus `server/websetup/index.html` — the first
Veritra surface a self-hoster ever sees. Nothing here touches crypto, storage,
or the `PM_CRYPTO_UNAVAILABLE` release gate.
