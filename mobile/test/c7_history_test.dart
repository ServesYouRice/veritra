import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/c7_history.dart';
import 'package:private_messenger/crypto/sha256.dart';

/// C7 build steps 3 and 4: the record codecs, the ordering table, windows,
/// the sender-key rule and the record message's size, against
/// testing/vectors/c7-primitives-v1.json and c7-ordering-v1.json. Rust and Go
/// check the same files. A missing vector fails; it never skips.
void main() {
  final primitives = jsonDecode(
    File('../testing/vectors/c7-primitives-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final ordering = jsonDecode(
    File('../testing/vectors/c7-ordering-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final inputs = primitives['inputs'] as Map<String, dynamic>;
  final outputs = primitives['outputs'] as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  group('records', () {
    test('the full form decodes, re-encodes and hashes as the vector says', () {
      final full = hex(outputs['record_full_hex']);
      final record = C7Record.decode(full);
      expect(record.encode(), full);
      expect(toHex(record.hash()), outputs['record_hash_hex']);
      expect(toHex(record.signedFields()), outputs['record_signed_fields_hex']);
      expect(utf8.decode(record.channelId), inputs['channel_id']);
      expect(record.seq, inputs['seq']);
    });

    test('the compact form expands to the full form', () {
      final compact =
          C7CompactRecord.decode(hex(outputs['record_compact_hex']));
      final full = C7Record.decode(hex(outputs['record_full_hex']));
      final expanded = compact.expand(C7RecordContext(
        communityId: full.communityId,
        channelId: full.channelId,
        groupId: full.groupId,
        epoch: full.epoch,
        actorDeviceId: full.actorDeviceId,
      ));
      expect(expanded.encode(), full.encode());
      expect(expanded.opensKey, isTrue);
      expect(toHex(expanded.chkCommit), outputs['chk_commit_hex']);
    });

    test('a move carries the old group and a wrap', () {
      final compact =
          C7CompactRecord.decode(hex(outputs['record_move_compact_hex']));
      expect(compact.reason, c7ReasonMove);
      expect(utf8.decode(compact.closeGroupId!), inputs['old_group_id']);
      expect(compact.wrap, hasLength(c7MoveWrapBytes));
    });

    test('malformed records are refused', () {
      final full = hex(outputs['record_full_hex']);
      expect(() => C7Record.decode(full.sublist(1)), throwsFormatException);
      final badVersion = Uint8List.fromList(full)..[0] = 2;
      expect(() => C7Record.decode(badVersion), throwsFormatException);
      final dirtyPadding = Uint8List.fromList(full)..[511] = 1;
      expect(() => C7Record.decode(dirtyPadding), throwsFormatException);
      final compact = hex(outputs['record_compact_hex']);
      expect(
        () => C7CompactRecord.decode([...compact, 0]),
        throwsFormatException,
      );
      expect(
        () => C7CompactRecord.decode(compact.sublist(0, compact.length - 1)),
        throwsFormatException,
      );
      // seq 2^32 - 1 never validates.
      final maxSeq = Uint8List.fromList(compact)
        ..setRange(1, 5, [0xff, 0xff, 0xff, 0xff]);
      expect(() => C7CompactRecord.decode(maxSeq), throwsFormatException);
    });
  });

  group('ordering table', () {
    C7Entry entryOf(Map<String, dynamic> r) {
      final prev = r['prev'] as String?;
      return C7Entry(
        seq: r['seq'] as int,
        hash: sha256(utf8.encode(r['id'] as String)),
        prev: prev == null ? Uint8List(32) : sha256(utf8.encode(prev)),
        mode: r['mode'] == 'full' ? c7ModeFull : c7ModeMembersFromJoin,
        reason: switch (r['reason']) {
          'create' => c7ReasonCreate,
          'switch' => c7ReasonSwitch,
          'move' => c7ReasonMove,
          _ => throw StateError('unknown reason'),
        },
        epoch: r['epoch'] as int,
      );
    }

    final names = <String, String>{};
    String nameOf(C7Entry? head) =>
        head == null ? '' : names[toHex(head.hash)]!;

    final cases = (ordering['ordering'] as Map)['cases'] as List;
    for (final raw in cases) {
      final c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        var state = const C7ChannelState.implicitGenesis();
        for (final stepRaw in c['steps'] as List) {
          final step = stepRaw as Map<String, dynamic>;
          final expect_ = step['expect'] as Map<String, dynamic>;
          if (step['event'] == 'unsure') {
            state = state.markUnsure(step['epoch'] as int);
          } else if (step['event'] == 'key_arrived') {
            state = state.keyArrived();
          } else {
            final entry = entryOf(step['record'] as Map<String, dynamic>);
            names[toHex(entry.hash)] =
                (step['record'] as Map<String, dynamic>)['id'] as String;
            if (step['valid'] == false) {
              // Validity runs before the table: the state is not touched.
              expect(expect_['row'], 'invalid');
            } else {
              final source = switch (step['source']) {
                'proposal_live' => C7Source.proposalLive,
                'proposal_history' => C7Source.proposalHistory,
                'report' => C7Source.report,
                _ => throw StateError('unknown source'),
              };
              final result = state.apply(
                entry,
                source: source,
                keyGiven: step['key_given'] as bool,
              );
              expect(result.row.number, expect_['row'], reason: '$step');
              state = result.state;
            }
          }
          final head = expect_['head'] as String?;
          expect(nameOf(state.head), head ?? '', reason: '$step');
          expect(state.status.name, expect_['status'], reason: '$step');
          expect(state.highestSeq, expect_['highest_seq'], reason: '$step');
        }
      });
    }

    test('every row of the table is covered by the vector', () {
      final seen = <Object?>{};
      for (final raw in cases) {
        for (final step in (raw as Map)['steps'] as List) {
          final row = ((step as Map)['expect'] as Map)['row'];
          if (row != null) seen.add(row);
        }
      }
      expect(seen, containsAll(<Object>[1, 2, 3, 4, 5, 6, 7, 'invalid']));
    });

    test('the implicit genesis seals no history key and hands none over', () {
      final genesis = ordering['implicit_genesis'] as Map<String, dynamic>;
      final expected = genesis['expect'] as Map<String, dynamic>;
      const state = C7ChannelState.implicitGenesis();
      expect(state.head, isNull);
      expect(expected['head'], isNull);
      expect(state.mode, c7ModeMembersFromJoin);
      expect(state.status.name, expected['status']);
      expect(state.sealsUnderHistoryKey, expected['seals_under_history_key']);
      expect(state.handsOverKey, expected['hands_over_key']);
      expect(state.highestSeq, expected['highest_seq']);
      for (final key in ['then_full_create', 'then_keyless']) {
        final next = genesis[key] as Map<String, dynamic>;
        final exp = next['expect'] as Map<String, dynamic>;
        final result = state.apply(
          entryOf(next['record'] as Map<String, dynamic>),
          source: C7Source.values.firstWhere((s) =>
              (s == C7Source.proposalLive ? 'proposal_live' : 'report') ==
              next['source']),
          keyGiven: next['key_given'] as bool,
        );
        expect(result.row.number, exp['row']);
        expect(result.state.status.name, exp['status']);
        expect(result.state.mode == c7ModeFull, exp['mode'] == 'full');
        expect(result.state.sealsUnderHistoryKey,
            exp['seals_under_history_key'] ?? false);
      }
    });
  });

  group('windows', () {
    for (final raw in ordering['windows'] as List) {
      final w = raw as Map<String, dynamic>;
      test(w['name'] as String, () {
        final gen = w['generation'] as Map<String, dynamic>;
        final body = w['body'] as Map<String, dynamic>;
        expect(
          c7WindowAccepts(
            generation: C7Generation(
              epoch: gen['epoch'] as int,
              groupId: gen['group'] as String,
              closeEpoch: gen['close_epoch'] as int?,
            ),
            periodStartEpoch: w['period_start_epoch'] as int,
            signedGen: body['signed_gen'] as int,
            signedGroupId: body['signed_group'] as String,
            signedEpoch: body['signed_epoch'] as int,
            routeEpoch: body['route_epoch'] as int,
          ),
          w['accept'],
          reason: w['reason'] as String,
        );
      });
    }
  });

  group('former members', () {
    final treeKey = Uint8List(32)..[0] = 1;
    final serverKey = Uint8List(32)..[0] = 2;

    test('a sender in the tree is checked against the tree, unmarked', () {
      final picked = c7SenderKey(treeKey: treeKey, serverKey: serverKey)!;
      expect(picked.key, treeKey);
      expect(picked.fromFormerMember, isFalse);
    });

    test('a departed sender uses the server list and is marked', () {
      final picked = c7SenderKey(serverKey: serverKey)!;
      expect(picked.key, serverKey);
      expect(picked.fromFormerMember, isTrue);
    });

    test('no key at all drops the post', () {
      expect(c7SenderKey(), isNull);
    });
  });

  group('record message size', () {
    final slack = ordering['vap1_slack'] as Map<String, dynamic>;
    for (final raw in slack['cases'] as List) {
      final c = raw as Map<String, dynamic>;
      test('${c['name']} fits its VAP1 bucket with the stated slack', () {
        final compact = Uint8List(c['compact_bytes'] as int);
        final inner = c7HistoryChangeInnerJson(
          conversationId: slack['conversation_id'] as String,
          senderDeviceId: slack['sender_device_id'] as String,
          actionId: slack['action_id'] as String,
          channelId: slack['channel_id'] as String,
          compactRecord: compact,
        );
        expect(inner.length, c['inner_json_bytes']);
        final framed = inner.length + 8;
        expect(framed, c['framed_bytes']);
        final vap1 = AppPayloadCodec.framedLength(inner.length);
        expect(vap1, c['vap1_bytes']);
        expect(vap1 - framed, c['slack']);
      });
    }

    test('the real compact record message stays in the smallest bucket', () {
      final inner = c7HistoryChangeInnerJson(
        conversationId: 'conv_${'a' * 32}',
        senderDeviceId: 'dev_${'b' * 32}',
        actionId: 'c' * 48,
        channelId: 'chan_${'d' * 32}',
        compactRecord: hex(outputs['record_compact_hex']),
      );
      expect(AppPayloadCodec.framedLength(inner.length), 512);
    });
  });
}
