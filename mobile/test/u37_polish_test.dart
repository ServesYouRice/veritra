// U37: small polish. Durations are written in words; account notices show
// inside an open chat too. (Role-change confirmation lives in roles_screen.dart
// and needs an MLS crypto fake to drive; it has no widget test. The ticked account, the
// one-fact passkey rows and the restore rows are covered in
// b7_accounts_screens_test, b7_passkey_screens_test and
// k1_backup_screens_test.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/communities/moderation_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';

import 'goldens/golden_harness.dart';

void main() {
  final l10n = englishL10n;

  test('durations are written in words', () {
    expect(durationWords(l10n, 30), '30 seconds');
    expect(durationWords(l10n, 600), '10 minutes');
    expect(durationWords(l10n, 3600), '1 hour');
    expect(durationWords(l10n, 21600), '6 hours');
    expect(durationWords(l10n, 86400), '1 day');
    expect(durationWords(l10n, 604800), '7 days');
  });

  testWidgets('an account notice also shows inside an open chat', (
    tester,
  ) async {
    setWindowSize(tester, phoneSize);
    final state = await connectedState();
    state.passkeyNotice = PasskeyNotice.added;
    await tester.pumpWidget(veritraTestApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@alice'));
    await tester.pumpAndSettle();

    // The pushed chat covers the shell, so its own banner is the one seen.
    expect(find.text(l10n.passkeyNoticeAdded), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Scaffold).last,
        matching: find.text(l10n.passkeyNoticeAdded),
      ),
      findsOneWidget,
    );
  });
}
