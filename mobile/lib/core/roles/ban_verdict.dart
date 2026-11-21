// C5: the receiving app's side of a ban (record format 3; docs/crypto.md,
// "C4 record format 3").
//
// A banned account is never in the record group's MLS roster: every app
// refuses a commit that would put it there (`validateCommit`). A private
// channel's own group carries no record, though, and a removal from it may
// lag behind the ban (it is a separate commit, and a hostile server can
// hold it back). So content from an account the community's verified
// record bans is hidden wherever it arrives, the way a timed-out member's
// is.
import '../../crypto/app_payload.dart';
import 'governance.dart';
import 'private_channel_membership.dart'
    show decodePrivateChannelPicks, encodePrivateChannelPicks;
import 'timeout_verdict.dart' show timeoutRefusedTypes;

/// Payload types a ban hides: the same as a timeout's (everything that adds
/// or changes visible content). Control payloads are never judged here.
const Set<AppPayloadType> banRefusedTypes = timeoutRefusedTypes;

/// True when the receiver must hide [type] from [sender] because the
/// verified [record] bans [sender]. No record: false.
bool shouldDropBannedPost({
  required GovernanceState? record,
  required String sender,
  required AppPayloadType type,
}) =>
    record != null &&
    banRefusedTypes.contains(type) &&
    record.bans.contains(sender);

/// The bans this device's user made in the community whose shared group is
/// [groupId] and still owes that group's record (JSON object of account id
/// to milliseconds since the epoch when the entry lapses; empty means none).
/// The device's own removal commit carries them when it takes the account
/// out ([recordWithBans]); a sync pass writes the rest as an admin's
/// role-only commit, and drops an entry once the record holds the ban.
String banRecordOwedSetting(String groupId) => 'c5.ban_record.$groupId';

/// How long an owed ban is kept when no commit could carry it.
const Duration banRecordOwedLifetime = Duration(days: 7);

/// The owed bans in [stored] that have not lapsed at [now].
Map<String, int> decodeOwedBans(String? stored, DateTime now) =>
    decodePrivateChannelPicks(stored, now);

/// [owed] as stored; empty when there are none.
String encodeOwedBans(Map<String, int> owed) => encodePrivateChannelPicks(owed);

/// A change list whose only adds were accounts the group's record bans:
/// nothing is staged and the change stays pending (a ban lifted later lets
/// it through).
class BannedAddRefusedException implements Exception {
  const BannedAddRefusedException(this.conversationId);
  final String conversationId;

  @override
  String toString() => 'BannedAddRefusedException';
}
