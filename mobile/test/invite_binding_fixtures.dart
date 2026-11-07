import 'dart:typed_data';

import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/membership_models.dart';

import 'test_crypto_service.dart';

/// The inviting device's key in the default fixtures (40 41 .. 5f).
final Uint8List defaultInviterKey =
    Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i));

/// A new link whose key commitment names [signingKey] (default
/// [defaultInviterKey]).
MembershipInviteLink newInviteLink({
  String origin = 'https://localhost:8080',
  List<int>? signingKey,
}) =>
    MembershipInviteLink.generate(
      origin: origin,
      inviterSigningKey: signingKey ?? defaultInviterKey,
    );

/// What an honest creating device binds [link] to (D90, v2): the tag and the
/// signature (the test engine's stand-in, see [fakeInviteSignature]) over the
/// fields. Defaults name a group `conv_1` and the inviter `acct_alice` on
/// `dev_alice`.
InviteBinding honestBinding(
  MembershipInviteLink link, {
  InviteTargetKind kind = InviteTargetKind.group,
  String targetId = 'conv_1',
  String accountId = 'acct_alice',
  String deviceId = 'dev_alice',
  List<int>? signingKey,
}) {
  final key = Uint8List.fromList(signingKey ?? defaultInviterKey);
  return InviteBinding(
    kind: kind,
    targetId: targetId,
    inviterAccountId: accountId,
    inviterDeviceId: deviceId,
    inviterSigningKey: key,
    tag: link.bindingTag(
      kind: kind,
      targetId: targetId,
      inviterAccountId: accountId,
      inviterDeviceId: deviceId,
      inviterSigningKey: key,
    ),
    signature: fakeInviteSignature(
      key,
      link.bindingMessage(
        kind: kind,
        targetId: targetId,
        inviterAccountId: accountId,
        inviterDeviceId: deviceId,
        inviterSigningKey: key,
      ),
    ),
  );
}

/// [binding] with one field changed, tag untouched.
InviteBinding tampered(
  InviteBinding binding, {
  InviteTargetKind? kind,
  String? targetId,
  String? accountId,
  String? deviceId,
  List<int>? signingKey,
  String? tag,
  List<int>? signature,
}) =>
    InviteBinding(
      kind: kind ?? binding.kind,
      targetId: targetId ?? binding.targetId,
      inviterAccountId: accountId ?? binding.inviterAccountId,
      inviterDeviceId: deviceId ?? binding.inviterDeviceId,
      inviterSigningKey:
          Uint8List.fromList(signingKey ?? binding.inviterSigningKey),
      tag: tag ?? binding.tag,
      signature: Uint8List.fromList(signature ?? binding.signature),
    );
