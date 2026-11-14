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

void main() {
  testWidgets('an invite shows how many of its uses are taken', (tester) async {
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
      ..invitesLoaded = true
      ..invites = <Invite>[
        Invite(id: 'i1', code: 'ABC123', maxUses: 5, uses: 3),
      ];
    addTearDown(state.dispose);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: InviteScreen(state: state),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('3 of 5 used'), findsOneWidget);
    expect(find.text('3/5'), findsNothing);
  });
}
