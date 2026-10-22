import 'dart:convert';

/// What a failed API call means for the app, independent of the exact
/// server code. App logic branches on this; the UI shows
/// [ApiException.message].
enum ApiErrorKind {
  /// The session token is no longer valid; sign in again.
  sessionExpired,

  /// Username or password (or device secret) was rejected.
  invalidCredentials,

  /// A sensitive action needs a fresh password confirmation.
  reauthRequired,

  /// Password sign-in needs this device to be linked first.
  deviceNotLinked,
  forbidden,
  notFound,

  /// The item existed but its retention window has passed.
  expired,

  /// The request raced another change or repeats one with other data.
  conflict,

  /// The device fell too far behind and must recover (card I33).
  recoveryRequired,

  /// Too many attempts; transient.
  rateLimited,
  tooLarge,
  quotaExceeded,

  /// The server refused this build's encryption material.
  encryptionRefused,
  setupAuthorization,

  /// Input the user can correct (names, passwords, invite codes).
  invalidInput,

  /// A request this client built wrongly; not user-correctable.
  badRequest,

  /// Stored ciphertext failed verification.
  integrity,

  /// A server feature that is not configured on this instance.
  featureUnavailable,

  /// A server-side failure that may pass; transient.
  serverUnavailable,
  unknown,
}

/// Every error code the server's HTTP API emits (inventory of
/// `server/internal/httpapi`, checked by `test/api_contract_test.dart`
/// against both the server source and the versioned fixture), plus the
/// codes the client synthesizes itself.
const Map<String, ApiErrorKind> apiErrorCodes = <String, ApiErrorKind>{
  // Authentication and session.
  'unauthorized': ApiErrorKind.sessionExpired,
  'invalid_credentials': ApiErrorKind.invalidCredentials,
  'recent_auth_required': ApiErrorKind.reauthRequired,
  'device_id_required': ApiErrorKind.deviceNotLinked,
  'device_session_required': ApiErrorKind.deviceNotLinked,
  'login_backoff': ApiErrorKind.rateLimited,
  'reauth_backoff': ApiErrorKind.rateLimited,
  'setup_authorization_required': ApiErrorKind.setupAuthorization,
  // Authorization and lookup.
  'forbidden': ApiErrorKind.forbidden,
  'mls_not_in_group': ApiErrorKind.forbidden,
  'not_found': ApiErrorKind.notFound,
  'blob_not_found': ApiErrorKind.notFound,
  'no_push_subscription': ApiErrorKind.notFound,
  'message_expired': ApiErrorKind.expired,
  // Conflicts.
  'already_setup': ApiErrorKind.conflict,
  'last_owner_required': ApiErrorKind.conflict,
  'idempotency_conflict': ApiErrorKind.conflict,
  'call_version_conflict': ApiErrorKind.conflict,
  'mls_epoch_conflict': ApiErrorKind.conflict,
  'mls_group_legacy': ApiErrorKind.conflict,
  'mls_commit_bundle_required': ApiErrorKind.conflict,
  'recovery_transfer_in_progress': ApiErrorKind.conflict,
  'key_package_unavailable': ApiErrorKind.conflict,
  'device_recovery_required': ApiErrorKind.recoveryRequired,
  'full_resync_required': ApiErrorKind.recoveryRequired,
  // Rate limits.
  'push_test_rate_limited': ApiErrorKind.rateLimited,
  'typing_rate_limited': ApiErrorKind.rateLimited,
  'realtime_connection_limit': ApiErrorKind.rateLimited,
  // Size and quota.
  'upload_too_large': ApiErrorKind.tooLarge,
  'storage_quota_exceeded': ApiErrorKind.quotaExceeded,
  'key_package_quota_exceeded': ApiErrorKind.quotaExceeded,
  // Encryption material.
  'device_key_package_required': ApiErrorKind.encryptionRefused,
  'invalid_device_key_package': ApiErrorKind.encryptionRefused,
  'non_production_device_key_package': ApiErrorKind.encryptionRefused,
  'invalid_enrollment': ApiErrorKind.encryptionRefused,
  'transcript_hash_required': ApiErrorKind.encryptionRefused,
  'transcript_mismatch': ApiErrorKind.encryptionRefused,
  // User-correctable input.
  'weak_password': ApiErrorKind.invalidInput,
  'invalid_identity': ApiErrorKind.invalidInput,
  'invalid_invite': ApiErrorKind.invalidInput,
  'invalid_device_link': ApiErrorKind.invalidInput,
  'invalid_device_name': ApiErrorKind.invalidInput,
  'invalid_name': ApiErrorKind.invalidInput,
  'invalid_max_uses': ApiErrorKind.invalidInput,
  'invalid_expires_at': ApiErrorKind.invalidInput,
  'expires_at_too_far': ApiErrorKind.invalidInput,
  'invalid_conversation_kind': ApiErrorKind.invalidInput,
  'invalid_channel_kind': ApiErrorKind.invalidInput,
  'invalid_retention_seconds': ApiErrorKind.invalidInput,
  'invalid_role': ApiErrorKind.invalidInput,
  'invalid_member': ApiErrorKind.invalidInput,
  'account_id_required': ApiErrorKind.invalidInput,
  // Requests this client built wrongly.
  'invalid_body': ApiErrorKind.badRequest,
  'invalid_json': ApiErrorKind.badRequest,
  'empty_body': ApiErrorKind.badRequest,
  'invalid_input': ApiErrorKind.badRequest,
  'invalid_cursor': ApiErrorKind.badRequest,
  'before_and_after_exclusive': ApiErrorKind.badRequest,
  'conversation_id_required': ApiErrorKind.badRequest,
  'message_id_required': ApiErrorKind.badRequest,
  'claim_token_required': ApiErrorKind.badRequest,
  'recovery_token_required': ApiErrorKind.badRequest,
  'reaction_ciphertext_required': ApiErrorKind.badRequest,
  'muted_required': ApiErrorKind.badRequest,
  'invalid_account_id': ApiErrorKind.badRequest,
  'invalid_conversation_id': ApiErrorKind.badRequest,
  'invalid_device_id': ApiErrorKind.badRequest,
  'invalid_invite_id': ApiErrorKind.badRequest,
  'invalid_subscription_id': ApiErrorKind.badRequest,
  'invalid_call_metadata': ApiErrorKind.badRequest,
  'invalid_call_version': ApiErrorKind.badRequest,
  'invalid_crypto_metadata': ApiErrorKind.badRequest,
  'invalid_encrypted_envelope': ApiErrorKind.badRequest,
  'invalid_encrypted_marker': ApiErrorKind.badRequest,
  'encrypted_upload_header_required': ApiErrorKind.badRequest,
  'invalid_key_derivation_metadata': ApiErrorKind.badRequest,
  'key_derivation_metadata_required': ApiErrorKind.badRequest,
  'invalid_key_packages': ApiErrorKind.badRequest,
  'invalid_push_subscription': ApiErrorKind.badRequest,
  'invalid_recovery_range': ApiErrorKind.badRequest,
  'plaintext_message_fields_forbidden': ApiErrorKind.badRequest,
  // Integrity and configuration.
  'blob_integrity_failed': ApiErrorKind.integrity,
  'push_provider_unavailable': ApiErrorKind.featureUnavailable,
  'setup_ui_unavailable': ApiErrorKind.featureUnavailable,
  // Server-side failures.
  'storage_error': ApiErrorKind.serverUnavailable,
  'storage_unavailable': ApiErrorKind.serverUnavailable,
  'blob_storage_unavailable': ApiErrorKind.serverUnavailable,
  'server_draining': ApiErrorKind.serverUnavailable,
  'attachment_record_failed': ApiErrorKind.serverUnavailable,
  'backup_record_failed': ApiErrorKind.serverUnavailable,
  'backup_upload_failed': ApiErrorKind.serverUnavailable,
  'claim_token_create_failed': ApiErrorKind.serverUnavailable,
  'communities_list_failed': ApiErrorKind.serverUnavailable,
  'community_create_failed': ApiErrorKind.serverUnavailable,
  'conversations_list_failed': ApiErrorKind.serverUnavailable,
  'device_link_claim_failed': ApiErrorKind.serverUnavailable,
  'device_link_status_failed': ApiErrorKind.serverUnavailable,
  'device_secret_create_failed': ApiErrorKind.serverUnavailable,
  'devices_list_failed': ApiErrorKind.serverUnavailable,
  'enrollment_reservation_failed': ApiErrorKind.serverUnavailable,
  'export_audit_failed': ApiErrorKind.serverUnavailable,
  'invite_create_failed': ApiErrorKind.serverUnavailable,
  'invites_list_failed': ApiErrorKind.serverUnavailable,
  'owner_create_failed': ApiErrorKind.serverUnavailable,
  'push_subscription_failed': ApiErrorKind.serverUnavailable,
  'register_failed': ApiErrorKind.serverUnavailable,
  'search_failed': ApiErrorKind.serverUnavailable,
  'session_create_failed': ApiErrorKind.serverUnavailable,
  'setup_status_failed': ApiErrorKind.serverUnavailable,
  'sync_events_failed': ApiErrorKind.serverUnavailable,
  'token_create_failed': ApiErrorKind.serverUnavailable,
  'typing_publish_failed': ApiErrorKind.serverUnavailable,
  'upload_failed': ApiErrorKind.serverUnavailable,
};

/// The kind for a response with no recognised code.
ApiErrorKind apiErrorKindForStatus(int statusCode) {
  switch (statusCode) {
    case 401:
      return ApiErrorKind.sessionExpired;
    case 403:
      return ApiErrorKind.forbidden;
    case 404:
      return ApiErrorKind.notFound;
    case 408:
      return ApiErrorKind.serverUnavailable;
    case 409:
      return ApiErrorKind.conflict;
    case 410:
      return ApiErrorKind.expired;
    case 413:
      return ApiErrorKind.tooLarge;
    case 429:
      return ApiErrorKind.rateLimited;
    case 507:
      return ApiErrorKind.quotaExceeded;
  }
  if (statusCode >= 500) return ApiErrorKind.serverUnavailable;
  if (statusCode >= 400) return ApiErrorKind.badRequest;
  return ApiErrorKind.unknown;
}

/// An error response from the server.
///
/// Only the validated `error` code and a few small integer fields are kept
/// from the response body; the raw body is never stored, so it cannot reach
/// the UI, a log, or a persisted failure record.
class ApiException implements Exception {
  /// Parses [body] immediately and discards it. Bodies longer than
  /// [maxErrorBodyChars] or that are not a JSON object yield no code, and
  /// the error falls back to its HTTP status.
  ApiException(int statusCode, String body)
      : this._parsed(statusCode, _ParsedErrorBody.parse(body));

  ApiException._parsed(this.statusCode, _ParsedErrorBody parsed)
      : serverCode = parsed.code,
        _intFields = parsed.ints;

  /// The longest error body the client reads or parses.
  static const maxErrorBodyChars = 4096;

  final int statusCode;

  /// The server's machine-readable code, when it is a well-formed one.
  final String? serverCode;
  final Map<String, int> _intFields;

  /// Small integer fields that some errors carry (such as `epoch`).
  int? intField(String name) => _intFields[name];

  ApiErrorKind get kind =>
      apiErrorCodes[serverCode] ?? apiErrorKindForStatus(statusCode);

  /// True when retrying the same request later may succeed.
  bool get isTransient =>
      kind == ApiErrorKind.rateLimited ||
      kind == ApiErrorKind.serverUnavailable;

  /// A sentence safe to show to end users.
  String get message => _codeMessages[serverCode] ?? _kindMessages[kind]!;

  @override
  String toString() => message;
}

/// A response that arrived but does not match the API contract: a body
/// that is too large, not UTF-8 or JSON, the wrong shape, a field of the
/// wrong type, a bad timestamp, or a page that breaks its paging contract.
///
/// It is a [FormatException] so existing handling (setup probing, sync
/// failure classification) treats it as a malformed response. Its message
/// is fixed text and never includes any part of the response.
class ApiResponseException extends FormatException {
  const ApiResponseException.malformed()
      : tooLarge = false,
        super('The server returned an unexpected response.');

  const ApiResponseException.tooLarge()
      : tooLarge = true,
        super('The server response exceeded the size limit.');

  final bool tooLarge;

  @override
  String toString() => message;
}

class _ParsedErrorBody {
  const _ParsedErrorBody(this.code, this.ints);

  final String? code;
  final Map<String, int> ints;

  static final _codePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static const _maxIntFields = 8;

  static _ParsedErrorBody parse(String body) {
    if (body.isEmpty || body.length > ApiException.maxErrorBodyChars) {
      return const _ParsedErrorBody(null, <String, int>{});
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const _ParsedErrorBody(null, <String, int>{});
    }
    if (decoded is! Map) {
      return const _ParsedErrorBody(null, <String, int>{});
    }
    final error = decoded['error'];
    final code = error is String && _codePattern.hasMatch(error) ? error : null;
    final ints = <String, int>{};
    for (final entry in decoded.entries) {
      if (ints.length >= _maxIntFields) break;
      final key = entry.key;
      final value = entry.value;
      if (key is String && key.length <= 64 && value is int && key != 'error') {
        ints[key] = value;
      }
    }
    return _ParsedErrorBody(code, Map<String, int>.unmodifiable(ints));
  }
}

const Map<String, String> _codeMessages = <String, String>{
  'unauthorized': 'Your session is no longer valid. Sign in again.',
  'invalid_credentials': 'Sign-in failed. Check your username and password.',
  'recent_auth_required': 'Confirm your password before this sensitive action.',
  'device_id_required': 'This device must be linked before password sign-in.',
  'device_session_required':
      'This device must be linked before password sign-in.',
  'login_backoff': 'Too many sign-in attempts. Wait a moment and try again.',
  'reauth_backoff':
      'Too many password confirmations. Wait a moment and try again.',
  'forbidden': 'You do not have permission to do that.',
  'mls_not_in_group':
      'This device is not part of the conversation’s encryption group yet.',
  'not_found': 'That item was not found. It may have been removed.',
  'blob_not_found': 'That attachment is no longer on the server.',
  'no_push_subscription':
      'This device has no notification registration to test.',
  'message_expired': 'That message has expired and is no longer available.',
  'already_setup': 'This server already has an owner. Sign in or join with an '
      'invite instead.',
  'last_owner_required':
      'Transfer ownership before disabling the last owner account.',
  'idempotency_conflict': 'This message was already submitted with different '
      'data. Discard it and compose a new message.',
  'call_version_conflict': 'The call changed on another device. Try again.',
  'mls_epoch_conflict':
      'Another encryption update was applied first. Try again.',
  'recovery_transfer_in_progress':
      'A backup transfer is already in progress. Try again shortly.',
  'key_package_unavailable': 'A member device has no encryption keys '
      'available right now. Try again later.',
  'key_package_quota_exceeded':
      'This device already has the maximum number of encryption keys.',
  'device_recovery_required':
      'This device fell too far behind and needs recovery.',
  'push_test_rate_limited':
      'A test notification was sent recently. Wait a moment and try again.',
  'weak_password': 'Password must be 12–72 characters.',
  'invalid_identity': 'Usernames are 3–32 letters, digits, “_” or “-”, and '
      'the server name is at most 64 characters.',
  'invalid_invite': 'That invite code is not valid, has expired, or has '
      'already been used up.',
  'invalid_device_link': 'That link code is not valid or has expired. '
      'Generate a new one on your linked device.',
  'transcript_hash_required': 'The locally verified device credentials '
      'changed. Generate a new link and compare both devices again.',
  'transcript_mismatch': 'The locally verified device credentials changed. '
      'Generate a new link and compare both devices again.',
  'invalid_device_name': 'That device name is not valid.',
  'invalid_name': 'That name is not valid.',
  'invalid_max_uses': 'The invite use limit is not valid.',
  'invalid_expires_at': 'That expiry time is not valid.',
  'expires_at_too_far': 'That expiry time is not valid.',
  'invalid_conversation_kind': 'The server rejected this conversation type.',
  'invalid_channel_kind': 'The server rejected this channel type.',
  'invalid_retention_seconds':
      'That disappearing-message duration is not supported.',
  'invalid_role': 'That member role is not valid.',
  'invalid_member': 'Choose a valid account and role to add.',
  'account_id_required': 'Choose an account to add.',
  'upload_too_large': 'That file is too large to upload.',
  'device_key_package_required': 'The server refused this build’s encryption '
      'keys. A client with production encryption support is required.',
  'invalid_device_key_package': 'The server refused this build’s encryption '
      'keys. A client with production encryption support is required.',
  'non_production_device_key_package': 'The server refused this build’s '
      'encryption keys. A client with production encryption support is '
      'required.',
  'invalid_enrollment': 'The server refused this build’s encryption keys. A '
      'client with production encryption support is required.',
  'storage_error': 'The server had a storage problem. Try again shortly.',
  'storage_unavailable': 'The server had a storage problem. Try again shortly.',
  'blob_storage_unavailable':
      'The server had a storage problem. Try again shortly.',
  'storage_quota_exceeded': 'The server is out of storage for this account. '
      'Delete older attachments or ask the administrator for more space.',
  'blob_integrity_failed': 'The encrypted attachment could not be verified. '
      'Discard it and try again.',
  'setup_authorization_required': 'The setup token is missing or wrong. Use '
      'the one the server printed when it started (the demo keeps it in '
      'data/demo/setup-token).',
  'server_draining': 'The server is restarting. Try again shortly.',
  'push_provider_unavailable':
      'This server does not offer notifications for this device.',
};

const Map<ApiErrorKind, String> _kindMessages = <ApiErrorKind, String>{
  ApiErrorKind.sessionExpired:
      'Your session is no longer valid. Sign in again.',
  ApiErrorKind.invalidCredentials:
      'Sign-in failed. Check your username and password.',
  ApiErrorKind.reauthRequired:
      'Confirm your password before this sensitive action.',
  ApiErrorKind.deviceNotLinked:
      'This device must be linked before password sign-in.',
  ApiErrorKind.forbidden: 'You do not have permission to do that.',
  ApiErrorKind.notFound: 'That item was not found. It may have been removed.',
  ApiErrorKind.expired: 'That item has expired and is no longer available.',
  ApiErrorKind.conflict:
      'Something changed at the same time. Refresh and try again.',
  ApiErrorKind.recoveryRequired:
      'This device fell too far behind and needs recovery.',
  ApiErrorKind.rateLimited: 'Too many attempts. Wait a moment and try again.',
  ApiErrorKind.tooLarge: 'That is too large for the server to accept.',
  ApiErrorKind.quotaExceeded:
      'The server is out of space for this account. Ask the administrator.',
  ApiErrorKind.encryptionRefused: 'The server refused this build’s '
      'encryption keys. A client with production encryption support is '
      'required.',
  ApiErrorKind.setupAuthorization: 'The setup token is missing or wrong.',
  ApiErrorKind.invalidInput:
      'The server rejected the request. Check your input and try again.',
  ApiErrorKind.badRequest: 'This app sent a request the server could not '
      'accept. Update the app or try again.',
  ApiErrorKind.integrity: 'The encrypted data could not be verified.',
  ApiErrorKind.featureUnavailable:
      'This feature is not available on this server.',
  ApiErrorKind.serverUnavailable:
      'The server had a problem. Try again shortly.',
  ApiErrorKind.unknown:
      'The server rejected the request. Check your input and try again.',
};
