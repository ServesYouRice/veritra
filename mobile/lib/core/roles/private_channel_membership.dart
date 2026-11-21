// C3: who may bring a new account into a private channel's own MLS group
// (docs/designs/C3-private-channels-and-info.md, "Private channel
// membership"; docs/crypto.md, "C3 private channel membership").
//
// Who can read a private channel is exactly who is in its MLS group, and
// the server's member list only proposes. A new account enters the group
// only by a commit from an owner, admin or moderator under the community's
// verified C4 record (the shared group's), and an honest device commits
// such an add only for an account its own user picked. A new device of an
// account that already holds a leaf needs neither (L1 still approves each
// device). Moderators may add (owner, 2026-11-21, as the server's
// `CanManageMembers`); plain members never do.
import 'dart:convert';

import 'governance.dart';

/// The lowest role under the verified record that may bring a new account
/// into a private channel's group. The receiver and the producer below
/// share it, so the two can never disagree.
const BuiltInRole privateChannelAddMinRole = BuiltInRole.moderator;

/// Set (to `1`) once this device has seen [conversationId] as a private
/// channel's own group. Never cleared: a server that later labels the group
/// as something else cannot switch the membership rule off.
String privateChannelPinSetting(String conversationId) =>
    'c3.private_group.$conversationId';

/// The accounts this device's user picked to add to the private channel
/// [conversationId], each with the time its pick lapses (JSON object of
/// account id to milliseconds since the epoch; empty means none).
String privateChannelPicksSetting(String conversationId) =>
    'c3.private_picks.$conversationId';

/// How long a pick stays usable when its add has not been committed yet.
const Duration privateChannelPickLifetime = Duration(days: 7);

/// The picks in [stored] that have not lapsed at [now].
Map<String, int> decodePrivateChannelPicks(String? stored, DateTime now) {
  if (stored == null || stored.isEmpty) return <String, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(stored);
  } on FormatException {
    return <String, int>{};
  }
  if (decoded is! Map) return <String, int>{};
  final at = now.millisecondsSinceEpoch;
  return <String, int>{
    for (final entry in decoded.entries)
      if (entry.key is String &&
          (entry.key as String).isNotEmpty &&
          entry.value is int &&
          (entry.value as int) > at)
        entry.key as String: entry.value as int,
  };
}

/// [picks] as stored; empty when there are none.
String encodePrivateChannelPicks(Map<String, int> picks) =>
    picks.isEmpty ? '' : jsonEncode(picks);

/// Receiver: whether [committer] may bring the accounts of [after] that are
/// not in [before] into a private channel's group: only an owner, admin or
/// moderator ([privateChannelAddMinRole]) may, and never an account the
/// community's record bans (C5, record format 3). [record] is the
/// community's verified role record as this device holds it (null when it
/// holds none: then no new account is accepted). The committer's leaf must
/// also be approved by its account's list; the caller checks that.
bool privateChannelAddAccepted({
  required GovernanceState? record,
  required String committer,
  required Set<String> before,
  required Set<String> after,
}) {
  final newcomers = after.difference(before);
  if (newcomers.isEmpty) return true;
  return record != null &&
      record.rankOf(committer) >= privateChannelAddMinRole.rank &&
      !newcomers.any(record.bans.contains);
}

/// Producer: the accounts of [candidates] this device may add to a private
/// channel's group: accounts already in it ([inGroup]) and this account
/// (new devices), and, only while [self] is an owner, admin or moderator
/// under [record] ([privateChannelAddMinRole]), the accounts its user
/// picked ([picked]). The role is checked now, when the add is staged, not
/// when the user picked: a moderator demoted since then adds nothing. An
/// account the record bans is never added (C5).
Set<String> privateChannelAddableAccounts({
  required GovernanceState? record,
  required String self,
  required Set<String> inGroup,
  required Set<String> picked,
  required Iterable<String> candidates,
}) {
  final mayPick =
      record != null && record.rankOf(self) >= privateChannelAddMinRole.rank;
  final banned = record?.bans ?? const <String>{};
  return <String>{
    for (final account in candidates)
      if (!banned.contains(account) &&
          (account == self ||
              inGroup.contains(account) ||
              (mayPick && picked.contains(account))))
        account,
  };
}

/// A crypto service that applies the private channel membership rule to the
/// adds it is asked to stage. AppState asks it before claiming key packages,
/// so a server-proposed account nobody picked never costs one.
abstract interface class PrivateChannelAddGate {
  /// The accounts of [accounts] this device may add to [conversationId]:
  /// all of them unless it is a private channel's own group.
  Future<Set<String>> privateChannelAddable(
    String conversationId,
    Set<String> accounts,
  );
}

/// A private channel's own group asked this device to stage only adds the
/// rule above refuses: nothing is staged and the change stays pending.
class PrivateChannelAddRefusedException implements Exception {
  const PrivateChannelAddRefusedException(this.conversationId);
  final String conversationId;

  @override
  String toString() => 'PrivateChannelAddRefusedException';
}
