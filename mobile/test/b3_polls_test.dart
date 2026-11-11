import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/poll.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

const _pollBody = <String, Object?>{
  'question': 'Lunch?',
  'options': ['Pizza', 'Sushi', 'Soup'],
  'multiple_choice': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = AppPayloadCodec();

  AppPayloadOutcome classify(String type, Map<String, Object?> body,
          {int v = 2, bool hidden = false}) =>
      codec.classify(
          _frame({
            'v': v,
            'type': type,
            'conversation_id': 'conv',
            'sender_device_id': 'dev',
            'action_id': 'action',
            if (hidden) 'hidden': true,
            'body': body,
          }),
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action');

  group('payload', () {
    test('a valid poll and vote decode; v1 and bad bodies are invalid', () {
      expect(classify('poll', _pollBody), isA<DecodedAppPayload>());
      expect(
          classify(
              'poll_vote',
              {
                'message_id': 'dev:p',
                'choices': [0]
              },
              hidden: true),
          isA<DecodedAppPayload>());
      expect(classify('poll', _pollBody, v: 1), isA<InvalidAppPayload>());
      for (final bad in <Map<String, Object?>>[
        {..._pollBody, 'question': ''},
        {..._pollBody, 'question': 'x' * 301},
        {
          ..._pollBody,
          'options': ['only']
        },
        {..._pollBody, 'options': List.generate(13, (i) => 'o$i')},
        {
          ..._pollBody,
          'options': ['same', 'same']
        },
        {
          ..._pollBody,
          'options': ['a', 'x' * 101]
        },
        {..._pollBody, 'multiple_choice': 'no'},
      ]) {
        expect(classify('poll', bad), isA<InvalidAppPayload>(), reason: '$bad');
      }
      // Index range and single-choice rules are checked at apply time, so
      // these still decode (vectors 12 and 13).
      expect(
          classify('poll_vote', {
            'message_id': 'dev:p',
            'choices': [2]
          }),
          isA<DecodedAppPayload>());
      expect(classify('poll_vote', {'message_id': 'dev:p', 'choices': 'x'}),
          isA<InvalidAppPayload>());
      expect(
          classify('poll_vote', {
            'message_id': 'dev:p',
            'choices': ['a']
          }),
          isA<InvalidAppPayload>());
    });

    test('poll_vote is v2, hidden and snake_case on the wire', () {
      Map<String, Object?> inner(AppPayloadType type, Map<String, Object?> b) {
        final bytes = codec.encode(
            type: type,
            conversationId: 'conv',
            senderDeviceId: 'dev',
            actionId: 'action',
            body: b,
            hidden: type.sendsHidden);
        return Map<String, Object?>.from(jsonDecode(utf8.decode(
            bytes.sublist(8, 8 + ByteData.sublistView(bytes).getUint32(4)))));
      }

      final vote = inner(AppPayloadType.pollVote, {
        'message_id': 'dev:p',
        'choices': [1]
      });
      expect(vote['type'], 'poll_vote');
      expect(vote['v'], 2);
      expect(vote['hidden'], true);
      final poll = inner(AppPayloadType.poll, _pollBody);
      expect(poll['type'], 'poll');
      expect(poll['v'], 2);
      expect(poll.containsKey('hidden'), isFalse);
    });

    test('poll payloads round trip through the codec', () {
      final bytes = codec.encode(
          type: AppPayloadType.poll,
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action',
          body: _pollBody);
      final decoded = codec.decode(bytes,
          conversationId: 'conv', senderDeviceId: 'dev', actionId: 'action');
      expect(decoded.type, AppPayloadType.poll);
      expect(decoded.body['question'], 'Lunch?');
    });
  });

  group('poll_close payload', () {
    test('decodes as v2 with a target; v1 and a missing target fail', () {
      expect(classify('poll_close', {'message_id': 'dev:p'}, hidden: true),
          isA<DecodedAppPayload>());
      expect(classify('poll_close', {'message_id': 'dev:p'}, v: 1),
          isA<InvalidAppPayload>());
      expect(classify('poll_close', {}), isA<InvalidAppPayload>());
      expect(
          classify('poll_close', {'message_id': 5}), isA<InvalidAppPayload>());
    });

    test('is v2, hidden and snake_case on the wire', () {
      final bytes = codec.encode(
          type: AppPayloadType.pollClose,
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action',
          body: {'message_id': 'dev:p'},
          hidden: AppPayloadType.pollClose.sendsHidden);
      final length = ByteData.sublistView(bytes).getUint32(4);
      final json = jsonDecode(utf8.decode(bytes.sublist(8, 8 + length))) as Map;
      expect(json['type'], 'poll_close');
      expect(json['v'], 2);
      expect(json['hidden'], true);
    });
  });

  group('poll close rules', () {
    final base = pollRowBody(_pollBody);

    test('close keeps the votes and refuses later votes', () {
      final voted = applyPollVote(base, 'alice', [1])!;
      final closed = applyPollClose(voted)!;
      final poll = parsePollBody(closed)!;
      expect(poll.closed, isTrue);
      expect(poll.votes, {
        'alice': [1]
      });
      expect(applyPollVote(closed, 'bob', [0]), isNull);
      expect(applyPollVote(closed, 'alice', []), isNull);
      expect(applyPollClose(closed), isNull);
      expect(parsePollBody(voted)!.closed, isFalse);
    });

    test('close of a non-poll body has no effect', () {
      expect(applyPollClose(null), isNull);
      expect(applyPollClose('{"not":"a poll"}'), isNull);
    });
  });

  group('poll rules', () {
    final base = pollRowBody(_pollBody);

    test('last valid vote replaces, empty retracts', () {
      var body = applyPollVote(base, 'alice', [0])!;
      expect(parsePollBody(body)!.votes, {
        'alice': [0]
      });
      body = applyPollVote(body, 'alice', [2])!;
      body = applyPollVote(body, 'bob', [2])!;
      expect(parsePollBody(body)!.tally(), [0, 0, 2]);
      body = applyPollVote(body, 'alice', [])!;
      expect(parsePollBody(body)!.tally(), [0, 0, 1]);
      expect(parsePollBody(body)!.voterCount(), 1);
    });

    test('invalid votes have no effect at all', () {
      expect(applyPollVote(base, 'alice', [3]), isNull);
      expect(applyPollVote(base, 'alice', [-1]), isNull);
      expect(applyPollVote(base, 'alice', [0, 1]), isNull);
      expect(applyPollVote(base, 'alice', [0, 0]), isNull);
      expect(applyPollVote(null, 'alice', [0]), isNull);
      expect(applyPollVote('{"not":"a poll"}', 'alice', [0]), isNull);
    });

    test('multiple choice accepts several distinct options', () {
      final multi = pollRowBody({..._pollBody, 'multiple_choice': true});
      final body = applyPollVote(multi, 'alice', [2, 0])!;
      expect(parsePollBody(body)!.votes['alice'], [0, 2]);
      expect(applyPollVote(multi, 'alice', [1, 1]), isNull);
    });

    test('only roster accounts are counted', () {
      var body = applyPollVote(base, 'alice', [0])!;
      body = applyPollVote(body, 'gone', [0])!;
      final poll = parsePollBody(body)!;
      expect(poll.tally(), [2, 0, 0]);
      expect(poll.tally(members: {'alice', 'bob'}), [1, 0, 0]);
      expect(poll.voterCount(members: {'alice'}), 1);
    });
  });

  test('messageEffectsFor builds a poll row and a hidden vote action', () {
    List<MessageEffect> effects(AppPayloadType type, Map<String, Object?> b) =>
        messageEffectsFor(
            DecryptedAppPayload(type: type, actionId: 'a1', body: b),
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            createdAt: 1,
            state: LocalMessageState.received);
    final poll = effects(AppPayloadType.poll, _pollBody);
    expect(poll.single, isA<InsertMessageEffect>());
    expect((poll.single as InsertMessageEffect).kind, LocalMessageKind.poll);
    final vote = effects(AppPayloadType.pollVote, {
      'message_id': 'dev:p',
      'choices': [1]
    });
    expect((vote.first as InsertMessageEffect).kind, LocalMessageKind.action);
    final effect = vote.last as PollVoteEffect;
    expect(effect.voterAccountId, 'alice');
    expect(effect.choices, [1]);
    final close = effects(AppPayloadType.pollClose, {'message_id': 'dev:p'});
    expect((close.first as InsertMessageEffect).kind, LocalMessageKind.action);
    final closeEffect = close.last as PollCloseEffect;
    expect(closeEffect.closerAccountId, 'alice');
    expect(closeEffect.targetKey, 'dev:p');
  });

  for (final encrypted in [false, true]) {
    group(encrypted ? 'SQLite' : 'memory', () {
      late LocalStore store;
      EncryptedLocalDatabase? database;
      late Directory dir;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        dir = await Directory.systemTemp.createTemp('veritra-b3-');
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

      Future<PollView> poll() async =>
          parsePollBody((await store.loadMessages('conv'))
              .firstWhere((m) => m.key == 'dev:p')
              .body)!;
      PollVoteEffect vote(String voter, List<int> choices,
              {String conversation = 'conv', String? channel}) =>
          PollVoteEffect(
              targetKey: 'dev:p',
              voterAccountId: voter,
              choices: choices,
              conversationId: conversation,
              channelId: channel);

      test('votes are counted, changed and retracted per account', () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          vote('alice', [0]),
          vote('bob', [1])
        ]);
        expect((await poll()).tally(), [1, 1, 0]);
        await _commit(store, [
          vote('alice', [2])
        ]);
        expect((await poll()).tally(), [0, 1, 1]);
        await _commit(store, [vote('bob', [])]);
        expect((await poll()).tally(), [0, 0, 1]);
      });

      test('invalid votes and wrong targets change nothing', () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          vote('alice', [0])
        ]);
        await _commit(store, [
          vote('alice', [5]),
          vote('alice', [0, 1]),
          vote('bob', [1], conversation: 'other'),
          vote('bob', [1], channel: 'c'),
        ]);
        expect((await poll()).votes, {
          'alice': [0]
        });
        // A vote on an ordinary text message is dropped.
        await _commit(store, [
          _pollRow(key: 'dev:t', kind: LocalMessageKind.text, body: 'hello'),
          const PollVoteEffect(
              targetKey: 'dev:t',
              voterAccountId: 'bob',
              choices: [0],
              conversationId: 'conv'),
        ]);
        final text = (await store.loadMessages('conv'))
            .firstWhere((m) => m.key == 'dev:t');
        expect(text.body, 'hello');
      });

      PollCloseEffect close(String closer,
              {String conversation = 'conv', String? channel}) =>
          PollCloseEffect(
              targetKey: 'dev:p',
              closerAccountId: closer,
              conversationId: conversation,
              channelId: channel);

      test('the author closes a poll; later votes are ignored', () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          vote('bob', [1])
        ]);
        await _commit(store, [close('alice')]);
        await _commit(store, [
          vote('bob', [2]),
          vote('carol', [0])
        ]);
        final closed = await poll();
        expect(closed.closed, isTrue);
        expect(closed.votes, {
          'bob': [1]
        });
      });

      test('a close from a non-author or a wrong context changes nothing',
          () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          close('bob'),
          close('alice', conversation: 'other'),
          close('alice', channel: 'c'),
        ]);
        expect((await poll()).closed, isFalse);
        await _commit(store, [
          vote('bob', [1])
        ]);
        expect((await poll()).votes, {
          'bob': [1]
        });
      });

      test('delete clears the poll with its votes; later votes are dropped',
          () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          vote('bob', [1])
        ]);
        await _commit(store, [
          const DeleteMessageEffect(
              targetKey: 'dev:p',
              deleterAccountId: 'alice',
              at: 5,
              conversationId: 'conv'),
        ]);
        await _commit(store, [
          vote('bob', [1])
        ]);
        final row = (await store.loadMessages('conv')).single;
        expect(row.deletedAt, 5);
        expect(row.body, isNull);
      });

      test('only the author deletes a poll', () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          const DeleteMessageEffect(
              targetKey: 'dev:p',
              deleterAccountId: 'bob',
              at: 5,
              conversationId: 'conv'),
        ]);
        expect((await store.loadMessages('conv')).single.deletedAt, isNull);
      });

      test('delete for me clears the poll and its votes', () async {
        await _commit(store, [_pollRow()]);
        await _commit(store, [
          vote('bob', [1])
        ]);
        await store.hideMessage('conv', 'dev:p');
        await _commit(store, [
          vote('bob', [2])
        ]);
        final row = (await store.loadMessages('conv')).single;
        expect(row.hiddenAt, isNotNull);
        expect(row.body, isNull);
      });
    });
  }
}

InsertMessageEffect _pollRow(
        {String key = 'dev:p',
        String kind = LocalMessageKind.poll,
        String? body}) =>
    InsertMessageEffect(
        key: key,
        conversationId: 'conv',
        senderAccountId: 'alice',
        senderDeviceId: 'dev',
        kind: kind,
        body: body ?? pollRowBody(_pollBody),
        createdAt: 1,
        state: LocalMessageState.received);

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

Uint8List _frame(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  final result = Uint8List(((bytes.length + 8 + 255) ~/ 256) * 256);
  result.setRange(0, 4, [86, 65, 80, 49]);
  ByteData.sublistView(result).setUint32(4, bytes.length);
  result.setRange(8, 8 + bytes.length, bytes);
  return result;
}
