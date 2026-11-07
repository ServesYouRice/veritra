import 'dart:typed_data';

import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/membership_models.dart';

/// What an honest creating device binds [link] to (D90): the tag a server
/// that never saw the secret cannot make. Defaults name a group `conv_1` and
/// the inviter `acct_alice` on `dev_alice`.
InviteBinding honestBinding(
  MembershipInviteLink link, {
  InviteTargetKind kind = InviteTargetKind.group,
  String targetId = 'conv_1',
  String accountId = 'acct_alice',
  String deviceId = 'dev_alice',
  List<int>? signingKey,
}) {
  final key =
      Uint8List.fromList(signingKey ?? List<int>.generate(32, (i) => 0x40 + i));
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
}) =>
    InviteBinding(
      kind: kind ?? binding.kind,
      targetId: targetId ?? binding.targetId,
      inviterAccountId: accountId ?? binding.inviterAccountId,
      inviterDeviceId: deviceId ?? binding.inviterDeviceId,
      inviterSigningKey:
          Uint8List.fromList(signingKey ?? binding.inviterSigningKey),
      tag: tag ?? binding.tag,
    );
