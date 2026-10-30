import 'dart:convert';

import 'server_origin.dart' show canonicalizeServerOrigin;
import 'transport_policy.dart' show TransportPolicy;

const deviceLinkV3Protocol = 'veritra-device-link-v3';

Never _invalid() => throw const FormatException('invalid device link v3 data');

String _string(Map<String, Object?> json, String key, [int max = 128]) {
  final value = json[key];
  if (value is! String || value.isEmpty || utf8.encode(value).length > max) {
    _invalid();
  }
  return value;
}

String deviceLinkV3Hash(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String deviceLinkV3Id(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value))
    _invalid();
  return value;
}

String deviceLinkV3ClaimToken(String value) {
  if (value.length != 43) _invalid();
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.length != 32 ||
        base64Url.encode(bytes).replaceAll('=', '') != value) _invalid();
    return value;
  } on FormatException {
    _invalid();
  }
}

List<int> _binary(Map<String, Object?> json, String key,
    {int min = 32, int max = 32}) {
  final value = _string(json, key, (max + 2) ~/ 3 * 4);
  try {
    final bytes = base64Decode(value);
    if (bytes.length < min ||
        bytes.length > max ||
        base64Encode(bytes) != value) {
      _invalid();
    }
    return List<int>.unmodifiable(bytes);
  } on FormatException {
    _invalid();
  }
}

DateTime _time(Map<String, Object?> json, String key) {
  final parsed = DateTime.tryParse(_string(json, key, 64));
  if (parsed == null || !parsed.isUtc || parsed.millisecondsSinceEpoch <= 0) {
    _invalid();
  }
  return parsed;
}

void _keys(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) _invalid();
}

String _origin(Map<String, Object?> json) {
  final origin = _string(json, 'server_origin', 2048);
  try {
    if (canonicalizeServerOrigin(origin) != origin ||
        !TransportPolicy.demo.allows(origin)) _invalid();
  } on FormatException {
    _invalid();
  }
  return origin;
}

/// Public server context only. This is NOT proof of the source's approval;
/// the native transcript/MAC check must succeed before identity promotion.
class DeviceLinkV3Record {
  DeviceLinkV3Record.fromJson(Map<String, Object?> json)
      : fields = Map<String, Object?>.unmodifiable(json) {
    _keys(fields, const {
      'id',
      'code',
      'protocol_version',
      'state',
      'account_id',
      'created_by_device_id',
      'server_origin',
      'link_nonce',
      'existing_signing_key',
      'claimed_device_id',
      'claimed_device_name',
      'claimed_signing_key',
      'transfer_public_key',
      'transcript_hash',
      'claim_tag',
      'approval_tag',
      'claim_request_hash',
      'created_at',
      'expires_at',
      'claimed_at',
      'approved_at',
      'transfer_expires_at',
      'completed_at',
    });
    if (fields['protocol_version'] != deviceLinkV3Protocol ||
        !const {'pending', 'claimed', 'approved', 'consumed', 'revoked'}
            .contains(fields['state'])) _invalid();
    for (final key in ['id', 'account_id', 'created_by_device_id']) {
      deviceLinkV3Id(fields[key]);
    }
    _origin(fields);
    _binary(fields, 'link_nonce');
    _binary(fields, 'existing_signing_key');
    final created = _time(fields, 'created_at');
    final expires = _time(fields, 'expires_at');
    if (!expires.isAfter(created) ||
        expires.difference(created) > const Duration(minutes: 30)) {
      _invalid();
    }
    if (fields.containsKey('code')) deviceLinkV3Hash(fields['code']);
    if (fields.containsKey('claimed_device_id')) {
      deviceLinkV3Id(fields['claimed_device_id']);
      if (fields['claimed_device_id'] == sourceDeviceId) _invalid();
    }
    for (final key in [
      'claimed_signing_key',
      'transfer_public_key',
      'transcript_hash',
      'claim_tag',
      'approval_tag'
    ]) {
      if (fields.containsKey(key)) _binary(fields, key);
    }
    for (final key in [
      'claimed_at',
      'approved_at',
      'transfer_expires_at',
      'completed_at'
    ]) {
      if (fields.containsKey(key)) _time(fields, key);
    }
    if (fields.containsKey('claim_request_hash')) {
      deviceLinkV3Hash(fields['claim_request_hash']);
    }
    if (fields.containsKey('claimed_device_name')) {
      final name = _string(fields, 'claimed_device_name', 64);
      if (name.trim() != name) _invalid();
    }
    if (state == 'claimed' || state == 'approved' || state == 'consumed') {
      deviceLinkV3Id(fields['claimed_device_id']);
      final name = _string(fields, 'claimed_device_name', 64);
      if (name.trim() != name) _invalid();
      for (final key in [
        'claimed_signing_key',
        'transfer_public_key',
        'transcript_hash',
        'claim_tag'
      ]) {
        _binary(fields, key);
      }
      deviceLinkV3Hash(fields['claim_request_hash']);
      final claimed = _time(fields, 'claimed_at');
      if (claimed.isBefore(created) || claimed.isAfter(expires)) _invalid();
    }
    if (state == 'approved' || state == 'consumed') {
      _binary(fields, 'approval_tag');
      final approved = _time(fields, 'approved_at');
      if (approved.isBefore(_time(fields, 'claimed_at')) ||
          approved.isAfter(expires) ||
          _time(fields, 'transfer_expires_at').difference(approved) !=
              const Duration(days: 7)) _invalid();
    }
    if (state == 'consumed') {
      final completed = _time(fields, 'completed_at');
      if (completed.isBefore(_time(fields, 'approved_at')) ||
          completed.isAfter(expires)) _invalid();
    }
    if (state == 'pending' || state == 'claimed') {
      if (['approval_tag', 'approved_at', 'transfer_expires_at', 'completed_at']
          .any(fields.containsKey)) _invalid();
    }
  }

  final Map<String, Object?> fields;
  String get id => fields['id'] as String;
  String get state => fields['state'] as String;
  String get origin => fields['server_origin'] as String;
  String get accountId => fields['account_id'] as String;
  String get sourceDeviceId => fields['created_by_device_id'] as String;
  String? get recipientDeviceId => fields['claimed_device_id'] as String?;
  List<int> bytes(String key) => _binary(fields, key);
}

/// Immutable exact signed request, persisted with pending native identity and
/// client-generated credentials BEFORE submission. No raw credential belongs
/// in this object. The native operation supplies its signature and digest.
class FrozenDeviceLinkV3Claim {
  FrozenDeviceLinkV3Claim.fromJson(Map<String, Object?> json,
      {required String requestHash})
      : fields = Map<String, Object?>.unmodifiable(json),
        requestHash = deviceLinkV3Hash(requestHash) {
    const keys = {
      'code',
      'protocol_version',
      'server_origin',
      'reservation_request_id',
      'enrollment_reservation_id',
      'device_name',
      'device_key_package',
      'signing_key',
      'transfer_public_key',
      'transcript_hash',
      'claim_tag',
      'claim_token_hash',
      'device_secret_hash',
      'initial_session_token_hash',
      'challenge_signature',
    };
    _keys(fields, keys);
    if (fields.length != keys.length ||
        fields['protocol_version'] != deviceLinkV3Protocol) _invalid();
    _origin(fields);
    for (final key in [
      'code',
      'reservation_request_id',
      'claim_token_hash',
      'device_secret_hash',
      'initial_session_token_hash'
    ]) {
      deviceLinkV3Hash(fields[key]);
    }
    if ({
          fields['claim_token_hash'],
          fields['device_secret_hash'],
          fields['initial_session_token_hash']
        }.length !=
        3) _invalid();
    deviceLinkV3Id(fields['enrollment_reservation_id']);
    final name = _string(fields, 'device_name', 64);
    if (name.trim() != name) _invalid();
    _binary(fields, 'device_key_package', min: 64, max: 48 * 1024);
    for (final key in [
      'signing_key',
      'transfer_public_key',
      'transcript_hash',
      'claim_tag'
    ]) {
      _binary(fields, key);
    }
    _binary(fields, 'challenge_signature', min: 64, max: 64);
  }

  final Map<String, Object?> fields;
  final String requestHash;
}

class DeviceLinkV3Reservation {
  DeviceLinkV3Reservation.fromJson(Map<String, Object?> json)
      : fields = Map<String, Object?>.unmodifiable(json) {
    _keys(fields, const {
      'id',
      'account_id',
      'device_id',
      'challenge',
      'expires_at',
      'protocol_version',
      'link_nonce',
      'existing_device_id',
      'existing_signing_key'
    });
    if (fields['protocol_version'] != deviceLinkV3Protocol) _invalid();
    for (final key in ['id', 'account_id', 'device_id', 'existing_device_id']) {
      deviceLinkV3Id(fields[key]);
    }
    _binary(fields, 'challenge', min: 1, max: 4096);
    _binary(fields, 'link_nonce');
    _binary(fields, 'existing_signing_key');
    _time(fields, 'expires_at');
  }
  final Map<String, Object?> fields;
}

/// A public receipt and approval MAC, never a server-issued Session/token.
class DeviceLinkV3Completion {
  DeviceLinkV3Completion.fromJson(Map<String, Object?> json) {
    _keys(json, const {'completion', 'approval_tag'});
    final raw = json['completion'];
    if (raw is! Map<String, Object?>) _invalid();
    fields = Map<String, Object?>.unmodifiable(raw);
    _keys(fields, const {
      'link_id',
      'account_id',
      'device_id',
      'server_origin',
      'claim_request_hash',
      'transcript_hash',
      'initial_session_token_hash',
      'completed_at'
    });
    for (final key in ['link_id', 'account_id', 'device_id']) {
      deviceLinkV3Id(fields[key]);
    }
    _origin(fields);
    deviceLinkV3Hash(fields['claim_request_hash']);
    deviceLinkV3Hash(fields['initial_session_token_hash']);
    _binary(fields, 'transcript_hash');
    _time(fields, 'completed_at');
    approvalTag = _binary(json, 'approval_tag');
  }
  late final Map<String, Object?> fields;
  late final List<int> approvalTag;
}
