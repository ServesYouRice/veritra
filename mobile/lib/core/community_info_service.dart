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
        LocalStore;
import 'community_info_book.dart';

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
  /// server's word. Used only to pick who answers a key request, never to
  /// decide what is shown.
  bool serverSaysAdmin(String communityId);
}

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
    DateTime Function()? clock,
    Duration Function()? answerDelay,
    String settingPrefix = 'c3',
  })  : _clock = clock ?? DateTime.now,
        _answerDelay = answerDelay ?? _randomDelay,
        _rotationSetting = '$settingPrefix.rotation_due.$accountId';

  final LocalStore store;
  final InfoApi api;
  final InfoSend send;
  final InfoTopology topology;
  final CommunityInfoCodec codec;
  final InfoEditPolicy Function(String communityId) policyFor;
  final String accountId;
  final String deviceId;
  final void Function()? onChanged;
  final DateTime Function() _clock;
  final Duration Function() _answerDelay;
  final String _rotationSetting;

  final Map<String, CommunityInfoRecord> _shown = {};
  final Map<String, DateTime> _lastAsked = {};
  final Set<String> _answered = {};

  static final _random = Random.secure();
  static Duration _randomDelay() =>
      Duration(milliseconds: _random.nextInt(3000));

  /// The record shown for a subject, or null (use the legacy name or a
  /// placeholder).
  CommunityInfoRecord? shown(String kind, String id) => _shown['$kind|$id'];

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

  /// The key to seal with: the newest key in the owning group from an owner
  /// or admin under the verified role state, or from this account (a device
  /// trusts the keys its own account made).
  Future<CommunityInfoEvent?> currentKey(
      InfoKeyHome home, String communityId) async {
    final policy = policyFor(communityId);
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    CommunityInfoEvent? best;
    for (final k in keys) {
      if (k.conversationId != home.conversationId || k.key == null) continue;
      if (k.senderAccountId != accountId &&
          !policy.mayEdit(k.senderAccountId, infoKindCommunity)) {
        continue;
      }
      if (best == null || (k.seq ?? 0) > (best.seq ?? 0)) best = k;
    }
    return best;
  }

  /// Makes a fresh key for [home] and keeps it locally. Others get it by
  /// asking; [rotate] also sends it at once.
  Future<CommunityInfoEvent> newKey(InfoKeyHome home) async {
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
    );
    await store.recordOwnCommunityInfoEvents([event]);
    return event;
  }

  /// Seals and uploads a record for [subject], then announces it in the
  /// group that owns its key. [build] gets the revision the upload becomes.
  /// Retries a stale `If-Match` a few times. Returns the accepted record.
  Future<CommunityInfoRecord> publish(
    InfoSubject subject,
    CommunityInfoRecord Function(int revision) build, {
    int attempts = 3,
  }) async {
    final home = homeOf(subject);
    if (home == null) throw StateError('C3 is not active here');
    final key =
        await currentKey(home, subject.communityId) ?? await newKey(home);
    for (var attempt = 0;; attempt++) {
      final served = await api.get(
          kind: subject.kind,
          subjectId: subject.id,
          communityId: subject.communityId);
      final version = served?.version ?? 0;
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
      await send(
        home.conversationId,
        AppPayloadType.infoUpdate,
        infoUpdateBody(
          subjectKind: subject.kind,
          subjectId: subject.id,
          revision: stored,
          keyId: key.keyId!,
          recordSha256: CommunityInfoCodec.recordSha256(blob),
        ),
      );
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
      if (k.keyId != accepted.keyId || k.key == null) continue;
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

  /// Fetches and judges one subject. A missing record (404) never clears
  /// what is shown. A missing key asks the group for it.
  Future<InfoVerdict?> refresh(InfoSubject subject) async {
    final home = homeOf(subject);
    if (home == null) return null;
    if (!_shown.containsKey(subject.key)) await loadAccepted(subject);
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
      case InfoKept():
        break;
    }
    return verdict;
  }

  /// Asks the group that owns [home]'s key for it, at most once an hour per
  /// subject (the first time at once).
  Future<bool> requestKey(InfoKeyHome home) async {
    final id = '${home.keySubjectKind}|${home.keySubjectId}';
    final now = _clock();
    if (!mayRequestInfoKey(_lastAsked[id], now)) return false;
    _lastAsked[id] = now;
    return send(
      home.conversationId,
      AppPayloadType.infoKeyRequest,
      infoKeyRequestBody(
          subjectKind: home.keySubjectKind, subjectId: home.keySubjectId),
    );
  }

  /// Answers key requests for [home] that no key has followed yet. Only an
  /// owner or admin answers, after a short random wait, and only in the group
  /// that owns the key: a request for a private channel's key made in the
  /// shared group is never answered there.
  Future<int> answerRequests(InfoKeyHome home, String communityId) async {
    if (!topology.serverSaysAdmin(communityId)) return 0;
    final key = await currentKey(home, communityId);
    if (key == null) return 0;
    final requests = (await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.keyRequest,
            home.keySubjectKind,
            home.keySubjectId))
        .where((r) =>
            mayDeliverInfoKey(home, r.conversationId) &&
            r.senderAccountId != accountId &&
            !_answered.contains(r.ident))
        .toList();
    if (requests.isEmpty) return 0;
    await Future<void>.delayed(_answerDelay());
    // Skip what another member already answered meanwhile.
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final lastKeySeq = keys
        .where((k) => k.conversationId == home.conversationId)
        .fold<int>(0, (m, k) => max(m, k.seq ?? 0));
    final open = requests.where((r) => (r.seq ?? 0) > lastKeySeq).toList();
    for (final r in requests) {
      _answered.add(r.ident);
    }
    if (open.isEmpty) return 0;
    final sent = await send(
      home.conversationId,
      AppPayloadType.infoKey,
      infoKeyBody(
          subjectKind: home.keySubjectKind,
          subjectId: home.keySubjectId,
          key: key.key!),
    );
    return sent ? 1 : 0;
  }

  /// Marks [home]'s key for rotation (D80: at once on a kick or ban; a
  /// private channel's on a removal from it). Kept across restarts.
  Future<void> markRotationDue(InfoKeyHome home, String communityId) async {
    final due = await _dueRotations();
    due['${home.keySubjectKind}|${home.keySubjectId}'] = communityId;
    await store.saveSetting(_rotationSetting, jsonEncode(due));
  }

  Future<Map<String, String>> _dueRotations() async {
    final raw = await store.loadSetting(_rotationSetting);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String
        };
      }
    } on FormatException {
      // A broken mark is dropped; the next removal marks again.
    }
    return {};
  }

  /// Runs every due rotation: a new key, sent at once into the owning group
  /// (the send waits for the removal commit, D68, so the removed member never
  /// gets it), then every record under the old key sealed again and
  /// announced. [subjectsUnder] lists the records a key covers. A rotation
  /// that fails stays due.
  Future<int> runRotations(
      List<InfoSubject> Function(InfoKeyHome home, String communityId)
          subjectsUnder) async {
    final due = await _dueRotations();
    var done = 0;
    for (final entry in Map.of(due).entries) {
      final parts = entry.key.split('|');
      if (parts.length != 2) {
        due.remove(entry.key);
        continue;
      }
      final communityId = entry.value;
      final keyed = InfoSubject(parts[0], parts[1], communityId);
      final home = parts[0] == infoKindCommunity
          ? homeOf(InfoSubject(infoKindCommunity, communityId, communityId))
          : homeOf(keyed);
      if (home == null) {
        due.remove(entry.key);
        continue;
      }
      try {
        // Remember what the records say before the key changes.
        final records = <InfoSubject, CommunityInfoRecord>{};
        for (final subject in subjectsUnder(home, communityId)) {
          if (!_shown.containsKey(subject.key)) await loadAccepted(subject);
          final shown = _shown[subject.key];
          if (shown != null) records[subject] = shown;
        }
        final fresh = await newKey(home);
        final delivered = await send(
          home.conversationId,
          AppPayloadType.infoKey,
          infoKeyBody(
              subjectKind: home.keySubjectKind,
              subjectId: home.keySubjectId,
              key: fresh.key!),
        );
        if (!delivered) continue;
        for (final entry in records.entries) {
          await publish(entry.key, (revision) => _copy(entry.value, revision));
        }
        due.remove('${home.keySubjectKind}|${home.keySubjectId}');
        done++;
      } catch (_) {
        // Stays due; the next pass tries again.
      }
    }
    await store.saveSetting(_rotationSetting, jsonEncode(due));
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
    _shown[subject.key] = record;
    onChanged?.call();
  }
}
