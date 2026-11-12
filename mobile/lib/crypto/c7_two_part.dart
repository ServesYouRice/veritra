// C7 build step 4, first slice: the two-part send and receive
// (docs/designs/C7-channel-history.md, "Core idea: seal once, choose the
// key"). Every application message in a community conversation is an MLS
// reference `"C7R1" | body_key[32] | sha256(sealed_body)[32]` plus a sealed
// body stored beside the envelope.
//
// A body is sealed under a random `body_key` unless the sender holds the
// channel as `full` and `ok`, when the key is derived from the current
// generation's `CHK` (decision 3). Live members read either the same way;
// newcomers open only what a generation key they hold derives.
import 'dart:math';
import 'dart:typed_data';

import 'c7_keys.dart';
import 'native_crypto_bindings.dart';
import 'sha256.dart';

/// `"C7R1"`.
const List<int> c7ReferenceMagic = <int>[0x43, 0x37, 0x52, 0x31];

/// The reference is 68 bytes for every message.
const int c7ReferenceBytes = 68;

/// The post signature's domain (Rust prepends it).
const String c7PostSignatureDomain = 'veritra-c7-post-sig-v1';

/// A decoded reference: the body's key and the hash that binds the body.
final class C7Reference {
  const C7Reference(this.bodyKey, this.bodyHash);
  final Uint8List bodyKey;
  final Uint8List bodyHash;
}

/// `"C7R1" | body_key | sha256(sealed_body)`.
Uint8List encodeC7Reference(List<int> bodyKey, List<int> sealedBody) {
  if (bodyKey.length != 32) throw ArgumentError('body key must be 32 bytes');
  return Uint8List.fromList(
      <int>[...c7ReferenceMagic, ...bodyKey, ...sha256(sealedBody)]);
}

/// The reference in a decrypted MLS plaintext, or null when the plaintext is
/// not one (a VAP1 payload from a sender that does not send two parts).
C7Reference? parseC7Reference(List<int> plaintext) {
  if (plaintext.length != c7ReferenceBytes) return null;
  for (var i = 0; i < c7ReferenceMagic.length; i++) {
    if (plaintext[i] != c7ReferenceMagic[i]) return null;
  }
  return C7Reference(
    Uint8List.fromList(plaintext.sublist(4, 36)),
    Uint8List.fromList(plaintext.sublist(36, 68)),
  );
}

List<int> _u64(int value) {
  if (value < 0) throw ArgumentError('C7 u64 is negative');
  final data = ByteData(8)
    ..setUint32(0, value ~/ 0x100000000, Endian.big)
    ..setUint32(4, value % 0x100000000, Endian.big);
  return data.buffer.asUint8List();
}

/// The bytes the post signature covers after its domain:
/// `lp(community_id) | lp(channel_id) | lp(action_id) | lp(group_id) |
/// u64(epoch) | lp(sender_device_id) | u64(gen) | sha256(padded VAP1)`.
Uint8List c7PostSignedFields({
  required String communityId,
  required String channelId,
  required String actionId,
  required String groupId,
  required int epoch,
  required String senderDeviceId,
  required int generation,
  required List<int> paddedVap1,
}) =>
    Uint8List.fromList(<int>[
      ...c7Lp(communityId),
      ...c7Lp(channelId),
      ...c7Lp(actionId),
      ...c7Lp(groupId),
      ..._u64(epoch),
      ...c7Lp(senderDeviceId),
      ..._u64(generation),
      ...sha256(paddedVap1),
    ]);

/// One message sealed in two parts.
final class C7SealedMessage {
  const C7SealedMessage({required this.reference, required this.sealedBody});

  /// What MLS encrypts (68 bytes).
  final Uint8List reference;

  /// What the envelope carries as `sealed_body`.
  final Uint8List sealedBody;
}

/// Seals [paddedVap1] in two parts. With [chk] the body key is the post key
/// of that generation key and the signature names [generation] (`E_g`: a
/// `full` channel that is `ok`); without it, a fresh random body key and
/// generation 0 (every other case, decision 3 and I4). [trailer] is appended
/// after the sealed VAP1 and covered by the reference's hash (a
/// `history_sync`'s slots). [sign] is the device's `c7Sign`. The sender keeps
/// both parts in its outbox and resends them unchanged; an action is never
/// sealed twice.
C7SealedMessage c7SealMessage({
  required NativeCryptoBindings bindings,
  required Uint8List Function(List<int> message) sign,
  required String communityId,
  required String conversationId,
  required String? channelId,
  required String senderDeviceId,
  required String actionId,
  required int epoch,
  required List<int> paddedVap1,
  Uint8List? chk,
  int generation = 0,
  List<int> trailer = const <int>[],
  Random? random,
}) {
  if ((chk == null) != (generation == 0) ||
      (chk != null && channelId == null)) {
    throw ArgumentError('a generation key needs its channel and generation');
  }
  final source = random ?? Random.secure();
  final keys = C7Keys(bindings);
  final bodyKey = chk == null
      ? Uint8List.fromList(List<int>.generate(32, (_) => source.nextInt(256)))
      : keys.postBodyKey(
          chk: chk,
          communityId: communityId,
          channelId: channelId!,
          senderDeviceId: senderDeviceId,
          actionId: actionId,
        );
  try {
    final signature = sign(c7PostSignedFields(
      communityId: communityId,
      channelId: channelId ?? '',
      actionId: actionId,
      groupId: conversationId,
      epoch: epoch,
      senderDeviceId: senderDeviceId,
      generation: generation,
      paddedVap1: paddedVap1,
    ));
    final body = keys.sealBody(
      bodyKey: bodyKey,
      aad: C7Keys.bodyAad(
        conversationId: conversationId,
        channelId: channelId,
        senderDeviceId: senderDeviceId,
        actionId: actionId,
      ),
      signature: signature,
      paddedVap1: paddedVap1,
    );
    final sealed = trailer.isEmpty
        ? body
        : (Uint8List(body.length + trailer.length)
          ..setRange(0, body.length, body)
          ..setRange(body.length, body.length + trailer.length, trailer));
    return C7SealedMessage(
      reference: encodeC7Reference(bodyKey, sealed),
      sealedBody: sealed,
    );
  } finally {
    bodyKey.fillRange(0, bodyKey.length, 0);
  }
}

/// `P(N) = 256 * ceil((512 + 128 N) / 256)`: the padded VAP1 of a
/// `history_sync`'s body0 for [channels] channels.
int c7Body0PaddedLength(int channels) =>
    ((512 + 128 * channels + 255) ~/ 256) * 256;

/// `P(N) + 124 + 700 N`: the sealed body of a `history_sync`.
int c7HistorySyncBodyLength(int channels) =>
    c7Body0PaddedLength(channels) + 124 + 700 * channels;

/// The `N` a `history_sync` body of [length] bytes names, or null.
int? c7HistorySyncChannelCount(int length) {
  for (var n = 1; c7Body0PaddedLength(n) <= 65536; n++) {
    final expected = c7HistorySyncBodyLength(n);
    if (expected == length) return n;
    if (expected > length) return null;
  }
  return null;
}

/// A live member's open of a two-part message: the padded VAP1 and, for a
/// `history_sync`, the slots after body0 ([trailer], empty otherwise).
final class C7Opened {
  const C7Opened(this.paddedVap1, this.trailer, {required this.bodyKey});
  final Uint8List paddedVap1;
  final Uint8List trailer;

  /// The reference's body key, kept so the receiver can tell which
  /// generation sealed the body (the `unsure` trigger); the caller wipes it.
  final Uint8List bodyKey;
}

/// A live member's open: the body must hash to the reference and open under
/// its key, bound to the envelope's own fields. Returns null for a missing,
/// swapped or damaged body (a P1 `invalid` row: the MLS state and cursor
/// still commit, so a server that strips a body cannot stop the
/// conversation). No signature check: MLS authenticated the reference,
/// which fixes the body (decision 8). A group-level body whose length is a
/// `history_sync`'s opens body0 alone when the whole body does not open, and
/// the rest is returned as the slots.
C7Opened? c7OpenLiveParts({
  required NativeCryptoBindings bindings,
  required C7Reference reference,
  required List<int>? sealedBody,
  required String conversationId,
  required String? channelId,
  required String senderDeviceId,
  required String actionId,
}) {
  final body = sealedBody;
  if (body == null || body.isEmpty) return null;
  final hash = sha256(body);
  var diff = 0;
  for (var i = 0; i < hash.length; i++) {
    diff |= hash[i] ^ reference.bodyHash[i];
  }
  if (diff != 0) return null;
  final keys = C7Keys(bindings);
  final aad = C7Keys.bodyAad(
    conversationId: conversationId,
    channelId: channelId,
    senderDeviceId: senderDeviceId,
    actionId: actionId,
  );
  final bytes = Uint8List.fromList(body);
  ({Uint8List signature, Uint8List paddedVap1})? tryOpen(Uint8List sealed) {
    try {
      return keys.openBody(
          bodyKey: reference.bodyKey, aad: aad, sealed: sealed);
    } on Object {
      return null;
    }
  }

  if (bytes.length <= 65536 + 124) {
    final whole = tryOpen(bytes);
    if (whole != null) {
      return C7Opened(Uint8List.fromList(whole.paddedVap1), Uint8List(0),
          bodyKey: Uint8List.fromList(reference.bodyKey));
    }
  }
  final n = channelId == null ? c7HistorySyncChannelCount(bytes.length) : null;
  if (n == null) return null;
  final split = c7Body0PaddedLength(n) + 124;
  final first = tryOpen(Uint8List.sublistView(bytes, 0, split));
  if (first == null) return null;
  return C7Opened(Uint8List.fromList(first.paddedVap1),
      Uint8List.fromList(Uint8List.sublistView(bytes, split)),
      bodyKey: Uint8List.fromList(reference.bodyKey));
}

/// [c7OpenLiveParts] for a message that is not a `history_sync`: the padded
/// VAP1 only. Wipes the reference's key.
Uint8List? c7OpenLive({
  required NativeCryptoBindings bindings,
  required C7Reference reference,
  required List<int>? sealedBody,
  required String conversationId,
  required String? channelId,
  required String senderDeviceId,
  required String actionId,
}) {
  try {
    final opened = c7OpenLiveParts(
      bindings: bindings,
      reference: reference,
      sealedBody: sealedBody,
      conversationId: conversationId,
      channelId: channelId,
      senderDeviceId: senderDeviceId,
      actionId: actionId,
    );
    if (opened == null) return null;
    opened.bodyKey.fillRange(0, 32, 0);
    return opened.trailer.isEmpty ? opened.paddedVap1 : null;
  } finally {
    reference.bodyKey.fillRange(0, reference.bodyKey.length, 0);
  }
}

/// Whether a conversation kind carries two-part messages: a community's
/// shared group, a private channel's group or a legacy channel (the server's
/// rule, `server/internal/storage/c7_body_store.go`).
bool c7CommunityKind(String? kind) =>
    kind == 'community_shared' || kind == 'community_channel';
