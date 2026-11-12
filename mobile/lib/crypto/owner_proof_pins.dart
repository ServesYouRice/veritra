import 'dart:convert';

import '../core/server_origin.dart' show canonicalizeServerOrigin;
import '../storage/local_store.dart';
import 'report_key_pins.dart' show ReportRecipientKey;

/// L2-3 (owner decision 2026-11-12, "Keep reports manual"): the instance
/// owners' report keys a sealed message's franking tags are designated to,
/// the "proof recipients". Kept apart from the D95 report pins
/// ([ReportKeyPins], `local_report_key_pins`), which only a person's code
/// comparison writes and which alone decide who a report is sealed to.
///
/// What is stored here (setting [ownerProofPinsSetting]) are overrides of
/// the D95 pins, for proofs only: a key pinned on first use or accepted on
/// the sealed key screen, or a tombstone for an owner the person accepted
/// as gone. The proof recipients ([effective]) are, per owner, the override
/// if there is one (a tombstone: none), else the owner's D95 pin. A
/// person's code comparison while reporting counts for proofs too: it drops
/// that owner's override ([followReportPin]). Nothing stored here ever
/// reaches a report.

/// The setting that keeps the proof overrides of one server origin: owner
/// account id to `{"key": base64, "rev": n, "at": ms}`, or to null for an
/// owner accepted as gone.
String ownerProofPinsSetting(String origin) =>
    'l2.owner_proof_pins:${canonicalizeServerOrigin(origin)}';

bool _isOwner(String inboxId) => !inboxId.contains(':');

class OwnerProofPins {
  OwnerProofPins(this.store, String origin, {DateTime Function()? clock})
      : origin = canonicalizeServerOrigin(origin),
        _clock = clock ?? DateTime.now;

  final LocalStore store;

  /// The canonical server origin.
  final String origin;
  final DateTime Function() _clock;

  /// The proof recipients: per instance owner (no `:` in the id), the
  /// override if any (a tombstone drops the owner), else its D95 pin. In
  /// account order.
  Future<List<ReportKeyPin>> effective() async {
    final overrides = await this.overrides();
    final byOwner = <String, ReportKeyPin>{
      for (final pin in await store.loadReportKeyPins(origin))
        if (_isOwner(pin.ownerAccountId)) pin.ownerAccountId: pin,
    };
    for (final entry in overrides.entries) {
      final pin = entry.value;
      if (pin == null) {
        byOwner.remove(entry.key);
      } else {
        byOwner[entry.key] = pin;
      }
    }
    return byOwner.values.toList()
      ..sort((a, b) => a.ownerAccountId.compareTo(b.ownerAccountId));
  }

  /// The stored overrides: an owner's proof key, or null for a tombstone.
  /// An unreadable setting reads as none (the first-pin flag in
  /// `owner_key_watch.dart` keeps that from pinning on first use again).
  Future<Map<String, ReportKeyPin?>> overrides() async {
    final raw = await store.loadSetting(ownerProofPinsSetting(origin));
    if (raw == null || raw.isEmpty) return <String, ReportKeyPin?>{};
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
      final result = <String, ReportKeyPin?>{};
      for (final entry in decoded.entries) {
        final id = entry.key;
        if (id.isEmpty || !_isOwner(id)) continue;
        final value = entry.value;
        if (value == null) {
          result[id] = null;
          continue;
        }
        final row = (value as Map).cast<String, Object?>();
        final key = base64Decode(row['key']! as String);
        final rev = row['rev']! as int;
        if (key.length != 32 || rev < 1) continue;
        result[id] = ReportKeyPin(
          origin: origin,
          ownerAccountId: id,
          publicKey: key,
          keyRev: rev,
          pinnedAt: row['at']! as int,
        );
      }
      return result;
    } catch (_) {
      return <String, ReportKeyPin?>{};
    }
  }

  /// Makes [recipient]'s key the owner's proof key (first use, or accepted
  /// on the sealed key screen). Never touches the D95 pins.
  Future<void> pin(ReportRecipientKey recipient) async {
    if (!_isOwner(recipient.inboxId) ||
        recipient.inboxId.isEmpty ||
        recipient.publicKey.length != 32 ||
        recipient.keyRev < 1) {
      throw const FormatException('invalid owner proof pin');
    }
    final current = await overrides();
    current[recipient.inboxId] = ReportKeyPin(
      origin: origin,
      ownerAccountId: recipient.inboxId,
      publicKey: recipient.publicKey,
      keyRev: recipient.keyRev,
      pinnedAt: _clock().toUtc().millisecondsSinceEpoch,
    );
    await _save(current);
  }

  /// Drops [ownerAccountId] from the proof recipients (accepted as gone).
  /// A tombstone when a D95 pin would otherwise show through; the D95 pin
  /// itself stays, for reports.
  Future<void> drop(String ownerAccountId) async {
    final current = await overrides();
    final manual = await store.loadReportKeyPin(origin, ownerAccountId);
    if (manual == null) {
      current.remove(ownerAccountId);
    } else {
      current[ownerAccountId] = null;
    }
    await _save(current);
  }

  /// A person pinned [ownerAccountId]'s report key after comparing codes
  /// (D95): that key becomes the owner's proof recipient too, so its
  /// override (a first-use key, an accepted one, or a tombstone) goes.
  Future<void> followReportPin(String ownerAccountId) async {
    final current = await overrides();
    if (!current.containsKey(ownerAccountId)) return;
    current.remove(ownerAccountId);
    await _save(current);
  }

  Future<void> _save(Map<String, ReportKeyPin?> overrides) => store.saveSetting(
      ownerProofPinsSetting(origin),
      jsonEncode(<String, Object?>{
        for (final entry in overrides.entries)
          entry.key: entry.value == null
              ? null
              : <String, Object?>{
                  'key': base64Encode(entry.value!.publicKey),
                  'rev': entry.value!.keyRev,
                  'at': entry.value!.pinnedAt,
                },
      }));
}
