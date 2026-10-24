import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import '../crypto/mls_commit_bundle.dart';
import 'admin_models.dart';
import 'api_errors.dart';
import 'models.dart';

export 'api_errors.dart';

class ApiClient {
  ApiClient({required String baseUrl, HttpClient? httpClient})
      : baseUrl = canonicalizeServerOrigin(baseUrl),
        _httpClient = httpClient ?? HttpClient() {
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  final String baseUrl;
  final HttpClient _httpClient;
  static const _requestTimeout = Duration(seconds: 30);
  static const _maxJsonResponseBytes = 2 * 1024 * 1024;

  /// Cap for replies that carry ciphertext. One item always fits: an MLS
  /// payload is at most 4 MiB (about 5.6 MB as base64) and a message
  /// envelope at most 1 MiB. Paged ciphertext lists that exceed it are
  /// re-requested with a smaller limit, so a page of large items never
  /// turns into a retry loop.
  static const _maxCiphertextResponseBytes = 16 * 1024 * 1024;

  /// The largest page the server serves; it replaces a larger limit with its
  /// default of 100, which would make a "short page" look like the end.
  static const _maxServerPageSize = 200;
  static const _maxSearchPageSize = 50;
  static const _listPageSize = 100;

  /// Upper bound on pages one list refresh follows (card T44A).
  static const maxListPages = 100;

  /// Ciphertext caps the server enforces on upload; downloads above them
  /// are refused while streaming.
  static const maxAttachmentCiphertextBytes = 50 * 1024 * 1024;
  static const maxBackupCiphertextBytes = 100 * 1024 * 1024;

  void close() => _httpClient.close(force: true);

  static int _pageLimit(int limit) =>
      limit.clamp(1, _maxServerPageSize).toInt();

  /// Runs [request] with [limit], halving it while the reply is over
  /// [_maxCiphertextResponseBytes]. A single item that is still too large
  /// rethrows.
  static Future<T> _shrinkingPage<T>(
    int limit,
    Future<T> Function(int limit) request,
  ) async {
    var current = _pageLimit(limit);
    while (true) {
      try {
        return await request(current);
      } on ApiResponseTooLargeException {
        if (current <= 1) rethrow;
        current = current ~/ 2;
      }
    }
  }

  Future<Map<String, Object?>> setupStatus() async {
    return _jsonRequest('GET', '/api/v1/setup/status');
  }

  Future<EnrollmentReservation> reserveOwnerEnrollment({
    String setupToken = '',
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/setup/owner/enrollment',
      body: const <String, Object?>{},
      extraHeaders: setupToken.isEmpty
          ? const <String, String>{}
          : <String, String>{'X-Veritra-Setup-Token': setupToken},
    );
    return _decode(() => EnrollmentReservation.fromJson(json));
  }

  Future<EnrollmentReservation> reserveRegistrationEnrollment(
    String inviteCode,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/register/enrollment',
      body: <String, Object?>{'invite_code': inviteCode},
    );
    return _decode(() => EnrollmentReservation.fromJson(json));
  }

  Future<Session> createOwner({
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    String setupToken = '',
    String? instanceName,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/setup/owner',
      body: <String, Object?>{
        if (instanceName != null && instanceName.trim().isNotEmpty)
          'instance_name': instanceName.trim(),
        'username': username,
        'password': password,
        'device_name': deviceName,
        'enrollment_reservation_id': enrollment.id,
        'device_key_package': base64Encode(credential.deviceKeyPackage),
        'signing_key': base64Encode(credential.signingKey),
        'challenge_signature': base64Encode(credential.challengeSignature),
      },
      extraHeaders: setupToken.isEmpty
          ? const <String, String>{}
          : <String, String>{'X-Veritra-Setup-Token': setupToken},
    );
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/register',
      body: <String, Object?>{
        'invite_code': inviteCode,
        'username': username,
        'password': password,
        'device_name': deviceName,
        'enrollment_reservation_id': enrollment.id,
        'device_key_package': base64Encode(credential.deviceKeyPackage),
        'signing_key': base64Encode(credential.signingKey),
        'challenge_signature': base64Encode(credential.challengeSignature),
      },
    );
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/auth/login',
      body: <String, Object?>{
        'username': username,
        'password': password,
        'device_id': deviceId,
        'device_secret': deviceSecret,
      },
    );
    return _sessionFromAuthJson(
      json,
      fallbackUsername: username,
      fallbackDeviceSecret: deviceSecret,
    );
  }

  Future<List<Conversation>> conversations(String token) {
    return _collectPages(
      (before) => '/api/v1/conversations?limit=$_listPageSize'
          '${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}',
      token: token,
      key: 'conversations',
      fromJson: Conversation.fromJson,
      cursorOf: (conversation) => conversation.id,
    );
  }

  Future<List<Device>> devices(String token) {
    return _collectPages(
      (after) => '/api/v1/devices/me?limit=$_listPageSize'
          '${after == null ? '' : '&after=${Uri.encodeQueryComponent(after)}'}',
      token: token,
      key: 'devices',
      fromJson: Device.fromJson,
      cursorOf: (device) => device.id,
    );
  }

  /// Follows a cursor-paged list to its end, with a page cap (card T44A).
  /// A cursor that does not advance is a server contract break, so it fails
  /// instead of looping; reaching the cap returns what was read so far.
  Future<List<T>> _collectPages<T>(
    String Function(String? cursor) pathFor, {
    required String token,
    required String key,
    required T Function(Map<String, Object?>) fromJson,
    required String Function(T row) cursorOf,
  }) async {
    final result = <T>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < maxListPages; page++) {
      final json = await _jsonRequest('GET', pathFor(cursor), token: token);
      final rows = _rows(json, key, fromJson);
      result.addAll(rows);
      if (rows.length < _listPageSize) return result;
      cursor = cursorOf(rows.last);
      if (!seen.add(cursor)) throw const ApiResponseException();
    }
    return result;
  }

  Future<void> logout(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout', token: token);
  }

  Future<void> logoutAll(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout-all', token: token);
  }

  /// Proves password and device secret again and asks the server to rotate
  /// the session token (card T37C). Returns the new token, which replaces
  /// [token] at once; the old one only finishes in-flight requests for a
  /// short grace. Returns null when the server does not rotate (an older
  /// server answers 204), and the caller keeps [token].
  Future<String?> reauthenticate(
    String token,
    String password,
    String deviceSecret,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/auth/reauth',
      token: token,
      body: {'password': password, 'device_secret': deviceSecret},
      extraHeaders: const <String, String>{sessionRotationHeader: '1'},
    );
    if (json.isEmpty) return null;
    final rotated = json['token'];
    if (rotated is! String || rotated.isEmpty || rotated.length > 256) {
      throw const ApiResponseException();
    }
    return rotated;
  }

  /// Opts a reauthentication into session-token rotation.
  static const String sessionRotationHeader = 'X-Veritra-Rotate-Session';

  Future<void> changePassword(String token, String newPassword) async {
    await _jsonRequest(
      'POST',
      '/api/v1/account/password',
      token: token,
      body: {'new_password': newPassword},
    );
  }

  Future<void> revokeDevice(String token, String deviceId) async {
    await _jsonRequest('DELETE', '/api/v1/devices/$deviceId', token: token);
  }

  /// Returns one bounded page of the versioned account export. The server
  /// requires recent authentication and keeps message bodies as ciphertext.
  Future<Map<String, Object?>> exportAccountPage(
    String token, {
    int limit = 250,
    String? before,
  }) async {
    final boundedLimit = limit.clamp(1, 5000).toInt();
    final path = '/api/v1/account/export?limit=$boundedLimit'
        '${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}';
    return _jsonRequest('GET', path, token: token);
  }

  Future<Conversation> createConversation(String token, String kind) async {
    return createConversationDetailed(token, kind: kind);
  }

  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async {
    final trimmedTitle = title?.trim();
    final json = await _jsonRequest(
      'POST',
      '/api/v1/conversations',
      token: token,
      body: <String, Object?>{
        'kind': kind,
        if (trimmedTitle != null && trimmedTitle.isNotEmpty)
          'title': trimmedTitle,
        if (communityId != null) 'community_id': communityId,
        if (channelId != null) 'channel_id': channelId,
        if (memberAccountIds.isNotEmpty) 'member_account_ids': memberAccountIds,
        if (retentionSeconds != null) 'retention_seconds': retentionSeconds,
      },
    );
    return _decode(() => Conversation.fromJson(json));
  }

  Future<Invite> createInvite(
    String token, {
    int maxUses = 1,
    DateTime? expiresAt,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/invites',
      token: token,
      body: <String, Object?>{
        'max_uses': maxUses,
        if (expiresAt != null)
          'expires_at': expiresAt.toUtc().toIso8601String(),
      },
    );
    return _decode(() => Invite.fromJson(json));
  }

  Future<List<Invite>> listInvites(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/invites', token: token);
    return _rows(json, 'invites', Invite.fromJson);
  }

  Future<void> revokeInvite(String token, String inviteId) async {
    await _jsonRequest('DELETE', '/api/v1/invites/$inviteId', token: token);
  }

  Future<AdminPage<AdminAccount>> listAdminAccounts(
    String token, {
    String? after,
    int limit = 50,
  }) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/admin/accounts',
        queryParameters: <String, String>{
          'limit': '$limit',
          if (after != null && after.isNotEmpty) 'after': after,
        },
      ).toString(),
      token: token,
    );
    return AdminPage<AdminAccount>(
      _rows(json, 'accounts', AdminAccount.fromJson),
      json['next_after']?.toString(),
    );
  }

  /// Suspends or reactivates an account. Needs a recent reauthentication.
  Future<void> setAdminAccountStatus(
    String token,
    String accountId, {
    required bool suspended,
  }) async {
    await _jsonRequest(
      'PATCH',
      '/api/v1/admin/accounts/${Uri.encodeComponent(accountId)}/status',
      token: token,
      body: <String, Object?>{'status': suspended ? 'suspended' : 'active'},
    );
  }

  Future<AdminPage<AdminAuditEvent>> listAdminAuditEvents(
    String token, {
    String? after,
    int limit = 50,
  }) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/admin/audit-events',
        queryParameters: <String, String>{
          'limit': '$limit',
          if (after != null && after.isNotEmpty) 'after': after,
        },
      ).toString(),
      token: token,
    );
    return AdminPage<AdminAuditEvent>(
      _rows(json, 'events', AdminAuditEvent.fromJson),
      json['next_after']?.toString(),
    );
  }

  Future<List<Community>> listCommunities(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/communities', token: token);
    return _rows(json, 'communities', Community.fromJson);
  }

  Future<List<Channel>> listChannels(String token, String communityId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/communities/$communityId/channels',
      token: token,
    );
    return _rows(json, 'channels', Channel.fromJson);
  }

  Future<Community> createCommunity(String token, String name) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/communities',
      token: token,
      body: <String, Object?>{'name': name},
    );
    return _decode(() => Community.fromJson(json));
  }

  Future<ChannelCreation> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'private',
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/communities/$communityId/channels',
      token: token,
      body: <String, Object?>{'name': name, 'kind': kind},
    );
    return _decode(() => ChannelCreation.fromJson(json));
  }

  Future<void> addConversationMember(
    String token,
    String conversationId,
    String accountId, {
    String role = 'member',
  }) async {
    await _jsonRequest(
      'POST',
      '/api/v1/conversations/$conversationId/members',
      token: token,
      body: <String, Object?>{'account_id': accountId, 'role': role},
    );
  }

  Future<Conversation> updateRetention(
    String token,
    String conversationId,
    int? retentionSeconds,
  ) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/conversations/$conversationId/retention',
      token: token,
      body: <String, Object?>{'retention_seconds': retentionSeconds},
    );
    return _decode(() => Conversation.fromJson(json));
  }

  Future<void> deleteAccount(String token) async {
    await _jsonRequest('DELETE', '/api/v1/account', token: token);
  }

  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    await _jsonRequest(
      'POST',
      '/api/v1/messages/envelopes',
      token: token,
      body: envelope.toJson(),
    );
  }

  Future<AttachmentEnvelope> uploadEncryptedAttachment(
    String token,
    String conversationId,
    Stream<List<int>> ciphertext, {
    required int ciphertextLength,
    required Map<String, Object?> cryptoMetadata,
  }) async {
    if (ciphertextLength <= 0 || ciphertextLength > 50 * 1024 * 1024) {
      throw ArgumentError.value(ciphertextLength, 'ciphertextLength');
    }
    final uri = Uri.parse(baseUrl).resolve(
      Uri(
        path: '/api/v1/attachments',
        queryParameters: <String, String>{'conversation_id': conversationId},
      ).toString(),
    );
    final request = await _httpClient.postUrl(uri).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set('X-Crypto-Metadata', jsonEncode(cryptoMetadata));
    request.contentLength = ciphertextLength;
    await request.addStream(ciphertext).timeout(_requestTimeout);
    final response = await request.close().timeout(_requestTimeout);
    final json = await _readJsonResponse(response);
    return _decode(() => AttachmentEnvelope.fromJson(json));
  }

  Future<Stream<List<int>>> downloadEncryptedAttachment(
    String token,
    String attachmentId,
  ) async {
    final uri = Uri.parse(
      baseUrl,
    ).resolve('/api/v1/attachments/${Uri.encodeComponent(attachmentId)}');
    final request = await _httpClient.getUrl(uri).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    return _boundedStream(response, maxAttachmentCiphertextBytes);
  }

  Future<void> uploadEncryptedBackup(
    String token,
    Stream<List<int>> ciphertext, {
    required int ciphertextLength,
    required List<int> recoveryToken,
    required Map<String, Object?> cryptoMetadata,
  }) async {
    if (ciphertextLength <= 0 ||
        ciphertextLength > 100 * 1024 * 1024 ||
        recoveryToken.length != 32) {
      throw ArgumentError('invalid encrypted backup');
    }
    final request = await _httpClient
        .postUrl(Uri.parse(baseUrl).resolve('/api/v1/backups'))
        .timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set(
      'X-Recovery-Token',
      base64Url.encode(recoveryToken).replaceAll('=', ''),
    );
    request.headers.set(
      'X-Key-Derivation-Metadata',
      jsonEncode(cryptoMetadata),
    );
    request.contentLength = ciphertextLength;
    await request.addStream(ciphertext).timeout(_requestTimeout);
    final response = await request.close().timeout(_requestTimeout);
    await _readJsonResponse(response);
  }

  Future<Stream<List<int>>> recoverEncryptedBackup(
    List<int> recoveryToken, {
    int? startOffset,
    int? endOffset,
  }) async {
    if (recoveryToken.length != 32) {
      // Never echo the token: ArgumentError.value would print its bytes.
      throw ArgumentError('invalid recovery token');
    }
    if (startOffset != null &&
        (startOffset < 0 || (endOffset != null && endOffset < startOffset))) {
      throw ArgumentError('invalid recovery range');
    }
    final encoded = base64Url.encode(recoveryToken).replaceAll('=', '');
    final request = await _httpClient
        .getUrl(Uri.parse(baseUrl).resolve('/api/v1/recovery'))
        .timeout(_requestTimeout);
    request.headers.set('X-Recovery-Token', encoded);
    if (startOffset != null) {
      final rangeEnd = endOffset == null ? '' : '$endOffset';
      request.headers.set('Range', 'bytes=$startOffset-$rangeEnd');
    }
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    return _boundedStream(
      response,
      maxBackupCiphertextBytes - (startOffset ?? 0),
    );
  }

  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {
    final expiresAt = DateTime.now().toUtc().add(lifetime).toIso8601String();
    await _jsonRequest(
      'POST',
      '/api/v1/devices/me/key-packages',
      token: token,
      body: <String, Object?>{
        'key_packages': <Object?>[
          for (final keyPackage in keyPackages)
            <String, Object?>{
              'key_package': base64Encode(keyPackage),
              'ciphersuite': 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
              'expires_at': expiresAt,
            },
        ],
      },
    );
  }

  Future<List<DeviceKeyPackage>> claimConversationKeyPackages(
    String token,
    String conversationId,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/key-packages/claim',
      token: token,
    );
    return _rows(
      json,
      'key_packages',
      DeviceKeyPackage.fromJson,
    ).toList(growable: false);
  }

  Future<MlsMessage> sendMlsMessage(
    String token,
    String conversationId, {
    required String kind,
    required List<int> payload,
    required String idempotencyKey,
    String? recipientDeviceId,
    String? revocationDeviceId,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/mls/messages',
      token: token,
      body: <String, Object?>{
        'kind': kind,
        'payload': base64Encode(payload),
        'idempotency_key': idempotencyKey,
        if (recipientDeviceId != null) 'recipient_device_id': recipientDeviceId,
        if (revocationDeviceId != null)
          'revocation_device_id': revocationDeviceId,
      },
    );
    return _decode(() => MlsMessage.fromJson(_object(json, 'mls_message')));
  }

  Future<MlsMessage> mlsMessage(String token, String messageId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/mls/messages/${Uri.encodeComponent(messageId)}',
      token: token,
      maxResponseBytes: _maxCiphertextResponseBytes,
    );
    return _decode(() => MlsMessage.fromJson(_object(json, 'mls_message')));
  }

  /// Sends one staged commit with its Welcomes and roster change (card
  /// I51). Returns the group's epoch after it. A 409 `mls_epoch_conflict`
  /// means another commit was accepted first.
  Future<int> sendMlsCommitBundle(
    String token,
    String conversationId, {
    required String idempotencyKey,
    required MlsCommitBundle bundle,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/mls/commits',
      token: token,
      body: bundle.toRequestJson(idempotencyKey),
    );
    return _decode(() => (json['epoch'] as num).toInt());
  }

  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/mls/pending-changes',
      token: token,
    );
    return _rows(
      json,
      'pending_changes',
      MlsPendingChange.fromJson,
    ).toList(growable: false);
  }

  /// Claims one key package for each listed device, to add them to an
  /// existing group. Devices with no package left are missing from the
  /// result.
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
    String token,
    String conversationId,
    List<String> deviceIds,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/key-packages/claim',
      token: token,
      body: <String, Object?>{'device_ids': deviceIds},
    );
    return _rows(
      json,
      'key_packages',
      DeviceKeyPackage.fromJson,
    ).toList(growable: false);
  }

  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final json = await _shrinkingPage(
      limit,
      (pageLimit) => _jsonRequest(
        'GET',
        Uri(
          path: '/api/v1/mls/messages',
          queryParameters: <String, String>{
            'after': after.toString(),
            'limit': pageLimit.toString(),
          },
        ).toString(),
        token: token,
        maxResponseBytes: _maxCiphertextResponseBytes,
      ),
    );
    return _rows(
      json,
      'mls_messages',
      MlsMessage.fromJson,
    ).toList(growable: false);
  }

  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/mls/revocations',
      token: token,
    );
    return _rows(
      json,
      'mls_revocations',
      MlsRevocation.fromJson,
    ).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> callIceServers(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/calls/config',
      token: token,
    );
    return _rows(json, 'ice_servers', (item) => item).toList(growable: false);
  }

  Future<CallSession> createCall(
    String token,
    String conversationId,
    Map<String, Object?> encryptedMetadata,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/calls',
      token: token,
      body: <String, Object?>{
        'conversation_id': conversationId,
        'metadata': encryptedMetadata,
      },
    );
    return _decode(() => CallSession.fromJson(json));
  }

  Future<CallSession> transitionCall(
    String token,
    String callId,
    String state, {
    required int expectedVersion,
    Map<String, Object?>? encryptedMetadata,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/calls/${Uri.encodeComponent(callId)}/state',
      token: token,
      body: <String, Object?>{
        'state': state,
        'expected_version': expectedVersion,
        if (encryptedMetadata != null) 'metadata': encryptedMetadata,
      },
    );
    return _decode(() => CallSession.fromJson(json));
  }

  Future<List<CallSession>> calls(String token, String conversationId) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/calls',
        queryParameters: <String, String>{'conversation_id': conversationId},
      ).toString(),
      token: token,
    );
    return _rows(json, 'calls', CallSession.fromJson).toList(growable: false);
  }

  Future<void> confirmMlsRevocation(
    String token,
    String conversationId,
    String revokedDeviceId,
  ) async {
    await _jsonRequest(
      'POST',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/mls/revocations/${Uri.encodeComponent(revokedDeviceId)}/confirm',
      token: token,
    );
  }

  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    final json = await _shrinkingPage(limit, (pageLimit) {
      final path = Uri(
        path: '/api/v1/conversations/$conversationId/messages',
        queryParameters: <String, String>{
          'limit': pageLimit.toString(),
          if (before != null && before.isNotEmpty) 'before': before,
          if (after != null && after.isNotEmpty) 'after': after,
        },
      ).toString();
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    return _rows(json, 'messages', ReceivedMessageEnvelope.fromJson);
  }

  /// Backward page of message history. Unlike [listMessages] this preserves
  /// the server's `next_before` cursor so the chat view can tell "no more
  /// history" apart from "a short page".
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    final json = await _shrinkingPage(limit, (pageLimit) {
      final path = Uri(
        path: '/api/v1/conversations/$conversationId/messages',
        queryParameters: <String, String>{
          'limit': pageLimit.toString(),
          if (before != null && before.isNotEmpty) 'before': before,
        },
      ).toString();
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    final nextBefore = json['next_before'];
    return MessagePage(
      messages: _rows(json, 'messages', ReceivedMessageEnvelope.fromJson),
      nextBefore:
          nextBefore is String && nextBefore.isNotEmpty ? nextBefore : null,
    );
  }

  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/members',
      token: token,
    );
    return _rows(json, 'members', ConversationMember.fromJson);
  }

  /// Removes a member, or leaves the conversation when [accountId] is `me`.
  /// The server records this as membership only; MLS removal is coordinated
  /// separately and is not implied by a successful response.
  Future<void> removeConversationMember(
    String token,
    String conversationId,
    String accountId,
  ) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/members/${Uri.encodeComponent(accountId)}',
      token: token,
    );
  }

  Future<bool> conversationMuted(String token, String conversationId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/notifications',
      token: token,
    );
    return json['muted'] == true;
  }

  Future<bool> setConversationMuted(
    String token,
    String conversationId,
    bool muted,
  ) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/notifications',
      token: token,
      body: <String, Object?>{'muted': muted},
    );
    return json['muted'] == true;
  }

  Future<List<BlockedAccount>> listBlocks(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/account/blocks',
      token: token,
    );
    return _rows(json, 'blocks', BlockedAccount.fromJson);
  }

  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/account/blocks/${Uri.encodeComponent(accountId)}',
      token: token,
    );
    return _decode(() => BlockedAccount.fromJson(json));
  }

  Future<void> unblockAccount(String token, String accountId) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/account/blocks/${Uri.encodeComponent(accountId)}',
      token: token,
    );
  }

  Future<ReceivedMessageEnvelope> message(
    String token,
    String messageId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/messages/${Uri.encodeComponent(messageId)}',
      token: token,
      maxResponseBytes: _maxCiphertextResponseBytes,
    );
    return _decode(() => ReceivedMessageEnvelope.fromJson(json));
  }

  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final json = await _shrinkingPage(limit, (pageLimit) {
      final path = Uri(
        path: '/api/v1/sync/events',
        queryParameters: <String, String>{
          'after': after.toString(),
          'limit': pageLimit.toString(),
        },
      ).toString();
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    return _rows(json, 'events', SyncEvent.fromJson);
  }

  Future<void> sendReaction(
    String token,
    String messageId,
    List<int> reactionCiphertext,
  ) async {
    await _jsonRequest(
      'POST',
      '/api/v1/messages/$messageId/reactions',
      token: token,
      body: <String, Object?>{
        'reaction_ciphertext': base64Encode(reactionCiphertext),
        'crypto_protocol': 'mls10-openmls-v1',
      },
    );
  }

  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {
    await _jsonRequest(
      'POST',
      '/api/v1/conversations/$conversationId/read-receipts',
      token: token,
      body: <String, Object?>{'message_id': messageId},
    );
  }

  Future<String> registerWebPush(
    String token, {
    required String endpoint,
    required String publicKey,
    required String authSecret,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/push/subscriptions',
      token: token,
      body: <String, Object?>{
        'provider': 'webpush',
        'endpoint': endpoint,
        'public_key': publicKey,
        'auth_secret': authSecret,
      },
    );
    return _decode(() => json['subscription_id'] as String);
  }

  Future<String> registerNativePush(
    String token, {
    required String provider,
    required String deviceToken,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/push/subscriptions',
      token: token,
      body: <String, Object?>{
        'provider': provider,
        'endpoint': deviceToken,
        'public_key': '',
        'auth_secret': '',
      },
    );
    return _decode(() => json['subscription_id'] as String);
  }

  /// Sends the generic wake to this device's own registrations and returns
  /// one result class per registration (card I41).
  Future<List<String>> sendTestPush(String token) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/push/test',
      token: token,
      body: const <String, Object?>{},
    );
    return _rows(
      json,
      'results',
      (row) => row['result'],
    ).whereType<String>().toList(growable: false);
  }

  Future<Map<String, Object?>> pushConfig(String token) =>
      _jsonRequest('GET', '/api/v1/push/config', token: token);

  Future<void> disablePush(String token, String subscriptionId) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/push/subscriptions/$subscriptionId',
      token: token,
    );
  }

  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final queryParameters = <String, String>{
      'q': query,
      'limit': limit.clamp(1, _maxSearchPageSize).toString(),
      'offset': max(0, offset).toString(),
    };
    final path = Uri(
      path: '/api/v1/search/metadata',
      queryParameters: queryParameters,
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    return _rows(json, 'results', MetadataSearchResult.fromJson);
  }

  Future<DeviceLink> createDeviceLink(String token) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links',
      token: token,
      body: <String, Object?>{},
    );
    return _decode(() => DeviceLink.fromJson(_object(json, 'device_link')));
  }

  Future<DeviceLink> deviceLink(String token, String linkId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId',
      token: token,
    );
    return _decode(() => DeviceLink.fromJson(_object(json, 'device_link')));
  }

  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(String code) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/claim-enrollment',
      body: <String, Object?>{'code': code},
    );
    return _decode(() => EnrollmentReservation.fromJson(json));
  }

  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    required DeviceLinkVerification verification,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/claim',
      body: <String, Object?>{
        'code': code,
        'device_name': deviceName,
        'enrollment_reservation_id': enrollment.id,
        'device_key_package': base64Encode(credential.deviceKeyPackage),
        'signing_key': base64Encode(credential.signingKey),
        'challenge_signature': base64Encode(credential.challengeSignature),
        'transcript_hash': base64Encode(verification.transcriptHash),
      },
    );
    return _decode(
      () => DeviceLinkClaim(
        deviceLink: DeviceLink.fromJson(_object(json, 'device_link')),
        claimToken: json['claim_token'] as String,
        deviceSecret: json['device_secret'] as String,
      ),
    );
  }

  Future<DeviceLink> approveDeviceLink(
    String token,
    String linkId,
    List<int> transcriptHash,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/$linkId/approve',
      token: token,
      body: <String, Object?>{'transcript_hash': base64Encode(transcriptHash)},
    );
    return _decode(() => DeviceLink.fromJson(_object(json, 'device_link')));
  }

  Future<Session?> completeDeviceLinkClaim(
    String linkId,
    String claimToken,
    List<int> expectedTranscriptHash,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId/claim-status',
      extraHeaders: <String, String>{'X-Veritra-Claim-Token': claimToken},
    );
    final token = _decode(() => json['token'] as String?);
    if (token == null) {
      return null;
    }
    final transcriptHash = _decodeRequiredBytes(json['transcript_hash']);
    if (!_bytesEqual(transcriptHash, expectedTranscriptHash)) {
      throw ApiException(409, '{"error":"transcript_mismatch"}');
    }
    return _sessionFromAuthJson(json);
  }

  List<int> _decodeRequiredBytes(Object? value) {
    if (value is! String) throw const ApiResponseException();
    return _decode(() => base64Decode(value));
  }

  bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Session _sessionFromAuthJson(
    Map<String, Object?> json, {
    String? fallbackUsername,
    String? fallbackDeviceSecret,
  }) {
    return _decode(
      () => Session(
        baseUrl: baseUrl,
        token: json['token'] as String,
        accountId: json['account_id'] as String? ?? _nestedId(json['account']),
        deviceId: json['device_id'] as String? ?? _nestedId(json['device']),
        username: _nestedField(json['account'], 'username') ?? fallbackUsername,
        deviceSecret: json['device_secret'] as String? ?? fallbackDeviceSecret,
        role: json['role'] as String? ?? _nestedField(json['account'], 'role'),
      ),
    );
  }

  String? _nestedId(Object? value) => _nestedField(value, 'id');

  String? _nestedField(Object? value, String field) {
    if (value is Map) {
      final nested = value[field];
      if (nested is String) {
        return nested;
      }
    }
    return null;
  }

  Future<Map<String, Object?>> _jsonRequest(
    String method,
    String path, {
    String? token,
    Map<String, Object?>? body,
    Map<String, String> extraHeaders = const <String, String>{},
    int maxResponseBytes = _maxJsonResponseBytes,
  }) async {
    final uri = Uri.parse(baseUrl).resolve(path);
    final request =
        await _httpClient.openUrl(method, uri).timeout(_requestTimeout);
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    extraHeaders.forEach((key, value) => request.headers.set(key, value));
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_requestTimeout);
    return _readJsonResponse(response, maxResponseBytes);
  }

  /// Reads a JSON object response. A non-2xx status becomes an
  /// [ApiException] built from at most [ApiException.maxErrorBodyBytes];
  /// a 2xx body is capped at [maxBytes] and must be a UTF-8
  /// JSON object (or empty). No body text is kept in a thrown error.
  Future<Map<String, Object?>> _readJsonResponse(
    HttpClientResponse response, [
    int maxBytes = _maxJsonResponseBytes,
  ]) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    final bytes = await _readBounded(response, maxBytes);
    if (bytes.isEmpty) {
      return <String, Object?>{};
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ApiResponseException();
    }
    if (decoded is! Map) throw const ApiResponseException();
    return _decode(() => Map<String, Object?>.from(decoded as Map));
  }

  /// Builds an [ApiException] from the start of an error body and stops
  /// reading there, so a large or binary error page costs at most a few KB.
  static Future<ApiException> _apiError(HttpClientResponse response) async {
    final bytes = await _readBounded(
      response,
      ApiException.maxErrorBodyBytes,
      truncate: true,
    );
    final text = utf8.decode(bytes, allowMalformed: true);
    return ApiException(
      response.statusCode,
      text,
      ApiException.parseRetryAfter(
          response.headers.value(HttpHeaders.retryAfterHeader)),
    );
  }

  static Future<Uint8List> _readBounded(
    Stream<List<int>> source,
    int maxBytes, {
    bool truncate = false,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in source.timeout(_requestTimeout)) {
      final room = maxBytes - bytes.length;
      if (chunk.length > room) {
        if (!truncate) throw const ApiResponseTooLargeException();
        // Leaving the loop cancels the subscription and the rest of the
        // body is never read.
        bytes.add(chunk.sublist(0, room));
        break;
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// Passes a download through while counting bytes; more than [maxBytes]
  /// (or an announced length above it) fails instead of filling the disk.
  static Future<Stream<List<int>>> _boundedStream(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (maxBytes < 0 || response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      throw const ApiResponseTooLargeException();
    }
    return _countBytes(response, maxBytes);
  }

  static Stream<List<int>> _countBytes(
    Stream<List<int>> source,
    int maxBytes,
  ) async* {
    var received = 0;
    await for (final chunk in source) {
      received += chunk.length;
      if (received > maxBytes) throw const ApiResponseTooLargeException();
      yield chunk;
    }
  }
}

/// Runs a model decoder and turns any shape or type mismatch into an
/// [ApiResponseException], so a malformed response is one typed failure
/// instead of a `TypeError` with the offending value in its text.
T _decode<T>(T Function() build) {
  try {
    return build();
  } on ApiResponseException {
    rethrow;
  } on FormatException {
    throw const ApiResponseException();
  } on TypeError {
    throw const ApiResponseException();
  } on ArgumentError {
    throw const ApiResponseException();
  }
}

/// The JSON object under [key]; anything else is a malformed response.
Map<String, Object?> _object(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw const ApiResponseException();
  return _decode(() => Map<String, Object?>.from(value));
}

/// Decodes the list under [key]. An absent list is empty; a list that is
/// not a list of objects, or any row that fails [fromJson], fails the whole
/// response so a partial page is never mistaken for the server's answer.
List<T> _rows<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) fromJson,
) {
  final value = json[key];
  if (value == null) return <T>[];
  if (value is! List) throw const ApiResponseException();
  return _decode(
    () => <T>[
      for (final row in value)
        if (row is Map)
          fromJson(Map<String, Object?>.from(row))
        else
          throw const ApiResponseException(),
    ],
  );
}

String canonicalizeServerOrigin(String raw) {
  final uri = Uri.parse(raw.trim());
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('A full HTTP(S) server origin is required');
  }
  if (uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Server URL must not contain credentials, a path, query, or fragment',
    );
  }
  final defaultPort = scheme == 'https' ? 443 : 80;
  final origin = Uri(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != defaultPort ? uri.port : null,
  );
  return origin.toString().replaceFirst(RegExp(r'/$'), '');
}
