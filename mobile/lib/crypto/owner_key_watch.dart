import 'dart:convert';

import '../core/report_models.dart' show ReportInbox;
import '../core/server_origin.dart' show canonicalizeServerOrigin;
import '../storage/local_store.dart';
import 'franking.dart' show reportInboxInstanceOwner;
import 'owner_proof_pins.dart';
import 'report_key_pins.dart';

/// L2-3 (owner decisions 2026-11-12, "auto-pin on first use" and "Keep
/// reports manual"): the instance owners' report keys a sealed message's
/// franking tags go to (the proof recipients, [OwnerProofPins]) are pinned
/// automatically the first time this app sees any (trust on first use).
/// They are kept apart from the D95 report pins, which this file never
/// writes: a report is still sealed only to keys a person pinned after
/// comparing codes. After the first pin nothing is pinned automatically: a
/// key that changes, an owner the server stops listing and an owner it
/// starts listing are each shown to the person ([review]) to accept or
/// reject, and until they accept, a sealed message is tagged only to the
/// proof recipients from before (the tags read them, never this listing).
/// What the server can do before the first pin is in `docs/crypto.md`,
/// "Franking a sealed message".

/// What differs between the server's latest owner listing and the pins.
enum OwnerKeyChange {
  /// A pinned owner is listed with another key.
  changed,

  /// An owner with no pin is listed.
  added,

  /// A pinned owner is no longer listed.
  missing,
}

/// One difference for the person to accept or reject.
class OwnerKeyReviewItem {
  const OwnerKeyReviewItem(this.inboxId, this.change, {this.pin, this.listed});

  /// The owner's account id.
  final String inboxId;
  final OwnerKeyChange change;

  /// The key pinned now (changed, missing).
  final ReportKeyPin? pin;

  /// The key the server lists now (changed, added).
  final ReportRecipientKey? listed;

  @override
  String toString() => 'OwnerKeyReviewItem($inboxId, $change)';
}

/// The setting that keeps the server's latest owner listing (public keys).
String ownerKeysSeenSetting(String origin) =>
    'l2.owner_keys_seen:${canonicalizeServerOrigin(origin)}';

/// Set once the first proof pin is made (on first use, on the sealed key
/// screen, or by a person pinning a report key while reporting), so that a
/// later empty set of proof recipients never pins on first use again.
String ownerKeysFirstPinSetting(String origin) =>
    'l2.owner_keys_first_pin:${canonicalizeServerOrigin(origin)}';

/// The differences the person rejected: owner id to the rejected key
/// (base64), or `""` for a rejected disappearance.
String ownerKeyRejectionsSetting(String origin) =>
    'l2.owner_key_rejections:${canonicalizeServerOrigin(origin)}';

bool _isOwner(String inboxId) => !inboxId.contains(':');

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

class OwnerKeyWatch {
  OwnerKeyWatch(this.store, String origin, {DateTime Function()? clock})
      : origin = canonicalizeServerOrigin(origin),
        pins = OwnerProofPins(store, origin, clock: clock);

  final LocalStore store;
  final String origin;

  /// The proof recipients. Never the D95 report pins.
  final OwnerProofPins pins;

  /// Records the server's owner listing [inbox] (an `instance_owner` inbox;
  /// any other is ignored) and pins every listed key as a proof recipient
  /// if this is the first sight: no proof recipient (a D95 pin counts) and
  /// no first pin before. Returns whether it pinned.
  /// Pass an empty inbox for `report_inbox_unavailable` (no owner has a
  /// key); never call this for any other error.
  Future<bool> observe(ReportInbox inbox) async {
    if (inbox.kind != reportInboxInstanceOwner) return false;
    final listed = <String, ReportRecipientKey>{};
    for (final row in inbox.recipients) {
      if (!_isOwner(row.inboxId)) continue;
      // An owner listed twice: record nothing from a listing this odd.
      if (listed.containsKey(row.inboxId)) return false;
      listed[row.inboxId] = ReportRecipientKey(
          inboxId: row.inboxId, publicKey: row.publicKey, keyRev: row.keyRev);
    }
    var pinned = false;
    final owned = await _ownerPins();
    final firstPinDone =
        await store.loadSetting(ownerKeysFirstPinSetting(origin));
    if (owned.isNotEmpty) {
      if (firstPinDone == null) {
        await store.saveSetting(ownerKeysFirstPinSetting(origin), '1');
      }
    } else if (firstPinDone == null && listed.isNotEmpty) {
      for (final recipient in listed.values) {
        await pins.pin(recipient);
      }
      await store.saveSetting(ownerKeysFirstPinSetting(origin), '1');
      pinned = true;
    }
    await store.saveSetting(
        ownerKeysSeenSetting(origin),
        jsonEncode(<Object?>[
          for (final recipient in listed.values)
            <String, Object?>{
              'id': recipient.inboxId,
              'key': base64Encode(recipient.publicKey),
              'rev': recipient.keyRev,
            },
        ]));
    await _pruneRejections();
    return pinned;
  }

  /// The differences not yet accepted or rejected, in owner order. Nothing
  /// before the first listing is recorded.
  Future<List<OwnerKeyReviewItem>> review() async {
    final all = await _differences();
    if (all.isEmpty) return all;
    final rejected = await _rejections();
    return [
      for (final item in all)
        if (rejected[item.inboxId] != _rejectionValue(item)) item
    ];
  }

  /// Accepts [item] for proofs: makes the listed key a proof recipient
  /// (changed, added) or drops the owner from them (missing). The D95
  /// report pins stay as they are. Refused (false) when the listing moved
  /// since [item] was read.
  Future<bool> accept(OwnerKeyReviewItem item) async {
    final current = await _current(item);
    if (current == null) return false;
    final listed = current.listed;
    if (current.change == OwnerKeyChange.missing) {
      await pins.drop(current.inboxId);
    } else if (listed != null) {
      await pins.pin(listed);
    } else {
      return false;
    }
    await store.saveSetting(ownerKeysFirstPinSetting(origin), '1');
    final rejected = await _rejections()
      ..remove(current.inboxId);
    await _saveRejections(rejected);
    return true;
  }

  /// Rejects [item]: the proof recipients stay as they are, and the warning
  /// stays away until the server lists something else for that owner.
  /// Refused (false) when the listing moved since [item] was read.
  Future<bool> reject(OwnerKeyReviewItem item) async {
    final current = await _current(item);
    if (current == null) return false;
    final rejected = await _rejections();
    rejected[current.inboxId] = _rejectionValue(current);
    await _saveRejections(rejected);
    return true;
  }

  Future<OwnerKeyReviewItem?> _current(OwnerKeyReviewItem item) async {
    for (final current in await _differences()) {
      if (current.inboxId != item.inboxId || current.change != item.change) {
        continue;
      }
      final a = current.listed?.publicKey, b = item.listed?.publicKey;
      final p = current.pin?.publicKey, q = item.pin?.publicKey;
      if ((a == null) != (b == null) || (a != null && !_same(a, b!))) {
        return null;
      }
      if ((p == null) != (q == null) || (p != null && !_same(p, q!))) {
        return null;
      }
      return current;
    }
    return null;
  }

  static String _rejectionValue(OwnerKeyReviewItem item) {
    final listed = item.listed;
    return listed == null ? '' : base64Encode(listed.publicKey);
  }

  Future<List<OwnerKeyReviewItem>> _differences() async {
    final seen = await _seen();
    if (seen == null) return <OwnerKeyReviewItem>[];
    final owned = {
      for (final pin in await _ownerPins()) pin.ownerAccountId: pin
    };
    final items = <OwnerKeyReviewItem>[];
    for (final listed in seen.values) {
      final pin = owned[listed.inboxId];
      if (pin == null) {
        items.add(OwnerKeyReviewItem(listed.inboxId, OwnerKeyChange.added,
            listed: listed));
      } else if (!_same(pin.publicKey, listed.publicKey)) {
        items.add(OwnerKeyReviewItem(listed.inboxId, OwnerKeyChange.changed,
            pin: pin, listed: listed));
      }
    }
    for (final pin in owned.values) {
      if (!seen.containsKey(pin.ownerAccountId)) {
        items.add(OwnerKeyReviewItem(pin.ownerAccountId, OwnerKeyChange.missing,
            pin: pin));
      }
    }
    items.sort((a, b) => a.inboxId.compareTo(b.inboxId));
    return items;
  }

  /// The proof recipients (owner scope), never the D95 pins alone.
  Future<List<ReportKeyPin>> _ownerPins() => pins.effective();

  /// The latest listing, or null before the first one (or when it cannot be
  /// read, which shows no warning and pins nothing).
  Future<Map<String, ReportRecipientKey>?> _seen() async {
    final raw = await store.loadSetting(ownerKeysSeenSetting(origin));
    if (raw == null) return null;
    try {
      final rows = jsonDecode(raw) as List<Object?>;
      return <String, ReportRecipientKey>{
        for (final row in rows.cast<Map<String, Object?>>())
          row['id']! as String: ReportRecipientKey(
            inboxId: row['id']! as String,
            publicKey: base64Decode(row['key']! as String),
            keyRev: row['rev']! as int,
          ),
      };
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _rejections() async {
    final raw = await store.loadSetting(ownerKeyRejectionsSetting(origin));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _saveRejections(Map<String, String> rejected) => store
      .saveSetting(ownerKeyRejectionsSetting(origin), jsonEncode(rejected));

  /// Keeps only the rejections that still match a difference, so a listing
  /// that moves on and back raises the warning again.
  Future<void> _pruneRejections() async {
    final rejected = await _rejections();
    if (rejected.isEmpty) return;
    final current = {
      for (final item in await _differences())
        item.inboxId: _rejectionValue(item)
    };
    rejected.removeWhere((id, value) => current[id] != value);
    await _saveRejections(rejected);
  }
}
