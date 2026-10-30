part of 'encrypted_database.dart';

extension LocalNoticeSql on EncryptedLocalDatabase {
  Future<void> _createNoticeOutbox() async {
    await customStatement('CREATE TABLE local_notice_references ('
        'identity TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL,'
        'device_id TEXT NOT NULL, event_id INTEGER NOT NULL, message_key TEXT NOT NULL,'
        'created_at INTEGER NOT NULL, queued_at INTEGER NOT NULL, expires_at INTEGER,'
        'decision_id TEXT, payload_json TEXT NOT NULL, size_bytes INTEGER NOT NULL,'
        'FOREIGN KEY(message_key) REFERENCES local_messages(key) ON DELETE CASCADE)');
    await customStatement(
        'CREATE INDEX local_notice_pending ON local_notice_references '
        '(origin,account_id,device_id,decision_id,event_id)');
    await customStatement(
        'CREATE INDEX local_notice_watermark ON local_notice_references '
        '(origin,account_id,device_id,event_id)');
    await customStatement('CREATE TABLE local_notice_decisions ('
        'id TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL,'
        'device_id TEXT NOT NULL, created_at INTEGER NOT NULL, state TEXT NOT NULL '
        "CHECK(state IN ('pending','shown','suppressed')), payload_json TEXT NOT NULL, size_bytes INTEGER NOT NULL)");
    await customStatement(
        'CREATE UNIQUE INDEX local_notice_one_pending ON local_notice_decisions '
        "(origin,account_id,device_id) WHERE state='pending'");
    await customStatement('CREATE TABLE local_notice_usage ('
        'singleton INTEGER PRIMARY KEY CHECK(singleton=1), refs INTEGER NOT NULL CHECK(refs>=0),'
        'decisions INTEGER NOT NULL CHECK(decisions>=0), size_bytes INTEGER NOT NULL CHECK(size_bytes>=0))');
    await customStatement('INSERT INTO local_notice_usage VALUES(1,0,0,0)');
    for (final (table, count) in [
      ('references', 'refs'),
      ('decisions', 'decisions')
    ]) {
      await customStatement(
          'CREATE TRIGGER local_notice_${table}_insert AFTER INSERT ON local_notice_$table '
          'BEGIN UPDATE local_notice_usage SET $count=$count+1,size_bytes=size_bytes+NEW.size_bytes WHERE singleton=1; END');
      await customStatement(
          'CREATE TRIGGER local_notice_${table}_delete AFTER DELETE ON local_notice_$table '
          'BEGIN UPDATE local_notice_usage SET $count=$count-1,size_bytes=size_bytes-OLD.size_bytes WHERE singleton=1; END');
      await customStatement(
          'CREATE TRIGGER local_notice_${table}_update AFTER UPDATE OF size_bytes ON local_notice_$table '
          'BEGIN UPDATE local_notice_usage SET size_bytes=size_bytes-OLD.size_bytes+NEW.size_bytes WHERE singleton=1; END');
    }
  }

  Future<void> clearNoticeOutbox() async {
    await customStatement('DELETE FROM local_notice_references');
    await customStatement('DELETE FROM local_notice_decisions');
    await customStatement(
        'UPDATE local_notice_usage SET refs=0,decisions=0,size_bytes=0 WHERE singleton=1');
  }

  List<Object> _noticeOwnerArgs(LocalNoticeOwner owner) =>
      [owner.origin, owner.accountId, owner.deviceId];
  static const _ownerWhere = 'origin=? AND account_id=? AND device_id=?';
  Selectable<QueryRow> _noticeSelect(String sql, List<Object> args) =>
      customSelect(sql,
          variables: args
              .map((v) => v is int
                  ? Variable.withInt(v)
                  : Variable.withString(v as String))
              .toList());
  Future<Session?> _noticeSession() async {
    final raw = await readSessionJson();
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map;
    return Session(
        baseUrl: json['base_url'] as String,
        token: '',
        accountId: json['account_id'] as String?,
        deviceId: json['device_id'] as String?);
  }

  Future<void> _noticePrune(LocalNoticeOwner owner, int now) async {
    final cutoff = now - localNoticeFreshnessMs;
    await customStatement(
        'DELETE FROM local_notice_references WHERE $_ownerWhere AND '
        '(created_at<? OR queued_at<? OR (expires_at IS NOT NULL AND expires_at<=?))',
        [..._noticeOwnerArgs(owner), cutoff, cutoff, now]);
    await customStatement(
        'DELETE FROM local_notice_decisions WHERE $_ownerWhere AND state<>? AND created_at<?',
        [..._noticeOwnerArgs(owner), 'pending', cutoff]);
    await _noticeSuppressEmptyDecisions(owner);
  }

  Future<void> _noticeSuppressEmptyDecisions(LocalNoticeOwner owner) async {
    final orphaned = await _noticeSelect(
            'SELECT payload_json FROM local_notice_decisions d WHERE '
            "$_ownerWhere AND state='pending' AND NOT EXISTS (SELECT 1 FROM local_notice_references r WHERE r.decision_id=d.id)",
            _noticeOwnerArgs(owner))
        .get();
    for (final row in orphaned) {
      final d = LocalNoticeDecision.fromJson(
          Map<String, Object?>.from(
              jsonDecode(row.read<String>('payload_json')) as Map),
          const []);
      await _noticeWriteDecision(d.terminal('suppressed'));
    }
  }

  Future<T> _noticeWork<T>(LocalNoticeOwner owner, Future<T> Function(int) work,
          {int? now, void Function()? checkCanCommit}) =>
      transaction(() async {
        checkCanCommit?.call();
        owner.requireSession(await _noticeSession());
        final at = now ?? DateTime.now().millisecondsSinceEpoch;
        await _noticePrune(owner, at);
        final result = await work(at);
        checkCanCommit?.call();
        return result;
      });
  Future<void> _noticeCapacity({bool admission = false}) async {
    final usage =
        await customSelect('SELECT * FROM local_notice_usage WHERE singleton=1')
            .getSingle();
    if (usage.read<int>('refs') > localNoticeReferenceLimit ||
        usage.read<int>('decisions') > localNoticeReferenceLimit ||
        usage.read<int>('size_bytes') >
            localNoticeMetadataLimit -
                (admission ? localNoticeDecisionReserve : 0)) {
      throw const LocalNoticeCapacityException();
    }
  }

  Future<void> captureLocalNoticeReferences(
      List<LocalNoticeReference> references,
      Set<String> previousKeys,
      int cursor,
      int now) async {
    if (references.isEmpty) return;
    if (references.length > localNoticeBatchLimit)
      throw StateError('notice batch limit reached');
    final session = await _noticeSession();
    references.first.owner.requireSession(session);
    final rows = <String, LocalMessage>{};
    for (final ref in references) {
      final row = await (select(localMessages)
            ..where((t) => t.key.equals(ref.messageKey)))
          .getSingleOrNull();
      if (row != null) rows[row.key] = row;
    }
    final accepted = validLocalNoticeReferences(
        session: session,
        references: references,
        previousKeys: previousKeys,
        rows: rows,
        cursor: cursor,
        now: now);
    await _noticePrune(references.first.owner, now);
    for (final ref in accepted) {
      final json = jsonEncode(ref.toJson());
      await customStatement(
          'INSERT OR IGNORE INTO local_notice_references '
          '(identity,origin,account_id,device_id,event_id,message_key,created_at,queued_at,expires_at,payload_json,size_bytes) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [
            ref.id,
            ..._noticeOwnerArgs(ref.owner),
            ref.eventId,
            ref.messageKey,
            ref.createdAt,
            ref.queuedAt,
            ref.expiresAt,
            json,
            utf8.encode(json).length
          ]);
    }
    await _noticeCapacity(admission: true);
  }

  Future<List<LocalNoticeReference>> pendingNoticeReferences(
          LocalNoticeOwner owner,
          {int limit = localNoticeBatchLimit,
          int? now,
          void Function()? checkCanCommit}) =>
      _noticeWork(owner, (_) async {
        if (limit < 1 || limit > localNoticeBatchLimit)
          throw ArgumentError('invalid notice batch limit');
        final rows = await _noticeSelect(
            'SELECT payload_json FROM local_notice_references WHERE '
            '$_ownerWhere AND decision_id IS NULL ORDER BY event_id,identity LIMIT ?',
            [..._noticeOwnerArgs(owner), limit]).get();
        return rows
            .map((r) => LocalNoticeReference.fromJson(Map<String, Object?>.from(
                jsonDecode(r.read<String>('payload_json')) as Map)))
            .toList();
      }, now: now, checkCanCommit: checkCanCommit);
  Future<LocalNoticeDecision?> _noticePendingDecision(
      LocalNoticeOwner owner) async {
    final row = await _noticeSelect(
            'SELECT payload_json FROM local_notice_decisions WHERE '
            "$_ownerWhere AND state='pending' LIMIT 1",
            _noticeOwnerArgs(owner))
        .getSingleOrNull();
    if (row == null) return null;
    final json = Map<String, Object?>.from(
        jsonDecode(row.read<String>('payload_json')) as Map);
    final refs = await _noticeSelect(
        'SELECT payload_json FROM local_notice_references WHERE '
        '$_ownerWhere AND decision_id=? ORDER BY event_id,identity',
        [..._noticeOwnerArgs(owner), json['id'] as String]).get();
    return LocalNoticeDecision.fromJson(
        json,
        refs
            .map((r) => LocalNoticeReference.fromJson(Map<String, Object?>.from(
                jsonDecode(r.read<String>('payload_json')) as Map)))
            .toList());
  }

  Future<LocalNoticeDecision?> pendingNoticeDecision(LocalNoticeOwner owner,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeWork(owner, (_) => _noticePendingDecision(owner),
          now: now, checkCanCommit: checkCanCommit);
  Future<void> _noticeWriteDecision(LocalNoticeDecision d) async {
    final json = jsonEncode(d.toJson());
    await customStatement(
        'UPDATE local_notice_decisions SET state=?,payload_json=?,size_bytes=? WHERE id=? AND $_ownerWhere',
        [
          d.state,
          json,
          utf8.encode(json).length,
          d.id,
          ..._noticeOwnerArgs(d.owner)
        ]);
  }

  Future<LocalNoticeDecision?> freezeNoticeDecision(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeWork(owner, (at) async {
        final ids = localNoticeIds(referenceIds);
        if (ids.isEmpty) return null;
        final existing = await _noticePendingDecision(owner);
        if (existing != null)
          return existing.referenceIds.length == ids.length &&
                  existing.referenceIds.toSet().containsAll(ids)
              ? existing
              : null;
        final refs = <LocalNoticeReference>[];
        for (final id in ids) {
          final row = await _noticeSelect(
              'SELECT payload_json FROM local_notice_references WHERE identity=? AND '
              '$_ownerWhere AND decision_id IS NULL',
              [id, ..._noticeOwnerArgs(owner)]).getSingleOrNull();
          if (row == null) throw StateError('stale notice reference');
          refs.add(LocalNoticeReference.fromJson(Map<String, Object?>.from(
              jsonDecode(row.read<String>('payload_json')) as Map)));
        }
        final d = LocalNoticeDecision(
            id: newLocalNoticeDecisionId(),
            owner: owner,
            createdAt: at,
            referenceIds: ids,
            references: refs);
        final json = jsonEncode(d.toJson());
        await customStatement(
            'INSERT INTO local_notice_decisions VALUES(?,?,?,?,?,?,?,?)', [
          d.id,
          ..._noticeOwnerArgs(owner),
          at,
          d.state,
          json,
          utf8.encode(json).length
        ]);
        for (final id in ids) {
          await customStatement(
              'UPDATE local_notice_references SET decision_id=? WHERE identity=? AND $_ownerWhere AND decision_id IS NULL',
              [d.id, id, ..._noticeOwnerArgs(owner)]);
        }
        await _noticeCapacity();
        return d;
      }, now: now, checkCanCommit: checkCanCommit);
  Future<void> suppressNoticeReferences(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeWork(owner, (_) async {
        for (final id in localNoticeIds(referenceIds)) {
          final row = await _noticeSelect(
              'SELECT origin,account_id,device_id,decision_id FROM local_notice_references WHERE identity=?',
              [id]).getSingleOrNull();
          if (row == null) continue;
          if (row.read<String>('origin') != owner.origin ||
              row.read<String>('account_id') != owner.accountId ||
              row.read<String>('device_id') != owner.deviceId ||
              row.readNullable<String>('decision_id') != null) {
            throw StateError('stale notice reference');
          }
          await customStatement(
              'DELETE FROM local_notice_references WHERE identity=? AND $_ownerWhere',
              [id, ..._noticeOwnerArgs(owner)]);
        }
      }, now: now, checkCanCommit: checkCanCommit);
  Future<void> suppressNoticesThrough(LocalNoticeOwner owner, int eventId,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeWork(owner, (_) async {
        if (eventId < 0 || eventId > await readCursor())
          throw StateError('notice watermark is not committed');
        await customStatement(
            'DELETE FROM local_notice_references WHERE $_ownerWhere AND event_id<=?',
            [..._noticeOwnerArgs(owner), eventId]);
        await _noticeSuppressEmptyDecisions(owner);
      }, now: now, checkCanCommit: checkCanCommit);
  Future<void> finishNoticeDecision(
          LocalNoticeOwner owner, String decisionId, LocalNoticeOutcome outcome,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeWork(owner, (_) async {
        validateLocalNoticeDecisionId(decisionId);
        final row = await _noticeSelect(
            'SELECT payload_json FROM local_notice_decisions WHERE id=? AND $_ownerWhere',
            [decisionId, ..._noticeOwnerArgs(owner)]).getSingleOrNull();
        if (row == null) throw StateError('unknown notice decision');
        final d = LocalNoticeDecision.fromJson(
            Map<String, Object?>.from(
                jsonDecode(row.read<String>('payload_json')) as Map),
            const []);
        if (outcome == LocalNoticeOutcome.unavailable) return;
        if (d.state != 'pending') {
          if (d.state != outcome.name)
            throw StateError('notice decision outcome conflict');
          return;
        }
        await customStatement(
            'DELETE FROM local_notice_references WHERE decision_id=? AND $_ownerWhere',
            [decisionId, ..._noticeOwnerArgs(owner)]);
        await _noticeWriteDecision(d.terminal(outcome.name));
      }, now: now, checkCanCommit: checkCanCommit);
}
