// C7 `history_sync` body layout and record signing (docs/designs/
// C7-channel-history.md decision 5, "history_sync body layout", and
// decision 3). Pure functions over the ABI 13 primitives: no state, no
// storage. Vector: testing/vectors/c7-sync-v1.json (Rust, Go and Dart).
//
//   sealed_body = body0 | slot_1 | ... | slot_N
//   body0  = the normal body framing; its VAP1 is the hidden W7 type
//            history_sync {for_epoch, channels: [[id, base64(key)], ...]},
//            ids sorted bytewise, padded to exactly P(N)
//   slot_i = c7_seal(slot_key(key_i, community, id_i, sender, action),
//                    body aad, head record (512) | generation entry (128))
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'app_payload.dart';
import 'c7_channel_book.dart';
import 'c7_history.dart';
import 'c7_keys.dart';
import 'c7_two_part.dart';
import 'native_crypto_bindings.dart';

/// The record signature's domain (Rust prepends it).
const String c7HistorySignatureDomain = 'veritra-c7-history-v1';

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// Channel ids sorted bytewise (UTF-8), as body0 lists them.
List<String> c7SortedChannels(Iterable<String> ids) => ids.toSet().toList()
  ..sort((a, b) => _compareBytes(utf8.encode(a), utf8.encode(b)));

/// The parts of a `history_sync` before the two-part seal: body0's padded
/// VAP1 and the slots that follow it.
final class C7SyncParts {
  const C7SyncParts(this.body0, this.slots, this.channels);
  final Uint8List body0;
  final Uint8List slots;
  final List<String> channels;
}

/// Builds a `history_sync` for [forEpoch] from the slot snapshots fixed at
/// that merge. A channel whose snapshot gives no key gets a fresh random
/// `key_c` (its slot holds its head with a zero entry). [extraChannels] are
/// channels this device knows of with no state (zero head, zero entry).
C7SyncParts c7BuildHistorySync({
  required NativeCryptoBindings bindings,
  required String communityId,
  required String conversationId,
  required String senderDeviceId,
  required String actionId,
  required int forEpoch,
  required Map<String, C7SlotSnapshot> snapshot,
  Iterable<String> extraChannels = const <String>[],
  Random? random,
}) {
  final source = random ?? Random.secure();
  final channels = c7SortedChannels(<String>[
    ...snapshot.keys,
    ...extraChannels,
  ]);
  if (channels.isEmpty) throw ArgumentError('a history_sync names channels');
  final keys = C7Keys(bindings);
  final aad = C7Keys.bodyAad(
    conversationId: conversationId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
  );
  final entries = <List<Object?>>[];
  final slots = BytesBuilder(copy: false);
  for (final channel in channels) {
    final slot = snapshot[channel] ??
        C7SlotSnapshot(
          head: Uint8List(c7RecordBytes),
          key: null,
          entry: Uint8List(c7EntryBytes),
        );
    final key = slot.key ??
        Uint8List.fromList(List<int>.generate(32, (_) => source.nextInt(256)));
    entries.add(<Object?>[channel, base64Encode(key)]);
    final slotKey = keys.slotKey(
      chk: key,
      communityId: communityId,
      channelId: channel,
      senderDeviceId: senderDeviceId,
      actionId: actionId,
    );
    try {
      slots.add(bindings.c7Seal(key: slotKey, aad: aad, plaintext: slot.plain));
    } finally {
      slotKey.fillRange(0, slotKey.length, 0);
    }
  }
  final body0 = AppPayloadCodec(random: source).encode(
    type: AppPayloadType.historySync,
    conversationId: conversationId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
    body: <String, Object?>{'for_epoch': forEpoch, 'channels': entries},
    hidden: true,
    paddedLength: c7Body0PaddedLength(channels.length),
  );
  return C7SyncParts(body0, slots.takeBytes(), channels);
}

/// One slot a live member opened with body0's key.
final class C7OpenedSlot {
  const C7OpenedSlot(this.channelId, this.key, this.plain);
  final String channelId;
  final Uint8List key;

  /// `head (512) | entry (128)`.
  final Uint8List plain;

  Uint8List get head => Uint8List.sublistView(plain, 0, c7RecordBytes);
  Uint8List get entry =>
      Uint8List.sublistView(plain, c7RecordBytes, c7SlotPlainBytes);
  bool get headIsZero => head.every((b) => b == 0);
}

/// Opens every slot of a live `history_sync` with the keys body0 lists
/// ([body] is body0's `body`). Null unless body0 parses and every slot opens
/// (decision 5: a valid `history_sync` means body0 and every slot open).
List<C7OpenedSlot>? c7OpenSlots({
  required NativeCryptoBindings bindings,
  required Map<String, Object?> body,
  required Uint8List trailer,
  required String communityId,
  required String conversationId,
  required String senderDeviceId,
  required String actionId,
}) {
  if (!isValidC7SyncBody(body)) return null;
  final channels = body['channels']! as List;
  if (trailer.length != channels.length * c7SlotBytes) return null;
  final keys = C7Keys(bindings);
  final aad = C7Keys.bodyAad(
    conversationId: conversationId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
  );
  final out = <C7OpenedSlot>[];
  for (var i = 0; i < channels.length; i++) {
    final entry = channels[i] as List;
    final channel = entry[0] as String;
    final key = Uint8List.fromList(base64Decode(entry[1] as String));
    final slotKey = keys.slotKey(
      chk: key,
      communityId: communityId,
      channelId: channel,
      senderDeviceId: senderDeviceId,
      actionId: actionId,
    );
    try {
      final plain = bindings.c7Open(
        key: slotKey,
        aad: aad,
        sealed: Uint8List.sublistView(
            trailer, i * c7SlotBytes, (i + 1) * c7SlotBytes),
      );
      if (plain == null || plain.length != c7SlotPlainBytes) return null;
      out.add(C7OpenedSlot(channel, key, Uint8List.fromList(plain)));
    } on Object {
      return null;
    } finally {
      slotKey.fillRange(0, slotKey.length, 0);
    }
  }
  return out;
}

/// A stored `history_sync` read without body0's key (a newcomer's backward
/// walk): tries [key] as [channelId]'s `key_c` on every slot after body0 and
/// returns the slot plaintext whose commitment matches, or null.
Uint8List? c7TryStoredSlot({
  required NativeCryptoBindings bindings,
  required Uint8List sealedBody,
  required Uint8List key,
  required String communityId,
  required String conversationId,
  required String channelId,
  required String senderDeviceId,
  required String actionId,
}) {
  final n = c7HistorySyncChannelCount(sealedBody.length);
  if (n == null) return null;
  final start = c7Body0PaddedLength(n) + 124;
  final keys = C7Keys(bindings);
  final aad = C7Keys.bodyAad(
    conversationId: conversationId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
  );
  final slotKey = keys.slotKey(
    chk: key,
    communityId: communityId,
    channelId: channelId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
  );
  try {
    for (var i = 0; i < n; i++) {
      final at = start + i * c7SlotBytes;
      try {
        final plain = bindings.c7Open(
          key: slotKey,
          aad: aad,
          sealed: Uint8List.sublistView(sealedBody, at, at + c7SlotBytes),
        );
        if (plain != null && plain.length == c7SlotPlainBytes) {
          return Uint8List.fromList(plain);
        }
      } on Object {
        return null;
      }
    }
    return null;
  } finally {
    slotKey.fillRange(0, slotKey.length, 0);
  }
}

/// Checks a record's signature against [publicKey] (a key in the current
/// tree; decision 4 and owner decision B).
bool c7VerifyRecord(
    NativeCryptoBindings bindings, C7Record record, Uint8List publicKey) {
  try {
    return bindings.c7Verify(
      domain: c7HistorySignatureDomain,
      publicKey: publicKey,
      message: record.signedFields(),
      signature: record.sig,
    );
  } on Object {
    return false;
  }
}

/// The 128-byte wrap a narrowing move carries (decision 11): the old group's
/// current generation `u64 E_prev | CHK_prev[32] | lp(prev_group_id) |
/// u64 E_prev_close`, zero-padded. Null when [wrap] is not one (a widening
/// move's 128 random bytes do not parse, or parse with a zero key).
({int epoch, Uint8List key, String groupId, int close})? c7DecodeMoveWrap(
    List<int> wrap) {
  if (wrap.length != c7MoveWrapBytes) return null;
  final bytes = Uint8List.fromList(wrap);
  final data = ByteData.sublistView(bytes);
  int u64(int at) {
    final high = data.getUint32(at, Endian.big);
    if (high > 0x1fffff) throw const FormatException('C7 epoch too large');
    return high * 0x100000000 + data.getUint32(at + 4, Endian.big);
  }

  try {
    final epoch = u64(0);
    final key = Uint8List.fromList(bytes.sublist(8, 40));
    final length = data.getUint16(40, Endian.big);
    if (length == 0 || length > 64 || 42 + length + 8 > c7MoveWrapBytes) {
      return null;
    }
    final group = utf8.decode(bytes.sublist(42, 42 + length));
    final close = u64(42 + length);
    if (bytes.sublist(50 + length).any((b) => b != 0)) return null;
    if (key.every((b) => b == 0) || close <= epoch) return null;
    return (epoch: epoch, key: key, groupId: group, close: close);
  } on Object {
    return null;
  }
}

/// Encodes a narrowing move's wrap (see [c7DecodeMoveWrap]).
Uint8List c7EncodeMoveWrap({
  required int epoch,
  required List<int> key,
  required String groupId,
  required int close,
}) {
  final group = utf8.encode(groupId);
  if (key.length != 32 || group.isEmpty || group.length > 64) {
    throw ArgumentError('invalid C7 move wrap');
  }
  final out = Uint8List(c7MoveWrapBytes);
  final data = ByteData.sublistView(out);
  data
    ..setUint32(0, epoch ~/ 0x100000000, Endian.big)
    ..setUint32(4, epoch % 0x100000000, Endian.big);
  out.setRange(8, 40, key);
  data.setUint16(40, group.length, Endian.big);
  out.setRange(42, 42 + group.length, group);
  data
    ..setUint32(42 + group.length, close ~/ 0x100000000, Endian.big)
    ..setUint32(46 + group.length, close % 0x100000000, Endian.big);
  return out;
}
