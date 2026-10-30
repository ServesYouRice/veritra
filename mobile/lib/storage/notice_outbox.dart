import 'dart:convert';
import 'dart:math';

import '../core/models.dart';
import '../core/server_origin.dart';
import 'encrypted_database.dart'
    show LocalMessage, LocalMessageKind, LocalMessageState;

const localNoticeFreshnessMs = 10 * 60 * 1000;
const localNoticeBatchLimit = 200;
const localNoticeReferenceLimit = 100000;
const localNoticeMetadataLimit = 32 * 1024 * 1024;
const localNoticeDecisionReserve = 1024 * 1024;

enum LocalNoticeOutcome { shown, suppressed, unavailable }

/// A bounded fresh queue can recover through notice handling or stale pruning.
/// It must retry the atomic inbound commit rather than enter crypto recovery.
class LocalNoticeCapacityException implements Exception {
  const LocalNoticeCapacityException();
  @override
  String toString() => 'Local notification outbox is full';
}

void _bounded(String value, [int maximum = 512]) {
  if (value.isEmpty ||
      utf8.encode(value).length > maximum ||
      value.contains('\u0000')) {
    throw const FormatException('invalid local notice metadata');
  }
}

class LocalNoticeOwner {
  const LocalNoticeOwner(
      {required this.origin, required this.accountId, required this.deviceId});
  final String origin, accountId, deviceId;
  void validate() {
    _bounded(origin, 2048);
    _bounded(accountId);
    _bounded(deviceId);
    if (canonicalizeServerOrigin(origin) != origin)
      throw const FormatException('invalid notice origin');
  }

  bool matchesSession(Session? session) =>
      session != null &&
      origin == session.baseUrl &&
      accountId == session.accountId &&
      deviceId == session.deviceId;
  void requireSession(Session? session) {
    validate();
    if (!matchesSession(session))
      throw StateError('local notice owner changed');
  }

  Map<String, Object?> toJson() =>
      {'origin': origin, 'account': accountId, 'device': deviceId};
  factory LocalNoticeOwner.fromJson(Map<String, Object?> json) =>
      LocalNoticeOwner(
          origin: json['origin'] as String,
          accountId: json['account'] as String,
          deviceId: json['device'] as String);
  @override
  bool operator ==(Object other) =>
      other is LocalNoticeOwner &&
      origin == other.origin &&
      accountId == other.accountId &&
      deviceId == other.deviceId;
  @override
  int get hashCode => Object.hash(origin, accountId, deviceId);
}

/// A private reference to an authenticated row, never a message/manifest copy.
class LocalNoticeReference {
  const LocalNoticeReference(
      {required this.owner,
      required this.eventId,
      required this.messageKey,
      required this.serverMessageId,
      required this.conversationId,
      this.channelId,
      required this.senderAccountId,
      required this.senderDeviceId,
      required this.createdAt,
      this.expiresAt,
      this.queuedAt = 0});
  final LocalNoticeOwner owner;
  final int eventId, createdAt, queuedAt;
  final int? expiresAt;
  final String messageKey,
      serverMessageId,
      conversationId,
      senderAccountId,
      senderDeviceId;
  final String? channelId;
  String get id => jsonEncode(
      [owner.origin, owner.accountId, owner.deviceId, eventId, messageKey]);
  void validate() {
    owner.validate();
    for (final value in [
      messageKey,
      serverMessageId,
      conversationId,
      senderAccountId,
      senderDeviceId
    ]) {
      _bounded(value);
    }
    if (channelId != null) _bounded(channelId!);
    if (eventId <= 0 ||
        createdAt < 0 ||
        queuedAt < 0 ||
        (expiresAt != null && expiresAt! < 0)) {
      throw const FormatException('invalid local notice metadata');
    }
  }

  bool stale(int now) =>
      createdAt < now - localNoticeFreshnessMs ||
      (queuedAt > 0 && queuedAt < now - localNoticeFreshnessMs) ||
      (expiresAt != null && expiresAt! <= now);
  LocalNoticeReference queued(int now) => LocalNoticeReference(
      owner: owner,
      eventId: eventId,
      messageKey: messageKey,
      serverMessageId: serverMessageId,
      conversationId: conversationId,
      channelId: channelId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      queuedAt: now);
  Map<String, Object?> toJson() => {
        'owner': owner.toJson(),
        'event': eventId,
        'key': messageKey,
        'server': serverMessageId,
        'conversation': conversationId,
        'channel': channelId,
        'sender_account': senderAccountId,
        'sender_device': senderDeviceId,
        'created': createdAt,
        'expires': expiresAt,
        'queued': queuedAt
      };
  factory LocalNoticeReference.fromJson(Map<String, Object?> json) =>
      LocalNoticeReference(
          owner: LocalNoticeOwner.fromJson(
              Map<String, Object?>.from(json['owner'] as Map)),
          eventId: json['event'] as int,
          messageKey: json['key'] as String,
          serverMessageId: json['server'] as String,
          conversationId: json['conversation'] as String,
          channelId: json['channel'] as String?,
          senderAccountId: json['sender_account'] as String,
          senderDeviceId: json['sender_device'] as String,
          createdAt: json['created'] as int,
          expiresAt: json['expires'] as int?,
          queuedAt: json['queued'] as int);
}

class LocalNoticeDecision {
  LocalNoticeDecision(
      {required this.id,
      required this.owner,
      required this.createdAt,
      this.state = 'pending',
      required List<String> referenceIds,
      required List<LocalNoticeReference> references})
      : referenceIds = List.unmodifiable(referenceIds),
        references = List.unmodifiable(references);
  final String id, state;
  final LocalNoticeOwner owner;
  final int createdAt;
  final List<String> referenceIds;
  final List<LocalNoticeReference> references;
  Map<String, Object?> toJson() => {
        'id': id,
        'owner': owner.toJson(),
        'created': createdAt,
        'state': state,
        'reference_ids': referenceIds
      };
  factory LocalNoticeDecision.fromJson(
          Map<String, Object?> json, List<LocalNoticeReference> refs) =>
      LocalNoticeDecision(
          id: json['id'] as String,
          owner: LocalNoticeOwner.fromJson(
              Map<String, Object?>.from(json['owner'] as Map)),
          createdAt: json['created'] as int,
          state: json['state'] as String,
          referenceIds: (json['reference_ids'] as List).cast<String>(),
          references: refs);
  LocalNoticeDecision terminal(String status) => LocalNoticeDecision(
      id: id,
      owner: owner,
      createdAt: createdAt,
      state: status,
      referenceIds: const [],
      references: const []);
}

String newLocalNoticeDecisionId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

void validateLocalNoticeDecisionId(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value))
    throw const FormatException('invalid local notice decision');
}

List<String> localNoticeIds(Iterable<String> input) {
  final ids = input.toList(growable: false);
  if (ids.length > localNoticeBatchLimit || ids.toSet().length != ids.length) {
    throw ArgumentError('invalid notice batch');
  }
  for (final id in ids) {
    _bounded(id, 4096);
  }
  return ids;
}

/// Called after effects, while the ratchet/cursor transaction still owns its
/// fence. Pre-existing rows (including promoted imports) never produce notices.
List<LocalNoticeReference> validLocalNoticeReferences(
    {required Session? session,
    required List<LocalNoticeReference> references,
    required Set<String> previousKeys,
    required Map<String, LocalMessage> rows,
    required int cursor,
    required int now}) {
  if (references.length > localNoticeBatchLimit)
    throw StateError('notice batch limit reached');
  final result = <String, LocalNoticeReference>{};
  for (final ref in references) {
    ref.validate();
    ref.owner.requireSession(session);
    if (previousKeys.contains(ref.messageKey)) continue;
    final row = rows[ref.messageKey];
    if (row == null ||
        ref.stale(now) ||
        row.state != LocalMessageState.received ||
        row.senderAccountId == ref.owner.accountId ||
        row.senderHidden == true ||
        row.hiddenAt != null ||
        row.deletedAt != null ||
        row.editedAt != null ||
        !const {LocalMessageKind.text, LocalMessageKind.attachment}
            .contains(row.kind)) continue;
    if (ref.eventId != cursor ||
        row.key != ref.messageKey ||
        row.serverMessageId != ref.serverMessageId ||
        row.conversationId != ref.conversationId ||
        row.channelId != ref.channelId ||
        row.senderAccountId != ref.senderAccountId ||
        row.senderDeviceId != ref.senderDeviceId ||
        row.createdAt != ref.createdAt ||
        row.expiresAt != ref.expiresAt)
      throw StateError('notice reference does not match committed row');
    result[ref.id] = ref.queued(now);
  }
  return result.values.toList(growable: false);
}

/// Test-store parity engine. Production SQL uses indexed rows/usage counters.
class LocalNoticeState {
  LocalNoticeState(
      {Map<String, LocalNoticeReference>? references,
      Map<String, LocalNoticeDecision>? decisions,
      Map<String, String>? frozen})
      : references = references ?? {},
        decisions = decisions ?? {},
        frozen = frozen ?? {};
  final Map<String, LocalNoticeReference> references;
  final Map<String, LocalNoticeDecision> decisions;
  final Map<String, String> frozen;
  LocalNoticeState copy() => LocalNoticeState(
      references: Map.of(references),
      decisions: Map.of(decisions),
      frozen: Map.of(frozen));
  int get size =>
      references.values.fold(
          0, (int n, r) => n + utf8.encode(jsonEncode(r.toJson())).length) +
      decisions.values.fold(
          0, (int n, d) => n + utf8.encode(jsonEncode(d.toJson())).length);
  void checkCapacity({bool admission = false}) {
    if (references.length > localNoticeReferenceLimit ||
        decisions.length > localNoticeReferenceLimit ||
        size >
            localNoticeMetadataLimit -
                (admission ? localNoticeDecisionReserve : 0)) {
      throw const LocalNoticeCapacityException();
    }
  }

  void prune(LocalNoticeOwner owner, int now) {
    references.removeWhere((id, r) {
      if (r.owner != owner || !r.stale(now)) return false;
      frozen.remove(id);
      return true;
    });
    for (final d in decisions.values.toList()) {
      if (d.owner != owner) continue;
      if (d.state == 'pending' && !d.referenceIds.any(references.containsKey)) {
        decisions[d.id] = d.terminal('suppressed');
      } else if (d.state != 'pending' &&
          d.createdAt < now - localNoticeFreshnessMs) {
        decisions.remove(d.id);
      }
    }
  }

  List<LocalNoticeReference> pending(LocalNoticeOwner owner, int limit) {
    if (limit < 1 || limit > localNoticeBatchLimit)
      throw ArgumentError('invalid notice batch limit');
    final list = references.values
        .where((r) => r.owner == owner && !frozen.containsKey(r.id))
        .toList()
      ..sort((a, b) => a.eventId.compareTo(b.eventId));
    return list.take(limit).toList(growable: false);
  }

  LocalNoticeDecision? decision(LocalNoticeOwner owner) {
    for (final d in decisions.values) {
      if (d.owner == owner && d.state == 'pending') {
        return LocalNoticeDecision(
            id: d.id,
            owner: d.owner,
            createdAt: d.createdAt,
            referenceIds: d.referenceIds,
            references: d.referenceIds
                .map((id) => references[id])
                .whereType<LocalNoticeReference>()
                .toList());
      }
    }
    return null;
  }

  LocalNoticeDecision? freeze(
      LocalNoticeOwner owner, Iterable<String> input, int now) {
    final ids = localNoticeIds(input);
    if (ids.isEmpty) return null;
    final existing = decision(owner);
    if (existing != null)
      return existing.referenceIds.length == ids.length &&
              existing.referenceIds.toSet().containsAll(ids)
          ? existing
          : null;
    final refs = <LocalNoticeReference>[];
    for (final id in ids) {
      final r = references[id];
      if (r == null || r.owner != owner || frozen.containsKey(id))
        throw StateError('stale notice reference');
      refs.add(r);
    }
    final d = LocalNoticeDecision(
        id: newLocalNoticeDecisionId(),
        owner: owner,
        createdAt: now,
        referenceIds: ids,
        references: refs);
    decisions[d.id] = d;
    for (final id in ids) {
      frozen[id] = d.id;
    }
    checkCapacity();
    return d;
  }

  void suppress(LocalNoticeOwner owner, Iterable<String> input) {
    for (final id in localNoticeIds(input)) {
      final r = references[id];
      if (r == null) continue;
      if (r.owner != owner || frozen.containsKey(id))
        throw StateError('stale notice reference');
      references.remove(id);
    }
  }

  void suppressThrough(LocalNoticeOwner owner, int eventId) {
    references.removeWhere((id, ref) {
      if (ref.owner != owner || ref.eventId > eventId) return false;
      frozen.remove(id);
      return true;
    });
    for (final d in decisions.values.toList()) {
      if (d.owner == owner &&
          d.state == 'pending' &&
          !d.referenceIds.any(references.containsKey)) {
        decisions[d.id] = d.terminal('suppressed');
      }
    }
  }

  void finish(LocalNoticeOwner owner, String id, LocalNoticeOutcome outcome) {
    validateLocalNoticeDecisionId(id);
    final d = decisions[id];
    if (d == null || d.owner != owner)
      throw StateError('unknown notice decision');
    if (outcome == LocalNoticeOutcome.unavailable) return;
    final status = outcome.name;
    if (d.state != 'pending') {
      if (d.state != status)
        throw StateError('notice decision outcome conflict');
      return;
    }
    for (final id in d.referenceIds) {
      references.remove(id);
      frozen.remove(id);
    }
    decisions[d.id] = d.terminal(status);
  }
}
