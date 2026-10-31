import 'dart:convert';

/// One conversation as the self-update policy sees it.
typedef SelfUpdateCandidate = ({
  String id,
  DateTime? lastActivity,
  int members,
});

/// When this device refreshes its own MLS leaf key in a conversation
/// (periodic self-update, docs/crypto.md change log 2026-10-31).
///
/// A device's leaf key changes only when it commits with an update path. A
/// device that never removes anyone would keep its first key for the life of
/// the group, so whoever copied it could read every later message. This
/// policy makes each device commit a path-only update:
///
/// - once shortly after it joins a group (fills its path in the tree);
/// - after it has sent [messageThreshold] application messages since its
///   last path commit;
/// - after [maxAge] since its last path commit when the conversation had
///   any activity since.
///
/// Each delay carries a jitter derived from this device and conversation,
/// so the members of a group do not all commit at the same moment. A
/// refusal or failure sets a back-off. The state is a small JSON value in
/// the encrypted local settings, bound to this account and device, so a
/// re-linked device starts over.
///
/// The policy only decides. AppState stages the commit through the D28
/// staged-commit path, only in a foreground pass, never while the group
/// has a removal pending.
class MlsSelfUpdatePolicy {
  MlsSelfUpdatePolicy({required this.accountId, required this.deviceId});

  /// Local setting the state is kept in.
  static const settingName = 'mls.self_update';

  /// Count trigger: application messages sent since the last path commit.
  static const messageThreshold = 100;

  /// Time trigger: age of the last path commit, with any activity since.
  static const maxAge = Duration(days: 7);

  /// Up to this much is added to [maxAge], per device and conversation.
  static const maxAgeJitter = Duration(hours: 12);

  /// A join update waits at least this long after the Welcome.
  static const joinDelay = Duration(seconds: 30);

  /// Join jitter grows with the group, since every device a commit adds
  /// joins at once: about a minute per member, at most [joinJitterMax].
  static const joinJitterPerMember = Duration(minutes: 1);
  static const joinJitterMax = Duration(hours: 3);

  /// Never two path commits closer than this in one conversation. It equals
  /// the server's default budget (`PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES`).
  static const minInterval = Duration(hours: 1);

  /// Back-off after another commit won the epoch, or a removal was pending.
  static const conflictBackoff = Duration(minutes: 10);

  /// Back-off after a refusal that will not pass soon: a server that does
  /// not accept update-only commits (older than this change) answers 400.
  static const refusedBackoff = Duration(hours: 24);

  /// Back-off after a local failure to stage.
  static const failureBackoff = Duration(minutes: 30);

  final String accountId;
  final String deviceId;
  final Map<String, _Record> _records = <String, _Record>{};

  /// True when the state changed since it was last saved.
  bool dirty = false;

  /// This device sent one application message in [conversationId].
  void recordSent(String conversationId) {
    final record = _records[conversationId];
    if (record == null) return; // seeded on the next pass instead
    record.sent++;
    dirty = true;
  }

  /// This device joined [conversationId] through a Welcome. Its leaf key is
  /// the one from a key package published earlier, so it updates soon.
  void recordJoined(String conversationId, DateTime now) {
    _records[conversationId] = _Record(joinedAt: now.toUtc());
    dirty = true;
  }

  /// This device's commit with an update path was accepted (a self-update,
  /// or a commit that removed someone), or it created the group with fresh
  /// keys.
  void recordPathCommit(String conversationId, DateTime now) {
    _records[conversationId] = _Record(last: now.toUtc());
    dirty = true;
  }

  /// The self-update for [conversationId] was refused or failed: wait
  /// [backoff] (plus jitter) before trying again.
  void recordBackoff(String conversationId, DateTime now, Duration backoff) {
    final at = now.toUtc();
    final record =
        _records.putIfAbsent(conversationId, () => _Record(last: at));
    record.notBefore = at.add(backoff).add(_jitter(
        '$conversationId|backoff|${at.millisecondsSinceEpoch}', backoff ~/ 2));
    dirty = true;
  }

  /// The conversations due for a self-update at [now], join updates first,
  /// then the count trigger, then the time trigger. A conversation seen for
  /// the first time (an existing group after an update to this version) is
  /// given a last update somewhere inside the past [maxAge], so devices
  /// that upgrade together spread their first updates over a week. Records
  /// of conversations no longer listed are dropped.
  List<String> due(Iterable<SelfUpdateCandidate> candidates, DateTime now) {
    now = now.toUtc();
    final listed = <String>{};
    final joins = <String>[];
    final counts = <String>[];
    final aged = <String>[];
    for (final candidate in candidates) {
      listed.add(candidate.id);
      final record = _records[candidate.id];
      if (record == null) {
        _records[candidate.id] = _Record(
            last: now.subtract(_jitter('${candidate.id}|seed', maxAge)));
        dirty = true;
        continue;
      }
      if (record.notBefore?.isAfter(now) ?? false) continue;
      final last = record.last;
      if (last == null) {
        final joinedAt = record.joinedAt ?? now;
        final spread = joinJitterPerMember * candidate.members;
        final wait = joinDelay +
            _jitter('${candidate.id}|join|${joinedAt.millisecondsSinceEpoch}',
                spread > joinJitterMax ? joinJitterMax : spread);
        if (!now.isBefore(joinedAt.add(wait))) joins.add(candidate.id);
        continue;
      }
      final age = now.difference(last);
      if (record.sent >= messageThreshold && age >= minInterval) {
        counts.add(candidate.id);
        continue;
      }
      final active = record.sent > 0 ||
          (candidate.lastActivity?.toUtc().isAfter(last) ?? false);
      final threshold = maxAge +
          _jitter('${candidate.id}|age|${last.millisecondsSinceEpoch}',
              maxAgeJitter);
      if (active && age >= threshold) aged.add(candidate.id);
    }
    // An empty list means nothing is loaded yet, not that every chat is
    // gone. A group joined moments ago may not be listed yet, so its join
    // record stays until it is long past.
    if (listed.isNotEmpty) {
      final before = _records.length;
      _records.removeWhere((id, record) =>
          !listed.contains(id) &&
          (record.last != null ||
              now.difference(record.joinedAt ?? now) > maxAge));
      if (_records.length != before) dirty = true;
    }
    return <String>[...joins, ...counts, ...aged];
  }

  /// A deterministic delay in [0, max) for this device and [salt].
  Duration _jitter(String salt, Duration max) {
    if (max <= Duration.zero) return Duration.zero;
    // FNV-1a, 32 bits: stable across runs and platforms.
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$deviceId|$salt')) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return Duration(
        microseconds: (max.inMicroseconds * (hash / 0x100000000)).floor());
  }

  String encode() => jsonEncode(<String, Object?>{
        'version': 1,
        'account': accountId,
        'device': deviceId,
        'groups': <String, Object?>{
          for (final entry in _records.entries) entry.key: entry.value.toJson(),
        },
      });

  /// The saved state, or a fresh one when [raw] is missing, unreadable or
  /// belongs to another account or device.
  static MlsSelfUpdatePolicy decode(String? raw,
      {required String accountId, required String deviceId}) {
    final policy =
        MlsSelfUpdatePolicy(accountId: accountId, deviceId: deviceId);
    if (raw == null) return policy;
    try {
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['version'] != 1 ||
          json['account'] != accountId ||
          json['device'] != deviceId) {
        return policy;
      }
      final groups = json['groups'];
      if (groups is Map) {
        for (final entry in groups.entries) {
          final record = _Record.fromJson(entry.value);
          if (entry.key is String && record != null) {
            policy._records[entry.key as String] = record;
          }
        }
      }
    } catch (_) {
      // Unreadable state starts over; the worst case is an early update.
    }
    return policy;
  }
}

class _Record {
  _Record({this.last, this.joinedAt});

  /// The last accepted path commit by this device, or null after a join
  /// until the join update lands.
  DateTime? last;
  DateTime? joinedAt;
  DateTime? notBefore;
  int sent = 0;

  Map<String, Object?> toJson() => <String, Object?>{
        if (last != null) 'last': last!.millisecondsSinceEpoch,
        if (joinedAt != null) 'joined': joinedAt!.millisecondsSinceEpoch,
        if (notBefore != null) 'not_before': notBefore!.millisecondsSinceEpoch,
        if (sent > 0) 'sent': sent,
      };

  static _Record? fromJson(Object? value) {
    if (value is! Map) return null;
    DateTime? at(Object? raw) => raw is int
        ? DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true)
        : null;
    final sent = value['sent'];
    final record =
        _Record(last: at(value['last']), joinedAt: at(value['joined']))
          ..notBefore = at(value['not_before'])
          ..sent = sent is int && sent > 0 ? sent : 0;
    if (record.last == null && record.joinedAt == null) return null;
    return record;
  }
}
