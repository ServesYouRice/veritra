import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/create_channel_dialog.dart';
import 'package:private_messenger/features/communities/edit_info_dialog.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

// Owner answer 2026-11-12, "Stronger warning": full-history posts are
// signed, so they can be proven to be their author's. Turning full history
// on asks first and says so; the setting carries a short line saying it.

const _proof = "Posts can be proven to be their author's";

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
  @override
  Future<List<ConversationMember>> communityMembers(
          String token, String id) async =>
      [ConversationMember(accountId: 'alice', role: 'owner')];
}

class _State extends AppState {
  _State() : this.withApi(_Api());
  _State.withApi(_Api client)
      : super(
          apiClientFactory: (_) => client,
          syncServiceFactory: (_, __) => _Sync(),
          localStore: MemoryLocalStore(),
          cryptoService: UnavailableCryptoService(),
        ) {
    api = client;
    session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'device');
  }

  bool full = false;
  final changes = <bool>[];
  bool? createdFull;

  @override
  bool get channelHistoryAvailable => true;

  @override
  Future<C7ChannelView?> channelHistory(Channel channel) async =>
      C7ChannelView(full: full, status: 'ok', pending: false);

  @override
  Future<bool> setChannelHistory(Channel channel, {required bool full}) async {
    changes.add(full);
    this.full = full;
    return true;
  }

  @override
  Future<Channel?> createChannel(String communityId, String name,
      {String? kind, bool fullHistory = false}) async {
    createdFull = fullHistory;
    return Channel(
        id: 'channel',
        communityId: communityId,
        name: '',
        kind: kind!,
        conversationId: 'shared',
        layoutGeneration: 1);
  }
}

final _channel = Channel(
    id: 'channel',
    communityId: 'community',
    name: '',
    kind: 'open',
    conversationId: 'shared',
    layoutGeneration: 1);

Future<void> _pump(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: body),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'turning full history on warns that posts can be proven to be the '
      "author's; cancelling changes nothing", (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _pump(tester, ChannelHistorySetting(state: state, channel: _channel));
    expect(find.text(_proof), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('can be proven to be its author'), findsOneWidget);
    expect(find.textContaining('Authors cannot deny their posts.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(state.changes, isEmpty);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(state.changes, [true]);
    // Turning it off has no proof warning.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authors cannot deny'), findsNothing);
    expect(find.textContaining("won't see earlier posts"), findsOneWidget);
  });

  testWidgets(
      'a new channel with full history asks first, and the warning line is on '
      'the switch', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _pump(
        tester,
        CreateChannelDialog(
            state: state,
            community: Community(
                id: 'community', name: '', sharedConversationId: 'shared')));
    expect(find.text(_proof), findsOneWidget);
    final history = find.widgetWithText(
        SwitchListTile, 'People who join later can read earlier posts');
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.textContaining('Authors cannot deny their posts.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(history).value, isFalse);
    await tester.tap(history);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(history).value, isTrue);
    await tester.enterText(find.byType(TextField), 'general');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(state.createdFull, isTrue);
  });
}
