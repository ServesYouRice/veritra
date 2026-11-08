import '../crypto/community_info_codec.dart';
import '../crypto/profile_record_codec.dart';
import '../storage/local_store.dart'
    show AcceptedCommunityInfo, CommunityInfoEvent;
import 'roles/governance.dart';

/// C3 receive rules for community info
/// (docs/designs/C3-private-channels-and-info.md, "Authorship" and "Keys").
///
/// The server serves records and says which conversation carries which
/// channel; neither is trusted to decide what is shown. A fetched record is
/// shown only when:
///
/// 1. its key arrived over MLS in the group that owns that key (the shared
///    group for the community key, the channel's own group for a private
///    channel key), and its id is the one the server names;
/// 2. an `info_update` in that same group, from an account allowed to edit
///    the subject under the community's C4 role state, announced exactly this
///    blob (SHA-256), revision and key id;
/// 3. its revision is above the one already accepted; and
/// 4. it opens with that key.
///
/// Anything else keeps the last accepted record. A key that fails on an
/// announced (so authentic) record is a forged key and is dropped at once.

/// Who may edit a subject. The C4 seam: [GovernanceInfoEditPolicy] reads the
/// community shared group's role record.
abstract interface class InfoEditPolicy {
  bool mayEdit(String editorAccountId, String subjectKind);
}

/// [InfoEditPolicy] over the community shared group's C4 role state.
///
/// - Community and category: the owner and admins.
/// - Channel: any member (D80), unless admins restrict channel info; then
///   the owner and admins.
///
/// With no verified role record the answer is no (D80: apps never take the
/// server's word for a role), so nothing is shown until C4's role record is
/// readable.
class GovernanceInfoEditPolicy implements InfoEditPolicy {
  const GovernanceInfoEditPolicy(this.roles,
      {this.channelInfoRestricted = false});

  final GovernanceState? roles;

  /// D80's "unless admins restrict it". The C4 role record (format 2) has no
  /// such flag yet; the C4 client wiring adds it and passes it here. Until
  /// then channel info follows D80's default: open to every member.
  final bool channelInfoRestricted;

  @override
  bool mayEdit(String editorAccountId, String subjectKind) {
    final state = roles;
    if (state == null) return false;
    final rank = state.rankOf(editorAccountId);
    return switch (subjectKind) {
      infoKindCommunity || infoKindCategory => rank >= BuiltInRole.admin.rank,
      infoKindChannel =>
        !channelInfoRestricted || rank >= BuiltInRole.admin.rank,
      _ => false,
    };
  }
}

/// Where a subject's key lives: the keyed subject (the community, or the
/// private channel itself) and the conversation whose MLS group carries it.
class InfoKeyHome {
  const InfoKeyHome({
    required this.keySubjectKind,
    required this.keySubjectId,
    required this.conversationId,
  });

  final String keySubjectKind;
  final String keySubjectId;
  final String conversationId;
}

/// The fetched record as the server served it.
class ServedCommunityInfo {
  const ServedCommunityInfo({
    required this.subjectKind,
    required this.subjectId,
    required this.version,
    required this.keyId,
    required this.blob,
  });

  final String subjectKind;
  final String subjectId;
  final int version;
  final String keyId;
  final List<int> blob;
}

sealed class InfoVerdict {
  const InfoVerdict();
}

/// Show [record]; keep [accepted] as the new cache.
final class InfoAccepted extends InfoVerdict {
  const InfoAccepted(this.record, this.accepted);
  final CommunityInfoRecord record;
  final AcceptedCommunityInfo accepted;
}

/// No key with the served id came from the owning group: show placeholders
/// and ask the group (`info_key_request`, at most once per subject per hour).
final class InfoNeedsKey extends InfoVerdict {
  const InfoNeedsKey(this.home);
  final InfoKeyHome home;
}

/// The key that failed on an announced record: drop it, keep the last record.
final class InfoBadKey extends InfoVerdict {
  const InfoBadKey(this.home, this.keyId);
  final InfoKeyHome home;
  final String keyId;
}

/// Keep the last accepted record (not announced by an allowed editor, not
/// newer, or not openable).
final class InfoKept extends InfoVerdict {
  const InfoKept(this.reason);
  final InfoKeptReason reason;
}

enum InfoKeptReason { notAnnounced, notNewer, refused }

/// Opens a blob with a key. In the app this is [CommunityInfoCodec.open].
typedef InfoOpener = CommunityInfoRecord Function(
    List<int> key, ServedCommunityInfo served, int cachedRevision);

/// Judges one fetched record. Pure: the caller loads [keys] (for the home
/// subject) and [updates] (for the subject) from the local store and acts on
/// the verdict.
InfoVerdict judgeCommunityInfo({
  required ServedCommunityInfo served,
  required InfoKeyHome home,
  required List<CommunityInfoEvent> keys,
  required List<CommunityInfoEvent> updates,
  required AcceptedCommunityInfo? accepted,
  required InfoEditPolicy policy,
  required InfoOpener open,
}) {
  final cached = accepted?.revision ?? 0;
  if (served.version <= cached) {
    return const InfoKept(InfoKeptReason.notNewer);
  }
  final key = keys
      .where((k) =>
          k.subjectKind == home.keySubjectKind &&
          k.subjectId == home.keySubjectId &&
          k.conversationId == home.conversationId &&
          k.keyId == served.keyId &&
          k.key != null)
      .lastOrNull;
  if (key == null) return InfoNeedsKey(home);
  final digest = CommunityInfoCodec.recordSha256(served.blob);
  final announced = updates.any((u) =>
      u.subjectKind == served.subjectKind &&
      u.subjectId == served.subjectId &&
      u.conversationId == home.conversationId &&
      u.revision == served.version &&
      u.keyId == served.keyId &&
      u.recordSha256 == digest &&
      policy.mayEdit(u.senderAccountId, served.subjectKind));
  if (!announced) return const InfoKept(InfoKeptReason.notAnnounced);
  final CommunityInfoRecord record;
  try {
    record = open(key.key!, served, cached);
  } on ProfileRecordException catch (e) {
    // The blob is the one an allowed editor announced, so a key that will
    // not open it (wrong bytes under the right id cannot happen; a failed
    // AEAD can) was forged by whoever sent it.
    if (e.failure == ProfileRecordFailure.authFailed ||
        e.failure == ProfileRecordFailure.keyMismatch) {
      return InfoBadKey(home, served.keyId);
    }
    return const InfoKept(InfoKeptReason.refused);
  }
  return InfoAccepted(
    record,
    AcceptedCommunityInfo(
      subjectKind: served.subjectKind,
      subjectId: served.subjectId,
      revision: record.revision,
      keyId: served.keyId,
      blob: served.blob,
    ),
  );
}

/// The key-request rule: at most one `info_key_request` per subject per
/// hour. [lastAsked] is when this device last asked, or null.
bool mayRequestInfoKey(DateTime? lastAsked, DateTime now) =>
    lastAsked == null || now.difference(lastAsked) >= const Duration(hours: 1);

/// The key-delivery rule: a key is only ever sent in the group that owns it,
/// never the community key into a private channel's group or the reverse.
bool mayDeliverInfoKey(InfoKeyHome home, String conversationId) =>
    home.conversationId == conversationId;
