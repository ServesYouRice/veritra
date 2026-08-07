# Veritra design

Proposals for how the app should look. **Nothing here is wired into the build
yet** — this folder is ideas and mockups, pending a decision.

## Start here

Open [`preview.html`](preview.html) in a browser.

It renders **sixteen** versions of the same three screens — Chats, Conversation,
Connect. The first row is what ships today. Then eleven variants of one
direction, all sharing an identical plum ground, type scale, radii and density:
**E–J** are six accent hues, and **K1–K5** spend no accent hue at all, varying
only the temperature of the near-white that carries the accent slots. The four
original directions follow for reference. There is a light/dark toggle at the
top right; every variant is tuned for both.

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
| [`preview.html`](preview.html) | **The main thing.** Sixteen looks, three screens each, light + dark |
| [`directions.md`](directions.md) | Every palette side by side, with a recommendation |
| [`redesign.md`](redesign.md) | Token system + what changes on each screen |
| [`implementation.md`](implementation.md) | How it lands in Flutter, once a direction is picked |

`redesign.md` applies to **whichever** direction is chosen — the layout work is
shared, only the skin differs.

## Decided

**K2 · Bone**, chosen 2026-08-07. A's discipline on C's plum with no accent hue
at all: a warm near-white carries every accent slot, so the ground is the
identity and the whole colour wheel stays free for state.

The tokens and theme are built — see `mobile/lib/ui/tokens.dart` and
`mobile/lib/ui/theme.dart`, tracked as **I28**. The remaining screen work is
listed in [`implementation.md`](implementation.md). Everything else in this
folder is kept as the record of what was considered.

## Scope

The Flutter app in `mobile/lib/`, plus `server/websetup/index.html` — the first
Veritra surface a self-hoster ever sees. Nothing here touches crypto, storage,
or the `PM_CRYPTO_UNAVAILABLE` release gate.
