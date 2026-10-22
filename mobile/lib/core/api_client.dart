import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/mls_commit_bundle.dart';
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

  /// Rows requested per page for full-list reads.
  static const listPageSize = 100;

  /// Pages a full-list read follows before it stops (card I44).
  static const maxListPages = 50;

  /// The server's largest page for messages, sync and MLS reads.
  static const maxPageSize = 200;
  static const maxSearchPageSize = 50;

  /// Rows accepted in a list response that has no paging contract.
  static const maxUnpagedRows = 5000;

  /// Largest ciphertext the server accepts, and so serves, per blob.
  static const maxAttachmentBytes = 50 * 1024 * 1024;
  static const maxBackupBytes = 100 * 1024 * 1024;

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
    return _model(json, EnrollmentReservation.fromJson);
  }

  Future<EnrollmentReservation> reserveRegistrationEnrollment(
      String inviteCode) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/register/enrollment',
      body: <String, Object?>{'invite_code': inviteCode},
    );
    return _model(json, EnrollmentReservation.fromJson);
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
    return _decode(
        () => _sessionFromAuthJson(json, fallbackUsername: username));
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
    return _decode(
        () => _sessionFromAuthJson(json, fallbackUsername: username));
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
    return _decode(() => _sessionFromAuthJson(json,
        fallbackUsername: username, fallbackDeviceSecret: deviceSecret));
  }

  /// Every conversation, read in pages of [listPageSize]. Paging stops at
  /// [maxListPages] pages, and a page that is oversized or repeats its
  /// cursor is a contract break, so a faulty server cannot loop the client
  /// or grow the list without bound.
  Future<List<Conversation>> conversations(String token) {
    return _collectPages(
      key: 'conversations',
      fromJson: Conversation.fromJson,
      idOf: (conversation) => conversation.id,
      path: (cursor) => '/api/v1/conversations?limit=$listPageSize'
          '${cursor == null ? '' : '&before=${Uri.encodeQueryComponent(cursor)}'}',
      token: token,
    );
  }

  /// Every device of this account, paged and bounded like [conversations].
  Future<List<Device>> devices(String token) {
    return _collectPages(
      key: 'devices',
      fromJson: Device.fromJson,
      idOf: (device) => device.id,
      path: (cursor) => '/api/v1/devices/me?limit=$listPageSize'
          '${cursor == null ? '' : '&after=${Uri.encodeQueryComponent(cursor)}'}',
      token: token,
    );
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
    return _model(json, Conversation.fromJson);
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
    return _model(json, Invite.fromJson);
  }

  Future<List<Invite>> listInvites(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/invites', token: token);
    return _rows(json, 'invites', Invite.fromJson);
  }

  Future<void> revokeInvite(String token, String inviteId) async {
    await _jsonRequest('DELETE', '/api/v1/invites/$inviteId', token: token);
  }

  Future<List<Community>> listCommunities(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/communities', token: token);
    return _rows(json, 'communities', Community.fromJson);
  }

  Future<List<Channel>> listChannels(String token, String communityId) async {
    final json = await _jsonRequest(
        'GET', '/api/v1/communities/$communityId/channels',
        token: token);
    return _rows(json, 'channels', Channel.fromJson);
  }

  Future<Community> createCommunity(String token, String name) async {
    final json = await _jsonRequest('POST', '/api/v1/communities',
        token: token,
        body: <String, Object?>{
          'name': name,
        });
    return _model(json, Community.fromJson);
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
    return _model(json, ChannelCreation.fromJson);
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
    return _model(json, Conversation.fromJson);
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
    return _model(await _readJson(response), AttachmentEnvelope.fromJson);
  }

  /// Streams one attachment's ciphertext. The stream fails with
  /// [ApiResponseException] once it passes [maxAttachmentBytes] (or the server
  /// announces more), and with a [TimeoutException] when it stalls.
  Future<Stream<List<int>>> downloadEncryptedAttachment(
      String token, String attachmentId) async {
    final uri = Uri.parse(baseUrl)
        .resolve('/api/v1/attachments/${Uri.encodeComponent(attachmentId)}');
    final request = await _httpClient.getUrl(uri).timeout(_requestTimeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(_requestTimeout);
    return _boundedDownload(response, maxAttachmentBytes);
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
    await _readJson(response);
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
    // A backup is at most [maxBackupBytes]; a resumed download only has
    // the rest of it to send.
    final remaining = maxBackupBytes - (startOffset ?? 0);
    return _boundedDownload(response, remaining < 0 ? 0 : remaining);
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
    return _rows(json, 'key_packages', DeviceKeyPackage.fromJson);
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
    return _model(json['mls_message'], MlsMessage.fromJson);
  }

  Future<MlsMessage> mlsMessage(String token, String messageId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/mls/messages/${Uri.encodeComponent(messageId)}',
      token: token,
    );
    return _model(json['mls_message'], MlsMessage.fromJson);
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
    return _decode(() => requiredApiInt(json['epoch']));
  }

  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/mls/pending-changes', token: token);
    return _rows(json, 'pending_changes', MlsPendingChange.fromJson);
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
    return _rows(json, 'key_packages', DeviceKeyPackage.fromJson);
  }

  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final boundedLimit = _pageLimit(limit);
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/mls/messages',
        queryParameters: <String, String>{
          'after': after.toString(),
          'limit': '$boundedLimit',
        },
      ).toString(),
      token: token,
    );
    return _rows(json, 'mls_messages', MlsMessage.fromJson,
        maxRows: boundedLimit);
  }

  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/mls/revocations', token: token);
    return _rows(json, 'mls_revocations', MlsRevocation.fromJson);
  }

  Future<List<Map<String, Object?>>> callIceServers(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/calls/config', token: token);
    return _rows(json, 'ice_servers', (item) => item);
  }

  Future<CallSession> createCall(String token, String conversationId,
      Map<String, Object?> encryptedMetadata) async {
    final json = await _jsonRequest('POST', '/api/v1/calls',
        token: token,
        body: <String, Object?>{
          'conversation_id': conversationId,
          'metadata': encryptedMetadata
        });
    return _model(json, CallSession.fromJson);
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
    return _model(json, CallSession.fromJson);
  }

  Future<List<CallSession>> calls(String token, String conversationId) async {
    final json = await _jsonRequest(
        'GET',
        Uri(path: '/api/v1/calls', queryParameters: <String, String>{
          'conversation_id': conversationId
        }).toString(),
        token: token);
    return _rows(json, 'calls', CallSession.fromJson);
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
    final boundedLimit = _pageLimit(limit);
    final queryParameters = <String, String>{
      'limit': '$boundedLimit',
      if (before != null && before.isNotEmpty) 'before': before,
      if (after != null && after.isNotEmpty) 'after': after,
    };
    final path = Uri(
      path: '/api/v1/conversations/$conversationId/messages',
      queryParameters: queryParameters,
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    return _rows(json, 'messages', ReceivedMessageEnvelope.fromJson,
        maxRows: boundedLimit);
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
    final boundedLimit = _pageLimit(limit);
    final path = Uri(
      path: '/api/v1/conversations/$conversationId/messages',
      queryParameters: <String, String>{
        'limit': '$boundedLimit',
        if (before != null && before.isNotEmpty) 'before': before,
      },
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    final messages = _rows(json, 'messages', ReceivedMessageEnvelope.fromJson,
        maxRows: boundedLimit);
    final nextBefore = json['next_before'];
    return MessagePage(
      messages: messages,
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
    final json =
        await _jsonRequest('GET', '/api/v1/account/blocks', token: token);
    return _rows(json, 'blocks', BlockedAccount.fromJson);
  }

  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/account/blocks/${Uri.encodeComponent(accountId)}',
      token: token,
    );
    return _model(json, BlockedAccount.fromJson);
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
    return _model(json, ReceivedMessageEnvelope.fromJson);
  }

  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final boundedLimit = _pageLimit(limit);
    final path = Uri(
      path: '/api/v1/sync/events',
      queryParameters: <String, String>{
        'after': after.toString(),
        'limit': '$boundedLimit',
      },
    ).toString();
    final json = await _jsonRequest('GET', path, token: token);
    return _rows(json, 'events', SyncEvent.fromJson, maxRows: boundedLimit);
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
    return _decode(() => json['subscription_id'] as String);
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
    return _decode(() => json['subscription_id'] as String);
  }

  /// Sends the generic wake to this device's own registrations and returns
  /// one result class per registration (card I41).
  Future<List<String>> sendTestPush(String token) async {
    final json = await _jsonRequest('POST', '/api/v1/push/test',
        token: token, body: const <String, Object?>{});
    return _rows(json, 'results', (row) => row['result'])
        .whereType<String>()
        .toList(growable: false);
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
    final boundedLimit = limit.clamp(1, maxSearchPageSize).toInt();
    final queryParameters = <String, String>{
      'q': query,
      'limit': '$boundedLimit',
      'offset': '${offset < 0 ? 0 : offset}',
    };
    final path =
        Uri(path: '/api/v1/search/metadata', queryParameters: queryParameters)
            .toString();
    final json = await _jsonRequest('GET', path, token: token);
    return _rows(json, 'results', MetadataSearchResult.fromJson,
        maxRows: boundedLimit);
  }

  Future<DeviceLink> createDeviceLink(String token) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links',
      token: token,
      body: <String, Object?>{},
    );
    return _model(json['device_link'], DeviceLink.fromJson);
  }

  Future<DeviceLink> deviceLink(String token, String linkId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/device-links/$linkId',
      token: token,
    );
    return _model(json['device_link'], DeviceLink.fromJson);
  }

  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(String code) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/claim-enrollment',
      body: <String, Object?>{'code': code},
    );
    return _model(json, EnrollmentReservation.fromJson);
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
      deviceLink: _model(json['device_link'], DeviceLink.fromJson),
      claimToken: _decode(() => json['claim_token'] as String),
      deviceSecret: _decode(() => json['device_secret'] as String),
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
    return _model(json['device_link'], DeviceLink.fromJson);
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
    return _decode(() => _sessionFromAuthJson(json));
  }

  List<int> _decodeRequiredBytes(Object? value) {
    if (value is! String) {
      throw const ApiResponseException.malformed();
    }
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
    return _readJson(response);
  }

  /// Reads a JSON object response. Errors become an [ApiException] built
  /// from at most [ApiException.maxErrorBodyChars] bytes of the body; a
  /// success body over [_maxJsonResponseBytes], or one that is not UTF-8
  /// JSON object text, is an [ApiResponseException]. No path keeps or
  /// reports the raw body.
  Future<Map<String, Object?>> _readJson(HttpClientResponse response) async {
    if (!_isSuccess(response.statusCode)) {
      throw await _errorFrom(response);
    }
    final bytes = await _readBounded(response, _maxJsonResponseBytes);
    if (bytes == null) throw const ApiResponseException.tooLarge();
    if (bytes.isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Reported below without the offending text.
    }
    throw const ApiResponseException.malformed();
  }

  static bool _isSuccess(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static Future<ApiException> _errorFrom(HttpClientResponse response) async {
    final bytes = await _readBounded(response, ApiException.maxErrorBodyChars);
    return ApiException(
      response.statusCode,
      bytes == null ? '' : utf8.decode(bytes, allowMalformed: true),
    );
  }

  /// Reads the whole body if it fits in [maxBytes], or returns null and
  /// stops reading (closing the connection) once it cannot.
  static Future<Uint8List?> _readBounded(
      HttpClientResponse response, int maxBytes) async {
    if (response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_requestTimeout)) {
      if (builder.length + chunk.length > maxBytes) return null;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Checks the status and announced size before handing out a binary
  /// stream, and enforces both the size limit and an idle timeout while it
  /// is read.
  static Future<Stream<List<int>>> _boundedDownload(
      HttpClientResponse response, int maxBytes) async {
    if (!_isSuccess(response.statusCode)) {
      throw await _errorFrom(response);
    }
    if (response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      throw const ApiResponseException.tooLarge();
    }
    return _limitStream(response, maxBytes);
  }

  static Stream<List<int>> _limitStream(
      Stream<List<int>> source, int maxBytes) async* {
    var received = 0;
    await for (final chunk in source.timeout(_requestTimeout)) {
      received += chunk.length;
      if (received > maxBytes) throw const ApiResponseException.tooLarge();
      yield chunk;
    }
  }

  /// Reads every page of a cursor-paged list. Bounded by [maxListPages];
  /// rows repeated across pages are kept once.
  Future<List<T>> _collectPages<T>({
    required String key,
    required T Function(Map<String, Object?>) fromJson,
    required String Function(T) idOf,
    required String Function(String? cursor) path,
    required String token,
  }) async {
    final result = <T>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < maxListPages; page++) {
      final json = await _jsonRequest('GET', path(cursor), token: token);
      final rows = _rows(json, key, fromJson, maxRows: listPageSize);
      for (final row in rows) {
        if (seen.add(idOf(row))) result.add(row);
      }
      if (rows.length < listPageSize) return result;
      final next = idOf(rows.last);
      if (next == cursor) throw const ApiResponseException.malformed();
      cursor = next;
    }
    return result;
  }

  static int _pageLimit(int limit) => limit.clamp(1, maxPageSize).toInt();
}

/// Builds a model from an API response, turning any type, format or range
/// failure into an [ApiResponseException] so implementation error text
/// never travels further than this layer.
T _decode<T>(T Function() build) {
  try {
    return build();
  } on ApiResponseException {
    rethrow;
  } on FormatException {
    throw const ApiResponseException.malformed();
  } on TypeError {
    throw const ApiResponseException.malformed();
  } on ArgumentError {
    throw const ApiResponseException.malformed();
  } on UnsupportedError {
    throw const ApiResponseException.malformed();
  }
}

T _model<T>(Object? raw, T Function(Map<String, Object?>) fromJson) {
  if (raw is! Map) throw const ApiResponseException.malformed();
  return _decode(() => fromJson(Map<String, Object?>.from(raw)));
}

/// Decodes the list under [key]. An absent or null list is empty; any
/// other non-list, or more than [maxRows] rows, breaks the contract.
List<T> _rows<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) fromJson, {
  int maxRows = ApiClient.maxUnpagedRows,
}) {
  final raw = json[key];
  if (raw == null) return <T>[];
  if (raw is! List || raw.length > maxRows) {
    throw const ApiResponseException.malformed();
  }
  return <T>[for (final row in raw) _model(row, fromJson)];
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
