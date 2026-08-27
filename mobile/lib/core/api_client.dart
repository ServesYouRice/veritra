import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

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

  void close() => _httpClient.close(force: true);

  Future<Map<String, Object?>> setupStatus() async {
    return _jsonRequest('GET', '/api/v1/setup/status');
  }

  Future<EnrollmentReservation> reserveOwnerEnrollment(
      {String setupToken = ''}) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/setup/owner/enrollment',
      body: const <String, Object?>{},
      extraHeaders: setupToken.isEmpty
          ? const <String, String>{}
          : <String, String>{'X-Veritra-Setup-Token': setupToken},
    );
    return EnrollmentReservation.fromJson(json);
  }

  Future<EnrollmentReservation> reserveRegistrationEnrollment(
      String inviteCode) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/register/enrollment',
      body: <String, Object?>{'invite_code': inviteCode},
    );
    return EnrollmentReservation.fromJson(json);
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
    final json = await _jsonRequest('POST', '/api/v1/setup/owner',
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
            : <String, String>{'X-Veritra-Setup-Token': setupToken});
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
    final json =
        await _jsonRequest('POST', '/api/v1/register', body: <String, Object?>{
      'invite_code': inviteCode,
      'username': username,
      'password': password,
      'device_name': deviceName,
      'enrollment_reservation_id': enrollment.id,
      'device_key_package': base64Encode(credential.deviceKeyPackage),
      'signing_key': base64Encode(credential.signingKey),
      'challenge_signature': base64Encode(credential.challengeSignature),
    });
    return _sessionFromAuthJson(json, fallbackUsername: username);
  }

  Future<Session> login(
      {required String username,
      required String password,
      required String deviceId,
      required String deviceSecret}) async {
    final json = await _jsonRequest('POST', '/api/v1/auth/login',
        body: <String, Object?>{
          'username': username,
          'password': password,
          'device_id': deviceId,
          'device_secret': deviceSecret,
        });
    return _sessionFromAuthJson(json,
        fallbackUsername: username, fallbackDeviceSecret: deviceSecret);
  }

  Future<List<Conversation>> conversations(String token) async {
    const pageSize = 100;
    final result = <Conversation>[];
    String? before;
    while (true) {
      final path = '/api/v1/conversations?limit=$pageSize'
          '${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}';
      final json = await _jsonRequest('GET', path, token: token);
      final page =
          (json['conversations'] as List<Object?>? ?? const <Object?>[])
              .map((row) => Conversation.fromJson(
                    Map<String, Object?>.from(row as Map),
                  ))
              .toList();
      result.addAll(page);
      if (page.length < pageSize) {
        return result;
      }
      before = page.last.id;
    }
  }

  Future<List<Device>> devices(String token) async {
    const pageSize = 100;
    final result = <Device>[];
    String? after;
    while (true) {
      final path = '/api/v1/devices/me?limit=$pageSize'
          '${after == null ? '' : '&after=${Uri.encodeQueryComponent(after)}'}';
      final json = await _jsonRequest('GET', path, token: token);
      final page = (json['devices'] as List<Object?>? ?? const <Object?>[])
          .map((row) => Device.fromJson(
                Map<String, Object?>.from(row as Map),
              ))
          .toList();
      result.addAll(page);
      if (page.length < pageSize) {
        return result;
      }
      after = page.last.id;
    }
  }

  Future<void> logout(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout', token: token);
  }

  Future<void> logoutAll(String token) async {
    await _jsonRequest('POST', '/api/v1/auth/logout-all', token: token);
  }

  Future<void> reauthenticate(
    String token,
    String password,
    String deviceSecret,
  ) async {
    await _jsonRequest('POST', '/api/v1/auth/reauth', token: token, body: {
      'password': password,
      'device_secret': deviceSecret,
    });
  }

  Future<void> changePassword(String token, String newPassword) async {
    await _jsonRequest('POST', '/api/v1/account/password', token: token, body: {
      'new_password': newPassword,
    });
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

  Future<void> revokeInvite(String token, String inviteId) async {
    await _jsonRequest('DELETE', '/api/v1/invites/$inviteId', token: token);
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

  Future<ChannelCreation> createChannel(
    String token,
    String communityId,
    String name, {
    String kind = 'private',
  }) async {
    final json = await _jsonRequest(
        'POST', '/api/v1/communities/$communityId/channels',
        token: token,
        body: <String, Object?>{
          'name': name,
          'kind': kind,
        });
    return ChannelCreation.fromJson(json);
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
    final uri = Uri.parse(baseUrl).resolve(Uri(
      path: '/api/v1/attachments',
      queryParameters: <String, String>{'conversation_id': conversationId},
    ).toString());
    final request = await _httpClient.postUrl(uri).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set('X-Crypto-Metadata', jsonEncode(cryptoMetadata));
    request.contentLength = ciphertextLength;
    await request.addStream(ciphertext).timeout(_requestTimeout);
    final response = await request.close().timeout(_requestTimeout);
    final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false), (builder, chunk) => builder..add(chunk));
    final text = utf8.decode(bytes.takeBytes());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, text);
    }
    return AttachmentEnvelope.fromJson(
        Map<String, Object?>.from(jsonDecode(text) as Map));
  }

  Future<Stream<List<int>>> downloadEncryptedAttachment(
      String token, String attachmentId) async {
    final uri = Uri.parse(baseUrl)
        .resolve('/api/v1/attachments/${Uri.encodeComponent(attachmentId)}');
    final request = await _httpClient.getUrl(uri).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await utf8.decodeStream(response);
      throw ApiException(response.statusCode, body);
    }
    return response;
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
    request.headers.set('X-Recovery-Token',
        base64Url.encode(recoveryToken).replaceAll('=', ''));
    request.headers
        .set('X-Key-Derivation-Metadata', jsonEncode(cryptoMetadata));
    request.contentLength = ciphertextLength;
    await request.addStream(ciphertext).timeout(_requestTimeout);
    final response = await request.close().timeout(_requestTimeout);
    final body = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, body);
    }
  }

  Future<Stream<List<int>>> recoverEncryptedBackup(
    List<int> recoveryToken, {
    int? startOffset,
    int? endOffset,
  }) async {
    if (recoveryToken.length != 32)
      throw ArgumentError.value(recoveryToken, 'recoveryToken');
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
      final body = await utf8.decodeStream(response);
      throw ApiException(response.statusCode, body);
    }
    return response;
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
    final rows = json['key_packages'] as List<Object?>? ?? const <Object?>[];
    return rows
        .map((row) =>
            DeviceKeyPackage.fromJson(Map<String, Object?>.from(row as Map)))
        .toList(growable: false);
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
    return MlsMessage.fromJson(
      Map<String, Object?>.from(json['mls_message'] as Map),
    );
  }

  Future<MlsMessage> mlsMessage(String token, String messageId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/mls/messages/${Uri.encodeComponent(messageId)}',
      token: token,
    );
    return MlsMessage.fromJson(
      Map<String, Object?>.from(json['mls_message'] as Map),
    );
  }

  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/mls/messages',
        queryParameters: <String, String>{
          'after': after.toString(),
          'limit': limit.toString(),
        },
      ).toString(),
      token: token,
    );
    final rows = json['mls_messages'] as List<Object?>? ?? const <Object?>[];
    return rows
        .map(
            (row) => MlsMessage.fromJson(Map<String, Object?>.from(row as Map)))
        .toList(growable: false);
  }

  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/mls/revocations', token: token);
    final rows = json['mls_revocations'] as List<Object?>? ?? const <Object?>[];
    return rows
        .map((row) =>
            MlsRevocation.fromJson(Map<String, Object?>.from(row as Map)))
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> callIceServers(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/calls/config', token: token);
    return (json['ice_servers'] as List<Object?>? ?? const <Object?>[])
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList(growable: false);
  }

  Future<CallSession> createCall(String token, String conversationId,
      Map<String, Object?> encryptedMetadata) async {
    final json = await _jsonRequest('POST', '/api/v1/calls',
        token: token,
        body: <String, Object?>{
          'conversation_id': conversationId,
          'metadata': encryptedMetadata
        });
    return CallSession.fromJson(json);
  }

  Future<CallSession> transitionCall(String token, String callId, String state,
      {required int expectedVersion,
      Map<String, Object?>? encryptedMetadata}) async {
    final json = await _jsonRequest(
        'POST', '/api/v1/calls/${Uri.encodeComponent(callId)}/state',
        token: token,
        body: <String, Object?>{
          'state': state,
          'expected_version': expectedVersion,
          if (encryptedMetadata != null) 'metadata': encryptedMetadata
        });
    return CallSession.fromJson(json);
  }

  Future<List<CallSession>> calls(String token, String conversationId) async {
    final json = await _jsonRequest(
        'GET',
        Uri(path: '/api/v1/calls', queryParameters: <String, String>{
          'conversation_id': conversationId
        }).toString(),
        token: token);
    return (json['calls'] as List<Object?>? ?? const <Object?>[])
        .map((item) =>
            CallSession.fromJson(Map<String, Object?>.from(item as Map)))
        .toList(growable: false);
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

  /// Backward page of message history. Unlike [listMessages] this preserves
  /// the server's `next_before` cursor so the chat view can tell "no more
  /// history" apart from "a short page".
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    final path = Uri(
      path: '/api/v1/conversations/$conversationId/messages',
      queryParameters: <String, String>{
        'limit': limit.toString(),
        if (before != null && before.isNotEmpty) 'before': before,
      },
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    final rows = (json['messages'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    final nextBefore = json['next_before'];
    return MessagePage(
      messages: rows.map(ReceivedMessageEnvelope.fromJson).toList(),
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
    final rows = (json['members'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(ConversationMember.fromJson).toList();
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
    final json =
        await _jsonRequest('GET', '/api/v1/account/blocks', token: token);
    final rows = (json['blocks'] as List<Object?>? ?? const <Object?>[])
        .map((row) => Map<String, Object?>.from(row as Map));
    return rows.map(BlockedAccount.fromJson).toList();
  }

  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/account/blocks/${Uri.encodeComponent(accountId)}',
      token: token,
    );
    return BlockedAccount.fromJson(json);
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
    );
    return ReceivedMessageEnvelope.fromJson(json);
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
          'crypto_protocol': 'mls10-openmls-v1',
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
    return json['subscription_id'] as String;
  }

  Future<String> registerNativePush(
    String token, {
    required String provider,
    required String deviceToken,
  }) async {
    final json = await _jsonRequest('POST', '/api/v1/push/subscriptions',
        token: token,
        body: <String, Object?>{
          'provider': provider,
          'endpoint': deviceToken,
          'public_key': '',
          'auth_secret': '',
        });
    return json['subscription_id'] as String;
  }

  Future<Map<String, Object?>> pushConfig(String token) => _jsonRequest(
        'GET',
        '/api/v1/push/config',
        token: token,
      );

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

  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(String code) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/claim-enrollment',
      body: <String, Object?>{'code': code},
    );
    return EnrollmentReservation.fromJson(json);
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
    return DeviceLinkClaim(
      deviceLink: DeviceLink.fromJson(
          Map<String, Object?>.from(json['device_link'] as Map)),
      claimToken: json['claim_token'] as String,
      deviceSecret: json['device_secret'] as String,
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
    return DeviceLink.fromJson(
        Map<String, Object?>.from(json['device_link'] as Map));
  }

  Future<Session?> completeDeviceLinkClaim(String linkId, String claimToken,
      List<int> expectedTranscriptHash) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId/claim-status',
      extraHeaders: <String, String>{'X-Veritra-Claim-Token': claimToken},
    );
    final token = json['token'] as String?;
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
    if (value is! String) {
      throw ApiException(502, 'Invalid binary API field');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw ApiException(502, 'Invalid binary API field');
    }
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
    return Session(
      baseUrl: baseUrl,
      token: json['token'] as String,
      accountId: json['account_id'] as String? ?? _nestedId(json['account']),
      deviceId: json['device_id'] as String? ?? _nestedId(json['device']),
      username: _nestedField(json['account'], 'username') ?? fallbackUsername,
      deviceSecret: json['device_secret'] as String? ?? fallbackDeviceSecret,
      role: json['role'] as String? ?? _nestedField(json['account'], 'role'),
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
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_requestTimeout)) {
      if (bytes.length + chunk.length > _maxJsonResponseBytes) {
        throw const HttpException('JSON response exceeded the size limit');
      }
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, text);
    }
    if (text.isEmpty) {
      return <String, Object?>{};
    }
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }
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
        'Server URL must not contain credentials, a path, query, or fragment');
  }
  final defaultPort = scheme == 'https' ? 443 : 80;
  final origin = Uri(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != defaultPort ? uri.port : null,
  );
  return origin.toString().replaceFirst(RegExp(r'/$'), '');
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

  int? intField(String name) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded[name] is num) {
        return (decoded[name] as num).toInt();
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
      case 'recent_auth_required':
        return 'Confirm your password before this sensitive action.';
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
      case 'last_owner_required':
        return 'Transfer ownership before disabling the last owner account.';
      case 'weak_password':
        return 'Password must be 12–72 characters.';
      case 'invalid_invite':
        return 'That invite code is not valid, has expired, or has already '
            'been used up.';
      case 'invalid_device_link':
        return 'That link code is not valid or has expired. Generate a new '
            'one on your linked device.';
      case 'transcript_hash_required':
      case 'transcript_mismatch':
        return 'The locally verified device credentials changed. Generate a '
            'new link and compare both devices again.';
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
      case 'invalid_device_key_package':
      case 'non_production_device_key_package':
      case 'invalid_enrollment':
        return 'The server refused this build’s encryption keys. A '
            'client with production encryption support is required.';
      case 'storage_error':
      case 'storage_unavailable':
        return 'The server had a storage problem. Try again shortly.';
      case 'storage_quota_exceeded':
        return 'The server is out of storage for this account. Delete older '
            'attachments or ask the administrator for more space.';
      case 'blob_integrity_failed':
        return 'The encrypted attachment could not be verified. Discard it '
            'and try again.';
      case 'server_draining':
        return 'The server is restarting. Try again shortly.';
      case 'idempotency_conflict':
        return 'This message was already submitted with different data. '
            'Discard it and compose a new message.';
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
