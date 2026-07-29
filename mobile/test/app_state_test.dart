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

  test('device link parses transcript metadata without a server SAS', () {
    final link = DeviceLink.fromJson(<String, Object?>{
      'id': 'dlink_1',
      'state': 'pending',
      'expires_at': '2026-05-29T12:00:00Z',
      'code': 'PAIRCODE',
      'link_uri': 'veritra://device-link?code=PAIRCODE',
      'protocol_version': 'veritra-device-link-v1',
      'link_nonce': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
    });
    expect(link.code, 'PAIRCODE');
    expect(link.verificationCode, isEmpty);
    expect(link.linkNonce, hasLength(32));
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

  test('crypto state and cursor commit together and reject rollback', () async {
    final store = MemoryLocalStore();
    final first = StoredCryptoState(
      counter: 4,
      stateKey: List<int>.filled(32, 7),
      sealedState: <int>[1, 2, 3],
    );
    await store.saveCryptoState(first, 91);

    final restored = await store.loadCryptoState();
    expect(restored?.counter, 4);
    expect(await store.loadSyncCursor(), 91);
    await expectLater(
      store.saveCryptoState(
        StoredCryptoState(
          counter: 4,
          stateKey: List<int>.filled(32, 8),
          sealedState: <int>[4],
        ),
        92,
      ),
      throwsStateError,
    );
    expect(await store.loadSyncCursor(), 91);
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

  test('device link rejects a server-substituted transcript', () async {
    final api = FakeDeviceLinkApiClient(transcriptByte: 8);
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
    await state.refreshActiveDeviceLink();
    expect(state.error, contains('substituted'));
    expect(state.activeDeviceLink?.verificationCode, isNot('654321'));
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
    expect(state.outboxState(key), OutboxDeliveryState.retrying);
    expect((await localStore.pendingEnvelopes()).single.idempotencyKey, key);

    api.failSend = false;
    await state.retryEnvelope(key);

    expect(api.sentKeys, <String>[key, key]);
    expect(state.pendingFor('conv_1'), isEmpty);
    expect(await localStore.pendingEnvelopes(), isEmpty);
  });

  test('sync repairs an old edited envelope by id without newest-page reload',
      () async {
    final localStore = MemoryLocalStore();
    final conversation = Conversation(id: 'conv_1', kind: 'group');
    final newest = ReceivedMessageEnvelope(
      id: 'msg_newest',
      conversationId: conversation.id,
      senderAccountId: 'acct_owner',
      senderDeviceId: 'dev_owner',
      idempotencyKey: 'idem_newest',
      ciphertext: <int>[1],
      cryptoProtocol: 'mls-openmls-todo',
      createdAt: DateTime.parse('2026-05-29T12:01:00Z'),
    );
    await localStore.saveSession(const Session(
      baseUrl: 'http://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    ));
    await localStore.saveSnapshot(
      <Conversation>[conversation],
      <String, List<ReceivedMessageEnvelope>>{
        conversation.id: <ReceivedMessageEnvelope>[newest],
      },
      0,
    );
    final api = _RepairApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )..selectedConversationId = conversation.id;

    await state.tryRestoreSession();
    await api.repairFetched.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);

    expect(api.listMessagesCalls, 0);
    expect(state.messagesFor(conversation.id).map((message) => message.id),
        <String>['msg_newest', 'msg_old']);
    final repaired = state
        .messagesFor(conversation.id)
        .singleWhere((message) => message.id == 'msg_old');
    expect(repaired.ciphertext, <int>[9, 9]);
    expect(repaired.editedAt, isNotNull);
    expect(await localStore.loadSyncCursor(), 7);
    state.dispose();
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
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
}

class FakeDeviceLinkApiClient extends ApiClient {
  FakeDeviceLinkApiClient({this.transcriptByte = 7})
      : super(baseUrl: 'http://localhost:8080');

  final int transcriptByte;

  @override
  Future<DeviceLink> createDeviceLink(String token) async {
    return _link(state: 'pending', code: 'PAIRCODE');
  }

  @override
  Future<DeviceLink> deviceLink(String token, String linkId) async {
    return _link(state: 'claimed', claimedDeviceName: 'linked tablet');
  }

  @override
  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(String code) async {
    return const EnrollmentReservation(
      id: 'dlink_1',
      accountId: 'acct_owner',
      deviceId: 'dev_linked',
      challenge: <int>[1, 2, 3],
      protocolVersion: 'veritra-device-link-v1',
      linkNonce: <int>[
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
      ],
      existingDeviceId: 'dev_owner',
      existingSigningKey: <int>[
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
      ],
    );
  }

  @override
  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    required DeviceLinkVerification verification,
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
    List<int> transcriptHash,
  ) async {
    if (transcriptHash.length != 32 || transcriptHash.first != 7) {
      throw StateError('verification mismatch');
    }
    return _link(
      state: 'approved',
      code: 'PAIRCODE',
      approvedDeviceId: 'dev_linked',
    );
  }

  @override
  Future<Session?> completeDeviceLinkClaim(String linkId, String claimToken,
      List<int> expectedTranscriptHash) async {
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
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    return MessagePage(messages: <ReceivedMessageEnvelope>[
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
    ]);
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
      verificationCode: state == 'pending' ? '' : '654321',
      expiresAt: DateTime.parse('2026-05-29T12:00:00Z'),
      code: code,
      linkUri: code == null ? null : 'veritra://device-link?code=$code',
      claimedDeviceName: claimedDeviceName,
      approvedDeviceId: approvedDeviceId,
      accountId: 'acct_owner',
      createdByDeviceId: 'dev_owner',
      protocolVersion: 'veritra-device-link-v1',
      linkNonce: List<int>.filled(32, 1),
      existingSigningKey: List<int>.filled(32, 2),
      claimedDeviceId: state == 'pending' ? null : 'dev_linked',
      claimedSigningKey: state == 'pending' ? null : List<int>.filled(32, 9),
      transcriptHash:
          state == 'pending' ? null : List<int>.filled(32, transcriptByte),
    );
  }
}

class _RepairApiClient extends FakeDeviceLinkApiClient {
  final Completer<void> repairFetched = Completer<void>();
  int listMessagesCalls = 0;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    if (after >= 7) {
      return <SyncEvent>[];
    }
    return <SyncEvent>[
      SyncEvent(
        id: 7,
        type: 'message.envelope.edited',
        conversationId: 'conv_1',
        payload: <String, Object?>{
          'message_id': 'msg_old',
          'conversation_id': 'conv_1',
        },
        createdAt: DateTime.parse('2026-05-29T12:02:00Z'),
      ),
    ];
  }

  @override
  Future<ReceivedMessageEnvelope> message(
    String token,
    String messageId,
  ) async {
    if (!repairFetched.isCompleted) {
      repairFetched.complete();
    }
    return ReceivedMessageEnvelope(
      id: messageId,
      conversationId: 'conv_1',
      senderAccountId: 'acct_owner',
      senderDeviceId: 'dev_owner',
      idempotencyKey: 'idem_old',
      ciphertext: <int>[9, 9],
      cryptoProtocol: 'mls-openmls-todo',
      createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      editedAt: DateTime.parse('2026-05-29T12:02:00Z'),
    );
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    listMessagesCalls++;
    return const MessagePage(messages: <ReceivedMessageEnvelope>[]);
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
