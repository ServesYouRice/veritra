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
  final Map<String, InfoSubject> _shownSubjects = {};
  final Map<String, DateTime> _lastAsked = {};
  final Set<String> _answered = {};
  final Map<String, DateTime> _answeredDevice = {};
  final Map<String, Future<int>> _answerRuns = {};

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

  /// The key to seal with: of the keys in the owning group from this
  /// account or from an owner or admin under the verified role state, the
  /// one whose id FIRST arrived last. A later re-delivery of an old key (an
  /// admin answering with a key from before a rotation) never makes it
  /// current again.
  Future<CommunityInfoEvent?> currentKey(
      InfoKeyHome home, String communityId) async {
    final policy = policyFor(communityId);
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final firstSeen = <String, int>{};
    for (final k in keys) {
      if (k.conversationId != home.conversationId) continue;
      final id = k.keyId;
      if (id == null) continue;
      final seq = k.seq ?? 0;
      final held = firstSeen[id];
      if (held == null || seq < held) firstSeen[id] = seq;
    }
    CommunityInfoEvent? best;
    var bestSeq = -1;
    for (final k in keys) {
      if (k.conversationId != home.conversationId || k.key == null) continue;
      if (k.senderAccountId != accountId &&
          !policy.mayEdit(k.senderAccountId, infoKindCommunity)) {
        continue;
      }
      final first = firstSeen[k.keyId] ?? 0;
      if (first > bestSeq) {
        best = k;
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
  ///
  /// [mint] allows a new key when none is trusted: only when the keyed
  /// subject is being created. Otherwise a device without the key asks for
  /// it and throws [InfoKeyMissing], so no parallel key ever appears. An
  /// announcement that could not be queued is sent again by [refresh].
  Future<CommunityInfoRecord> publish(
    InfoSubject subject,
    CommunityInfoRecord Function(int revision) build, {
    int attempts = 3,
    bool mint = false,
    CommunityInfoEvent? withKey,
  }) async {
    final home = homeOf(subject);
    if (home == null) throw StateError('C3 is not active here');
    var key = withKey ?? await currentKey(home, subject.communityId);
    if (key == null) {
      if (!mint) {
        await requestKey(home);
        throw const InfoKeyMissing();
      }
      key = await newKey(home);
    }
    final accepted =
        await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
    for (var attempt = 0;; attempt++) {
      final served = await api.get(
          kind: subject.kind,
          subjectId: subject.id,
          communityId: subject.communityId);
      final version = served?.version ?? 0;
      // A server serving less than this device already accepted would make
      // the edit invisible to others (they keep the newer one): refuse.
      if (accepted != null && version < accepted.revision) {
        throw const InfoVersionConflict();
      }
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
      await _announce(subject, home, stored, key.keyId!, blob);
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
    final digest = CommunityInfoCodec.recordSha256(accepted.blob);
    final updates = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.update, subject.kind, subject.id);
    if (updates.any((u) =>
        u.revision == accepted.revision &&
        u.recordSha256 == digest &&
        u.conversationId == home.conversationId)) {
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

  /// Answers key requests for [home] that no key has followed yet. Only an
  /// owner or admin answers, after a short random wait, and only in the group
  /// that owns the key: a request for a private channel's key made in the
  /// shared group is never answered there.
  Future<int> answerRequests(InfoKeyHome home, String communityId) async {
    final id =
        '${home.conversationId}|${home.keySubjectKind}|${home.keySubjectId}';
    final running = _answerRuns[id];
    if (running != null) return running;
    final run = _answerRequests(home, communityId);
    _answerRuns[id] = run;
    try {
      return await run;
    } finally {
      _answerRuns.remove(id);
    }
  }

  Future<int> _answerRequests(InfoKeyHome home, String communityId) async {
    if (topology.serverSaysAdmin(communityId) != true ||
        topology.sendHeld(home.conversationId)) {
      return 0;
    }
    final key = await currentKey(home, communityId);
    if (key == null) return 0;
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
    // Skip what another member already answered meanwhile.
    final keys = await store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, home.keySubjectKind, home.keySubjectId);
    final lastKeySeq = keys
        .where((k) => k.conversationId == home.conversationId)
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
    for (final r in requests) {
      _answered.add('${r.ident}#${r.seq}');
      _answeredDevice[
              '${r.senderDeviceId}|${home.keySubjectKind}|${home.keySubjectId}'] =
          _clock();
    }
    if (open.isEmpty) return 0;
    // A device that asks is new to the group (a joiner, a new or restored
    // device): it never saw the announcements made before it came. Announce
    // again, as this admin, every record under this key that this device
    // accepted.
    for (final subject in _shownSubjects.values.toList()) {
      final at = homeOf(subject);
      if (at == null ||
          at.conversationId != home.conversationId ||
          at.keySubjectId != home.keySubjectId) {
        continue;
      }
      final accepted =
          await store.loadAcceptedCommunityInfo(subject.kind, subject.id);
      if (accepted == null) continue;
      await _announce(
          subject, home, accepted.revision, accepted.keyId, accepted.blob);
    }
    return 1;
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
          't': '${_clock().microsecondsSinceEpoch}.${_marks++}',
        };
        await _saveDue(due);
      });

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
  /// - Only owners and admins (server's word) rotate; a moderator's own mark
  ///   is dropped on its device (owner question: who rotates then).
  /// - A retry reuses the key it already made and sent; failures back off.
  Future<int> runRotations(
      List<InfoSubject> Function(InfoKeyHome home, String communityId)
          subjectsUnder) async {
    final due = await _locked(_dueRotations);
    var done = 0;
    for (final entry in due.entries) {
      final id = entry.key;
      final mark = entry.value;
      final token = mark['t'];
      final communityId = mark['c'] as String;
      final parts = id.split('|');
      if (parts.length != 2 || topology.communityGone(communityId)) {
        await _updateMark(id, token, (_) => null);
        continue;
      }
      final InfoKeyHome? home;
      if (parts[0] == infoKindCommunity) {
        home = homeOf(InfoSubject(infoKindCommunity, communityId, communityId));
      } else {
        // A private channel's key lives in its own group only: never fall
        // back to the community's.
        final conversation = topology.privateConversationOf(parts[1]);
        home = conversation == null
            ? null
            : InfoKeyHome(
                keySubjectKind: infoKindChannel,
                keySubjectId: parts[1],
                conversationId: conversation);
      }
      if (home == null || topology.sendHeld(home.conversationId)) continue;
      // Unknown (the member list failed to load) keeps the mark; only a
      // known non-admin drops it.
      final admin = topology.serverSaysAdmin(communityId);
      if (admin == null) continue;
      if (!admin) {
        await _updateMark(id, token, (_) => null);
        continue;
      }
      final wait = _backoff[id];
      if (wait != null && _clock().isBefore(wait.next)) continue;
      try {
        // Remember what the records say before the key changes.
        final records = <InfoSubject, CommunityInfoRecord>{};
        for (final subject in subjectsUnder(home, communityId)) {
          if (!_shown.containsKey(subject.key)) await loadAccepted(subject);
          final shown = _shown[subject.key];
          if (shown != null) records[subject] = shown;
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
          await publish(record.key, (revision) => _copy(record.value, revision),
              withKey: fresh);
        }
        await _updateMark(id, token, (_) => null);
        _backoff.remove(id);
        done++;
      } catch (_) {
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
