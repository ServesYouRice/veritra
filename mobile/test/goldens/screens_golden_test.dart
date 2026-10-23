// T43C representative light/dark goldens.
//
// Regenerate on Linux with:
//   TZ=UTC flutter test --update-goldens test/goldens
// See goldenSkipReason for why other hosts skip the comparison.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';

import 'golden_harness.dart';

/// One representative screen, reached the way a user reaches it.
class _Screen {
  const _Screen(this.name, {required this.connected, this.open});

  final String name;
  final bool connected;

  /// Navigates from the shell's first page to this screen.
  final Future<void> Function(WidgetTester tester)? open;
}

final _screens = <_Screen>[
  const _Screen('connect', connected: false),
  const _Screen('chats', connected: true),
  _Screen('chat', connected: true, open: (tester) async {
    await tester.tap(find.text('@alice'));
  }),
  _Screen('settings', connected: true, open: (tester) async {
    await tester.tap(find.byIcon(Icons.settings_outlined));
  }),
];

const _sizes = <String, Size>{'phone': phoneSize, 'wide': wideSize};

const _themes = <String, ThemeMode>{
  'light': ThemeMode.light,
  'dark': ThemeMode.dark,
};

void main() {
  for (final screen in _screens) {
    for (final size in _sizes.entries) {
      for (final theme in _themes.entries) {
        final file = '${screen.name}_${size.key}_${theme.key}.png';
        testWidgets(file, (tester) async {
          setWindowSize(tester, size.value);
          final AppState state =
              screen.connected ? await connectedState() : disconnectedState();
          await tester.pumpWidget(veritraTestApp(
            state: state,
            themeMode: theme.value,
            disableAnimations: true,
          ));
          await tester.pumpAndSettle();
          if (screen.open != null) {
            await screen.open!(tester);
            await tester.pumpAndSettle();
          }

          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(file),
          );
        }, skip: goldenSkipReason != null);
      }
    }
  }
}
