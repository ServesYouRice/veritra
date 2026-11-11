import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/community_info_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

// C3 send and receive against real OpenMLS devices: an info payload goes out
// unfranked and hidden, the sender keeps its own copy (MLS never decrypts a
// device's own message), and a receiver keeps it only in a community
// conversation.

class _Kinds implements ConversationAuthority {
  _Kinds(this.kind);
  String? kind;
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
}

final _channel = 'chan_${'2' * 32}';
final _key = List<int>.generate(32, (i) => i + 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();

  for (final lostResponse in [false, true]) {
    test(
        'app delivers a private info key after merging its accepted add '
        '(lost response: $lostResponse)', () async {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
      final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
      bob.service.conversationAuthority = _Kinds('community_channel');
      const conversation = 'conv_private_add';
      final community = 'comm_${'1' * 32}';
      final keyId = ProfileRecordCodec.keyId(_key);
      final codec = CommunityInfoCodec(bindings);
      final blob = codec.seal(
          key: _key,
          record: CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: _channel,
            revision: 1,
            name: 'Private name',
            topic: 'Private topic',
            privatePlace: const InfoPrivatePlace(position: 0),
          ));
      await alice.store.recordOwnCommunityInfoEvents([
        CommunityInfoEvent(
          kind: CommunityInfoEventKind.key,
          subjectKind: infoKindChannel,
          subjectId: _channel,
          conversationId: conversation,
          senderAccountId: alice.accountId,
          senderDeviceId: alice.deviceId,
          keyId: keyId,
          key: _key,
        )
      ]);
      await alice.store.saveAcceptedCommunityInfo(AcceptedCommunityInfo(
        subjectKind: infoKindChannel,
        subjectId: _channel,
        revision: 1,
        keyId: keyId,
        blob: blob,
      ));
      await alice.service
          .initializeConversation(conversation, [await bob.keyPackage()]);
      final queued = (await alice.store.pendingMlsMessages()).single;
      await alice.store.saveSession(_session(alice.accountId, alice.deviceId));
      final api = _AddApi(alice, bob, community, conversation, queued)
        ..lostResponse = lostResponse;
      final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: alice.service,
        localStore: alice.store,
        syncServiceFactory: (_, __) => _SilentSync(),
      )
        ..communities = api.communityList
        ..channelsByCommunity = {community: api.channelList}
        ..conversations = api.conversationList
        ..debugInfoRoleSource = _AddRoles(alice.accountId, bob.accountId);
      addTearDown(state.dispose);
      addTearDown(bob.service.dispose);
      await state.tryRestoreSession();
      if (lostResponse) {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (api.accepted == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(api.accepted, isNotNull);
        state.handleAppLifecycleState(AppLifecycleState.resumed);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while ((await bob.store.loadCommunityInfoEvents(
                  CommunityInfoEventKind.update, infoKindChannel, _channel))
              .isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final keys = await bob.store.loadCommunityInfoEvents(
          CommunityInfoEventKind.key, infoKindChannel, _channel);
      final updates = await bob.store.loadCommunityInfoEvents(
          CommunityInfoEventKind.update, infoKindChannel, _channel);
      expect(keys, isNotEmpty,
          reason: 'epoch=${await alice.service.groupEpoch(conversation)}, '
              'pending=${(await alice.store.pendingMlsMessages()).length}, '
              'queued=${(await alice.store.pendingEnvelopes()).length}, '
              'session=${state.session != null}, error=${state.errorFor(Ops.communityInfo)}');
      expect(keys.single.key, _key);
      expect(
          updates.single.recordSha256, CommunityInfoCodec.recordSha256(blob));
      expect(
          api.sentTypes, [AppPayloadType.infoKey, AppPayloadType.infoUpdate]);
      expect(
          codec
              .open(
                  key: keys.single.key!,
                  servedKeyId: keyId,
                  servedVersion: 1,
                  kind: infoKindChannel,
                  subjectId: _channel,
                  blob: blob)
              .name,
          'Private name');
      expect(
          await bob.store.loadCommunityInfoEvents(
              CommunityInfoEventKind.keyRequest, infoKindChannel, _channel),
          isEmpty);
    }, skip: skip);
  }

  test('info announcements and requests survive the native MLS send path',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_info');
    bob.service.conversationAuthority = _Kinds('community_channel');

    for (final (type, kind, body) in [
      (
        AppPayloadType.infoUpdate,
        CommunityInfoEventKind.update,
        infoUpdateBody(
            subjectKind: 'channel',
            subjectId: _channel,
            revision: 7,
            keyId: 'a' * 32,
            recordSha256: 'b' * 64),
      ),
      (
        AppPayloadType.infoKeyRequest,
        CommunityInfoEventKind.keyRequest,
        infoKeyRequestBody(subjectKind: 'channel', subjectId: _channel),
      ),
    ]) {
      final sent = await alice.service.encryptPayload('conv_info', type, body);
      expect(sent.frankCommit, isNull);
      await bob.service.processApplicationMessage(
          bob.envelopeFrom(alice, sent), bob.nextEvent());
      for (final client in [alice, bob]) {
        final event = (await client.store
                .loadCommunityInfoEvents(kind, 'channel', _channel))
            .single;
        expect(event.conversationId, 'conv_info');
        expect(event.senderAccountId, 'acct_alice');
        if (kind == CommunityInfoEventKind.update) {
          expect(event.revision, 7);
          expect(event.recordSha256, 'b' * 64);
        }
      }
    }
    final rows = await bob.store.loadMessages('conv_info');
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.kind, 'action');
      expect(row.senderHidden, isTrue);
      expect(row.body, isNull);
      expect(await bob.store.loadFrankReveal(row.key), isNull);
    }
  }, skip: skip);

  test('an info key goes out unfranked and hidden, and both sides keep it',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_p');
    final kinds = _Kinds('community_channel');
    bob.service.conversationAuthority = kinds;

    final body =
        infoKeyBody(subjectKind: 'channel', subjectId: _channel, key: _key);
    final sent = await alice.service
        .encryptPayload('conv_p', AppPayloadType.infoKey, body);
    // Never franked: a report could otherwise hand the key to its reader.
    expect(sent.frankCommit, isNull);
    // The sender's own copy: a hidden action row and the key itself.
    final own = await alice.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', _channel);
    expect(own.single.key, _key);
    expect(own.single.conversationId, 'conv_p');
    expect(own.single.senderAccountId, 'acct_alice');
    final row = (await alice.store.loadMessages('conv_p')).single;
    expect(row.kind, 'action');
    expect(row.senderHidden, isTrue);
    expect(row.body, isNull);
    // An info payload never carries an expiry.
    await expectLater(
        alice.service.encryptExpiringPayload(
            'conv_p', AppPayloadType.infoKey, body,
            expiresAt: DateTime.now().add(const Duration(hours: 1))),
        throwsArgumentError);

    // Bob, in a community conversation, keeps it with no reveal.
    await alice.store.removePendingEnvelope(sent.idempotencyKey);
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, sent), bob.nextEvent());
    final got = await bob.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', _channel);
    expect(got.single.key, _key);
    expect(got.single.senderAccountId, 'acct_alice');
    final bobRow = (await bob.store.loadMessages('conv_p')).single;
    expect(bobRow.kind, 'action');
    expect(await bob.store.loadFrankReveal(bobRow.key), isNull);

    // The same payload in a conversation that is not a community's is
    // consumed and kept nowhere.
    kinds.kind = 'group';
    final again = await alice.service.encryptPayload(
        'conv_p',
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel',
            subjectId: _channel,
            key: List<int>.filled(32, 9)));
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, again), bob.nextEvent());
    expect(
        await bob.store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, 'channel', _channel),
        hasLength(1));
  }, skip: skip);
}

int _serverIds = 0;

class _SilentSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _AddRoles implements VerifiedRoleSource {
  _AddRoles(String owner, String member)
      : roles = GovernanceState(
            rev: 1, owner: owner, ownerRev: 1, joined: {owner: 0, member: 1});
  final GovernanceState roles;
  @override
  GovernanceState? governanceOf(String conversationId) => roles;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

class _AddApi extends ApiClient {
  _AddApi(this.alice, this.bob, this.community, this.conversation, this.queued)
      : super(baseUrl: 'https://localhost:8443');
  final _Client alice;
  final _Client bob;
  final String community;
  final String conversation;
  final PendingMlsMessage queued;
  bool lostResponse = false;
  MlsMessage? accepted;
  final sentTypes = <AppPayloadType>[];
  List<Community> get communityList => [
        Community(
            id: community, name: '', sharedConversationId: 'conv_shared_unused')
      ];
  List<Channel> get channelList => [
        Channel(
            id: _channel,
            name: '',
            communityId: community,
            kind: 'private',
            layoutGeneration: 1,
            conversationId: conversation)
      ];
  List<Conversation> get conversationList => [
        Conversation(
            id: conversation,
            kind: 'community_channel',
            communityId: community,
            createdBy: alice.accountId)
      ];
  @override
  Future<List<Conversation>> conversations(String token) async =>
      conversationList;
  @override
  Future<List<Community>> listCommunities(String token) async => communityList;
  @override
  Future<List<Channel>> listChannels(String token, String communityId) async =>
      channelList;
  @override
  Future<List<ConversationMember>> communityMembers(
          String token, String communityId) async =>
      [
        ConversationMember(accountId: alice.accountId, role: 'owner'),
        ConversationMember(accountId: bob.accountId, role: 'member')
      ];
  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      communityMembers(token, community);
  @override
  Future<List<Device>> devices(String token) async => [];
  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async => [];
  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async => [];
  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      !lostResponse || accepted == null || after >= 1
          ? []
          : [
              SyncEvent(
                  id: 1,
                  type: 'mls.message.created',
                  conversationId: conversation,
                  createdAt: DateTime.now().toUtc(),
                  payload: {'mls_message_id': accepted!.id})
            ];
  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async =>
      accepted!;
  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      {'enabled': false};
  @override
  Future<List<({String kind, String id, int version, String keyId})>>
      infoVersions(String token,
              {List<String> communityIds = const [],
              List<String> categoryIds = const [],
              List<String> channelIds = const []}) async =>
          [];
  @override
  Future<int> sendMlsCommitBundle(String token, String conversationId,
      {required String idempotencyKey, required MlsCommitBundle bundle}) async {
    expect((await alice.service.groupEpoch(conversation))!.pending, isTrue);
    expect(sentTypes, isEmpty);
    await bob.service.processMlsMessage(MlsMessage(
      id: 'mls_add_welcome',
      conversationId: conversation,
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${queued.idempotencyKey}:welcome:${bob.deviceId}',
      syncEventId: bob.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: bob.deviceId,
    ));
    accepted = MlsMessage(
        id: 'mls_accepted_add',
        conversationId: conversation,
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        kind: 'commit',
        payload: bundle.commit,
        idempotencyKey: idempotencyKey,
        syncEventId: 1,
        createdAt: DateTime.now().toUtc());
    if (lostResponse) throw const SocketException('lost bundle response');
    return bundle.epoch + 1;
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    expect((await alice.service.groupEpoch(conversation))!.pending, isFalse);
    expect(await alice.store.pendingMlsMessages(), isEmpty);
    final plaintext = await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, envelope), bob.nextEvent());
    // Info actions are consumed by the receiver and kept as hidden rows.
    expect(plaintext, isNull);
    final keys = await bob.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, infoKindChannel, _channel);
    final updates = await bob.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.update, infoKindChannel, _channel);
    sentTypes.add(updates.isEmpty && keys.isNotEmpty
        ? AppPayloadType.infoKey
        : AppPayloadType.infoUpdate);
  }
}

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

Future<void> _start(_Client alice, _Client bob, String conversationId) async {
  await alice.service.initializeConversation(
      conversationId, <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: conversationId,
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: bundle.welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId, this.events);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service =
        TestNativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, local, accountId, deviceId, 0);
  }

  /// A new service over the same store, as after an app restart.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    await service.dispose();
    final next = TestNativeCryptoService(bindings: bindings, localStore: store);
    await next.activateSession(_session(accountId, deviceId));
    return _Client(next, store, accountId, deviceId, events);
  }

  int nextEvent() => ++events;

  Future<int> epoch(String conversationId) async =>
      (await service.groupEpoch(conversationId))!.epoch;

  /// Stages a self-update commit and merges it, as after the server accepts
  /// it. Returns the accepted outbox item, so its commit can be delivered.
  Future<PendingMlsMessage> selfUpdate(String conversationId) async {
    await service.stageSelfUpdate(conversationId);
    final item = (await store.pendingMlsMessages())
        .singleWhere((pending) => pending.conversationId == conversationId);
    await service.completeCommitBundle(item);
    return item;
  }

  /// The sync event that delivers [payload], a copy of [item]'s commit, from
  /// [from] to this device.
  MlsMessage commitFrom(
      _Client from, PendingMlsMessage item, int eventId, List<int> payload) {
    return MlsMessage(
      id: 'mls_${item.conversationId}',
      conversationId: item.conversationId,
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: payload,
      idempotencyKey: item.idempotencyKey,
      syncEventId: eventId,
      createdAt: DateTime.now().toUtc(),
    );
  }

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<MessageEnvelope> send(String conversationId, String text) async {
    final envelope = await service.encryptPayload(
        conversationId, AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        frankCommit: sent.frankCommit,
        createdAt: DateTime.now().toUtc(),
      );
}
