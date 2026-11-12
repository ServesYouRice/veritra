// C3 channel conversion (C7 decision 11, revised 2026-11-12 with the owner's
// answers): what this device knows of the moves of channels it can read,
// and the walk into the old group that a move's wrap starts. Design:
// docs/designs/C7-channel-history.md decision 11; docs/crypto.md, "C3
// channel conversion".
import 'dart:convert';
import 'dart:typed_data';

import 'c7_channel_book.dart';
import 'c7_history.dart';
import 'c7_sync.dart';
import 'crypto_service.dart' show C7HistoryRow;
import 'native_crypto_bindings.dart';

/// The setting that holds every [C7Move] this device knows.
const String c7MovesSetting = 'c7.moves';

/// At most this many moves are kept; the oldest go first.
const int c7MoveLimit = 64;

/// One move of [channelId] from [fromConversationId] to
/// [toConversationId], as the server's `conversation.channel_moved` event
/// or this device's own conversion told it.
final class C7Move {
  const C7Move({
    required this.channelId,
    required this.fromConversationId,
    required this.toConversationId,
    this.owed = false,
    this.wrapEpoch,
    this.wrapKey,
    this.wrapClose,
    this.imported = false,
  });

  final String channelId;
  final String fromConversationId;
  final String toConversationId;

  /// This device made the move and still owes its `move` record (sent once
  /// the new group's epoch is above 0, so the record's message seals under
  /// its own key and a later newcomer can open it).
  final bool owed;

  /// The old group's generation the move's wrap gave (a verified live
  /// record, or the move message a newcomer's import reached): its opening
  /// epoch and `CHK`. Null until then, or when the move had no wrap.
  final int? wrapEpoch;
  final Uint8List? wrapKey;

  /// The old group's epoch at the move (the record's `close_epoch`): no
  /// old-group post of a later epoch is taken.
  final int? wrapClose;

  /// The old group's posts were imported under [wrapKey].
  final bool imported;

  bool get importDue => wrapKey != null && !imported;

  bool same(C7Move other) =>
      channelId == other.channelId &&
      fromConversationId == other.fromConversationId &&
      toConversationId == other.toConversationId;

  C7Move copyWith({
    bool? owed,
    int? wrapEpoch,
    Uint8List? wrapKey,
    int? wrapClose,
    bool? imported,
  }) =>
      C7Move(
        channelId: channelId,
        fromConversationId: fromConversationId,
        toConversationId: toConversationId,
        owed: owed ?? this.owed,
        wrapEpoch: wrapEpoch ?? this.wrapEpoch,
        wrapKey: wrapKey ?? this.wrapKey,
        wrapClose: wrapClose ?? this.wrapClose,
        imported: imported ?? this.imported,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'channel': channelId,
        'from': fromConversationId,
        'to': toConversationId,
        if (owed) 'owed': true,
        if (wrapEpoch != null) 'wrap_epoch': wrapEpoch,
        if (wrapKey != null) 'wrap_key': base64Encode(wrapKey!),
        if (wrapClose != null) 'wrap_close': wrapClose,
        if (imported) 'imported': true,
      };

  static C7Move? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final channel = raw['channel'];
    final from = raw['from'];
    final to = raw['to'];
    final epoch = raw['wrap_epoch'];
    final key = raw['wrap_key'];
    final close = raw['wrap_close'];
    if (channel is! String || from is! String || to is! String) return null;
    if ((epoch == null) != (key == null) ||
        (epoch == null) != (close == null)) {
      return null;
    }
    if (epoch != null &&
        (epoch is! int || close is! int || epoch < 0 || close < epoch)) {
      return null;
    }
    Uint8List? wrapKey;
    if (key != null) {
      if (key is! String) return null;
      try {
        wrapKey = base64Decode(key);
      } on FormatException {
        return null;
      }
      if (wrapKey.length != 32) return null;
    }
    return C7Move(
      channelId: channel,
      fromConversationId: from,
      toConversationId: to,
      owed: raw['owed'] == true,
      wrapEpoch: epoch as int?,
      wrapKey: wrapKey,
      wrapClose: close as int?,
      imported: raw['imported'] == true,
    );
  }

  static List<C7Move> decodeAll(String? text) {
    if (text == null) return const <C7Move>[];
    try {
      final raw = jsonDecode(text);
      if (raw is! List) return const <C7Move>[];
      return <C7Move>[
        for (final item in raw)
          if (tryParse(item) case final move?) move,
      ];
    } on FormatException {
      return const <C7Move>[];
    }
  }

  static String encodeAll(List<C7Move> moves) {
    final kept = moves.length > c7MoveLimit
        ? moves.sublist(moves.length - c7MoveLimit)
        : moves;
    return jsonEncode(<Object?>[for (final move in kept) move.toJson()]);
  }
}

/// The old group's generations behind a move's wrap: [start] (the wrap's
/// generation, open-ended: the server's cutoff bounds it) and, walking back
/// through the old group's stored `history_sync` slots, every earlier
/// generation of the same period that exactly one wrap names. A slot is
/// taken only when its entry names the generation it is sealed under and
/// its head is a `full` record of this channel in the old group; the
/// head's epoch bounds the walk, as in [c7WalkBack]. A dispute (two
/// different wraps) stops the walk there: a gap, never a leak.
///
/// The slot's head is taken as the floor without checking its record
/// signature: only a holder of the old generation key can write a slot
/// that opens, and a signature would not stop such a member from placing
/// a genuine older head (see the C7 design, "Moved slot heads"). What it
/// gains equals leaking the keys it holds.
List<C7Gen> c7WalkMoved({
  required NativeCryptoBindings bindings,
  required C7Gen start,
  required Iterable<C7HistoryRow> syncs,
  required String communityId,
  required String fromConversationId,
  required String channelId,
}) {
  final stored = <C7HistoryRow>[
    for (final row in syncs)
      if (row.channelId == null) row,
  ];
  var gens = <C7Gen>[start];
  int? floor;
  while (gens.length < 1024) {
    final gen = gens.first;
    final key = gen.key;
    if (key == null) break;
    final found = <C7Gen>[];
    for (final row in stored) {
      final plain = c7TryStoredSlot(
        bindings: bindings,
        sealedBody: row.body,
        key: key,
        communityId: communityId,
        conversationId: fromConversationId,
        channelId: channelId,
        senderDeviceId: row.senderDeviceId,
        actionId: row.actionId,
      );
      if (plain == null) continue;
      try {
        final head =
            C7Record.decode(Uint8List.sublistView(plain, 0, c7RecordBytes));
        final entry = C7GenerationEntry.decode(
            Uint8List.sublistView(plain, c7RecordBytes, c7SlotPlainBytes));
        if (entry == null ||
            head.mode != c7ModeFull ||
            utf8.decode(head.groupId) != fromConversationId ||
            utf8.decode(head.channelId) != channelId ||
            entry.epoch != gen.epoch ||
            !c7SameBytes(entry.keyCommit, c7ChkCommitOf(key))) {
          continue;
        }
        final bound = floor ?? head.epoch;
        floor = bound;
        final previous = entry.previousEpoch;
        final previousKey = entry.previousKey;
        if (previous == null ||
            previousKey == null ||
            previous >= gen.epoch ||
            previous < bound ||
            (previous == bound &&
                !c7SameBytes(c7ChkCommitOf(previousKey), head.chkCommit))) {
          continue;
        }
        if (!found.any(
            (g) => g.epoch == previous && c7SameBytes(g.key!, previousKey))) {
          found.add(C7Gen(
            epoch: previous,
            groupId: fromConversationId,
            key: Uint8List.fromList(previousKey),
            close: gen.epoch,
          ));
        }
      } on FormatException {
        continue;
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    }
    if (found.length != 1) break;
    gens = <C7Gen>[found.single, ...gens];
  }
  return gens;
}
