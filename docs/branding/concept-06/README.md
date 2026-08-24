# Chain Link V — the Veritra mark family

Concept 06 from the exploration round, developed into the identity the app,
the setup page and the README all use. Two interlocked capsule links draw the
V: an end-to-end connection between exactly two parties. At the junction the
right link passes over and the left link tucks under with a uniform keyline
gap, its tip showing through the right link's loop.

Every file here is on **K2 · Bone**, the direction decided 2026-08-07 and
specified in [`../../design.md`](../../design.md) §K. Open `preview.html` in a
browser to see the family on both grounds. Replaced brand assets are available
only from Git history at `bfb3922`.

## Files

| File | Use |
| --- | --- |
| `veritra-mark.svg` | Primary mark, deep plum. Default on paper/light grounds. |
| `veritra-mark-bone.svg` | Bone mark for plum/dark grounds. |
| `veritra-mark-mono.svg` | Single-ink variant for print / one-colour contexts. |
| `veritra-app-icon-bone.svg` | Mark at 82% on a plum squircle; iOS/Android launcher source. |
| `veritra-favicon.svg` | Small-size variant: heavier strokes, no keyline gap, carries its own ground. |
| `veritra-wordmark.svg` | Horizontal lockup for light backgrounds. |
| `veritra-wordmark-dark.svg` | Horizontal lockup for dark backgrounds. |
| `exports/veritra-mark-{512,192}.png` | Transparent raster mark, deep plum. |
| `exports/veritra-mark-bone-{512,192}.png` | Transparent raster mark, bone. |
| `exports/veritra-app-icon-bone-{1024,512}.png` | App-store / launcher raster icons. |
| `exports/veritra-favicon-{48,32,16}.png` | Opaque raster favicons. |
| `exports/favicon.ico` | Multi-size ICO (16/32/48, PNG-encoded entries). |

## Palette

The direction spends **no accent hue**, so the mark carries no gradient and no
second colour. Every value below is a token from `../../design.md` §K, not a
brand colour of its own — that is the whole point of Bone, and it is what keeps
green, amber, red and blue free to mean verified, warning, error and info.

| Colour | Hex | Role |
| --- | --- | --- |
| Deep plum | `#3A2E42` | Mark on light grounds; the light-mode accent |
| Bone | `#EDE4DA` | Mark on dark grounds; the dark-mode accent |
| Plum canvas | `#16111F` | Icon and favicon ground; the dark-mode canvas |
| Ink | `#1A1620` | Mono/print mark, and wordmark text on light |
| Paper text | `#F3EFFA` | Wordmark text on dark |

Bone on the plum canvas measures 14.0:1. There is no light-mode contrast risk
in the mark itself; the values that sit close to AA are the four state tones in
§K, which the mark does not use.

## Construction notes

- Both links are the same rounded rect (`90 × 290`, `rx 45`, stroke 30 in a
  512 viewBox) rotated ±35° about its center; the crossings land at
  (256, 284) and (256, 356).
- The tuck-under is done with one mask: the left link is erased along the
  right link's silhouette stroked 24 px wider, leaving a uniform 12 px
  keyline gap. Don't try to alternate over/under at this geometry — both
  crossing points sit on the capsules' rounded end caps, so circular bites
  there amputate the tips. Keep the mask on a wrapper `<g>`, not on the
  rotated rect itself — masks on a transformed element rotate with it.
- The mark's optical centre is **y=238, not 256**. Everything that re-centres
  it before scaling (app icon, favicon, `VeritraMark`) accounts for that.
- **The favicon carries its own plum ground**, unlike the old Indigo/Sky one.
  A hueless mark on a transparent field would be a near-white on a light
  browser tab and a near-black on a dark one — invisible either way.
- The wordmark's `letter-spacing` of 6.24 is 0.06em at its 104 px size, which
  is the value `server/websetup/index.html` sets on `.wordmark`. Change one and
  change the other.
- Below ~24 px use `veritra-favicon.svg`; the keyline gap closes up and the
  thin strokes alias badly at those sizes.

## Regenerating the rasters

The PNGs and the launcher icons were rendered from these SVGs with **macOS
QuickLook** (`qlmanage -t`), which is the only rasteriser present on the
machine — no ImageMagick, Inkscape, rsvg, Python/PIL, sharp or headless
Chromium, and none was added, because a new dependency here means a license
review and a `THIRD_PARTY_NOTICES.md` entry per `AGENTS.md`.

Two QuickLook properties matter to anyone repeating this:

- **It always composites onto opaque white**, so transparency has to be
  recovered by rendering each file twice, once over an injected white ground
  and once over black. The black render is exactly the premultiplied colour and
  the difference between the two is the inverse of alpha. Downscaling is then
  done in premultiplied space, which is what avoids dark halos.
- **It does not preserve aspect ratio for non-square SVGs** — an 860×220 file
  comes back in a 960×275 canvas, a 12% vertical stretch. Every asset exported
  here is square, where the scaling is exact. Wrap a lockup in a square viewBox
  before rasterising it, or use a real rasteriser.

Any conventional rasteriser reproduces all of these from the SVGs directly and
is the better tool if one is available.

## Where the mark is used

- `mobile/lib/ui/widgets/veritra_mark.dart` — drawn as a `CustomPainter`, not
  imported. Same geometry, theme colour, no `flutter_svg` dependency.
- `mobile/android/.../mipmap-*/ic_launcher.png` — the squircle with its alpha
  corners, from `veritra-app-icon-bone.svg`.
- `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/` — full-bleed and
  opaque, with **no alpha channel**: iOS applies its own mask and rejects an
  alpha channel outright. Generated from the same file with the inset squircle
  swapped for an edge-to-edge ground.
- `server/websetup/index.html` — the `/setup` page lockup, drawn inline with
  `currentColor` so it follows the page's light/dark tokens, plus a data-URI
  favicon that is `veritra-favicon.svg` inlined. The two are pixel-identical;
  change one and change the other.
- Repository `README.md` — wordmark via a `<picture>` light/dark switch.
