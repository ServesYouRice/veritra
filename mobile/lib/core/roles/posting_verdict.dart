// C2: the receiving app's side of admin-only posting.
//
// A post is dropped when posting is restricted where it was made and its
// sender is below admin. Roles come only from the group's signed role record
// (C4, D80): the server-reported role is never an input. Until that record
// can be read, no source implements [VerifiedRoleSource] and nothing is
// dropped; the server already refuses restricted posts from non-admins
// (migration 0046). Design: docs/designs/C2-admin-only-posting.md.
import '../../crypto/app_payload.dart';
import 'governance.dart';

/// Where verified roles come from. Not implemented by any build yet: it is
/// the seam C4's ABI fills (the record read from the group's MLS extension).
abstract interface class VerifiedRoleSource {
  /// The group's role record as this device holds it, or null when the group
  /// has none (a demo group made before C4, or a record not readable yet).
  /// Must not throw (a throw turns a valid post into an invalid row); return
  /// null instead.
  GovernanceState? governanceOf(String conversationId);

  /// Whether the server says posting is restricted in [conversationId]
  /// (`Conversation.posting_restricted`, or an announcement channel). The
  /// server can only narrow: it never widens what the record restricts.
  bool serverRestrictsPosting(String conversationId, String? channelId);
}

/// Payload types that add a visible post. Reactions, edits, deletes, pins and
/// poll votes follow their own rules and are not judged here.
const Set<AppPayloadType> restrictedPostTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.attachmentManifest,
  AppPayloadType.poll,
};

/// True when the receiver must drop this post.
///
/// - No verified record: false. Everyone would read as a member, and dropping
///   would hide real admins' announcements; the server's refusal stands.
/// - No channel exemption here: `history_sync` and its request are not in
///   [restrictedPostTypes], and in a shared community group `classify`
///   already refuses any other payload without a channel.
/// - Otherwise: restricted where the record or the server says so, and the
///   sender's role (from the record) is below admin, or its leaf is one its
///   account's approved-device list removed ([senderRemoved], owner
///   decision B: a stolen phone keeps no posting power).
bool shouldDropRestrictedPost({
  required GovernanceState? record,
  required String sender,
  required String? channelId,
  required bool serverRestricts,
  bool senderRemoved = false,
}) {
  if (record == null) return false;
  final restricted =
      record.isRestricted(channelId: channelId) || serverRestricts;
  // Owner decision B: a leaf its account's list removed posts as a member.
  return restricted &&
      (senderRemoved || record.rankOf(sender) < BuiltInRole.admin.rank);
}
