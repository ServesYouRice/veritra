// C3 (D115): when a removal leaves a private channel's key due for renewal
// and no owner or admin is in the channel, the channel says so. Moderators
// never renew it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/l10n/app_localizations_en.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const <ConversationMember>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      ConversationMute(muted: false);

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<void> markRead(
      String token, String conversationId, String messageId) async {}
}

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('a channel with no admin to renew its key shows a notice',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_mod',
        deviceId: 'dev_mod',
        username: 'mod',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_private', kind: 'community_channel'),
      ];
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(state: state, conversationId: 'conv_private'),
    ));
    await tester.pumpAndSettle();
    final notice = AppLocalizationsEn().chatKeyRenewalNoAdmin;
    expect(find.text(notice), findsNothing);

    state.debugKeyRenewalStuck({'conv_private'});
    await tester.pumpAndSettle();
    expect(find.text(notice), findsOneWidget);

    state.debugKeyRenewalStuck({});
    await tester.pumpAndSettle();
    expect(find.text(notice), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });
}
