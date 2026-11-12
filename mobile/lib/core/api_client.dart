import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

import '../crypto/mls_commit_bundle.dart';
import 'account_recovery.dart';
import 'admin_models.dart';
import 'api_errors.dart';
import 'device_link_v3_models.dart';
import 'device_lists.dart' show DeviceListPage;
import 'membership_models.dart';
import 'models.dart';
import 'report_models.dart';
import 'profile_models.dart';
import 'passkeys.dart';
import 'server_origin.dart';
import 'transport_policy.dart';

export 'api_errors.dart';
export 'server_origin.dart';

/// The largest K1 container (crypto/rust/src/history.rs
/// MAX_HISTORY_CIPHERTEXT): the 64 MiB padded snapshot, 20 bytes per 1 MiB
/// chunk and the 416-byte header.
const int k1MaxBackupCiphertextBytes = 64 * 1024 * 1024 + 64 * 20 + 416;

/// [bytes] as 64 KiB views, without copying.
Stream<List<int>> k1UploadSlices(Uint8List bytes) async* {
  const slice = 64 * 1024;
  for (var offset = 0; offset < bytes.length; offset += slice) {
    yield Uint8List.sublistView(
        bytes, offset, min(offset + slice, bytes.length));
  }
}

class ApiClient {
  /// [transport] decides which origins the device-link checks accept. It
  /// defaults to HTTPS only; only the demo entry point passes a policy that
  /// also allows loopback HTTP (D11, D12).
  ///
  /// [transferIdleTimeout] bounds how long a streamed upload or download may
  /// go without moving a chunk (see [defaultTransferIdleTimeout]); tests
  /// shorten it.
  ApiClient({
    required String baseUrl,
    HttpClient? httpClient,
    TransportPolicy transport = TransportPolicy.production,
    Duration transferIdleTimeout = defaultTransferIdleTimeout,
  })  : baseUrl = canonicalizeServerOrigin(baseUrl),
        _transport = transport,
        _httpClient = httpClient ?? HttpClient(),
        _transferIdleTimeout = transferIdleTimeout {
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  final String baseUrl;
  final TransportPolicy _transport;
  final HttpClient _httpClient;
  final Duration _transferIdleTimeout;
  static const _requestTimeout = Duration(seconds: 30);

  /// Streamed bodies (attachments, backups, up to 100 MiB) are bounded by
  /// progress, not by a whole-transfer deadline: a healthy slow link may take
  /// minutes, a stalled one is cut after this long without a chunk.
  static const defaultTransferIdleTimeout = Duration(seconds: 30);
  static const _maxJsonResponseBytes = 2 * 1024 * 1024;

  /// A profile record is 4 KiB or 256 KiB plus 28 bytes of overhead.
  static const maxProfileBlobBytes = 256 * 1024 + 64;

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

  /// L2-3: whether sync reads ask for sealed events (`sealed=1`). Only an
  /// app that can open them sets it: the server keeps them out of every
  /// other read, so an older app is never shown an event it would stop on
  /// (`docs/crypto.md`, "Older apps").
  bool readsSealedEvents = false;

  Map<String, String> get _sealedQuery => readsSealedEvents
      ? const <String, String>{'sealed': '1'}
      : const <String, String>{};

  /// Runs [request] with [limit], halving it while the reply is over
  /// [_maxCiphertextResponseBytes]. A single item that is still too large
  /// rethrows.
  static Future<T> _shrinkingPage<T>(
    int limit,
    Future<T> Function(int limit) request, {
    int maxLimit = _maxServerPageSize,
  }) async {
    var current = limit.clamp(1, maxLimit).toInt();
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

  void _v3Owner(Session owner) {
    _v3Origin();
    deviceLinkV3Id(owner.accountId);
    deviceLinkV3Id(owner.deviceId);
    if (owner.baseUrl != baseUrl) {
      throw const FormatException('device link owner origin mismatch');
    }
  }

  void _v3Origin() {
    if (!_transport.allows(baseUrl)) {
      throw const FormatException(
          'device link requires an origin this build allows');
    }
  }

  DeviceLinkV3Record _v3Link(Map<String, Object?> json,
      {String? id, Session? owner}) {
    return _decode(() {
      final link = DeviceLinkV3Record.fromJson(_object(json, 'device_link'),
          transport: _transport);
      if (link.origin != baseUrl ||
          (id != null && link.id != id) ||
          (owner != null &&
              (link.accountId != owner.accountId ||
                  link.sourceDeviceId != owner.deviceId))) {
        throw const ApiResponseException();
      }
      return link;
    });
  }

  /// [sourceCommitment] is this device's commitment to the random it will
  /// reveal once it accepted the claim (L1-3).
  Future<DeviceLinkV3Record> createDeviceLinkV3(
      Session owner, String locator, List<int> sourceCommitment,
      {int expiresInSeconds = 600}) async {
    _v3Owner(owner);
    deviceLinkV3Hash(locator);
    if (expiresInSeconds < 1 || expiresInSeconds > 1800) {
      throw const FormatException('invalid device link lifetime');
    }
    if (sourceCommitment.length != 32) {
      throw const FormatException('invalid device link commitment');
    }
    final json = await _jsonRequest('POST', '/api/v1/device-links/v3',
        token: owner.token,
        body: {
          'code': locator,
          'server_origin': baseUrl,
          'protocol_version': deviceLinkV3Protocol,
          'source_commitment': base64Encode(sourceCommitment),
          'expires_in_seconds': expiresInSeconds,
        });
    final link = _v3Link(json, owner: owner);
    if (link.fields['code'] != locator ||
        link.fields['source_commitment'] != base64Encode(sourceCommitment)) {
      throw const ApiResponseException();
    }
    return link;
  }

  /// Reveals the source random for the claim in [expected] (L1-3). Call it
  /// only after the native accept of that claim is committed.
  Future<DeviceLinkV3Record> revealDeviceLinkV3(Session owner,
      DeviceLinkV3Record expected, List<int> sourceRandom) async {
    _v3Owner(owner);
    if (expected.origin != baseUrl ||
        expected.accountId != owner.accountId ||
        expected.sourceDeviceId != owner.deviceId ||
        sourceRandom.length != 32) {
      throw const FormatException('device link reveal context mismatch');
    }
    final link = _v3Link(
        await _jsonRequest(
            'POST', '/api/v1/device-links/v3/${expected.id}/reveal',
            token: owner.token,
            body: {
              'protocol_version': deviceLinkV3Protocol,
              'claim_request_hash':
                  deviceLinkV3Hash(expected.fields['claim_request_hash']),
              'source_random': base64Encode(sourceRandom),
            }),
        id: expected.id,
        owner: owner);
    _v3SameClaim(expected, link);
    if (link.fields['source_random'] != base64Encode(sourceRandom)) {
      throw const ApiResponseException();
    }
    return link;
  }

  Future<DeviceLinkV3Reservation> reserveDeviceLinkV3(
      String locator, String requestId) async {
    _v3Origin();
    deviceLinkV3Hash(locator);
    deviceLinkV3Hash(requestId);
    final json = await _jsonRequest(
        'POST', '/api/v1/device-links/v3/claim-enrollment',
        body: {
          'code': locator,
          'protocol_version': deviceLinkV3Protocol,
          'reservation_request_id': requestId,
        });
    return _decode(() => DeviceLinkV3Reservation.fromJson(json));
  }

  Future<DeviceLinkV3Record> submitDeviceLinkV3Claim(
      FrozenDeviceLinkV3Claim claim,
      DeviceLinkV3Reservation reservation) async {
    _v3Origin();
    if (claim.fields['server_origin'] != baseUrl ||
        claim.fields['enrollment_reservation_id'] != reservation.fields['id']) {
      throw const FormatException('device link claim origin mismatch');
    }
    final link = _v3Link(
        await _jsonRequest('POST', '/api/v1/device-links/v3/claim',
            body: claim.fields),
        id: claim.fields['enrollment_reservation_id'] as String);
    for (final (returned, reserved) in [
      ('account_id', 'account_id'),
      ('claimed_device_id', 'device_id'),
      ('created_by_device_id', 'existing_device_id'),
      ('existing_signing_key', 'existing_signing_key'),
      ('source_commitment', 'source_commitment'),
      ('link_nonce', 'link_nonce'),
      ('expires_at', 'expires_at'),
    ]) {
      if (link.fields[returned] != reservation.fields[reserved]) {
        throw const ApiResponseException();
      }
    }
    for (final (returned, sent) in [
      ('claimed_device_name', 'device_name'),
      ('claimed_signing_key', 'signing_key'),
      ('transfer_public_key', 'transfer_public_key'),
      ('recipient_random', 'recipient_random'),
      ('transcript_hash', 'transcript_hash'),
      ('claim_tag', 'claim_tag'),
    ]) {
      if (link.fields[returned] != claim.fields[sent]) {
        throw const ApiResponseException();
      }
    }
    if (link.fields['claim_request_hash'] != claim.requestHash) {
      throw const ApiResponseException();
    }
    return link;
  }

  Future<DeviceLinkV3Record> deviceLinkV3(Session owner, String id) async {
    _v3Owner(owner);
    deviceLinkV3Id(id);
    return _v3Link(
        await _jsonRequest('GET', '/api/v1/device-links/v3/$id',
            token: owner.token),
        id: id,
        owner: owner);
  }

  /// Polling is deliberately read-only and never yields a Session.
  Future<DeviceLinkV3Record> deviceLinkV3ClaimStatus(
      DeviceLinkV3Record expected, String claimToken) async {
    _v3Origin();
    if (expected.origin != baseUrl) {
      throw const FormatException('device link status origin mismatch');
    }
    deviceLinkV3ClaimToken(claimToken);
    final link = _v3Link(
        await _jsonRequest(
            'GET', '/api/v1/device-links/v3/${expected.id}/claim-status',
            extraHeaders: {'X-Veritra-Claim-Token': claimToken}),
        id: expected.id);
    _v3SameClaim(expected, link);
    return link;
  }

  void _v3SameClaim(DeviceLinkV3Record expected, DeviceLinkV3Record actual) {
    for (final key in [
      'id',
      'account_id',
      'created_by_device_id',
      'server_origin',
      'link_nonce',
      'existing_signing_key',
      'source_commitment',
      'recipient_random',
      'claimed_device_id',
      'claimed_device_name',
      'claimed_signing_key',
      'transfer_public_key',
      'transcript_hash',
      'claim_tag',
      'claim_request_hash',
      'created_at',
      'expires_at',
      'claimed_at'
    ]) {
      if (expected.fields[key] != actual.fields[key]) {
        throw const ApiResponseException();
      }
    }
    const rank = {'pending': 0, 'claimed': 1, 'approved': 2, 'consumed': 3};
    if ((rank[actual.state] ?? -1) < (rank[expected.state] ?? 0)) {
      throw const ApiResponseException();
    }
    for (final key in [
      'source_random',
      'revealed_at',
      'approved_at',
      'transfer_expires_at',
      'approval_tag',
      'completed_at'
    ]) {
      if (expected.fields.containsKey(key) &&
          expected.fields[key] != actual.fields[key]) {
        throw const ApiResponseException();
      }
    }
  }

  Future<DeviceLinkV3Record> approveDeviceLinkV3(
      Session owner, DeviceLinkV3Record expected, List<int> approvalTag,
      {List<int>? deviceList}) async {
    _v3Owner(owner);
    if (expected.origin != baseUrl ||
        expected.accountId != owner.accountId ||
        expected.sourceDeviceId != owner.deviceId ||
        approvalTag.length != 32) {
      throw const FormatException('device link approval context mismatch');
    }
    final link = _v3Link(
        await _jsonRequest(
            'POST', '/api/v1/device-links/v3/${expected.id}/approve',
            token: owner.token,
            body: {
              'protocol_version': deviceLinkV3Protocol,
              'claim_request_hash':
                  deviceLinkV3Hash(expected.fields['claim_request_hash']),
              'transcript_hash':
                  base64Encode(expected.bytes('transcript_hash')),
              'approval_tag': base64Encode(approvalTag),
              if (deviceList != null) 'device_list': base64Encode(deviceList),
            }),
        id: expected.id,
        owner: owner);
    _v3SameClaim(expected, link);
    if (!const {'approved', 'consumed'}.contains(link.state) ||
        link.fields['approval_tag'] != base64Encode(approvalTag)) {
      throw const ApiResponseException();
    }
    return link;
  }

  Future<DeviceLinkV3Completion> completeDeviceLinkV3(
      DeviceLinkV3Record expected,
      String claimToken,
      String initialSessionTokenHash) async {
    _v3Origin();
    deviceLinkV3ClaimToken(claimToken);
    deviceLinkV3Hash(initialSessionTokenHash);
    if (expected.origin != baseUrl || expected.recipientDeviceId == null) {
      throw const FormatException('device link completion context mismatch');
    }
    final json = await _jsonRequest(
        'POST', '/api/v1/device-links/v3/${expected.id}/complete',
        extraHeaders: {
          'X-Veritra-Claim-Token': claimToken
        },
        body: {
          'protocol_version': deviceLinkV3Protocol,
          'claim_request_hash':
              deviceLinkV3Hash(expected.fields['claim_request_hash']),
          'transcript_hash': base64Encode(expected.bytes('transcript_hash')),
          'initial_session_token_hash': initialSessionTokenHash,
        });
    return _decode(() {
      final receipt =
          DeviceLinkV3Completion.fromJson(json, transport: _transport);
      final fields = receipt.fields;
      if (fields['link_id'] != expected.id ||
          fields['account_id'] != expected.accountId ||
          fields['device_id'] != expected.recipientDeviceId ||
          fields['server_origin'] != baseUrl ||
          fields['claim_request_hash'] !=
              expected.fields['claim_request_hash'] ||
          fields['transcript_hash'] != expected.fields['transcript_hash'] ||
          fields['initial_session_token_hash'] != initialSessionTokenHash ||
          (expected.fields.containsKey('completed_at') &&
              fields['completed_at'] != expected.fields['completed_at']) ||
          (expected.fields.containsKey('approval_tag') &&
              base64Encode(receipt.approvalTag) !=
                  expected.fields['approval_tag'])) {
        throw const ApiResponseException();
      }
      return receipt;
    });
  }

  Future<void> cancelDeviceLinkV3(Session owner, String id) async {
    _v3Owner(owner);
    deviceLinkV3Id(id);
    await _jsonRequest('DELETE', '/api/v1/device-links/v3/$id',
        token: owner.token);
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
    List<int>? deviceList,
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
        if (deviceList != null) 'device_list': base64Encode(deviceList),
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
    List<int>? deviceList,
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
        if (deviceList != null) 'device_list': base64Encode(deviceList),
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

  // ---------------------------------------------------------- passkeys (B7)

  /// Begins a passkey sign-in. The device ID and secret are checked by the
  /// server exactly as `login` checks them; no username is sent.
  Future<PasskeyCeremony> passkeyLoginOptions({
    required String deviceId,
    required String deviceSecret,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/auth/passkey/options',
      body: <String, Object?>{
        'device_id': deviceId,
        'device_secret': deviceSecret,
      },
    );
    return _ceremony(json);
  }

  /// Finishes a passkey sign-in. The answer has the shape of `login`'s and
  /// grants no recent authentication.
  Future<Session> passkeyLogin({
    required String ceremonyId,
    required String deviceId,
    required String deviceSecret,
    required Map<String, Object?> credential,
    String? fallbackUsername,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/auth/passkey',
      body: <String, Object?>{
        'ceremony_id': ceremonyId,
        'device_id': deviceId,
        'device_secret': deviceSecret,
        'credential': credential,
      },
    );
    return _sessionFromAuthJson(
      json,
      fallbackUsername: fallbackUsername,
      fallbackDeviceSecret: deviceSecret,
    );
  }

  Future<List<PasskeyRecord>> passkeys(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/account/passkeys', token: token);
    final raw = json['passkeys'];
    if (raw == null) return const <PasskeyRecord>[];
    if (raw is! List || raw.length > 64) throw const ApiResponseException();
    return <PasskeyRecord>[
      for (final row in raw)
        PasskeyRecord.tryParse(row) ?? (throw const ApiResponseException()),
    ];
  }

  /// Needs a recent password check on the session.
  Future<PasskeyCeremony> passkeyRegisterOptions(String token) async {
    final json = await _jsonRequest('POST', '/api/v1/account/passkeys/options',
        token: token);
    return _ceremony(json);
  }

  /// Returns the new passkey's row ID.
  Future<String> passkeyRegister(
    String token, {
    required String ceremonyId,
    required String name,
    required Map<String, Object?> credential,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/account/passkeys',
      token: token,
      body: <String, Object?>{
        'ceremony_id': ceremonyId,
        'name': name,
        'credential': credential,
      },
    );
    final id = json['id'];
    if (id is! String || id.isEmpty) throw const ApiResponseException();
    return id;
  }

  Future<void> renamePasskey(String token, String id, String name) async {
    await _jsonRequest(
        'PATCH', '/api/v1/account/passkeys/${Uri.encodeComponent(id)}',
        token: token, body: <String, Object?>{'name': name});
  }

  /// Needs a recent password check on the session.
  Future<void> deletePasskey(String token, String id) async {
    await _jsonRequest(
        'DELETE', '/api/v1/account/passkeys/${Uri.encodeComponent(id)}',
        token: token);
  }

  PasskeyCeremony _ceremony(Map<String, Object?> json) {
    final id = json['ceremony_id'];
    if (id is! String || id.isEmpty || id.length > 256) {
      throw const ApiResponseException();
    }
    return PasskeyCeremony(id: id, publicKey: _object(json, 'public_key'));
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

  // K0 recovery enrollment (docs/designs/K0-recovery-enrollment.md).

  /// `GET /api/v1/account/recovery-key`.
  Future<RecoveryKeyStatus> recoveryKeyStatus(String token) async {
    final json =
        await _jsonRequest('GET', '/api/v1/account/recovery-key', token: token);
    return _decode(() => RecoveryKeyStatus.fromJson(json));
  }

  /// Sets or replaces the account's recovery key (needs recent auth). Only
  /// the verification key and id leave the device, never the key.
  Future<RecoveryKeyStatus> putRecoveryKey(
    String token, {
    required List<int> rkAuthPub,
    required List<int> rkId,
    List<int>? deviceList,
  }) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/account/recovery-key',
      token: token,
      body: <String, Object?>{
        'rk_auth_pub': base64Encode(rkAuthPub),
        'rk_id': base64Encode(rkId),
        if (deviceList != null) 'device_list': base64Encode(deviceList),
      },
    );
    return _decode(() => RecoveryKeyStatus.fromJson(json));
  }

  /// Reserves a recovery enrollment for [username]: the only recovery route
  /// that takes one. An unknown account gets a decoy reservation.
  Future<EnrollmentReservation> reserveAccountRecovery(String username) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/account-recovery/enrollment',
      body: <String, Object?>{'username': username},
    );
    return _decode(() => EnrollmentReservation.fromJson(json));
  }

  /// Claims [enrollment] with the password and the recovery proof. The
  /// account is always the reservation's; the body names no username.
  Future<AccountRecoveryClaim> claimAccountRecovery({
    required EnrollmentReservation enrollment,
    required String password,
    required String deviceName,
    required EnrollmentCredential credential,
    required List<int> recoverySignature,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/account-recovery/claim',
      body: <String, Object?>{
        'enrollment_reservation_id': enrollment.id,
        'password': password,
        'device_name': deviceName,
        'device_key_package': base64Encode(credential.deviceKeyPackage),
        'signing_key': base64Encode(credential.signingKey),
        'challenge_signature': base64Encode(credential.challengeSignature),
        'recovery_signature': base64Encode(recoverySignature),
      },
    );
    return _decode(() => AccountRecoveryClaim.fromJson(json));
  }

  /// Polls a recovery request with its claim token. The call after
  /// `ready_at` completes it; only that call carries the session token.
  Future<AccountRecoveryStatus> accountRecoveryStatus(
      String requestId, String claimToken) async {
    final (status, json) = await _jsonRequestWithStatus(
      'GET',
      '/api/v1/account-recovery/${Uri.encodeComponent(requestId)}/status',
      extraHeaders: <String, String>{'X-Veritra-Claim-Token': claimToken},
    );
    return _decode(() {
      final state = json['state'];
      if (status == 202 && state == 'waiting') {
        return AccountRecoveryStatus(
          phase: AccountRecoveryPhase.waiting,
          readyAt: DateTime.parse(json['ready_at'] as String).toUtc(),
        );
      }
      if (status != 200 || state != 'completed') {
        throw const ApiResponseException();
      }
      final token = json['token'];
      if (token != null && (token is! String || token.isEmpty)) {
        throw const ApiResponseException();
      }
      final accountId = _nestedId(json['account']);
      final deviceId = _nestedId(json['device']);
      if (accountId == null || deviceId == null) {
        throw const ApiResponseException();
      }
      return AccountRecoveryStatus(
        phase: token == null
            ? AccountRecoveryPhase.completedWithoutToken
            : AccountRecoveryPhase.completed,
        accountId: accountId,
        deviceId: deviceId,
        username: _nestedField(json['account'], 'username'),
        role: _nestedField(json['account'], 'role'),
        token: token as String?,
      );
    });
  }

  /// Cancels a waiting recovery request of this account (needs recent
  /// auth).
  Future<void> cancelAccountRecovery(String token, String requestId) async {
    await _jsonRequest(
      'POST',
      '/api/v1/account-recovery/${Uri.encodeComponent(requestId)}/cancel',
      token: token,
    );
  }

  Future<void> revokeDevice(String token, String deviceId,
      {List<int>? deviceList}) async {
    await _jsonRequest('DELETE', '/api/v1/devices/$deviceId',
        token: token,
        body: deviceList == null
            ? null
            : <String, Object?>{'device_list': base64Encode(deviceList)});
  }

  /// One page of [accountId]'s approved-device list after version [after]
  /// (L1). Null when the server answers 404: an unknown account, or one
  /// this account shares no conversation with (the same answer for both).
  Future<DeviceListPage?> fetchDeviceList(String token, String accountId,
      {required int after}) async {
    try {
      final json = await _jsonRequest(
          'GET',
          '/api/v1/accounts/${Uri.encodeComponent(accountId)}/device-list'
              '?after=$after',
          token: token);
      return _decode(() => DeviceListPage.fromJson(json));
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// `POST /api/v1/account/device-list`: a migration genesis, a repair
  /// removal or a recovery version. Returns the version stored.
  Future<int> publishDeviceList(String token, List<int> statement) async {
    final json = await _jsonRequest('POST', '/api/v1/account/device-list',
        token: token,
        body: <String, Object?>{'device_list': base64Encode(statement)});
    final version = json['version'];
    if (version is! int) throw const ApiResponseException();
    return version;
  }

  /// Returns one bounded page of the versioned account export. The server
  /// requires recent authentication and keeps message bodies as ciphertext.
  Future<Map<String, Object?>> exportAccountPage(
    String token, {
    int limit = 250,
    String? before,
  }) async {
    // Rows keep their message ciphertext, so a page can pass the JSON cap;
    // it is then re-requested smaller. The export has its own 1..5000 limit
    // range, and the caller follows `next_before`, not the page length.
    return _shrinkingPage(limit, maxLimit: 5000, (pageLimit) {
      final path = '/api/v1/account/export?limit=$pageLimit'
          '${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}';
      return _jsonRequest(
        'GET',
        path,
        token: token,
        maxResponseBytes: _maxCiphertextResponseBytes,
      );
    });
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
    final (status, json) = await _jsonRequestWithStatus(
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
    final conversation = _decode(() => Conversation.fromJson(json));
    // 200 instead of 201: a DM the pair already had (D67).
    if (status != HttpStatus.ok) return conversation;
    return Conversation(
      id: conversation.id,
      kind: conversation.kind,
      title: conversation.title,
      communityId: conversation.communityId,
      channelId: conversation.channelId,
      retentionSeconds: conversation.retentionSeconds,
      createdAt: conversation.createdAt,
      lastMessageAt: conversation.lastMessageAt,
      unreadCount: conversation.unreadCount,
      currentRole: conversation.currentRole,
      peerAccountId: conversation.peerAccountId,
      peerUsername: conversation.peerUsername,
      createdBy: conversation.createdBy,
      postingRestricted: conversation.postingRestricted,
      existedOnServer: true,
    );
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

  /// The audit log, newest first. [before] continues below an event id (the
  /// previous page's cursor).
  Future<AdminPage<AdminAuditEvent>> listAdminAuditEvents(
    String token, {
    String? before,
    int limit = 50,
  }) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/admin/audit-events',
        queryParameters: <String, String>{
          'limit': '$limit',
          'order': 'desc',
          if (before != null && before.isNotEmpty) 'before': before,
        },
      ).toString(),
      token: token,
    );
    return AdminPage<AdminAuditEvent>(
      _rows(json, 'events', AdminAuditEvent.fromJson),
      json['next_before']?.toString(),
    );
  }

  // C6 reports. The server routes sealed copies and learns nothing about the
  // reported message; the envelope id travels only inside the sealed body and,
  // at review time, to the recipient's envelope-record request (D95).

  /// Where a report about a message of [conversationId] goes, and the keys to
  /// seal one copy to each recipient. Members only.
  Future<ReportInbox> getReportInbox(
      String token, String conversationId) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/reports/inbox',
        queryParameters: <String, String>{'conversation_id': conversationId},
      ).toString(),
      token: token,
    );
    return _decode(() => ReportInbox.fromJson(json));
  }

  /// Publishes the calling instance owner's report public key. Needs a recent
  /// reauthentication. Returns the stored key revision.
  Future<int> putInstanceReportKey(String token, List<int> publicKey) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/reports/inbox-keys/instance',
      token: token,
      body: <String, Object?>{'public_key': base64Encode(publicKey)},
    );
    return _decode(() {
      final rev = json['key_rev'];
      if (rev is! int || rev < 1) throw const FormatException('invalid rev');
      return rev;
    });
  }

  /// C6: publishes the caller's report public key as a moderator inbox of
  /// [communityId] (one sealed copy per moderator). Needs a recent sign-in.
  Future<int> putModeratorReportKey(
      String token, String communityId, List<int> publicKey) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/reports/inbox-keys/community/${Uri.encodeComponent(communityId)}',
      token: token,
      body: <String, Object?>{'public_key': base64Encode(publicKey)},
    );
    return _decode(() {
      final rev = json['key_rev'];
      if (rev is! int || rev < 1) throw const FormatException('invalid rev');
      return rev;
    });
  }

  /// The caller's own moderator report key for [communityId], or null.
  Future<ReportInboxRecipient?> getOwnModeratorReportKey(
      String token, String communityId) async {
    final Map<String, Object?> json;
    try {
      json = await _jsonRequest('GET',
          '/api/v1/reports/inbox-keys/community/${Uri.encodeComponent(communityId)}',
          token: token);
    } on ApiException catch (err) {
      if (err.statusCode == 404) return null;
      rethrow;
    }
    return _decode(() => ReportInboxRecipient.fromJson(json));
  }

  /// The caller's own report copies in [communityId]'s moderator inbox.
  Future<List<ReportCopyRow>> listModeratorReports(
      String token, String communityId,
      {String? afterId, int limit = 50}) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/reports',
        queryParameters: <String, String>{
          'inbox': 'community',
          'community_id': communityId,
          'limit': '$limit',
          if (afterId != null && afterId.isNotEmpty) 'after_id': afterId,
        },
      ).toString(),
      token: token,
      maxResponseBytes: _maxCiphertextResponseBytes,
    );
    return _rows(json, 'reports', ReportCopyRow.fromJson);
  }

  /// The calling owner's own current report key as the server holds it, or
  /// null when none was published.
  Future<ReportInboxRecipient?> getOwnReportKey(String token) async {
    final Map<String, Object?> json;
    try {
      json = await _jsonRequest('GET', '/api/v1/reports/inbox-keys/instance',
          token: token);
    } on ApiException catch (err) {
      if (err.statusCode == 404) return null;
      rethrow;
    }
    return _decode(() => ReportInboxRecipient.fromJson(json));
  }

  /// Files one report: a copy sealed to each recipient of the inbox.
  Future<void> createReport(
    String token, {
    required String conversationId,
    required String reportId,
    required List<Map<String, Object?>> copies,
  }) async {
    await _jsonRequest(
      'POST',
      '/api/v1/reports',
      token: token,
      body: <String, Object?>{
        'conversation_id': conversationId,
        'report_id': reportId,
        'copies': copies,
      },
    );
  }

  /// The caller's own instance-owner inbox, oldest first, after [afterId].
  Future<List<ReportCopyRow>> listOwnerReports(String token,
      {String? afterId, int limit = 50}) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/reports',
        queryParameters: <String, String>{
          'inbox': 'instance_owner',
          'limit': '$limit',
          if (afterId != null && afterId.isNotEmpty) 'after_id': afterId,
        },
      ).toString(),
      token: token,
      maxResponseBytes: _maxCiphertextResponseBytes,
    );
    return _rows(json, 'reports', ReportCopyRow.fromJson);
  }

  /// Dismisses the caller's copy of a report.
  Future<void> deleteReport(String token, String reportRowId) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/reports/${Uri.encodeComponent(reportRowId)}',
      token: token,
    );
  }

  /// What the server recorded for [envelopeId], a message of the conversation
  /// report copy [reportRowId] was filed about. The one moment the server
  /// learns an envelope id, from the recipient, at review time.
  Future<ReportEnvelopeRecord> getReportEnvelope(
      String token, String reportRowId, String envelopeId) async {
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/reports/${Uri.encodeComponent(reportRowId)}/envelope',
        queryParameters: <String, String>{'envelope_id': envelopeId},
      ).toString(),
      token: token,
    );
    return _decode(() => ReportEnvelopeRecord.fromJson(json));
  }

  // C3 community info records (docs/designs/C3-private-channels-and-info.md).
  // The body is the sealed `VPE1` blob; the server never sees a name.

  static String _infoPath(String kind, String subjectId, String? communityId) {
    final id = Uri.encodeComponent(subjectId);
    return switch (kind) {
      'community' => '/api/v1/communities/$id/info',
      'category' =>
        '/api/v1/communities/${Uri.encodeComponent(communityId ?? '')}/categories/$id',
      'channel' => '/api/v1/channels/$id/info',
      _ => throw ArgumentError.value(kind, 'kind'),
    };
  }

  /// Uploads an info record. [expectedVersion] 0 is the first write
  /// (`If-None-Match: *`). Returns the stored version; a 412 is an
  /// [ApiException] with `version_conflict`.
  Future<int> putInfoRecord(
    String token, {
    required String kind,
    required String subjectId,
    String? communityId,
    required String keyId,
    required List<int> blob,
    required int expectedVersion,
  }) async {
    final uri =
        Uri.parse(baseUrl).resolve(_infoPath(kind, subjectId, communityId));
    final request = await _openRequest('PUT', uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
      ..set('X-Private-Messenger-Encrypted', '1')
      ..set('X-Profile-Key-Id', keyId);
    if (expectedVersion == 0) {
      request.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
    } else {
      request.headers.set(HttpHeaders.ifMatchHeader, '"$expectedVersion"');
    }
    request.add(blob);
    final response = await request.close().timeout(_requestTimeout);
    final json = await _readJsonResponse(response);
    final version = json['version'];
    if (version is! int || version < 1) throw const ApiResponseException();
    return version;
  }

  /// Fetches an info record, or null when the server has none this account
  /// may read (404). The blob is at most the large bucket.
  Future<({int version, String keyId, Uint8List blob})?> getInfoRecord(
    String token, {
    required String kind,
    required String subjectId,
    String? communityId,
  }) async {
    final uri =
        Uri.parse(baseUrl).resolve(_infoPath(kind, subjectId, communityId));
    final request = await _openRequest('GET', uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode == HttpStatus.notFound) {
      await _discard(response);
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    final version = int.tryParse(
        (response.headers.value(HttpHeaders.etagHeader) ?? '')
            .replaceAll('"', ''));
    final keyId = response.headers.value('X-Profile-Key-Id') ?? '';
    final blob = await _readBounded(response, 256 * 1024 + 28);
    if (version == null || version < 1 || keyId.length != 32) {
      throw const ApiResponseException();
    }
    return (version: version, keyId: keyId, blob: blob);
  }

  /// Versions of the info records this account may read, per kind. Missing
  /// or unreadable subjects are left out.
  Future<List<({String kind, String id, int version, String keyId})>>
      infoVersions(
    String token, {
    List<String> communityIds = const <String>[],
    List<String> categoryIds = const <String>[],
    List<String> channelIds = const <String>[],
  }) async {
    // Each server list is bounded to 200 IDs; a community may have 500
    // channels. Fetch every batch rather than silently omitting the tail.
    if (communityIds.length > 200 ||
        categoryIds.length > 200 ||
        channelIds.length > 200) {
      final versions =
          <({String kind, String id, int version, String keyId})>[];
      for (var offset = 0;
          offset < communityIds.length ||
              offset < categoryIds.length ||
              offset < channelIds.length;
          offset += 200) {
        versions.addAll(await infoVersions(token,
            communityIds: communityIds.skip(offset).take(200).toList(),
            categoryIds: categoryIds.skip(offset).take(200).toList(),
            channelIds: channelIds.skip(offset).take(200).toList()));
      }
      return versions;
    }
    final json = await _jsonRequest('POST', '/api/v1/profiles/versions',
        token: token,
        body: <String, Object?>{
          'community_ids': communityIds,
          'category_ids': categoryIds,
          'channel_ids': channelIds,
        });
    final raw = json['versions'];
    if (raw is! List) throw const ApiResponseException();
    return _decode(() => [
          for (final item in raw)
            if (item is Map &&
                item['kind'] is String &&
                item['id'] is String &&
                item['version'] is int &&
                item['key_id'] is String)
              (
                kind: item['kind'] as String,
                id: item['id'] as String,
                version: item['version'] as int,
                keyId: item['key_id'] as String,
              ),
        ]);
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

  /// [name] never leaves the device: the server keeps IDs only and refuses a
  /// plaintext name (C3). It goes into the encrypted community record.
  Future<Community> createCommunity(String token, String name) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/communities',
      token: token,
      body: const <String, Object?>{},
    );
    return _decode(() => Community.fromJson(json));
  }

  /// As [createCommunity]: [name] is never sent; it goes into the encrypted
  /// channel record.
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
      body: <String, Object?>{'kind': kind},
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

  // C1: membership invitations, join requests and community membership.
  // An invitation's secret never reaches these calls: they carry only the
  // locator derived from it (`MembershipInviteLink.locator`), in a body.

  static String _targetPath(InviteTargetKind kind, String id) {
    final segment = Uri.encodeComponent(id);
    return kind == InviteTargetKind.community
        ? '/api/v1/communities/$segment'
        : '/api/v1/conversations/$segment';
  }

  /// The roster of a community, with usernames, for its members.
  Future<List<ConversationMember>> communityMembers(
    String token,
    String communityId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '${_targetPath(InviteTargetKind.community, communityId)}/members',
      token: token,
    );
    return _rows(json, 'members', ConversationMember.fromJson);
  }

  /// Sets [accountId]'s server-side role in a community (the server's own
  /// route checks follow it; apps read roles from the verified record, C4).
  Future<void> setCommunityMemberRole(
    String token,
    String communityId,
    String accountId,
    String role,
  ) async {
    await _jsonRequest(
      'POST',
      '${_targetPath(InviteTargetKind.community, communityId)}/members',
      token: token,
      body: <String, Object?>{'account_id': accountId, 'role': role},
    );
  }

  /// C4 server succession: asks the server to make [candidateAccountId] the
  /// owner of a group ([communityId] null) or of a community, after this
  /// app's verified role record shows a won election. The server moves its
  /// row only by its own rule (the owner quiet for 37 days and a majority of
  /// admins asking); apps never read that row for roles. Returns the
  /// server's `status`: `moved` or `recorded`.
  Future<String> requestOwnerSuccession(
    String token, {
    String? conversationId,
    String? communityId,
    required String candidateAccountId,
  }) async {
    if ((conversationId == null) == (communityId == null)) {
      throw ArgumentError('exactly one of conversationId and communityId');
    }
    final path = communityId != null
        ? _moderationPath(communityId, 'owner-succession')
        : '/api/v1/conversations/${Uri.encodeComponent(conversationId!)}/owner-succession';
    final json = await _jsonRequest(
      'POST',
      path,
      token: token,
      body: <String, Object?>{'candidate_account_id': candidateAccountId},
    );
    final status = json['status'];
    return status is String ? status : '';
  }

  /// Leaves a community when [accountId] is `me`, or removes a member. The
  /// server drops access to every channel at once; MLS removal follows
  /// through each channel's reconcile and is not implied by the response.
  Future<CommunityRemoval> removeCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    final json = await _jsonRequest(
      'DELETE',
      '${_targetPath(InviteTargetKind.community, communityId)}'
          '/members/${Uri.encodeComponent(accountId)}',
      token: token,
    );
    return _decode(() => CommunityRemoval.fromJson(json));
  }

  String _moderationPath(String communityId, String rest) =>
      '${_targetPath(InviteTargetKind.community, communityId)}/$rest';

  /// Removes a member the actor outranks and records a kick (C5).
  Future<CommunityRemoval> kickCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    final json = await _jsonRequest(
      'POST',
      _moderationPath(
        communityId,
        'members/${Uri.encodeComponent(accountId)}/kick',
      ),
      token: token,
    );
    return _decode(() => CommunityRemoval.fromJson(json));
  }

  /// Removes the member, if it is one, and bans the account (C5).
  Future<CommunityRemoval> banCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    final json = await _jsonRequest(
      'POST',
      _moderationPath(communityId, 'bans'),
      token: token,
      body: <String, Object?>{'account_id': accountId},
    );
    return _decode(() => CommunityRemoval.fromJson(json));
  }

  Future<void> unbanCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    await _jsonRequest(
      'DELETE',
      _moderationPath(communityId, 'bans/${Uri.encodeComponent(accountId)}'),
      token: token,
    );
  }

  Future<List<CommunityBan>> communityBans(
    String token,
    String communityId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      _moderationPath(communityId, 'bans'),
      token: token,
    );
    return _rows(json, 'bans', CommunityBan.fromJson);
  }

  /// Mutes a member for [seconds]; 0 lifts the timeout. Returns the
  /// server's `timeout_until` (null when lifted or not reported), which C5
  /// copies into the verified record.
  Future<DateTime?> setMemberTimeout(
    String token,
    String communityId,
    String accountId,
    int seconds,
  ) async {
    final json = await _jsonRequest(
      'PUT',
      _moderationPath(
        communityId,
        'members/${Uri.encodeComponent(accountId)}/timeout',
      ),
      token: token,
      body: <String, Object?>{'seconds': seconds},
    );
    final until = json['timeout_until'];
    return until is String ? DateTime.tryParse(until)?.toUtc() : null;
  }

  /// Sets a channel's gap between a member's posts; 0 turns it off.
  Future<void> setChannelSlowMode(
    String token,
    String communityId,
    String channelId,
    int seconds,
  ) async {
    await _jsonRequest(
      'PUT',
      _moderationPath(
        communityId,
        'channels/${Uri.encodeComponent(channelId)}/slow-mode',
      ),
      token: token,
      body: <String, Object?>{'seconds': seconds},
    );
  }

  /// Pauses the community's invitations for [seconds]; 0 resumes them.
  Future<void> setInvitesPaused(
    String token,
    String communityId,
    int seconds,
  ) async {
    await _jsonRequest(
      'PUT',
      _moderationPath(communityId, 'invites-pause'),
      token: token,
      body: <String, Object?>{'seconds': seconds},
    );
  }

  Future<ModerationState> moderationState(
    String token,
    String communityId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      _moderationPath(communityId, 'moderation-state'),
      token: token,
    );
    return _decode(() => ModerationState.fromJson(json));
  }

  Future<List<ModerationEvent>> moderationEvents(
    String token,
    String communityId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      _moderationPath(communityId, 'moderation-events'),
      token: token,
    );
    return _rows(json, 'events', ModerationEvent.fromJson);
  }

  Future<MembershipInvite> createMembershipInvite(
    String token,
    InviteTargetKind kind,
    String targetId, {
    required String locator,
    required List<int> signingKey,
    required String bindingTag,
    required List<int> bindingSignature,
    int maxUses = 10,
    Duration lifetime = const Duration(days: 7),
  }) async {
    final json = await _jsonRequest(
      'POST',
      '${_targetPath(kind, targetId)}/invites',
      token: token,
      body: <String, Object?>{
        'locator': locator,
        'signing_key': base64.encode(signingKey),
        'binding_tag': bindingTag,
        'binding_signature': base64.encode(bindingSignature),
        'max_uses': maxUses,
        'expires_in_seconds': lifetime.inSeconds,
      },
    );
    return _decode(() => MembershipInvite.fromJson(json));
  }

  Future<List<MembershipInvite>> listMembershipInvites(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '${_targetPath(kind, targetId)}/invites',
      token: token,
    );
    return _rows(json, 'invites', MembershipInvite.fromJson);
  }

  Future<void> revokeMembershipInvite(String token, String inviteId) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/membership-invites/${Uri.encodeComponent(inviteId)}',
      token: token,
    );
  }

  /// What a link leads to. A link that is unknown, revoked, expired or used
  /// up is a 404, whichever it is.
  Future<InvitePreview> previewMembershipInvite(
    String token,
    String locator,
  ) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/membership-invites/preview',
      token: token,
      body: <String, Object?>{'locator': locator},
    );
    return _decode(() => InvitePreview.fromJson(json));
  }

  /// Asks to join. Nothing is granted until an admin approves.
  Future<JoinRequest> requestToJoin(String token, String locator) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/membership-invites/requests',
      token: token,
      body: <String, Object?>{'locator': locator},
    );
    return _decode(() => JoinRequest.fromJson(json));
  }

  /// Pending requests for a group or community, for its owners and admins.
  Future<List<JoinRequest>> listJoinRequests(
    String token,
    InviteTargetKind kind,
    String targetId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '${_targetPath(kind, targetId)}/join-requests',
      token: token,
    );
    return _rows(json, 'requests', JoinRequest.fromJson);
  }

  /// The signed-in account's own recent requests.
  Future<List<JoinRequest>> listOwnJoinRequests(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/join-requests',
      token: token,
    );
    return _rows(json, 'requests', JoinRequest.fromJson);
  }

  Future<JoinRequest> decideJoinRequest(
    String token,
    String requestId, {
    required bool approve,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/join-requests/${Uri.encodeComponent(requestId)}'
          '/${approve ? 'approve' : 'reject'}',
      token: token,
    );
    return _decode(() => JoinRequest.fromJson(_object(json, 'request')));
  }

  Future<void> cancelJoinRequest(String token, String requestId) async {
    await _jsonRequest(
      'DELETE',
      '/api/v1/join-requests/${Uri.encodeComponent(requestId)}',
      token: token,
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

  Future<Conversation> setPostingPolicy(
    String token,
    String conversationId,
    String policy,
  ) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/conversations/$conversationId/posting-policy',
      token: token,
      body: <String, Object?>{'policy': policy},
    );
    return _decode(() => Conversation.fromJson(json));
  }

  Future<void> deleteAccount(String token) async {
    await _jsonRequest('DELETE', '/api/v1/account', token: token);
  }

  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    // L2-3: a message chosen to go sealed is only ever posted sealed
    // (SealedPostClient); posting it here would tie it to this session.
    if (envelope.sealed) {
      throw StateError('a sealed envelope never goes on the session route');
    }
    await _jsonRequest(
      'POST',
      '/api/v1/messages/envelopes',
      token: token,
      body: envelope.toJson(),
    );
  }

  /// C7: the bodies sync withheld from this device in [conversationId]'s
  /// stream ([channelId], or the group-level stream when null), newest
  /// first, before the message [beforeId]. Each row is
  /// `{message_id, sender_device_id, action_id, channel_id?, created_at,
  /// epoch?, body}` with `body` base64. 404 while the server has C7 off.
  Future<List<Map<String, Object?>>> historyBodies(
    String token,
    String conversationId, {
    String? channelId,
    String? beforeId,
    int limit = 50,
  }) async {
    final query = <String, String>{
      if (channelId != null) 'channel_id': channelId,
      if (beforeId != null) 'before': beforeId,
      'limit': '$limit',
    };
    final json = await _jsonRequest(
      'GET',
      Uri(
        path: '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
            '/history',
        queryParameters: query,
      ).toString(),
      token: token,
      maxResponseBytes: _maxCiphertextResponseBytes,
    );
    return _decode(() => (json['history'] as List)
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList());
  }

  /// C7: the signing keys of devices that posted in [conversationId] and are
  /// no longer in its group (one bulk call at join, in every mode).
  Future<List<Map<String, Object?>>> formerMemberKeys(
      String token, String conversationId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/former-member-keys',
      token: token,
    );
    return _decode(() => (json['devices'] as List)
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList());
  }

  /// C7: marks a community post `history_hidden`, so the history route never
  /// serves it to a newcomer. The author's or a moderator's delete sends it
  /// with the W7 delete.
  Future<void> hideHistoryMessage(String token, String messageId) async {
    await _jsonRequest(
      'POST',
      '/api/v1/messages/${Uri.encodeComponent(messageId)}/history-hide',
      token: token,
      body: const <String, Object?>{},
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
    final request = await _openRequest('POST', uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set('X-Crypto-Metadata', jsonEncode(cryptoMetadata));
    request.contentLength = ciphertextLength;
    final response = await _sendBody(request, ciphertext);
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
    final request = await _openRequest('GET', uri);
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
    final request = await _openRequest(
      'POST',
      Uri.parse(baseUrl).resolve('/api/v1/backups'),
    );
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
    final response = await _sendBody(request, ciphertext);
    await _readJsonResponse(response);
  }

  /// Uploads a K1 copy (K1-2): sealed to the recovery key [rkId] with this
  /// device's [counter], and no recovery token. Errors carry the server's
  /// code (`recovery_key_changed`, `backup_counter_stale`,
  /// `storage_quota_exceeded`, `recovery_not_configured`).
  Future<void> uploadK1Backup(
    String token,
    Uint8List ciphertext, {
    required List<int> rkId,
    required int counter,
  }) async {
    if (ciphertext.isEmpty ||
        ciphertext.length > k1MaxBackupCiphertextBytes ||
        rkId.length != 16 ||
        counter <= 0) {
      throw ArgumentError('invalid K1 backup');
    }
    final request = await _openRequest(
      'POST',
      Uri.parse(baseUrl).resolve('/api/v1/backups'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set(
      'X-Key-Derivation-Metadata',
      jsonEncode(<String, Object?>{
        'kind': 1,
        'rk_id': base64.encode(rkId),
        'counter': counter,
      }),
    );
    request.contentLength = ciphertext.length;
    // 64 KiB slices, like the file streams of other uploads: _sendBody's
    // idle watchdog re-arms per slice, so a slow link is not cut off.
    final response = await _sendBody(request, k1UploadSlices(ciphertext));
    await _readJsonResponse(response);
  }

  /// `GET /api/v1/backups`: the account's backups. Rows are the server's
  /// claims; the restore opens the container to trust anything.
  Future<List<Map<String, Object?>>> listBackups(String token,
      {int limit = 100}) async {
    final json =
        await _jsonRequest('GET', '/api/v1/backups?limit=$limit', token: token);
    final backups = json['backups'];
    if (backups is! List) throw const ApiResponseException();
    return <Map<String, Object?>>[
      for (final b in backups)
        if (b is Map) Map<String, Object?>.from(b),
    ];
  }

  /// `GET /api/v1/backups/{id}` with the session: the sealed container, or
  /// the byte range [start]..[end] of it (the header peek). The stream is
  /// bounded by [k1MaxBackupCiphertextBytes]; the server verifies every
  /// chunk before sending it.
  Future<Stream<List<int>>> downloadBackup(String token, String id,
      {int? start, int? end}) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        (start != null && (start < 0 || (end != null && end < start)))) {
      throw ArgumentError('invalid backup download');
    }
    final request = await _openRequest(
      'GET',
      Uri.parse(baseUrl).resolve('/api/v1/backups/$id'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (start != null) {
      request.headers.set('Range', 'bytes=$start-${end ?? ''}');
    }
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    final ranged = start != null;
    if (response.statusCode != (ranged ? 206 : 200)) {
      // A 200 for a range is the whole file; a 206 for none is not ours.
      await _discard(response);
      throw const ApiResponseException();
    }
    return _boundedStream(response, k1MaxBackupCiphertextBytes);
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
    final request = await _openRequest(
      'GET',
      Uri.parse(baseUrl).resolve('/api/v1/recovery'),
    );
    request.headers.set('X-Recovery-Token', encoded);
    if (startOffset != null) {
      final rangeEnd = endOffset == null ? '' : '$endOffset';
      request.headers.set('Range', 'bytes=$startOffset-$rangeEnd');
    }
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    if (startOffset == null) {
      if (response.statusCode != 200) {
        await _discard(response);
        throw const ApiResponseException();
      }
      return _boundedStream(response, maxBackupCiphertextBytes);
    }
    // A ranged request is answered only by a 206 that proves where its body
    // starts. A 200 is the whole object from byte 0 (RFC 9110, 14.2) and
    // would be misplaced at the saved offset.
    if (response.statusCode == 200) {
      await _discard(response);
      throw RangeNotHonoredException();
    }
    final range = response.statusCode == 206
        ? _parseContentRange(response.headers['content-range'])
        : null;
    if (range == null ||
        range.first != startOffset ||
        (endOffset != null && range.last > endOffset) ||
        (response.contentLength >= 0 &&
            response.contentLength != range.last - range.first + 1)) {
      await _discard(response);
      throw const ApiResponseException();
    }
    if (range.last >= maxBackupCiphertextBytes) {
      await _discard(response);
      throw const ApiResponseTooLargeException();
    }
    return _boundedStream(response, range.last - range.first + 1);
  }

  /// Stops reading [response]; the rest of its body is never downloaded.
  static Future<void> _discard(HttpClientResponse response) =>
      response.listen(null).cancel();

  /// Parses `bytes first-last/complete` (the complete length may be `*`).
  /// Anything else, including an unsatisfied range (`bytes */n`), a repeated
  /// header or a last byte before the first, gives null.
  static ({int first, int last})? _parseContentRange(List<String>? values) {
    if (values == null || values.length != 1) return null;
    final match = RegExp(r'^bytes (\d{1,15})-(\d{1,15})/(\d{1,15}|\*)$')
        .firstMatch(values.single.trim());
    if (match == null) return null;
    final first = int.parse(match.group(1)!);
    final last = int.parse(match.group(2)!);
    final complete = match.group(3)!;
    if (last < first) return null;
    if (complete != '*' && int.parse(complete) <= last) return null;
    return (first: first, last: last);
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
      // The reply echoes the stored message, payload included.
      maxResponseBytes: _maxCiphertextResponseBytes,
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
    final cut = json['list_truncated'];
    return MlsPendingChanges(
      _rows(
        json,
        'pending_changes',
        MlsPendingChange.fromJson,
      ).toList(growable: false),
      // Absent from older servers: the caller then falls back.
      cut: cut is bool ? cut : null,
    );
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

  // ---- B6 group-call rooms (docs/designs/B6-group-calls.md). Raw JSON:
  // the room engine's adapter (calls/room/room_api.dart) reads it. ----

  Future<Map<String, Object?>> joinRoom(String token, String conversationId) =>
      _jsonRequest('POST', '/api/v1/rooms/join',
          token: token,
          body: <String, Object?>{'conversation_id': conversationId});

  Future<Map<String, Object?>> roomState(String token, String callId) =>
      _jsonRequest('GET', '/api/v1/rooms/${Uri.encodeComponent(callId)}',
          token: token);

  Future<Map<String, Object?>> roomCommits(String token, String callId,
          {required int after}) =>
      _jsonRequest(
          'GET',
          Uri(
              path: '/api/v1/rooms/${Uri.encodeComponent(callId)}/commits',
              queryParameters: <String, String>{'after': '$after'}).toString(),
          token: token,
          maxResponseBytes: 8 * 1024 * 1024);

  /// A 409 `room_epoch_conflict` means another commit won this epoch.
  Future<Map<String, Object?>> sendRoomCommit(
          String token, String callId, Map<String, Object?> body) =>
      _jsonRequest(
          'POST', '/api/v1/rooms/${Uri.encodeComponent(callId)}/commit',
          token: token, body: body);

  Future<void> sendRoomOffer(
      String token, String callId, Map<String, Object?> body) async {
    await _jsonRequest(
        'POST', '/api/v1/rooms/${Uri.encodeComponent(callId)}/offer',
        token: token, body: body);
  }

  Future<void> leaveRoom(String token, String callId) async {
    await _jsonRequest(
        'POST', '/api/v1/rooms/${Uri.encodeComponent(callId)}/leave',
        token: token, body: const <String, Object?>{});
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
  ///
  /// Returns the sync event id the server reports as the removed member's
  /// own event (`event_id`, the leaver's `membership.left` for a leave), or
  /// null when it reports none (an older server) or an unusable value. The
  /// app dates a leave by it (D70): every Welcome stored for the leaver
  /// before the leave has a lower id.
  Future<int?> removeConversationMember(
    String token,
    String conversationId,
    String accountId,
  ) async {
    final json = await _jsonRequest(
      'DELETE',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/members/${Uri.encodeComponent(accountId)}',
      token: token,
    );
    final id = json['event_id'];
    return id is int && id > 0 ? id : null;
  }

  Future<ConversationMute> conversationMute(
      String token, String conversationId) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/notifications',
      token: token,
    );
    return ConversationMute.fromJson(json);
  }

  /// Mutes or unmutes push for the conversation. [forDuration] ends a mute by
  /// itself; without it a mute has no end.
  Future<ConversationMute> setConversationMute(
    String token,
    String conversationId, {
    required bool muted,
    Duration? forDuration,
  }) async {
    final json = await _jsonRequest(
      'PUT',
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}'
          '/notifications',
      token: token,
      body: <String, Object?>{
        'muted': muted,
        // A length, not a time of day: the server counts from its own clock,
        // so a device whose clock is off still mutes for the length asked.
        if (muted && forDuration != null)
          'muted_for_seconds': forDuration.inSeconds,
      },
    );
    return ConversationMute.fromJson(json);
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

  // W11 encrypted profiles. The server holds one opaque record per account
  // and per group; names, photos and keys never reach it.

  Future<ProfileFetch> fetchProfile(
    String token,
    String path, {
    int? ifNoneMatchVersion,
  }) async {
    final request = await _openRequest('GET', Uri.parse(baseUrl).resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (ifNoneMatchVersion != null) {
      request.headers
          .set(HttpHeaders.ifNoneMatchHeader, '"$ifNoneMatchVersion"');
    }
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode == 304) {
      await response.drain<void>();
      return const ProfileFetch.notModified();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    final version = int.tryParse(
        (response.headers.value(HttpHeaders.etagHeader) ?? '')
            .replaceAll('"', ''));
    final keyId = response.headers.value('X-Profile-Key-Id');
    final blob = await _readBounded(response, maxProfileBlobBytes);
    if (version == null || version < 1 || keyId == null || blob.isEmpty) {
      throw const ApiResponseException();
    }
    return ProfileFetch.record(version: version, keyId: keyId, blob: blob);
  }

  Future<ProfileFetch> fetchAccountProfile(String token, String accountId,
          {int? ifNoneMatchVersion}) =>
      fetchProfile(
          token, '/api/v1/profiles/account/${Uri.encodeComponent(accountId)}',
          ifNoneMatchVersion: ifNoneMatchVersion);

  Future<ProfileFetch> fetchConversationProfile(
          String token, String conversationId, {int? ifNoneMatchVersion}) =>
      fetchProfile(token,
          '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/profile',
          ifNoneMatchVersion: ifNoneMatchVersion);

  /// Replaces a record. [ifMatchVersion] is the version being replaced, or
  /// null for the first write. Throws [ApiException] with kind conflict when
  /// another device wrote first (412).
  Future<int> putProfile(
    String token,
    String path,
    Uint8List blob, {
    required String keyId,
    int? ifMatchVersion,
  }) async {
    if (blob.isEmpty || blob.length > maxProfileBlobBytes) {
      throw ArgumentError.value(blob.length, 'blob');
    }
    final request = await _openRequest('PUT', Uri.parse(baseUrl).resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Private-Messenger-Encrypted', '1');
    request.headers.set('X-Profile-Key-Id', keyId);
    if (ifMatchVersion == null) {
      request.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
    } else {
      request.headers.set(HttpHeaders.ifMatchHeader, '"$ifMatchVersion"');
    }
    request.headers.contentType = ContentType.binary;
    request.contentLength = blob.length;
    final response = await _sendBody(request, Stream.value(blob));
    final json = await _readJsonResponse(response);
    final version = json['version'];
    if (version is! int || version < 1) throw const ApiResponseException();
    return version;
  }

  Future<int> putAccountProfile(String token, Uint8List blob,
          {required String keyId, int? ifMatchVersion}) =>
      putProfile(token, '/api/v1/profiles/account/me', blob,
          keyId: keyId, ifMatchVersion: ifMatchVersion);

  Future<int> putConversationProfile(
          String token, String conversationId, Uint8List blob,
          {required String keyId, int? ifMatchVersion}) =>
      putProfile(
          token,
          '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/profile',
          blob,
          keyId: keyId,
          ifMatchVersion: ifMatchVersion);

  /// The current `{version, key_id}` of every subject the caller may read, at
  /// most 200 of each kind. Unreadable and missing subjects are left out.
  Future<List<ProfileVersion>> profileVersions(
    String token, {
    List<String> accountIds = const <String>[],
    List<String> conversationIds = const <String>[],
  }) async {
    if (accountIds.length > 200 || conversationIds.length > 200) {
      throw ArgumentError('at most 200 subjects of a kind');
    }
    final json = await _jsonRequest('POST', '/api/v1/profiles/versions',
        token: token,
        body: <String, Object?>{
          'account_ids': accountIds,
          'conversation_ids': conversationIds,
        });
    final list = json['versions'];
    if (list is! List) throw const ApiResponseException();
    return _decode(() => [
          for (final item in list)
            ProfileVersion.fromJson(Map<String, Object?>.from(item as Map)),
        ]);
  }

  /// Clears the legacy plaintext title after the group's encrypted profile
  /// holds the name (owner or admin only).
  Future<void> clearConversationTitle(
      String token, String conversationId) async {
    final request = await _openRequest(
        'DELETE',
        Uri.parse(baseUrl).resolve(
            '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/title'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _apiError(response);
    }
    await response.drain<void>();
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
          ..._sealedQuery,
        },
      ).toString();
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    return _rows(json, 'events', SyncEvent.fromJson);
  }

  /// [syncEvents] with the scan position, asking for the bounded scan
  /// (TASK-209, D92): the server examines at most a budget of candidates,
  /// hidden ones included, and reports how far it looked
  /// ([ConversationSyncPage.scannedThrough]) and whether the budget ended the
  /// page early ([ConversationSyncPage.truncated]). Both are absent from an
  /// older server, which also ignores the opt-in. Test fakes that only
  /// override [syncEvents] mix in [LegacySyncPageFake].
  Future<ConversationSyncPage> syncEventsPage(
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
          'scan': 'bounded',
          ..._sealedQuery,
        },
      ).toString();
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    final events = _rows(json, 'events', SyncEvent.fromJson);
    return _decode(() {
      final through = json['scanned_through'];
      final truncated = json['scan_truncated'];
      if (through != null && (through is! int || through < 0)) {
        throw const FormatException();
      }
      if (truncated != null && truncated is! bool) {
        throw const FormatException();
      }
      return ConversationSyncPage(
        events,
        scannedThrough: through as int?,
        truncated: truncated == true,
      );
    });
  }

  /// One conversation's own sync stream (C1 prerequisite 1), in event order.
  /// The server serves it only when the operator turned scoped sync on, and
  /// answers 404 otherwise. A conversation whose retention was pruned past
  /// [after] answers 409 `conversation_recovery_required`; a non-member 403.
  /// Only the events are read: the envelope's bounds are the account's, not
  /// this stream's. See [conversationSyncPage] for the scan position.
  Future<List<SyncEvent>> conversationSyncEvents(
    String token,
    String conversationId, {
    int after = 0,
    int limit = 100,
  }) async =>
      (await conversationSyncPage(token, conversationId,
              after: after, limit: limit))
          .events;

  /// [conversationSyncEvents] with the scan position (C1 bounds, D92): how
  /// far the server looked, hidden events included, and whether its scan
  /// budget cut the page short. Both are absent from an older server.
  Future<ConversationSyncPage> conversationSyncPage(
    String token,
    String conversationId, {
    int after = 0,
    int limit = 100,
  }) async {
    final id = Uri.encodeComponent(conversationId);
    final json = await _shrinkingPage(limit, (pageLimit) {
      final path = '/api/v1/conversations/$id/sync-events'
          '?after=$after&limit=$pageLimit&scan=bounded'
          '${readsSealedEvents ? '&sealed=1' : ''}';
      return _jsonRequest('GET', path,
          token: token, maxResponseBytes: _maxCiphertextResponseBytes);
    });
    _decode(() {
      if (json['scope'] != 'conversation' ||
          json['scope_id'] != conversationId) {
        throw const FormatException();
      }
    });
    final events = _rows(json, 'events', SyncEvent.fromJson);
    return _decode(() {
      final through = json['scanned_through'];
      final truncated = json['scan_truncated'];
      if (through != null && (through is! int || through < 0)) {
        throw const FormatException();
      }
      if (truncated != null && truncated is! bool) {
        throw const FormatException();
      }
      return ConversationSyncPage(
        events,
        scannedThrough: through as int?,
        truncated: truncated == true,
      );
    });
  }

  /// The newest sync event id the server holds for this account, read from
  /// the `latest_event_id` bound of an empty page (the cursor is past every
  /// event, so no event or ciphertext comes back). Used to date a leave
  /// (D70): every event from before it has an id at or below this.
  Future<int> syncLatestEventId(String token) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/sync/events?after=$_pastEveryEventId&limit=1',
      token: token,
    );
    return _decode(() {
      final latest = json['latest_event_id'];
      if (latest is! int || latest < 0) throw const FormatException();
      return latest;
    });
  }

  /// A cursor above any event id the server can have issued (2^53 - 1).
  static const int _pastEveryEventId = 9007199254740991;

  /// L2-3: the server's sealed sender key, `GET /api/v1/sealed/key` (no
  /// session; 404 while the server's switch is off).
  Future<SealedServerKey> sealedKey() async {
    final json = await _jsonRequest('GET', '/api/v1/sealed/key');
    return _decode(() {
      if (json['suite'] != sealedSuite) throw const FormatException();
      return SealedServerKey(
        keyId: json['key_id'] as String,
        publicKey: base64Decode(json['public_key'] as String),
      );
    });
  }

  /// L2-3: what this account needs to ask for tokens in [conversationId].
  Future<SealedConversationState> sealedConversation(
      String token, String conversationId) async {
    final id = Uri.encodeComponent(conversationId);
    final json = await _jsonRequest(
        'GET', '/api/v1/sealed/conversations/$id',
        token: token);
    return _decode(() {
      final generation = json['generation'] as int;
      final epoch = json['epoch'] as int;
      final remaining = json['remaining'] as int;
      if (generation < 0 || epoch < 0 || remaining < 0) {
        throw const FormatException();
      }
      return SealedConversationState(
        key: SealedServerKey(
          keyId: json['key_id'] as String,
          publicKey: base64Decode(json['public_key'] as String),
        ),
        generation: generation,
        epoch: epoch,
        eligible: json['eligible'] as bool,
        remaining: remaining,
      );
    });
  }

  /// L2-3: the server's evaluation of [blinded] (`count × 32` bytes) and its
  /// batch proof, as the one response the crypto core finalizes
  /// (`evaluated || proof`), with the key id it was made under.
  Future<({String keyId, Uint8List response})> sealedTokens(
    String token,
    String conversationId, {
    required int epoch,
    required int generation,
    required List<int> blinded,
  }) async {
    final id = Uri.encodeComponent(conversationId);
    final json = await _jsonRequest(
      'POST',
      '/api/v1/sealed/conversations/$id/tokens',
      token: token,
      body: <String, Object?>{
        'epoch': epoch,
        'generation': generation,
        'blinded': base64Encode(blinded),
      },
    );
    return _decode(() {
      final evaluated = base64Decode(json['evaluated'] as String);
      final proof = base64Decode(json['proof'] as String);
      if (evaluated.length != blinded.length || proof.length != 64) {
        throw const FormatException();
      }
      return (
        keyId: json['key_id'] as String,
        response: Uint8List.fromList(<int>[...evaluated, ...proof]),
      );
    });
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

  /// Moves the read cursor for the caller's own unread count only: the server
  /// announces nothing and lists it to nobody (read receipts switched off).
  Future<void> markReadPrivate(
    String token,
    String conversationId,
    String messageId,
  ) async {
    await _jsonRequest(
      'POST',
      '/api/v1/conversations/$conversationId/read-receipts',
      token: token,
      body: <String, Object?>{'message_id': messageId, 'private': true},
    );
  }

  /// Whether this account shares read receipts; the switch is per account, so
  /// every linked device honours it.
  Future<bool> readReceiptsEnabled(String token) async {
    final json = await _jsonRequest('GET', '/api/v1/account/read-receipts',
        token: token);
    return json['enabled'] != false;
  }

  Future<void> setReadReceiptsEnabled(String token, bool enabled) async {
    await _jsonRequest(
      'PUT',
      '/api/v1/account/read-receipts',
      token: token,
      body: <String, Object?>{'enabled': enabled},
    );
  }

  /// The other members' delivery and read cursors (W5).
  Future<List<MemberReceipt>> listReceipts(
    String token,
    String conversationId,
  ) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/conversations/$conversationId/read-receipts',
      token: token,
    );
    return _rows(json, 'receipts', MemberReceipt.fromJson);
  }

  /// Ephemeral typing signal: nothing is stored, and the server admits about
  /// one per two seconds per conversation (429 otherwise).
  Future<void> sendTyping(String token, String conversationId) async {
    await _jsonRequest(
      'POST',
      '/api/v1/conversations/$conversationId/typing',
      token: token,
    );
  }

  Future<String> registerWebPush(
    String token, {
    String provider = 'webpush',
    required String endpoint,
    required String publicKey,
    required String authSecret,
    String? notificationMode,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/push/subscriptions',
      token: token,
      body: <String, Object?>{
        'provider': provider,
        'endpoint': endpoint,
        'public_key': publicKey,
        'auth_secret': authSecret,
        if (notificationMode != null) 'notification_mode': notificationMode,
      },
    );
    return _decode(() => json['subscription_id'] as String);
  }

  Future<String> registerNativePush(
    String token, {
    required String provider,
    required String deviceToken,
    String? notificationMode,
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
        if (notificationMode != null) 'notification_mode': notificationMode,
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

  Future<DeviceLink> createDeviceLink(String token, String locator) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links',
      token: token,
      body: <String, Object?>{'code': locator},
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
        'claim_tag': base64Encode(verification.claimTag),
      },
    );
    return _decode(
      () => DeviceLinkClaim(
        serverOrigin: baseUrl,
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
    List<int> approvalTag, {
    List<int>? deviceList,
  }) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/device-links/$linkId/approve',
      token: token,
      body: <String, Object?>{
        'transcript_hash': base64Encode(transcriptHash),
        'approval_tag': base64Encode(approvalTag),
        if (deviceList != null) 'device_list': base64Encode(deviceList),
      },
    );
    return _decode(() => DeviceLink.fromJson(_object(json, 'device_link')));
  }

  Future<Session?> completeDeviceLinkClaim(
    String linkId,
    String claimToken,
    List<int> expectedTranscriptHash,
    List<int> expectedApprovalTag,
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
    final approvalTag = _decodeRequiredBytes(json['approval_tag']);
    if (expectedApprovalTag.length != 32 ||
        !_bytesEqual(approvalTag, expectedApprovalTag)) {
      throw ApiException(409, '{"error":"link_confirmation_mismatch"}');
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

  /// Opens every request this client makes. API credentials, including the
  /// custom recovery, claim and setup tokens that dart:io does not strip on a
  /// redirect, are bound to this origin, so a 3xx is never followed: it
  /// reaches the caller as an [ApiException] carrying the 3xx status.
  Future<HttpClientRequest> _openRequest(String method, Uri uri) async {
    final request =
        await _httpClient.openUrl(method, uri).timeout(_requestTimeout);
    request.followRedirects = false;
    return request;
  }

  /// Streams [body] as the request body and returns the response. The
  /// transfer is bounded by progress: it fails with a [TimeoutException]
  /// when no chunk is taken from [body] for [_transferIdleTimeout], and when
  /// the server then does not answer within the same time. A [Timer] is used
  /// because [Stream.timeout] restarts its countdown on pause, which a socket
  /// that applies backpressure does all the time. On any failure the request
  /// is aborted, so a stalled upload does not keep running unowned.
  Future<HttpClientResponse> _sendBody(
    HttpClientRequest request,
    Stream<List<int>> body,
  ) async {
    final idle = _transferIdleTimeout;
    final stalled = Completer<void>();
    Timer? watchdog;
    void arm() {
      watchdog?.cancel();
      watchdog = Timer(idle, () {
        if (stalled.isCompleted) return;
        stalled.complete();
        request.abort(TimeoutException('The transfer stopped.', idle));
      });
    }

    Stream<List<int>> watched() async* {
      await for (final chunk in body) {
        arm();
        yield chunk;
      }
    }

    try {
      arm();
      await Future.any<void>(<Future<void>>[
        request.addStream(watched()),
        stalled.future,
      ]);
      if (stalled.isCompleted)
        throw TimeoutException('The transfer stopped.', idle);
      arm();
      final response = await Future.any<HttpClientResponse?>(
        <Future<HttpClientResponse?>>[
          request.close(),
          stalled.future.then((_) => null),
        ],
      );
      if (response == null)
        throw TimeoutException('The transfer stopped.', idle);
      return response;
    } catch (_) {
      // A no-op once the response has arrived.
      request.abort();
      rethrow;
    } finally {
      watchdog?.cancel();
    }
  }

  Future<Map<String, Object?>> _jsonRequest(
    String method,
    String path, {
    String? token,
    Map<String, Object?>? body,
    Map<String, String> extraHeaders = const <String, String>{},
    int maxResponseBytes = _maxJsonResponseBytes,
  }) async {
    final (_, json) = await _jsonRequestWithStatus(method, path,
        token: token,
        body: body,
        extraHeaders: extraHeaders,
        maxResponseBytes: maxResponseBytes);
    return json;
  }

  /// [_jsonRequest] that also returns the 2xx status.
  Future<(int, Map<String, Object?>)> _jsonRequestWithStatus(
    String method,
    String path, {
    String? token,
    Map<String, Object?>? body,
    Map<String, String> extraHeaders = const <String, String>{},
    int maxResponseBytes = _maxJsonResponseBytes,
  }) async {
    final uri = Uri.parse(baseUrl).resolve(path);
    final request = await _openRequest(method, uri);
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    extraHeaders.forEach((key, value) => request.headers.set(key, value));
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_requestTimeout);
    return (
      response.statusCode,
      await _readJsonResponse(response, maxResponseBytes),
    );
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
  Future<Stream<List<int>>> _boundedStream(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (maxBytes < 0 || response.contentLength > maxBytes) {
      await _discard(response);
      throw const ApiResponseTooLargeException();
    }
    return _countBytes(response, maxBytes, _transferIdleTimeout);
  }

  /// Also fails with a [TimeoutException] when the body stops arriving for
  /// [idle] while someone is listening. [Stream.timeout] stops its countdown
  /// while the listener is paused (a slow disk write), which is wanted here.
  /// Leaving the loop cancels the response and closes its connection.
  static Stream<List<int>> _countBytes(
    Stream<List<int>> source,
    int maxBytes,
    Duration idle,
  ) async* {
    var received = 0;
    await for (final chunk in source.timeout(idle)) {
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

/// One page of a conversation's sync stream with the server's scan position
/// (C1 bounds, D92). [scannedThrough] is the highest event id the server
/// examined, hidden events included, so a hidden run is crossed once; null
/// from a server that does not report it. [truncated] means the server's scan
/// budget ended the page early: more may follow even when [events] is short
/// or empty.
class ConversationSyncPage {
  const ConversationSyncPage(this.events,
      {this.scannedThrough, this.truncated = false});

  final List<SyncEvent> events;
  final int? scannedThrough;
  final bool truncated;
}

/// For test fakes that override [ApiClient.syncEvents] only: the page method
/// answers from it, with no scan position, as an older server would.
mixin LegacySyncPageFake on ApiClient {
  @override
  Future<ConversationSyncPage> syncEventsPage(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      ConversationSyncPage(await syncEvents(token, after: after, limit: limit));
}
