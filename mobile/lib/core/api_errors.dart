import 'dart:convert';
import 'dart:io';

import '../l10n/l10n.dart';

/// Version of the error contract below. Bump it, and the fixture in
/// `test/fixtures/api/v1/`, when the server adds, renames or removes a code.
const int apiErrorContractVersion = 1;

/// What a server error means to the client, independent of its exact code.
enum ApiErrorKind {
  /// The session, credentials or device identity are not accepted.
  authentication,

  /// The caller is signed in but may not do this.
  permission,

  /// The target does not exist, expired, or is gone.
  notFound,

  /// The request raced another change or repeats an earlier one.
  conflict,

  /// The request itself is malformed or fails validation.
  invalidRequest,

  /// The client is sending too much or too often.
  rateLimited,

  /// The upload is larger than the server accepts.
  tooLarge,

  /// The account or server is out of storage.
  storageFull,

  /// The server refused this build's encryption keys or envelopes.
  encryption,

  /// A dependency of the server is temporarily unavailable.
  unavailable,

  /// The server failed internally.
  server,
}

/// Every error code the server writes (`server/internal/httpapi`), mapped
/// to a client kind (card T44A). `test/api_bounded_decoding.dart` keeps this map
/// equal to the server's inventory and to the versioned fixture.
const Map<String, ApiErrorKind> apiErrorKinds = <String, ApiErrorKind>{
  // Authentication.
  'unauthorized': ApiErrorKind.authentication,
  'invalid_credentials': ApiErrorKind.authentication,
  'recent_auth_required': ApiErrorKind.authentication,
  'device_id_required': ApiErrorKind.authentication,
  'device_session_required': ApiErrorKind.authentication,
  'claim_token_required': ApiErrorKind.authentication,
  'recovery_token_required': ApiErrorKind.authentication,
  'invalid_identity': ApiErrorKind.authentication,
  // Permission.
  'forbidden': ApiErrorKind.permission,
  'mls_not_in_group': ApiErrorKind.permission,
  'setup_authorization_required': ApiErrorKind.permission,
  // Not found or gone.
  'not_found': ApiErrorKind.notFound,
  'blob_not_found': ApiErrorKind.notFound,
  'message_expired': ApiErrorKind.notFound,
  'no_push_subscription': ApiErrorKind.notFound,
  'key_package_unavailable': ApiErrorKind.notFound,
  'invalid_invite': ApiErrorKind.notFound,
  'invalid_device_link': ApiErrorKind.notFound,
  // Conflict.
  'already_setup': ApiErrorKind.conflict,
  'last_owner_required': ApiErrorKind.conflict,
  'idempotency_conflict': ApiErrorKind.conflict,
  'call_version_conflict': ApiErrorKind.conflict,
  'mls_epoch_conflict': ApiErrorKind.conflict,
  'mls_group_legacy': ApiErrorKind.conflict,
  'mls_commit_bundle_required': ApiErrorKind.conflict,
  'recovery_transfer_in_progress': ApiErrorKind.conflict,
  'transcript_mismatch': ApiErrorKind.conflict,
  'device_recovery_required': ApiErrorKind.conflict,
  // Invalid request.
  'account_id_required': ApiErrorKind.invalidRequest,
  'before_and_after_exclusive': ApiErrorKind.invalidRequest,
  'conversation_id_required': ApiErrorKind.invalidRequest,
  'empty_body': ApiErrorKind.invalidRequest,
  'expires_at_too_far': ApiErrorKind.invalidRequest,
  'invalid_account_id': ApiErrorKind.invalidRequest,
  'invalid_body': ApiErrorKind.invalidRequest,
  'invalid_call_metadata': ApiErrorKind.invalidRequest,
  'invalid_call_version': ApiErrorKind.invalidRequest,
  'invalid_channel_kind': ApiErrorKind.invalidRequest,
  'invalid_conversation_id': ApiErrorKind.invalidRequest,
  'invalid_conversation_kind': ApiErrorKind.invalidRequest,
  'invalid_cursor': ApiErrorKind.invalidRequest,
  'invalid_device_id': ApiErrorKind.invalidRequest,
  'invalid_device_name': ApiErrorKind.invalidRequest,
  'invalid_expires_at': ApiErrorKind.invalidRequest,
  'invalid_input': ApiErrorKind.invalidRequest,
  'invalid_invite_id': ApiErrorKind.invalidRequest,
  'invalid_json': ApiErrorKind.invalidRequest,
  'invalid_max_uses': ApiErrorKind.invalidRequest,
  'invalid_member': ApiErrorKind.invalidRequest,
  'invalid_name': ApiErrorKind.invalidRequest,
  'invalid_push_subscription': ApiErrorKind.invalidRequest,
  'invalid_recovery_range': ApiErrorKind.invalidRequest,
  'invalid_retention_seconds': ApiErrorKind.invalidRequest,
  'invalid_role': ApiErrorKind.invalidRequest,
  'invalid_subscription_id': ApiErrorKind.invalidRequest,
  'message_id_required': ApiErrorKind.invalidRequest,
  'muted_required': ApiErrorKind.invalidRequest,
  'transcript_hash_required': ApiErrorKind.invalidRequest,
  'weak_password': ApiErrorKind.invalidRequest,
  // Rate limits and quotas on request volume.
  'login_backoff': ApiErrorKind.rateLimited,
  'reauth_backoff': ApiErrorKind.rateLimited,
  'push_test_rate_limited': ApiErrorKind.rateLimited,
  'typing_rate_limited': ApiErrorKind.rateLimited,
  'realtime_connection_limit': ApiErrorKind.rateLimited,
  'key_package_quota_exceeded': ApiErrorKind.rateLimited,
  // Size and storage.
  'upload_too_large': ApiErrorKind.tooLarge,
  'storage_quota_exceeded': ApiErrorKind.storageFull,
  // Encryption contract.
  'blob_integrity_failed': ApiErrorKind.encryption,
  'device_key_package_required': ApiErrorKind.encryption,
  'encrypted_upload_header_required': ApiErrorKind.encryption,
  'invalid_crypto_metadata': ApiErrorKind.encryption,
  'invalid_device_key_package': ApiErrorKind.encryption,
  'invalid_encrypted_envelope': ApiErrorKind.encryption,
  'invalid_encrypted_marker': ApiErrorKind.encryption,
  'invalid_enrollment': ApiErrorKind.encryption,
  'invalid_key_derivation_metadata': ApiErrorKind.encryption,
  'invalid_key_packages': ApiErrorKind.encryption,
  'key_derivation_metadata_required': ApiErrorKind.encryption,
  'non_production_device_key_package': ApiErrorKind.encryption,
  'plaintext_message_fields_forbidden': ApiErrorKind.encryption,
  'reaction_ciphertext_required': ApiErrorKind.encryption,
  // Temporarily unavailable.
  'server_draining': ApiErrorKind.unavailable,
  'storage_unavailable': ApiErrorKind.unavailable,
  'blob_storage_unavailable': ApiErrorKind.unavailable,
  'push_provider_unavailable': ApiErrorKind.unavailable,
  'setup_ui_unavailable': ApiErrorKind.unavailable,
  // Internal server failures.
  'attachment_record_failed': ApiErrorKind.server,
  'backup_record_failed': ApiErrorKind.server,
  'backup_upload_failed': ApiErrorKind.server,
  'claim_token_create_failed': ApiErrorKind.server,
  'communities_list_failed': ApiErrorKind.server,
  'community_create_failed': ApiErrorKind.server,
  'conversations_list_failed': ApiErrorKind.server,
  'device_link_claim_failed': ApiErrorKind.server,
  'device_link_status_failed': ApiErrorKind.server,
  'device_secret_create_failed': ApiErrorKind.server,
  'devices_list_failed': ApiErrorKind.server,
  'enrollment_reservation_failed': ApiErrorKind.server,
  'export_audit_failed': ApiErrorKind.server,
  'invite_create_failed': ApiErrorKind.server,
  'invites_list_failed': ApiErrorKind.server,
  'owner_create_failed': ApiErrorKind.server,
  'push_subscription_failed': ApiErrorKind.server,
  'register_failed': ApiErrorKind.server,
  'search_failed': ApiErrorKind.server,
  'session_create_failed': ApiErrorKind.server,
  'setup_status_failed': ApiErrorKind.server,
  'storage_error': ApiErrorKind.server,
  'sync_events_failed': ApiErrorKind.server,
  'token_create_failed': ApiErrorKind.server,
  'typing_publish_failed': ApiErrorKind.server,
  'upload_failed': ApiErrorKind.server,
};

/// A non-2xx API response. It keeps only the status, a validated error code
/// and a few bounded integer fields; the raw response body is never stored,
/// so it cannot reach the UI or a log through this object.
class ApiException implements Exception {
  ApiException(this.statusCode, [String body = '', this.retryAfter])
      : _decoded = _DecodedError.parse(body);

  /// Error bodies longer than this are not parsed (card T44A).
  static const int maxErrorBodyBytes = 4096;

  /// Longest server-requested wait honoured; a larger value is clamped.
  static const Duration maxRetryAfter = Duration(minutes: 5);

  final int statusCode;
  final _DecodedError _decoded;

  /// The server's `Retry-After` in whole seconds (a rate limit names when
  /// its window resets), bounded to [maxRetryAfter]; null when absent.
  final Duration? retryAfter;

  /// Parses a delta-seconds `Retry-After` header; the HTTP-date form, which
  /// this server never sends, and malformed values give null.
  static Duration? parseRetryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds == null || seconds < 0) return null;
    final wait = Duration(seconds: seconds);
    return wait > maxRetryAfter ? maxRetryAfter : wait;
  }

  /// The server's error code, when it sent a well-formed one.
  String? get serverCode => _decoded.code;

  /// A top-level integer field of the error body, such as `epoch`.
  int? intField(String name) => _decoded.ints[name];

  ApiErrorKind get kind {
    final known = apiErrorKinds[serverCode];
    if (known != null) return known;
    if (statusCode == 401) return ApiErrorKind.authentication;
    if (statusCode == 403) return ApiErrorKind.permission;
    if (statusCode == 404 || statusCode == 410) return ApiErrorKind.notFound;
    if (statusCode == 409) return ApiErrorKind.conflict;
    if (statusCode == 413) return ApiErrorKind.tooLarge;
    if (statusCode == 429) return ApiErrorKind.rateLimited;
    if (statusCode == 507) return ApiErrorKind.storageFull;
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      return ApiErrorKind.unavailable;
    }
    if (statusCode >= 500) return ApiErrorKind.server;
    return ApiErrorKind.invalidRequest;
  }

  /// Whether retrying the same request later can succeed.
  bool get retryable =>
      kind == ApiErrorKind.rateLimited ||
      kind == ApiErrorKind.unavailable ||
      kind == ApiErrorKind.server;

  /// A sentence safe to show to end users, in English; see
  /// [localizedMessage].
  String get message => localizedMessage(englishL10n);

  /// A sentence safe to show to end users, in [l10n]'s language.
  String localizedMessage(AppLocalizations l10n) {
    switch (serverCode) {
      case 'unauthorized':
        return l10n.apiErrorSessionInvalid;
      case 'invalid_credentials':
        return l10n.apiErrorInvalidCredentials;
      case 'recent_auth_required':
        return l10n.apiErrorRecentAuth;
      case 'device_id_required':
      case 'device_session_required':
        return l10n.apiErrorDeviceNotLinked;
      case 'forbidden':
        return l10n.apiErrorForbidden;
      case 'not_found':
        return l10n.apiErrorNotFound;
      case 'already_setup':
        return l10n.apiErrorAlreadySetup;
      case 'last_owner_required':
        return l10n.apiErrorLastOwner;
      case 'weak_password':
        return l10n.apiErrorWeakPassword;
      case 'invalid_invite':
        return l10n.apiErrorInvalidInvite;
      case 'invalid_device_link':
        return l10n.apiErrorInvalidDeviceLink;
      case 'transcript_hash_required':
      case 'transcript_mismatch':
        return l10n.apiErrorTranscriptMismatch;
      case 'invalid_device_name':
        return l10n.apiErrorInvalidDeviceName;
      case 'invalid_name':
        return l10n.apiErrorInvalidName;
      case 'invalid_max_uses':
        return l10n.apiErrorInvalidMaxUses;
      case 'invalid_expires_at':
      case 'expires_at_too_far':
        return l10n.apiErrorInvalidExpiry;
      case 'invalid_conversation_kind':
        return l10n.apiErrorInvalidConversationKind;
      case 'invalid_retention_seconds':
        return l10n.apiErrorInvalidRetention;
      case 'invalid_role':
        return l10n.apiErrorInvalidRole;
      case 'account_id_required':
        return l10n.apiErrorAccountRequired;
      case 'upload_too_large':
        return l10n.apiErrorUploadTooLarge;
      case 'device_key_package_required':
      case 'invalid_device_key_package':
      case 'non_production_device_key_package':
      case 'invalid_enrollment':
        return l10n.apiErrorKeyPackageRefused;
      case 'storage_error':
      case 'storage_unavailable':
        return l10n.apiErrorStorage;
      case 'storage_quota_exceeded':
        return l10n.apiErrorStorageFull;
      case 'blob_integrity_failed':
        return l10n.apiErrorBlobIntegrity;
      case 'setup_authorization_required':
        return l10n.apiErrorSetupToken;
      case 'server_draining':
        return l10n.apiErrorDraining;
      case 'idempotency_conflict':
        return l10n.apiErrorIdempotencyConflict;
      case 'message_expired':
        return l10n.apiErrorMessageExpired;
      case 'recovery_transfer_in_progress':
        return l10n.apiErrorRecoveryInProgress;
    }
    switch (kind) {
      case ApiErrorKind.authentication:
        return l10n.apiErrorSessionInvalid;
      case ApiErrorKind.permission:
        return l10n.apiErrorForbidden;
      case ApiErrorKind.notFound:
        return l10n.apiErrorNotFound;
      case ApiErrorKind.conflict:
        return l10n.apiErrorConflict;
      case ApiErrorKind.rateLimited:
        return l10n.apiErrorRateLimited;
      case ApiErrorKind.tooLarge:
        return l10n.apiErrorUploadTooLarge;
      case ApiErrorKind.storageFull:
        return l10n.apiErrorStorageFull;
      case ApiErrorKind.encryption:
        return l10n.apiErrorEncryption;
      case ApiErrorKind.unavailable:
      case ApiErrorKind.server:
        return l10n.apiErrorServer;
      case ApiErrorKind.invalidRequest:
        return l10n.apiErrorInvalidRequest;
    }
  }

  @override
  String toString() => message;
}

/// A 2xx response the client could not decode: not JSON, not the expected
/// shape, or a field of the wrong type. It never carries the body.
class ApiResponseException implements FormatException {
  const ApiResponseException();

  @override
  String get message => englishL10n.errorUnexpectedResponse;

  @override
  Object? get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => message;
}

/// A response larger than the client accepts for its kind. It stays an
/// [HttpException] so retry policy treats it like other transport failures.
class ApiResponseTooLargeException extends HttpException {
  const ApiResponseTooLargeException()
      : super('The server response exceeded the size limit.');

  @override
  String toString() => message;
}

class _DecodedError {
  const _DecodedError(this.code, this.ints);

  static final RegExp _codePattern = RegExp(r'^[a-z0-9_]{1,64}$');
  static const int _maxIntFields = 8;

  final String? code;
  final Map<String, int> ints;

  static _DecodedError parse(String body) {
    if (body.isEmpty || body.length > ApiException.maxErrorBodyBytes) {
      return const _DecodedError(null, <String, int>{});
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const _DecodedError(null, <String, int>{});
    }
    if (decoded is! Map) return const _DecodedError(null, <String, int>{});
    final error = decoded['error'];
    final code = error is String && _codePattern.hasMatch(error) ? error : null;
    final ints = <String, int>{};
    for (final entry in decoded.entries) {
      if (ints.length >= _maxIntFields) break;
      final key = entry.key;
      final value = entry.value;
      if (key is String && _codePattern.hasMatch(key) && value is int) {
        ints[key] = value;
      }
    }
    return _DecodedError(code, Map<String, int>.unmodifiable(ints));
  }
}
