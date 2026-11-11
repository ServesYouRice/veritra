part of 'app_state.dart';

// L1 complete adds (D94; docs/designs/L1-approved-devices.md, "Complete adds
// without a reported change" and "Incomplete-join notice"). The server's
// pending-change list is a hint, not the inventory: a conversation it never
// reports is still audited against the members' signed lists, and an
// approved device that stays out of a group is shown after a grace period.

/// Per conversation, per account: when discovery first found one of the
/// account's approved devices outside the group (JSON, milliseconds since
/// the epoch, UTC). Conversation and account ids only; no names or keys.
const String _l1MissingJoinsSetting = 'l1.missing_joins';

/// How many held groups one catch-up audits at most.
const int _l1JoinAuditBatch = 8;

/// The audit and notice state of one session. Cleared with the session.
class _L1JoinAudit {
  /// When each conversation may be audited again (memory only).
  final Map<String, DateTime> due = <String, DateTime>{};

  /// Conversation -> account -> first time a gap was seen.
  final Map<String, Map<String, DateTime>> missingSince =
      <String, Map<String, DateTime>>{};

  /// Conversations the last successful pending-change read reported. The
  /// reconcile pass covers them; the audit leaves them alone.
  Set<String> reported = <String>{};

  /// The session generation [missingSince] was read for.
  int? loadedFor;

  void clear() {
    due.clear();
    missingSince.clear();
    reported = <String>{};
    loadedFor = null;
  }
}

extension AppStateL1Joins on AppState {
  /// Accounts of [conversationId] with an approved device that has stayed
  /// out of the group for [l1IncompleteJoinGrace] or longer (design: "Some
  /// of <name>'s devices haven't joined yet").
  Set<String> incompleteJoinAccounts(String conversationId, {DateTime? now}) {
    final since = _l1Joins.missingSince[conversationId];
    if (since == null || since.isEmpty) return const <String>{};
    final at = now ?? DateTime.now().toUtc();
    return <String>{
      for (final entry in since.entries)
        if (at.difference(entry.value) >= l1IncompleteJoinGrace) entry.key,
    };
  }

  Future<void> _loadMissingJoins(Session current) async {
    final generation = _sessionGeneration;
    if (_l1Joins.loadedFor == generation) return;
    final loaded = <String, Map<String, DateTime>>{};
    try {
      final raw = await localStore.loadSetting(_l1MissingJoinsSetting);
      final stored = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      // Another identity's clocks (a relink, another account) are not ours.
      final value =
          stored is Map && stored['owner'] == _missingJoinsOwner(current)
              ? stored['joins']
              : null;
      if (value is Map) {
        for (final conversation in value.entries) {
          final accounts = conversation.value;
          if (conversation.key is! String || accounts is! Map) continue;
          final map = <String, DateTime>{};
          for (final account in accounts.entries) {
            if (account.key is String && account.value is int) {
              map[account.key as String] = DateTime.fromMillisecondsSinceEpoch(
                  account.value as int,
                  isUtc: true);
            }
          }
          if (map.isNotEmpty) loaded[conversation.key as String] = map;
        }
      }
    } on Object {
      // Unreadable: start the clocks again. The notice only comes later.
    }
    if (!_syncOwnerActive(current, generation)) return;
    // A gap seen in this session before the load finished keeps its time
    // unless the stored one is earlier.
    for (final entry in loaded.entries) {
      final live = _l1Joins.missingSince[entry.key];
      if (live == null) {
        _l1Joins.missingSince[entry.key] = entry.value;
        continue;
      }
      for (final account in entry.value.entries) {
        final seen = live[account.key];
        if (seen != null && account.value.isBefore(seen)) {
          live[account.key] = account.value;
        }
      }
    }
    _l1Joins.loadedFor = generation;
  }

  /// The identity the stored clocks belong to.
  static String _missingJoinsOwner(Session current) =>
      '${current.accountId}\u0000${current.deviceId}';

  Future<void> _saveMissingJoins() async {
    final current = session;
    if (current == null) return;
    final out = <String, Object?>{
      for (final conversation in _l1Joins.missingSince.entries)
        if (conversation.value.isNotEmpty)
          conversation.key: <String, int>{
            for (final account in conversation.value.entries)
              account.key: account.value.millisecondsSinceEpoch,
          },
    };
    try {
      await localStore.saveSetting(
          _l1MissingJoinsSetting,
          out.isEmpty
              ? ''
              : jsonEncode(<String, Object?>{
                  'owner': _missingJoinsOwner(current),
                  'joins': out,
                }));
    } on Object catch (err) {
      // Memory still holds the clocks; the next change writes them again.
      developer.log('l1_missing_joins_not_saved ${err.runtimeType}',
          name: 'veritra.l1');
    }
  }

  /// Records one completed discovery of [conversationId]: [unresolved] are
  /// the accounts with an approved device that is not a leaf of the local
  /// tree. Every other account is complete. Only the tree resolves a gap: a
  /// claimed package or a staged commit does not (the server may refuse or
  /// never sequence the bundle), so the clock keeps running until the next
  /// discovery finds the device in the group.
  Future<void> _noteMissingJoins(
      String conversationId, Set<String> unresolved, DateTime now) async {
    final before =
        _l1Joins.missingSince[conversationId] ?? const <String, DateTime>{};
    final next = <String, DateTime>{
      for (final account in unresolved) account: before[account] ?? now,
    };
    final changed = next.length != before.length ||
        next.entries.any((entry) => before[entry.key] != entry.value);
    if (!changed) return;
    if (next.isEmpty) {
      _l1Joins.missingSince.remove(conversationId);
    } else {
      _l1Joins.missingSince[conversationId] = next;
    }
    await _saveMissingJoins();
    notifyListeners();
  }

  /// The accounts [discovered] names.
  static Set<String> _gapAccounts(List<MlsDeviceRef> discovered) =>
      <String>{for (final ref in discovered) ref.accountId};

  /// Claims one package for each of [requested] by explicit ID. The server
  /// refuses a whole batch (403) when one device in it is revoked or off
  /// its head, which a stale pin can still list until repair: then each
  /// device is claimed alone and the refused ones are skipped, so one such
  /// device cannot keep its siblings out. Every answer must be a unique
  /// subset of [requested].
  Future<List<DeviceKeyPackage>> _claimListedDevices(Session current,
      ApiClient client, String conversationId, List<MlsDeviceRef> requested,
      {bool Function()? stillOwner}) async {
    if (requested.isEmpty) return const <DeviceKeyPackage>[];
    List<DeviceKeyPackage> packages;
    try {
      packages = await client.claimDeviceKeyPackages(current.token,
          conversationId, [for (final ref in requested) ref.deviceId]);
    } on ApiException catch (err) {
      if (err.statusCode != 403 || requested.length == 1) rethrow;
      packages = <DeviceKeyPackage>[];
      ApiException? refused;
      var anyAnswered = false;
      for (final ref in requested) {
        if (stillOwner != null && !stillOwner()) break;
        try {
          packages.addAll(await client.claimDeviceKeyPackages(
              current.token, conversationId, <String>[ref.deviceId]));
          anyAnswered = true;
        } on ApiException catch (one) {
          if (one.statusCode != 403) rethrow;
          refused = one;
        }
      }
      // Refused one by one as well: the requester itself is not allowed.
      if (!anyAnswered && refused != null) throw refused;
    }
    _checkDiscoveredPackages(requested, packages);
    return packages;
  }

  /// Audits held groups the server did not report as pending: approved
  /// devices of member accounts that are not leaves are claimed by their
  /// explicit IDs and staged. Bounded per pass and per conversation; a
  /// revoked session (401) ends it, anything else waits a full interval.
  Future<void> _auditCompleteAdds(Session current, int ownerGeneration) async {
    final client = api;
    final mls = _mlsCrypto;
    if (client == null || mls == null) return;
    if (mls is! ApprovedDeviceDiscoveryCryptoService) return;
    final discovery = mls as ApprovedDeviceDiscoveryCryptoService;
    await _loadMissingJoins(current);
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final now = DateTime.now().toUtc();
    final held = <String>{for (final c in conversations) c.id};
    // Records of conversations this account no longer has are dropped.
    final stale = _l1Joins.missingSince.keys
        .where((id) => !held.contains(id))
        .toList(growable: false);
    if (stale.isNotEmpty) {
      for (final id in stale) {
        _l1Joins.missingSince.remove(id);
      }
      await _saveMissingJoins();
    }
    _l1Joins.due.removeWhere((id, _) => !held.contains(id));
    final candidates = <String>[
      for (final id in held)
        if (!_l1Joins.reported.contains(id) &&
            !(_l1Joins.due[id]?.isAfter(now) ?? false))
          id,
    ]..sort((a, b) {
        // Never audited first, then the longest overdue.
        final da = _l1Joins.due[a];
        final db = _l1Joins.due[b];
        if (da == null || db == null) {
          return da == null ? (db == null ? a.compareTo(b) : -1) : 1;
        }
        return da.compareTo(db);
      });
    var staged = false;
    for (final id in candidates.take(_l1JoinAuditBatch)) {
      _l1Joins.due[id] = now.add(l1JoinAuditInterval);
      try {
        if (await _hasPendingMlsWork(id)) continue;
        final local = await mls.groupEpoch(id);
        // No group here, or a commit of this device is still out.
        if (local == null || local.pending) continue;
        final discovered =
            await _discoverApprovedAdds(current, client, discovery, id);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (discovered.isEmpty) {
          await _noteMissingJoins(id, const <String>{}, now);
          continue;
        }
        final accounts = _gapAccounts(discovered);
        final earlier = _l1Joins.missingSince[id];
        final firstSeen = <DateTime>[
          for (final account in accounts)
            if (earlier?[account] case final DateTime seen) seen,
        ].fold<DateTime>(now, (a, b) => b.isBefore(a) ? b : a);
        await _noteMissingJoins(id, accounts, now);
        // An honest server reports the change and names a coordinator:
        // give that the first turn.
        final waitUntil = firstSeen.add(reconcileFallback);
        if (now.isBefore(waitUntil)) {
          _l1Joins.due[id] = waitUntil.add(AppState._reconcileFallbackMargin);
          continue;
        }
        final adds = await _claimListedDevices(current, client, id, discovered,
            stillOwner: () => _syncOwnerActive(current, ownerGeneration));
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (adds.isEmpty) continue;
        await mls.stageMembershipChange(id,
            adds: adds, removes: const <MlsDeviceRef>[]);
        staged = true;
      } catch (err) {
        if (err is ApiException && err.statusCode == 401) rethrow;
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        // Body-free: no conversation, device or server text.
        developer.log(
            'l1_join_audit_failed '
            '${err is ApiException ? err.statusCode : err.runtimeType}',
            name: 'veritra.sync');
      }
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    if (staged) await _flushMlsOutbox();
  }
}
