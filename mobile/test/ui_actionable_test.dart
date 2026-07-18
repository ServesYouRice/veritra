import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  test('conversation parses activity ordering and unread metadata', () {
    final conversation = Conversation.fromJson(<String, Object?>{
      'id': 'conv_1',
      'kind': 'dm',
      'created_at': '2026-06-01T10:00:00Z',
      'last_message_at': '2026-06-02T12:30:00Z',
      'unread_count': 4,
    });
    expect(conversation.unreadCount, 4);
    expect(conversation.lastMessageAt, isNotNull);
    // lastActivityAt prefers the last message time over creation.
    expect(conversation.lastActivityAt, conversation.lastMessageAt);
  });

  test('conversation defaults unread to zero and falls back to createdAt', () {
    final conversation = Conversation.fromJson(<String, Object?>{
      'id': 'conv_1',
      'kind': 'dm',
      'created_at': '2026-06-01T10:00:00Z',
    });
    expect(conversation.unreadCount, 0);
    expect(conversation.lastMessageAt, isNull);
    expect(conversation.lastActivityAt, conversation.createdAt);
  });

  test('copyWith updates unread while preserving other fields', () {
    final conversation = Conversation(
      id: 'conv_1',
      kind: 'group',
      title: 'Family',
      unreadCount: 5,
    );
    final cleared = conversation.copyWith(unreadCount: 0);
    expect(cleared.unreadCount, 0);
    expect(cleared.title, 'Family');
    expect(cleared.kind, 'group');
    expect(cleared.id, 'conv_1');
  });

  test('parseDeviceLinkCode extracts the code from a link URI', () {
    expect(
      parseDeviceLinkCode('veritra://device-link?code=ABCD1234'),
      'ABCD1234',
    );
  });

  test('parseDeviceLinkCode falls back to the raw scan for a bare code', () {
    expect(parseDeviceLinkCode('  BARECODE  '), 'BARECODE');
  });

  test('markNewestMessageRead clears the unread badge locally', () async {
    final api = _ReadApiClient();
    final state = _connectedState(api);
    state.conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'dm', unreadCount: 3),
      Conversation(id: 'conv_2', kind: 'dm', unreadCount: 2),
    ];
    state.messagesByConversation['conv_1'] = <ReceivedMessageEnvelope>[
      _message('m_newest'),
    ];

    await state.markNewestMessageRead('conv_1');

    expect(state.conversations[0].unreadCount, 0);
    // Untouched conversations keep their badge.
    expect(state.conversations[1].unreadCount, 2);
    expect(api.lastReadMessageId, 'm_newest');
  });

  test('per-list loaded flags flip after refresh and reset on logout',
      () async {
    final api = _ReadApiClient();
    final state = _connectedState(api);
    expect(state.communitiesLoaded, isFalse);
    expect(state.invitesLoaded, isFalse);
    expect(state.devicesLoaded, isFalse);

    await state.refreshCommunities();
    await state.refreshInvites();
    await state.refreshDevices();
    expect(state.communitiesLoaded, isTrue);
    expect(state.invitesLoaded, isTrue);
    expect(state.devicesLoaded, isTrue);

    await state.logout();
    expect(state.communitiesLoaded, isFalse);
    expect(state.invitesLoaded, isFalse);
    expect(state.devicesLoaded, isFalse);
  });
}

ReceivedMessageEnvelope _message(String id) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': 'conv_1',
    'sender_account_id': 'acct_other',
    'sender_device_id': 'dev_other',
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': '2026-06-02T12:30:00Z',
  });
}

AppState _connectedState(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'http://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    );
}

class _ReadApiClient extends ApiClient {
  _ReadApiClient() : super(baseUrl: 'http://localhost:8080');

  String? lastReadMessageId;

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {
    lastReadMessageId = messageId;
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    return <Community>[];
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    return <Invite>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[];
  }

  @override
  Future<void> logout(String token) async {}
}

class _FakeSyncService implements SyncService {
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
