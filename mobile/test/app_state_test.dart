import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  test('message envelope serializes ciphertext without plaintext body field',
      () {
    final envelope = MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: 'key_1',
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'mls-openmls-todo',
    );
    final json = envelope.toJson();
    expect(json.containsKey('ciphertext'), isTrue);
    expect(json.containsKey('body'), isFalse);
    expect(json.containsKey('text'), isFalse);
  });

  test('metadata search result parses non-message metadata only', () {
    final result = MetadataSearchResult.fromJson(<String, Object?>{
      'type': 'community',
      'id': 'comm_1',
      'label': 'Family',
    });
    expect(result.type, 'community');
    expect(result.label, 'Family');
  });

  test('device link parses QR verification metadata', () {
    final link = DeviceLink.fromJson(<String, Object?>{
      'id': 'dlink_1',
      'state': 'pending',
      'verification_code': '123456',
      'expires_at': '2026-05-29T12:00:00Z',
      'code': 'PAIRCODE',
      'link_uri': 'veritra://device-link?code=PAIRCODE',
    });
    expect(link.code, 'PAIRCODE');
    expect(link.verificationCode, '123456');
  });

  test('app state can store session through local abstraction', () async {
    final localStore = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );
    await localStore.saveSession(
        const Session(baseUrl: 'http://localhost:8080', token: 'token'));
    expect((await state.localStore.loadSession())?.token, 'token');
  });

  test('app state drives device link claim through approval', () async {
    final localStore = MemoryLocalStore();
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.claimDeviceLink('http://localhost:8080', 'PAIRCODE');
    expect(state.pendingDeviceLinkClaim?.deviceLink.verificationCode, '654321');
    expect(state.session, isNull);

    await state.completeDeviceLinkClaim();
    expect(state.session?.token, 'linked-token');
    expect((await localStore.loadSession())?.token, 'linked-token');
  });

  test('app state can create and approve a device link', () async {
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'http://localhost:8080',
        token: 'owner-token',
      );

    await state.createDeviceLink();
    expect(state.activeDeviceLink?.code, 'PAIRCODE');

    await state.refreshActiveDeviceLink();
    expect(state.activeDeviceLink?.claimedDeviceName, 'linked tablet');
    expect(state.activeDeviceLink?.code, 'PAIRCODE');

    await state.approveActiveDeviceLink('654321');
    expect(state.activeDeviceLink?.state, 'approved');
    expect(state.activeDeviceLink?.approvedDeviceId, 'dev_linked');
  });

  test('app state refreshes encrypted messages for selected conversation',
      () async {
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'http://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    state.selectConversation('conv_1');
    await Future<void>.delayed(Duration.zero);

    expect(state.selectedMessages, hasLength(1));
    expect(state.selectedMessages.first.ciphertext, <int>[1, 2, 3]);
  });

  test('logout preserves local device identity for password sign-in', () async {
    final localStore = MemoryLocalStore();
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'http://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );

    await localStore.saveSession(state.session!);
    await state.logout();

    expect(state.session, isNull);
    final stored = await localStore.loadSession();
    expect(stored?.token, '');
    expect(stored?.deviceId, 'dev_owner');
  });

  test('failed encrypted envelope persists and retry reuses its key', () async {
    final localStore = MemoryLocalStore();
    final api = _OutboxApiClient()..failSend = true;
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'http://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    await state.sendMessageTo('conv_1', 'test-only plaintext');

    expect(state.pendingFor('conv_1'), hasLength(1));
    final key = state.pendingFor('conv_1').single.idempotencyKey;
    expect(state.outboxState(key), OutboxDeliveryState.failed);
    expect((await localStore.pendingEnvelopes()).single.idempotencyKey, key);

    api.failSend = false;
    await state.retryEnvelope(key);

    expect(api.sentKeys, <String>[key, key]);
    expect(state.pendingFor('conv_1'), isEmpty);
    expect(await localStore.pendingEnvelopes(), isEmpty);
  });
}

class _OutboxApiClient extends ApiClient {
  _OutboxApiClient() : super(baseUrl: 'http://localhost:8080');

  bool failSend = false;
  final List<String> sentKeys = <String>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sentKeys.add(envelope.idempotencyKey);
    if (failSend) {
      throw ApiException(503, 'unavailable');
    }
  }

  @override
  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async =>
      <ReceivedMessageEnvelope>[];
}

class FakeDeviceLinkApiClient extends ApiClient {
  FakeDeviceLinkApiClient() : super(baseUrl: 'http://localhost:8080');

  @override
  Future<DeviceLink> createDeviceLink(String token) async {
    return _link(state: 'pending', code: 'PAIRCODE');
  }

  @override
  Future<DeviceLink> deviceLink(String token, String linkId) async {
    return _link(state: 'claimed', claimedDeviceName: 'linked tablet');
  }

  @override
  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required List<int> deviceKeyPackage,
    List<int> signingKey = const <int>[],
  }) async {
    return DeviceLinkClaim(
      deviceLink: _link(state: 'claimed'),
      claimToken: 'claim-token',
      deviceSecret: 'device-secret',
    );
  }

  @override
  Future<DeviceLink> approveDeviceLink(
    String token,
    String linkId,
    String verificationCode,
  ) async {
    if (verificationCode != '654321') {
      throw StateError('verification mismatch');
    }
    return _link(
      state: 'approved',
      code: 'PAIRCODE',
      approvedDeviceId: 'dev_linked',
    );
  }

  @override
  Future<Session?> completeDeviceLinkClaim(
      String linkId, String claimToken) async {
    return const Session(
      baseUrl: 'http://localhost:8080',
      token: 'linked-token',
      accountId: 'acct_owner',
      deviceId: 'dev_linked',
    );
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    return <Conversation>[];
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    return <Invite>[];
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    return <Community>[];
  }

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async {
    return <Channel>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[
      Device(
        id: 'dev_linked',
        accountId: 'acct_owner',
        name: 'linked tablet',
        createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      ),
    ];
  }

  @override
  Future<void> logout(String token) async {}

  @override
  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    return <ReceivedMessageEnvelope>[
      ReceivedMessageEnvelope(
        id: 'msg_1',
        conversationId: conversationId,
        senderAccountId: 'acct_owner',
        senderDeviceId: 'dev_owner',
        idempotencyKey: 'idem_1',
        ciphertext: <int>[1, 2, 3],
        cryptoProtocol: 'mls-openmls-todo',
        createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      ),
    ];
  }

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return <SyncEvent>[];
  }

  DeviceLink _link({
    required String state,
    String? code,
    String? approvedDeviceId,
    String? claimedDeviceName,
  }) {
    return DeviceLink(
      id: 'dlink_1',
      state: state,
      verificationCode: '654321',
      expiresAt: DateTime.parse('2026-05-29T12:00:00Z'),
      code: code,
      linkUri: code == null ? null : 'veritra://device-link?code=$code',
      claimedDeviceName: claimedDeviceName,
      approvedDeviceId: approvedDeviceId,
    );
  }
}

class FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() {
    _controller.close();
  }
}
