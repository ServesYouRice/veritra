import 'dart:convert';

import '../storage/local_store.dart'
    show CryptoRecordChange, PendingEnrollment, StoredCryptoState;

// K0 recovery enrollment, client side (docs/designs/K0-recovery-enrollment.md,
// R3 and R4): the recovery key status, the claim a device that lost every
// other device makes, and the claim it keeps while it waits.

/// Typed or pasted recovery key text, ready for the native decoder.
///
/// A key copied from a note, a PDF or a chat arrives with tabs, line breaks,
/// non-breaking or zero-width spaces and typographic dashes between its
/// groups, and sometimes in full-width forms. The decoder ignores only ASCII
/// `-` and spaces, so every separator is dropped here and full-width letters
/// and digits become ASCII. A key typed on a Cyrillic keyboard layout (sr)
/// arrives with Cyrillic look-alikes of Latin letters; those that can only
/// be read as one Latin letter become it. Any other character is kept, so a
/// real typo still fails the decode.
String normalizeRecoveryKeyInput(String raw) {
  final output = StringBuffer();
  for (final rune in raw.runes) {
    if (_isRecoveryKeySeparator(rune)) continue;
    final latin = _cyrillicLookAlikes[rune];
    if (latin != null) {
      output.write(latin);
      continue;
    }
    if ((rune >= 0xFF10 && rune <= 0xFF19) ||
        (rune >= 0xFF21 && rune <= 0xFF3A) ||
        (rune >= 0xFF41 && rune <= 0xFF5A)) {
      output.writeCharCode(rune - 0xFEE0);
      continue;
    }
    output.writeCharCode(rune);
  }
  return output.toString();
}

/// Cyrillic letters drawn the same as one Latin letter of the recovery key
/// alphabet (Crockford base32; the decoder reads O as 0 and I as 1). Letters
/// that only resemble a digit or several letters (З, Ч, П, Г, Д, Л) are left
/// alone, so they still fail the decode.
const Map<int, String> _cyrillicLookAlikes = <int, String>{
  0x0410: 'A', 0x0430: 'A', // А а
  0x0412: 'B', 0x0432: 'B', // В в
  0x0415: 'E', 0x0435: 'E', // Е е
  0x041A: 'K', 0x043A: 'K', // К к
  0x041C: 'M', 0x043C: 'M', // М м
  0x041D: 'H', 0x043D: 'H', // Н н
  0x041E: 'O', 0x043E: 'O', // О о
  0x0420: 'P', 0x0440: 'P', // Р р
  0x0421: 'C', 0x0441: 'C', // С с
  0x0422: 'T', 0x0442: 'T', // Т т
  0x0423: 'Y', 0x0443: 'Y', // У у
  0x0425: 'X', 0x0445: 'X', // Х х
  0x0405: 'S', 0x0455: 'S', // Ѕ ѕ
  0x0406: 'I', 0x0456: 'I', // І і
  0x0408: 'J', 0x0458: 'J', // Ј ј
};

bool _isRecoveryKeySeparator(int rune) =>
    // ASCII space, tab, line feed, vertical tab, form feed, carriage return.
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    // Hyphen-minus, soft hyphen, and the Unicode dashes and minus signs.
    rune == 0x2D ||
    rune == 0xAD ||
    (rune >= 0x2010 && rune <= 0x2015) ||
    rune == 0x2043 ||
    rune == 0x2212 ||
    rune == 0xFE58 ||
    rune == 0xFE63 ||
    rune == 0xFF0D ||
    // Non-breaking, typographic and ideographic spaces; line and paragraph
    // separators; next line.
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000 ||
    // Zero-width characters and the byte-order mark.
    (rune >= 0x200B && rune <= 0x200D) ||
    rune == 0x2060 ||
    rune == 0xFEFF;

/// The 52-character display in 13 groups of 4, as the user writes it down.
String groupRecoveryKey(String display) {
  final groups = <String>[];
  for (var i = 0; i < display.length; i += 4) {
    groups.add(
        display.substring(i, i + 4 > display.length ? display.length : i + 4));
  }
  return groups.join('-');
}

/// A recovery request waiting on this account, as
/// `GET /api/v1/account/recovery-key` and the `account.recovery.pending`
/// sync event describe it.
class PendingRecoveryRequest {
  const PendingRecoveryRequest({
    required this.id,
    required this.deviceName,
    required this.readyAt,
    this.createdAt,
  });

  final String id;
  final String deviceName;
  final DateTime readyAt;
  final DateTime? createdAt;

  static PendingRecoveryRequest? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'] ?? value['request_id'];
    final name = value['device_name'];
    final readyAt = _time(value['ready_at']);
    if (id is! String || id.isEmpty || name is! String || readyAt == null) {
      return null;
    }
    return PendingRecoveryRequest(
      id: id,
      deviceName: name,
      readyAt: readyAt,
      createdAt: _time(value['created_at']),
    );
  }
}

/// `GET /api/v1/account/recovery-key`.
class RecoveryKeyStatus {
  const RecoveryKeyStatus({
    required this.available,
    required this.configured,
    this.setAt,
    this.pending,
    this.publicOrigin,
  });

  /// Whether the server has recovery turned on (its public origin is set).
  final bool available;

  /// The origin the server checks recovery proofs against, from the signed-in
  /// status only. Shown and compared, never signed: a claim signs over the
  /// address the user typed.
  final String? publicOrigin;

  /// Whether this account has a recovery key.
  final bool configured;
  final DateTime? setAt;
  final PendingRecoveryRequest? pending;

  factory RecoveryKeyStatus.fromJson(Map<String, Object?> json) {
    final available = json['available'];
    final configured = json['configured'];
    if (available is! bool || configured is! bool) {
      throw const FormatException('recovery key status');
    }
    return RecoveryKeyStatus(
      available: available,
      configured: configured,
      setAt: _time(json['set_at']),
      pending: PendingRecoveryRequest.fromJson(json['pending_request']),
      publicOrigin: _origin(json['public_origin']),
    );
  }
}

String? _origin(Object? value) {
  if (value is! String || value.isEmpty || value.length > 512) return null;
  return value;
}

/// The 202 answer to a recovery claim. [claimToken] and [deviceSecret] are
/// credentials: kept only in the encrypted local store, never logged.
class AccountRecoveryClaim {
  const AccountRecoveryClaim({
    required this.requestId,
    required this.claimToken,
    required this.deviceSecret,
    required this.state,
    required this.readyAt,
  });

  final String requestId;
  final String claimToken;
  final String deviceSecret;
  final String state;
  final DateTime readyAt;

  factory AccountRecoveryClaim.fromJson(Map<String, Object?> json) {
    final requestId = json['request_id'];
    final claimToken = json['claim_token'];
    final deviceSecret = json['device_secret'];
    final state = json['state'];
    final readyAt = _time(json['ready_at']);
    if (requestId is! String ||
        requestId.isEmpty ||
        claimToken is! String ||
        claimToken.isEmpty ||
        deviceSecret is! String ||
        deviceSecret.isEmpty ||
        state is! String ||
        readyAt == null) {
      throw const FormatException('recovery claim');
    }
    return AccountRecoveryClaim(
      requestId: requestId,
      claimToken: claimToken,
      deviceSecret: deviceSecret,
      state: state,
      readyAt: readyAt,
    );
  }
}

/// What a status poll found.
enum AccountRecoveryPhase {
  /// Still within the wait; [AccountRecoveryStatus.readyAt] says until when.
  waiting,

  /// Completed by this poll: [AccountRecoveryStatus.token] is the session.
  completed,

  /// Completed earlier, and the answer that carried the session was lost:
  /// sign in with the password and the claim's device secret.
  completedWithoutToken,
}

/// `GET /api/v1/account-recovery/{id}/status`.
class AccountRecoveryStatus {
  const AccountRecoveryStatus({
    required this.phase,
    this.readyAt,
    this.accountId,
    this.deviceId,
    this.username,
    this.role,
    this.token,
  });

  final AccountRecoveryPhase phase;
  final DateTime? readyAt;
  final String? accountId;
  final String? deviceId;
  final String? username;
  final String? role;
  final String? token;
}

/// The claim this device keeps through the wait (design, client flow step
/// 4): the claim token, device id and secret, the request, its ready time
/// and the new identity's sealed MLS state. It lives only in the encrypted
/// local store's pending enrollment (schema 17), which no backup carries
/// (D71); schema 16 kept it in the setting `k0.pending_recovery`
/// ([encode]/[decode]), which the upgrade moves.
class PendingAccountRecovery {
  const PendingAccountRecovery({
    required this.origin,
    required this.username,
    required this.accountId,
    required this.deviceId,
    required this.deviceName,
    required this.requestId,
    required this.claimToken,
    required this.deviceSecret,
    required this.readyAt,
    required this.mlsState,
    this.needsLogin = false,
  });

  final String origin;
  final String username;
  final String accountId;
  final String deviceId;
  final String deviceName;
  final String requestId;
  final String claimToken;
  final String deviceSecret;
  final DateTime readyAt;
  final StoredCryptoState mlsState;

  /// The server answered `completed` without a session: the session answer
  /// was lost, and only a password sign-in finishes.
  final bool needsLogin;

  PendingAccountRecovery copyWith({DateTime? readyAt, bool? needsLogin}) =>
      PendingAccountRecovery(
        origin: origin,
        username: username,
        accountId: accountId,
        deviceId: deviceId,
        deviceName: deviceName,
        requestId: requestId,
        claimToken: claimToken,
        deviceSecret: deviceSecret,
        readyAt: readyAt ?? this.readyAt,
        mlsState: mlsState,
        needsLogin: needsLogin ?? this.needsLogin,
      );

  static const int _version = 1;

  /// This claim as the device's pending enrollment.
  PendingEnrollment toEnrollment() => PendingEnrollment(
        kind: PendingEnrollment.kindAccountRecovery,
        origin: origin,
        accountId: accountId,
        deviceId: deviceId,
        payloadJson: encodePayload(),
        state: mlsState,
      );

  /// The fields the enrollment's own columns do not hold.
  String encodePayload() => jsonEncode(<String, Object?>{
        'v': _version,
        'username': username,
        'device_name': deviceName,
        'request_id': requestId,
        'claim_token': claimToken,
        'device_secret': deviceSecret,
        'ready_at': readyAt.toUtc().toIso8601String(),
        'needs_login': needsLogin,
      });

  /// The claim in [enrollment]; null when it is none, of another kind, or
  /// not a whole, current claim.
  static PendingAccountRecovery? fromEnrollment(PendingEnrollment? enrollment) {
    if (enrollment == null ||
        enrollment.kind != PendingEnrollment.kindAccountRecovery) {
      return null;
    }
    final state = enrollment.state;
    if (state == null) return null;
    try {
      final json = jsonDecode(enrollment.payloadJson);
      if (json is! Map) return null;
      return _fromFields(json,
          origin: enrollment.origin,
          accountId: enrollment.accountId,
          deviceId: enrollment.deviceId,
          mlsState: state);
    } catch (_) {
      // Never echo the text: it holds credentials.
      return null;
    }
  }

  static PendingAccountRecovery? _fromFields(
    Map<Object?, Object?> json, {
    required String origin,
    required String accountId,
    required String deviceId,
    required StoredCryptoState mlsState,
  }) {
    if (json['v'] != _version) return null;
    final readyAt = _time(json['ready_at']);
    if (readyAt == null) return null;
    String text(String name) {
      final value = json[name];
      if (value is! String || value.isEmpty) {
        throw const FormatException('pending recovery');
      }
      return value;
    }

    if (origin.isEmpty || accountId.isEmpty || deviceId.isEmpty) return null;
    return PendingAccountRecovery(
      origin: origin,
      username: text('username'),
      accountId: accountId,
      deviceId: deviceId,
      deviceName: text('device_name'),
      requestId: text('request_id'),
      claimToken: text('claim_token'),
      deviceSecret: text('device_secret'),
      readyAt: readyAt,
      needsLogin: json['needs_login'] == true,
      mlsState: mlsState,
    );
  }

  /// The schema 16 setting's format; kept for its upgrade.
  String encode() => jsonEncode(<String, Object?>{
        'v': _version,
        'origin': origin,
        'username': username,
        'account_id': accountId,
        'device_id': deviceId,
        'device_name': deviceName,
        'request_id': requestId,
        'claim_token': claimToken,
        'device_secret': deviceSecret,
        'ready_at': readyAt.toUtc().toIso8601String(),
        'needs_login': needsLogin,
        'mls': <String, Object?>{
          'counter': mlsState.counter,
          'key': base64Encode(mlsState.stateKey),
          'root': base64Encode(mlsState.sealedState),
          'records': <Object?>[
            for (final change in mlsState.changes)
              <String, Object?>{
                'kind': change.kind,
                'id': base64Encode(change.recordId),
                'generation': change.generation,
                'sealed':
                    change.sealed == null ? null : base64Encode(change.sealed!),
              },
          ],
        },
      });

  /// The schema 16 setting's claim. Null for anything that is not a whole,
  /// current claim.
  static PendingAccountRecovery? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != _version) return null;
      final mls = json['mls'] as Map;
      final readyAt = _time(json['ready_at']);
      if (readyAt == null) return null;
      String text(String name) {
        final value = json[name];
        if (value is! String || value.isEmpty) {
          throw const FormatException('pending recovery');
        }
        return value;
      }

      return PendingAccountRecovery(
        origin: text('origin'),
        username: text('username'),
        accountId: text('account_id'),
        deviceId: text('device_id'),
        deviceName: text('device_name'),
        requestId: text('request_id'),
        claimToken: text('claim_token'),
        deviceSecret: text('device_secret'),
        readyAt: readyAt,
        needsLogin: json['needs_login'] == true,
        mlsState: StoredCryptoState(
          counter: (mls['counter'] as num).toInt(),
          stateKey: base64Decode(mls['key'] as String),
          sealedState: base64Decode(mls['root'] as String),
          changes: <CryptoRecordChange>[
            for (final record in mls['records'] as List)
              CryptoRecordChange(
                kind: ((record as Map)['kind'] as num).toInt(),
                recordId: base64Decode(record['id'] as String),
                generation: (record['generation'] as num).toInt(),
                sealed: record['sealed'] == null
                    ? null
                    : base64Decode(record['sealed'] as String),
              ),
          ],
        ),
      );
    } catch (_) {
      // Never echo the text: it holds credentials.
      return null;
    }
  }
}

DateTime? _time(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
