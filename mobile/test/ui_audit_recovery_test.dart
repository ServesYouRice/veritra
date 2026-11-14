import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/auth/account_recovery_screen.dart';
import 'package:private_messenger/features/auth/recovery_follow_up_screen.dart';
import 'package:private_messenger/features/settings/reauth_dialog.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
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
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      );

  /// The groups of [k0Display], as the screen numbers them.
  final groups = <String>[
    for (var i = 0; i < k0Display.length; i += 4) k0Display.substring(i, i + 4),
  ];

  Future<void> openShowStep(
    WidgetTester tester,
    AppState state, {
    double scale = 1,
  }) async {
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

  Icon markIcon(WidgetTester tester, int group) => tester.widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey<String>('recovery-key-mark-$group')),
          matching: find.byType(Icon),
        ),
      );

  group('U24: the key in 13 numbered groups', () {
    for (final scale in <double>[1, 2]) {
      testWidgets('13 numbered groups fit at 360 dp, text scale $scale', (
        tester,
      ) async {
        phone(tester);
        final state = signedIn();
        await openShowStep(tester, state, scale: scale);
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 13; i++) {
          expect(
            tester
                .widget<Text>(
                  find.byKey(ValueKey<String>('recovery-key-group-${i + 1}')),
                )
                .data,
            groups[i],
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey<String>('recovery-key-display')),
              matching: find.text('${i + 1}'),
            ),
            findsOneWidget,
          );
        }
        expect(
          find.byKey(const ValueKey<String>('recovery-key-group-14')),
          findsNothing,
        );
        // Each group sits inside the screen.
        final last = tester.getRect(
          find.byKey(const ValueKey<String>('recovery-key-group-4')),
        );
        expect(last.right, lessThanOrEqualTo(360));
        state.dispose();
      });
    }

    testWidgets('it is still read group by group, never as one word', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey<String>('recovery-key-display')),
      );
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

    testWidgets('copies the grouped key, and clears it on continuing', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      expect(find.byIcon(Icons.print), findsNothing);
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.textContaining('Print'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-copy')));
      await tester.pumpAndSettle();
      expect(copies, <String>[groups.join('-')]);
      expect(
        find.textContaining('Paste it into your password manager'),
        findsOneWidget,
      );

      // The check that follows must come from the saved copy.
      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();
      expect(copies, <String>[groups.join('-'), '']);
      state.dispose();
    });

    testWidgets('the copy clears itself after 90 seconds, once', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-copy')));
      await tester.pump();
      expect(copies, <String>[groups.join('-')]);
      expect(find.textContaining('about a minute and a half'), findsOneWidget);

      await tester.pump(const Duration(seconds: 89));
      expect(copies, <String>[groups.join('-')]);
      await tester.pump(const Duration(seconds: 1));
      expect(copies, <String>[groups.join('-'), '']);

      // Continuing afterwards does not clear a second time.
      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();
      expect(copies, <String>[groups.join('-'), '']);
      state.dispose();
    });

    testWidgets('continuing cancels the timer, and leaving does not re-clear', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-copy')));
      await tester.pump();
      await tester.tap(find.text('I have saved it'));
      await tester.pump();
      expect(copies, <String>[groups.join('-'), '']);

      await tester.pump(const Duration(seconds: 120));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 120));
      expect(copies, <String>[groups.join('-'), '']);
      state.dispose();
    });

    testWidgets('leaving the screen clears at once and cancels the timer', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openShowStep(tester, state);
      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-copy')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(copies, <String>[groups.join('-'), '']);
      await tester.pump(const Duration(seconds: 120));
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
    testWidgets('ticks the right groups and names the wrong one by number', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      expect(
        find.byKey(const ValueKey<String>('recovery-key-check-message')),
        findsNothing,
      );

      await tester.enterText(
        confirmField(),
        '${groups[0]} ${groups[1].toLowerCase()} ZZZZ',
      );
      await tester.pump();
      expect(markIcon(tester, 1).icon, Icons.check_circle);
      expect(markIcon(tester, 2).icon, Icons.check_circle);
      expect(markIcon(tester, 3).icon, Icons.cancel);
      expect(markIcon(tester, 4).icon, Icons.radio_button_unchecked);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('recovery-key-check-message')),
            )
            .data,
        'Group 3 does not match. Check it on your copy.',
      );
      // The key itself is not on this step.
      expect(find.textContaining(groups[2]), findsNothing);
      state.dispose();
    });

    testWidgets('reads O as 0 and I or L as 1, like the decoder', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      // Group 6 is "YZ01".
      final typed = groups.take(6).join('-').replaceFirst('YZ01', 'yzOL');
      await tester.enterText(confirmField(), typed);
      await tester.pump();
      for (var group = 1; group <= 6; group++) {
        expect(
          markIcon(tester, group).icon,
          Icons.check_circle,
          reason: 'group $group',
        );
      }
      expect(find.text('6 of 13 groups match.'), findsOneWidget);
      state.dispose();
    });

    testWidgets('a group still being typed waits until it goes wrong', (
      tester,
    ) async {
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

    testWidgets('all 13 ticked, and the native check still decides', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      await tester.enterText(confirmField(), '${groups.join(' ')} 7');
      await tester.pump();
      expect(
        find.text(
          'This is longer than the key. Check for extra '
          'characters.',
        ),
        findsOneWidget,
      );
      // Saving is never turned off by the ticks; the native check refuses.
      await tester.tap(find.text('Save recovery key'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That is not the key shown. Check your paper and try '
          'again.',
        ),
        findsOneWidget,
      );
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
      expect(
        recoveryGroupMarks(k0Display, ''),
        everyElement(RecoveryGroupMark.pending),
      );
      expect(
        recoveryGroupMarks(k0Display, k0Display),
        everyElement(RecoveryGroupMark.correct),
      );
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
    await tester.tap(
      find.byKey(const ValueKey<String>('recovery-key-show-draft')),
    );
    await tester.pumpAndSettle();
    expect(crypto.handedOut.length, handedOut, reason: 'no new key was made');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('recovery-key-group-1')),
          )
          .data,
      groups[0],
    );
    state.dispose();
  });

  bool obscured(WidgetTester tester, Finder field) => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .obscureText;

  group('U23: recovery start in three points', () {
    for (final scale in <double>[1, 2]) {
      testWidgets(
        'three points, the fine print behind a toggle, scale $scale',
        (tester) async {
          phone(tester, height: 800);
          final state = k0App(server, store, crypto);
          await tester.pumpWidget(
            app(
              AccountRecoveryStartScreen(state: state, initialServer: k0Origin),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.text(
              'Use this only if you lost every device signed in to '
              'your account.',
            ),
            findsOneWidget,
          );
          expect(
            find.text('You need your password and your recovery key.'),
            findsOneWidget,
          );
          // The wait and who can cancel it stay in sight.
          expect(
            find.textContaining(
              'you wait 7 days, and your devices can '
              'cancel',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining('comes back only from a backup'),
            findsNothing,
          );
          await tester.scrollUntilVisible(
            find.text('How recovery works'),
            100,
            scrollable: find.byType(Scrollable).first,
          );
          // The larger type ramp (U10) can leave the toggle just below the
          // fold at 200% text; scroll its own scrollable until it is on
          // screen.
          await tester.ensureVisible(find.text('How recovery works'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('How recovery works'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('comes back only from a backup'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          state.dispose();
        },
      );
    }

    testWidgets('the password can be shown; the key field is never hidden', (
      tester,
    ) async {
      phone(tester);
      final state = k0App(server, store, crypto);
      await tester.pumpWidget(app(AccountRecoveryStartScreen(state: state)));
      await tester.pumpAndSettle();
      final password = find.byType(TextFormField).at(2);
      expect(obscured(tester, password), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(tester, password), isFalse);
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();
      expect(obscured(tester, password), isTrue);
      expect(
        obscured(
          tester,
          find.byKey(const ValueKey<String>('recovery-key-field')),
        ),
        isFalse,
      );
      state.dispose();
    });
  });

  group('U23: the wait counts down', () {
    Future<AppState> waiting() async {
      final state = k0App(server, store, crypto);
      await state.startAccountRecovery(
        baseUrl: k0Origin,
        username: 'alice',
        password: 'pw',
        recoveryKey: k0Display,
      );
      return state;
    }

    testWidgets('shows the time left beside the date, and redraws', (
      tester,
    ) async {
      phone(tester);
      final state = await waiting();
      final readyAt = state.pendingAccountRecovery!.readyAt;
      var now = readyAt.subtract(const Duration(days: 6, minutes: 30));
      await tester.pumpWidget(
        app(AccountRecoveryWaitingScreen(state: state, clock: () => now)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('recovery-countdown')),
            )
            .data,
        '6 days 1 hour left',
      );
      expect(
        find.textContaining('This device joins your account after'),
        findsOneWidget,
      );

      final polls = server.recoveryPolls;
      now = readyAt.subtract(const Duration(minutes: 3, seconds: 10));
      await tester.pump(recoveryCountdownInterval);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('recovery-countdown')),
            )
            .data,
        '4 minutes left',
      );
      expect(
        server.recoveryPolls,
        polls,
        reason: 'the countdown only redraws; it does not poll',
      );

      now = readyAt.add(const Duration(seconds: 1));
      await tester.pump(recoveryCountdownInterval);
      expect(
        find.byKey(const ValueKey<String>('recovery-countdown')),
        findsNothing,
      );
      expect(
        find.text('The wait is over. Check now to finish.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    test('the time left is rounded up and never reads zero', () {
      final l10n = englishL10n;
      expect(recoveryTimeLeftText(l10n, Duration.zero), '1 minute');
      expect(
        recoveryTimeLeftText(l10n, const Duration(seconds: 61)),
        '2 minutes',
      );
      expect(recoveryTimeLeftText(l10n, const Duration(minutes: 60)), '1 hour');
      expect(
        recoveryTimeLeftText(l10n, const Duration(hours: 2, minutes: 5)),
        '2 hours 5 minutes',
      );
      expect(
        recoveryTimeLeftText(
          l10n,
          const Duration(hours: 23, minutes: 59, seconds: 30),
        ),
        '1 day',
      );
      expect(recoveryTimeLeftText(l10n, const Duration(days: 7)), '7 days');
      expect(
        recoveryTimeLeftText(
          l10n,
          const Duration(days: 6, hours: 23, minutes: 1),
        ),
        '7 days',
      );
    });

    testWidgets('the sign-in password can be shown', (tester) async {
      phone(tester);
      final state = await waiting();
      server.statusAnswers.add(
        const AccountRecoveryStatus(
          phase: AccountRecoveryPhase.completedWithoutToken,
          accountId: 'acct_me',
          deviceId: 'dev_new',
        ),
      );
      await state.checkAccountRecovery();
      await tester.pumpWidget(app(AccountRecoveryWaitingScreen(state: state)));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(obscured(tester, field), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(tester, field), isFalse);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  });

  group('U23: the follow-up shows its step', () {
    test('three steps with the restore, two without', () {
      expect(
        recoveryFollowUpPosition(
          RecoveryFollowUpStep.restore,
          restoreOffered: true,
        ),
        (1, 3),
      );
      expect(
        recoveryFollowUpPosition(
          RecoveryFollowUpStep.recoveryKey,
          restoreOffered: true,
        ),
        (2, 3),
      );
      expect(
        recoveryFollowUpPosition(
          RecoveryFollowUpStep.password,
          restoreOffered: true,
        ),
        (3, 3),
      );
      expect(
        recoveryFollowUpPosition(
          RecoveryFollowUpStep.recoveryKey,
          restoreOffered: false,
        ),
        (1, 2),
      );
      expect(
        recoveryFollowUpPosition(
          RecoveryFollowUpStep.password,
          restoreOffered: false,
        ),
        (2, 2),
      );
    });

    testWidgets('step n of total on each step', (tester) async {
      phone(tester);
      final state = signedIn()..recoveryFollowUp = RecoveryFollowUpStep.restore;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
      state.dispose();

      final last = signedIn()..recoveryFollowUp = RecoveryFollowUpStep.password;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: last)));
      await tester.pumpAndSettle();
      final total = last.k1RestoreSupported ? 3 : 2;
      expect(find.text('Step $total of $total'), findsOneWidget);
      last.dispose();
    });

    testWidgets('Back on the key step stays in the flow', (tester) async {
      phone(tester);
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-back')));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryFollowUpScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('recovery-key-show-draft')),
        findsOneWidget,
      );
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
      state.dispose();
    });

    Finder back() => find.byKey(const ValueKey<String>('follow-up-back'));
    Finder anyBack() => find.byIcon(Icons.arrow_back);

    testWidgets('Back from the key step returns to the restore step, and on',
        (tester) async {
      phone(tester);
      crypto = K0RestoringCrypto();
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(back(), findsOneWidget);

      await tester.tap(back());
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('follow-up-restore')),
          findsOneWidget);
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.restore);
      expect(await store.loadSetting('k0.recovery_follow_up'),
          'acct_me\u0000dev_old\u0000restore');
      // The first step has nothing before it.
      expect(back(), findsNothing);
      expect(anyBack(), findsNothing);

      // Forward again goes through the same skip warning.
      await tester
          .tap(find.byKey(const ValueKey<String>('follow-up-restore-skip')));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('older backups become unusable'), findsOneWidget);
      await tester.tap(
          find.byKey(const ValueKey<String>('follow-up-restore-skip-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
      expect(back(), findsOneWidget);

      // Back and forth made no key and replaced nothing.
      expect(crypto.handedOut, isEmpty);
      expect(server.puts, isEmpty);
      expect(server.passwords, isEmpty);
      state.dispose();
    });

    testWidgets('no step Back while a new key is held', (tester) async {
      phone(tester);
      crypto = K0RestoringCrypto();
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a recovery key'));
      await tester.pumpAndSettle();
      expect(back(), findsNothing);
      // The key's own Back keeps the key; the step stays.
      await tester.tap(find.byKey(const ValueKey<String>('recovery-key-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('recovery-key-show-draft')),
          findsOneWidget);
      expect(back(), findsNothing,
          reason: 'leaving would drop a key that may be written down');
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
      state.dispose();
    });

    testWidgets('a saved key leads to the password step, which has no Back',
        (tester) async {
      phone(tester);
      crypto = K0RestoringCrypto();
      server.requireRecentAuth = false;
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a recovery key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have saved it'));
      await tester.pumpAndSettle();
      await tester.enterText(confirmField(), k0Display);
      await tester.tap(find.text('Save recovery key'));
      await tester.pumpAndSettle();
      expect(server.puts, hasLength(1));
      expect(state.recoveryFollowUp, RecoveryFollowUpStep.password);
      expect(find.text('Step 3 of 3'), findsOneWidget);
      // The new key is on the server and wiped here: going back could
      // only replace it again.
      expect(back(), findsNothing);
      expect(anyBack(), findsNothing);
      expect(find.byType(BackButton), findsNothing);
      expect(state.canGoBackToRecoveryRestore, isFalse);
      expect(server.puts, hasLength(1));
      state.dispose();
    });

    testWidgets('without the restore, the key step is first and has no Back',
        (tester) async {
      phone(tester);
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.recoveryKey;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      expect(state.k1RestoreSupported, isFalse);
      expect(find.text('Step 1 of 2'), findsOneWidget);
      expect(back(), findsNothing);
      state.dispose();
    });

    testWidgets('one toggle shows both new-password fields', (tester) async {
      phone(tester);
      final state = signedIn()
        ..recoveryFollowUp = RecoveryFollowUpStep.password;
      await tester.pumpWidget(app(RecoveryFollowUpScreen(state: state)));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      expect(obscured(tester, fields.at(0)), isTrue);
      expect(obscured(tester, fields.at(1)), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(tester, fields.at(0)), isFalse);
      expect(obscured(tester, fields.at(1)), isFalse);
      state.dispose();
    });
  });

  testWidgets('U23: the password dialog can show the password', (tester) async {
    phone(tester);
    final state = signedIn();
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmPasswordForRecentAuth(context, state),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(obscured(tester, field), isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(obscured(tester, field), isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    state.dispose();
  });

  group('U37: Check my key', () {
    testWidgets('says whether the typed key is the one shown, saves nothing', (
      tester,
    ) async {
      phone(tester);
      final state = signedIn();
      await openConfirmStep(tester, state);
      final check = find.byKey(
        const ValueKey<String>('recovery-key-check-button'),
      );
      await tester.enterText(confirmField(), 'WRONG');
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.recoveryKeyMismatch), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('recovery-key-check-ok')),
        findsNothing,
      );
      await tester.enterText(confirmField(), k0Display);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('recovery-key-check-ok')),
        findsOneWidget,
      );
      expect(find.text(englishL10n.recoveryKeyMismatch), findsNothing);
      // Editing the text clears the answer.
      await tester.enterText(confirmField(), '${k0Display}X');
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('recovery-key-check-ok')),
        findsNothing,
      );
      state.dispose();
    });
  });
}
