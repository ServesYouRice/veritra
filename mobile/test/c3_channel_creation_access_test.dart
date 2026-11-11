import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/features/communities/create_channel_dialog.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  String role = 'owner';
  bool failList = false;
  bool failRoster = false;
  List<Community> listed = [
    Community(id: 'community', name: 'Club', sharedConversationId: 'shared'),
  ];
  Future<List<ConversationMember>> Function()? roster;

  @override
  Future<Community> createCommunity(String token, String name) async {
    final created = Community(id: 'created', name: name);
    listed = [created];
    return created;
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    if (failList) throw ApiException(503, '');
    return listed;
  }

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async =>
      [];

  @override
  Future<List<ConversationMember>> communityMembers(
      String token, String communityId) async {
    if (failRoster) throw ApiException(503, '');
    if (roster != null) return roster!();
    return [ConversationMember(accountId: 'alice', role: role)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState stateFor(_Api api) {
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
          deviceId: 'device');
    addTearDown(state.dispose);
    return state;
  }

  Future<void> show(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CommunityScreen(state: state),
    ));
    await tester.pumpAndSettle();
  }

  for (final role in ['owner', 'admin', 'moderator', 'member']) {
    testWidgets('$role channel creation entry follows the refreshed roster',
        (tester) async {
      final api = _Api()..role = role;
      final state = stateFor(api);
      await state.refreshCommunities();
      await show(tester, state);
      final allowed = role == 'owner' || role == 'admin';
      expect(find.byTooltip('New channel'),
          allowed ? findsOneWidget : findsNothing);
      if (allowed) {
        await tester.tap(find.byTooltip('New channel'));
        await tester.pumpAndSettle();
        expect(find.byType(CreateChannelDialog), findsOneWidget);
      }
      // Server roster hints never unlock encrypted peer records or edits.
      expect(state.mayEditCommunityInfo('community', 'community'), isFalse);
    });
  }

  testWidgets('legacy communities also hide creation from moderators',
      (tester) async {
    final api = _Api()
      ..listed = [Community(id: 'community', name: 'Legacy club')]
      ..role = 'moderator';
    final state = stateFor(api);
    await state.refreshCommunities();
    await show(tester, state);
    expect(find.byTooltip('New channel'), findsNothing);
    api.role = 'admin';
    await state.refreshCommunities();
    await tester.pumpAndSettle();
    expect(find.byTooltip('New channel'), findsOneWidget);
    await tester.tap(find.byTooltip('New channel'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(CreateChannelDialog), findsNothing);
  });

  testWidgets(
      'refresh hides stale access, then reflects demotion and promotion',
      (tester) async {
    final api = _Api();
    final state = stateFor(api);
    await state.refreshCommunities();
    await show(tester, state);
    final pending = Completer<List<ConversationMember>>();
    api.roster = () => pending.future;
    final refresh = state.refreshCommunities();
    await tester.pump();
    expect(find.byTooltip('New channel'), findsNothing);
    pending
        .complete([ConversationMember(accountId: 'alice', role: 'moderator')]);
    await refresh;
    await tester.pumpAndSettle();
    expect(find.byTooltip('New channel'), findsNothing);
    api.roster = null;
    api.role = 'admin';
    await state.refreshCommunities();
    await tester.pumpAndSettle();
    expect(find.byTooltip('New channel'), findsOneWidget);
  });

  test('list or roster failure keeps channels but clears creation access',
      () async {
    final api = _Api();
    final state = stateFor(api);
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isTrue);
    api.failRoster = true;
    await state.refreshCommunities();
    expect(state.communities.single.name, 'Club');
    expect(state.mayCreateCommunityChannel('community'), isFalse);
    api.failRoster = false;
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isTrue);
    api.failList = true;
    await state.refreshCommunities();
    expect(state.communities.single.name, 'Club');
    expect(state.mayCreateCommunityChannel('community'), isFalse);
  });

  test('an older roster cannot overwrite a newer refresh', () async {
    final api = _Api();
    final state = stateFor(api);
    final pending = Completer<List<ConversationMember>>();
    final started = Completer<void>();
    api.roster = () {
      started.complete();
      return pending.future;
    };
    final old = state.refreshCommunities();
    await started.future;
    api.roster = null;
    api.role = 'member';
    await state.refreshCommunities();
    pending.complete([ConversationMember(accountId: 'alice', role: 'owner')]);
    await old;
    expect(state.mayCreateCommunityChannel('community'), isFalse);
  });

  test('session replacement invalidates cached and in-flight access', () async {
    final api = _Api();
    final state = stateFor(api);
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isTrue);
    final pending = Completer<List<ConversationMember>>();
    final started = Completer<void>();
    api.roster = () {
      started.complete();
      return pending.future;
    };
    final old = state.refreshCommunities();
    await started.future;
    state.session = const Session(
        baseUrl: 'https://example.test',
        token: 'another-token',
        accountId: 'alice',
        deviceId: 'device');
    expect(state.mayCreateCommunityChannel('community'), isFalse);
    pending.complete([ConversationMember(accountId: 'alice', role: 'owner')]);
    await old;
    expect(state.mayCreateCommunityChannel('community'), isFalse);
  });

  test('creating a community loads creation rights without manual refresh',
      () async {
    final api = _Api();
    final state = stateFor(api);
    final rosterRead = Completer<void>();
    api.roster = () async {
      rosterRead.complete();
      return [ConversationMember(accountId: 'alice', role: 'owner')];
    };
    final created = await state.createCommunity('New club');
    expect(created?.id, 'created');
    await rosterRead.future;
    await Future<void>.delayed(Duration.zero);
    expect(state.mayCreateCommunityChannel('created'), isTrue);
  });

  test('missing viewer and removed communities have no creation entry',
      () async {
    final api = _Api();
    final state = stateFor(api);
    api.roster =
        () async => [ConversationMember(accountId: 'bob', role: 'owner')];
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isFalse);
    api.roster = null;
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isTrue);
    api.listed = [];
    await state.refreshCommunities();
    expect(state.mayCreateCommunityChannel('community'), isFalse);
  });
}
