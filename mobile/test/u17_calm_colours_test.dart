import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/conversation_pause.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart';
import 'package:private_messenger/ui/widgets/account_recovery_banner.dart';
import 'package:private_messenger/ui/widgets/connection_banner.dart';
import 'package:private_messenger/ui/widgets/notice_stack.dart';

import 'k0_recovery_fakes.dart';

/// UI-audit card U17: red is for danger. Offline, "messages waiting", the
/// hidden-message bubble and failed sends are neutral or amber; several
/// notices fold into one plus "N more"; an account-recovery attempt is its
/// own card with a filled "This is not me" button.
void main() {
  final themes = <String, ThemeData Function()>{
    'light': veritraLightTheme,
    'dark': veritraDarkTheme,
  };

  late K0Server server;
  late MemoryLocalStore store;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
  });

  AppState signedIn() => k0App(server, store, K0Crypto())
    ..session = k0SignedIn
    ..api = K0Api(server)
    // Online, so only what a test adds is showing (connecting would also
    // spin forever and stop pumpAndSettle).
    ..connectionStatus = ConnectionStatus.online
    ..conversations = <Conversation>[
      Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'acct_me'),
    ]
    ..conversationsLoaded = true;

  Color warningOf(ThemeData theme) {
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    return states.warning;
  }

  RecoveryKeyStatus waiting() => RecoveryKeyStatus(
        available: true,
        configured: true,
        pending: PendingRecoveryRequest(
            id: 'arr_9',
            deviceName: 'Unknown phone',
            readyAt: DateTime.utc(2099, 11, 8, 10)),
      );

  Widget shell(ThemeData theme, Widget body) =>
      MaterialApp(theme: theme, home: Scaffold(body: body));

  group('contrast', () {
    for (final entry in themes.entries) {
      final theme = entry.value();
      final scheme = theme.colorScheme;
      final states = theme.brightness == Brightness.dark
          ? VeritraStateColors.dark
          : VeritraStateColors.light;
      final own = BoneColors.ownBubble(theme.brightness);

      test('${entry.key}: words on the calm surfaces are at least 4.5:1', () {
        // Offline, connecting and "messages waiting": the neutral strip.
        expect(contrastRatio(scheme.onSurface, scheme.surfaceContainerHigh),
            greaterThanOrEqualTo(4.5));
        // The hidden-message bubble and a failed send keep normal words.
        expect(
            contrastRatio(scheme.onSurfaceVariant, scheme.surfaceContainerLow),
            greaterThanOrEqualTo(4.5));
        expect(contrastRatio(scheme.onSurface, own), greaterThanOrEqualTo(4.5));
      });

      test('${entry.key}: the amber icon and border are at least 3:1', () {
        for (final ground in <Color>[
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerLow,
          own,
        ]) {
          expect(contrastRatio(states.warning, ground), greaterThanOrEqualTo(3),
              reason: '$ground');
        }
        expect(contrastRatio(states.info, scheme.surfaceContainerHigh),
            greaterThanOrEqualTo(3));
      });

      test('${entry.key}: the recovery card and its button stay loud', () {
        expect(contrastRatio(scheme.onErrorContainer, scheme.errorContainer),
            greaterThanOrEqualTo(4.5));
        // The filled button: its label on its fill, and its fill on the card.
        expect(contrastRatio(scheme.onError, scheme.error),
            greaterThanOrEqualTo(4.5));
        expect(contrastRatio(scheme.error, scheme.errorContainer),
            greaterThanOrEqualTo(3));
      });
    }
  });

  group('offline', () {
    for (final entry in themes.entries) {
      testWidgets('is neutral with an amber icon, ${entry.key}',
          (tester) async {
        final theme = entry.value();
        final state = signedIn()..connectionStatus = ConnectionStatus.offline;
        addTearDown(state.dispose);
        await tester.pumpWidget(shell(theme, ConnectionBanner(state: state)));
        expect(find.text('Offline'), findsOneWidget);
        final strip = tester.widget<Material>(find
            .ancestor(of: find.text('Offline'), matching: find.byType(Material))
            .first);
        expect(strip.color, theme.colorScheme.surfaceContainerHigh);
        expect(strip.color, isNot(theme.colorScheme.errorContainer));
        final icon = tester.widget<Icon>(find.byIcon(Icons.cloud_off_outlined));
        expect(icon.color, warningOf(theme));
        final words = tester.widget<Text>(find.text('Offline'));
        expect(words.style?.color, theme.colorScheme.onSurface);
      });
    }

    testWidgets('meets the text contrast guideline', (tester) async {
      final semantics = tester.ensureSemantics();
      for (final theme in themes.values) {
        final state = signedIn()..connectionStatus = ConnectionStatus.offline;
        addTearDown(state.dispose);
        await tester.pumpWidget(shell(theme(), NoticeStack(state: state)));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      }
      semantics.dispose();
    });
  });

  group('folding', () {
    final copying = HistoryTransferStatus(
        incoming: true, phase: HistoryTransferPhase.working);

    testWidgets('several notices show as one plus "N more"', (tester) async {
      final state = signedIn()
        ..connectionStatus = ConnectionStatus.offline
        ..historyTransferStatus = copying;
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));

      // The most urgent one shows; the other is behind the button.
      expect(find.text('Offline'), findsOneWidget);
      expect(find.textContaining('Receiving your history'), findsNothing);
      expect(find.text('1 more'), findsOneWidget);

      await tester.tap(find.text('1 more'));
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
      expect(find.textContaining('Receiving your history'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);
      expect(find.text('1 more'), findsNothing);

      await tester.tap(find.text('Show fewer'));
      await tester.pump();
      expect(find.textContaining('Receiving your history'), findsNothing);
      expect(find.text('1 more'), findsOneWidget);
    });

    testWidgets('one notice shows alone, with no "more" button',
        (tester) async {
      final state = signedIn()..connectionStatus = ConnectionStatus.offline;
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('notice-stack-toggle')),
          findsNothing);
    });

    testWidgets('a notice that goes away leaves the count right',
        (tester) async {
      final state = signedIn()
        ..connectionStatus = ConnectionStatus.offline
        ..historyTransferStatus = copying;
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));
      expect(find.text('1 more'), findsOneWidget);
      await tester.tap(find.text('1 more'));
      await tester.pump();
      expect(find.textContaining('Receiving your history'), findsOneWidget);
      // The copy ending folds the stack back to one.
      state.historyTransferStatus = null;
      state.notifyListeners();
      await tester.pump();
      expect(find.textContaining('Receiving your history'), findsNothing);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('notice-stack-toggle')),
          findsNothing);
    });

    testWidgets('a passkey change and a leaked password are never folded',
        (tester) async {
      final state = signedIn()
        ..connectionStatus = ConnectionStatus.offline
        ..historyTransferStatus = copying
        ..passkeyNotice = PasskeyNotice.added;
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      await store.saveSetting(
          'k0.password_leak_day', '$k0Origin\u0000acct_me\u0000$today');
      await state.refreshRecoveryNotices();
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));
      expect(find.textContaining('A passkey was added'), findsOneWidget);
      expect(find.byType(PasswordLeakBanner), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      // Only the connection and the history copy fold.
      expect(find.textContaining('Receiving your history'), findsNothing);
      expect(find.text('1 more'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('the pushed chat shows the account notices unfolded',
        (tester) async {
      final state = signedIn()
        ..connectionStatus = ConnectionStatus.offline
        ..passkeyNotice = PasskeyNotice.removed;
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: veritraLightTheme(),
          home: ChatScreen(
              state: state, conversationId: 'conv', showBackButton: true)));
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsNothing);
      expect(find.textContaining('A passkey was removed'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('notice-stack-toggle')),
          findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('recovery attempt', () {
    for (final entry in themes.entries) {
      testWidgets('is its own red card with a filled button, ${entry.key}',
          (tester) async {
        final theme = entry.value();
        final state = signedIn()..recoveryKeyStatus = waiting();
        addTearDown(state.dispose);
        await tester
            .pumpWidget(shell(theme, RecoveryAttemptCard(state: state)));
        expect(find.text('Account recovery attempt'), findsOneWidget);
        expect(find.textContaining('“Unknown phone”'), findsOneWidget);
        final card = tester.widget<Container>(
            find.byKey(const ValueKey<String>('recovery-attempt-card')));
        final decoration = card.decoration! as BoxDecoration;
        expect(decoration.color, theme.colorScheme.errorContainer);
        final button =
            find.byKey(const ValueKey<String>('recovery-attempt-not-me'));
        expect(tester.widget(button), isA<FilledButton>());
        expect(
            find.descendant(of: button, matching: find.text('This is not me')),
            findsOneWidget);
        final style = tester.widget<FilledButton>(button).style!;
        expect(style.backgroundColor!.resolve(<WidgetState>{}),
            theme.colorScheme.error);
        expect(style.foregroundColor!.resolve(<WidgetState>{}),
            theme.colorScheme.onError);
        // A real, enabled button at least 48 dp tall.
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(tester.getSize(button).height,
            greaterThanOrEqualTo(BoneSpacing.minTapTarget));
      });
    }

    testWidgets('is never folded behind "N more"', (tester) async {
      final state = signedIn()
        ..recoveryKeyStatus = waiting()
        ..connectionStatus = ConnectionStatus.offline
        ..passkeyNotice = PasskeyNotice.added
        ..historyTransferStatus = const HistoryTransferStatus(
            incoming: false, phase: HistoryTransferPhase.failed);
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraDarkTheme(), NoticeStack(state: state)));
      // The attempt and the passkey notice show in full; the other two fold
      // to one plus 1 more.
      expect(find.text('Account recovery attempt'), findsOneWidget);
      expect(find.text('This is not me'), findsOneWidget);
      expect(find.textContaining('A passkey was added'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('1 more'), findsOneWidget);
    });

    testWidgets('"This is not me" is off while a cancel runs, then back on',
        (tester) async {
      final state = signedIn()..recoveryKeyStatus = waiting();
      addTearDown(state.dispose);
      server
        ..recentAuth = true
        ..cancelGate = Completer<void>()
        ..cancelFailure = ApiException(404, 'proxy says no');
      await tester.pumpWidget(
          shell(veritraLightTheme(), RecoveryAttemptCard(state: state)));
      FilledButton notMe() => tester.widget<FilledButton>(
          find.byKey(const ValueKey<String>('recovery-attempt-not-me')));
      expect(notMe().onPressed, isNotNull);

      final cancelling = state.cancelAccountRecoveryRequest('arr_9');
      await tester.pump();
      expect(state.isBusy(Ops.accountRecovery), isTrue);
      expect(notMe().onPressed, isNull);

      server.cancelGate!.complete();
      await cancelling;
      await tester.pump();
      expect(state.isBusy(Ops.accountRecovery), isFalse);
      // The recovery is still waiting, and the button works again.
      expect(find.text('This is not me'), findsOneWidget);
      expect(notMe().onPressed, isNotNull);
    });

    testWidgets('on its own it has no "more" button', (tester) async {
      final state = signedIn()..recoveryKeyStatus = waiting();
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));
      expect(find.text('This is not me'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('notice-stack-toggle')),
          findsNothing);
    });

    testWidgets('"This is not me" asks first, then cancels the same recovery',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = signedIn()..recoveryKeyStatus = waiting();
      addTearDown(state.dispose);
      await tester
          .pumpWidget(shell(veritraLightTheme(), NoticeStack(state: state)));
      await tester.tap(find.text('This is not me'));
      await tester.pumpAndSettle();
      // Nothing is cancelled until the dialog is confirmed.
      expect(find.text('Cancel this recovery?'), findsOneWidget);
      expect(server.cancels, isEmpty);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel recovery')));
      await tester.pumpAndSettle();
      // The same action as before; it asks for the password first.
      expect(find.text('Confirm your password'), findsOneWidget);
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'pw');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(server.cancels, <String>['arr_9']);
    });
  });

  group('chat surfaces', () {
    for (final entry in themes.entries) {
      testWidgets('a failed send is amber, not red, ${entry.key}',
          (tester) async {
        final theme = entry.value();
        final state = signedIn()
          ..pendingOutbox = [
            MessageEnvelope(
                conversationId: 'conv',
                idempotencyKey: 'k1',
                ciphertext: const [1],
                cryptoProtocol: 'test'),
          ];
        addTearDown(state.dispose);
        await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: ChatScreen(state: state, conversationId: 'conv')));
        await tester.pumpAndSettle();
        final retry = find.byKey(const Key('pending-not-sent-retry'));
        expect(retry, findsOneWidget);
        final bubble = tester.widget<Container>(find
            .ancestor(
                of: retry,
                matching: find.byWidgetPredicate((widget) =>
                    widget is Container &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration! as BoxDecoration).border != null))
            .first);
        final decoration = bubble.decoration! as BoxDecoration;
        expect(decoration.color, BoneColors.ownBubble(theme.brightness));
        expect(decoration.color, isNot(theme.colorScheme.errorContainer));
        expect((decoration.border! as Border).top.color, warningOf(theme));
        final icon = tester.widget<Icon>(find.descendant(
            of: retry, matching: find.byIcon(Icons.error_outline)));
        expect(icon.color, warningOf(theme));
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('"messages waiting" is a neutral strip, ${entry.key}',
          (tester) async {
        final theme = entry.value();
        final state = signedIn()
          ..conversationPauses = <String, ConversationPause>{
            'conv': ConversationPause(
                conversationId: 'conv',
                resumeAfter: 1,
                failedEventId: 2,
                kind: SyncFailureKind.governanceHeld,
                recordedAt: DateTime.utc(2026, 11, 14)),
          };
        addTearDown(state.dispose);
        await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: ChatScreen(state: state, conversationId: 'conv')));
        await tester.pumpAndSettle();
        final notice = tester.widget<Container>(
            find.byKey(const ValueKey('sync-paused-notice')));
        expect(notice.color, theme.colorScheme.surfaceContainerHigh);
        expect(find.textContaining('are waiting'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final entry in themes.entries) {
      testWidgets('the hidden-message bubble is amber, not red, ${entry.key}',
          (tester) async {
        final theme = entry.value();
        final state = signedIn();
        addTearDown(state.dispose);
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
            0);
        await store.commitMlsTransition(MlsStateTransition(
            messageId: 'seed-1',
            conversationId: 'conv',
            expectedCounter: 1,
            expectedCursor: 0,
            state: StoredCryptoState(
                counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
            cursor: 1,
            messageEffects: [
              InsertMessageEffect(
                  key: 'dev:m1',
                  conversationId: 'conv',
                  senderAccountId: 'alice',
                  senderDeviceId: 'dev',
                  kind: LocalMessageKind.unverifiable,
                  body: '',
                  createdAt: 1,
                  state: LocalMessageState.received),
            ]));
        await state.refreshHistory('conv');
        await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: ChatScreen(state: state, conversationId: 'conv')));
        await tester.pumpAndSettle();
        final words =
            find.text('Sender could not be verified. Message hidden.');
        expect(words, findsOneWidget);
        expect(tester.widget<Text>(words).style?.color,
            theme.colorScheme.onSurfaceVariant);
        expect(tester.widget<Icon>(find.byIcon(Icons.gpp_maybe_outlined)).color,
            warningOf(theme));
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('a paused conversation that needs a choice stays red',
        (tester) async {
      final theme = veritraLightTheme();
      final state = signedIn()
        ..conversationPauses = <String, ConversationPause>{
          'conv': ConversationPause(
              conversationId: 'conv',
              resumeAfter: 1,
              failedEventId: 2,
              kind: SyncFailureKind.localStorage,
              recordedAt: DateTime.utc(2026, 11, 14)),
        };
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: ChatScreen(state: state, conversationId: 'conv')));
      await tester.pumpAndSettle();
      final notice = tester
          .widget<Container>(find.byKey(const ValueKey('sync-paused-notice')));
      expect(notice.color, theme.colorScheme.errorContainer);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
