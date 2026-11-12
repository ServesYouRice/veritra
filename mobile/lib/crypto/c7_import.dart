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

// The pre-join attachment placeholder lives with the history snapshot
// reader, which must accept it (K1 backups, K2 link bundles).
export '../storage/history_snapshot.dart' show c7HiddenAttachmentBody;

/// The first page per stream (owner answer Q1): at most this many bodies...
const int c7FirstPagePosts = 1000;

/// ...or this many body bytes, whichever comes first.
const int c7FirstPageBytes = 8 * 1024 * 1024;

/// Bodies per history request.
const int c7HistoryRequestLimit = 100;

/// The most candidate generations the walk keeps where stored slots
/// disagree (review M3).
const int c7WalkCandidateLimit = 32;

/// The walk through the stored `history_sync` messages in [syncs] for
/// [book] (decision 5, "Generation entry and backward walk"): starting from
/// the oldest generation held, a slot that opens under its key and whose
/// entry names it (its `E_cur` and key commitment) with a non-zero wrap
/// `E_prev < E_g` adds the previous generation, closing at `E_g`. Repeats
/// until nothing is added. Never reaches before the period's record (its
/// epoch, and at that epoch the record's own key commitment), and only in
/// [conversationId]'s own group.
///
/// Review M3: every slot is read, not the first that matches. While all
/// slots that name a generation agree on its previous key, it joins
/// [book]'s generations, as before. Where they disagree (a member stored a
/// junk wrap), the walk keeps each distinct previous key, and the walks
/// back from them, as `candidates` (at most [c7WalkCandidateLimit]): the
/// import tries every candidate whose window holds a body's epoch and the
/// AEAD decides. Candidates never join the book, so a key whose wrap was
/// disputed is never handed on.
({C7ChannelBook book, List<C7Gen> candidates}) c7WalkBack({
  required NativeCryptoBindings bindings,
  required C7ChannelBook book,
  required Iterable<C7HistoryRow> syncs,
  required String communityId,
  required String conversationId,
}) {
  final none = (book: book, candidates: const <C7Gen>[]);
  final head = book.headRecord;
  if (book.mode != c7ModeFull || head == null || book.gens.isEmpty) {
    return none;
  }
  if (utf8.decode(head.groupId) != conversationId) return none;
  final stored = <C7HistoryRow>[
    for (final row in syncs)
      if (row.channelId == null) row,
  ];
  // The distinct previous generations the stored slots give for [gen].
  List<C7Gen> previousOf(C7Gen gen) {
    final key = gen.key;
    if (key == null ||
        gen.groupId != conversationId ||
        gen.epoch <= head.epoch) {
      return const <C7Gen>[];
    }
    final found = <C7Gen>[];
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
          entry.epoch == gen.epoch &&
          c7SameBytes(entry.keyCommit, c7ChkCommitOf(key)) &&
          previous < gen.epoch &&
          previous >= head.epoch &&
          (previous != head.epoch ||
              c7SameBytes(c7ChkCommitOf(previousKey), head.chkCommit));
      if (adopt &&
          !found.any(
              (g) => g.epoch == previous && c7SameBytes(g.key!, previousKey))) {
        found.add(C7Gen(
          epoch: previous,
          groupId: conversationId,
          key: Uint8List.fromList(previousKey),
          close: gen.epoch,
        ));
      }
      plain.fillRange(0, plain.length, 0);
    }
    return found;
  }

  var gens = book.gens;
  var frontier = <C7Gen>[];
  while (true) {
    final found = previousOf(gens.first);
    if (found.length == 1) {
      gens = <C7Gen>[found.single, ...gens];
      continue;
    }
    frontier = found;
    break;
  }
  final candidates = <C7Gen>[];
  while (frontier.isNotEmpty && candidates.length < c7WalkCandidateLimit) {
    final gen = frontier.removeAt(0);
    candidates.add(gen);
    frontier.addAll(previousOf(gen));
  }
  return (
    book: gens.length == book.gens.length ? book : book.copyWith(gens: gens),
    candidates: candidates,
  );
}

/// A newcomer's import state in one group (`c7ImportSetting`): for each
/// stream fetched, the oldest history message fetched so far (the cursor
/// "Load earlier posts" pages before) or null once the route had nothing
/// older, and the former-member keys fetched at join. Cleared by the re-add
/// wipe with the rest of the group's C7 state.
final class C7ImportState {
  C7ImportState({
    required Map<String, String?> cursors,
    required List<C7FormerKey> keys,
    Map<String, List<C7Gen>> candidates = const <String, List<C7Gen>>{},
  })  : cursors = Map<String, String?>.unmodifiable(cursors),
        keys = List<C7FormerKey>.unmodifiable(keys),
        candidates = Map<String, List<C7Gen>>.unmodifiable(candidates);

  static final C7ImportState empty = C7ImportState(
      cursors: const <String, String?>{}, keys: const <C7FormerKey>[]);

  /// By channel id (`''` for the group-level stream).
  final Map<String, String?> cursors;
  final List<C7FormerKey> keys;

  /// By channel id: the walk's disputed generations ([c7WalkBack]), tried
  /// for later pages too.
  final Map<String, List<C7Gen>> candidates;

  String encode() => jsonEncode(<String, Object?>{
        'v': 1,
        'cursors': cursors,
        'keys': <Object?>[
          for (final key in keys)
            <Object?>[key.deviceId, key.accountId, base64Encode(key.signingKey)]
        ],
        if (candidates.isNotEmpty)
          'candidates': <String, Object?>{
            for (final entry in candidates.entries)
              entry.key: <Object?>[for (final gen in entry.value) gen.toJson()],
          },
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
        candidates: <String, List<C7Gen>>{
          for (final entry
              in ((map['candidates'] as Map?) ?? const <String, Object?>{})
                  .entries)
            entry.key as String: <C7Gen>[
              for (final gen in entry.value as List) C7Gen.fromJson(gen)
            ],
        },
      );
    } on Object {
      return empty;
    }
  }
}
