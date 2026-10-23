// Card T44C: the main screens in Serbian, in both scripts. Serbian words run
// longer than English ones, so these also check that nothing overflows at
// 320 px with 200% text, and that no English message is left on screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/l10n/l10n.dart';

import 'goldens/golden_harness.dart';

typedef _Open = Future<void> Function(WidgetTester tester);

Future<void> _tapIcon(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon).first);
  await tester.pumpAndSettle();
}

/// Drags every vertical list on screen to its end so lazily built rows are
/// laid out too.
Future<void> _scrollThrough(WidgetTester tester) async {
  final lists = find.byWidgetPredicate((widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down);
  final count = lists.evaluate().length;
  for (var i = 0; i < count; i++) {
    for (var step = 0; step < 6; step++) {
      await tester.drag(lists.at(i), const Offset(0, -400),
          warnIfMissed: false);
      await tester.pump();
    }
  }
  await tester.pumpAndSettle();
}

class _Screen {
  const _Screen(this.name, {required this.connected, this.open, this.text});

  final String name;
  final bool connected;
  final _Open? open;

  /// A message the screen shows once it is open.
  final String Function(AppLocalizations l10n)? text;
}

final _screens = <_Screen>[
  _Screen('connect', connected: false, text: (l10n) => l10n.connectTagline),
  _Screen('chat list', connected: true, text: (l10n) => l10n.navChats),
  _Screen('chat',
      connected: true,
      open: (tester) async {
        await tester.tap(find.text('@alice'));
        await tester.pumpAndSettle();
      },
      text: (l10n) => l10n.chatSenderUnverified),
  _Screen('communities',
      connected: true,
      open: (tester) => _tapIcon(tester, Icons.groups_outlined),
      text: (l10n) => l10n.navCommunities),
  _Screen('settings',
      connected: true,
      open: (tester) => _tapIcon(tester, Icons.settings_outlined),
      // Section headers are set in capitals.
      text: (l10n) => l10n.settingsSectionAccount.toUpperCase()),
];

class _Viewport {
  const _Viewport(this.name, this.size, this.textScale);

  final String name;
  final Size size;
  final double textScale;
}

const _viewports = <_Viewport>[
  _Viewport('phone', phoneSize, 1.0),
  _Viewport('320 px at 200% text', narrowPhoneSize, 2.0),
  _Viewport('desktop', wideSize, 1.0),
];

const _serbianLatin =
    Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn');

/// English messages that read differently in [l10n], so finding one on
/// screen means a string did not follow the locale.
Set<String> _englishOnly(AppLocalizations l10n) {
  final english = <String>{
    englishL10n.navChats,
    englishL10n.navCommunities,
    englishL10n.settingsTitle,
    englishL10n.settingsSectionAccount,
    englishL10n.settingsSectionDevices,
    englishL10n.settingsSignOut,
    englishL10n.chatComposerHint,
    englishL10n.chatStatusEncrypted,
    englishL10n.chatSenderUnverified,
    englishL10n.chatListSearch,
    englishL10n.chatListNewChat,
    englishL10n.connectInstanceUrl,
    englishL10n.connectTagline,
    englishL10n.connectOtherWays,
    englishL10n.communityEmptyTitle,
    englishL10n.listTimeYesterday,
    englishL10n.commonCancel,
    'Back',
  };
  return english
    ..remove(l10n.navChats)
    ..remove(l10n.commonCancel);
}

void main() {
  for (final locale in <Locale>[const Locale('sr'), _serbianLatin]) {
    final l10n = lookupAppLocalizations(locale);
    group(locale.toLanguageTag(), () {
      test('the strings really are Serbian in this script', () {
        final settings =
            locale.scriptCode == 'Latn' ? 'Podešavanja' : 'Подешавања';
        expect(l10n.settingsTitle, settings);
        expect(l10n.demoBannerLabel, isNot(englishL10n.demoBannerLabel));
      });

      for (final viewport in _viewports) {
        for (final screen in _screens) {
          testWidgets('${screen.name} at ${viewport.name}', (tester) async {
            setWindowSize(tester, viewport.size);
            final AppState state =
                screen.connected ? await connectedState() : disconnectedState();
            state.communitiesLoaded = true;
            await tester.pumpWidget(veritraTestApp(
              state: state,
              textScale: viewport.textScale,
              locale: locale,
            ));
            await tester.pumpAndSettle();
            await screen.open?.call(tester);

            if (screen.text != null) {
              expect(find.text(screen.text!(l10n)), findsWidgets);
            }
            await _scrollThrough(tester);
            expect(tester.takeException(), isNull);

            final shown = tester
                .widgetList<Text>(find.byType(Text))
                .map((text) => text.data)
                .whereType<String>()
                .toSet();
            expect(shown.intersection(_englishOnly(l10n)), isEmpty);
          });
        }
      }

      testWidgets('AppState text follows the locale', (tester) async {
        setWindowSize(tester, phoneSize);
        final state = disconnectedState();
        await tester.pumpWidget(veritraTestApp(state: state, locale: locale));
        await tester.pumpAndSettle();

        expect(state.l10n.localeName, l10n.localeName);
        expect(
          describeError(TimeoutException('slow'), state.l10n),
          l10n.errorTimeout,
        );
        expect(l10n.errorTimeout, isNot(englishL10n.errorTimeout));
      });
    });
  }

  testWidgets('AppState text switches back to English with the app',
      (tester) async {
    setWindowSize(tester, phoneSize);
    final state = disconnectedState();
    await tester
        .pumpWidget(veritraTestApp(state: state, locale: const Locale('sr')));
    await tester.pumpAndSettle();
    expect(state.l10n.localeName, 'sr');

    await tester.pumpWidget(veritraTestApp(state: state));
    await tester.pumpAndSettle();
    expect(state.l10n.localeName, 'en');
  });
}
