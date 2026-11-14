import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';

import 'k0_recovery_fakes.dart';

/// UI audit U23 and U24: the recovery screens in plain steps, and a
/// recovery key that is easier to copy and check.
void main() {
  late K0Server server;
  late MemoryLocalStore store;
  late K0Crypto crypto;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
    crypto = K0Crypto();
  });

  void phone(WidgetTester tester, {double height = 2000}) {
    tester.view.physicalSize = Size(360, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  AppState signedIn() => k0App(server, store, crypto)
    ..session = k0SignedIn
    ..api = K0Api(server);

  Widget app(Widget home, {double scale = 1}) => MaterialApp(
        theme: veritraLightTheme(),
        home: home,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      );

  /// The groups of [k0Display], as the screen numbers them.
  final groups = <String>[
    for (var i = 0; i < k0Display.length; i += 4) k0Display.substring(i, i + 4)
  ];

  Future<void> openShowStep(WidgetTester tester, AppState state,
      {double scale = 1}) async {
    await tester.pumpWidget(app(RecoveryKeyScreen(state: state), scale: scale));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a recovery key'));
    await tester.pumpAndSettle();
  }

  Future<void> openConfirmStep(WidgetTester tester, AppState state) async {
    await openShowStep(tester, state);
    await tester.tap(find.text('I have saved it'));
    await tester.pumpAndSettle();
  }

  Finder confirmField() =>
      find.byKey(const ValueKey<String>('recovery-key-confirm-field'));

  Icon markIcon(WidgetTester tester, int group) =>
      tester.widget<Icon>(find.descendant(
          of: find.byKey(ValueKey<String>('recovery-key-mark-$group')),
          matching: find.byType(Icon)));

  group('U24: the key in 13 numbered groups', () {
    for (final scale in <double>[1, 2]) {
      testWidgets('13 numbered groups fit at 360 dp, text scale $scale',
          (tester) async {
        phone(tester);
        final state = signedIn();
        await openShowStep(tester, state, scale: scale);
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 13; i++) {
          expect(
              tester
                  .widget<Text>(find
                      .byKey(ValueKey<String>('recovery-key-group-${i + 1}')))
                  .data,
              groups[i]);
          expect(
              find.descendant(
                  of: find
                      .byKey(const ValueKey<String>('recovery-key-display')),
                  matching: find.text('${i + 1}')),
              findsOneWidget);
        }
        expect(find.byKey(const ValueKey<String>('recovery-key-group-14')),
            findsNothing);
        // Each group sits inside the screen.
        final last = tester.getRect(
            find.byKey(const ValueKey<String>('recovery-key-group-4')));
        expect(last.right, lessThanOrEqualTo(360));
        state.dispose();
      });
    }

    testWidgets('it is still read group by group, never as one word',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      final semantics = tester.getSemantics(
          find.byKey(const ValueKey<String>('recovery-key-display')));
      expect(semantics.label, startsWith('A B C D - E F G H'));
      state.dispose();
    });
  });

  group('U24: a copy for a password manager, no print', () {
    late List<String> copies;

    setUp(() {
      copies = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copies.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('copies the grouped key, and clears it on continuing',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      expect(find.byIcon(Icons.print), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.textContaining('Print'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-copy')));
      await tester.pumpAndSettle();
      expect(copies, <String>[groups.join('-')]);
      expect(find.textContaining('Paste it into your password manager'),
          findsOneWidget);

      // The check that follows must come from the saved copy.
      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();
      expect(copies, <String>[groups.join('-'), '']);
      state.dispose();
    });

    testWidgets('nothing is cleared when nothing was copied', (tester) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(copies, isEmpty);
      state.dispose();
    });
  });

  group('U24: typing it back ticks each group', () {
    testWidgets('ticks the right groups and names the wrong one by number',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      expect(find.byKey(const ValueKey<String>('recovery-key-check-message')),
          findsNothing);

      await tester.enterText(
          confirmField(), '${groups[0]} ${groups[1].toLowerCase()} ZZZZ');
      await tester.pump();
      expect(markIcon(tester, 1).icon, Icons.check_circle);
      expect(markIcon(tester, 2).icon, Icons.check_circle);
      expect(markIcon(tester, 3).icon, Icons.cancel);
      expect(markIcon(tester, 4).icon, Icons.radio_button_unchecked);
      expect(
          tester
              .widget<Text>(find
                  .byKey(const ValueKey<String>('recovery-key-check-message')))
              .data,
          'Group 3 does not match. Check it on your copy.');
      // The key itself is not on this step.
      expect(find.textContaining(groups[2]), findsNothing);
      state.dispose();
    });

    testWidgets('reads O as 0 and I or L as 1, like the decoder',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      // Group 6 is "YZ01".
      final typed = groups.take(6).join('-').replaceFirst('YZ01', 'yzOL');
      await tester.enterText(confirmField(), typed);
      await tester.pump();
      for (var group = 1; group <= 6; group++) {
        expect(markIcon(tester, group).icon, Icons.check_circle,
            reason: 'group $group');
      }
      expect(find.text('6 of 13 groups match.'), findsOneWidget);
      state.dispose();
    });

    testWidgets('a group still being typed waits until it goes wrong',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      await tester.enterText(confirmField(), '${groups[0]}-${groups[1][0]}');
      await tester.pump();
      expect(markIcon(tester, 2).icon, Icons.radio_button_unchecked);
      await tester.enterText(confirmField(), '${groups[0]}-U');
      await tester.pump();
      expect(markIcon(tester, 2).icon, Icons.cancel);
      state.dispose();
    });

    testWidgets('all 13 ticked, and the native check still decides',
        (tester) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      await tester.enterText(confirmField(), '${groups.join(' ')} 7');
      await tester.pump();
      expect(
          find.text('This is longer than the key. Check for extra '
              'characters.'),
          findsOneWidget);
      // Saving is never turned off by the ticks; the native check refuses.
      await tester.tap(find.text('Save recovery key'));
      await tester.pumpAndSettle();
      expect(
          find.text('That is not the key shown. Check your paper and try '
              'again.'),
          findsOneWidget);
      expect(server.puts, isEmpty);

      await tester.enterText(confirmField(), groups.join(' '));
      await tester.pump();
      expect(find.text('13 of 13 groups match.'), findsOneWidget);
      for (var group = 1; group <= 13; group++) {
        expect(markIcon(tester, group).icon, Icons.check_circle);
      }
      state.dispose();
    });

    test('marks are guidance computed from the typed text', () {
      expect(recoveryGroupMarks(k0Display, ''),
          everyElement(RecoveryGroupMark.pending));
      expect(recoveryGroupMarks(k0Display, k0Display),
          everyElement(RecoveryGroupMark.correct));
      final marks = recoveryGroupMarks(k0Display, 'ABCE');
      expect(marks.first, RecoveryGroupMark.wrong);
      expect(marks.skip(1), everyElement(RecoveryGroupMark.pending));
      expect(canonicalRecoveryKeyText('ab-cd o i l '), 'ABCD011');
    });
  });

  testWidgets('U23: Back from the key keeps the same key', (tester) async {
    phone(tester);
    final state = signedIn();
    await openShowStep(tester, state);
    await tester.tap(find.byKey(const ValueKey<String>('recovery-key-back')));
    await tester.pumpAndSettle();
    expect(find.text('Create a recovery key'), findsNothing);
    final handedOut = crypto.handedOut.length;
    await tester
        .tap(find.byKey(const ValueKey<String>('recovery-key-show-draft')));
    await tester.pumpAndSettle();
    expect(crypto.handedOut.length, handedOut, reason: 'no new key was made');
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey<String>('recovery-key-group-1')))
            .data,
        groups[0]);
    state.dispose();
  });
}
