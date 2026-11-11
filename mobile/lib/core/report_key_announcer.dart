import 'dart:convert';

import '../crypto/report_key_announcement.dart';
import '../storage/local_store.dart';

/// C6: the moderator side of "moderator keys over MLS"
/// (docs/designs/C6-reports-franking.md). Decides, per community this
/// account moderates under its verified record, whether this device
/// announces its report key (`report_key`) in the community's shared group
/// now, and records what it sent. Everything outside is injected, so the
/// rules are tested without MLS.
class ReportKeyAnnouncer {
  ReportKeyAnnouncer({
    required this.store,
    required this.listedKey,
    required this.send,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalStore store;

  /// The key the server lists as this account's moderator inbox in a
  /// community, or null when it lists none.
  final Future<List<int>?> Function(String communityId) listedKey;

  /// Queues a `report_key` with [key] into the shared group [group]. False
  /// when nothing was queued.
  final Future<bool> Function(String group, String key) send;
  final DateTime Function() _clock;

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
