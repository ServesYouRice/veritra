// Message-request state that cannot be read or decoded fails closed
// (TASK-033): nothing is grandfathered, nothing stored is overwritten, and
// a later good read restores the stored decisions.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _setting = 'message_requests';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

Conversation _dm(String id, String peer, {DateTime? lastMessageAt}) =>
    Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      createdBy: peer,
      createdAt: DateTime.utc(2026, 6, 1),
      lastMessageAt: lastMessageAt,
    );

Conversation _group(String id, String createdBy) => Conversation(
      id: id,
      kind: 'group',
      title: id,
      createdBy: createdBy,
      createdAt: DateTime.utc(2026, 6, 1),
    );

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list = <Conversation>[];

  @override
  Future<List<Conversation>> conversations(String token) async => list;

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];
}

/// Fails reads of the request setting while [failReads] is above zero and
/// records every write of it.
class _FaultyStore extends MemoryLocalStore {
  int failReads = 0;
  final List<String> writes = <String>[];

  @override
  Future<String?> loadSetting(String name) async {
    if (name == _setting && failReads > 0) {
      failReads--;
      throw StateError('keystore locked');
    }
    return super.loadSetting(name);
  }

  @override
  Future<void> saveSetting(String name, String value) async {
    if (name == _setting) writes.add(value);
    return super.saveSetting(name, value);
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

AppState _state(_Api api, LocalStore store) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _FakeSync(),
    );

RequestBucket _bucket(AppState state, String id) =>
    state.requestBucket(state.conversations.firstWhere((c) => c.id == id));

String _stored({
  List<String> accepted = const <String>[],
  List<String> groups = const <String>[],
  Map<String, String> declined = const <String, String>{},
}) =>
    jsonEncode(<String, Object?>{
      'account': 'acct_me',
      'accepted': accepted,
      'groups': groups,
      'declined': declined,
    });

/// A device with a cached snapshot, so a restore takes the upgrade path
/// (grandfather: true) when the stored value is missing.
Future<_FaultyStore> _upgradedStore(List<Conversation> cached) async {
  final store = _FaultyStore();
  await store.saveSession(_session);
  await store.saveSnapshot(
      cached, <String, List<ReceivedMessageEnvelope>>{}, 0);
  return store;
}

void main() {
  final stranger = _dm('stranger', 'acct_stranger');
  final friend = _dm('friend', 'acct_friend');
  final strangerGroup = _group('sgroup', 'acct_stranger');

  test(
      'VAL-044: a read error on restore grandfathers nothing and writes '
      'nothing', () async {
    final store = await _upgradedStore(<Conversation>[stranger, strangerGroup]);
    await store.saveSetting(_setting, _stored(accepted: ['acct_friend']));
    store.writes.clear();
    store.failReads = 2;
    final api = _Api()..list = <Conversation>[stranger, strangerGroup, friend];
    final state = _state(api, store);
    await state.tryRestoreSession();

    expect(state.requestStateLoaded, isTrue,
        reason: 'the list must still show, with requests held back');
    expect(_bucket(state, 'stranger'), RequestBucket.request);
    expect(_bucket(state, 'sgroup'), RequestBucket.request);
    expect(_bucket(state, 'friend'), RequestBucket.request);
    expect(store.writes, isEmpty);
    expect(
        await store.loadSetting(_setting), _stored(accepted: ['acct_friend']));

    // The next refresh reads the value and applies it as stored.
    await state.refreshConversations();
    expect(_bucket(state, 'friend'), RequestBucket.chat);
    expect(_bucket(state, 'stranger'), RequestBucket.request);
    expect(_bucket(state, 'sgroup'), RequestBucket.request);
    expect(store.writes, isEmpty);
    state.dispose();
  });

  test(
      'VAL-045: an undecodable value is neither grandfathered nor '
      'overwritten', () async {
    for (final raw in <String>['{not json', '[1,2]', '"text"']) {
      final store =
          await _upgradedStore(<Conversation>[stranger, strangerGroup]);
      await store.saveSetting(_setting, raw);
      store.writes.clear();
      final api = _Api()..list = <Conversation>[stranger, strangerGroup];
      final state = _state(api, store);
      await state.tryRestoreSession();
      await state.refreshConversations();

      expect(_bucket(state, 'stranger'), RequestBucket.request, reason: raw);
      expect(_bucket(state, 'sgroup'), RequestBucket.request, reason: raw);
      expect(store.writes, isEmpty, reason: raw);
      expect(await store.loadSetting(_setting), raw);
      state.dispose();
    }
  });

  test('VAL-046: stored declines survive a read error', () async {
    final declinedAt = DateTime.utc(2026, 6, 3);
    final declinedDm =
        _dm('declined', 'acct_spam', lastMessageAt: DateTime.utc(2026, 6, 2));
    final stored =
        _stored(declined: {'declined': declinedAt.toIso8601String()});
    final store = await _upgradedStore(<Conversation>[declinedDm]);
    await store.saveSetting(_setting, stored);
    store.writes.clear();
    store.failReads = 2;
    final api = _Api()..list = <Conversation>[declinedDm];
    final state = _state(api, store);
    await state.tryRestoreSession();
    expect(store.writes, isEmpty);
    expect(await store.loadSetting(_setting), stored);

    await state.refreshConversations();
    expect(_bucket(state, 'declined'), RequestBucket.hidden);
    expect(await store.loadSetting(_setting), stored);
    state.dispose();
  });

  test(
      'a failed upgrade read that later finds no value still grandfathers '
      'the cached chats', () async {
    final store = await _upgradedStore(<Conversation>[friend, strangerGroup]);
    store.failReads = 2;
    final api = _Api()..list = <Conversation>[friend, strangerGroup, stranger];
    final state = _state(api, store);
    await state.tryRestoreSession();
    expect(_bucket(state, 'friend'), RequestBucket.request);

    await state.refreshConversations();
    expect(_bucket(state, 'friend'), RequestBucket.chat);
    expect(_bucket(state, 'sgroup'), RequestBucket.chat);
    expect(_bucket(state, 'stranger'), RequestBucket.request,
        reason: 'only what the cached snapshot held is grandfathered');
    state.dispose();
  });

  test('decisions made during a read error merge into the stored value',
      () async {
    final declinedAt = DateTime.utc(2026, 6, 3);
    final other = _dm('other', 'acct_other');
    final store = await _upgradedStore(<Conversation>[]);
    await store.saveSetting(
        _setting,
        _stored(
            accepted: ['acct_friend'],
            declined: {'stranger': declinedAt.toIso8601String()}));
    store.writes.clear();
    store.failReads = 2;
    final api = _Api()..list = <Conversation>[stranger, friend, other];
    final state = _state(api, store);
    await state.tryRestoreSession();
    expect(_bucket(state, 'stranger'), RequestBucket.request);

    expect(await state.acceptMessageRequest('stranger'), isTrue);
    expect(await state.deleteMessageRequest('other'), isTrue);
    expect(_bucket(state, 'stranger'), RequestBucket.chat);
    expect(store.writes, isEmpty, reason: 'wrote over an unread value');

    await state.refreshConversations();
    expect(_bucket(state, 'stranger'), RequestBucket.chat);
    expect(_bucket(state, 'friend'), RequestBucket.chat);
    expect(_bucket(state, 'other'), RequestBucket.hidden);
    final saved = jsonDecode((await store.loadSetting(_setting))!)
        as Map<String, Object?>;
    expect(saved['accepted'], <String>['acct_friend', 'acct_stranger']);
    expect((saved['declined'] as Map).keys, <String>['other']);
    state.dispose();
  });

  test('an explicit decision replaces an undecodable value', () async {
    final store = await _upgradedStore(<Conversation>[]);
    await store.saveSetting(_setting, '{not json');
    final api = _Api()..list = <Conversation>[stranger, friend];
    final state = _state(api, store);
    await state.tryRestoreSession();
    expect(await state.acceptMessageRequest('stranger'), isTrue);
    final saved = jsonDecode((await store.loadSetting(_setting))!)
        as Map<String, Object?>;
    expect(saved['accepted'], <String>['acct_stranger']);
    expect(_bucket(state, 'friend'), RequestBucket.request);
    state.dispose();
  });

  test('an absent value keeps the first-run behaviour', () async {
    final store = _FaultyStore();
    final api = _Api()..list = <Conversation>[stranger];
    final state = _state(api, store)
      ..api = api
      ..session = _session;
    await state.refreshConversations();
    expect(_bucket(state, 'stranger'), RequestBucket.request);
    expect(store.writes, hasLength(1));
    state.dispose();
  });
}
