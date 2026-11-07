import '../core/server_origin.dart' show canonicalizeServerOrigin;
import '../storage/local_store.dart';

/// Pinning of the instance owners' report keys (C6, D95). A report is sealed
/// to each instance owner's own report public key, and the server hands the
/// keys out. A server that substituted one could read the reports sealed to
/// it, so the app pins each owner's key (per server origin) and seals only to
/// a key that matches its pin, the way the K0 recovery key is pinned. Nothing
/// is pinned silently: a pin is made by [ReportKeyPins.pin], which a screen
/// calls after showing the person the key's [reportKeyFingerprint]; a key the
/// server later changes is refused until it is pinned again the same way.

/// A report key as the server lists it for one instance owner.
class ReportRecipientKey {
  ReportRecipientKey({
    required this.inboxId,
    required List<int> publicKey,
    required this.keyRev,
  }) : publicKey = List<int>.unmodifiable(publicKey);

  /// The owner's account id (the report inbox id, D95).
  final String inboxId;
  final List<int> publicKey;
  final int keyRev;

  @override
  String toString() => 'ReportRecipientKey($inboxId)';
}

enum ReportKeyStatus {
  /// The key equals the pinned one.
  pinned,

  /// Nothing is pinned for this owner yet.
  unpinned,

  /// A different key than the pinned one: refuse until the person pins it.
  changed,
}

class ReportKeyAssessment {
  const ReportKeyAssessment(this.recipient, this.status, this.pin);

  final ReportRecipientKey recipient;
  final ReportKeyStatus status;

  /// The earlier pin for this owner, if any (what a `changed` key is judged
  /// against).
  final ReportKeyPin? pin;
}

/// How the server's recipients compare with what is pinned.
class ReportKeyCheck {
  const ReportKeyCheck(this.recipients, this.missing);

  final List<ReportKeyAssessment> recipients;

  /// Owners pinned earlier that the server does not list now. An owner may
  /// have left or not republished a key, but a server withholding an owner's
  /// copy looks the same, so a screen shows this.
  final List<ReportKeyPin> missing;

  /// Whether every listed key matches its pin (and there is at least one).
  bool get allPinned =>
      recipients.isNotEmpty &&
      recipients.every((r) => r.status == ReportKeyStatus.pinned);
}

/// Thrown when a report would be sealed to a key that is not pinned.
class ReportKeyNotPinned implements Exception {
  const ReportKeyNotPinned(this.check);

  final ReportKeyCheck check;

  @override
  String toString() => 'a report key is not pinned';
}

/// The 32-byte key as uppercase hex in groups of four, for a person to
/// compare with what an owner shows on their own device.
String reportKeyFingerprint(List<int> publicKey) {
  final hex = StringBuffer();
  for (final byte in publicKey) {
    hex.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  final text = hex.toString().toUpperCase();
  return [
    for (var start = 0; start < text.length; start += 4)
      text.substring(start, start + 4 > text.length ? text.length : start + 4)
  ].join('-');
}

bool _sameKey(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

/// The pins of one server's instance owners.
class ReportKeyPins {
  ReportKeyPins(this.store, String origin, {DateTime Function()? clock})
      : origin = canonicalizeServerOrigin(origin),
        _clock = clock ?? DateTime.now;

  final LocalStore store;

  /// The canonical server origin.
  final String origin;
  final DateTime Function() _clock;

  /// Compares [recipients] (as the server lists them) with the pins.
  Future<ReportKeyCheck> check(List<ReportRecipientKey> recipients) async {
    final pins = {
      for (final pin in await store.loadReportKeyPins(origin))
        pin.ownerAccountId: pin
    };
    final listed = <String>{};
    final assessments = <ReportKeyAssessment>[];
    for (final recipient in recipients) {
      listed.add(recipient.inboxId);
      final pin = pins[recipient.inboxId];
      assessments.add(ReportKeyAssessment(
        recipient,
        pin == null
            ? ReportKeyStatus.unpinned
            : _sameKey(pin.publicKey, recipient.publicKey)
                ? ReportKeyStatus.pinned
                : ReportKeyStatus.changed,
        pin,
      ));
    }
    return ReportKeyCheck(
      assessments,
      [
        for (final pin in pins.values)
          if (!listed.contains(pin.ownerAccountId)) pin
      ],
    );
  }

  /// Checks [recipients] and returns the check when every key is pinned.
  /// Throws [ReportKeyNotPinned] otherwise, so no copy is sealed to an
  /// unconfirmed key.
  Future<ReportKeyCheck> requirePinned(
      List<ReportRecipientKey> recipients) async {
    final result = await check(recipients);
    if (!result.allPinned) throw ReportKeyNotPinned(result);
    return result;
  }

  /// Pins [recipient]'s key, replacing an earlier pin of the same owner. The
  /// one deliberate act that accepts a key, including a changed one: call it
  /// only after the person confirmed the fingerprint.
  Future<void> pin(ReportRecipientKey recipient) =>
      store.saveReportKeyPin(ReportKeyPin(
        origin: origin,
        ownerAccountId: recipient.inboxId,
        publicKey: recipient.publicKey,
        keyRev: recipient.keyRev,
        pinnedAt: _clock().toUtc().millisecondsSinceEpoch,
      ));

  /// Drops the pin of an owner who is gone.
  Future<void> forget(String ownerAccountId) =>
      store.deleteReportKeyPin(origin, ownerAccountId);
}
