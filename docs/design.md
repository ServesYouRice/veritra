# Veritra design — K2 · Bone

The app's visual design: the palette, the per-screen spec, and the record of
how it landed in Flutter.

**Direction decided 2026-08-07: K2 · Bone.** All eight build steps are written
and were verified on 2026-08-08 against the pinned Docker toolchains. Card
status, the verification run and what it did *not* cover live on the board
([`board.md`](board.md), card I28) — this document is the specification, not the
status.

Scope is the Flutter app in `mobile/lib/` plus `server/websetup/index.html`, the
first Veritra surface a self-hoster ever sees. Nothing here touches crypto,
storage, sync, or the `PM_CRYPTO_UNAVAILABLE` release gate.

## The problem this solved

The app was stock Material 3 with the defaults left on.

| | Before the rebuild |
| --- | --- |
| Colour | One teal seed, `#126f7a`, auto-expanded by `ColorScheme.fromSeed` |
| Typography | **None.** No `TextTheme` at all — every screen default Roboto at default sizes |
| Assets | **None.** No fonts, no images; launcher icons were stock Flutter |
| Brand | Ignored. `branding/` held a full identity the app never used |
| Layout | Every screen was `Card` + `ListTile` + `Divider` + chevron |

The worst single thing was the conversation screen: every bubble rendered an
identical `🔒 Encrypted message` row, so a chat was a stack of identical grey
blocks. The teal was not even intentional — the old `mobile/lib/ui/theme.dart`
said it was "kept from the original prototype".

Eleven variants were compared before K2 was chosen. The owner rejected **A ·
Ink** (reads as Viber — its `#6366F1` indigo sits about ten degrees of hue from
Viber's `#7360F2`) and **C · Aurora** (overdone), while keeping C's plum ground.

---

## §K — The palette

K2 · Bone spends **no accent hue**. In dark mode a warm near-white carries every
accent slot over a plum ground; in light mode that inverts, so the paper becomes
warm and the accent becomes deep plum. The ground is the whole identity.

Shipped values are `mobile/lib/ui/tokens.dart`; that file and this table must
agree.

| Role | Dark | Light |
| --- | --- | --- |
| Canvas | `#16111F` | `#F8F6F1` |
| Surface | `#211A2D` | `#FFFFFF` |
| Raised | `#2B233A` | `#F0EDE6` |
| Text | `#F3EFFA` | `#1A1620` |
| Muted | `#A89EA6` | `#6B6169` |
| Outline | `#A89EA6` | `#8A808A` |
| Accent | `#EDE4DA` | `#3A2E42` |
| On accent | `#1E1620` | `#FFFFFF` |
| Border | `rgb(168 158 166 / 60%)` | `rgb(26 22 32 / 50%)` |

Surfaces separate by **tone, not shadow**, over 1px hairlines. Structural radii
are 12 and 20; controls use 10, bubbles 18, pills 999. Rows are 62dp.

### Non-text boundary contrast

T43A measures the final painted boundary, including alpha compositing, against
every Material surface role used by the app. The minimum ratios are:

| Palette | Opaque `outline` | Composited `outlineVariant` |
| --- | ---: | ---: |
| Dark | 5.77:1 | 3.02:1 |
| Light | 3.25:1 | 3.29:1 |

The contract is covered by `mobile/test/chat_visuals_test.dart` and protects
both the token values and the surface-role mapping in `theme.dart`.
The `ConnectionBanner`'s error-container hairline is a decorative status
boundary; actionable error controls use the opaque `error` border and are
covered separately.

### The five bone temperatures

K2 is the second of five near-whites that differ only in temperature, plus a
muted grey biased to match — a neutral leaning toward its own bone reads as
chosen rather than inherited. All five are still used: `mobile/lib/ui/avatar.dart`
hashes an account ID across them to tint avatars (see §3).

| | Bone (dark) | Deep (light) | Muted | Character |
| --- | --- | --- | --- | --- |
| **K1 · Chalk** | `#F4F4F6` | `#332F3A` | `#A39FA6` | Starkest, most contemporary |
| **K2 · Bone** | `#EDE4DA` | `#3A2E42` | `#A89EA6` | Warm paper — **chosen** |
| **K3 · Greige** | `#DCD3C6` | `#403528` | `#A79C93` | Warmest, most analog |
| **K4 · Ash** | `#E4DDEA` | `#372C43` | `#A79EB4` | Leans into the plum |
| **K5 · Steel** | `#D8E0E8` | `#2C333B` | `#9FA8B4` | Coolest, most technical |

The order of that table is the order of `boneTints` in `avatar.dart`.
Reordering the list re-colours every existing avatar.

### The state palette

This is Bone's actual payoff. Every coloured direction spends a hue on brand,
which means that hue can no longer mean anything else — a green brand cannot use
green for "verified". Bone spends none, so all four states stay unambiguous.
Carried by `VeritraStateColors` in `tokens.dart`, except error, which is left to
`ColorScheme.error` so there is one source of truth.

| State | Dark | on plum | Light | on paper |
| --- | --- | --- | --- | --- |
| Verified | `#4ADE80` | 10.6 | `#15803D` | 4.56 |
| Warning | `#FBBF24` | 11.1 | `#B45309` | 4.57 |
| Error | `#FB7185` | 6.9 | `#BE123C` | 5.72 |
| Info | `#7DD3FC` | 11.1 | `#0369A1` | 5.40 |

**The light set only just clears AA** at 4.56 and 4.57. Keep those two at body
size or larger, and re-check them if the paper ground is ever lightened.

Every pair here was measured against WCAG 2.1 AA before being written down.
Re-run the check if any value changes.

### Interaction and fill rules

Interaction states use the bone itself rather than a second hue: hover lifts it
toward white, pressed drops it about 8%, disabled falls back to raised plum with
muted text. All keep on-accent text above 4.5:1.

**Sent bubbles stay on tone.** A near-white tiled down a whole column would blow
out the ground the direction is built on, so mine and theirs separate by one
tonal step plus a hairline, not by fill colour.

**No gradients.** That instruction applied to the rejected A and C. K2 uses a
single flat accent, so the `--grad` / `--grad-fill` split — and the contrast trap
in its middle stops — does not exist here. Nothing should introduce one.

---

## The screen spec

Section numbers are cited from source comments throughout `mobile/lib/`. Keep
them stable. Where the shipped result deliberately departs from the original
specification, the departure is recorded in place rather than in a separate list.

### §1 Typography

The single highest-leverage change. The theme previously customised **no** text
styles at all, so all twelve screens rendered default Roboto at default sizes.
That alone was most of why the app looked generic.

| Token | Size / weight / tracking | Used for |
| --- | --- | --- |
| `display` | 27 / 700 / -0.03em | Screen titles ("Chats") |
| `title` | 17 / 650 / -0.02em | Section and dialog headings |
| `body` | 14.5 / 400 / -0.01em | Default reading text |
| `label` | 13.5 / 600 | Row titles, buttons |
| `caption` | 11.5 / 400 | Row subtitles |
| `micro` | 11 / 700 / 0.11em / uppercase | Group headers, field labels, chips |
| `mono` | 13 / 400 | IDs, invite codes, fingerprints |

`micro` is what makes group headers and field labels read as designed rather
than as leftover `Text` widgets.

Landed **without bundling a font.** The ramp is carried on the platform faces
(SF on iOS, Roboto on Android), which is where nearly all of the improvement
comes from and avoids a `THIRD_PARTY_NOTICES.md` entry. Tracking is converted
from `em` to the logical pixels Flutter's `letterSpacing` expects.

### §2 The encrypted-message placeholder

**The worst thing in the old app.** An identical lock icon + `Encrypted message`
row rendered in every bubble.

The fix is not to invent plaintext. The ciphertext renders as **redacted bars**,
wrapping across up to three lines. The thread gets the rhythm and shape of a
real conversation while staying completely honest about having nothing to show.
It degrades correctly: when the mobile MLS path lands, real text replaces the
bars in the same bubble and nothing else about the layout moves.

**Bar widths are bucketed, and must stay bucketed.**
`ReceivedMessageEnvelope.ciphertext` is a `List<int>`, so `.length` is available
client-side with no new field and no decryption — but deriving width directly
from it makes **message length readable over someone's shoulder**. That is a
real regression against a threat this app takes seriously, and the old
identical-width bubbles happened not to have it. `redactedBarFractions`
(`chat_screen.dart`) buckets into six steps instead, leaking only a coarse
bucket.

`chat_visuals_test.dart` pins that property: two lengths in one bucket must
render identically, and the 0–5000 byte range must collapse to exactly six
shapes. A change back to linear fails that test rather than shipping quietly.

Each bubble keeps its `Semantics` wrapper.

### §3 The chat list

`ListTile` + `Divider(indent: 72)` was the most recognisably default surface in
the app. Now a 62dp `InkWell` row, no dividers, separated by spacing and a
subtle background on the active row.

- **Avatars tinted deterministically from the account ID** — computed locally,
  no server data involved. Previously every avatar was the same
  `secondaryContainer` colour, so the list had no visual anchors at all.
- Initials instead of a generic person icon for DMs; `#` for channels.
- Unread: a **dot** for one, a count for more. The old `_UnreadBadge` always
  showed a number, which over-weights a single message.
- Retention as its own chip rather than buried in a `' · '`-joined subtitle.
- Display-sized screen title.

**Deviation — avatars vary by bone temperature, not by hue.** The original spec
assumed a hue wheel to hash into. Bone deliberately has none; that is exactly
what keeps green, amber, red and blue free to mean verified, warning, error and
info. The hash picks one of the five §K temperatures instead. Same anchoring
effect, no collision with the state palette.

**Deviation — no `Pinned` / `All` group headers.** `Conversation` has no pin
concept and neither does the API (`mobile/lib/core/models.dart:64`). Adding the
headers means adding the feature, which is a behaviour change hiding inside a
visual one. Out until pinning is actually specified.

### §4 The composer

Was a bordered row of an icon, a filled `TextField`, and a button. Now a single
rounded pill containing all three.

The attachment button stays **visible but disabled** — a deliberate existing
choice that should not be quietly dropped.

**Deviation — the pill does not float over the thread.** The spec also asked for
the thread to stay visible behind it. That needs a `Stack` whose list padding
tracks a composer whose height changes with its content, and getting it wrong
overlaps the last message. The pill is where nearly all of the visual change is;
the float can follow once there is a toolchain to check it on.

### §5 The connect screen

Opened on a four-way `SegmentedButton` — Owner / Sign in / Join / Link — which
read like a debug menu and was the first thing a new user saw.

- Leads with the brand mark, the wordmark, and one line of positioning.
- Shows **one** path. The setup probe at `_probeSetupStatus` already detects
  whether the instance needs an owner, so the right mode is chosen without
  asking. The other three moved behind "Other ways to connect".
- Fields carry a floating `micro` label above the value instead of a Material
  `labelText` notched into the border, which is what made the form look like a
  form. Every field gained a `hintText` to buy back the accessible name that
  `labelText` supplied for free.

### §6 Settings, communities, search, details

Was six `Card`s of `ListTile` + `Divider` + trailing chevron — generic by
construction. Now an identity header (avatar, `@username`, instance host),
grouped rows on a tinted canvas, `micro` section headers, and **no chevrons**.
State facts moved out of `' · '`-joined subtitles and onto pills. Also covers
profile, device link, invites, blocked accounts and the search field.

The `errorContainer` treatment stays on the danger zone; it is doing real work.

### §7 Empty states

Was a `CircleAvatar` + icon. Now the concept-06 chain-link mark as low-opacity
line art. One shared widget already existed and was used consistently — only its
interior changed.

The mark family behind it was redrawn on Bone on 2026-08-18, so
`branding/concept-06/` and this document no longer disagree about the palette;
see [`branding/concept-06/README.md`](branding/concept-06/README.md).

### §8 Chrome

- **App bars**: a `display`-sized large title (`ui/widgets/large_title_bar.dart`)
  replacing the fixed 20px `AppBar`.
- **Nav**: a pill rather than the full-width `NavigationBar`.

**Deviation — app bars do not collapse on scroll.** A collapsing sliver has to
own the scroll view, so every screen using one also hands it their
`RefreshIndicator` and their list — a restructure of six screens for the second
half of the effect. The title size is the first half and it is one line per
screen.

**Deviation — the nav is a pill but does not float.** Same reasoning as the
composer, plus a specific hazard: two of the three destinations own a
`FloatingActionButton`, and floating the nav over the page puts a centred pill
and a bottom-right FAB in one strip with nothing arbitrating between them on a
narrow screen. It stays the `Scaffold`'s `bottomNavigationBar`, and says
`Semantics(selected:, button:)` itself — `NavigationBar` supplied that for free
and a `Row` of `InkWell`s does not.

### §9 Shared widgets

Three hand-rolled pill patterns existed — `_StateChip` (device link),
`_UnreadBadge` (chat list), `_DaySeparator` (conversation) — each a `Container`
with a 999 radius and its own colour logic. All three collapsed into
`StatusPill`/`StatusDot`.

**Contrast note.** The four state tones fill solid and put the ground colour on
top, rather than tinting a neutral pill. That is not a style preference:
measured against §K, a tinted pill lands at 3.58–4.25 in light mode and a
neutral pill with coloured text at 4.29 for verified and warning — both fail AA.
Solid fill measures 5.02–6.29 light and 6.88–11.11 dark. Re-run those numbers if
the widget is restyled.

`conversation_details_screen.dart` also duplicated `_SectionHeader` from
`settings_screen.dart` instead of sharing it. Now one `SectionHeader`, plus
`TileGroup`, `LargeTitleBar` and `VeritraMark`.

`VeritraMark` is a `CustomPainter`, not an SVG asset. Do **not** add
`flutter_svg` to draw the chain-link mark — it is two rounded rects and an arc,
which a painter renders with no dependency at all and scales better.

`TileGroup` is a `Material` that carries its own colour, border and radius.
It must not wrap `ListTile` in a decorated `Container`: `ListTile` paints its
background and ink splashes onto the nearest `Material` ancestor, so a decorated
box between them hides both and Flutter asserts on exactly that.

### §10 Motion

There was no custom motion anywhere — every navigation was the default
`MaterialPageRoute`. Now a shared-axis route with a list→detail avatar `Hero`
(`ui/motion.dart`), hand-written because `package:animations` would be a new
dependency for one `PageRouteBuilder`.

180ms ease-out is the standard duration, 120ms the short one. Callers must
respect `MediaQuery.disableAnimationsOf`.

### §11 The setup page

`server/websetup/index.html` is the first Veritra surface a self-hoster sees. It
now carries the wordmark rather than just the badge, on Bone tokens.

`server/websetup/websetup_test.go` requires four exact strings in that file and
forbids a `<form`. The rewrite keeps all four.

---

## Dependencies

`AGENTS.md` requires license review **and** a `THIRD_PARTY_NOTICES.md` update for
any new dependency. Nothing in this rebuild added one — no font, no `flutter_svg`,
no animation package. Keep it that way unless the ramp genuinely needs a bundled
face; Inter and Geist are both OFL-1.1 and would need `mobile/assets/fonts/`, a
`fonts:` block in `mobile/pubspec.yaml` (which has no `assets:` or `fonts:`
section at all), and an attribution.

## Test contracts

Two test files pump widgets and bind the screens above. These were worked around
rather than changed, and must keep passing.

`profile_screen_test.dart`:

| Must survive | Where |
| --- | --- |
| `@alice` rendered | header and username row |
| `Alice phone` as its own `Text` | current-device row |
| `owner`, lowercase, own `Text` | instance-role row |
| Tooltip `Copy Account ID` | `_IdentityRow` copy button |
| Tooltip `Copy Current device` | same |
| `Encryption identity pending` | static placeholder card |

So: don't merge those values into composite strings, don't title-case `owner`,
and don't replace the copy `IconButton`s with a menu. That test now scrolls
before asserting `Encryption identity pending`, because the taller profile
screen puts that group below the 800px test viewport and a `ListView` does not
build what it has not laid out. Keep the scroll if you add rows above it; do not
drop the assertion — that notice being genuinely on screen is a crypto-honesty
guarantee, and it survives scrolling.

`ui_remaining_test.dart`:

| Must survive | Why it constrains you |
| --- | --- |
| `@alice` / `@bob` as their own `Text` in the chat list | row titles cannot be merged into a composite string |
| no `Text` reading exactly `Direct message` in the chat list | a named DM's row subtitle must not be the kind |
| one `TextField` in the composer | no second field, no `EditableText` substitute |
| `Icons.send` inside an `IconButton` | `IconButton.filled` is fine; a bare `GestureDetector` is not |
| `SwitchListTile` on conversation details | the mute control stays a switch |
| `FilledButton` labelled `Remove` in the confirm dialog | dialog actions stay filled buttons |
| tooltips `Remove @alice`, `Block @alice`, `Unblock` | details-screen controls keep their tooltips and labels |
| `find.byType(Scrollable).first` is the details `ListView` | do not put another scrollable above it in that tree |
| `parseDeviceLinkCode` in `qr_scan_screen.dart` | `ui_actionable_test.dart` calls it directly |
| `No blocked accounts` as the empty-state title | `blocked_accounts_screen.dart` |
| `Offline` and "queued on this device" | `connection_banner.dart` |

The remaining test files are pure unit tests over `AppState`, models, error
mapping and the crypto bindings; they never call `pumpWidget`. `shortId`'s exact
`acct_012…cdef` output (`ui/format.dart`) is the one format-layer contract.
`chat_visuals_test.dart` covers bar bucketing, avatar tint stability and the
retention labels.

**Golden tests are the known gap.** None exist. A golden needs its reference PNG
generated by a real `flutter test --update-goldens`, and no toolchain was
available when the screens were written — committing one without its golden only
breaks the suite. **That constraint is gone:** the pinned Flutter image runs
through Docker. Generate them in the container, not on a host Flutter, or they
will encode a different font rasterisation and fail in CI.

## Accessibility

Preserved from before the rebuild — better than the visuals were, and easy to
destroy in a refactor:

- `MergeSemantics` on chat rows, so a screen reader announces each row once.
- `ExcludeSemantics` on decorative avatars and icons.
- `Semantics(liveRegion: true)` on pending-message bubbles.
- `Semantics(header: true)` on section headers.

Added by the rebuild:

- The retention chip carries the spoken form (`Disappearing after 1 day`) rather
  than letting a reader sound out `1d`, and the unread dot keeps the
  `n unread messages` label the count badge had — so dropping the number changed
  nothing for a screen reader.
- `StatusPill` takes a `semanticsLabel` for exactly that reason, and every
  compressed label in the app uses it.
- `SectionHeader` keeps `Semantics(header: true)` from both patterns it replaced,
  and excludes its trailing action from the header node.

Two things still need a real device and are part of card I24: 48dp minimum touch
targets (the `TileGroup` rows and the nav pill are built to it, but nothing has
measured them) and 200% text scale, where this dense direction will hurt first.
The redacted bars scale their height with the text scaler for that reason; the
pills and rows have not been checked at all.

## App icon

The Android `mipmap-*/ic_launcher.png` set and the fifteen images in
`mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/` are the chain-link mark
on the Bone palette, replacing the stock Flutter icon.

The source is `branding/concept-06/veritra-app-icon-bone.svg`. The old
Indigo→Sky icon it replaced now lives in `branding/concept-06/superseded/`,
which is where every file of that brand went — the directory itself is the
warning, so there is no longer a same-directory file to export by mistake.

Both sets were **re-rendered from the SVG on 2026-08-18** with macOS QuickLook
(`qlmanage -t`), replacing the earlier PNGs that had been encoded analytically
because no rasteriser was available at the time. Still no icon-generator
dependency: a new one means a license review and a `THIRD_PARTY_NOTICES.md`
entry per `AGENTS.md`, and QuickLook ships with the OS. The recovery technique
QuickLook needs — it composites onto opaque white, so alpha has to be recovered
from a white and a black render — is written up in
[`branding/concept-06/README.md`](branding/concept-06/README.md).

iOS images are full-bleed and opaque, and carry **no alpha channel at all**:
the system applies its own mask and rejects an alpha channel, including a fully
opaque one, so those files are written as PNG colour type 2. Android keeps the
squircle and its alpha corners.
