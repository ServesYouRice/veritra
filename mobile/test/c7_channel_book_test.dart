import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/c7_channel_book.dart';
import 'package:private_messenger/crypto/c7_group_state.dart';
import 'package:private_messenger/crypto/c7_history.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';

/// C7 full mode, the per-channel and per-group state (decisions 2, 4 and 5):
/// what a device keeps between messages and how records, rekeys, misses and
/// slots move it. Pure Dart: no signatures are checked here (the native
/// tests do that); these pin the state rules themselves.
void main() {
  const groupId = 'grp-1';
  const channel = 'chan-1';
  final zero32 = Uint8List(32);

  Uint8List key(int fill) => Uint8List(32)..fillRange(0, 32, fill);

  C7Record record({
    required int seq,
    required List<int> prev,
    required int mode,
    int reason = c7ReasonSwitch,
    int epoch = 5,
    List<int>? chkKey,
    String actor = 'dev-admin',
  }) =>
      C7Record(
        communityId: utf8.encode('comm'),
        channelId: utf8.encode(channel),
        seq: seq,
        prev: prev,
        mode: mode,
        reason: reason,
        groupId: utf8.encode(groupId),
        epoch: epoch,
        closeGroupId: utf8.encode(groupId),
        closeEpoch: epoch,
        chkCommit: mode == c7ModeFull ? c7ChkCommitOf(chkKey!) : zero32,
        actorDeviceId: utf8.encode(actor),
        sig: Uint8List(64)..[0] = seq + 1,
      );

  ({C7ChannelBook book, C7Record create}) fullChannel(
      {int epoch = 5, int fill = 7}) {
    final create = record(
      seq: 0,
      prev: zero32,
      mode: c7ModeFull,
      reason: c7ReasonCreate,
      epoch: epoch,
      chkKey: key(fill),
    );
    final step = C7ChannelBook.genesis(channel, groupId).applyRecord(
      create,
      create.encode(),
      source: C7Source.proposalLive,
      key: key(fill),
    );
    expect(step.row, C7Row.adopt);
    return (book: step.book, create: create);
  }

  group('generation entry', () {
    test('encodes to 128 bytes and reads back, wrap included', () {
      final entry = C7GenerationEntry(
        epoch: 9,
        keyCommit: c7ChkCommitOf(key(1)),
        previousEpoch: 5,
        previousKey: key(2),
      );
      final bytes = entry.encode();
      expect(bytes, hasLength(c7EntryBytes));
      final back = C7GenerationEntry.decode(bytes)!;
      expect(back.epoch, 9);
      expect(back.previousEpoch, 5);
      expect(back.previousKey, key(2));
      expect(back.keyCommit, c7ChkCommitOf(key(1)));
    });

    test('the zero entry is no key; dirty padding or a lone epoch fails', () {
      expect(C7GenerationEntry.decode(Uint8List(c7EntryBytes)), isNull);
      final base = C7GenerationEntry(epoch: 3, keyCommit: key(4)).encode();
      expect(
          () => C7GenerationEntry.decode(Uint8List.fromList(base)..[127] = 1),
          throwsFormatException);
      expect(() => C7GenerationEntry.decode(Uint8List.fromList(base)..[47] = 1),
          throwsFormatException);
      expect(() => C7GenerationEntry.decode(base.sublist(1)),
          throwsFormatException);
    });
  });

  group('channel book', () {
    test('a genesis channel seals nothing under a history key', () {
      final book = C7ChannelBook.genesis(channel, groupId);
      expect(book.hasHead, isFalse);
      expect(book.mode, c7ModeMembersFromJoin);
      expect(book.sealGenAt(5), isNull);
      final snapshot = book.snapshot(5);
      expect(snapshot.key, isNull);
      expect(snapshot.head.every((b) => b == 0), isTrue);
    });

    test('a full create with its key opens a generation that seals', () {
      final (:book, :create) = fullChannel();
      expect(book.status, C7Status.ok);
      expect(book.headRecord!.encode(), create.encode());
      expect(book.periodStart, 5);
      expect(book.sealGenAt(5)!.key, key(7));
      expect(book.sealGenAt(4), isNull, reason: 'before the period');
    });

    test('a full record without its key is keyless and seals nothing', () {
      final create = record(
          seq: 0,
          prev: zero32,
          mode: c7ModeFull,
          reason: c7ReasonCreate,
          chkKey: key(7));
      final step = C7ChannelBook.genesis(channel, groupId).applyRecord(
          create, create.encode(),
          source: C7Source.report, key: key(8));
      expect(step.book.status, C7Status.keyless);
      expect(step.book.sealGenAt(5), isNull);
      expect(step.book.snapshot(5).key, isNull);
    });

    test('a removal rekey closes the generation and opens the next', () {
      final book = fullChannel().book.rekey(8, key(9));
      expect(book.gens.map((gen) => gen.epoch), [5, 8]);
      expect(book.gens.first.close, 8);
      expect(book.sealGenAt(7)!.key, key(7));
      expect(book.sealGenAt(8)!.key, key(9));
      // The slot hands the current key and wraps the previous one.
      final snapshot = book.snapshot(8);
      expect(snapshot.key, key(9));
      final entry = C7GenerationEntry.decode(snapshot.entry)!;
      expect(entry.epoch, 8);
      expect(entry.previousEpoch, 5);
      expect(entry.previousKey, key(7));
      // A rekey at or below the current generation changes nothing.
      expect(book.rekey(8, key(1)).gens.last.key, key(9));
    });

    test('a miss turns the channel unsure: no seal, no handover', () {
      final book = fullChannel().book.markUnsure(6);
      expect(book.status, C7Status.unsure);
      expect(book.sealGenAt(6), isNull);
      expect(book.snapshot(6).key, isNull);
    });

    test('a slot with the held key confirms only above the miss epoch', () {
      final book = fullChannel().book.markUnsure(6);
      final entry =
          C7GenerationEntry(epoch: 5, keyCommit: c7ChkCommitOf(key(7)));
      expect(book.confirmedBySlot(6, key(7), entry).status, C7Status.unsure);
      expect(book.confirmedBySlot(7, key(8), entry).status, C7Status.unsure,
          reason: 'a key this device does not hold');
      expect(book.confirmedBySlot(7, key(7), entry).status, C7Status.ok);
    });

    test('a switch to members_from_join ends the period and its keys', () {
      final (:book, :create) = fullChannel();
      final off = record(
          seq: 1, prev: create.hash(), mode: c7ModeMembersFromJoin, epoch: 6);
      final step =
          book.applyRecord(off, off.encode(), source: C7Source.proposalLive);
      expect(step.row, C7Row.apply);
      expect(step.book.gens, isEmpty);
      expect(step.book.pastGens, [5]);
      expect(step.book.sealGenAt(6), isNull);
    });

    test('a report whose entry commits to the slot key gives two gens', () {
      final create = record(
          seq: 0,
          prev: zero32,
          mode: c7ModeFull,
          reason: c7ReasonCreate,
          chkKey: key(7));
      final entry = C7GenerationEntry(
        epoch: 8,
        keyCommit: c7ChkCommitOf(key(9)),
        previousEpoch: 5,
        previousKey: key(7),
      );
      final step = C7ChannelBook.genesis(channel, groupId).applyRecord(
          create, create.encode(),
          source: C7Source.report, key: key(9), entry: entry);
      expect(step.book.status, C7Status.ok);
      expect(step.book.gens.map((gen) => (gen.epoch, gen.close)),
          [(5, 8), (8, null)]);
      expect(step.book.sealGenAt(8)!.key, key(9));
      expect(step.book.genAt(groupId, 6)!.key, key(7));
    });

    test('a wrap reaching before the record is not a key', () {
      final create = record(
          seq: 0,
          prev: zero32,
          mode: c7ModeFull,
          reason: c7ReasonCreate,
          chkKey: key(7));
      final entry = C7GenerationEntry(
        epoch: 8,
        keyCommit: c7ChkCommitOf(key(9)),
        previousEpoch: 2,
        previousKey: key(7),
      );
      final step = C7ChannelBook.genesis(channel, groupId).applyRecord(
          create, create.encode(),
          source: C7Source.report, key: key(9), entry: entry);
      expect(step.book.status, C7Status.keyless);
    });

    test('a pending proposal is lost when another record takes its seq', () {
      final (:book, :create) = fullChannel();
      final mine = record(
          seq: 1,
          prev: create.hash(),
          mode: c7ModeMembersFromJoin,
          epoch: 6,
          actor: 'dev-me');
      final theirs = record(
          seq: 1,
          prev: create.hash(),
          mode: c7ModeFull,
          epoch: 6,
          chkKey: key(3));
      final pending = book.copyWith(
          pending: C7Pending(
              actionId: 'a1', sentAtMs: 1, record: mine.encode(), key: key(0)));
      final step = pending.applyRecord(theirs, theirs.encode(),
          source: C7Source.proposalLive, key: key(3));
      expect(step.book.pending, isNull);
      expect(step.book.ownNotice, 'lost');
      expect(step.book.lastOwn, C7OwnOutcome.lost);
      // The own record then comes back and loses the race (row 4).
      final echo = step.book.applyRecord(mine, mine.encode(),
          source: C7Source.proposalLive, ownProposal: true);
      expect(echo.row, C7Row.lostRace);
      expect(echo.book.ownNotice, 'lost');
    });

    test('the state survives its JSON form; malformed reads as closed', () {
      final (:book, create: _) = fullChannel();
      final stored =
          book.rekey(8, key(9)).markUnsure(9).copyWith(ownNotice: 'stale');
      final back = C7ChannelBook.decode(stored.encode(), channel, groupId);
      expect(back.encode(), stored.encode());
      expect(back.status, C7Status.unsure);
      expect(back.chain.missEpoch, 9);
      expect(back.ownNotice, 'stale');
      for (final bad in <String>[
        '{',
        '{"v":2}',
        stored.encode().replaceFirst('"channel":"chan-1"', '"channel":"x"'),
      ]) {
        final read = C7ChannelBook.decode(bad, channel, groupId);
        expect(read.status, C7Status.closed, reason: bad);
        expect(read.sealGenAt(9), isNull);
      }
      expect(C7ChannelBook.decode(null, channel, groupId).hasHead, isFalse);
    });
  });

  group('group state', () {
    test('v2 survives its JSON form and v1 still reads', () {
      final (:book, create: _) = fullChannel();
      final state = C7GroupState.joined(4, requestDueAtMs: 1000)
          .copyWith(channels: {channel}).withSnapshot(
              5, {channel: book.snapshot(5)}, 2000);
      final back = C7GroupState.decode(state.encode());
      expect(back.encode(), state.encode());
      expect(back.joinEpoch, 4);
      expect(back.duties[5]!.dueAtMs, 2000);
      expect(back.snapshots[5]![channel]!.key, key(7));
      final v1 = C7GroupState.decode(
          '{"v":1,"floor":3,"root_epoch":3,"root":"${base64Encode(key(1))}"}');
      expect(v1.floor, 3);
      expect(v1.root, key(1));
      expect(C7GroupState.decode('{"v":3,"floor":1}').floor, 0);
    });

    test('snapshots and duties keep only the newest commits', () {
      var state = C7GroupState.empty;
      for (var epoch = 1; epoch <= c7SnapshotLimit + 2; epoch++) {
        state = state.withSnapshot(epoch, const {}, epoch);
      }
      expect(state.snapshots.keys.toList()..sort(), [3, 4, 5, 6]);
      expect(state.duties.keys.toList()..sort(), [3, 4, 5, 6]);
      final settled =
          state.withDuty(6, const C7SyncDuty(dueAtMs: 6, settled: true));
      expect(settled.duties[6]!.settled, isTrue);
      expect(settled.duties[5]!.settled, isFalse);
    });
  });

  group('history_sync sizes', () {
    test('body0 pads to P(N) and the body length names N', () {
      expect(c7Body0PaddedLength(1), 768);
      expect(c7Body0PaddedLength(2), 768);
      expect(c7Body0PaddedLength(3), 1024);
      for (final n in <int>[1, 2, 3, 17, 64]) {
        final length = c7HistorySyncBodyLength(n);
        expect(length, c7Body0PaddedLength(n) + 124 + c7SlotBytes * n);
        expect(c7HistorySyncChannelCount(length), n);
        expect(c7HistorySyncChannelCount(length + 1), isNull);
      }
    });
  });
}
