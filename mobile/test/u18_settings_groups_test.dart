// U18: Settings in eight groups. At 360 x 800 the tab fits two viewports,
// every row that opens a page has an arrow, the account ID lives under
// Profile > Advanced, the "Coming soon" group is gone and Sign out is last.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/settings/profile_screen.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';

import 'goldens/golden_harness.dart';

/// The test font (Ahem) is a full em wide per character, about twice as wide
/// as the phone's UI font, so text wraps far more than on a device. 0.55
/// brings the widths close to Roboto's; row heights are set by ListTile's
/// minimums, which this scale does not change.
const double _realisticWidthScale = 0.55;

Future<void> _openSettings(WidgetTester tester,
    {Size size = phoneSize}) async {
  setWindowSize(tester, size);
  await tester.pumpWidget(veritraTestApp(
    state: await connectedState(),
    textScale: _realisticWidthScale,
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pumpAndSettle();
}

/// A lazy list only knows its true length once it has built every row.
Future<void> _scrollToEnd(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  final l10n = englishL10n;

  testWidgets('the tab fits two viewports at 360 x 800', (tester) async {
    await _openSettings(tester);
    await _scrollToEnd(tester);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final position = scrollable.position;
    expect(
      position.maxScrollExtent,
      lessThanOrEqualTo(position.viewportDimension),
      reason: 'content is ${position.maxScrollExtent + position.viewportDimension} '
          'dp tall; two viewports are ${2 * position.viewportDimension} dp',
    );
  });

  testWidgets('groups, arrows, no Coming soon, Sign out last and red',
      (tester) async {
    // Tall, so the lazy list builds every row.
    await _openSettings(tester, size: const Size(360, 4000));

    for (final header in <String>[
      l10n.settingsSectionAccount,
      l10n.settingsSectionDevices,
      l10n.settingsSectionPrivacySafety,
      l10n.settingsSectionNotifications,
    ]) {
      // SectionHeader upper-cases its title.
      expect(find.text(header.toUpperCase(), skipOffstage: false),
          findsOneWidget,
          reason: header);
    }
    expect(
        find.text(l10n.settingsSectionComingSoon.toUpperCase(),
            skipOffstage: false),
        findsNothing);
    // Account ID is no longer a Settings row.
    expect(find.text(l10n.settingsAccountId, skipOffstage: false), findsNothing);

    // Rows that open a page carry an arrow.
    final blocked = find.ancestor(
      of: find.text(l10n.settingsBlockedAccounts, skipOffstage: false),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(
        of: blocked,
        matching: find.byIcon(Icons.chevron_right),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    // A row that opens a dialog does not.
    final password = find.ancestor(
      of: find.text(l10n.settingsChangePassword, skipOffstage: false),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(
        of: password,
        matching: find.byIcon(Icons.chevron_right),
        skipOffstage: false,
      ),
      findsNothing,
    );

    // Sign out is the last row, in the error colour.
    final signOut = find.byKey(const ValueKey<String>('settings-sign-out'));
    final tiles = find.descendant(
      of: find.byType(SettingsScreen),
      matching: find.byType(ListTile),
      skipOffstage: false,
    );
    expect(tester.widget<ListTile>(tiles.last).key,
        const ValueKey<String>('settings-sign-out'));
    final title = tester.widget<Text>(find.descendant(
      of: signOut,
      matching: find.text(l10n.settingsSignOut),
      skipOffstage: false,
    ));
    final scheme = Theme.of(tester.element(find.byType(SettingsScreen)))
        .colorScheme;
    expect(title.style?.color, scheme.error);
  });

  testWidgets('Account ID sits under Profile > Advanced', (tester) async {
    await _openSettings(tester, size: const Size(360, 4000));
    await tester.tap(find.text('@owner'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.text(l10n.profileSectionAdvanced.toUpperCase()),
        findsOneWidget);
    expect(find.text(l10n.settingsAccountId.toUpperCase()), findsOneWidget);
  });
}
