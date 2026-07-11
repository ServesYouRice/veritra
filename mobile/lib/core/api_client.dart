import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

class ApiClient {
  ApiClient({required this.baseUrl, HttpClient? httpClient})
      : _httpClient = httpClient ?? HttpClient() {
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  final String baseUrl;
  final HttpClient _httpClient;
  static const _requestTimeout = Duration(seconds: 30);

  Future<Map<String, Object?>> setupStatus() async {
    return _jsonRequest('GET', '/api/v1/setup/status');
  }

  Future<Session> createOwner({
    required String username,
    required String password,
    required String deviceName,
    required List<int> deviceKeyPackage,
    String instanceName = 'Private Messenger',
  }) async {
    final json = await _jsonRequest('POST', '/api/v1/setup/owner',
        body: <String, Object?>{
          'instance_name': instanceName,
          'username': username,
          'password': password,
          'device_name': deviceName,
          'device_key_package': base64Encode(deviceKeyPackage),
        },
        setupRequest: true);
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required List<int> deviceKeyPackage,
  }) async {
    final json =
        await _jsonRequest('POST', '/api/v1/register', body: <String, Object?>{
      'invite_code': inviteCode,
      'username': username,
      'password': password,
      'device_name': deviceName,
      'device_key_package': base64Encode(deviceKeyPackage),
    });
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<Session> login(
      {required String username,
      required String password,
      required String deviceId}) async {
    final json = await _jsonRequest('POST', '/api/v1/auth/login',
        body: <String, Object?>{
          'username': username,
          'password': password,
          'device_id': deviceId,
        });
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<List<Conversation>> conversations(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/conversations', token: token);
    final rows = (json['conversations'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(Conversation.fromJson).toList();
  }

  Future<List<Device>> devices(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/devices/me', token: token);
    final rows = (json['devices'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(Device.fromJson).toList();
  }

  Future<void> logout(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout', token: token);
  }

  Future<void> logoutAll(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout-all', token: token);
  }

  Future<void> revokeDevice(String token, String deviceId) async {
    await _jsonRequest('DELETE', '/api/v1/devices/$deviceId', token: token);
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
    final json = await _jsonRequest('POST', '/api/v1/conversations',
        token: token,
        body: <String, Object?>{
          'kind': kind,
          if (trimmedTitle != null && trimmedTitle.isNotEmpty)
            'title': trimmedTitle,
          if (communityId != null) 'community_id': communityId,
          if (channelId != null) 'channel_id': channelId,
          if (memberAccountIds.isNotEmpty)
            'member_account_ids': memberAccountIds,
          if (retentionSeconds != null) 'retention_seconds': retentionSeconds,
        });
    return Conversation.fromJson(json);
  }

  Future<Invite> createInvite(
    String token, {
    int maxUses = 1,
    DateTime? expiresAt,
  }) async {
    final json = await _jsonRequest('POST', '/api/v1/invites',
        token: token,
        body: <String, Object?>{
          'max_uses': maxUses,
          if (expiresAt != null)
            'expires_at': expiresAt.toUtc().toIso8601String(),
        });
    return Invite.fromJson(json);
  }

  Future<List<Invite>> listInvites(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/invites', token: token);
    final rows = (json['invites'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(Invite.fromJson).toList();
  }

  Future<List<Community>> listCommunities(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/communities', token: token);
    final rows = (json['communities'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(Community.fromJson).toList();
  }

  Future<List<Channel>> listChannels(String token, String communityId) async {
    final json = await _jsonRequest(
        'GET', '/api/v1/communities/$communityId/channels',
        token: token);
    final rows = (json['channels'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(Channel.fromJson).toList();
  }

  Future<Community> createCommunity(String token, String name) async {
    final json = await _jsonRequest('POST', '/api/v1/communities',
        token: token,
        body: <String, Object?>{
          'name': name,
        });
    return Community.fromJson(json);
  }

  Future<Channel> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'text',
  }) async {
    final json = await _jsonRequest(
        'POST', '/api/v1/communities/$communityId/channels',
        token: token,
        body: <String, Object?>{
          'name': name,
          'kind': kind,
        });
    return Channel.fromJson(json);
  }

  Future<void> addConversationMember(
    String token,
    String conversationId,
    String accountId, {
    String role = 'member',
  }) async {
    await _jsonRequest('POST', '/api/v1/conversations/$conversationId/members',
        token: token,
        body: <String, Object?>{
          'account_id': accountId,
          'role': role,
        });
  }

  Future<Conversation> updateRetention(
    String token,
    String conversationId,
    int? retentionSeconds,
  ) async {
    final json = await _jsonRequest(
        'PUT', '/api/v1/conversations/$conversationId/retention',
        token: token,
        body: <String, Object?>{
          'retention_seconds': retentionSeconds,
        });
    return Conversation.fromJson(json);
  }

  Future<void> deleteAccount(String token) async {
    await _jsonRequest('DELETE', '/api/v1/account', token: token);
  }

  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    await _jsonRequest('POST', '/api/v1/messages/envelopes',
        token: token, body: envelope.toJson());
  }

  Future<List<ReceivedMessageEnvelope>> listMessages(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    final queryParameters = <String, String>{
      'limit': limit.toString(),
      if (before != null && before.isNotEmpty) 'before': before,
      if (after != null && after.isNotEmpty) 'after': after,
    };
    final path = Uri(
      path: '/api/v1/conversations/$conversationId/messages',
      queryParameters: queryParameters,
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    final rows = (json['messages'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(ReceivedMessageEnvelope.fromJson).toList();
  }

  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final path = Uri(
      path: '/api/v1/sync/events',
      queryParameters: <String, String>{
        'after': after.toString(),
        'limit': limit.toString(),
      },
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    final rows = (json['events'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(SyncEvent.fromJson).toList();
  }

  Future<void> sendReaction(
      String token, String messageId, List<int> reactionCiphertext) async {
    await _jsonRequest('POST', '/api/v1/messages/$messageId/reactions',
        token: token,
        body: <String, Object?>{
          'reaction_ciphertext': base64Encode(reactionCiphertext),
        });
  }

  Future<void> markRead(
      String token, String conversationId, String messageId) async {
    await _jsonRequest(
        'POST', '/api/v1/conversations/$conversationId/read-receipts',
        token: token,
        body: <String, Object?>{
          'message_id': messageId,
        });
  }

  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final queryParameters = <String, String>{
      'q': query,
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    final path =
        Uri(path: '/api/v1/search/metadata', queryParameters: queryParameters)
            .toString();
    final json = await _jsonRequest('GET', path, token: token);
    final rows = (json['results'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(MetadataSearchResult.fromJson).toList();
  }

  Future<DeviceLink> createDeviceLink(String token) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links',
      token: token,
      body: <String, Object?>{},
    );
    return DeviceLink.fromJson(
        Map<String, Object?>.from(json['device_link'] as Map));
  }

  Future<DeviceLink> deviceLink(String token, String linkId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId',
      token: token,
    );
    return DeviceLink.fromJson(
        Map<String, Object?>.from(json['device_link'] as Map));
  }

  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required List<int> deviceKeyPackage,
    List<int> signingKey = const <int>[],
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/claim',
      body: <String, Object?>{
        'code': code,
        'device_name': deviceName,
        'device_key_package': base64Encode(deviceKeyPackage),
        if (signingKey.isNotEmpty) 'signing_key': base64Encode(signingKey),
      },
    );
    return DeviceLinkClaim(
      deviceLink: DeviceLink.fromJson(
          Map<String, Object?>.from(json['device_link'] as Map)),
      claimToken: json['claim_token'] as String,
    );
  }

  Future<DeviceLink> approveDeviceLink(
    String token,
    String linkId,
    String verificationCode,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/$linkId/approve',
      token: token,
      body: <String, Object?>{'verification_code': verificationCode},
    );
    return DeviceLink.fromJson(
        Map<String, Object?>.from(json['device_link'] as Map));
  }

  Future<Session?> completeDeviceLinkClaim(
      String linkId, String claimToken) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId/claim-status',
      extraHeaders: <String, String>{'X-Veritra-Claim-Token': claimToken},
    );
    final token = json['token'] as String?;
    if (token == null) {
      return null;
    }
    return _sessionFromAuthJson(json);
  }

  Session _sessionFromAuthJson(
    Map<String, Object?> json, {
    String? fallbackUsername,
  }) {
    return Session(
      baseUrl: baseUrl,
      token: json['token'] as String,
      accountId: json['account_id'] as String? ?? _nestedId(json['account']),
      deviceId: json['device_id'] as String? ?? _nestedId(json['device']),
      username: _nestedField(json['account'], 'username') ?? fallbackUsername,
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
    bool setupRequest = false,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final uri = Uri.parse(baseUrl).resolve(path);
    final request =
        await _httpClient.openUrl(method, uri).timeout(_requestTimeout);
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (setupRequest) {
      request.headers.set('X-Private-Messenger-Setup', '1');
    }
    extraHeaders.forEach((key, value) => request.headers.set(key, value));
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_requestTimeout);
    final text = await utf8.decodeStream(response).timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, text);
    }
    if (text.isEmpty) {
      return <String, Object?>{};
    }
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  String? get serverCode {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is String) {
          return error;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String get message {
    switch (serverCode) {
      case 'unauthorized':
        return 'Your session is no longer valid. Sign in again.';
      case 'invalid_credentials':
        return 'Sign-in failed. Check your username and password.';
      case 'device_id_required':
      case 'device_session_required':
        return 'This device must be linked before password sign-in.';
      case 'forbidden':
        return 'You do not have permission to do that.';
      case 'not_found':
        return 'That item was not found. It may have been removed.';
      case 'already_setup':
        return 'This server already has an owner. Sign in or join with an '
            'invite instead.';
      case 'weak_password':
        return 'Password must be 12–72 characters.';
      case 'invalid_invite':
        return 'That invite code is not valid, has expired, or has already '
            'been used up.';
      case 'invalid_device_link':
        return 'That link code is not valid or has expired. Generate a new '
            'one on your linked device.';
      case 'verification_code_required':
        return 'Enter the verification code shown on the new device.';
      case 'verification_code_mismatch':
        return 'The verification code did not match. Check both devices and '
            'try again.';
      case 'invalid_device_name':
        return 'That device name is not valid.';
      case 'invalid_name':
        return 'That name is not valid.';
      case 'invalid_max_uses':
        return 'The invite use limit is not valid.';
      case 'invalid_expires_at':
      case 'expires_at_too_far':
        return 'That expiry time is not valid.';
      case 'invalid_conversation_kind':
        return 'The server rejected this conversation type.';
      case 'invalid_retention_seconds':
        return 'That disappearing-message duration is not supported.';
      case 'invalid_role':
        return 'That member role is not valid.';
      case 'cannot_grant_higher_role':
        return 'You cannot grant a role higher than your own.';
      case 'account_id_required':
        return 'Choose an account to add.';
      case 'upload_too_large':
        return 'That file is too large to upload.';
      case 'device_key_package_required':
      case 'non_production_device_key_package':
        return 'The server refused this build’s encryption keys. A '
            'client with production encryption support is required.';
      case 'storage_error':
      case 'storage_unavailable':
        return 'The server had a storage problem. Try again shortly.';
    }
    if (statusCode == 401) {
      return 'Your session is no longer valid. Sign in again.';
    }
    if (statusCode == 403) {
      return 'You do not have permission to do that.';
    }
    if (statusCode == 404) {
      return 'That item was not found. It may have been removed.';
    }
    if (statusCode == 429) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    if (statusCode >= 500) {
      return 'The server had a problem. Try again shortly.';
    }
    return 'The server rejected the request. Check your input and try again.';
  }

  @override
  String toString() => message;
}
