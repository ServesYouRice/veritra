// Message loading in AppState: what may be fetched or marked read, and the
// history cursor across refreshes.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

ReceivedMessageEnvelope _message(String id, int minute,
        {String conversationId = 'conv'}) =>
    ReceivedMessageEnvelope.fromJson(<String, Object?>{
      'id': id,
      'conversation_id': conversationId,
      'sender_account_id': 'acct_peer',
      'sender_device_id': 'dev_peer',
      'idempotency_key': id,
      'ciphertext': '',
      'crypto_protocol': 'test',
      'created_at': DateTime.utc(2026, 6, 2, 12, minute).toIso8601String(),
    });

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  /// Pages served for a conversation, keyed by the `before` cursor (null
  /// for the newest page).
  final Map<String?, MessagePage> pages = <String?, MessagePage>{};
  final List<String?> pageRequests = <String?>[];
  final List<String> pageConversations = <String>[];
  final List<String> receiptReads = <String>[];
  final List<String> reads = <String>[];
  final List<String> privateReads = <String>[];
  Completer<void>? pageGate;

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    pageConversations.add(conversationId);
    pageRequests.add(before);
    final gate = pageGate;
    if (gate != null) {
      pageGate = null;
      await gate.future;
    }
    return pages[before] ??
        const MessagePage(messages: <ReceivedMessageEnvelope>[]);
  }

  @override
  Future<List<MemberReceipt>> listReceipts(
      String token, String conversationId) async {
    receiptReads.add(conversationId);
    return const <MemberReceipt>[];
  }

  @override
  Future<void> markRead(String token, String conversationId, String id) async {
    reads.add(conversationId);
  }

  @override
  Future<void> markReadPrivate(
      String token, String conversationId, String id) async {
    privateReads.add(conversationId);
  }
}

class _FakeSync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}

AppState _state(
  _Api api, {
  List<Conversation>? conversations,
  ReceiptPreferences? receiptPreferences,
}) =>
    AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSync(),
      receiptPreferences: receiptPreferences,
    )
      ..api = api
      ..session = _session
      ..conversations = conversations ??
          <Conversation>[
            Conversation(
                id: 'conv',
                kind: 'group',
                createdBy: 'acct_me',
                unreadCount: 2),
            Conversation(id: 'other', kind: 'group', createdBy: 'acct_me'),
          ];

/// Holds the saved read-receipts choice until [gate] completes.
class _GatedPreferenceStore implements ReceiptPreferenceStore {
  final Completer<void> gate = Completer<void>();

  @override
  Future<bool?> load() async {
    await gate.future;
    return true;
  }

  @override
  Future<void> save(bool sendReadReceipts) async {}
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('C-c20d1ce84e57: an unknown conversation is held back', () {
    test('selecting it fetches nothing and sends no receipt', () async {
      final api = _Api()
        ..pages[null] = MessagePage(messages: <ReceivedMessageEnvelope>[
          _message('m1', 1, conversationId: 'unknown')
        ]);
      final state = _state(api);
      state.selectConversation('unknown');
      await _settle();
      expect(api.pageConversations, isEmpty);
      expect(api.receiptReads, isEmpty);
      expect(api.reads, isEmpty);
      expect(api.privateReads, isEmpty);
      state.dispose();
    });

    test('markNewestMessageRead sends nothing for it', () async {
      final api = _Api();
      final state = _state(api);
      state.messagesByConversation['unknown'] = <ReceivedMessageEnvelope>[
        _message('m1', 1, conversationId: 'unknown'),
      ];
      await state.markNewestMessageRead('unknown');
      expect(api.reads, isEmpty);
      expect(api.privateReads, isEmpty);
      state.dispose();
    });

    test('a known open conversation still loads and is marked read', () async {
      final api = _Api()
        ..pages[null] =
            MessagePage(messages: <ReceivedMessageEnvelope>[_message('m1', 1)]);
      final state = _state(api);
      state.selectConversation('conv');
      await _settle();
      expect(api.pageConversations, <String>['conv']);
      expect(api.receiptReads, <String>['conv']);
      expect(api.reads, <String>['conv']);
      state.dispose();
    });
  });

  group('TASK-040: a newest-page refresh and the history cursor', () {
    MessagePage page(List<int> ids, String? nextBefore) => MessagePage(
          messages: <ReceivedMessageEnvelope>[
            for (final id in ids) _message('m$id', id),
          ],
          nextBefore: nextBefore,
        );

    _Api history() => _Api()
      ..pages[null] = page(<int>[6, 5], 'c5')
      ..pages['c5'] = page(<int>[4, 3], 'c3')
      ..pages['c3'] = page(<int>[2, 1], null);

    test('an exhausted history stays exhausted after an overlapping refresh',
        () async {
      final api = history();
      final state = _state(api);
      await state.loadMessages('conv');
      await state.loadOlderMessages('conv');
      await state.loadOlderMessages('conv');
      expect(api.pageRequests, <String?>[null, 'c5', 'c3']);

      api.pages[null] = page(<int>[7, 6], 'c6');
      await state.loadMessages('conv');
      expect(state.messagesFor('conv').map((m) => m.id),
          <String>['m7', 'm6', 'm5', 'm4', 'm3', 'm2', 'm1']);
      await state.loadOlderMessages('conv');
      expect(api.pageRequests, <String?>[null, 'c5', 'c3', null],
          reason: 'already-loaded history was fetched again');
      state.dispose();
    });

    test('an overlapping refresh keeps the deeper cursor', () async {
      final api = history();
      final state = _state(api);
      await state.loadMessages('conv');
      await state.loadOlderMessages('conv');

      api.pages[null] = page(<int>[7, 6], 'c6');
      await state.loadMessages('conv');
      await state.loadOlderMessages('conv');
      expect(api.pageRequests.last, 'c3');
      expect(state.messagesFor('conv').map((m) => m.id),
          <String>['m7', 'm6', 'm5', 'm4', 'm3', 'm2', 'm1']);
      state.dispose();
    });

    test('a refresh with a gap rewinds to the fresh page cursor', () async {
      final api = history();
      final state = _state(api);
      await state.loadMessages('conv');
      await state.loadOlderMessages('conv');

      api.pages[null] = page(<int>[9, 8], 'c8');
      await state.loadMessages('conv');
      await state.loadOlderMessages('conv');
      expect(api.pageRequests.last, 'c8');
      state.dispose();
    });
  });

  group('TASK-041: a load that lands after the user moved on', () {
    int unread(AppState state) =>
        state.conversations.firstWhere((c) => c.id == 'conv').unreadCount;

    test('sends no receipt once another conversation is selected', () async {
      final api = _Api()
        ..pages[null] =
            MessagePage(messages: <ReceivedMessageEnvelope>[_message('m1', 1)])
        ..pageGate = Completer<void>();
      final gate = api.pageGate!;
      final state = _state(api);
      state.selectConversation('conv');
      await _settle();
      state.selectConversation('other');
      await _settle();
      gate.complete();
      await _settle();
      expect(api.reads, isNot(contains('conv')));
      expect(api.privateReads, isNot(contains('conv')));
      expect(unread(state), 2);
      expect(state.messagesFor('conv'), hasLength(1),
          reason: 'the load itself still lands');
      state.dispose();
    });

    test('sends no receipt once the app is in the background', () async {
      final api = _Api()
        ..pages[null] =
            MessagePage(messages: <ReceivedMessageEnvelope>[_message('m1', 1)])
        ..pageGate = Completer<void>();
      final gate = api.pageGate!;
      final state = _state(api);
      state.selectConversation('conv');
      await _settle();
      state.handleAppLifecycleState(AppLifecycleState.paused);
      gate.complete();
      await _settle();
      expect(api.reads, isEmpty);
      expect(api.privateReads, isEmpty);
      expect(unread(state), 2);
      state.dispose();
    });

    test('sends no receipt if the app is backgrounded while the choice loads',
        () async {
      final store = _GatedPreferenceStore();
      final api = _Api();
      final state = _state(api, receiptPreferences: ReceiptPreferences(store))
        ..messagesByConversation['conv'] = <ReceivedMessageEnvelope>[
          _message('m1', 1),
        ];
      final read = state.markNewestMessageRead('conv');
      await _settle();
      state.handleAppLifecycleState(AppLifecycleState.paused);
      store.gate.complete();
      await read;
      expect(api.reads, isEmpty);
      expect(api.privateReads, isEmpty);
      expect(unread(state), 2);
      state.dispose();
    });

    test('a load for the selected, visible conversation still marks it read',
        () async {
      final api = _Api()
        ..pages[null] =
            MessagePage(messages: <ReceivedMessageEnvelope>[_message('m1', 1)])
        ..pageGate = Completer<void>();
      final gate = api.pageGate!;
      final state = _state(api);
      state.selectConversation('conv');
      await _settle();
      gate.complete();
      await _settle();
      expect(api.reads, <String>['conv']);
      expect(unread(state), 0);
      state.dispose();
    });
  });
}
