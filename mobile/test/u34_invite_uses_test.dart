// U34: an invite reads "3 of 5 used".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/invite_screen.dart';
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

AppState _state(List<Invite> invites) {
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
      role: 'admin',
    )
    ..invitesLoaded = true
    ..invites = invites;
  addTearDown(state.dispose);
  return state;
}

Future<void> _show(
  WidgetTester tester,
  AppState state, {
  DateTime? now,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: veritraLightTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: InviteScreen(state: state, now: now),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  final now = DateTime.utc(2026, 11, 21, 12);

  testWidgets('an invite shows how many of its uses are taken', (tester) async {
    await _show(
      tester,
      _state(<Invite>[Invite(id: 'i1', code: 'ABC123', maxUses: 5, uses: 3)]),
    );

    expect(find.text('3 of 5 used'), findsOneWidget);
    expect(find.text('3/5'), findsNothing);
  });

  testWidgets('expiry is in words, not a date', (tester) async {
    await _show(
      tester,
      _state(<Invite>[
        Invite(
          id: 'i1',
          code: 'AAA111',
          maxUses: 1,
          uses: 0,
          expiresAt: now.add(const Duration(days: 6, hours: 4)),
        ),
        Invite(
          id: 'i2',
          code: 'BBB222',
          maxUses: 1,
          uses: 0,
          expiresAt: now.add(const Duration(minutes: 40)),
        ),
        Invite(id: 'i3', code: 'CCC333', maxUses: 1, uses: 0),
        Invite(
          id: 'i4',
          code: 'DDD444',
          maxUses: 1,
          uses: 0,
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ]),
      now: now,
    );

    expect(find.text('Expires in 6 days 4 hours'), findsOneWidget);
    expect(find.text('Expires in 40 minutes'), findsOneWidget);
    expect(find.text('Never expires'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
  });

  testWidgets('turning an invite off asks first and can be cancelled', (
    tester,
  ) async {
    final state = _state(<Invite>[
      Invite(id: 'i1', code: 'ABC123', maxUses: 5, uses: 3),
    ]);
    await _show(tester, state);

    await tester.tap(find.byTooltip(englishL10n.inviteActions));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('invite-turn-off')));
    await tester.pumpAndSettle();

    expect(find.text('Turn off this invite?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('ABC123'), findsOneWidget);
    expect(state.invites, hasLength(1));
  });

  testWidgets('an invite without a code cannot be re-shared, only turned off', (
    tester,
  ) async {
    await _show(
      tester,
      _state(<Invite>[Invite(id: 'i1', code: '', maxUses: 5, uses: 3)]),
    );

    expect(find.text("Can't be shared again"), findsOneWidget);
    await tester.tap(find.byTooltip(englishL10n.inviteActions));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey<String>('invite-copy-link')), findsNothing);
    expect(find.byKey(const ValueKey<String>('invite-show-qr')), findsNothing);
    expect(find.text('Copy code'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('invite-turn-off')),
      findsOneWidget,
    );
  });
}
