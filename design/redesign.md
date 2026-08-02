# What changes on each screen

These apply to **whichever direction is chosen** — only the skin differs. This
is the part that turns "restyled Material" into a designed app.

Ordered by impact.

## 1. Add a typography scale

The single highest-leverage change. `mobile/lib/ui/theme.dart` currently
customises **no** text styles at all, so all twelve screens render default Roboto
at default sizes. That alone is most of why the app looks generic.

| Token | Size / weight / tracking | Used for |
| --- | --- | --- |
| `display` | 27 / 700 / -0.03em | Screen titles ("Chats") |
| `title` | 17 / 650 / -0.02em | Section and dialog headings |
| `body` | 14.5 / 400 / -0.01em | Default reading text |
| `label` | 13.5 / 600 | Row titles, buttons |
| `caption` | 11.5 / 400 | Row subtitles |
| `micro` | 10 / 700 / 0.11em / uppercase | Group headers, field labels, chips |
| `mono` | 13 / 400 | IDs, invite codes, fingerprints |

`micro` is what makes the group headers and field labels read as designed rather
than as leftover `Text` widgets. It does not exist anywhere in the app today.

## 2. Fix the encrypted-message placeholder

**The worst thing in the app.** `chat_screen.dart:396-415` renders an identical
lock icon + `Encrypted message` row in every single bubble, so a conversation is
a stack of identical grey blocks. Open `preview.html` and compare rows 1 and 2 —
this is the most visible difference between today and any direction.

The fix is not to invent plaintext. Render the ciphertext as **redacted bars
whose widths derive from the envelope's byte length**, wrapping across two or
three lines for longer messages. The thread then has the rhythm and shape of a
real conversation while remaining completely honest about having nothing to
show.

It also degrades correctly: when the mobile MLS path lands and real plaintext
becomes available, the bars are replaced by text in the same bubble, and nothing
else about the layout moves.

Keep a screen-reader label on each bubble — the existing `Semantics` wrapper at
`chat_screen.dart:362` already does this and should be preserved verbatim.

## 3. Rebuild the chat list

`chat_list_screen.dart` — `ListTile` + `Divider(indent: 72)` is the most
recognisably default surface in the app.

- Drop dividers. Rows separate by spacing and a subtle background on the active
  row.
- **Avatars tinted from a hash of the account ID** — deterministic, computed
  locally, no server data involved. Currently every avatar is the same
  `secondaryContainer` colour, so the list has no visual anchors at all.
- Initials instead of a generic person icon for DMs; keep `#` for channels.
- Unread: a **dot** for one, a count for more. The current
  `_UnreadBadge` always shows a number, which over-weights a single message.
- `Pinned` / `All` group headers in the `micro` style.
- Retention shown as a `24h` chip rather than buried in the
  `' · '`-joined subtitle from `conversationSubtitle`.

## 4. Float the composer

`chat_screen.dart:442` is a bordered row of an icon, a filled `TextField`, and a
button. Replace with a single rounded pill containing all three, floating above
the keyboard with the thread visible behind it.

Keep the attachment button **visible but disabled** — that is a deliberate
choice already documented at `chat_screen.dart:466-471` and should not be
quietly dropped.

## 5. Simplify the connect screen

`connect_screen.dart:103` opens on a four-way `SegmentedButton` — Owner / Sign
in / Join / Link — which reads like a debug menu and is the first thing a new
user sees.

- Lead with the brand mark, the wordmark, and one line of positioning.
- Show **one** path. The setup probe at `_probeSetupStatus` already detects
  whether the instance needs an owner, so the right mode can be chosen without
  asking.
- Everything else moves behind a single "Other ways to connect" link.
- Fields get a floating `micro` label above the value instead of a Material
  `labelText`, which is what makes the current form look like a form.

## 6. Regroup settings

`settings_screen.dart` is six `Card`s of `ListTile` + `Divider` + trailing
chevron — generic by construction.

- An identity header at the top: avatar, `@username`, instance host.
- Grouped rows on a tinted canvas, `micro` section headers, **no chevrons**.
- Keep the `errorContainer` treatment on the danger zone; it is doing real work.

## 7. Empty states

`ui/widgets/empty_state.dart` uses a `CircleAvatar` + icon. Replace with the
concept-06 chain-link mark as low-opacity line art. One shared widget already
exists and is used consistently — only its interior changes.

## 8. Chrome

- **App bars**: large title (`display`) that shrinks into a compact bar on
  scroll, replacing the fixed 20px `AppBar`.
- **Nav**: a floating pill above the bottom edge rather than the full-width
  `NavigationBar`. Terminal is the exception — it keeps an edge-to-edge bar,
  which suits its density.

## 9. One `StatusPill` widget

Three hand-rolled pill patterns exist today:

- `device_link_screen.dart:189` — `_StateChip`
- `chat_list_screen.dart:158` — `_UnreadBadge`
- `chat_screen.dart:323` — `_DaySeparator`

All three are a `Container` with `BorderRadius.circular(999)` and a themed
background. Collapse into one widget with `neutral` / `accent` / `warning`
variants.

Similarly, `conversation_details_screen.dart` duplicates the `_SectionHeader`
pattern from `settings_screen.dart:416` instead of sharing it. Extract one.

## 10. Motion

There is no custom motion anywhere in the app — every navigation is the default
`MaterialPageRoute`.

- Shared-axis transition between chat list and conversation.
- `Hero` on the conversation avatar, list → detail.
- 180ms ease-out as the standard duration; Aurora can afford a gentle spring,
  Terminal should stay at 120ms linear.
- Respect `MediaQuery.disableAnimationsOf`.

## 11. Setup page

`server/websetup/index.html` is the first Veritra surface a self-hoster sees. It
is already close — it uses the concept-06 mark and a matching palette — but it
should carry the **wordmark**, not just the badge, and its CSS variables
(lines 12–26) should be renamed to match the chosen direction's token names so
the two stay in sync.

## Out of scope

Nothing here touches crypto, storage, sync, or the `PM_CRYPTO_UNAVAILABLE`
release gate. The encrypted-bubble change in §2 reads an envelope's byte length,
which the client already has — it does not decrypt anything or add a field.
