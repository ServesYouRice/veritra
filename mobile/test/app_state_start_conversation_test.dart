// TASK-054: startConversation and a DM the server already had.

import 'dart:async';

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

/// Records group creation; [groups] are the groups this device already has.
class _Mls implements MlsConversationCryptoService {
  final Set<String> groups = <String>{};
  final List<String> initialized = <String>[];

  @override
  Future<void> initializeConversation(
      String conversationId, List<DeviceKeyPackage> claimedPackages) async {
    initialized.add(conversationId);
    groups.add(conversationId);
  }

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      groups.contains(conversationId) ? (epoch: 1, pending: false) : null;

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

Conversation _dm(String createdBy, {String? peer = 'acct_peer'}) =>
    Conversation(
      id: 'dm_1',
      kind: 'dm',
      peerAccountId: peer,
      createdBy: createdBy,
      createdAt: DateTime.utc(2026, 6, 1),
    );

ReceivedMessageEnvelope _message(String id) =>
    ReceivedMessageEnvelope.fromJson(<String, Object?>{
      'id': id,
      'conversation_id': 'dm_1',
      'sender_account_id': 'acct_peer',
      'sender_device_id': 'dev_peer',
      'idempotency_key': id,
      'ciphertext': '',
      'crypto_protocol': 'test',
      'created_at': '2026-06-02T12:00:00Z',
    });

Future<(AppState, _Api, _Mls)> _start() async {
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
  // Request state loaded (a fresh device: nothing accepted yet).
  await state.refreshConversations();
  return (state, api, mls);
}

void main() {
  test('a DM the peer created makes no new group and is accepted', () async {
    final (state, api, mls) = await _start();
    addTearDown(state.dispose);
    api.created = _dm('acct_peer');

    final result = await state
        .startConversation(kind: 'dm', memberAccountIds: <String>['acct_peer']);

    expect(result?.id, 'dm_1');
    expect(api.claims, isEmpty, reason: 'claimed key packages again');
    expect(mls.initialized, isEmpty, reason: 'made a second MLS group');
    expect(state.conversations.where((c) => c.id == 'dm_1'), hasLength(1));
    expect(state.selectedConversationId, 'dm_1');
    expect(state.isMessageRequestId('dm_1'), isFalse);
  });

  test('a returned DM already listed is not added twice and keeps messages',
      () async {
    final (state, api, mls) = await _start();
    addTearDown(state.dispose);
    // Listed without its peer, so the local reuse check missed it.
    state.conversations = <Conversation>[_dm('acct_peer', peer: null)];
    state.messagesByConversation['dm_1'] = <ReceivedMessageEnvelope>[
      _message('m1'),
    ];
    api.created = _dm('acct_peer');

    await state
        .startConversation(kind: 'dm', memberAccountIds: <String>['acct_peer']);

    expect(state.conversations.where((c) => c.id == 'dm_1'), hasLength(1));
    expect(state.conversations.single.peerAccountId, 'acct_peer');
    expect(state.messagesFor('dm_1').map((m) => m.id), <String>['m1']);
    expect(mls.initialized, isEmpty);
  });

  test('an own DM whose group this device has is not set up again', () async {
    final (state, api, mls) = await _start();
    addTearDown(state.dispose);
    mls.groups.add('dm_1');
    api.created = _dm('acct_me');

    await state
        .startConversation(kind: 'dm', memberAccountIds: <String>['acct_peer']);

    expect(api.claims, isEmpty);
    expect(mls.initialized, isEmpty);
  });

  test('a new DM still gets its group', () async {
    final (state, api, mls) = await _start();
    addTearDown(state.dispose);
    api.created = _dm('acct_me');

    await state
        .startConversation(kind: 'dm', memberAccountIds: <String>['acct_peer']);

    expect(api.claims, <String>['dm_1']);
    expect(mls.initialized, <String>['dm_1']);
    expect(state.selectedConversationId, 'dm_1');
  });
}
