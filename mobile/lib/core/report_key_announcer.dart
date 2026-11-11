import 'dart:convert';

import '../crypto/report_key_announcement.dart';
import '../storage/local_store.dart';

/// C6: the background half of "moderator keys over MLS"
/// (docs/designs/C6-reports-franking.md). Decides, per community this
/// account moderates under its verified record, whether this device
/// announces its report key (`report_key`) in the community's shared group
/// now ([run]), and, per community it belongs to, whether it asks for the
/// announcements it lacks (`report_key_request`, [askMissing]). Records what
/// it sent. Everything outside is injected, so the rules are tested without
/// MLS.
class ReportKeyAnnouncer {
  ReportKeyAnnouncer({
    required this.store,
    required this.listedKey,
    required this.send,
    this.sendRequest,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalStore store;

  /// The key the server lists as this account's moderator inbox in a
  /// community, or null when it lists none.
  final Future<List<int>?> Function(String communityId) listedKey;

  /// Queues a `report_key` with [key] into the shared group [group]. False
  /// when nothing was queued.
  final Future<bool> Function(String group, String key) send;

  /// Queues a `report_key_request` naming [accounts] into [group]. False
  /// when nothing was queued.
  final Future<bool> Function(String group, List<String> accounts)? sendRequest;
  final DateTime Function() _clock;

  /// Asks [group] for the announcements of [moderators] (the verified
  /// record's owner, admins and moderators, never this account) that this
  /// device holds none of, when due ([reportKeyRequestDue]). Runs for every
  /// community whether or not anyone reports, so a request says nothing
  /// about a report. Returns whether a request was queued.
  Future<bool> askMissing({
    required String group,
    required Set<String> moderators,
  }) async {
    final request = sendRequest;
    if (request == null) return false;
    final missing = <String>[];
    for (final account in moderators.toList()..sort()) {
      if (missing.length == maxReportKeyRequestAccounts) break;
      if (await store
              .loadSetting(reportKeyAnnouncementSetting(group, account)) ==
          null) {
        missing.add(account);
      }
    }
    final now = _clock().toUtc();
    if (!reportKeyRequestDue(
        missing: missing,
        asked: ReportKeyAsked.decode(
            await store.loadSetting(reportKeyAskedSetting(group))),
        now: now)) {
      return false;
    }
    if (!await request(group, missing)) return false;
    await store.saveSetting(
        reportKeyAskedSetting(group),
        ReportKeyAsked(accounts: missing, atMs: now.millisecondsSinceEpoch)
            .encode());
    return true;
  }

  /// Announces [key] (canonical base64) where it is due, for each
  /// `(communityId, sharedGroup)` in [moderated]. A group where the server
  /// does not list [key] is skipped and remembered in [unlisted] (group to
  /// key), so a key another device replaced is never announced back and the
  /// lookup is not repeated for the same key. [active] stops the pass (the
  /// session ended). Returns how many announcements were queued.
  Future<int> run({
    required String key,
    required List<(String, String)> moderated,
    required Map<String, String> unlisted,
    bool Function()? active,
  }) async {
    var queued = 0;
    for (final (communityId, group) in moderated) {
      if (active != null && !active()) break;
      if (unlisted[group] == key) continue;
      final sent = ReportKeySent.decode(
          await store.loadSetting(reportKeySentSetting(group)));
      final request = await store.loadSetting(reportKeyRequestSetting(group));
      final now = _clock().toUtc();
      if (!reportKeyAnnouncementDue(
          key: key, sent: sent, request: request, now: now)) {
        continue;
      }
      final listed = await listedKey(communityId);
      if (listed == null || base64Encode(listed) != key) {
        unlisted[group] = key;
        continue;
      }
      if (active != null && !active()) break;
      if (!await send(group, key)) continue;
      queued++;
      await store.saveSetting(
          reportKeySentSetting(group),
          ReportKeySent(
                  key: key, atMs: now.millisecondsSinceEpoch, answered: request)
              .encode());
    }
    return queued;
  }
}
