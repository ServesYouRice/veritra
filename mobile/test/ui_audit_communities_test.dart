import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

// UI audit 2026-11-14, communities cards (U1, U4, U31, U32, part of U8).

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Roles implements VerifiedRoleSource {
  _Roles(this.state);
  final GovernanceState state;
  @override
  GovernanceState? governanceOf(String conversationId) => state;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

AppState _ownerState() {
  final api = ApiClient(baseUrl: 'https://example.test');
  final state = AppState(
    apiClientFactory: (_) => api,
    syncServiceFactory: (_, __) => _Sync(),
    localStore: MemoryLocalStore(),
    cryptoService: UnavailableCryptoService(),
  )
    ..api = api
    ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'device')
    ..communities = <Community>[
      Community(id: 'comm_1', name: 'Club', sharedConversationId: 'shared'),
    ]
    ..conversations = <Conversation>[
      Conversation(
          id: 'shared',
          kind: 'community_shared',
          communityId: 'comm_1',
          currentRole: 'owner'),
    ]
    ..debugInfoRoleSource = _Roles(GovernanceState(
        rev: 1, owner: 'alice', ownerRev: 1, joined: const {'alice': 1}));
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  testWidgets(
      'U1: at 360 dp an owner sees the whole name, one actions menu, and a '
      'header under 100 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _ownerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(CommunityScreen(state: state)));
    await tester.pumpAndSettle();

    // The community name is not squeezed out by trailing buttons.
    final name = find.text('Community');
    expect(name, findsOneWidget);
    expect(tester.getSize(name).width, greaterThan(100));
    expect(tester.getSize(name).height, lessThan(30),
        reason: 'one line, not one letter per line');
    // The header (first tile of the card) is under 100 dp tall.
    expect(tester.getSize(find.byType(ListTile).first).height, lessThan(100));
    // One labelled menu, no loose icon buttons on the header.
    final menu = find.byType(PopupMenuButton<String>);
    expect(menu, findsOneWidget);
    expect(find.byTooltip('Actions for Community'), findsOneWidget);
    expect(find.byType(IconButton), findsNWidgets(2),
        reason: 'only the top bar: Join with a link and Refresh');

    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Edit community'), findsOneWidget);
    expect(find.text('Categories and icon'), findsOneWidget);
    expect(find.text('Roles'), findsOneWidget);
    expect(find.text('New channel'), findsOneWidget);
  });
}
