// U15 and U16: risky actions get words. Devices sign out through a labelled
// button and a red confirmation that names the device; blocking asks first
// and both directions offer Undo. (Members, join requests and invitation
// links are covered in ui_remaining_test and membership_screens_test.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/block_actions.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

AppState _stateWithDevices() {
  final state = AppState(
    apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    )
    ..devicesLoaded = true
    ..devices = <Device>[
      Device(
        id: 'dev_me',
        accountId: 'acct_me',
        name: 'Pixel 8',
        createdAt: DateTime.utc(2026, 1, 2),
      ),
      Device(
        id: 'dev_old',
        accountId: 'acct_me',
        name: 'Old tablet',
        createdAt: DateTime.utc(2025, 6, 1),
      ),
    ];
  addTearDown(state.dispose);
  return state;
}

Future<void> _show(WidgetTester tester, AppState state,
    {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(360, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: veritraLightTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(body: SettingsScreen(state: state)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  final l10n = englishL10n;

  group('U15 devices', () {
    testWidgets('sign-out is a labelled button with a red confirmation naming '
        'the device', (tester) async {
      await _show(tester, _stateWithDevices());

      final button = find.byKey(const ValueKey<String>('device-sign-out-dev_old'));
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.text(l10n.settingsSignOutDeviceButton)),
          findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('Sign out "Old tablet"?')),
          findsOneWidget);
      final confirm = tester.widget<FilledButton>(find.descendant(
          of: dialog, matching: find.byType(FilledButton)));
      expect(confirm.style?.backgroundColor?.resolve(<WidgetState>{}),
          Theme.of(tester.element(dialog)).colorScheme.error);
    });

    testWidgets('at 200% text the button drops under the name, which keeps '
        '120 dp', (tester) async {
      await _show(tester, _stateWithDevices(), scale: 2.0);
      expect(tester.takeException(), isNull);
      final name = tester.getSize(find.text('Old tablet'));
      expect(name.width, greaterThanOrEqualTo(120));
      final button = find.byKey(const ValueKey<String>('device-sign-out-dev_old'));
      expect(tester.getTopLeft(button).dy,
          greaterThan(tester.getBottomLeft(find.text('Old tablet')).dy));
    });
  });

  group('U16 block and unblock', () {
    Future<_BlockState> pumpButton(WidgetTester tester,
        {required bool blocked}) async {
      final state = _BlockState();
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => toggleBlock(
                context,
                state,
                accountId: 'acct_sam',
                label: '@sam',
                blocked: blocked,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      return state;
    }

    testWidgets('blocking asks first; cancelling sends nothing',
        (tester) async {
      final state = await pumpButton(tester, blocked: false);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Block @sam'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.calls, isEmpty);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('a confirmed block offers Undo, which unblocks',
        (tester) async {
      final state = await pumpButton(tester, blocked: false);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      expect(state.calls, <String>['block:acct_sam']);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(state.calls, <String>['block:acct_sam', 'unblock:acct_sam']);
    });

    testWidgets('unblocking needs no question and offers Undo, which blocks',
        (tester) async {
      final state = await pumpButton(tester, blocked: true);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(state.calls, <String>['unblock:acct_sam']);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(state.calls, <String>['unblock:acct_sam', 'block:acct_sam']);
    });
  });
}

class _BlockState extends AppState {
  _BlockState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final List<String> calls = <String>[];

  @override
  Future<bool> blockAccount(String accountId) async {
    calls.add('block:$accountId');
    return true;
  }

  @override
  Future<bool> unblockAccount(String accountId) async {
    calls.add('unblock:$accountId');
    return true;
  }
}
