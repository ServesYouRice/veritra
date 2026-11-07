import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _owner = Session(
    baseUrl: 'https://example.test',
    token: 'token',
    accountId: 'alice',
    deviceId: 'dev');
const _elsewhere = Session(
    baseUrl: 'https://example.test',
    token: 'other-token',
    accountId: 'bob',
    deviceId: 'other');

Channel _channel(String id, String kind, {int generation = 1}) => Channel(
    id: id,
    communityId: 'comm',
    name: id,
    kind: kind,
    conversationId: kind == 'private' ? 'private_conv' : 'shared',
    layoutGeneration: generation);

AppState _state(_Mls crypto) {
  final state = AppState(
      apiClientFactory: (_) => _Api(),
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: MemoryLocalStore(),
      cryptoService: crypto);
  state.session = _owner;
  state.api = _Api();
  state.conversations = [
    Conversation(
        id: 'shared',
        kind: 'community_shared',
        communityId: 'comm',
        createdBy: 'alice'),
    Conversation(id: 'group', kind: 'group', createdBy: 'alice'),
  ];
  state.channelsByCommunity = {
    'comm': [
      _channel('chan_a', 'open'),
      _channel('chan_b', 'announcement'),
      _channel('chan_p', 'private'),
    ],
  };
  // Stop each send at the encrypt call: the test looks at what reached it.
  crypto.afterEncrypt = () => state.session = _elsewhere;
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('models', () {
    test('a community with the shared layout names its group', () {
      final shared = Community.fromJson(<String, Object?>{
        'id': 'comm',
        'name': 'Club',
        'layout_version': 1,
        'layout_generation': 1,
        'shared_conversation_id': 'conv_shared',
      });
      expect(shared.sharedConversationId, 'conv_shared');
      final legacy =
          Community.fromJson(<String, Object?>{'id': 'c', 'name': 'Old'});
      expect(legacy.sharedConversationId, isNull);
    });

    test('a routed channel carries its group and generation', () {
      final routed = Channel.fromJson(<String, Object?>{
        'id': 'chan',
        'community_id': 'comm',
        'name': 'general',
        'kind': 'open',
        'conversation_id': 'conv_shared',
        'layout_version': 1,
        'layout_generation': 2,
      });
      expect(routed.isRouted, isTrue);
      expect(routed.conversationId, 'conv_shared');
      expect(routed.layoutGeneration, 2);
      final legacy = Channel.fromJson(<String, Object?>{
        'id': 'chan',
        'community_id': 'comm',
        'name': 'general',
        'kind': 'private',
      });
      expect(legacy.isRouted, isFalse);
    });

    test('the shared group reads as a channel conversation', () {
      final shared =
          Conversation(id: 'c', kind: 'community_shared', createdBy: 'a');
      expect(shared.isCommunityShared, isTrue);
      expect(shared.isChannel, isTrue);
      final legacy =
          Conversation(id: 'c', kind: 'community_channel', createdBy: 'a');
      expect(legacy.isCommunityShared, isFalse);
      expect(legacy.isChannel, isTrue);
    });
  });

  group('sending into a shared group', () {
    test('nothing is sent until a channel is chosen', () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      expect(await state.sendMessageTo('shared', 'hello'), false);
      expect(crypto.routed, isEmpty);
      expect(crypto.plain, isEmpty);
    });

    test('a post names the chosen channel and the layout generation', () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      state.selectChannel('shared', 'chan_a');
      await state.sendMessageTo('shared', 'hello');
      expect(crypto.plain, isEmpty,
          reason: 'a shared group never uses the channel-less call');
      expect(crypto.routed, [('shared', 'chan_a', 1)]);
    });

    test('an announcement channel is posted to the same group', () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      state.channelsByCommunity = {
        'comm': [_channel('chan_b', 'announcement', generation: 3)]
      };
      state.selectChannel('shared', 'chan_b');
      await state.sendMessageTo('shared', 'news');
      expect(crypto.routed, [('shared', 'chan_b', 3)]);
    });

    test('a private or unknown channel is never posted to through the group',
        () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      for (final channel in ['chan_p', 'chan_missing']) {
        state.selectChannel('shared', channel);
        expect(await state.sendMessageTo('shared', 'hello'), false);
      }
      expect(crypto.routed, isEmpty);
      expect(crypto.plain, isEmpty);
    });

    test('leaving for another channel does not redirect a send already made',
        () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      state.selectChannel('shared', 'chan_a');
      final sent = state.sendMessageTo('shared', 'hello');
      state.selectChannel('shared', 'chan_b');
      await sent;
      expect(crypto.routed, [('shared', 'chan_a', 1)]);
    });

    test('other conversations keep the channel-less call', () async {
      final crypto = _Mls();
      final state = _state(crypto);
      addTearDown(state.dispose);
      await state.sendMessageTo('group', 'hello');
      expect(crypto.plain, ['group']);
      expect(crypto.routed, isEmpty);
    });
  });

  group('showing a channel', () {
    ReceivedMessageEnvelope post(String id, String? channel) =>
        ReceivedMessageEnvelope(
          id: id,
          conversationId: 'shared',
          senderAccountId: 'bob',
          senderDeviceId: 'other',
          idempotencyKey: id,
          ciphertext: const <int>[],
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 1, 1),
          cryptoMetadata: <String, Object?>{
            if (channel != null) 'channel_id': channel,
          },
        );

    test('the timeline lists only the selected channel', () {
      final state = _state(_Mls());
      addTearDown(state.dispose);
      state.messagesByConversation = {
        'shared': [post('m1', 'chan_a'), post('m2', 'chan_b'), post('m3', null)]
      };
      expect(state.timelineFor('shared').map((e) => e.id),
          unorderedEquals(['m1', 'm2', 'm3']));
      state.selectChannel('shared', 'chan_a');
      expect(state.timelineFor('shared').map((e) => e.id), ['m1']);
      state.selectChannel('shared', 'chan_b');
      expect(state.timelineFor('shared').map((e) => e.id), ['m2']);
    });

    test('a pending post shows only in its own channel', () {
      final state = _state(_Mls());
      addTearDown(state.dispose);
      MessageEnvelope pending(String key, String channel) => MessageEnvelope(
            conversationId: 'shared',
            idempotencyKey: key,
            ciphertext: const <int>[1],
            cryptoProtocol: 'mls10-openmls-v1',
            cryptoMetadata: <String, Object?>{'channel_id': channel},
          );
      state.pendingOutbox = [pending('k1', 'chan_a'), pending('k2', 'chan_b')];
      state.selectChannel('shared', 'chan_b');
      expect(state.pendingFor('shared').map((e) => e.idempotencyKey), ['k2']);
    });
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
}

class _Mls implements MlsConversationCryptoService, ChannelRoutedCryptoService {
  final List<String> plain = [];
  final List<(String, String, int)> routed = [];
  void Function()? afterEncrypt;

  MessageEnvelope _envelope(String conversationId) => MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'action-${plain.length + routed.length}',
      ciphertext: [1],
      cryptoProtocol: 'test');

  @override
  Future<MessageEnvelope> encryptPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {List<String> attachmentRefs = const [], String? draftText}) async {
    plain.add(conversationId);
    afterEncrypt?.call();
    return _envelope(conversationId);
  }

  @override
  Future<MessageEnvelope> encryptChannelPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {required String channelId,
      required int layoutGeneration,
      List<String> attachmentRefs = const [],
      String? draftText}) async {
    routed.add((conversationId, channelId, layoutGeneration));
    afterEncrypt?.call();
    return _envelope(conversationId);
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
