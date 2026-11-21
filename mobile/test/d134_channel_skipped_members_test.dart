import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

// D134: a legacy-layout channel is made without community members already in
// the most chats an account may; the server counts them in skipped_members
// and the admin who made the channel is told how many.

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient with LegacySyncPageFake {
  _Api() : super(baseUrl: 'https://localhost:8080');

  /// What the next [createChannel] answers in skipped_members; null makes
  /// it fail.
  int? skipped = 0;
  var _channels = 0;

  @override
  Future<ChannelCreation> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'private',
  }) async {
    final count = skipped;
    if (count == null) {
      throw ApiException(500, '{"error":"internal"}');
    }
    _channels += 1;
    final channel = Channel(
        id: 'chan_$_channels', communityId: communityId, name: '', kind: kind);
    return ChannelCreation.fromJson(<String, Object?>{
      'channel': <String, Object?>{
        'id': channel.id,
        'community_id': communityId,
        'kind': kind,
      },
      'conversation': <String, Object?>{
        'id': 'conv_$_channels',
        'kind': 'community_channel',
        'community_id': communityId,
        'channel_id': channel.id,
      },
      'skipped_members': count,
    });
  }

  @override
  Future<List<Community>> listCommunities(String token) async =>
      <Community>[_community];

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async =>
      const <Channel>[];

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<MessagePage> listMessagePage(String token, String conversationId,
          {int limit = 50, String? before}) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];
}

// A legacy community (no shared group) this account created.
final _community = Community(id: 'comm_1', name: '', createdBy: 'acct_owner');

AppState _state(_Api api) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..communities = <Community>[_community];

void main() {
  group('ChannelCreation.skippedMembers', () {
    Map<String, Object?> body(Object? skipped, {bool include = true}) =>
        <String, Object?>{
          'channel': <String, Object?>{
            'id': 'chan_1',
            'community_id': 'comm_1',
            'kind': 'private'
          },
          'conversation': <String, Object?>{
            'id': 'conv_1',
            'kind': 'community_channel'
          },
          if (include) 'skipped_members': skipped,
        };

    test('reads the count the server sends', () {
      expect(ChannelCreation.fromJson(body(2)).skippedMembers, 2);
      expect(ChannelCreation.fromJson(body(0)).skippedMembers, 0);
    });

    test('is 0 from an older server or for a value that is no count', () {
      expect(
          ChannelCreation.fromJson(body(null, include: false)).skippedMembers,
          0);
      expect(ChannelCreation.fromJson(body(-1)).skippedMembers, 0);
      expect(ChannelCreation.fromJson(body('3')).skippedMembers, 0);
    });
  });

  test('createChannel records the members left out, and resets the count',
      () async {
    final api = _Api()..skipped = 2;
    final state = _state(api);
    addTearDown(state.dispose);

    expect(await state.createChannel('comm_1', 'general'), isNotNull);
    expect(state.lastChannelSkippedMembers, 2);
    // The channel is made and opened all the same.
    expect(state.selectedConversationId, 'conv_1');

    api.skipped = 0;
    expect(await state.createChannel('comm_1', 'random'), isNotNull);
    expect(state.lastChannelSkippedMembers, 0);

    api.skipped = 3;
    await state.createChannel('comm_1', 'news');
    api.skipped = null;
    expect(await state.createChannel('comm_1', 'broken'), isNull);
    expect(state.lastChannelSkippedMembers, 0,
        reason: 'a failed create left nobody out');
  });

  Widget app(Widget home) => MaterialApp(
        theme: veritraLightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      );

  Future<void> createFromMenu(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(app(CommunityScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New channel'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'general');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
  }

  testWidgets('the admin is told how many members were left out',
      (tester) async {
    final api = _Api()..skipped = 2;
    final state = _state(api);
    addTearDown(state.dispose);

    await createFromMenu(tester, state);

    expect(
        find.text('2 members were not added: they are in too many chats. '
            "Add them later from the channel's members."),
        findsOneWidget);
    expect(state.channelsByCommunity['comm_1'], hasLength(1));
  });

  testWidgets('one member left out reads in the singular', (tester) async {
    final api = _Api()..skipped = 1;
    final state = _state(api);
    addTearDown(state.dispose);

    await createFromMenu(tester, state);

    expect(
        find.text('1 member was not added: they are in too many chats. '
            "Add them later from the channel's members."),
        findsOneWidget);
  });

  testWidgets('nobody left out shows no note', (tester) async {
    final api = _Api();
    final state = _state(api);
    addTearDown(state.dispose);

    await createFromMenu(tester, state);

    expect(find.textContaining('were not added'), findsNothing);
    expect(find.textContaining('was not added'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });
}
