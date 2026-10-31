import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/message_format.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = AppPayloadCodec();
  AppPayloadOutcome classify(Map<String, Object?> json,
          {bool shared = false, String? channel}) =>
      codec.classify(_frame(json),
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action',
          communityShared: shared,
          channelId: channel);
  Map<String, Object?> payload(String type, Map<String, Object?> body,
          {int v = 2}) =>
      {
        'v': v,
        'type': type,
        'conversation_id': 'conv',
        'sender_device_id': 'dev',
        'action_id': 'action',
        'body': body
      };

  test('plain bodies keep v1, formatting and hidden pins use v2', () {
    for (final body in [
      {'text': 'plain'},
      {
        'text': 'bold',
        'entities': [
          {'type': 'bold', 'offset': 0, 'length': 4}
        ]
      }
    ]) {
      final bytes = codec.encode(
          type: AppPayloadType.text,
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action',
          body: body);
      final inner = jsonDecode(utf8.decode(
              bytes.sublist(8, 8 + ByteData.sublistView(bytes).getUint32(4))))
          as Map;
      expect(inner['v'], body.length == 1 ? 1 : 2);
      expect(
          codec
              .decode(bytes,
                  conversationId: 'conv',
                  senderDeviceId: 'dev',
                  actionId: 'action')
              .body,
          body);
    }
    expect(
        classify(payload('pin', {
          'message_id': 'dev:target',
          'pinned': true,
          'duration_seconds': 123
        })),
        isA<InvalidAppPayload>());
    expect(
        classify(payload('pin', {'message_id': 'dev:target', 'pinned': false},
            v: 1)),
        isA<InvalidAppPayload>());
    expect(
        classify(payload('pin', {
          'message_id': 'dev:target',
          'pinned': false,
          'duration_seconds': 'ignored on unpin'
        })),
        isA<DecodedAppPayload>());
    for (final type in ['poll', 'admin_delete', 'profile_key']) {
      expect(classify({...payload(type, {}), 'hidden': true}),
          isA<UnsupportedAppPayload>().having((p) => p.hidden, 'hidden', true));
    }
  });

  test('v2 ignores additive fields and binds shared-channel context', () {
    for (final (type, body) in <(String, Map<String, Object?>)>[
      ('text', {'text': 'hi'}),
      ('reply', {'text': 'hi', 'reply_to_id': 'dev:x'}),
      ('edit', {'text': 'hi', 'message_id': 'dev:x'}),
      ('delete', {'message_id': 'dev:x'}),
      ('reaction', {'message_id': 'dev:x', 'reaction': 'x'}),
      ('attachmentManifest', {'attachments': []}),
      ('pin', {'message_id': 'dev:x', 'pinned': false}),
      ('callSignal', {'signal': {}}),
    ]) {
      expect(
          classify({
            ...payload(type, {...body, 'future': true}),
            'future_top': true
          }),
          isA<DecodedAppPayload>(),
          reason: type);
    }
    final shared = {
      ...payload('text', {'text': 'hi'}),
      'channel_id': 'chan_a'
    };
    expect(classify(shared), isA<InvalidAppPayload>());
    expect(classify(shared, shared: true, channel: 'chan_a'),
        isA<DecodedAppPayload>());
    expect(classify(shared, shared: true, channel: 'chan_b'),
        isA<InvalidAppPayload>());
    expect(
        classify(payload('text', {'text': 'hi'}),
            shared: true, channel: 'chan_a'),
        isA<InvalidAppPayload>());
  });

  test('decorations drop bad entries alone and never split a surrogate', () {
    final decoration = messageDecoration({
      'text': '😀 @bob',
      'entities': [
        {'type': 'bold', 'offset': 0, 'length': 2},
        {'type': 'italic', 'offset': 1, 'length': 1},
        {'type': 'unknown', 'offset': 0, 'length': 2},
        {'type': 'bold', 'offset': 0, 'length': 1},
        {'type': 'code', 'offset': 0, 'length': 2},
        {'type': 'italic', 'offset': 99, 'length': 1},
      ],
      'mentions': [
        {'account_id': 'bob', 'offset': 3, 'length': 4},
        {'account_id': 'stranger', 'offset': 3, 'length': 4},
        {'account_id': 'bob', 'offset': 0, 'length': 2},
      ]
    }, members: {
      'bob'
    });
    expect(decoration['entities'], [
      {'type': 'bold', 'offset': 0, 'length': 2}
    ]);
    expect(decoration['mentions'], [
      {'account_id': 'bob', 'offset': 3, 'length': 4}
    ]);
    final composed = composeMessage(
        '*bold* _italic_ ~strike~ `code` ```block``` ||secret|| @bob',
        accountsByUsername: {'bob': 'bob'});
    expect(composed['text'], 'bold italic strike code block secret @bob');
    expect((composed['entities'] as List).length, 6);
    expect((composed['mentions'] as List).single,
        {'account_id': 'bob', 'offset': 37, 'length': 4});
  });

  test('pins require the conversation authority seam', () {
    final pin = DecryptedAppPayload(
        type: AppPayloadType.pin,
        actionId: 'p',
        body: {
          'message_id': 'dev:t',
          'pinned': true,
          'duration_seconds': 86400
        });
    List<MessageEffect> effects(ConversationAuthority authority) =>
        messageEffectsFor(pin,
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            createdAt: 1,
            state: LocalMessageState.received,
            authority: authority);
    // Owner decision 2026-10-31: any group member may pin; community
    // conversations keep moderator roles until C4.
    expect(effects(_Authority('group', 'member')).whereType<PinMessageEffect>(),
        hasLength(1));
    expect(effects(_Authority('group', 'admin')).whereType<PinMessageEffect>(),
        hasLength(1));
    expect(effects(_Authority('dm', 'member')).whereType<PinMessageEffect>(),
        hasLength(1));
    for (final kind in ['community_shared', 'community_channel']) {
      expect(effects(_Authority(kind, 'member')).whereType<PinMessageEffect>(),
          isEmpty);
      expect(
          effects(_Authority(kind, 'moderator')).whereType<PinMessageEffect>(),
          hasLength(1));
    }
    expect(effects(_Authority('', 'member')).whereType<PinMessageEffect>(),
        isEmpty);
  });

  for (final encrypted in [false, true]) {
    group(encrypted ? 'SQLite' : 'memory', () {
      late LocalStore store;
      EncryptedLocalDatabase? database;
      late Directory dir;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        dir = await Directory.systemTemp.createTemp('veritra-w8-');
        database = null;
        store = encrypted
            ? SecureLocalStore(
                directoryProvider: () async => dir,
                databaseFactory: (_, __) => database ??=
                    EncryptedLocalDatabase(NativeDatabase.memory()))
            : MemoryLocalStore();
        await store.saveSession(const Session(
            baseUrl: 'https://example.test',
            token: 'token',
            accountId: 'alice',
            deviceId: 'dev'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
            0);
      });
      tearDown(() async {
        await database?.close();
        await SecureLocalStore.releaseInstanceLocks();
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      test(
          'channel and hidden target guards cover edit delete and reaction clearing',
          () async {
        await _commit(store, [
          _text('dev:t', channel: 'a'),
          const ReactionEffect(
              targetKey: 'dev:t',
              reactorAccountId: 'bob',
              reaction: 'x',
              at: 1,
              conversationId: 'conv',
              channelId: 'a')
        ]);
        await _commit(store, [
          const EditMessageEffect(
              targetKey: 'dev:t',
              editorAccountId: 'alice',
              body: 'forged',
              at: 2,
              conversationId: 'conv',
              channelId: 'b'),
          const DeleteMessageEffect(
              targetKey: 'dev:t',
              deleterAccountId: 'alice',
              at: 2,
              conversationId: 'conv',
              channelId: 'b'),
          const ReactionEffect(
              targetKey: 'dev:t',
              reactorAccountId: 'bob',
              reaction: '',
              at: 2,
              conversationId: 'conv',
              channelId: 'b'),
        ]);
        expect((await store.loadMessages('conv')).single.body, 'text');
        expect(await store.loadReactions('conv'), hasLength(1));
        await store.setStarred('dev:t', true);
        await _commit(store, [_pin('dev:t', channel: 'a')]);
        await store.hideMessage('conv', 'dev:t');
        await _commit(store, [
          const EditMessageEffect(
              targetKey: 'dev:t',
              editorAccountId: 'alice',
              body: 'resurrected',
              at: 3,
              conversationId: 'conv',
              channelId: 'a'),
          const DeleteMessageEffect(
              targetKey: 'dev:t',
              deleterAccountId: 'alice',
              at: 3,
              conversationId: 'conv',
              channelId: 'a'),
          const ReactionEffect(
              targetKey: 'dev:t',
              reactorAccountId: 'bob',
              reaction: 'y',
              at: 3,
              conversationId: 'conv',
              channelId: 'a'),
          _pin('dev:t', channel: 'a'),
        ]);
        final hidden = (await store.loadMessages('conv')).single;
        expect(hidden.hiddenAt, isNotNull);
        expect(hidden.body, isNull);
        expect(hidden.deletedAt, isNull);
        expect(await store.loadReactions('conv'), isEmpty);
        expect(await store.loadPins('conv'), isEmpty);
        expect(await store.loadStarred(), isEmpty);
        expect(await store.searchMessages('text'), isEmpty);
        expect(utf8.decode(await store.exportBackup()),
            isNot(contains('resurrected')));
      });

      test('51 simultaneous pins evict the first and ordering survives backup',
          () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        await _commit(store,
            [for (var i = 0; i <= pinLimitPerChat; i++) _text('dev:$i')]);
        for (var i = 0; i <= pinLimitPerChat; i++) {
          await _commit(store, [_pin('dev:$i', at: now)]);
        }
        expect(pinLimitPerChat, 50);
        expect((await store.loadPins('conv')).map((p) => p.targetKey),
            [for (var i = pinLimitPerChat; i >= 1; i--) 'dev:$i']);
        final before = await store.loadPins('conv');
        await store.restoreBackup(await store.exportBackup());
        expect(await store.loadPins('conv'), before);
        await store.setStarred('dev:2', true);
        await store.saveConversationPref(const LocalConversationPref(
            conversationId: 'conv', archivedAt: 1, pinnedAt: 2));
        final backup = await store.exportBackup();
        expect((jsonDecode(utf8.decode(backup)) as Map)['version'], 5);
        await store.restoreBackup(backup);
        expect(await store.loadStarred(), {'dev:2'});
        expect((await store.loadConversationPrefs()).single.archivedAt, 1);
      });

      test('pin expiry is capped and attachment deletion clears key and extras',
          () async {
        final expiry = DateTime.now()
            .add(const Duration(minutes: 1))
            .millisecondsSinceEpoch;
        await _commit(store, [
          _text('dev:t', expires: expiry),
          _text('dev:a',
              kind: LocalMessageKind.attachment, body: 'attachment-secret')
        ]);
        await _commit(store, [_pin('dev:t'), _pin('dev:a')]);
        expect(
            (await store.loadPins('conv'))
                .firstWhere((p) => p.targetKey == 'dev:t')
                .expiresAt,
            expiry);
        await store.setStarred('dev:a', true);
        await _commit(store, [
          const DeleteMessageEffect(
              targetKey: 'dev:a',
              deleterAccountId: 'alice',
              conversationId: 'conv',
              at: 3)
        ]);
        expect(
            (await store.loadMessages('conv'))
                .firstWhere((m) => m.key == 'dev:a')
                .body,
            isNull);
        expect(await store.loadStarred(), isEmpty);
        expect(
            (await store.loadPins('conv')).map((p) => p.targetKey), ['dev:t']);
      });

      test(
          'old backup history receives safe defaults and local pin limit is five',
          () async {
        await _commit(store, [_text('dev:t')]);
        final root = jsonDecode(utf8.decode(await store.exportBackup()))
            as Map<String, dynamic>;
        root['version'] = 3;
        for (final message in root['history'] as List) {
          (message as Map).remove('senderHidden');
        }
        root.remove('pins');
        root.remove('pending_pins');
        root.remove('starred');
        root.remove('conversation_prefs');
        await store.restoreBackup(utf8.encode(jsonEncode(root)));
        expect((await store.loadMessages('conv')).single.senderHidden, false);
        for (var i = 0; i < 5; i++) {
          await store.saveConversationPref(
              LocalConversationPref(conversationId: 'c$i', pinnedAt: i));
        }
        await expectLater(
            store.saveConversationPref(const LocalConversationPref(
                conversationId: 'six', pinnedAt: 6)),
            throwsStateError);
      });

      test(
          'own pin waits for server echo and duplicate echoes never reapply it',
          () async {
        await _commit(store, [_text('dev:t')]);
        final current = (await store.loadCryptoState())!;
        final envelope = MessageEnvelope(
            conversationId: 'conv',
            idempotencyKey: 'pin',
            ciphertext: [1],
            cryptoProtocol: 'mls10-openmls-v1');
        await store.commitOutgoingApplicationTransition(
            OutgoingApplicationStateTransition(
                expectedCounter: current.counter,
                expectedCursor: await store.loadSyncCursor(),
                state: StoredCryptoState(
                    counter: current.counter + 1,
                    stateKey: current.stateKey,
                    sealedState: [2]),
                envelope: envelope,
                messageEffects: [
              const InsertMessageEffect(
                  key: 'dev:pin',
                  conversationId: 'conv',
                  senderAccountId: 'alice',
                  senderDeviceId: 'dev',
                  kind: LocalMessageKind.action,
                  createdAt: 1,
                  state: LocalMessageState.pending),
              PinMessageEffect(
                  conversationId: 'conv',
                  targetKey: 'dev:t',
                  accountId: 'alice',
                  at: 1,
                  pinned: true,
                  durationSeconds: 86400,
                  pendingActionKey: 'dev:pin'),
            ]));
        expect(await store.loadPins('conv'), isEmpty);
        // Restart/backup preserves only this device's still-pending command.
        await store.restoreBackup(await store.exportBackup());
        // A server HTTP acknowledgement removes the outbox before sync echo.
        await store.removePendingEnvelope('pin');
        await store.restoreBackup(await store.exportBackup());
        final now = DateTime.now().millisecondsSinceEpoch;
        final cursor = await store.loadSyncCursor();
        final echoed = ReceivedMessageEnvelope(
            id: 'srv_pin',
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            idempotencyKey: 'pin',
            ciphertext: [1],
            cryptoProtocol: 'mls10-openmls-v1',
            createdAt: DateTime.fromMillisecondsSinceEpoch(now));
        if (encrypted) {
          await database!.customStatement(
              "CREATE TRIGGER fail_pin BEFORE INSERT ON local_pins BEGIN SELECT RAISE(ABORT, 'pin test failure'); END");
          await expectLater(
              store.commitSyncEvent(SyncEventCommit(
                  eventKey: 'echo',
                  conversationId: 'conv',
                  expectedCursor: cursor,
                  cursor: cursor + 1,
                  envelope: echoed,
                  ownMessageKey: 'dev:pin',
                  allowOwnPinEffect: true)),
              throwsA(anything));
          expect(await store.loadSyncCursor(), cursor);
          expect(await store.loadPins('conv'), isEmpty);
          await database!.customStatement('DROP TRIGGER fail_pin');
        }
        await store.commitSyncEvent(SyncEventCommit(
            eventKey: 'echo',
            conversationId: 'conv',
            expectedCursor: cursor,
            cursor: cursor + 1,
            envelope: echoed,
            ownMessageKey: 'dev:pin',
            allowOwnPinEffect: true));
        final pin = (await store.loadPins('conv')).single;
        expect(pin.pinnedAt, now);
        expect(pin.expiresAt, now + 86400000);
        await _commit(store, [_pin('dev:t', pinned: false)]);
        final next = await store.loadSyncCursor();
        await store.commitSyncEvent(SyncEventCommit(
            eventKey: 'another-echo',
            conversationId: 'conv',
            expectedCursor: next,
            cursor: next + 1,
            envelope: echoed,
            ownMessageKey: 'dev:pin',
            allowOwnPinEffect: true));
        expect(await store.loadPins('conv'), isEmpty);
      });
    });
  }
}

Uint8List _frame(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  final result = Uint8List(((bytes.length + 8 + 255) ~/ 256) * 256);
  result.setRange(0, 4, [86, 65, 80, 49]);
  ByteData.sublistView(result).setUint32(4, bytes.length);
  result.setRange(8, 8 + bytes.length, bytes);
  return result;
}

InsertMessageEffect _text(String key,
        {String? channel,
        String kind = LocalMessageKind.text,
        String body = 'text',
        int? expires}) =>
    InsertMessageEffect(
        key: key,
        conversationId: 'conv',
        senderAccountId: 'alice',
        senderDeviceId: 'dev',
        kind: kind,
        body: body,
        createdAt: 1,
        state: LocalMessageState.received,
        channelId: channel,
        expiresAt: expires);
PinMessageEffect _pin(String key,
        {String? channel, int? at, bool pinned = true}) =>
    PinMessageEffect(
        conversationId: 'conv',
        targetKey: key,
        accountId: 'alice',
        at: at ?? DateTime.now().millisecondsSinceEpoch,
        pinned: pinned,
        durationSeconds: 86400,
        channelId: channel);
Future<void> _commit(LocalStore store, List<MessageEffect> effects) async {
  final state = (await store.loadCryptoState())!,
      cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'event:${cursor + 1}',
      conversationId: 'conv',
      expectedCounter: state.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: state.counter + 1,
          stateKey: state.stateKey,
          sealedState: [2]),
      cursor: cursor + 1,
      messageEffects: effects));
}

class _Authority implements ConversationAuthority {
  _Authority(this.kind, this.role);
  final String kind, role;
  @override
  String? roleOf(String conversationId, String accountId) => role;
  @override
  Set<String> memberAccounts(String conversationId) => {'alice', 'bob'};
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
}
