// C5 rejoin gap (docs/designs/C5-moderation.md, "Timeouts after a rejoin").
//
// A removal prunes the leaver's timeout from the C4 record
// (`GovernanceState.removeAccount`), but the server remembers it
// (migration 0095) and puts it back on the new membership when the person
// rejoins. The server then refuses their posts while the record has no
// entry, so the member screen would show no timeout. Admins read the
// server's running timeouts (`GET .../timeouts`, `member` true) and may lift
// it there, or write it into the record by an explicit action; nothing here
// commits on its own, so admins' devices never race to write it.
import 'governance.dart';
import 'governance_commands.dart';

/// How far ahead of now a server timeout must still end for this device to
/// write it into the record. A shorter one would expire about as the commit
/// lands, and the record entry would only add a commit to every member.
const Duration recordTimeoutMargin = Duration(minutes: 5);

/// True while [record] holds a timeout for [account] that has not ended at
/// [now] (an ended entry is the same as none to the member screen).
bool recordHasRunningTimeout(
  GovernanceState record,
  String account,
  DateTime now,
) {
  final entry = record.timeouts[account];
  return entry != null && entry.untilMs > now.millisecondsSinceEpoch;
}

/// Whether [actor] may write the server's timeout of [account], ending at
/// [serverUntil], into [record] now: the record lacks a running entry,
/// [account] is in the group's MLS [roster] (a rejoiner the server lists but
/// whose devices have not joined yet is not), the record lets [actor] act on
/// [account] (`mayActOn`), and the end is more than [recordTimeoutMargin]
/// ahead of [now] and within the record's 28-day bound.
bool mayApplyServerTimeout({
  required GovernanceState record,
  required Set<String> roster,
  required String actor,
  required String account,
  required DateTime serverUntil,
  required DateTime now,
}) {
  if (recordHasRunningTimeout(record, account, now)) return false;
  if (!roster.contains(account)) return false;
  if (!record.mayActOn(actor, account)) return false;
  final left = serverUntil.difference(now);
  return left > recordTimeoutMargin && left.inMilliseconds <= maxTimeoutMillis;
}

/// The record commit for "Apply to the record": [account]'s timeout from
/// [now] (this device's clock: the server's start is not known after a
/// rejoin; receivers hide a post stamped before it only when its epoch is at
/// or after this commit's, so earlier posts rest on the server's refusal, as
/// before) to [serverUntil].
///
/// Checked against the record at staging time, not the one the screen
/// loaded: another admin may have written it meanwhile (`no_change`, so the
/// first start is kept), or the end may now be too close (`timeout_ending`).
/// [GovernanceCommands.setTimeout] refuses an account outside the roster
/// (`not_member`) or one the actor does not outrank (`hierarchy`).
GovernanceState applyServerTimeout(
  GovernanceCommands commands,
  String account, {
  required DateTime serverUntil,
  required DateTime now,
}) {
  if (recordHasRunningTimeout(commands.state, account, now)) {
    throw const GovernanceCommandException('no_change');
  }
  if (serverUntil.difference(now) <= recordTimeoutMargin) {
    throw const GovernanceCommandException('timeout_ending');
  }
  return commands.setTimeout(
    account,
    fromMs: now.millisecondsSinceEpoch,
    untilMs: serverUntil.millisecondsSinceEpoch,
  );
}
