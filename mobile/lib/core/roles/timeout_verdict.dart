// C5: the receiving app's side of a member's timeout.
//
// The server refuses every envelope from a timed-out member by its own clock
// (`checkNotTimedOutTx`). Apps do not trust the server for that (D80): they
// judge visible content against the timeout the verified C4 record holds
// (docs/crypto.md, "C5 timeouts in the record"), the same way the server
// decides, so a server that accepts such a post anyway does not get it shown.
import '../../crypto/app_payload.dart';
import 'governance.dart';

/// Payload types a timeout refuses: everything that adds or changes visible
/// content, as the server refuses posts, edits and reactions. Control
/// payloads (leave proofs, info and profile keys, C7 history, calls) are
/// never judged here, so a timeout cannot break C3, C4 or C7 state, and a
/// member's own delete stays allowed (it only removes content).
const Set<AppPayloadType> timeoutRefusedTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.attachmentManifest,
  AppPayloadType.poll,
  AppPayloadType.edit,
  AppPayloadType.reaction,
  AppPayloadType.pollVote,
  AppPayloadType.pollClose,
  AppPayloadType.pin,
};

/// How far ahead of this device's clock a server-stamped time is believed.
/// A later stamp is taken as this device's time plus this much: a server
/// cannot show a timed-out member's post early by dating it after the end.
/// Generous, because a hidden post stays hidden: a receiving clock slow by
/// more than this hides an honest post sent within this long after a
/// timeout ends.
const Duration timeoutClockTolerance = Duration(hours: 1);

/// True when the receiver must hide this post.
///
/// - No record, or no timeout for [sender] in it: false.
/// - The post's time is the server's [serverTime], but never later than
///   [receivedAt] + [timeoutClockTolerance].
/// - At or after the end: false. Within `[from, until)`: true, as the server
///   would have refused it.
/// - Stamped before the timeout began: hidden only when [postEpoch] (the
///   post's MLS epoch, authenticated by decryption; pass it only when the post
///   is in the record's own group) is at or after the epoch the timeout was
///   set in, since such a post was made after the timeout began. A private
///   channel's group has its own epochs and passes null.
bool shouldDropTimedOutPost({
  required GovernanceState? record,
  required String sender,
  required DateTime serverTime,
  required DateTime receivedAt,
  int? postEpoch,
}) {
  final timeout = record?.timeouts[sender];
  if (timeout == null) return false;
  final latest =
      receivedAt.toUtc().add(timeoutClockTolerance).millisecondsSinceEpoch;
  var judged = serverTime.toUtc().millisecondsSinceEpoch;
  if (judged > latest) judged = latest;
  if (judged >= timeout.untilMs) return false;
  if (judged >= timeout.fromMs) return true;
  return postEpoch != null && postEpoch >= timeout.epoch;
}
