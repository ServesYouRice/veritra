# B5 one-to-one calls (demo builds)

- `CallController` (`mobile/lib/calls/call_controller.dart`) drives start,
  accept, decline, hang up, mute, camera and speaker on the existing
  `NativeCallService`. Relay-only ICE and TURN validation (D56) are enforced
  by the service; the controller cannot disable them.
- `CallHost` (`mobile/lib/features/calls/call_host.dart`) is mounted by
  `VeritraApp` only when `config.demo` is true (demo entry point), so release
  builds create no call service and show no call buttons.
- Call buttons sit in the DM chat app bar; the call screen, incoming-call
  card and missed / declined / no-answer / failed notices draw above every route.
- Strings: English, Serbian Cyrillic, Latin regenerated with
  `scripts/l10n-sr-latn.py`, `flutter gen-l10n` run.
- Checks run: `flutter analyze` clean, `dart format --set-exit-if-changed`,
  `flutter test` for `b5_call_controller_test`, `b5_call_screen_test`,
  `call_service_test`, `l10n_locales_test`.
- Not done: native incoming-call UI (T42B, deferred); no real-device media
  test (needs two devices and a TURN service).
