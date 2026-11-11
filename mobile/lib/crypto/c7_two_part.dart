// C7 build step 4, first slice: the two-part send and receive
// (docs/designs/C7-channel-history.md, "Core idea: seal once, choose the
// key"). Every application message in a community conversation is an MLS
// reference `"C7R1" | body_key[32] | sha256(sealed_body)[32]` plus a sealed
// body stored beside the envelope.
//
// This slice seals every body under a random `body_key`: the behaviour of a
// `members_from_join` channel, which is every channel until C7 records exist
// (the implicit genesis, decision 3). Live members read as before; newcomers
// can open nothing, which is exactly `members_from_join`. Generation keys,
// records and `history_sync` (the `full` mode) are later slices.
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

/// Seals [paddedVap1] under a fresh random body key (the `members_from_join`
/// case, generation 0). [sign] is the device's `c7Sign`. The sender keeps
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
  Random? random,
}) {
  final source = random ?? Random.secure();
  final bodyKey =
      Uint8List.fromList(List<int>.generate(32, (_) => source.nextInt(256)));
  try {
    final signature = sign(c7PostSignedFields(
      communityId: communityId,
      channelId: channelId ?? '',
      actionId: actionId,
      groupId: conversationId,
      epoch: epoch,
      senderDeviceId: senderDeviceId,
      generation: 0,
      paddedVap1: paddedVap1,
    ));
    final sealed = C7Keys(bindings).sealBody(
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
    return C7SealedMessage(
      reference: encodeC7Reference(bodyKey, sealed),
      sealedBody: sealed,
    );
  } finally {
    bodyKey.fillRange(0, bodyKey.length, 0);
  }
}

/// A live member's open: the body must hash to the reference and open under
/// its key, bound to the envelope's own fields. Returns the padded VAP1, or
/// null for a missing, swapped or damaged body (a P1 `invalid` row: the MLS
/// state and cursor still commit, so a server that strips a body cannot stop
/// the conversation). No signature check: MLS authenticated the reference,
/// which fixes the body (decision 8).
Uint8List? c7OpenLive({
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
  try {
    final opened = C7Keys(bindings).openBody(
      bodyKey: reference.bodyKey,
      aad: C7Keys.bodyAad(
        conversationId: conversationId,
        channelId: channelId,
        senderDeviceId: senderDeviceId,
        actionId: actionId,
      ),
      sealed: Uint8List.fromList(body),
    );
    return opened == null ? null : Uint8List.fromList(opened.paddedVap1);
  } on Object {
    return null;
  } finally {
    reference.bodyKey.fillRange(0, reference.bodyKey.length, 0);
  }
}

/// Whether a conversation kind carries two-part messages: a community's
/// shared group, a private channel's group or a legacy channel (the server's
/// rule, `server/internal/storage/c7_body_store.go`).
bool c7CommunityKind(String? kind) =>
    kind == 'community_shared' || kind == 'community_channel';
