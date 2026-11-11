import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/profile_service.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// W11 wiring: what AppState does with profiles when a group is made, an
/// account is blocked, a group is left, a sync event arrives or a post goes
/// out. The service itself is covered in `w11_profile_service_test.dart`.
const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

class _NoBindings implements NativeCryptoBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unused');
}

/// Records what AppState asks of the service.
class _Recording extends ProfileService {
  _Recording()
      : super(
          store: MemoryLocalStore(),
          codec: ProfileRecordCodec(_NoBindings()),
          api: _NoApi(),
          accountId: 'acct_me',
          sendKey: (_, __, ___) async => true,
          postableConversationIds: () => const [],
          coMemberAccountIds: () => null,
        );

  final List<String> calls = <String>[];
  Map<String, Object?> sidecarMap = <String, Object?>{};
  bool sidecarsThrow = false;

  @override
  Future<void> saveGroupProfile(String conversationId,
      {String? name, ProfilePhoto? photo}) async {
    calls.add('saveGroup:$conversationId:$name');
  }

  @override
  Future<void> forgetAccount(String id) async => calls.add('forgetAccount:$id');

  @override
  Future<void> forgetConversation(String id) async =>
      calls.add('forgetConversation:$id');

  @override
  Future<void> markOwnRotationDue() async => calls.add('ownDue');

  @override
  Future<void> markGroupRotationDue(String conversationId) async =>
      calls.add('groupDue:$conversationId');

  @override
  Future<void> markGroupKeyForSidecar(String conversationId) async =>
      calls.add('sidecarFlag:$conversationId');

  @override
  Future<void> onProfileUpdated(Object? payload) async =>
      calls.add('updated:$payload');

  @override
  Future<Map<String, Object?>> sidecars(String conversationId) async {
    if (sidecarsThrow) throw StateError('store unreadable');
    return sidecarMap;
  }
}

class _NoApi implements ProfileApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unused');
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  String? sentTitle = 'unset';
  final List<String> blocked = <String>[];
  List<BlockedAccount> remoteBlocks = [];

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async => remoteBlocks;

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
  }) async {
    sentTitle = title;
    return Conversation(
      id: 'conv_new',
      kind: kind,
      title: title,
      createdBy: 'acct_me',
      peerAccountId: kind == 'dm' && memberAccountIds.isNotEmpty
          ? memberAccountIds.first
          : null,
    );
  }

  @override
  Future<List<DeviceKeyPackage>> claimConversationKeyPackages(
          String token, String conversationId) async =>
      const <DeviceKeyPackage>[];

  @override
  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    blocked.add(accountId);
    return BlockedAccount(accountId: accountId);
  }

  @override
  Future<int?> removeConversationMember(
          String token, String conversationId, String accountId) async =>
      null;
}

class _Mls implements MlsConversationCryptoService {
  @override
  Future<void> initializeConversation(
      String conversationId, List<DeviceKeyPackage> claimedPackages) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: 1, pending: false);

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Capture the final payload at the expiry encryption boundary.
class _ExpiringMls extends _Mls implements ExpiringPayloadCryptoService {
  Map<String, Object?>? encryptedBody;
  DateTime? expiry;

  @override
  Future<MessageEnvelope> encryptExpiringPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {required DateTime expiresAt,
      String? channelId,
      int? layoutGeneration,
      List<String> attachmentRefs = const [],
      String? draftText}) async {
    encryptedBody = body;
    expiry = expiresAt;
    throw StateError('stop after capturing encryption input');
  }
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

Future<(AppState, _Api, _Recording?)> _start(
    {bool profiles = true, bool mls = true}) async {
  final api = _Api();
  final recording = profiles ? _Recording() : null;
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: mls ? _Mls() : TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _IdleSync(),
  )
    ..api = api
    ..session = _session
    ..profiles = recording;
  await state.refreshConversations();
  return (state, api, recording);
}

SyncEvent _event(String type, {String? conversationId, Object? payload}) =>
    SyncEvent(
      id: 1,
      type: type,
      createdAt: DateTime.utc(2026),
      conversationId: conversationId,
      payload: payload,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('a new group', () {
    test('its name goes into the encrypted profile, not the server title',
        () async {
      final (state, api, profiles) = await _start();
      await state.startConversation(kind: 'group', title: '  Walkers  ');
      await Future<void>.delayed(Duration.zero);
      expect(api.sentTitle, isNull);
      expect(profiles!.calls, ['saveGroup:conv_new:Walkers']);
    });

    test('without profiles the title still goes to the server', () async {
      final (state, api, _) = await _start(profiles: false);
      await state.startConversation(kind: 'group', title: 'Walkers');
      expect(api.sentTitle, 'Walkers');
    });

    test('a group with no name sends none and makes no profile', () async {
      final (state, api, profiles) = await _start();
      await state.startConversation(kind: 'group');
      await state.startConversation(kind: 'group', title: '   ');
      await Future<void>.delayed(Duration.zero);
      expect(api.sentTitle, '   ');
      expect(profiles!.calls, isEmpty);
    });

    test('a DM never gets a profile', () async {
      final (state, api, profiles) = await _start();
      await state.startConversation(
          kind: 'dm', memberAccountIds: <String>['acct_peer'], title: 'x');
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, isEmpty);
      expect(api.sentTitle, 'x');
    });
  });

  group('blocking and leaving', () {
    test('blocking forgets the account and makes a rotation due', () async {
      final (state, api, profiles) = await _start();
      expect(await state.blockAccount('acct_bob'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(api.blocked, ['acct_bob']);
      expect(profiles!.calls, ['forgetAccount:acct_bob', 'ownDue']);
    });

    test('a block discovered on another device marks rotation due once',
        () async {
      final (state, api, profiles) = await _start();
      api.remoteBlocks = [BlockedAccount(accountId: 'acct_bob')];
      await state.refreshBlocks();
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, ['forgetAccount:acct_bob', 'ownDue']);
      profiles.calls.clear();
      await state.refreshBlocks();
      await Future<void>.delayed(Duration.zero);
      expect(profiles.calls, isEmpty);
      state.dispose();
    });

    test('a refused block changes nothing', () async {
      final (state, _, profiles) = await _start();
      state.api = _FailingBlock();
      expect(await state.blockAccount('acct_bob'), isFalse);
      expect(profiles!.calls, isEmpty);
    });

    test('leaving a group forgets its profile', () async {
      final (state, _, profiles) = await _start(mls: false);
      state.conversations = <Conversation>[
        Conversation(id: 'conv_g', kind: 'group')
      ];
      expect(await state.leaveConversation('conv_g'), isTrue);
      expect(profiles!.calls, contains('forgetConversation:conv_g'));
    });

    test('blocking with no profile service is unchanged', () async {
      final (state, _, _) = await _start(profiles: false);
      expect(await state.blockAccount('acct_bob'), isTrue);
    });
  });

  group('sync events', () {
    test('profile.updated reaches the service', () async {
      final (state, _, profiles) = await _start();
      final payload = {
        'subject_kind': 'account',
        'subject_id': 'acct_bob',
        'version': 3,
        'key_id': 'x',
      };
      state.debugProfileSyncEvent(_event('profile.updated', payload: payload));
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, ['updated:$payload']);
    });

    test('a removal marks the group rotation due', () async {
      final (state, _, profiles) = await _start();
      state.debugProfileSyncEvent(
          _event('membership.removed', conversationId: 'conv_g'));
      state.debugProfileSyncEvent(
          _event('membership.left', conversationId: 'conv_g'));
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, ['groupDue:conv_g', 'groupDue:conv_g']);
    });

    test('other roster events flag the next post to carry the group key',
        () async {
      final (state, _, profiles) = await _start();
      state.debugProfileSyncEvent(
          _event('conversation.updated', conversationId: 'conv_g'));
      state.debugProfileSyncEvent(
          _event('membership.updated', conversationId: 'conv_g'));
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, ['sidecarFlag:conv_g', 'sidecarFlag:conv_g']);
    });

    test('unrelated events and events with no conversation do nothing',
        () async {
      final (state, _, profiles) = await _start();
      state.debugProfileSyncEvent(
          _event('reaction.created', conversationId: 'conv_g'));
      state.debugProfileSyncEvent(_event('membership.removed'));
      state.debugProfileSyncEvent(_event('conversation.updated'));
      await Future<void>.delayed(Duration.zero);
      expect(profiles!.calls, isEmpty);
    });

    test('with no profile service every event is ignored', () async {
      final (state, _, _) = await _start(profiles: false);
      state.debugProfileSyncEvent(_event('profile.updated', payload: {}));
    });
  });

  test('disappearing messages include profile sidecars at encryption',
      () async {
    final api = _Api();
    final crypto = _ExpiringMls();
    final profiles = _Recording()
      ..sidecarMap = {
        'profile_key': {'key': 'k', 'key_id': 'i', 'version': 1}
      };
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = _session
      ..profiles = profiles;
    await state.refreshConversations();
    state.conversations = [
      Conversation(
          id: 'conv_g',
          kind: 'group',
          createdBy: 'acct_me',
          retentionSeconds: 60)
    ];
    await state.sendMessageTo('conv_g', 'hello');
    expect(crypto.encryptedBody, {
      'text': 'hello',
      ...profiles.sidecarMap,
    });
    expect(crypto.expiry, isNotNull);
    state.dispose();
  });

  group('sidecars on a post', () {
    final key = {'key': 'k', 'key_id': 'i', 'version': 1};

    test('a text, reply, manifest and poll carry them', () async {
      final (state, _, profiles) = await _start();
      profiles!.sidecarMap = {'profile_key': key};
      for (final type in [
        AppPayloadType.text,
        AppPayloadType.reply,
        AppPayloadType.attachmentManifest,
        AppPayloadType.poll,
      ]) {
        final out =
            await state.debugWithProfileSidecars('conv_g', type, {'a': 1});
        expect(out, {'a': 1, 'profile_key': key}, reason: type.name);
      }
    });

    test('other types, and a post with nothing to add, are left as they are',
        () async {
      final (state, _, profiles) = await _start();
      profiles!.sidecarMap = {'profile_key': key};
      final body = {'message_id': 'm', 'reaction': '+'};
      expect(
          identical(
              await state.debugWithProfileSidecars(
                  'conv_g', AppPayloadType.reaction, body),
              body),
          isTrue);
      profiles.sidecarMap = {};
      final text = {'text': 'hi'};
      expect(
          identical(
              await state.debugWithProfileSidecars(
                  'conv_g', AppPayloadType.text, text),
              text),
          isTrue);
    });

    test('a very long text gets no room-eating key', () async {
      final (state, _, profiles) = await _start();
      profiles!.sidecarMap = {'profile_key': key};
      final long = {'text': 'x' * 9000};
      expect(
          identical(
              await state.debugWithProfileSidecars(
                  'conv_g', AppPayloadType.text, long),
              long),
          isTrue);
    });

    test('an unreadable store never stops the post', () async {
      final (state, _, profiles) = await _start();
      profiles!.sidecarsThrow = true;
      final text = {'text': 'hi'};
      expect(
          await state.debugWithProfileSidecars(
              'conv_g', AppPayloadType.text, text),
          text);
    });

    test('with no profile service a post is untouched', () async {
      final (state, _, _) = await _start(profiles: false);
      final text = {'text': 'hi'};
      expect(
          identical(
              await state.debugWithProfileSidecars(
                  'conv_g', AppPayloadType.text, text),
              text),
          isTrue);
    });
  });

  group('a key never goes to a blocked or unread chat (S8)', () {
    final key = {'key': 'k', 'key_id': 'i', 'version': 1};

    Future<(AppState, _Recording)> dm() async {
      final (state, _, profiles) = await _start();
      profiles!.sidecarMap = {'profile_key': key};
      await state.startConversation(
          kind: 'dm', memberAccountIds: <String>['acct_peer']);
      return (state, profiles);
    }

    test('an accepted DM with blocks not yet loaded gets none', () async {
      final (state, _) = await dm();
      state.blocksLoaded = false;
      final text = {'text': 'hi'};
      expect(
          await state.debugWithProfileSidecars(
              'conv_new', AppPayloadType.text, text),
          text);
    });

    test('an accepted DM with an unblocked peer gets the key', () async {
      final (state, _) = await dm();
      state.blocksLoaded = true;
      expect(
          await state.debugWithProfileSidecars(
              'conv_new', AppPayloadType.text, {'text': 'hi'}),
          {'text': 'hi', 'profile_key': key});
    });

    test('an accepted DM whose peer was blocked later gets none', () async {
      final (state, _) = await dm();
      state.blocksLoaded = true;
      state.blockedAccounts = <BlockedAccount>[
        BlockedAccount(accountId: 'acct_peer')
      ];
      final text = {'text': 'hi'};
      expect(
          await state.debugWithProfileSidecars(
              'conv_new', AppPayloadType.text, text),
          text);
    });
  });

  test('a profile write does not wait on the session queue', () async {
    // The write sends key messages through the send queue; if it ran inside
    // the session queue it would wait on itself.
    final (state, _, _) = await _start(profiles: false);
    state.profiles = _WritesThroughQueue(state);
    expect(
        await state
            .saveOwnProfile(name: 'x')
            .timeout(const Duration(seconds: 5)),
        isTrue);
  });

  test('co-members are unknown until the list came from the server', () async {
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: _Mls(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'dm', peerAccountId: 'acct_peer')
      ];
    expect(state.debugCoMemberAccounts(), isNull);
    await state.refreshConversations();
    expect(state.debugCoMemberAccounts(), isEmpty);
  });

  test('the editors are offered only when profiles exist', () async {
    final (enabled, _, _) = await _start();
    final (without, _, _) = await _start(profiles: false);
    expect(enabled.profilesAvailable, isTrue);
    expect(without.profilesAvailable, isFalse);
    expect(without.profileNameOf('acct_bob'), isNull);
    expect(without.groupProfileName('conv_g'), isNull);
    expect(without.profilePhotoOf('acct_bob'), isNull);
    expect(await without.saveOwnProfile(name: 'x'), isFalse);
    expect(await without.saveGroupProfile('conv_g', name: 'x'), isFalse);
  });

  test('profile reads come from the service', () async {
    final store = MemoryLocalStore();
    await store.saveProfile(StoredProfile(
        kind: 'account',
        subjectId: 'acct_bob',
        serverVersion: 1,
        keyId: '0' * 32,
        revision: 1,
        name: 'Bobby',
        photoPng: Uint8List.fromList([1]),
        fetchedAt: 1));
    await store.saveProfile(StoredProfile(
        kind: 'conversation',
        subjectId: 'conv_g',
        serverVersion: 1,
        keyId: '0' * 32,
        revision: 1,
        name: 'Walkers',
        fetchedAt: 1));
    final service = ProfileService(
      store: store,
      codec: ProfileRecordCodec(_NoBindings()),
      api: _NoApi(),
      accountId: 'acct_me',
      sendKey: (_, __, ___) async => true,
      postableConversationIds: () => const [],
      coMemberAccountIds: () => null,
    );
    await service.load();
    final (state, _, _) = await _start(profiles: false);
    state.profiles = service;
    expect(state.profileNameOf('acct_bob'), 'Bobby');
    expect(state.profilePhotoOf('acct_bob'), isNotNull);
    expect(state.groupProfileName('conv_g'), 'Walkers');
    expect(state.groupProfilePhoto('conv_g'), isNull);
  });
}

class _FailingBlock extends _Api {
  @override
  Future<BlockedAccount> blockAccount(String token, String accountId) async =>
      throw ApiException(503, 'unavailable');
}

/// A service whose write needs the session queue, as a key message does.
class _WritesThroughQueue extends _Recording {
  _WritesThroughQueue(this.state);
  final AppState state;

  @override
  Future<void> saveOwnProfile({String? name, ProfilePhoto? photo}) async {
    await state.blockAccount('acct_other');
  }
}
