// C7 newcomer import (docs/designs/C7-channel-history.md decisions 5, 6, 8
// and 10): the backward walk through stored `history_sync` slots and the
// import state kept between the first page and later pages. The opening,
// signature checks and the two-pass apply live in the native crypto service,
// next to the live receive path they mirror.
import 'dart:convert';
import 'dart:typed_data';

import 'c7_channel_book.dart';
import 'c7_history.dart';
import 'c7_sync.dart';
import 'crypto_service.dart' show C7FormerKey, C7HistoryRow;
import 'native_crypto_bindings.dart';

/// The first page per stream (owner answer Q1): at most this many bodies...
const int c7FirstPagePosts = 1000;

/// ...or this many body bytes, whichever comes first.
const int c7FirstPageBytes = 8 * 1024 * 1024;

/// Bodies per history request.
const int c7HistoryRequestLimit = 100;

/// The stored body of a pre-join attachment post (owner answer Q2: never
/// offered). Not a JSON list, so no attachment entry, key or blob id ever
/// reaches the database and the timeline has nothing to download; it shows
/// the "from before you joined" placeholder instead.
const String c7HiddenAttachmentBody = '{"c7":"pre_join_attachment"}';

/// At most this many former-member post keys are kept for the mark.
const int c7FormerPostLimit = 20000;

/// The walk through the stored `history_sync` messages in [syncs] for
/// [book] (decision 5, "Generation entry and backward walk"): starting from
/// the oldest generation held, a slot that opens under its key and whose
/// entry names it (its `E_cur` and key commitment) with a non-zero wrap
/// `E_prev < E_g` adds the previous generation, closing at `E_g`. Repeats
/// until nothing is added. Never reaches before the period's record (its
/// epoch, and at that epoch the record's own key commitment), and only in
/// [conversationId]'s own group.
C7ChannelBook c7WalkBack({
  required NativeCryptoBindings bindings,
  required C7ChannelBook book,
  required Iterable<C7HistoryRow> syncs,
  required String communityId,
  required String conversationId,
}) {
  final head = book.headRecord;
  if (book.mode != c7ModeFull || head == null || book.gens.isEmpty) {
    return book;
  }
  if (utf8.decode(head.groupId) != conversationId) return book;
  final stored = <C7HistoryRow>[
    for (final row in syncs)
      if (row.channelId == null) row,
  ];
  var gens = book.gens;
  while (true) {
    final oldest = gens.first;
    final key = oldest.key;
    if (key == null ||
        oldest.groupId != conversationId ||
        oldest.epoch <= head.epoch) {
      break;
    }
    C7Gen? found;
    for (final row in stored) {
      final plain = c7TryStoredSlot(
        bindings: bindings,
        sealedBody: row.body,
        key: key,
        communityId: communityId,
        conversationId: conversationId,
        channelId: book.channelId,
        senderDeviceId: row.senderDeviceId,
        actionId: row.actionId,
      );
      if (plain == null) continue;
      C7GenerationEntry? entry;
      try {
        entry = C7GenerationEntry.decode(
            Uint8List.sublistView(plain, c7RecordBytes, c7SlotPlainBytes));
      } on FormatException {
        entry = null;
      }
      final previous = entry?.previousEpoch;
      final previousKey = entry?.previousKey;
      final adopt = entry != null &&
          previous != null &&
          previousKey != null &&
          entry.epoch == oldest.epoch &&
          c7SameBytes(entry.keyCommit, c7ChkCommitOf(key)) &&
          previous < oldest.epoch &&
          previous >= head.epoch &&
          (previous != head.epoch ||
              c7SameBytes(c7ChkCommitOf(previousKey), head.chkCommit));
      if (adopt) {
        found = C7Gen(
          epoch: previous,
          groupId: conversationId,
          key: previousKey,
          close: oldest.epoch,
        );
      }
      plain.fillRange(0, plain.length, 0);
      if (found != null) break;
    }
    if (found == null) break;
    gens = <C7Gen>[found, ...gens];
  }
  return gens.length == book.gens.length ? book : book.copyWith(gens: gens);
}

/// A newcomer's import state in one group (`c7ImportSetting`): for each
/// stream fetched, the oldest history message fetched so far (the cursor
/// "Load earlier posts" pages before) or null once the route had nothing
/// older; the former-member keys fetched at join; and the imported posts
/// verified with them.
final class C7ImportState {
  C7ImportState({
    required Map<String, String?> cursors,
    required List<C7FormerKey> keys,
    required Set<String> former,
  })  : cursors = Map<String, String?>.unmodifiable(cursors),
        keys = List<C7FormerKey>.unmodifiable(keys),
        former = Set<String>.unmodifiable(former);

  static final C7ImportState empty = C7ImportState(
      cursors: const <String, String?>{},
      keys: const <C7FormerKey>[],
      former: const <String>{});

  /// By channel id (`''` for the group-level stream).
  final Map<String, String?> cursors;
  final List<C7FormerKey> keys;
  final Set<String> former;

  C7ImportState copyWith({
    Map<String, String?>? cursors,
    List<C7FormerKey>? keys,
    Set<String>? former,
  }) {
    final kept = former ?? this.former;
    return C7ImportState(
      cursors: cursors ?? this.cursors,
      keys: keys ?? this.keys,
      former: kept.length <= c7FormerPostLimit
          ? kept
          : kept.skip(kept.length - c7FormerPostLimit).toSet(),
    );
  }

  String encode() => jsonEncode(<String, Object?>{
        'v': 1,
        'cursors': cursors,
        'keys': <Object?>[
          for (final key in keys)
            <Object?>[key.deviceId, key.accountId, base64Encode(key.signingKey)]
        ],
        'former': former.toList(),
      });

  /// Anything malformed reads as no import state: no paging, no keys.
  static C7ImportState decode(String? stored) {
    if (stored == null) return empty;
    try {
      final map = jsonDecode(stored) as Map;
      if (map['v'] != 1) return empty;
      return C7ImportState(
        cursors: <String, String?>{
          for (final entry in (map['cursors'] as Map).entries)
            entry.key as String: entry.value as String?,
        },
        keys: <C7FormerKey>[
          for (final raw in map['keys'] as List)
            C7FormerKey(
              deviceId: (raw as List)[0] as String,
              accountId: raw[1] as String,
              signingKey: Uint8List.fromList(base64Decode(raw[2] as String)),
            ),
        ],
        former: (map['former'] as List).cast<String>().toSet(),
      );
    } on Object {
      return empty;
    }
  }
}
