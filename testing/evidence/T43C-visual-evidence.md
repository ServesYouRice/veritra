# T43C — Responsive, semantic and visual evidence

Tested commit: `8d8dc39` (base `a45f267`). Date: 2026-10-23.
Host: Linux x86_64, `TZ=UTC`.
Toolchain: Flutter 3.44.0 (stable, framework `559ffa3f75`), Dart 3.12.0,
go1.26.10 linux/amd64.

This file covers automated evidence only. It does **not** claim TalkBack,
VoiceOver, on-device large text or any manual rendering check. Those are
listed under G24 below as not run.

## Commands

```sh
cd mobile
flutter pub get
TZ=UTC flutter test --update-goldens test/goldens   # once, to create PNGs
TZ=UTC flutter test test/goldens                    # compare: 16 passed
TZ=Europe/Berlin flutter test test/goldens          # 16 skipped, as designed
flutter test test/responsive_layout_test.dart       # 35 passed
flutter test                                        # 310 passed, 2 skipped
flutter analyze                                     # no issues
dart format --output=none --set-exit-if-changed lib test   # 0 changed
cd ../server && go test ./websetup                  # ok
```

`flutter test` ran with `VERITRA_CRYPTO_LIBRARY` pointing at a local release
build of `crypto/rust`.

## Goldens

`mobile/test/goldens/screens_golden_test.dart`, 16 PNGs, 320 KB in total:
connect, chat list, an open chat and settings, each at 360x800 and
1280x800, light and dark. The chat holds sent and received text, a
reaction and one "sender could not be verified" row. At 1280 px the chat is
the detail pane of the workspace layout.

The harness (`golden_harness.dart`) builds the shell as `main.dart` does:
real themes, ARB localizations and `AppearanceScope`, rebuilt on every state
change. It fixes the locale to `en` and the clock to 24 hours, dates all
fixtures in 2025, turns animations off and uses no network or real crypto.
The repository bundles no fonts, so text renders in the Flutter test font
(blocks). The goldens therefore pin layout, colour and theme, not glyphs.

CI safety: the goldens are compared only when `Platform.isLinux` and the
local clock is UTC, because bubbles show a local time of day. That matches
the CI `mobile` job (ubuntu, UTC), which is the only job that runs
`flutter test`. Other hosts skip the comparison and report why.

## Viewport, text scale and motion

`mobile/test/responsive_layout_test.dart` runs on every platform. It opens
the same four screens at 320x640, 320x640 at 200% text, 360x800 at 200%,
landscape 800x360 at 100% and 200%, tablet 820x1180 at 100% and 200%, and
1280x800 at 200%. It scrolls every vertical list to the end, then fails on
any layout error. All 32 cases pass.

It also checks the following:

- At 320 px the compact nav hides its labels but keeps "Chats",
  "Communities" and "Settings" in semantics, and the list stays reachable.
- With `disableAnimations`, an opened chat sits at x = 0 on the first frame.
  With animations on, it is still sliding in.

## Failures reproduced and fixed

| Failure | Where | Fix |
|---|---|---|
| The phone nav pill covered the whole screen. `Container.alignment` made an `Align` that filled the bottom bar slot's loose height, which is the full screen. | `lib/ui/app_shell.dart` `_NavItem` | The `Row` centres the item. |
| The device row overflowed at 320 px and at 200% text, by up to 136 px with the test font. | `lib/features/settings/settings_screen.dart` | The name and pill sit in a `Wrap`. |
| A pill without an icon could not wrap, because its `Row` gave the text unbounded width. | `lib/ui/widgets/status_pill.dart` | A pill without an icon is now a bare `Text`. The icon case is unchanged. |

The test font is wider than Roboto, so the device-row overflow at 320 px and
100% text may not happen on a device. At 200% text it does.

## G24 manual checklist (not run)

| Check | Platform | Status |
|---|---|---|
| TalkBack: traverse connect, chat list, chat and settings; every control is announced with a name and role | Android device | not run |
| VoiceOver: same traversal and rotor headings | iOS device | not run |
| Large text: system font size at maximum or 200%; no clipped or overlapping text on the four screens | Android and iOS devices | not run |
| Reduced motion: "Remove animations" (Android) and "Reduce Motion" (iOS); opening a chat does not slide | Android and iOS devices | not run |
| Keyboard traversal: Tab/Shift+Tab order and visible focus on connect, chat list, chat composer and settings; Enter sends | Windows, Linux and macOS desktop builds | not run |
| Contrast in real rendering, light and dark, with the real font | Devices | not run |
