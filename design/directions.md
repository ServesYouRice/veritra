# Four directions

See them rendered in [`preview.html`](preview.html). This file is the reference
for the numbers behind them.

## At a glance

| | **A · Ink** | **B · Vault** | **C · Aurora** | **D · Terminal** |
| --- | --- | --- | --- | --- |
| Default mode | Dark | Light | Light | Dark |
| Character | Precise, editorial | Restrained, forensic | Warm, premium | Dense, technical |
| Reads like | Linear, Vercel | Proton, Tailscale | Bluesky, Beeper | Warp, Datadog |
| Corner radius | 12 / 20 | 8 | 20 / 28 | 4 |
| Depth | Tone only, no shadow | Visible borders | Soft coloured shadow | Hairline borders |
| Accent use | Rationed to 4 places | Encryption state only | Gradient everywhere | Cyan + amber states |
| Row height | 62px | 62px | 66px | **44px** |
| Brand fit | **Already matches** | Needs new palette | Matches, softened | Needs new palette |
| Best for | A serious privacy tool | Making trust visible | Non-technical users | Self-hosters |

## A · Ink — recommended

Dark-first editorial. Surfaces separate by **tone, not shadow**, over 1px
hairlines at 9% white. The Indigo→Sky gradient is spent in exactly four places:
send button, active nav, unread badge, focus ring. Everything else is greyscale.

| Role | Dark | Light |
| --- | --- | --- |
| Canvas | `#0B1220` | `#F5F6FB` |
| Surface | `#151D31` | `#FFFFFF` |
| Raised | `#1C2740` | `#ECEFF8` |
| Border | `rgb(255 255 255 / 9%)` | `rgb(11 18 32 / 11%)` |
| Text | `#EEF1FA` | `#0B1220` |
| Muted | `#8B93AE` | `#5A6280` |
| Brand Indigo | `#6366F1` | `#4F46E5` |
| Brand Sky | `#0EA5E9` | `#0284C7` |
| Fill gradient | `#4F46E5 → #0369A1` | same |

**Why this one.** It is the only direction that already matches
`docs/branding/concept-06/` — the same Indigo and Sky, the same Ink surface.
Adopting it makes the app, the setup page, and the README one identity for free.
Dark-first also suits a product whose whole pitch is discretion.

**Cost.** The least "fun" of the four. If you want Veritra to feel friendly to
people who don't know what MLS is, pick C.

## B · Vault

Greyscale everywhere **except one signal green**, spent only on encryption and
verification state. The lock glyph becomes the only colour in the list, so the
security story is literally the visual story. Squarer corners, heavier type,
borders you can see.

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#FAFAFA` | `#08090A` |
| Surface | `#FFFFFF` | `#131415` |
| Raised | `#F0F0F0` | `#1D1E20` |
| Border | `#D6D6D6` | `#2F3032` |
| Text | `#08090A` | `#FAFAFA` |
| Muted | `#6B6B6B` | `#8A8A8A` |
| Signal | `#16A34A` | `#22C55E` |
| On signal | `#08090A` | `#08090A` |

Note the last row: text on green is **near-black in both modes**. White on
`#16A34A` is only 3.30:1 and fails AA.

**Why.** The strongest *argument* of the four — it makes the product's one
distinguishing feature the one thing your eye lands on. Avatars are deliberately
greyscale so nothing competes.

**Cost.** Abandons the Indigo/Sky brand entirely; `docs/branding/` would need
redoing. Single-hue systems also leave you nothing for error and warning states
without breaking the rule.

## C · Aurora

Light-first with a deep-plum dark mode. Surfaces float on soft indigo-tinted
shadows, a gradient glow sits behind the brand moment, and **sent bubbles carry
the gradient itself**. Big radii, generous spacing.

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#F7F7FB` | `#16111F` |
| Surface | `#FFFFFF` | `#211A2D` |
| Raised | `#F0EFF8` | `#2B233A` |
| Border | `rgb(79 70 229 / 12%)` | `rgb(255 255 255 / 9%)` |
| Text | `#1A1630` | `#F3EFFA` |
| Muted | `#6F6A8D` | `#A79EC0` |
| Glow Indigo | `#6366F1` | `#818CF8` |
| Glow Sky | `#38BDF8` | `#38BDF8` |
| Fill gradient | `#4F46E5 → #0369A1` | same |
| Shadow | `0 10px 30px rgb(79 70 229 / 13%)` | `0 10px 30px rgb(0 0 0 / 40%)` |

**Why.** By far the most approachable. If Veritra is meant for people who were
told to install it by a friend, this is the one that doesn't scare them.

**Cost.** Gradient-heavy UI ages fastest, and coloured shadows plus large radii
cost more to keep consistent across 12 screens. Softest read of the four — least
"secure-feeling".

## D · Terminal

Dense and technical. Rows are 44px instead of 62px, so ~40% more fits per screen.
Every identifier — account IDs, invite codes, verification codes, device
fingerprints — is **monospace by default**.

| Role | Dark | Light |
| --- | --- | --- |
| Canvas | `#0F1419` | `#F2F4F6` |
| Surface | `#161C22` | `#FFFFFF` |
| Raised | `#1E262E` | `#E6EBEF` |
| Border | `#2A343E` | `#C9D2DA` |
| Text | `#D7E0EA` | `#0F1419` |
| Muted | `#7C8B99` | `#58656F` |
| Accent | `#22D3EE` | `#0E7490` |
| On accent | `#04222A` | `#FFFFFF` |
| Warning | `#F59E0B` | `#B45309` |

**Why.** Honest about who actually runs a self-hosted messenger. This app is
*full* of identifiers — `invite_screen.dart:175` already reaches for
`fontFamily: 'monospace'` on its own — and this direction stops treating them
as an exception.

**Cost.** Narrowest audience. Dense rows and 10.5px monospace are harder on
accessibility; the type ramp needs care to stay legible at large text sizes.

## Contrast

Measured, not assumed. WCAG 2.1 body-text target is **4.5:1**; the numbers below
are computed from the hexes in this file.

| Pair | Ratio |
| --- | --- |
| A Ink dark — text on canvas | 16.6 |
| A Ink dark — muted on canvas | 6.1 |
| A Ink light — muted on canvas | 5.6 |
| B Vault light — muted on canvas | 5.1 |
| B Vault dark — muted on canvas | 5.8 |
| C Aurora light — muted on canvas | 4.8 |
| C Aurora dark — muted on canvas | 7.3 |
| D Terminal dark — muted on canvas | 5.3 |
| D Terminal light — muted on canvas | 5.4 |
| B — near-black on `#22C55E` | 8.8 |
| D — `#04222A` on `#22D3EE` | 9.2 |
| **Fill gradient — white, worst stop** | **5.9** |

### Two gradients, on purpose

The bright brand gradient `#6366F1 → #0EA5E9` is **decorative only**. White text
on its sky end is **2.77:1** — it fails AA badly, and the naive version of this
design (gradient send button, gradient sent-bubbles, white text) is not
accessible.

So there are two tokens:

- `--grad` — `#6366F1 → #0EA5E9`. Brand mark, hero glow, anything with no text
  on it.
- `--grad-fill` — `#4F46E5 → #0369A1`. Everything that carries text or an icon:
  send button, unread count, active nav, sent bubbles, primary CTA. White stays
  **≥ 5.9:1 at every stop** along the gradient, not just at the ends.

Applies to A and C. B and D use flat accents and are checked above.

**If you change any hue, re-run the check** — gradients are where this is
easiest to get wrong, because the failing region is in the middle where nobody
looks.

## Also worth knowing

- Every palette is specified for **both** light and dark. Whichever is chosen,
  both ship — `ThemeMode.system` is already wired up in `mobile/lib/main.dart`.
- Avatar tints are generated from a hash of the account ID, so they vary by
  contact. In Vault they are forced to greyscale to protect the one-colour rule.
