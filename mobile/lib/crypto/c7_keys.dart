// C7 key schedule and body sealing on top of the ABI 13 primitives. No state
// and no storage: the caller keeps the keys in the sealed local database in
// the same transaction as the MLS state (design decision 2 and "One local
// transaction"). Design: docs/designs/C7-channel-history.md revision 7.
import 'dart:convert';
import 'dart:typed_data';

import 'native_crypto_bindings.dart';

/// `lp(x)`: a u16 big-endian length, then the bytes. Empty is allowed here
/// (a group-level message has no channel).
List<int> c7Lp(String value) {
  final bytes = utf8.encode(value);
  if (bytes.length > 0xffff) throw ArgumentError('C7 field too long');
  return <int>[bytes.length >> 8, bytes.length & 0xff, ...bytes];
}

final class C7Keys {
  const C7Keys(this._bindings);

  final NativeCryptoBindings _bindings;

  /// The key of the generation a removal opens: `c7_derive(root,
  /// "veritra-c7-rekey-chk-v1", lp(community_id) | lp(channel_id))`. [root]
  /// is [C7CommitOutcome.root]; the caller wipes it afterwards.
  Uint8List rekeyChk({
    required Uint8List root,
    required String communityId,
    required String channelId,
  }) =>
      _bindings.c7Derive(
        key: root,
        label: 'veritra-c7-rekey-chk-v1',
        info: [...c7Lp(communityId), ...c7Lp(channelId)],
      );

  List<int> _messageInfo(String communityId, String channelId,
          String senderDeviceId, String actionId) =>
      [
        ...c7Lp(communityId),
        ...c7Lp(channelId),
        ...c7Lp(senderDeviceId),
        ...c7Lp(actionId),
      ];

  /// The body key of a post sealed under generation key [chk].
  Uint8List postBodyKey({
    required Uint8List chk,
    required String communityId,
    required String channelId,
    required String senderDeviceId,
    required String actionId,
  }) =>
      _bindings.c7Derive(
        key: chk,
        label: 'veritra-c7-post-v1',
        info: _messageInfo(communityId, channelId, senderDeviceId, actionId),
      );

  /// The key of one `history_sync` slot, sealed under that channel's `key_c`.
  Uint8List slotKey({
    required Uint8List chk,
    required String communityId,
    required String channelId,
    required String senderDeviceId,
    required String actionId,
  }) =>
      _bindings.c7Derive(
        key: chk,
        label: 'veritra-c7-slot-v1',
        info: _messageInfo(communityId, channelId, senderDeviceId, actionId),
      );

  /// `lp(conversation_id) | lp(channel_id or "") | lp(sender_device_id) |
  /// lp(action_id)`: the envelope's own fields, so the server cannot move a
  /// body.
  static Uint8List bodyAad({
    required String conversationId,
    String? channelId,
    required String senderDeviceId,
    required String actionId,
  }) =>
      Uint8List.fromList([
        ...c7Lp(conversationId),
        ...c7Lp(channelId ?? ''),
        ...c7Lp(senderDeviceId),
        ...c7Lp(actionId),
      ]);

  /// `sig | padded VAP1` sealed under [bodyKey]; a key seals one message.
  Uint8List sealBody({
    required Uint8List bodyKey,
    required Uint8List aad,
    required List<int> signature,
    required List<int> paddedVap1,
  }) {
    if (signature.length != 64) throw ArgumentError('signature must be 64');
    return _bindings.c7Seal(
      key: bodyKey,
      aad: aad,
      plaintext: Uint8List.fromList([...signature, ...paddedVap1]),
    );
  }

  /// Opens a sealed body: `null` when [bodyKey] is not its key (try the next
  /// candidate), otherwise the signature and the padded VAP1. A body that
  /// fails after its commitment matched throws.
  ({Uint8List signature, Uint8List paddedVap1})? openBody({
    required Uint8List bodyKey,
    required Uint8List aad,
    required Uint8List sealed,
  }) {
    final opened = _bindings.c7Open(key: bodyKey, aad: aad, sealed: sealed);
    if (opened == null) return null;
    if (opened.length <= 64) {
      throw const FormatException('C7 body is shorter than its signature');
    }
    return (
      signature: Uint8List.sublistView(opened, 0, 64),
      paddedVap1: Uint8List.sublistView(opened, 64),
    );
  }
}
