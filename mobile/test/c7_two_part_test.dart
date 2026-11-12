// C7 step 5, pure parts: the reference codec, the post signature fields, the
// hidden-type body rules and the group-state codec. No native library.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/c7_group_state.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';
import 'package:private_messenger/crypto/sha256.dart';

void main() {
  group('C7 reference', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final body = Uint8List.fromList(List<int>.filled(124 + 256, 7));

    test('is 68 bytes and round-trips', () {
      final reference = encodeC7Reference(key, body);
      expect(reference.length, c7ReferenceBytes);
      expect(reference.sublist(0, 4), utf8.encode('C7R1'));
      final parsed = parseC7Reference(reference)!;
      expect(parsed.bodyKey, key);
      expect(parsed.bodyHash, sha256(body));
    });

    test('a VAP1 payload or any other length is not a reference', () {
      final vap1 = Uint8List(68)..setAll(0, utf8.encode('VAP1'));
      expect(parseC7Reference(vap1), isNull);
      final long = Uint8List.fromList([...encodeC7Reference(key, body), 0]);
      expect(parseC7Reference(long), isNull);
    });

    test('the signed fields bind every input', () {
      Uint8List fields({String channel = 'chan_a', int gen = 0}) =>
          c7PostSignedFields(
            communityId: 'comm_a',
            channelId: channel,
            actionId: 'act',
            groupId: 'conv_a',
            epoch: 5,
            senderDeviceId: 'dev_a',
            generation: gen,
            paddedVap1: const <int>[1, 2, 3],
          );
      expect(fields(), isNot(equals(fields(channel: 'chan_b'))));
      expect(fields(), isNot(equals(fields(gen: 5))));
      // lp(comm_a) starts the fields.
      expect(fields().sublist(0, 2), <int>[0, 6]);
    });

    test('only community kinds send two parts', () {
      expect(c7CommunityKind('community_shared'), isTrue);
      expect(c7CommunityKind('community_channel'), isTrue);
      expect(c7CommunityKind('group'), isFalse);
      expect(c7CommunityKind(null), isFalse);
    });
  });

  group('C7 hidden types', () {
    String b64(int n) => base64Encode(List<int>.filled(n, 1));

    test('wire names and hidden flag', () {
      expect(AppPayloadType.historyChange.wireName, 'history_change');
      expect(AppPayloadType.historySync.wireName, 'history_sync');
      expect(
          AppPayloadType.historySyncRequest.wireName, 'history_sync_request');
      for (final type in c7PayloadTypes) {
        expect(type.sendsHidden, isTrue);
      }
      expect(c7GroupLevelTypes.contains(AppPayloadType.historyChange), isFalse);
    });

    test('history_change takes a compact record or a move', () {
      expect(isValidC7ChangeBody({'r': b64(143)}), isTrue);
      expect(isValidC7ChangeBody({'r': b64(143 + 2 + 36 + 128)}), isTrue);
      expect(isValidC7ChangeBody({'r': b64(142)}), isFalse);
      expect(isValidC7ChangeBody({'r': b64(143), 'x': 1}), isFalse);
      expect(isValidC7ChangeBody({'r': 'not base64!'}), isFalse);
    });

    test('history_sync needs sorted distinct ids and 32-byte keys', () {
      expect(
          isValidC7SyncBody({
            'for_epoch': 4,
            'channels': [
              ['chan_a', b64(32)],
              ['chan_b', b64(32)],
            ],
          }),
          isTrue);
      expect(
          isValidC7SyncBody({
            'for_epoch': 4,
            'channels': [
              ['chan_b', b64(32)],
              ['chan_a', b64(32)],
            ],
          }),
          isFalse);
      expect(
          isValidC7SyncBody({
            'for_epoch': 4,
            'channels': [
              ['chan_a', b64(31)],
            ],
          }),
          isFalse);
      expect(isValidC7SyncBody({'for_epoch': 4, 'channels': []}), isFalse);
      expect(isValidC7SyncBody({'for_epoch': -1, 'channels': []}), isFalse);
    });

    test('history_sync_request names one epoch', () {
      expect(isValidC7SyncRequestBody({'for_epoch': 0}), isTrue);
      expect(isValidC7SyncRequestBody({'for_epoch': 'x'}), isFalse);
      expect(isValidC7SyncRequestBody({'for_epoch': 1, 'y': 2}), isFalse);
    });
  });

  group('C7 group state', () {
    test('round-trips floor and root', () {
      final root = Uint8List.fromList(List<int>.filled(32, 9));
      final state = C7GroupState(floor: 7, rootEpoch: 7, root: root);
      final back = C7GroupState.decode(state.encode());
      expect(back.floor, 7);
      expect(back.rootEpoch, 7);
      expect(back.root, root);
    });

    test('anything malformed reads as empty (fails closed)', () {
      for (final stored in <String?>[
        null,
        'not json',
        '{"v":3,"floor":1}',
        '{"v":1,"floor":-1}',
      ]) {
        final state = C7GroupState.decode(stored);
        expect(state.floor, 0);
        expect(state.root, isNull);
      }
      // A root of the wrong length is dropped, the floor kept.
      final short = C7GroupState.decode(jsonEncode({
        'v': 1,
        'floor': 3,
        'root_epoch': 3,
        'root': base64Encode([1])
      }));
      expect(short.floor, 3);
      expect(short.root, isNull);
    });

    test('a Welcome resets to the join epoch', () {
      final state = C7GroupState.joined(12);
      expect(state.floor, 12);
      expect(state.root, isNull);
    });
  });
}
