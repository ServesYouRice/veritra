# Chain Link V — expanded identity (concept 06)

Concept 06 from the exploration round, developed into a usable mark family.
Two interlocked capsule links draw the V: an end-to-end connection between
exactly two parties. The weave is explicit — the left (indigo, sender) link
passes over at the top crossing and under at the bottom, where the right
(sky, receiver) link passes over.

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
- The weave is done with masks: each link is erased by a 27 px circle at the
  crossing where it passes under. Keep the mask on a wrapper `<g>`, not on
  the rotated rect itself — masks on a transformed element rotate with it.
- Gradients are `objectBoundingBox`; fine here because the rotated rects have
  non-degenerate boxes. Don't put gradients on axis-aligned single lines
  (zero-width boxes don't paint).
- Below ~24 px use `veritra-favicon.svg`; the weave gaps close up and the
  thin strokes alias badly at those sizes.
