import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/c7_channel_book.dart';
import 'package:private_messenger/crypto/c7_history.dart';
import 'package:private_messenger/crypto/c7_import.dart';
import 'package:private_messenger/crypto/c7_sync.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';
import 'package:private_messenger/crypto/crypto_service.dart' show C7HistoryRow;
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// Review M3: the backward walk read only the first slot that named a
/// generation, so a member could store a junk wrap ahead of the honest one
/// and cut a newcomer's history short. Every slot is read now; where they
/// disagree, every distinct wrap is a candidate and the AEAD decides.
void main() {
  final skip = nativeCryptoSkip();
  const community = 'comm';
  const conversation = 'grp-1';
  const channel = 'chan-1';
  Uint8List key(int fill) => Uint8List(32)..fillRange(0, 32, fill);
  final k1 = key(1), k3 = key(3), k5 = key(5), junk = key(9);

  test(
      'a disputed wrap keeps both candidates; an undisputed chain joins '
      'the book', () {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final create = C7Record(
      communityId: utf8.encode(community),
      channelId: utf8.encode(channel),
      seq: 0,
      prev: Uint8List(32),
      mode: c7ModeFull,
      reason: c7ReasonCreate,
      groupId: utf8.encode(conversation),
      epoch: 1,
      closeGroupId: utf8.encode(conversation),
      closeEpoch: 1,
      chkCommit: c7ChkCommitOf(k1),
      actorDeviceId: utf8.encode('dev-admin'),
      sig: Uint8List(64)..[0] = 1,
    );
    final created = C7ChannelBook.genesis(channel, conversation).applyRecord(
        create, create.encode(),
        source: C7Source.proposalLive, key: k1);
    expect(created.row, C7Row.adopt);
    // A newcomer at epoch 5 holds only the current generation.
    final book = created.book
        .copyWith(gens: [C7Gen(epoch: 5, groupId: conversation, key: k5)]);

    var ids = 0;
    C7HistoryRow sync(int current, Uint8List currentKey, int previous,
        Uint8List previousKey) {
      final actionId = 'act-${++ids}';
      final parts = c7BuildHistorySync(
        bindings: bindings,
        communityId: community,
        conversationId: conversation,
        senderDeviceId: 'dev-member',
        actionId: actionId,
        forEpoch: current,
        snapshot: <String, C7SlotSnapshot>{
          channel: C7SlotSnapshot(
            head: create.encode(),
            key: currentKey,
            entry: C7GenerationEntry(
              epoch: current,
              keyCommit: c7ChkCommitOf(currentKey),
              previousEpoch: previous,
              previousKey: previousKey,
            ).encode(),
          ),
        },
      );
      // The walk reads only the slots; body0's sealed part may be anything
      // of its size.
      final body = Uint8List(c7Body0PaddedLength(1) + 124 + parts.slots.length)
        ..setRange(c7Body0PaddedLength(1) + 124,
            c7Body0PaddedLength(1) + 124 + parts.slots.length, parts.slots);
      expect(c7HistorySyncChannelCount(body.length), 1);
      return C7HistoryRow(
        messageId: 'hist_$ids',
        senderDeviceId: 'dev-member',
        actionId: actionId,
        channelId: null,
        createdAt: DateTime.utc(2026),
        epoch: current,
        body: body,
      );
    }

    final honest5 = sync(5, k5, 3, k3);
    final honest3 = sync(3, k3, 1, k1);
    final junk5 = sync(5, k5, 3, junk);
    List<(int, int?, int)> shape(Iterable<C7Gen> gens) =>
        [for (final g in gens) (g.epoch, g.close, g.key!.first)];

    final clean = c7WalkBack(
        bindings: bindings,
        book: book,
        syncs: [honest5, honest3, honest5],
        communityId: community,
        conversationId: conversation);
    expect(shape(clean.book.gens), [(1, 3, 1), (3, 5, 3), (5, null, 5)]);
    expect(clean.candidates, isEmpty);

    // The junk wrap is stored after the honest one, so it is read first.
    final disputed = c7WalkBack(
        bindings: bindings,
        book: book,
        syncs: [junk5, honest5, honest3],
        communityId: community,
        conversationId: conversation);
    // Neither wrap joins the book; both are candidates, and the honest one
    // still leads back to the period's first generation.
    expect(shape(disputed.book.gens), [(5, null, 5)]);
    expect(shape(disputed.candidates), [(3, 5, 9), (3, 5, 3), (1, 3, 1)]);
  }, skip: skip);
}
