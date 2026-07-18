# Chain Link V — expanded identity (concept 06)

Concept 06 from the exploration round, developed into a usable mark family.
Two interlocked capsule links draw the V: an end-to-end connection between
exactly two parties. At the junction the right (sky, receiver) link passes
over and the left (indigo, sender) link tucks under with a uniform keyline
gap, its tip showing through the right link's loop.

Open `preview.html` in a browser to see the full family.

## Files

| File | Use |
| --- | --- |
| `veritra-mark.svg` | Primary gradient mark. Default choice everywhere. |
| `veritra-mark-mono.svg` | Single-ink (`#0F172A`) variant for print / one-color contexts. |
| `veritra-mark-white.svg` | White knockout for dark or brand-color surfaces. |
| `veritra-app-icon.svg` | Mark at 82% on an ink squircle; iOS/Android adaptive-icon ready. |
| `veritra-favicon.svg` | Small-size variant: heavier strokes, no weave gaps (invisible below ~24 px). |
| `veritra-wordmark.svg` | Horizontal lockup, dark text, for light backgrounds. |
| `veritra-wordmark-dark.svg` | Horizontal lockup, light text, for dark backgrounds. |
| `exports/veritra-mark-{512,192}.png` | Transparent raster mark for contexts that can't take SVG. |
| `exports/veritra-app-icon-{1024,512}.png` | App-store / launcher raster icons. |
| `exports/veritra-favicon-{48,32,16}.png` | Raster favicons from the small-size variant. |
| `exports/favicon.ico` | Multi-size ICO (16/32/48, PNG-encoded entries). |

## Palette

| Color | Hex | Role |
| --- | --- | --- |
| Indigo light | `#818CF8` | Left link gradient start |
| Indigo | `#4F46E5` | Left link gradient end; mono accent |
| Sky light | `#38BDF8` | Right link gradient start |
| Sky | `#0284C7` | Right link gradient end |
| Ink | `#0B1220` | App-icon surface, dark backgrounds |

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
- Gradients are `objectBoundingBox`; fine here because the rotated rects have
  non-degenerate boxes. Don't put gradients on axis-aligned single lines
  (zero-width boxes don't paint).
- Below ~24 px use `veritra-favicon.svg`; the keyline gap closes up and the
  thin strokes alias badly at those sizes.
- PNG exports were rasterized with headless Chromium (`--screenshot` with
  `--default-background-color=00000000` for large sizes; a canvas
  `drawImage` + `toDataURL` pass for 48/32/16, since tiny headless windows
  don't paint). The ICO is a plain container around the PNG entries.

## Where the mark is used

- `server/websetup/index.html` — the `/setup` page badge and its data-URI
  SVG favicon, plus the page accent palette.
- Repository `README.md` — wordmark via a `<picture>` light/dark switch.
