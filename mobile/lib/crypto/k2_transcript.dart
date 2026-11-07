import 'dart:convert';
import 'dart:typed_data';

import 'native_crypto_bindings.dart' show K2LinkContext;
import 'sha256.dart';

/// The device-link transcript hash of [context] (protocol
/// `veritra-device-link-v4`, TASK-010/048), computed in Dart exactly as Rust
/// does (`crypto/rust/src/mls/link_v3.rs`, `LinkContext::transcript`):
/// SHA-256 over `lp(x)` fields (u16 big-endian length, then `x`) in this
/// order: the transcript domain, the protocol string, origin, link id,
/// account id, nonce, source device id and signing key, recipient device id
/// and signing key, transfer public key, the source commitment and the
/// recipient random. Ids and the origin are their UTF-8
/// bytes, as the K2 control writer sends them.
///
/// L1 uses it to bind the pair a change-2 version adds to the transcript the
/// native K2 state verified (claim tag and typed code): a server record whose
/// recipient id or signing key differs from that transcript hashes to
/// something else. Every field is public; nothing secret is hashed.
Uint8List deviceLinkV3TranscriptHash(K2LinkContext context) {
  final out = BytesBuilder(copy: false);
  void field(List<int> value) {
    if (value.isEmpty || value.length > 0xffff) {
      throw ArgumentError('device-link transcript field size');
    }
    out
      ..addByte(value.length >> 8)
      ..addByte(value.length & 0xff)
      ..add(value);
  }

  field(utf8.encode('veritra-device-link-transcript'));
  field(utf8.encode('veritra-device-link-v4'));
  field(utf8.encode(context.id.serverOrigin));
  field(utf8.encode(context.id.linkId));
  field(utf8.encode(context.accountId));
  field(context.nonce);
  field(utf8.encode(context.sourceDeviceId));
  field(context.sourceSigningKey);
  field(utf8.encode(context.recipientDeviceId));
  field(context.recipientSigningKey);
  field(context.transferPublicKey);
  field(context.sourceCommitment);
  field(context.recipientRandom);
  return sha256(out.takeBytes());
}
