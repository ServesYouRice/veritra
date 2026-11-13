import 'dart:convert';
import 'dart:math';

import '../crypto/app_payload.dart';
import '../crypto/community_info_codec.dart';
import '../crypto/community_info_payload.dart';
import '../crypto/profile_record_codec.dart';
import '../storage/local_store.dart'
    show
        AcceptedCommunityInfo,
        CommunityInfoEvent,
        CommunityInfoEventKind,
        LocalStore,
        communityInfoRemovalSetting;
import 'community_info_book.dart';
import 'roles/governance.dart';
import 'sha256.dart';

/// C3 senders and the fetch loop (docs/designs/C3-private-channels-and-info.md,
/// "Keys", "Key delivery", "Private channel lifecycle").
///
/// Everything outside this class is injected, so the rules are tested
/// without a server: [InfoApi] is the server's record store, [InfoSend]
/// queues one MLS payload (the app's ordinary send path, so removal holds
/// and per-conversation order apply), [InfoTopology] says which conversation
/// carries what, and [policyFor] gives the C4 role check.
///
/// Delivery is convergent: a device missing a key asks
/// (`info_key_request`), and an owner or admin holding it answers in the
/// group that owns it. Nothing depends on catching one message at the right
/// moment.

/// The server side of info records.
abstract interface class InfoApi {
  Future<int> put({
    required String kind,
    required String subjectId,
    String? communityId,
    required String keyId,
    required List<int> blob,
    required int expectedVersion,
  });

  Future<ServedCommunityInfo?> get({
    required String kind,
    required String subjectId,
    String? communityId,
  });
}

/// Thrown by [InfoApi.put] when `If-Match` was stale (HTTP 412).
class InfoVersionConflict implements Exception {
  const InfoVersionConflict();
}

/// Queues one payload into a conversation. False when nothing was queued.
typedef InfoSend = Future<bool> Function(
    String conversationId, AppPayloadType type, Map<String, Object?> body);

/// What the app knows about where things live. Server-supplied; the book's
/// checks do not depend on it being honest (see the design's residuals).
abstract interface class InfoTopology {
  /// The community's shared conversation, or null when it has none (a legacy
  /// layout: C3 is not active there).
  String? sharedConversationOf(String communityId);

  /// The conversation of a private channel, or null when the channel is open
  /// or unknown.
  String? privateConversationOf(String channelId);

  /// Whether this account is an owner or admin of the community, by the
  /// server's word, or null while unknown (the member list did not load).
  /// Used only to pick who answers key requests and who rotates, never to
  /// decide what is shown.
  bool? serverSaysAdmin(String communityId);

  /// Whether sends to [conversationId] wait for a removal commit (D68).
  /// Background work skips such a group and comes back later, so one stuck
  /// group never stalls the others.
  bool sendHeld(String conversationId);

  /// Whether the community is known to be gone (the lists loaded and it is
  /// not there). False while the lists are not loaded: unknown is not gone.
  bool communityGone(String communityId);
}

/// [CommunityInfoService.publish] could not find a key it trusts and may not
/// make one: it asked the group for it instead.
class InfoKeyMissing implements Exception {
  const InfoKeyMissing();
}

/// An edit must wait until removal and info-key rotation finish.
class InfoRotationPending implements Exception {
  const InfoRotationPending();
}

/// C3 remote-removal schedule (docs/designs/C3-private-channels-and-info.md,
/// "Remote removals: who rotates"). An owner or admin device that observes a
/// removal it did not make waits [remoteRotationBase] plus one
/// [remoteRotationSlot] per rank plus a per-device jitter, then rotates only
/// if no other owner or admin device has delivered a fresh key meanwhile.
///
/// The schedule changes timing only. Nothing in it (rank, jitter, the
/// server's labels) can cancel an obligation; only this device's completed
/// pass or an MLS-authenticated fresh key from a verified owner or admin
/// device ends it.
const remoteRotationBase = Duration(seconds: 15);
const remoteRotationSlot = Duration(seconds: 30);
const remoteRotationJitter = Duration(seconds: 10);
const remoteRotationMaxRank = 8;

List<int> _rotationDigest(String label, List<String> parts) =>
    sha256(utf8.encode(<String>[label, ...parts].join('\u0000')));

/// This account's place in the order in which the verified owners and admins
/// ([rotators]) rotate after the removal at [epoch] in [home]. The order is a
/// hash of the home, the epoch and each account, so every member computes
/// the same order and no single admin (an often-offline owner, say) is
/// always first. Capped at [remoteRotationMaxRank]. An account missing from
/// [rotators] (no verified record; the server's word let it rotate) is 0.
int remoteRotationRank({
  required Iterable<String> rotators,
  required String accountId,
  required InfoKeyHome home,
  required int epoch,
}) {
  String order(String account) =>
      _rotationDigest('veritra-c3-rotation-rank-v1', [
        home.conversationId,
        home.keySubjectKind,
        home.keySubjectId,
        '$epoch',
        account,
      ]).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final sorted = rotators.toSet().toList()
    ..sort((a, b) {
      final byHash = order(a).compareTo(order(b));
      return byHash != 0 ? byHash : a.compareTo(b);
    });
  final rank = sorted.indexOf(accountId);
  return rank < 0 ? 0 : min(rank, remoteRotationMaxRank);
}

/// How long a device of rank [rank] waits after observing the removal at
/// [epoch] before rotating. The jitter is derived from the device id, so a
/// restart computes the same wait and two devices of one account spread out.
Duration remoteRotationDelay({
  required int rank,
  required String deviceId,
  required InfoKeyHome home,
  required int epoch,
}) {
  final digest = _rotationDigest('veritra-c3-rotation-jitter-v1', [
    deviceId,
    home.conversationId,
    home.keySubjectKind,
    home.keySubjectId,
    '$epoch',
  ]);
  final spread =
      ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) %
          remoteRotationJitter.inMilliseconds;
  return remoteRotationBase +
      remoteRotationSlot * min(max(rank, 0), remoteRotationMaxRank) +
      Duration(milliseconds: spread);
}

/// The accounts that may rotate under a verified role record: its owner
/// (while in the roster) and its admins. Moderators rotate only in a
/// private channel with none of these among its members.
Set<String> verifiedRotators(GovernanceState roles) => <String>{
      if (roles.owner case final owner?)
        if (roles.joined.isEmpty || roles.joined.containsKey(owner)) owner,
      ...roles.admins.keys,
    };

/// The verified moderators of [roles] (owner and admins excluded).
Set<String> verifiedModerators(GovernanceState roles) => <String>{
      for (final account in roles.moderators)
        if (roles.rankOf(account) == BuiltInRole.moderator.rank) account,
    };

/// One info subject: its kind, id, and the community it belongs to.
class InfoSubject {
  const InfoSubject(this.kind, this.id, this.communityId);
  final String kind;
  final String id;
  final String communityId;

  String get key => '$kind|$id';

  @override
  bool operator ==(Object other) =>
      other is InfoSubject && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

class CommunityInfoService {
  CommunityInfoService({
    required this.store,
    required this.api,
    required this.send,
    required this.topology,
    required this.codec,
    required this.policyFor,
    required this.accountId,
    required this.deviceId,
    this.onChanged,
    this.epochOf,
    this.verifiedRolesOf,
    this.membersOf,
    DateTime Function()? clock,
    Duration Function()? answerDelay,
    String settingPrefix = 'c3',
  })  : _clock = clock ?? DateTime.now,
        _answerDelay = answerDelay ?? _randomDelay,
        _rotationSetting = '$settingPrefix.rotation_due.$accountId' {
    _startedAt = _clock();
  }

  final LocalStore store;
  final InfoApi api;
  final InfoSend send;
  final InfoTopology topology;
  final CommunityInfoCodec codec;
  final InfoEditPolicy Function(String communityId) policyFor;
  final String accountId;
  final String deviceId;
  final void Function()? onChanged;

  /// The local MLS epoch of a conversation's group, or null when unknown.
  /// A key this device makes is stamped with it (see [currentKey]).
  final Future<int?> Function(String conversationId)? epochOf;

  /// The community's verified C4 role record, or null while none is held.
  /// With a record, only its owner and admins rotate, whatever the server
  /// says; without one, the server's word ([InfoTopology.serverSaysAdmin])
  /// stands in, as before C4.
  final GovernanceState? Function(String communityId)? verifiedRolesOf;

  /// The accounts in a conversation's MLS group, from the group's own tree
  /// (never the server's list), or null when unknown. It decides the
  /// no-admin case of a private channel ([_noAdminModerators]).
  final Set<String>? Function(String conversationId)? membersOf;

  /// When this service started: a deferred rotation's wait counts from here
  /// at the earliest, so a restarted device catches up on what other admins
  /// sent before it decides to rotate itself.
  late final DateTime _startedAt;
  final DateTime Function() _clock;
  final Duration Function() _answerDelay;
  final String _rotationSetting;

  final Map<String, CommunityInfoRecord> _shown = {};
  final Map<String, InfoSubject> _shownSubjects = {};
  final Map<String, DateTime> _lastAsked = {};
  final Set<String> _answered = {};
  final Map<String, DateTime> _answeredDevice = {};
  final Map<String, Future<int>> _answerRuns = {};
  Future<void> _writes = Future<void>.value();

  // A rotation reads the displayed records before re-sealing them. Keep
  // edits and rotation passes in one queue so that snapshot cannot overwrite
  // an edit that completed while the new key was being sent.
  Future<T> _serializeWrites<T>(Future<T> Function() body) {
    final result = _writes.then((_) => body());
    _writes = result.then((_) {}, onError: (_) {});
    return result;
  }

  static final _random = Random.secure();
  static Duration _randomDelay() =>
      Duration(milliseconds: _random.nextInt(3000));

  /// The record shown for a subject, or null (use the legacy name or a
  /// placeholder).
  CommunityInfoRecord? shown(String kind, String id) => _shown['$kind|$id'];

  /// [communityId]'s category ids whose shown record is a tombstone, sorted.
  /// C3 reuses one before minting a new id: the server's 200-binding bound
  /// holds for the community's whole life.
  List<String> tombstonedCategories(String communityId) => <String>[
        for (final entry in _shown.entries)
          if (entry.value.kind == infoKindCategory &&
              entry.value.isTombstone &&
              _shownSubjects[entry.key]?.communityId == communityId)
            entry.value.subjectId,
      ]..sort();

  /// Where [subject]'s key lives, or null when C3 is not active for it.
  InfoKeyHome? homeOf(InfoSubject subject) {
    final shared = topology.sharedConversationOf(subject.communityId);
    if (subject.kind == infoKindChannel) {
      final private = topology.privateConversationOf(subject.id);
      if (private != null) {
        return InfoKeyHome(
            keySubjectKind: infoKindChannel,
            keySubjectId: subject.id,
            conversationId: private);
      }
    }
    if (shared == null) return null;
    return InfoKeyHome(
        keySubjectKind: infoKindCommunity,
        keySubjectId: subject.communityId,
        conversationId: shared);
  }

  /// The key to seal with (docs/crypto.md, "C3 key freshness").
  ///
  /// Only keys in the owning group from this account, or from an owner or
  /// admin under the verified role state, count ("trusted"); in a private
  /// channel, with no such key fresh, a verified moderator's key does. A key's
  /// freshness is the LOWEST authenticated MLS epoch any trusted copy of it
  /// was sent in: a delayed original lowers it, and a later re-delivery (an
  /// admin answering with a key from before a rotation) never raises it.
  ///
  /// - A key fresher than none of the group's last removal is retired: the
  ///   removed member may hold it. With no other key the answer is null, so
  ///   the caller asks or waits for the rotation (fail closed).
  /// - Otherwise the freshest key wins; equal epochs fall back to the key
  ///   whose id first arrived last.
  ///
  /// First local arrival alone is not enough: a retired key whose first copy
  /// arrives after its replacement would win.
  Future<CommunityInfoEvent?> currentKey(
      InfoKeyHome home, String communityId) async {
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final policy = policyFor(communityId);
    bool admin(String account) =>
        account == accountId || policy.mayEdit(account, infoKindCommunity);
    final best = await _freshest(home, keys, admin);
    if (best != null) return best;
    // No fresh key from this account or an owner or admin. In a private
    // channel a verified moderator's key stands in: one rotates when no
    // owner or admin is a member (owner decision 2026-11-11). Its key stays
    // usable after an owner or admin joins, until one of them rotates;
    // otherwise the joined admin and every member would hold no key at all.
    // Only a key sent in the group itself counts, so its sender was a
    // member at that epoch, and freshness still retires it at a removal.
    final roles = home.keySubjectKind == infoKindChannel
        ? verifiedRolesOf?.call(communityId)
        : null;
    if (roles == null) return null;
    final moderators = verifiedModerators(roles);
    if (moderators.isEmpty) return null;
    // Freshness counts the owner's and admins' rows too: a moderator
    // re-sending a key retired by a removal must not make it fresh again.
    // And here a row from any sender dates the key: an admin who minted it
    // before the removal and was demoted since is no longer trusted, but
    // its row still shows the removed member may hold the key.
    return _freshest(home, keys, (a) => admin(a) || moderators.contains(a),
        retireByAnyRow: true);
  }

  /// Who else's delivery of [home]'s current key covers a due rotation
  /// (D115 dedup): an owner or admin under the verified record, or, in a
  /// private channel with no owner or admin among its members, a verified
  /// moderator who is a member ([_noAdminModerators]). This account is not
  /// included for its own sake: it counts only with that role.
  bool Function(String account) _deliverers(
      InfoKeyHome home, String communityId) {
    final policy = policyFor(communityId);
    final stand = _noAdminModerators(home, communityId) ?? const <String>{};
    return (account) =>
        policy.mayEdit(account, infoKindCommunity) || stand.contains(account);
  }

  /// In a private channel's group where the verified record names no owner
  /// or admin among the members, the verified moderators who are members;
  /// otherwise null (owners and admins rotate, D115). Null as well without a
  /// verified record or a known roster.
  Set<String>? _noAdminModerators(InfoKeyHome home, String communityId) {
    if (home.keySubjectKind != infoKindChannel) return null;
    final roles = verifiedRolesOf?.call(communityId);
    final members = membersOf?.call(home.conversationId);
    if (roles == null || members == null) return null;
    if (verifiedRotators(roles).any(members.contains)) return null;
    final moderators =
        verifiedModerators(roles).where(members.contains).toSet();
    return moderators.isEmpty ? null : moderators;
  }

  /// With [retireByAnyRow] a key is also retired when any row of it in
  /// [home]'s group, from any sender, trusted or not, is older than the last
  /// removal (the moderator-only second choice; never the primary path,
  /// where an untrusted member could retire the admins' key that way).
  Future<CommunityInfoEvent?> _freshest(InfoKeyHome home,
      List<CommunityInfoEvent> keys, bool Function(String) author,
      {bool retireByAnyRow = false}) async {
    bool trusted(CommunityInfoEvent k) =>
        k.conversationId == home.conversationId &&
        k.keyId != null &&
        author(k.senderAccountId);
    // Rows from before schema 35 carry no epoch: they rank below every key
    // with one, and below any removal.
    const unknown = -1;
    final firstSeen = <String, int>{};
    final freshness = <String, int>{};
    for (final k in keys.where(trusted)) {
      final id = k.keyId!;
      final seq = k.seq ?? 0;
      final epoch = k.epoch ?? unknown;
      if (seq < (firstSeen[id] ?? seq + 1)) firstSeen[id] = seq;
      if (epoch < (freshness[id] ?? epoch + 1)) freshness[id] = epoch;
    }
    final removal = await _removalEpoch(home);
    final retired = <String>{
      if (retireByAnyRow && removal > 0)
        for (final k in keys)
          if (k.conversationId == home.conversationId &&
              k.keyId != null &&
              (k.epoch ?? unknown) < removal)
            k.keyId!,
    };
    CommunityInfoEvent? best;
    var bestEpoch = unknown - 1;
    var bestSeq = -1;
    for (final k in keys) {
      if (k.key == null || !trusted(k)) continue;
      final epoch = freshness[k.keyId]!;
      if (removal > 0 && epoch < removal) continue;
      if (retired.contains(k.keyId)) continue;
      final first = firstSeen[k.keyId]!;
      if (epoch > bestEpoch || (epoch == bestEpoch && first > bestSeq)) {
        best = k;
        bestEpoch = epoch;
        bestSeq = first;
      }
    }
    return best;
  }

  Future<CommunityInfoEvent?> _ownKey(InfoKeyHome home, String keyId) async {
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    return keys
        .where((k) =>
            k.keyId == keyId &&
            k.key != null &&
            k.conversationId == home.conversationId &&
            k.senderAccountId == accountId)
        .firstOrNull;
  }

  /// Makes a fresh key for [home] and keeps it locally. Others get it by
  /// asking; [rotate] also sends it at once.
  Future<CommunityInfoEvent> newKey(InfoKeyHome home) async {
    // Made now, after every removal this device has seen in the group: its
    // freshness is the group's epoch, and never below that removal's.
    final epoch = max(await epochOf?.call(home.conversationId) ?? 0,
        await _removalEpoch(home));
    final key = codec.newKey();
    final event = CommunityInfoEvent(
      kind: CommunityInfoEventKind.key,
      subjectKind: home.keySubjectKind,
      subjectId: home.keySubjectId,
      conversationId: home.conversationId,
      senderAccountId: accountId,
      senderDeviceId: deviceId,
      keyId: ProfileRecordCodec.keyId(key),
      key: key,
      epoch: epoch,
    );
    await store.recordOwnCommunityInfoEvents([event]);
    return event;
  }

  /// Seals and uploads a record for [subject], then announces it in the
  /// group that owns its key. [build] gets the revision the upload becomes.
  /// Retries a stale `If-Match` a few times. Returns the accepted record.
  ///
  /// [mint] allows a new key when none is trusted: only when the keyed
  /// subject is being created. Otherwise a device without the key asks for
  /// it and throws [InfoKeyMissing], so no parallel key ever appears. An
  /// announcement that could not be queued is sent again by [refresh].
  /// [expectedRevision] protects edits that preserve fields from a displayed
  /// snapshot: a newer server record must be fetched before trying again.
  Future<CommunityInfoRecord> publish(
    InfoSubject subject,
    CommunityInfoRecord Function(int revision) build, {
    int attempts = 3,
    bool mint = false,
    int? expectedRevision,
    bool rehome = false,
  }) =>
      _serializeWrites(() => _publish(subject, build,
          attempts: attempts,
          mint: mint,
          expectedRevision: expectedRevision,
          rehome: rehome));

  String _rotatedSetting(InfoKeyHome home) =>
      '$_rotationSetting.completed.${home.keySubjectKind}.'
      '${home.keySubjectId}.${home.conversationId}';

  Future<int> _removalEpoch(InfoKeyHome home) async => int.parse(await store
          .loadSetting(communityInfoRemovalSetting(home.conversationId)) ??
      '0');

  /// Recover remote removals from the watermark committed with MLS state.
  /// Topology may load later, and inbound-only wakes must never send a key.
  Future<void> observeRemoval(InfoKeyHome home, String communityId) =>
      _locked(() async {
        final epoch = await _removalEpoch(home);
        final completed =
            int.parse(await store.loadSetting(_rotatedSetting(home)) ?? '0');
        if (epoch <= completed) return;
        final due = await _dueRotations();
        final id = '${home.keySubjectKind}|${home.keySubjectId}';
        final held = due[id];
        if (held?['e'] == epoch) return;
        final now = _clock();
        due[id] = <String, Object?>{
          'c': communityId,
          'e': epoch,
          't': '${now.microsecondsSinceEpoch}.${_marks++}',
          // A removal this device did not ask for waits its turn (see
          // [remoteRotationDelay]). A mark this device made for its own
          // removal ([markRotationDue]) stays immediate when the commit's
          // epoch arrives, and covers any later removal too.
          if (held == null || held['d'] == true) ...{
            'd': true,
            'o': now.microsecondsSinceEpoch,
          },
        };
        await _saveDue(due);
        _backoff.remove(id);
      });

  Future<void> _checkWritable(InfoKeyHome home, {Object? rotationToken}) async {
    final due = await _locked(_dueRotations);
    final mark = due['${home.keySubjectKind}|${home.keySubjectId}'];
    final epoch = await _removalEpoch(home);
    final completed =
        int.parse(await store.loadSetting(_rotatedSetting(home)) ?? '0');
    if ((epoch > completed && (rotationToken == null || mark?['e'] != epoch)) ||
        topology.sendHeld(home.conversationId) ||
        (rotationToken == null ? mark != null : mark?['t'] != rotationToken)) {
      throw const InfoRotationPending();
    }
  }

  Future<CommunityInfoRecord> _publish(
    InfoSubject subject,
    CommunityInfoRecord Function(int revision) build, {
    int attempts = 3,
    bool mint = false,
    CommunityInfoEvent? withKey,
    Object? rotationToken,
    int? expectedRevision,
    bool rehome = false,
  }) async {
    final home = homeOf(subject);
    if (home == null) throw StateError('C3 is not active here');
    await observeRemoval(home, subject.communityId);
    await _checkWritable(home, rotationToken: rotationToken);
    var selected = withKey ?? await currentKey(home, subject.communityId);
    if (selected == null) {
      if (!mint) {
        await requestKey(home);
        throw const InfoKeyMissing();
      }
      selected = await newKey(home);
    }
    CommunityInfoEvent key = selected;
    final accepted =
        await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
    // Topology comes from the server. It must not turn a cached private
    // record into community-readable content by relabelling its channel.
    // Moving a record between key homes requires an explicit conversion:
    // [rehome], which only a C3 channel conversion this account just made
    // passes (the user chose it, and confirmed a private-to-open one).
    if (!rehome &&
        accepted != null &&
        !await _acceptedKeyInHome(accepted, home)) {
      throw const InfoKeyMissing();
    }
    for (var attempt = 0;; attempt++) {
      final served = await api.get(
          kind: subject.kind,
          subjectId: subject.id,
          communityId: subject.communityId);
      final version = served?.version ?? 0;
      // A snapshot-based edit or rotation must never re-publish older
      // preserved fields over an edit made by another device.
      if (expectedRevision != null && version != expectedRevision) {
        throw const InfoVersionConflict();
      }
      // A server serving less than this device already accepted would make
      // the edit invisible to others (they keep the newer one): refuse.
      if (accepted != null && version < accepted.revision) {
        throw const InfoVersionConflict();
      }
      // Another admin may have delivered a rotation while the HTTP read
      // was in flight (or between conflict retries). Ordinary edits must
      // use that current key rather than the one selected before the read.
      if (withKey == null) {
        final latest = await currentKey(home, subject.communityId);
        if (latest == null) throw const InfoKeyMissing();
        key = latest;
      }
      // A removal may have started while either read was in flight.
      await _checkWritable(home, rotationToken: rotationToken);
      final record = build(version + 1);
      final blob = codec.seal(key: key.key!, record: record);
      final int stored;
      try {
        stored = await api.put(
          kind: subject.kind,
          subjectId: subject.id,
          communityId: subject.communityId,
          keyId: key.keyId!,
          blob: blob,
          expectedVersion: version,
        );
      } on InfoVersionConflict {
        if (attempt + 1 >= attempts) rethrow;
        continue;
      }
      if (stored != record.revision) {
        throw StateError('the server stored another version');
      }
      await store.saveAcceptedCommunityInfo(AcceptedCommunityInfo(
        subjectKind: subject.kind,
        subjectId: subject.id,
        revision: stored,
        keyId: key.keyId!,
        blob: blob,
      ));
      _show(subject, record);
      final announced =
          await _announce(subject, home, stored, key.keyId!, blob);
      if (withKey != null && !announced) throw const InfoKeyMissing();
      return record;
    }
  }

  /// Shows what was accepted before (at start, before any fetch).
  Future<void> loadAccepted(InfoSubject subject) async {
    final accepted =
        await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
    final home = homeOf(subject);
    if (accepted == null || home == null) return;
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    for (final k in keys) {
      if (k.keyId != accepted.keyId ||
          k.key == null ||
          k.conversationId != home.conversationId) {
        continue;
      }
      try {
        _show(
            subject,
            codec.open(
              key: k.key!,
              servedKeyId: accepted.keyId,
              servedVersion: accepted.revision,
              kind: subject.kind,
              subjectId: subject.id,
              blob: accepted.blob,
            ));
        return;
      } on ProfileRecordException {
        continue;
      }
    }
  }

  Future<bool> _announce(InfoSubject subject, InfoKeyHome home, int revision,
          String keyId, List<int> blob) =>
      send(
        home.conversationId,
        AppPayloadType.infoUpdate,
        infoUpdateBody(
          subjectKind: subject.kind,
          subjectId: subject.id,
          revision: revision,
          keyId: keyId,
          recordSha256: CommunityInfoCodec.recordSha256(blob),
        ),
      );

  Future<bool> _acceptedKeyInHome(
      AcceptedCommunityInfo accepted, InfoKeyHome home) async {
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    return keys.any((k) =>
        k.keyId == accepted.keyId &&
        k.key != null &&
        k.conversationId == home.conversationId);
  }

  /// Sends the announcement of an accepted record again when none is held
  /// for it: a record is accepted from others only with one, so this is this
  /// device's own upload whose announcement could not be queued (no open
  /// channel yet, a pause, an ended session). Skipped while the group holds
  /// sends for a removal.
  Future<bool> healAnnouncement(InfoSubject subject,
      {int? servedVersion}) async {
    final home = homeOf(subject);
    if (home == null || topology.sendHeld(home.conversationId)) return false;
    final accepted =
        await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
    if (accepted == null ||
        (servedVersion != null && servedVersion != accepted.revision)) {
      return false;
    }
    if (!await _acceptedKeyInHome(accepted, home)) return false;
    final digest = CommunityInfoCodec.recordSha256(accepted.blob);
    final updates = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.update, subject.kind, subject.id);
    final policy = policyFor(subject.communityId);
    if (updates.any((u) =>
        u.revision == accepted.revision &&
        u.keyId == accepted.keyId &&
        u.recordSha256 == digest &&
        u.conversationId == home.conversationId &&
        (u.senderAccountId == accountId ||
            policy.mayEdit(u.senderAccountId, subject.kind)))) {
      return false;
    }
    return _announce(
        subject, home, accepted.revision, accepted.keyId, accepted.blob);
  }

  /// Fetches and judges one subject. A missing record (404) never clears
  /// what is shown. A missing key asks the group for it. With
  /// [knownVersion] (from the versions route) a subject already at that
  /// version is not fetched.
  Future<InfoVerdict?> refresh(InfoSubject subject, {int? knownVersion}) async {
    final home = homeOf(subject);
    if (home == null) return null;
    await observeRemoval(home, subject.communityId);
    if (!_shown.containsKey(subject.key)) await loadAccepted(subject);
    if (knownVersion != null) {
      final accepted =
          await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
      if (accepted != null && accepted.revision >= knownVersion) {
        await healAnnouncement(subject, servedVersion: knownVersion);
        return null;
      }
    }
    final served = await api.get(
        kind: subject.kind,
        subjectId: subject.id,
        communityId: subject.communityId);
    if (served == null) return null;
    final verdict = judgeCommunityInfo(
      served: served,
      home: home,
      keys: await store.loadCommunityInfoEvents(
          CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId),
      updates: await store.loadCommunityInfoEvents(
          CommunityInfoEventKind.update, subject.kind, subject.id),
      accepted: await store.loadAcceptedCommunityInfo(subject.kind, subject.id),
      policy: policyFor(subject.communityId),
      open: (key, s, cached) => codec.open(
        key: key,
        servedKeyId: s.keyId,
        servedVersion: s.version,
        kind: s.subjectKind,
        subjectId: s.subjectId,
        blob: s.blob,
        cachedRevision: cached,
      ),
    );
    switch (verdict) {
      case InfoAccepted(:final record, :final accepted):
        await store.saveAcceptedCommunityInfo(accepted);
        _show(subject, record);
      case InfoNeedsKey(:final home):
        await requestKey(home);
      case InfoKept(:final reason):
        if (reason == InfoKeptReason.notNewer) {
          await healAnnouncement(subject, servedVersion: served.version);
        }
    }
    return verdict;
  }

  /// Asks the group that owns [home]'s key for it, at most once an hour per
  /// subject (the first time at once).
  Future<bool> requestKey(InfoKeyHome home) async {
    final id = '${home.keySubjectKind}|${home.keySubjectId}';
    final now = _clock();
    if (topology.sendHeld(home.conversationId)) return false;
    if (!mayRequestInfoKey(_lastAsked[id], now)) return false;
    _lastAsked[id] = now;
    var sent = false;
    try {
      sent = await send(
        home.conversationId,
        AppPayloadType.infoKeyRequest,
        infoKeyRequestBody(
            subjectKind: home.keySubjectKind, subjectId: home.keySubjectId),
      );
      return sent;
    } finally {
      // A paused group or a failed queue write did not send a request.
      if (!sent && _lastAsked[id] == now) _lastAsked.remove(id);
    }
  }

  /// The device that committed an add delivers the current key immediately,
  /// without waiting for the joiner to ask. Call only after merging that
  /// accepted commit. The ordinary send path orders this after the commit
  /// and Welcome; a pending removal leaves delivery to its rotation.
  ///
  /// Announcements accepted before the join are sent again where this
  /// account may author them. Without them a new member cannot authenticate
  /// the fetched records. Missing keys are requested, never minted here.
  Future<bool> deliverAfterAdd(InfoKeyHome home, String communityId,
          Iterable<InfoSubject> subjects) =>
      _serializeWrites(() async {
        try {
          await _checkWritable(home);
        } on InfoRotationPending {
          return false;
        }
        final key = await currentKey(home, communityId);
        if (key == null) {
          await requestKey(home);
          return false;
        }
        final records = <InfoSubject, AcceptedCommunityInfo>{};
        final policy = policyFor(communityId);
        for (final subject in subjects) {
          final at = homeOf(subject);
          if (subject.communityId != communityId ||
              at?.conversationId != home.conversationId ||
              at?.keySubjectKind != home.keySubjectKind ||
              at?.keySubjectId != home.keySubjectId ||
              !policy.mayEdit(accountId, subject.kind)) {
            continue;
          }
          final accepted =
              await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
          if (accepted?.keyId == key.keyId) records[subject] = accepted!;
        }
        // A removal or remote rotation may have arrived during the reads.
        if ((await currentKey(home, communityId))?.keyId != key.keyId) {
          return false;
        }
        try {
          await _checkWritable(home);
        } on InfoRotationPending {
          return false;
        }
        if (!await send(
            home.conversationId,
            AppPayloadType.infoKey,
            infoKeyBody(
                subjectKind: home.keySubjectKind,
                subjectId: home.keySubjectId,
                key: key.key!))) {
          return false;
        }
        for (final entry in records.entries) {
          try {
            await _checkWritable(home);
          } on InfoRotationPending {
            return false;
          }
          if (!await _announce(entry.key, home, entry.value.revision,
              entry.value.keyId, entry.value.blob)) {
            return false;
          }
        }
        return true;
      });

  /// Answers key requests for [home] that no key has followed yet. Only an
  /// owner or admin answers, after a short random wait, and only in the group
  /// that owns the key: a request for a private channel's key made in the
  /// shared group is never answered there.
  Future<int> answerRequests(InfoKeyHome home, String communityId) async {
    final id =
        '${home.conversationId}|${home.keySubjectKind}|${home.keySubjectId}';
    final running = _answerRuns[id];
    if (running != null) return running;
    final run = _serializeWrites(() => _answerRequests(home, communityId));
    _answerRuns[id] = run;
    try {
      return await run;
    } finally {
      _answerRuns.remove(id);
    }
  }

  Future<int> _answerRequests(InfoKeyHome home, String communityId) async {
    // Who answers follows who rotates: the verified C4 record's owner and
    // admins when one is held (a moderator only in a private channel with
    // no owner or admin among its members, whatever the server says), else
    // the server's word, as before C4.
    if (!_mayRotate(communityId, home) ||
        topology.sendHeld(home.conversationId)) {
      return 0;
    }
    if (await currentKey(home, communityId) == null) return 0;
    final requests = (await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.keyRequest,
            home.keySubjectKind,
            home.keySubjectId))
        .where((r) =>
            mayDeliverInfoKey(home, r.conversationId) &&
            r.senderDeviceId != deviceId &&
            !_answered.contains('${r.ident}#${r.seq}') &&
            // One answer per asking device and key home per hour, however
            // often it asks: a member repeating requests cannot make every
            // admin send the key and every record again and again.
            mayRequestInfoKey(
                _answeredDevice[
                    '${r.senderDeviceId}|${home.keySubjectKind}|${home.keySubjectId}'],
                _clock()))
        .toList();
    if (requests.isEmpty) return 0;
    await Future<void>.delayed(_answerDelay());
    // The write queue keeps rotation from replacing the selected key during
    // the delay. A new removal mark still cancels this answer until rotation.
    try {
      await _checkWritable(home);
    } on InfoRotationPending {
      return 0;
    }
    // Another admin's rotation may have arrived over MLS during the delay.
    final key = await currentKey(home, communityId);
    if (key == null) return 0;
    // Only a trusted delivery of the current key answers a request. An
    // unrelated member key must not suppress delivery to a joiner.
    final deliverer = _deliverers(home, communityId);
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final lastKeySeq = keys
        .where((k) =>
            k.conversationId == home.conversationId &&
            k.keyId == key.keyId &&
            (k.senderAccountId == accountId || deliverer(k.senderAccountId)))
        .fold<int>(0, (m, k) => max(m, k.seq ?? 0));
    final open = requests.where((r) => (r.seq ?? 0) > lastKeySeq).toList();
    final sent = open.isEmpty ||
        await send(
          home.conversationId,
          AppPayloadType.infoKey,
          infoKeyBody(
              subjectKind: home.keySubjectKind,
              subjectId: home.keySubjectId,
              key: key.key!),
        );
    if (!sent) return 0;
    // A device that asks is new to the group (a joiner, a new or restored
    // device): it never saw the announcements made before it came. Announce
    // again, as this admin, every record under this key that this device
    // accepted.
    for (final subject in _shownSubjects.values.toList()) {
      try {
        await _checkWritable(home);
      } on InfoRotationPending {
        return 0;
      }
      final at = homeOf(subject);
      if (at == null ||
          at.conversationId != home.conversationId ||
          at.keySubjectId != home.keySubjectId) {
        continue;
      }
      final accepted =
          await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
      if (accepted == null || accepted.keyId != key.keyId) continue;
      try {
        await _checkWritable(home);
      } on InfoRotationPending {
        return 0;
      }
      if (!await _announce(
          subject, home, accepted.revision, accepted.keyId, accepted.blob)) {
        return 0;
      }
    }
    // A key alone is insufficient for a joiner: retry failed announcements
    // before consuming the request's hourly allowance, even if the key was
    // already delivered by this device or another admin.
    try {
      await _checkWritable(home);
    } on InfoRotationPending {
      return 0;
    }
    for (final r in requests) {
      _answered.add('${r.ident}#${r.seq}');
      _answeredDevice[
              '${r.senderDeviceId}|${home.keySubjectKind}|${home.keySubjectId}'] =
          _clock();
    }
    return open.isEmpty ? 0 : 1;
  }

  /// Marks [home]'s key for rotation (D80: at once on a kick or ban; a
  /// private channel's on a removal from it). Kept across restarts. A new
  /// mark for a key already due replaces the old one, so a pass that started
  /// before it does not clear it.
  Future<void> markRotationDue(InfoKeyHome home, String communityId) =>
      _locked(() async {
        final due = await _dueRotations();
        due['${home.keySubjectKind}|${home.keySubjectId}'] = <String, Object?>{
          'c': communityId,
          'e': await _removalEpoch(home),
          't': '${_clock().microsecondsSinceEpoch}.${_marks++}',
        };
        await _saveDue(due);
        _backoff.remove('${home.keySubjectKind}|${home.keySubjectId}');
      });

  /// Owner decision B (2026-11-11): an owner or admin who is a member of a
  /// private channel's group, and finds only a moderator's key current there
  /// (the second choice in [currentKey]), mints its own. This marks [home]'s
  /// key due and returns true; the pass then runs as for a removal this
  /// device did not make: it waits its turn ([remoteRotationDelay], over the
  /// verified owners and admins), so of several owner and admin devices that
  /// joined, one mints and the others adopt its key ([_rotatedElsewhere],
  /// where a moderator's key never counts while an owner or admin is a
  /// member). While the mark is due this device neither edits nor answers
  /// requests under the moderator's key ([_checkWritable]).
  ///
  /// Nothing is marked for the community key, without a verified record or
  /// a known roster, for a device not holding the moderator's key (it could
  /// not seal the records again), while an owner's or admin's key (this
  /// account's included) is current, or while a mark for [home] is already
  /// due (that pass mints, as the moderator's key does not end it).
  Future<bool> replaceModeratorKey(InfoKeyHome home, String communityId) async {
    if (home.keySubjectKind != infoKindChannel) return false;
    final roles = verifiedRolesOf?.call(communityId);
    final members = membersOf?.call(home.conversationId);
    if (roles == null ||
        members == null ||
        !members.contains(accountId) ||
        roles.rankOf(accountId) < BuiltInRole.admin.rank) {
      return false;
    }
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final policy = policyFor(communityId);
    bool admin(String account) =>
        account == accountId || policy.mayEdit(account, infoKindCommunity);
    if (await _freshest(home, keys, admin) != null) return false;
    if (await currentKey(home, communityId) == null) return false;
    return _locked(() async {
      final due = await _dueRotations();
      final id = '${home.keySubjectKind}|${home.keySubjectId}';
      if (due.containsKey(id)) return false;
      final now = _clock();
      due[id] = <String, Object?>{
        'c': communityId,
        'e': await _removalEpoch(home),
        't': '${now.microsecondsSinceEpoch}.${_marks++}',
        'd': true,
        'o': now.microsecondsSinceEpoch,
      };
      await _saveDue(due);
      _backoff.remove(id);
      return true;
    });
  }

  int _marks = 0;
  Future<void> _lock = Future<void>.value();
  final Map<String, ({int failures, DateTime next})> _backoff = {};

  /// Runs [body] after every earlier locked step: the due list is read,
  /// changed and written by one step at a time.
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Map<String, Object?>>> _dueRotations() async {
    final raw = await store.loadSetting(_rotationSetting);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            if (e.key is String &&
                e.value is Map &&
                (e.value as Map)['c'] is String)
              e.key as String: Map<String, Object?>.from(e.value as Map)
        };
      }
    } on FormatException {
      // A broken list is dropped; the next removal marks again.
    }
    return {};
  }

  Future<void> _saveDue(Map<String, Map<String, Object?>> due) =>
      store.saveSetting(_rotationSetting, jsonEncode(due));

  /// Changes one entry only if it is still the mark [token] (no newer mark
  /// replaced it meanwhile). [change] null removes it.
  Future<void> _updateMark(String id, Object? token,
          Map<String, Object?>? Function(Map<String, Object?> entry) change) =>
      _locked(() async {
        final due = await _dueRotations();
        final entry = due[id];
        if (entry == null || entry['t'] != token) return;
        final next = change(entry);
        if (next == null) {
          due.remove(id);
        } else {
          due[id] = next;
        }
        await _saveDue(due);
      });

  /// The keys due for rotation, by their keyed subject (for tests and
  /// screens).
  Future<Set<String>> dueRotations() async =>
      (await _dueRotations()).keys.toSet();

  /// Runs every due rotation this device should run: a new key, sent at once
  /// into the owning group (the send waits for the removal commit, D68, so
  /// the removed member never gets it), then every record under the old key
  /// sealed again and announced. [subjectsUnder] lists the records a key
  /// covers.
  ///
  /// - A mark whose group or community this device cannot place yet stays.
  /// - A group still holding sends for the removal is skipped and stays.
  /// - Only owners and admins rotate: by the verified role record when one
  ///   is held (a moderator never rotates, whatever the server says), else
  ///   by the server's word.
  /// - A removal this device did not ask for waits its turn
  ///   ([remoteRotationDelay]); its own removals rotate at once.
  /// - A fresh key another owner or admin device already delivered ends the
  ///   obligation without a new key ([_rotatedElsewhere]): any device then
  ///   completes; an owner or admin first seals again, under that key, any
  ///   record still under a retired one, once its own turn has come.
  /// - Other devices keep the mark in case this account is promoted later.
  /// - A retry reuses the key it already made and sent; failures back off.
  Future<int> runRotations(
          List<InfoSubject> Function(InfoKeyHome home, String communityId)
              subjectsUnder) =>
      _serializeWrites(() => _runRotations(subjectsUnder));

  /// The private channels' conversations whose due rotation no device can
  /// run: under the verified role record, none of the owner, admins and
  /// moderators is a member of the channel's MLS group ([membersOf], from
  /// the group's own tree). The obligation waits until one joins; the app
  /// tells the channel so. Marks without a verified record, an unplaced
  /// channel or an unknown roster are left out (nothing is known to be
  /// stuck).
  Future<Set<String>> rotationsWithoutRotator(
      Set<String>? Function(String conversationId) membersOf) async {
    final due = await _locked(_dueRotations);
    final stuck = <String>{};
    for (final entry in due.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 2 || parts[0] != infoKindChannel) continue;
      final roles = verifiedRolesOf?.call(entry.value['c'] as String);
      if (roles == null) continue;
      final conversation = topology.privateConversationOf(parts[1]);
      if (conversation == null) continue;
      final members = membersOf(conversation);
      if (members == null) continue;
      if (verifiedRotators(roles).any(members.contains) ||
          verifiedModerators(roles).any(members.contains)) {
        continue;
      }
      stuck.add(conversation);
    }
    return stuck;
  }

  /// Where a due mark's key lives now, or null while topology cannot place
  /// it.
  InfoKeyHome? _homeOfMark(String id, String communityId) {
    final parts = id.split('|');
    if (parts.length != 2) return null;
    if (parts[0] == infoKindCommunity) {
      return homeOf(InfoSubject(infoKindCommunity, communityId, communityId));
    }
    // A private channel's key lives in its own group only: never fall back
    // to the community's.
    final conversation = topology.privateConversationOf(parts[1]);
    return conversation == null
        ? null
        : InfoKeyHome(
            keySubjectKind: infoKindChannel,
            keySubjectId: parts[1],
            conversationId: conversation);
  }

  /// Whether this account may rotate [home]'s key in [communityId]: owner
  /// or admin in the verified record when one is held, or a verified
  /// moderator member of a private channel with no owner or admin among its
  /// members ([_noAdminModerators]); else by the server's word.
  bool _mayRotate(String communityId, InfoKeyHome home) {
    final roles = verifiedRolesOf?.call(communityId);
    if (roles != null) {
      return roles.rankOf(accountId) >= BuiltInRole.admin.rank ||
          (_noAdminModerators(home, communityId)?.contains(accountId) ?? false);
    }
    return topology.serverSaysAdmin(communityId) == true;
  }

  /// When a deferred mark's turn comes, or null for a mark that runs at
  /// once (this device's own removal, or a pass that already made its key).
  DateTime? _turnOf(
      Map<String, Object?> mark, InfoKeyHome home, String communityId) {
    if (mark['d'] != true || mark['k'] is String) return null;
    final observed = DateTime.fromMicrosecondsSinceEpoch(mark['o'] as int? ?? 0,
        isUtc: true);
    final from = observed.isAfter(_startedAt) ? observed : _startedAt;
    final epoch = mark['e'] as int? ?? 0;
    final roles = verifiedRolesOf?.call(communityId);
    // In a private channel with no owner or admin member, the order runs
    // over the verified moderators who are members.
    final rank = roles == null
        ? 0
        : remoteRotationRank(
            rotators: _noAdminModerators(home, communityId) ??
                verifiedRotators(roles),
            accountId: accountId,
            home: home,
            epoch: epoch);
    return from.add(remoteRotationDelay(
        rank: rank, deviceId: deviceId, home: home, epoch: epoch));
  }

  /// The current key when another device already rotated it for the last
  /// removal: [currentKey] (so fresher than that removal) and delivered in
  /// the owning group by a device other than this one, from an owner or
  /// admin under the verified record, or from a moderator member of a
  /// private channel with no owner or admin member ([_deliverers]). Null
  /// otherwise.
  ///
  /// This device's own copies never count: a key it made and stored but
  /// crashed before sending must not stand in for a delivery. Outside that
  /// no-admin case a moderator's key never counts, not even one from this
  /// account's other device.
  Future<CommunityInfoEvent?> _rotatedElsewhere(
      InfoKeyHome home, String communityId) async {
    final current = await currentKey(home, communityId);
    if (current == null) return null;
    final deliverer = _deliverers(home, communityId);
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final delivered = keys.any((k) =>
        k.keyId == current.keyId &&
        k.conversationId == home.conversationId &&
        k.senderDeviceId != deviceId &&
        deliverer(k.senderAccountId));
    return delivered ? current : null;
  }

  /// The earliest time a deferred rotation this device would run becomes
  /// due, or null when none waits. Passes are event driven; the app sets a
  /// timer for this.
  Future<DateTime?> nextDeferredRotation() async {
    final due = await _locked(_dueRotations);
    final now = _clock();
    DateTime? next;
    for (final entry in due.entries) {
      final communityId = entry.value['c'] as String;
      final home = _homeOfMark(entry.key, communityId);
      if (home == null || !_mayRotate(communityId, home)) continue;
      final turn = _turnOf(entry.value, home, communityId);
      if (turn == null || !turn.isAfter(now)) continue;
      if (next == null || turn.isBefore(next)) next = turn;
    }
    return next;
  }

  Future<void> _complete(InfoKeyHome home, String id, Object? token,
      Map<String, Object?> mark) async {
    await _checkWritable(home, rotationToken: token);
    // A later removal writes another epoch independently; completing this
    // pass never acknowledges that later obligation.
    await store.saveSetting(
        _rotatedSetting(home), (mark['e'] as int? ?? 0).toString());
    await _updateMark(id, token, (_) => null);
    _backoff.remove(id);
  }

  Future<int> _runRotations(
      List<InfoSubject> Function(InfoKeyHome home, String communityId)
          subjectsUnder) async {
    final due = await _locked(_dueRotations);
    var done = 0;
    for (final entry in due.entries) {
      final id = entry.key;
      final mark = entry.value;
      final token = mark['t'];
      final communityId = mark['c'] as String;
      if (id.split('|').length != 2 || topology.communityGone(communityId)) {
        await _updateMark(id, token, (_) => null);
        continue;
      }
      final home = _homeOfMark(id, communityId);
      if (home == null || topology.sendHeld(home.conversationId)) continue;
      final wait = _backoff[id];
      try {
        // A pass that already made its key finishes with it; otherwise
        // another owner or admin device's delivered rotation may already
        // cover this.
        final adopted = mark['k'] is String
            ? null
            : await _rotatedElsewhere(home, communityId);
        if (!_mayRotate(communityId, home)) {
          // An unknown role or a member without the right never makes a
          // key. It completes once an eligible device has rotated (its edits then use that
          // key); until then it keeps the mark, also for a later promotion.
          // Waiting is not a failure: no backoff.
          if (adopted == null) continue;
          if (wait != null && _clock().isBefore(wait.next)) continue;
          try {
            await _complete(home, id, token, mark);
            done++;
          } on InfoRotationPending {
            // A newer removal arrived meanwhile: its own mark decides.
          }
          continue;
        }
        final turn = _turnOf(mark, home, communityId);
        final early = turn != null && _clock().isBefore(turn);
        // Not this device's turn yet, and nobody else has rotated: wait.
        if (early && adopted == null) continue;
        if (wait != null && _clock().isBefore(wait.next)) continue;
        // Remember what the records say before the key changes.
        final records = <InfoSubject, CommunityInfoRecord>{};
        for (final subject in subjectsUnder(home, communityId)) {
          final verdict = await refresh(subject);
          // An existing record whose latest contents cannot be verified
          // must stay pending, rather than being skipped or overwritten
          // with an older cached record.
          if (verdict is InfoNeedsKey ||
              (verdict is InfoKept &&
                  verdict.reason != InfoKeptReason.notNewer)) {
            throw const InfoKeyMissing();
          }
          final shown = _shown[subject.key];
          if (verdict != null && shown == null) throw const InfoKeyMissing();
          if (shown != null) records[subject] = shown;
        }
        // A newer removal invalidates this pass: its key may already be
        // known to the newly removed member. Never publish under that key.
        await _checkWritable(home, rotationToken: token);
        if (adopted != null) {
          // Another device rotated: no second key. Records it has not sealed
          // again yet (it may still be doing so, or have stopped for good)
          // are sealed under its key once this device's turn has come.
          final stale = <InfoSubject, CommunityInfoRecord>{};
          for (final record in records.entries) {
            final accepted = await store.loadAcceptedCommunityInfo(
                record.key.kind, record.key.id);
            if (accepted?.keyId != adopted.keyId) {
              stale[record.key] = record.value;
            }
          }
          if (stale.isNotEmpty && early) continue;
          for (final record in stale.entries) {
            await _publish(
                record.key, (revision) => _copy(record.value, revision),
                withKey: adopted,
                rotationToken: token,
                expectedRevision: record.value.revision);
          }
          await _complete(home, id, token, mark);
          done++;
          continue;
        }
        // The key this mark already made, if any; otherwise a new one.
        final made = mark['k'] is String
            ? await _ownKey(home, mark['k'] as String)
            : null;
        final fresh = made ?? await newKey(home);
        if (made == null) {
          await _updateMark(id, token, (e) => {...e, 'k': fresh.keyId});
        }
        if (mark['s'] != true) {
          final delivered = await send(
            home.conversationId,
            AppPayloadType.infoKey,
            infoKeyBody(
                subjectKind: home.keySubjectKind,
                subjectId: home.keySubjectId,
                key: fresh.key!),
          );
          if (!delivered) throw const InfoKeyMissing();
          await _updateMark(
              id, token, (e) => {...e, 'k': fresh.keyId, 's': true});
        }
        for (final record in records.entries) {
          await _publish(
              record.key, (revision) => _copy(record.value, revision),
              withKey: fresh,
              rotationToken: token,
              expectedRevision: record.value.revision);
        }
        await _complete(home, id, token, mark);
        done++;
      } catch (_) {
        // A superseded pass must not delay the newer removal's rotation.
        if ((await _locked(_dueRotations))[id]?['t'] != token) continue;
        // Stays due, and waits longer each time (1 minute doubling to an
        // hour), so a failing re-seal never storms the group.
        final failures = (wait?.failures ?? 0) + 1;
        final minutes = min(60, 1 << min(failures - 1, 6));
        _backoff[id] = (
          failures: failures,
          next: _clock().add(Duration(minutes: minutes)),
        );
      }
    }
    return done;
  }

  static CommunityInfoRecord _copy(CommunityInfoRecord r, int revision) =>
      CommunityInfoRecord(
        kind: r.kind,
        subjectId: r.subjectId,
        revision: revision,
        name: r.name,
        topic: r.topic,
        icon: r.icon,
        categories: r.categories,
        channels: r.channels,
        privatePlace: r.privatePlace,
      );

  void _show(InfoSubject subject, CommunityInfoRecord record) {
    final held = _shown[subject.key];
    if (held != null && held.revision >= record.revision) return;
    _shown[subject.key] = record;
    _shownSubjects[subject.key] = subject;
    onChanged?.call();
  }
}
