// D67 (TASK-054 Q-004): the server answers 200 for a DM the pair already
// had and 201 for a new one; the app never builds a second MLS group for an
// existing DM.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  late Conversation created;
  final List<String> claims = <String>[];

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async =>
      created;

  @override
  Future<List<DeviceKeyPackage>> claimConversationKeyPackages(
      String token, String conversationId) async {
    claims.add(conversationId);
    return const <DeviceKeyPackage>[];
  }
}

class _Mls implements MlsConversationCryptoService {
  final List<String> initialized = <String>[];

  @override
  Future<void> initializeConversation(
      String conversationId, List<DeviceKeyPackage> claimedPackages) async {
    initialized.add(conversationId);
  }

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      null;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

Map<String, Object?> _dmJson() => <String, Object?>{
      'id': 'dm_1',
      'kind': 'dm',
      'created_by': 'acct_me',
      'created_at': '2026-06-01T00:00:00Z',
    };

Future<Conversation> _createAgainst(int status) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    await utf8.decodeStream(request);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(_dmJson()));
    await request.response.close();
  });
  final client =
      ApiClient(baseUrl: 'http://${server.address.address}:${server.port}');
  addTearDown(client.close);
  return client.createConversationDetailed('token',
      kind: 'dm', memberAccountIds: <String>['acct_peer']);
}

void main() {
  test('a 201 is a new conversation', () async {
    final conversation = await _createAgainst(HttpStatus.created);
    expect(conversation.id, 'dm_1');
    expect(conversation.existedOnServer, isFalse);
  });

  test('a 200 is a DM the server already had', () async {
    final conversation = await _createAgainst(HttpStatus.ok);
    expect(conversation.id, 'dm_1');
    expect(conversation.existedOnServer, isTrue);
    // Never stored or sent: it describes one answer only.
    expect(conversation.toJson().containsKey('existed_on_server'), isFalse);
  });

  test(
      'an own DM the server already had, without a group on this device, '
      'waits for its Welcome instead of building a second group', () async {
    final api = _Api();
    final mls = _Mls();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: mls,
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = _session;
    addTearDown(state.dispose);
    await state.refreshConversations();
    // Made earlier by another of this account's devices.
    api.created = Conversation(
      id: 'dm_1',
      kind: 'dm',
      peerAccountId: 'acct_peer',
      createdBy: 'acct_me',
      createdAt: DateTime.utc(2026, 6, 1),
      existedOnServer: true,
    );

    final result = await state
        .startConversation(kind: 'dm', memberAccountIds: <String>['acct_peer']);

    expect(result?.id, 'dm_1');
    expect(api.claims, isEmpty, reason: 'claimed key packages again');
    expect(mls.initialized, isEmpty, reason: 'made a second MLS group');
    expect(state.selectedConversationId, 'dm_1');
    expect(state.conversations.where((c) => c.id == 'dm_1'), hasLength(1));
  });
}
