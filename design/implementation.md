# Landing it in Flutter

For after a direction is picked. Nothing here has been built yet.

## Order of work

Each step is independently shippable and visible on its own.

1. **Tokens + theme** — rewrite `mobile/lib/ui/theme.dart`. Every screen changes
   at once, for free, because they all read from `Theme.of(context)` already.
2. **Typography** — bundle the font, fill in the `TextTheme`. Biggest visible
   jump per line changed.
3. **Chat list** — `chat_list_screen.dart`. The screen users see most.
4. **Conversation** — bubbles and composer, `chat_screen.dart`.
5. **Connect** — `connect_screen.dart`.
6. **Settings, communities, search, details** — mechanical once 1–4 land.
7. **Shared widgets** — `StatusPill`, `SectionHeader`, `EmptyState` interior.
8. **Motion**, then **app icon**, then `server/websetup/index.html`.

Steps 1 and 2 alone get most of the way there. Do them first and re-judge.

## theme.dart

Replace `ColorScheme.fromSeed` with explicit `ColorScheme(...)` constructors for
light and dark. `fromSeed` derives a whole tonal palette from one colour and
**cannot** be made to land on specific brand hexes — which is exactly why the app
looks the way it does today.

Structure it as:

```
ui/tokens.dart   colour, spacing, radius, duration constants
ui/theme.dart    ColorScheme + ThemeData built from tokens
```

Keep the existing component overrides in `theme.dart` (`inputDecorationTheme`,
`cardTheme`, `filledButtonTheme`, …) — they are already doing the right thing,
they just need the new radii and colours.

Add the two gradients from `directions.md` as constants. `--grad-fill` is not
optional: the bright brand gradient fails contrast under text.

## Dependencies — read before adding anything

`AGENTS.md` requires license review **and** a `THIRD_PARTY_NOTICES.md` update for
any new dependency. Two consequences:

- **Do not add `flutter_svg`** just to draw the chain-link mark. It is two
  rounded rects and an arc — a `CustomPainter` renders it with no dependency at
  all, and scales better than an SVG asset.
- **A bundled font still needs a notices entry.** Inter and Geist are both
  OFL-1.1. Add `mobile/assets/fonts/`, declare it under `fonts:` in
  `mobile/pubspec.yaml` (which currently has no `assets:` or `fonts:` section at
  all), and add the attribution.

If you would rather avoid the font question entirely, the platform faces (SF on
iOS, Roboto on Android) with a proper size and weight ramp already get you ~80%
of the improvement. The ramp is what matters, not the typeface.

## Ciphertext bar widths — one caveat

`ReceivedMessageEnvelope.ciphertext` is a `List<int>`
(`mobile/lib/core/models.dart:281`), so `.length` is available client-side with
no new field and no decryption.

But deriving bar width directly from that length makes **message length readable
over someone's shoulder**. That is a small regression against a threat this app
takes seriously, and today's identical-width bubbles happen not to have it.

Bucket the widths — say six steps from short to long, capped at three lines —
rather than mapping length linearly. You keep the visual rhythm and leak only a
coarse bucket. Worth a line in the code explaining why it is bucketed, or someone
will "fix" it back to linear later.

## Tests

Only one widget test exists in the repo: `mobile/test/profile_screen_test.dart`.
Keep these six assertions passing:

| Must survive | Where |
| --- | --- |
| `@alice` rendered | header and username row |
| `Alice phone` as its own `Text` | current-device row |
| `owner`, lowercase, own `Text` | instance-role row |
| Tooltip `Copy Account ID` | `_IdentityRow` copy button |
| Tooltip `Copy Current device` | same |
| `Encryption identity pending` | static placeholder card |

So: don't merge those values into composite strings, don't title-case `owner`,
and don't replace the copy `IconButton`s with a menu. Everything else in the UI
is unconstrained — no test references a `Key`, a widget type, or a semantics
label anywhere.

The other six test files are pure unit tests over `AppState`, models, and error
mapping. They never call `pumpWidget`. `shortId`'s exact `acct_012…cdef` output
(`ui/format.dart`) is the one format-layer contract.

Worth adding as you go: golden tests for the chat row, the bubble, and the
composer in both brightnesses. There are none today, and a redesign is the
cheapest moment to add them.

## Accessibility

Preserve the existing semantics work — it is better than the visuals and easy to
destroy in a refactor:

- `MergeSemantics` on chat rows (`chat_list_screen.dart:102`) so a screen reader
  announces each row once.
- `ExcludeSemantics` on decorative avatars and icons.
- `Semantics(liveRegion: true)` on pending-message bubbles
  (`chat_screen.dart:280`).
- `Semantics(header: true)` on section headers.

Additionally: keep 48dp minimum touch targets (Terminal's 44px rows are the
*row* height — the tap target still needs to reach 48), and test at 200% text
scale, where the dense direction will hurt first.

## App icon

`mobile/android/app/src/main/res/mipmap-*/ic_launcher.png` and
`mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/` are still the stock
Flutter icon. `docs/branding/concept-06/veritra-app-icon.svg` already exists —
export it to the required sizes. Generating these by hand is fine; adding an
icon-generator dependency for a one-time export is not worth the notices churn.

## Board

Tracked as card **I28** in `implementation/KANBAN.md`. It is decision blocked:
pick one direction from `preview.html` before any of the work above starts.
