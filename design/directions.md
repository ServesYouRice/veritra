# Directions

See them rendered in [`preview.html`](preview.html). This file is the reference
for the numbers behind them.

**E · Ember** and **F · Dusk** are the current candidates; the four original
directions follow as reference.

## The candidates: E and F

Both are the same revision of A + C — Ink's structure (tone-only depth, 1px
hairlines, 12/20 radii, 62px rows) on Aurora's plum ground. Two things from the
originals are deliberately gone:

- **The indigo.** `#6366F1` sits about ten degrees of hue from Viber's
  `#7360F2`, which is why A read as Viber-adjacent.
- **The gradient and the coloured shadow.** Both accents are flat. This removes
  the `--grad` / `--grad-fill` split entirely — there is no gradient left to get
  wrong, and it is less to keep consistent across 12 screens.

They differ only in accent, and in what that costs. **G through K** extend the
same recipe to five more accents — identical ground, type, radii and density —
so choosing between any of E–K is a pure hue decision.

| | Accent (dark / light) | Hue | From Viber | Character |
| --- | --- | --- | --- | --- |
| **E · Ember** | `#E9A23B` / `#A8590C` | 38° | 140° | Warm, editorial |
| **F · Dusk** | `#38BDF8` / `#0369A1` | 199° | 59° | Cool, precise |
| **G · Rose** | `#F2879F` / `#B03A55` | 347° | 89° | Warmest, friendly |
| **H · Fuchsia** | `#EE7BD0` / `#A83A8C` | 316° | 58° | Boldest |
| **I · Jade** | `#42D6A0` / `#0F7A57` | 158° | 100° | Cool, clinical |
| **J · Azure** | `#6FB2FF` / `#1667C7` | 212° | 46° | Conventional |
| **K · Bone** | see below | — | — | No accent hue |

"From Viber" is hue distance from `#7360F2`, the read that ruled out A. **J is
the closest at 46°** — still blue rather than violet, but it is the one to check
against what you rejected.

Sent bubbles are accent-filled except in **E**, **H** and **K**, where the accent
is too high-energy to tile down a whole column without re-creating C's loudness.

Brand cost splits cleanly: **F** keeps the Sky half of `docs/branding/` and needs
only a ground swap. Every other variant is a full palette redo.

## K · Bone — the five temperatures

Bone spends **no accent hue**. A near-white carries every accent slot, so the
plum ground is the whole identity. The five below vary only the temperature of
that near-white, plus the muted grey biased to match it — a neutral leaning
toward its own bone reads as chosen rather than inherited.

| | Bone (dark) | Deep (light) | Muted | Character |
| --- | --- | --- | --- | --- |
| **K1 · Chalk** | `#F4F4F6` | `#332F3A` | `#A39FA6` | Starkest, most contemporary |
| **K2 · Bone** | `#EDE4DA` | `#3A2E42` | `#A89EA6` | Warm paper — the original |
| **K3 · Greige** | `#DCD3C6` | `#403528` | `#A79C93` | Warmest, most analog |
| **K4 · Ash** | `#E4DDEA` | `#372C43` | `#A79EB4` | Leans into the plum; most cohesive |
| **K5 · Steel** | `#D8E0E8` | `#2C333B` | `#9FA8B4` | Coolest, most technical |

Light mode inverts rather than tints: the bone becomes the paper ground and the
accent becomes a deep tone of the same temperature. Each variant therefore
carries its own light canvas — `#F6F7F9` for Chalk through `#F7F4EC` for Greige
— so the warmth survives the switch instead of collapsing to one grey.

Sent bubbles stay on tone in all five. A near-white tiled down a whole column
would blow out the ground the direction is built on.

### The state palette

This is Bone's actual payoff. Every other variant spends a hue on brand, which
means that hue can no longer mean anything else — I · Jade cannot use green for
"verified" once green *is* the brand. Bone spends none, so all four states stay
unambiguous:

| State | Dark | on plum | Light | on paper |
| --- | --- | --- | --- | --- |
| Verified | `#4ADE80` | 10.6 | `#15803D` | 4.56 |
| Warning | `#FBBF24` | 11.1 | `#B45309` | 4.57 |
| Error | `#FB7185` | 6.9 | `#BE123C` | 5.72 |
| Info | `#7DD3FC` | 11.1 | `#0369A1` | 5.40 |

**The light set only just clears AA** at 4.56 and 4.57. Keep those two at body
size or larger, and re-check them if the paper ground is ever lightened.

Interaction states use the bone itself rather than a second hue: hover lifts it
toward white, pressed drops it about 8%, disabled falls back to the raised plum
with muted text. All were checked to keep the on-accent text above 4.5:1 in
every state.

Shared plum ground, both:

| Role | Dark | Light |
| --- | --- | --- |
| Canvas | `#16111F` | `#F8F5FA` (E) / `#F7F5FA` (F) |
| Surface | `#211A2D` | `#FFFFFF` |
| Raised | `#2B233A` | `#F0EBF4` (E) / `#EEEAF4` (F) |
| Border | `rgb(255 255 255 / 9%)` | `rgb(26 18 38 / 11%)` |
| Text | `#F3EFFA` | `#1A1226` |
| Muted | `#A79EC0` | `#675E79` (E) / `#655D77` (F) |

Accents:

| | Dark | On accent | Light | On accent |
| --- | --- | --- | --- | --- |
| E · Ember | `#E9A23B` | `#1A1220` | `#A8590C` | `#FFFFFF` |
| F · Dusk | `#38BDF8` | `#04202E` | `#0369A1` | `#FFFFFF` |

**Why E holds the accent back.** Ember is a warning-adjacent hue, so a full
column of amber sent-bubbles would re-create exactly the loudness that made C
feel overdone. Sent bubbles separate by tone plus a hairline instead, and the
accent is spent only on send button, active nav, unread badge and focus ring.
F does not have that problem — sky-blue sent bubbles are the conventional read
and test at 7.83:1 — so it keeps them filled.

**Why F is recommended.** The brand in `docs/branding/` is Indigo **and** Sky.
Only the indigo was the problem. F drops it and keeps `#38BDF8`/`#0369A1`, so
the mark and wordmark need their navy ground moved to plum rather than a new
palette. E is the better-looking of the two if warmth matters more than that.

## The four originals

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

## A · Ink

Superseded by E and F, which keep its structure. Dark-first editorial. Surfaces separate by **tone, not shadow**, over 1px
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
| **E–K plum dark — text on canvas** | **16.4** |
| **E–K plum dark — muted on canvas** | **7.3** |
| **E–K plum light — muted on canvas** | **5.7** |
| **G Rose — `#2A0F17` on `#F2879F`** | **7.4** |
| **H Fuchsia — `#2C0C24` on `#EE7BD0`** | **7.1** |
| **I Jade — `#06251A` on `#42D6A0`** | **8.8** |
| **J Azure — `#051D33` on `#6FB2FF`** | **7.7** |
| **K Bone — `#1E1620` on `#EDE4DA`** | **14.0** |
| **G–K light — white on accent** | **5.3–12.7** |
| **E Ember light — muted on canvas** | **5.6** |
| **F Dusk light — muted on canvas** | **5.7** |
| **E — `#1A1220` on `#E9A23B`** | **8.4** |
| **E light — white on `#A8590C`** | **5.1** |
| **F — `#04202E` on `#38BDF8`** | **7.8** |
| **F light — white on `#0369A1`** | **5.9** |
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

Applies to A and C only. B, D, **E and F** use flat accents and are checked
above — dropping the gradient is one of the reasons E and F are simpler to
implement and to keep consistent.

**If you change any hue, re-run the check** — gradients are where this is
easiest to get wrong, because the failing region is in the middle where nobody
looks.

## Also worth knowing

- Every palette is specified for **both** light and dark. Whichever is chosen,
  both ship — `ThemeMode.system` is already wired up in `mobile/lib/main.dart`.
- Avatar tints are generated from a hash of the account ID, so they vary by
  contact. In Vault they are forced to greyscale to protect the one-colour rule.
