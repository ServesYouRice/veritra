# UI and UX issues

Reviewed against the working tree including the uncommitted **K2 · Bone** visual
rebuild (card I28), and against the per-screen spec in
[`docs/design.md`](../docs/design.md).

**Context.** The rebuild is good work. The screens have real empty states, real
error states with retry, real loading states, operation-scoped busy flags,
`MergeSemantics` on rows, `Semantics` labels on non-text indicators, bounded
timestamp columns, and design rationale left in the source. Findings below are
against that standard, not a low one.

**Two caveats on method.** Nothing was rendered — `flutter test` proves the
screens build, and this audit reads source and computes colour values; neither
proves they look right. And the crypto-gated screens (reply, edit, delete,
reactions, attachments, safety numbers, decrypted text) are deliberately
unavailable and are **not** reported as missing.

| ID | Severity | Title | Where | Blocker |
| --- | --- | --- | --- | --- |
| [U1](#u1) | **High** | Form and control boundaries fail WCAG 1.4.11 (≈1.4:1) | `ui/tokens.dart`, `ui/theme.dart` | **Yes** |
| [U2](#u2) | **High** | Connect screen is prefilled with a URL that cannot work on a device | `connect_screen.dart` | **Yes** |
| [U3](#u3) | **High** | "Sign in" is the default mode but always fails on a fresh install | `connect_screen.dart` | **Yes** |
| [U4](#u4) | Medium | No feedback when the server is unreachable | `connect_screen.dart` | No |
| [U5](#u5) | Medium | Chat-list timestamps are always a full date, never a time | `ui/format.dart` | No |
| [U6](#u6) | Medium | Master-detail layout activates in phone landscape | `ui/app_shell.dart` | No |
| [U7](#u7) | Medium | No scroll-to-latest or "new messages" affordance | `chat_screen.dart` | No |
| [U8](#u8) | Medium | Disabled attachment button explains itself only via tooltip | `chat_screen.dart` | No |
| [U9](#u9) | Medium | Every state change rebuilds the whole app and both themes | `main.dart` | No |
| [U10](#u10) | Medium | Switching tabs destroys page state | `ui/app_shell.dart` | No |
| [U11](#u11) | Medium | New-conversation sheet: toast-only validation, no scroll | `new_conversation_sheet.dart` | No |
| [U12](#u12) | Medium | No localisation delegates; dates forced to en-US | `main.dart` | No |
| [U13](#u13) | Medium | No open-source licences screen | `settings_screen.dart` | No |
| [U14](#u14) | Medium | `veritra://` device-link URI has no handler | `AndroidManifest.xml`, `Info.plist` | No |
| [U15](#u15) | Low | Quota (507) has no user-facing message | `core/api_client.dart` | No |
| [U16](#u16) | Low | Nav pill labels truncate at small widths and large text | `ui/app_shell.dart` | No |
| [U17](#u17) | Low | No in-app light/dark setting | `main.dart` | No |
| [U18](#u18) | Low | "Coming soon" section ships in Settings | `settings_screen.dart` | No |
| [U19](#u19) | Low | Composer has no keyboard send and no length feedback | `chat_screen.dart` | No |
| [U20](#u20) | Low | 10px `micro` type carries headers, labels and chips | `ui/tokens.dart` | No |
| [U21](#u21) | Low | Sign out is the only destructive action without confirmation | `settings_screen.dart` | No |
| [U22](#u22) | Low | Terminally-failed messages cannot be recovered or copied | `chat_screen.dart` | No |
| [U23](#u23) | Low | No chat-list row actions (mute, mark read, leave) | `chat_list_screen.dart` | No |

---

## U1

### Form and control boundaries fail WCAG 1.4.11 (≈1.4:1)

**Severity:** High
**Location:** [`mobile/lib/ui/tokens.dart:29`](../mobile/lib/ui/tokens.dart#L29) and `:42` (`darkBorder`, `lightBorder`); mapped to `outlineVariant` at [`mobile/lib/ui/theme.dart:46`](../mobile/lib/ui/theme.dart#L46) and `:82`; consumed as a control boundary at `theme.dart:168`, `:172`, `:196`, `:214`, `:220`, `:267`

**Problem**

`outlineVariant` is `darkBorder = 0x17ffffff` (9% white) in dark and
`lightBorder = 0x1c1a1620` (11% of the text colour) in light. It is used as the
`BorderSide` for **`InputDecorationTheme.enabledBorder`**, cards, `TileGroup`,
chips, the composer pill, the floating nav pill, message bubbles, and dividers —
i.e. for the visual boundary of interactive controls, not only decorative rules.

Computed from the sRGB relative-luminance formula, dark theme:

| Pair | Ratio | Required |
| --- | --- | --- |
| Field fill `surfaceContainer` `#211a2d` vs canvas `#16111f` | **1.09 : 1** | — |
| `outlineVariant` composited (≈`#3a3444`) vs canvas | **1.53 : 1** | 3 : 1 (SC 1.4.11) |
| `outlineVariant` composited vs field fill | **1.40 : 1** | 3 : 1 (SC 1.4.11) |

For comparison, the *text* pairs the design doc measured do pass —
`darkMuted #a89ea6` on `darkCanvas #16111f` is **7.08 : 1**, comfortably above
the 4.5 : 1 that SC 1.4.3 requires.

That is the precise gap: `docs/design.md:99` says *"Every pair here was measured
against WCAG 2.1 AA before being written down."* That statement is true for
**text** contrast (SC 1.4.3). **Non-text contrast (SC 1.4.11)**, which governs
"the visual information required to identify user interface components and
states", was never measured — the doc contains no such table. `tokens.dart:11-13`
repeats the claim, so both the code and the spec assert a check that was not
performed for this class.

**Why it matters in production**

Text fields are effectively invisible at rest. In dark mode the fill is 1.09:1
against the canvas and its border is 1.53:1 — a user cannot see where a field
begins or how many fields there are until one is focused. The screen where this
hurts most is the **first screen anyone sees**: `ConnectScreen` is five stacked
text fields, and it is the only screen a new user must complete before the app
does anything.

It also degrades for reasons unrelated to disability: outdoors in daylight, on
inexpensive LCD panels, with a screen-dimming filter on, or at an off-axis
viewing angle, a 1.4:1 edge disappears entirely.

Finally, this affects the sent/received bubble distinction. `docs/design.md:112`
states *"mine and theirs separate by one tonal step plus a hairline, not by fill
colour."* Both halves of that separation are sub-3:1, so the only robust
distinction left is alignment. Alignment does carry it, and the `Semantics`
labels are correct for screen readers — but a low-vision user who is not using a
screen reader has one weak cue where the design intends two.

**Fix**

This is one token, changed twice, and it fixes every affected surface at once.

1. **Split the roles.** `outlineVariant` in Material 3 is intended for
   *decorative dividers*; `outline` is intended for *component boundaries*.
   `theme.dart` already defines `outline` (`darkOutline #6f6675`, which measures
   **3.35 : 1** against the canvas and passes). Point
   `InputDecorationTheme.enabledBorder`, chip borders, `TileGroup` borders and
   the composer/nav pill borders at `outline`; leave `outlineVariant` for
   `DividerTheme` and bubble hairlines only.
2. **Raise the field fill.** `surfaceContainer` at 1.09:1 against the canvas is
   not a visible surface. Use `surfaceContainerHigh` (`darkRaised #2b233a`) for
   `fillColor`, or introduce a dedicated field-fill token one further step from
   the canvas.
3. **Add a 1.4.11 table to `docs/design.md`.** The doc has an excellent 1.4.3
   table; add its non-text counterpart covering field borders, focus rings, chip
   outlines, dividers and bubble hairlines, so the claim at `design.md:99`
   becomes true for both criteria.
4. **Add a test.** A pure-Dart contrast helper plus a unit test asserting ≥3:1
   for the control-boundary pairs and ≥4.5:1 for the text pairs makes this a
   permanent guarantee rather than a one-time check. This is cheap and there is
   already a `chat_visuals_test.dart` to extend.
5. Re-check the light palette the same way — `lightBorder` at 11% of `lightText`
   over `lightSurface #ffffff` has the same problem.

**Blocker:** **Yes.** It is an accessibility conformance failure on the primary
input surface, it contradicts a documented claim, and it is a one-token fix.

**Related risks**

- Interacts with [U20](#u20): 10px labels *and* invisible field boundaries
  compound on the same screens.
- Card **I24** step 5 requires TalkBack/VoiceOver/large-text checks. Those will
  pass — screen-reader semantics are correct — while a sighted low-vision user
  still cannot use the form. Add a contrast check to that manual pass explicitly.
- Fixing this changes the look of every screen, so it should land **before** the
  I28 tree is committed, not after.

---

## U2

### Connect screen is prefilled with a URL that cannot work on a device

**Severity:** High
**Location:** [`mobile/lib/features/auth/connect_screen.dart:28`](../mobile/lib/features/auth/connect_screen.dart#L28); validator at `:369-386`; platform config at [`mobile/android/app/src/main/AndroidManifest.xml`](../mobile/android/app/src/main/AndroidManifest.xml) (`usesCleartextTraffic="false"`) and [`mobile/ios/Runner/Info.plist`](../mobile/ios/Runner/Info.plist) (no ATS exception)

**Problem**

```dart
final url = TextEditingController(text: 'http://localhost:8080');
```

The very first field a new user sees is pre-filled with a value that cannot work
on a phone, for two independent reasons:

1. `localhost` on a handset is the handset. There is no server there.
2. Even against a correct host, `http://` is blocked at the platform layer —
   Android sets `usesCleartextTraffic="false"` and iOS has no App Transport
   Security exception. The request fails inside the socket layer before any
   Veritra code runs.

`_validateUrl` (`:369-386`) accepts any `http` or `https` origin. It rejects
paths, queries and credentials — good — but says nothing about the scheme. So the
form validates cleanly and then fails opaquely at submit with whatever
`describeError` makes of a `SocketException`.

Blocking cleartext is the right decision for a privacy product. The problem is
that nothing in the product tells the user, and the default value contradicts it.

**Why it matters in production**

This is the first thirty seconds of the product for every user, and the default
guarantees failure with a network-level error rather than an explanation. For a
self-hosted app the connect screen *is* the onboarding — there is no app-store
account, no magic link, nothing else. It has to be right.

It also breaks the documented quickstart: `README.md:62` tells the reader to open
`http://localhost:8080`, which works in a desktop browser and can never work from
the app.

**Fix**

1. **Empty the field.** The hint is already correct
   (`https://chat.example.org`); let it do its job.
2. **Reject cleartext in the validator**, with an actionable message rather than
   a rule: *"Veritra requires HTTPS. If you are self-hosting, put your server
   behind a TLS proxy — `deploy/caddy/` sets this up automatically."* Link or
   quote the Compose Caddy profile, which already exists and solves exactly this.
3. **Decide and document the LAN case.** A self-hosted instance on a home network
   with no public DNS cannot get a Let's Encrypt certificate. Today that user is
   simply blocked with no explanation. Pick one and write it down:
   (a) HTTPS-only, with the Caddy internal-CA path documented; or
   (b) an explicit, deliberately awkward "trust this certificate" flow showing the
   fingerprint. Do not leave it undefined.
4. **Fix the README quickstart** to say the browser page is browser-only and that
   the app requires an HTTPS origin.

**Blocker:** **Yes.** First-run failure with no diagnosis.

**Related risks**

- Pairs with [U3](#u3) and [U4](#u4); all three land on the same screen and
  should be fixed together as one onboarding pass.
- iOS additionally needs `NSLocalNetworkUsageDescription` for any LAN address —
  see [`production-readiness.md` R15](production-readiness.md#r15).

---

## U3

### "Sign in" is the default mode but always fails on a fresh install

**Severity:** High
**Location:** [`mobile/lib/features/auth/connect_screen.dart:37`](../mobile/lib/features/auth/connect_screen.dart#L37); server precondition at [`server/internal/httpapi/auth_handlers.go:210-213`](../server/internal/httpapi/auth_handlers.go#L210-L213) and `:226`

**Problem**

The screen defaults to `AuthMode.signIn` and offers username + password. But the
server requires **three** credentials:

```go
if strings.TrimSpace(req.DeviceID) == "" {
    writeError(w, http.StatusBadRequest, "device_id_required"); return
}
...
deviceOK := lookupErr == nil && record.DeviceAuthHash != "" &&
    subtle.ConstantTimeCompare([]byte(auth.HashToken(req.DeviceSecret)), []byte(record.DeviceAuthHash)) == 1
```

`device_id` and `device_secret` come only from a previously stored local session
(`AppState.login` reads them from `localStore`). A fresh install has neither.

So "Sign in" works **only** on a device that already enrolled and still holds its
secret. On a new phone, after a reinstall, or after the keystore reset described
in [`logical-issues.md` L7](logical-issues.md#l7), it cannot succeed — the user
must link from an existing device or register with a fresh invite.

This is a sound security design: the device secret is a real second factor and it
is why a stolen password alone is not enough. The problem is purely presentational
— the default mode is the one that cannot work for a new user, and the
explanation arrives only as a failure message after they have typed their
credentials ("This device must be linked before password sign-in").

**Why it matters in production**

Every new user starts here and the default is wrong for them. Worse, the failure
looks like *"my password is wrong"*, so the natural response is to retry — which
walks straight into the per-username login backoff
(`login_backoff.go:72-79`, three failures then escalating delays), making the
"wrong password" theory look confirmed.

**Fix**

1. **Choose the default from local state, not a constant.** If no stored device
   identity exists, default to `AuthMode.linkDevice` (or `join` when the URL bar
   is empty). Reserve `signIn` for when a device identity is present. The screen
   already picks `owner` from a server probe (`:79-83`), so the machinery exists.
2. **Explain the model where it applies.** Under the sign-in fields, one line:
   *"Signing in needs this device to be linked. New phone? Use **Link this
   device** or an invite."* — with the phrase as a button that switches mode.
3. **Make the failure recoverable.** When `device_id_required` /
   `device_session_required` comes back, offer a direct "Link this device
   instead" action rather than only a sentence.
4. Consider surfacing this in `docs/overview.md` too — the three-credential model
   is unusual and deserves a paragraph.

**Blocker:** **Yes.** The default path in the first-run flow cannot succeed for a
new user.

**Related risks**

- Amplified by [L7](logical-issues.md#l7): a keystore reset silently converts an
  existing user into this case with no explanation.
- There is no password-reset flow at all; owner recovery is CLI-only
  (`reset-owner-password`) and non-owner recovery does not exist. See
  [nice-to-haves.md](nice-to-haves.md).

---

## U4

### No feedback when the server is unreachable

**Severity:** Medium
**Location:** [`mobile/lib/features/auth/connect_screen.dart:70-85`](../mobile/lib/features/auth/connect_screen.dart#L70-L85); `checkSetupRequired` at [`mobile/lib/core/app_state.dart:196-204`](../mobile/lib/core/app_state.dart#L196-L204)

**Problem**

The URL field is debounced 600 ms and probed. `checkSetupRequired` swallows
everything:

```dart
} catch (_) {
  return null;      // "unknown"
}
```

`setupRequired == null` renders nothing at all. The screen looks identical for
*"still typing"*, *"host does not resolve"*, *"connection refused"*, *"TLS
certificate rejected"*, and *"this is not a Veritra server"*.

**Why it matters in production**

The probe already knows the answer to the most common first-run question — "is
this URL right?" — and throws it away. The user only finds out at submit, and
then gets a generic message. Combined with [U2](#u2), the most likely first-run
outcome is a blank screen followed by an unexplained failure.

**Fix**

1. Have `checkSetupRequired` return a small result type distinguishing
   `reachable(setupRequired)`, `unreachable(reason)` and `notVeritra`, instead of
   `bool?`.
2. Render each: a subtle spinner while probing; a green "Server reachable —
   *Instance Name*" line on success (the endpoint already returns
   `instance_name`); an amber callout naming the failure otherwise. The `_Callout`
   widget already exists and is used for the fresh-instance case.
3. Map the common causes to plain language: DNS failure → "That address could not
   be found"; TLS failure → "The server's certificate was not accepted"; non-JSON
   response → "That address does not look like a Veritra server."

**Blocker:** No — but fix it with [U2](#u2) and [U3](#u3) as one pass.

---

## U5

### Chat-list timestamps are always a full date, never a time

**Severity:** Medium
**Location:** [`mobile/lib/features/chat/chat_list_screen.dart:256`](../mobile/lib/features/chat/chat_list_screen.dart#L256); helper at [`mobile/lib/ui/format.dart:11-13`](../mobile/lib/ui/format.dart#L11-L13)

**Problem**

```dart
String formatDate(BuildContext context, DateTime time) =>
    MaterialLocalizations.of(context).formatMediumDate(time.toLocal());
```

Every conversation row renders a medium date. A message from two minutes ago and
one from this morning both read *"Fri, Aug 8"*. Every conversation active today —
which is most of them, in an active list — shows an identical string.

The same helper is reused for the in-conversation day separator
(`chat_screen.dart:362`), where a full date is correct.

**Why it matters in production**

Recency ordering is the chat list's main job, and the timestamp column is how a
user confirms it at a glance. A column of identical strings conveys nothing and
occupies the 112 dp reserved for it. Every comparable product (WhatsApp, Signal,
Telegram, iMessage) uses the same convention: time for today, "Yesterday",
weekday within the last week, date beyond that.

**Fix**

Add a distinct `formatRelativeStamp(context, time)` for list rows:

| Age | Render | Example |
| --- | --- | --- |
| Today | time of day | `14:32` |
| Yesterday | word | `Yesterday` |
| Within 7 days | weekday | `Tuesday` |
| Older | medium date | `Aug 1` |
| Different year | date with year | `Aug 1, 2025` |

Keep `formatDate` for day separators and detail screens. `MaterialLocalizations`
already provides `formatTimeOfDay`, and `formatMediumDate`; "Yesterday" and
weekday names need real localisation — see [U12](#u12), which should be fixed
first so this can be localised properly rather than hardcoded.

**Blocker:** No.

---

## U6

### Master-detail layout activates in phone landscape

**Severity:** Medium
**Location:** [`mobile/lib/ui/app_shell.dart:21`](../mobile/lib/ui/app_shell.dart#L21) and `:53`

**Problem**

```dart
static const double _railBreakpoint = 720;
...
final wide = MediaQuery.sizeOf(context).width >= AppShell._railBreakpoint;
```

Width only. A large phone in landscape is roughly 850 × 390 logical pixels, so it
crosses the breakpoint and gets:

- a `NavigationRail` with `labelType: all` down the left edge,
- a fixed **360 px** chat-list pane (`_ChatWorkspace`, `:248`),
- the conversation squeezed into the remaining ~410 px,
- all inside ~390 px of height, minus the rail, minus the connection banner,
  minus the keyboard when the composer is focused.

With the keyboard open the message list has almost no vertical space, and the
360 px list pane is nearly as wide as the conversation it is meant to be
subordinate to.

**Why it matters in production**

Phone landscape is not rare — it happens on every rotation, and `Info.plist`
explicitly permits landscape on iPhone
(`UISupportedInterfaceOrientations` includes both landscape values). A layout
intended for tablets appearing on a phone whenever it is turned sideways reads as
a bug, and it is the state in which the composer is least usable.

**Fix**

1. Gate on **both** dimensions:
   ```dart
   final size = MediaQuery.sizeOf(context);
   final wide = size.width >= 720 && size.height >= 600;
   ```
   Or use `size.shortestSide >= 600`, the conventional tablet test, which is
   orientation-independent by construction.
2. Make the list pane flexible rather than fixed — a `Flexible` with a 300–400 px
   clamp — so the 720–900 px band is not two cramped columns.
3. If a phone-landscape layout is genuinely wanted later, design it; do not let
   the tablet layout fall into it by accident.
4. Add a widget test at 850 × 390 asserting the single-pane layout, and one at
   1024 × 768 asserting master-detail.

**Blocker:** No.

---

## U7

### No scroll-to-latest or "new messages" affordance

**Severity:** Medium
**Location:** [`mobile/lib/features/chat/chat_screen.dart:37-67`](../mobile/lib/features/chat/chat_screen.dart#L37-L67) and `:328-374`

**Problem**

`_ChatScreenState` owns a `ScrollController` used for one purpose — loading older
history near `maxScrollExtent`. There is no counterpart for new messages.

The list is `reverse: true`, so new messages are inserted at index 0. Flutter's
reverse mode keeps the viewport anchored at its current offset, so a user who has
scrolled up **stays** scrolled up while new messages arrive silently below them.
Nothing indicates that anything happened: no jump-to-bottom button, no unread
divider, no count badge.

There is also no scroll-to-bottom after sending. The user's own message may land
offscreen.

**Why it matters in production**

Scrolling up to re-read something is a constant behaviour in messaging. In this
build, doing so silently stops you receiving — you will not know a reply arrived
until you manually scroll back. The pending-message bubble that appears on send
is likewise invisible if you are not already at the bottom, so the send
confirmation is lost too.

**Fix**

1. Track "at bottom" from the controller (`pixels < 80` in a reversed list).
2. Auto-scroll to index 0 when a new message arrives **and** the user is at
   bottom, and unconditionally after the user's own send.
3. When not at bottom, show a floating jump-to-latest button above the composer
   with an unread count. `state.messagesFor(...)` already gives the length to
   diff against, and `AppState` already tracks per-conversation unread counts.
4. Consider an unread divider on entry — `markNewestMessageRead` already knows
   the boundary.
5. Respect `MediaQuery.disableAnimationsOf` when animating, consistent with the
   note in `ui/tokens.dart:87-88`.

**Blocker:** No.

---

## U8

### Disabled attachment button explains itself only via tooltip

**Severity:** Medium
**Location:** [`mobile/lib/features/chat/chat_screen.dart:732-738`](../mobile/lib/features/chat/chat_screen.dart#L732-L738)

**Problem**

```dart
IconButton(
  onPressed: null,
  icon: const Icon(Icons.attach_file),
  tooltip: 'Attachments require client crypto (coming soon)',
),
```

A `null` `onPressed` disables the button. A disabled Flutter `IconButton` does not
respond to long-press, so the tooltip never appears on touch — the only way to see
it is a mouse hover, which does not exist on the target platforms. Disabled
controls are also skipped by TalkBack and VoiceOver traversal, so screen-reader
users get nothing.

The result is a permanently greyed-out paperclip in the composer of a messaging
app, with no reachable explanation on any supported input method.

**Why it matters in production**

The intent — be honest that attachments are not ready — is right, and matches the
project's stance elsewhere. The execution makes the honesty unreachable. Users
will read a dead paperclip as "the app is broken", which is a worse conclusion
than the truth.

**Fix**

1. Keep the button **enabled** and have `onPressed` show the explanation: a
   `SnackBar` or a small dialog saying attachments arrive with end-to-end
   encryption. An enabled control is focusable, announced, and long-pressable.
2. Add `Semantics(label: 'Attachments, not yet available')` so it is announced
   correctly regardless.
3. Apply the same pattern to the other gated affordances — the "Coming soon"
   tiles in Settings ([U18](#u18)) have the same shape.
4. Document the convention in `docs/design.md`: gated features are *enabled and
   explanatory*, never silently disabled. That is a durable rule the remaining
   crypto-gated UI will need repeatedly.

**Blocker:** No.

---

## U9

### Every state change rebuilds the whole app and both themes

**Severity:** Medium
**Location:** [`mobile/lib/main.dart:44-58`](../mobile/lib/main.dart#L44-L58)

**Problem**

```dart
return AnimatedBuilder(
  animation: state,
  builder: (context, _) => MaterialApp(
    theme: veritraLightTheme(),
    darkTheme: veritraDarkTheme(),
    home: AppShell(state: state),
  ),
);
```

`AppState` is a single ~1,900-line `ChangeNotifier` that calls `notifyListeners()`
for every message, typing event, sync tick, busy-flag change and connection-status
change. Each one rebuilds `MaterialApp` and **constructs two fresh `ThemeData`
objects**, which is among the more expensive object graphs Flutter builds — a full
`ColorScheme`, `TextTheme`, and roughly a dozen component sub-themes, twice, per
notification.

It also marks the entire subtree dirty, so `ChatListScreen` — a `StatelessWidget`
with no listener of its own — re-renders on unrelated changes such as a typing
indicator in a different conversation.

`ChatScreen` compensates with its own `AnimatedBuilder` (`chat_screen.dart:71`),
with a comment explaining that pushed routes sit outside the root scope. So the
codebase has two different rebuild strategies and the root one is the costly one.

**Why it matters in production**

Rebuild cost lands exactly when the app is busiest: during catch-up after a period
offline, when `notifyListeners()` fires repeatedly while message lists mutate. It
compounds with [`performance-issues.md` P6](performance-issues.md#p6) (linear
roster scans per bubble per frame) to produce jank precisely when the user is
watching the app catch up.

**Fix**

1. Hoist the themes out of the builder — `static final _light = veritraLightTheme();`
   — so they are built once. Zero-risk, immediate win.
2. Move the listener **below** `MaterialApp`: keep `MaterialApp` static and wrap
   only `AppShell` in a `ListenableBuilder`.
3. Longer term, split `AppState` or expose narrower `Listenable`s
   (conversation list, selected-conversation messages, connection status) so a
   typing event in conversation A does not rebuild conversation B. `ValueNotifier`
   or `InheritedNotifier` selectors are enough; no new dependency needed.
4. Measure before and after with the Flutter DevTools timeline during a
   simulated catch-up, so the improvement is evidence and not assertion.

**Blocker:** No.

---

## U10

### Switching tabs destroys page state

**Severity:** Medium
**Location:** [`mobile/lib/ui/app_shell.dart:57-63`](../mobile/lib/ui/app_shell.dart#L57-L63) and `:102`

**Problem**

```dart
final pages = <Widget>[ ..., CommunityScreen(...), SettingsScreen(...) ];
...
Expanded(child: pages[index])
```

Only the selected page is mounted. Switching destroys the previous page's
`State`, so scroll offsets, expanded sections, and any partially-entered form
input are lost and never restored.

**Why it matters in production**

Concretely: scroll halfway down a long chat list, check Settings, come back — you
are at the top again. In Communities, an expanded channel list collapses. Users
read this as the app forgetting where they were.

**Fix**

Use `IndexedStack` to keep all three mounted (three light screens; the cost is
negligible), or attach a `PageStorageKey` to each scrollable so offsets restore.
`IndexedStack` is the smaller change and also removes the rebuild on switch.

If lazy construction matters, `IndexedStack` combined with a "has been visited"
set gives both.

**Blocker:** No.

---

## U11

### New-conversation sheet: toast-only validation, no scroll

**Severity:** Medium
**Location:** [`mobile/lib/features/chat/new_conversation_sheet.dart:49-104`](../mobile/lib/features/chat/new_conversation_sheet.dart#L49-L104) and `:107-129`

**Problem**

Two issues in one sheet.

**Validation is transient and detached.** `_validate` returns a string and
`_submit` shows it in a `SnackBar`. The `TextField` for the group name has no
`errorText`, there is no `Form`/`GlobalKey<FormState>`, and nothing marks *which*
field is wrong. A snackbar appears at the bottom of the screen — behind or beside
the sheet — for a few seconds and disappears. `ConnectScreen` does this properly
with `TextFormField` + `validator` + `AutovalidateMode.onUserInteraction`, so the
better pattern already exists in the codebase.

**The sheet cannot scroll.** The body is a `Column(mainAxisSize: min)` with no
`SingleChildScrollView`. `isScrollControlled: true` allows the sheet to grow but
the content itself cannot scroll. With the group name field, the account picker
and its results list, plus a large text scale or an open keyboard, the content
overflows — the yellow-and-black overflow banner in debug, silently clipped
controls in release.

**Why it matters in production**

Creating a conversation is the primary action of the app — it is what the FAB
does. A user at 150% text scale may not be able to reach the "Create group"
button at all.

**Fix**

1. Wrap the body in `SingleChildScrollView` and give the sheet a
   `maxHeight` of ~0.85 × screen height via `constraints`.
2. Convert to `Form` + `TextFormField` with `validator` and
   `AutovalidateMode.onUserInteraction`, matching `ConnectScreen`. Keep the
   snackbar only for submit-time server errors.
3. Show the member-count requirement inline near the picker rather than only on
   failed submit.
4. Show busy state on the button (a spinner in the icon slot, as
   `ConnectScreen:157-164` does) rather than only disabling it.
5. Add a golden or widget test at 150% text scale asserting no overflow.

**Blocker:** No.

---

## U12

### No localisation delegates; dates forced to en-US

**Severity:** Medium
**Location:** [`mobile/lib/main.dart:49-55`](../mobile/lib/main.dart#L49-L55)

**Problem**

`MaterialApp` declares no `localizationsDelegates` and no `supportedLocales`, and
`flutter_localizations` is not in `pubspec.yaml`. Two consequences:

1. Only `DefaultMaterialLocalizations` is available, so
   `MaterialLocalizations.of(context).formatMediumDate(...)` and
   `formatTimeOfDay(...)` — used throughout `ui/format.dart` — render in en-US
   regardless of device locale. A German or Japanese user sees US-formatted dates.
2. Every string in the app is a hardcoded English literal. There is no ARB file,
   no `AppLocalizations`, no extraction path.

**Why it matters in production**

Veritra is an open-source, self-hostable privacy messenger — a category whose
users are disproportionately non-US and specifically motivated by *not* accepting
defaults imposed on them. Every comparable project (Signal, Element, Briar) ships
community translations, and translation is one of the easiest ways for
non-programmers to contribute to an open-source project. Retrofitting i18n after
launch means touching every widget file again.

Also relevant: RTL layout is untested. Flutter handles most of it automatically
via `Directionality`, but the hand-rolled `_FloatingNav` and several
`EdgeInsets.fromLTRB` calls in the new Bone widgets should be checked once a
delegate exists to test with.

**Fix**

1. Add `flutter_localizations` and set `localizationsDelegates` +
   `supportedLocales`. Even with English only, this fixes date and time
   formatting to follow the device locale immediately.
2. Adopt `gen_l10n` with an `app_en.arb`. Extraction is mechanical and can be
   done incrementally, screen by screen.
3. Prefer `EdgeInsetsDirectional` over `fromLTRB` in the new shared widgets so RTL
   works when it arrives.
4. Add `CONTRIBUTING.md` guidance on adding a translation — this converts a cost
   into a contribution channel.

**Blocker:** No — but it gets much more expensive after launch.

---

## U13

### No open-source licences screen

**Severity:** Medium
**Location:** [`mobile/lib/features/settings/settings_screen.dart`](../mobile/lib/features/settings/settings_screen.dart) — no `showLicensePage`, no About tile

**Problem**

Settings has Account, Devices, Safety, Notifications, Session, Coming soon and
Danger zone. It has no **About** section: no version number, no build/commit, no
link to the source, and no third-party licence list.

`THIRD_PARTY_NOTICES.md` exists in the repository and CI verifies that all 157
Dart packages carry a licence file — thorough work that never reaches the user.

**Why it matters in production**

Three separate reasons, all concrete:

1. **AGPL-3.0-or-later.** The licence turns on conveying the work and offering
   corresponding source. A shipped binary with no in-app notice and no source
   pointer is at best poor practice for a project whose licence choice is a
   deliberate statement.
2. **Store review.** Both App Store and Play expect attribution for bundled
   open-source components; Flutter provides `showLicensePage` precisely for this,
   and it costs one tile.
3. **Support.** Without a visible version and commit, no bug report can be tied
   to a build. For a self-hosted product where every operator runs a different
   version, this matters more than usual.

**Fix**

1. Add an **About** section with: app version and build number (from
   `package_info_plus` or an injected constant), the server's instance name and
   version, a link to the repository, and a "Licences" tile calling
   `showLicensePage`.
2. Register the Rust crypto core's licence with `LicenseRegistry.addLicense` so
   it appears alongside the Dart packages — it is not a pub package and will not
   be picked up automatically.
3. Surface the AGPL source offer explicitly, since that is the licence's point.

**Blocker:** No — but it should land before any store submission.

---

## U14

### `veritra://` device-link URI has no handler

**Severity:** Medium
**Location:** generated at [`server/internal/httpapi/api.go:363`](../server/internal/httpapi/api.go#L363); no `intent-filter` in [`AndroidManifest.xml`](../mobile/android/app/src/main/AndroidManifest.xml); no `CFBundleURLTypes` in [`Info.plist`](../mobile/ios/Runner/Info.plist)

**Problem**

The server mints and returns a deep link:

```go
payload["link_uri"] = "veritra://device-link?code=" + url.QueryEscape(link.Code)
```

`DeviceLink.linkUri` is carried all the way through the Dart model. But the
Android manifest declares only the `MAIN`/`LAUNCHER` intent filter, `Info.plist`
declares no URL scheme, and `pubspec.yaml` has no deep-linking package
(`app_links`, `uni_links`) — so nothing on either platform can open a
`veritra://` URL.

**Why it matters in production**

Device linking is a required flow (card I24 step 3 tests it on hardware), and it
is the recovery path for the sign-in precondition in [U3](#u3). The URI is dead
weight today: the QR path works, but the "tap the link" path a user would
reasonably expect does not, and if the link is ever surfaced in a UI as tappable
it will fail silently.

**Fix**

Pick one and make it true:

- **Implement it.** Register the scheme on both platforms, add a deep-link
  package, and route `veritra://device-link?code=...` into
  `AppState.claimDeviceLink`. Also register `https://<host>/device-link?...` as an
  App Link / Universal Link so the URL works when opened from a browser on a
  device that does not have the app.
- **Or remove it.** Drop `link_uri` from the server payload and the Dart model so
  no future UI is tempted to render a link that cannot open.

Either is fine; the current half-state is not.

**Blocker:** No.

---

## U15

### Quota (507) has no user-facing message

**Severity:** Low
**Location:** [`mobile/lib/core/api_client.dart:1055-1106`](../mobile/lib/core/api_client.dart#L1055-L1106) (`ApiException.message`)

**Problem**

The error catalogue in `ApiException.message` is genuinely good — around 25
server codes mapped to plain, actionable English. Some codes are missing, and one
matters:

`storage_quota_exceeded` (HTTP 507, from `enforceBlobQuota`) has no case, so it
falls through to *"The server rejected the request. Check your input and try
again."* — which tells the user to fix their input when the real problem is that
the server is full.

Also unmapped: `login_backoff` (429, falls to the generic "Too many attempts",
which is close enough), `idempotency_conflict`, `plaintext_message_fields_forbidden`,
`invalid_encrypted_envelope`, `blob_integrity_failed`, and `server_draining`.

**Why it matters in production**

A wrong diagnosis is worse than a vague one: it sends the user to fix something
that is not broken, and the real fix (delete attachments, or ask the operator for
space) is one they could have performed.

**Fix**

Add the missing cases. Suggested copy:

- `storage_quota_exceeded` → *"This server is out of storage for your account.
  Delete older attachments, or ask your admin for more space."*
- `blob_integrity_failed` → *"That file failed its integrity check and was not
  delivered."*
- `server_draining` → *"The server is restarting. This will retry
  automatically."*
- `idempotency_conflict` → *"That message was already sent."*

Then add a test asserting every `writeError` code string in `server/internal/httpapi/`
has a corresponding case. The API-contract test harness
(`scripts/test-api-contracts.sh`) is the natural place, and it turns this into a
permanent invariant rather than a list that drifts.

**Blocker:** No. Fix alongside [`logical-issues.md` L10](logical-issues.md#l10).

---

## U16

### Nav pill labels truncate at small widths and large text

**Severity:** Low
**Location:** [`mobile/lib/ui/app_shell.dart:154-166`](../mobile/lib/ui/app_shell.dart#L154-L166) and `:206-229`

**Problem**

`_FloatingNav` lays three `Expanded` items in a `Row`, each an icon plus a
`Flexible(Text(maxLines: 1, overflow: ellipsis))`. On a 320 dp-wide device
(iPhone SE, small Android) after subtracting 24 dp gutters and 4 dp padding, each
destination gets roughly 90 dp for a 20 dp icon, an 8 dp gap and its label. At
default scale "Communities" already crowds; at 150–200% text scale it becomes
"Com…".

The Material `NavigationBar` this replaced handled the label/icon-only trade-off
automatically.

**Why it matters in production**

The primary navigation is the one place truncation is least acceptable, and large
text scale is an accessibility setting — the users most likely to enable it are
the ones who most need the label.

**Fix**

1. Drop labels below a width threshold or above a text-scale threshold, keeping
   icons plus `Semantics(label:)`, so meaning survives for screen readers.
2. Or drop the label for **unselected** destinations only, keeping it for the
   selected one — a common pattern that fits the pill design.
3. Shorten "Communities" to "Groups" or "Spaces" if the product allows.
4. Add a widget test at 320 dp × 2.0 text scale asserting no ellipsis.

**Blocker:** No.

---

## U17

### No in-app light/dark setting

**Severity:** Low
**Location:** [`mobile/lib/main.dart:53`](../mobile/lib/main.dart#L53) — `themeMode: ThemeMode.system`

**Problem**

Both themes are fully built and correct, but the user cannot choose. `themeMode`
is hardcoded to `system`.

**Why it matters in production**

The Bone direction is explicitly built around two very different grounds — a plum
dark and a warm paper light — so which one a user gets is a meaningful choice,
not a detail. Users who keep their OS in light mode but prefer dark messaging apps
(common, especially at night) have no way to say so. It is also the single most
requested setting in almost every app that ships without it.

**Fix**

Add a three-way Appearance control (System / Light / Dark) in Settings, persisted
in the encrypted local store alongside other preferences, driving `themeMode`.
Small change, high perceived value, and it exercises both palettes in a way that
will surface any remaining contrast issues from [U1](#u1).

**Blocker:** No.

---

## U18

### "Coming soon" section ships in Settings

**Severity:** Low
**Location:** [`mobile/lib/features/settings/settings_screen.dart:203-218`](../mobile/lib/features/settings/settings_screen.dart#L203-L218)

**Problem**

Settings contains a `SectionHeader('Coming soon')` with two disabled tiles —
Recovery ("Encrypted backup & recovery key") and Calls ("1:1 audio/video").

The honesty is consistent with the project's stance and is better than hiding
them. But a "Coming soon" section is a beta artefact: it advertises absence in the
place users go to *change* things, and both tiles are disabled, so per
[U8](#u8) they are also unreachable by screen reader.

**Why it matters in production**

It is the clearest "this is not finished" signal in the app, sitting in the one
screen users visit deliberately. It sets expectations you then have to meet.

**Fix**

1. For v1, remove the section. The board is the right place to track unshipped
   features; Settings is not.
2. If they stay, make the tiles enabled and explanatory per [U8](#u8) — tapping
   Recovery could describe what encrypted backup will do and why it is not on yet,
   which is genuinely reassuring rather than merely absent.
3. Note that **Recovery is not actually unbuilt** — card I18 implemented
   capability-based encrypted backup with rollback protection, and
   `crypto/backup_service.dart` exists. What is missing is only the client UI. See
   [nice-to-haves.md](nice-to-haves.md); this is a high-value gap, not a distant
   one.

**Blocker:** No.

---

## U19

### Composer has no keyboard send and no length feedback

**Severity:** Low
**Location:** [`mobile/lib/features/chat/chat_screen.dart:739-768`](../mobile/lib/features/chat/chat_screen.dart#L739-L768)

**Problem**

```dart
TextField(
  minLines: 1, maxLines: 4,
  textInputAction: TextInputAction.newline,
  ...
)
```

`TextInputAction.newline` means the on-screen keyboard shows a return key, not a
send key, so the only way to send is the button. There is also no
`maxLength`/counter and no hardware-keyboard shortcut — relevant now for tablets
and imminently for the Phase 2 desktop targets, which reuse this exact widget.

The server caps a request body at 1 MiB (`api.go:180`), so a very long paste fails
at send time with a generic error rather than being prevented.

**Why it matters in production**

Multi-line composition is worth supporting, so `newline` is a defensible default
— but shipping with no send affordance beyond a tap, and no keyboard shortcut at
all, is a gap that will be felt immediately on desktop.

**Fix**

1. Add a hardware-keyboard `Shortcuts`/`Actions` binding: Enter sends,
   Shift+Enter inserts a newline. On touch keep `newline` as the soft-keyboard
   action.
2. Add a soft `maxLength` well under the 1 MiB body limit with a counter that
   appears only near the cap.
3. Consider a per-user "Enter sends" preference later; the shortcut alone covers
   most of the value.

**Blocker:** No.

---

## U20

### 10px `micro` type carries headers, labels and chips

**Severity:** Low
**Location:** [`mobile/lib/ui/tokens.dart:145-150`](../mobile/lib/ui/tokens.dart#L145-L150)

**Problem**

```dart
static const TextStyle micro = TextStyle(
  fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, height: 1.2,
);
```

Used for group headers, field labels and status chips — via `SectionHeader`,
`StatusPill` and `_Field` — and the text is uppercased, which raises the effective
cap height but also removes the word-shape cues that aid legibility at small
sizes.

10 px is below the ~11 px practical floor for sustained legibility and below both
Material's 11 px `labelSmall` and Apple's 11 pt caption floor.

Flutter's `textScaler` does scale it, and `_RedactedBars` explicitly scales with
text scale (`chat_screen.dart:671`) — the codebase clearly cares about this. But
the default is small enough that a user with mild presbyopia will need to raise
system text size to read a field label.

**Why it matters in production**

Field labels are how a form communicates. If the label is the least legible text
on the screen and — per [U1](#u1) — the field boundary is invisible, the two
compound on exactly the screens that need to work first.

**Fix**

1. Raise `micro` to 11 px, or 11.5 to match `caption`. The tracking and weight
   already give it a distinct voice; it does not need to be that small.
2. Verify the change against `docs/design.md` §1's type ramp and update the table.
3. Add a widget test at 200% text scale for `SectionHeader` and `StatusPill`
   asserting no clipping — the tighter chip paddings are the likely failure point.

**Blocker:** No.

---

## U21

### Sign out is the only destructive action without confirmation

**Severity:** Low
**Location:** [`mobile/lib/features/settings/settings_screen.dart:192`](../mobile/lib/features/settings/settings_screen.dart#L192)

**Problem**

```dart
ListTile(title: const Text('Sign out'), onTap: state.busy ? null : state.logout),
```

Direct call, no confirmation. Its three neighbours — revoke device, sign out other
devices, delete account — all route through `_confirm` **and** `_reauthenticate`.

Sign-out is the mildest of the four: `logout()` uses
`preserveDeviceIdentity: true` (`app_state.dart:1181`), so the device secret
survives and the user can sign back in. It is not destructive in the way the
others are.

But it does clear cached state via `localStore.clearCachedState()`, and it sits
directly above "Sign out other devices" in the same `TileGroup`, so a mis-tap
between two adjacent, similarly-named rows is easy.

**Why it matters in production**

Low consequence, but the inconsistency is the point: users learn that destructive
rows in this screen ask first, and this one silently does not.

**Fix**

Add a `_confirm` (without `_reauthenticate` — that would be disproportionate).
Or separate the two rows visually so the mis-tap is less likely. Consider whether
sign-out should preserve the local message cache; today it does not, so signing
out and back in costs a full re-sync.

**Blocker:** No.

---

## U22

### Terminally-failed messages cannot be recovered or copied

**Severity:** Low
**Location:** [`mobile/lib/features/chat/chat_screen.dart:214-234`](../mobile/lib/features/chat/chat_screen.dart#L214-L234) (`_send`) and `:407-467` (`_PendingMessageBubble`)

**Problem**

`_send` clears the composer immediately — deliberate, and the reasoning is written
into the code: the envelope is durable and the pending bubble carries its state.

But when the failure is **terminal** (400/403/404/409/413/422 →
`OutboxDeliveryState.terminal`), the bubble shows "Send failed" with a Retry
button that is guaranteed to fail again. The typed text lives only inside an
encrypted envelope in the outbox; it cannot be read back, edited, or copied.

Realistic trigger: you are removed from a group while composing. The send returns
403, the message is terminal, and the text you wrote is gone.

**Why it matters in production**

Small in frequency, large in the moment — losing a long message you just wrote is
memorable in a way that shapes trust in the whole product.

**Fix**

1. Distinguish terminal from retrying in the bubble. Terminal should not offer
   Retry; it should offer **Copy text** and **Delete**, and state the reason
   (`ApiException.message` is already the right copy).
2. Keep the plaintext recoverable for terminal entries — store it in the encrypted
   local database alongside the envelope so it can be restored to the composer.
   The local DB is already encrypted at rest, so this adds no plaintext exposure
   the device does not already have.
3. Only clear the composer once the envelope reaches `sending`, not on tap.

**Blocker:** No.

---

## U23

### No chat-list row actions (mute, mark read, leave)

**Severity:** Low
**Location:** [`mobile/lib/features/chat/chat_list_screen.dart:128-286`](../mobile/lib/features/chat/chat_list_screen.dart#L128-L286)

**Problem**

`_ConversationTile` has a single `onTap`. No long-press menu, no swipe actions, no
trailing overflow button. Every operation on a conversation — mute, view details,
leave, block — requires opening it and then navigating to
`ConversationDetailsScreen`.

The state layer already supports all of it: `setConversationMuted`,
`markNewestMessageRead`, `leaveConversation` and `blockAccount` are all public on
`AppState`.

**Why it matters in production**

Muting a noisy group is something users do while triaging a list, not after
opening the thread. Three taps and a screen transition for a one-bit toggle is
enough friction that most users will not do it, and will instead mute
notifications for the whole app.

**Fix**

1. Add a long-press context menu with Mute/Unmute, Mark as read, Conversation
   details, and Leave (with confirmation).
2. Optionally add a swipe action for Mute, the highest-frequency one.
3. Ensure the menu is reachable by screen reader — a long-press-only affordance is
   invisible to TalkBack, so also expose the actions via
   `Semantics(customSemanticsActions:)`.

**Blocker:** No.

---

# Recommended UI priorities before production

Ranked by user impact per unit of effort. Items 1–4 are the launch gate.

### 1. Fix the control-contrast token — [U1](#u1)

*Highest value, smallest change in this document.* One token, changed in two
palettes, fixes every text field, card, chip, tile group and pill in the app, and
makes a claim in `docs/design.md` true. Everything else on this list is on a
screen; this is on all of them. **Do it before committing the I28 tree**, so the
visual rebuild lands once.

### 2. Rebuild the first-run flow — [U2](#u2), [U3](#u3), [U4](#u4)

The three findings are one problem: the connect screen defaults to a URL that
cannot work, in a mode that cannot succeed, and says nothing when either fails.
Fix together:

- clear the URL default and reject cleartext with an actionable message;
- pick the default auth mode from stored device state;
- render the probe's three outcomes distinctly.

Until this is done, a new user's first experience is an unexplained failure.

### 3. Make the conversation behave like a conversation — [U7](#u7)

No scroll-to-latest and no new-message indicator is the most visible functional
gap in the core screen. Scrolling up silently stops you receiving.

### 4. Make gated features explain themselves — [U8](#u8), [U18](#u18)

The project's honesty about unfinished crypto is a strength, but disabled controls
carry that honesty nowhere on touch and nowhere at all for screen readers. Adopt
"gated features are enabled and explanatory" as a rule in `docs/design.md` and
apply it to the paperclip and the Coming-soon tiles.

### 5. Timestamps and layout correctness — [U5](#u5), [U6](#u6)

Relative timestamps make the chat list legible at a glance; the breakpoint fix
stops the tablet layout appearing whenever a phone is rotated. Both are small and
both are noticed immediately.

### 6. Form quality — [U11](#u11), [U15](#u15)

Inline validation and a scrollable sheet in the new-conversation flow; the
missing quota message in the error catalogue.

### 7. Render cost — [U9](#u9), [U10](#u10)

Hoist the themes out of the root builder (one line), then `IndexedStack` for tab
state. Both are quick; the deeper `AppState` split can wait for a considered
refactor.

### 8. Completeness and polish — [U12](#u12), [U13](#u13), [U14](#u14), [U16](#u16), [U17](#u17), [U19](#u19)–[U23](#u23)

Localisation delegates and an About/Licences screen should land before any store
submission. The rest is a good first post-launch cycle.

### Cross-cutting: add tests for what you fix

There are no golden tests. Every fix above is a rendering or layout change that
`flutter test` will not catch on the next refactor. When fixing these, add:

- a contrast unit test (item 1),
- widget tests at 320 dp and at 200% text scale (items 5, 6, and [U16](#u16),
  [U20](#u20)),
- a layout test at 850 × 390 and 1024 × 768 ([U6](#u6)).

See [`production-readiness.md` R6](production-readiness.md#r6).
