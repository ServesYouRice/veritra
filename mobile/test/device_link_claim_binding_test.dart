// TASK-094: device-link transcript binding with strict fakes. The server
// here always sends its own verification code ('99999999'), so a test can
// tell the locally derived SAS ('65432101') from a relayed one, and every
// hash the fake receives is compared in full.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _localSas = '65432101';
const _serverCode = '99999999';
const _origin = 'https://localhost:8080';

List<int> _bytes(int value) => List<int>.filled(32, value);

/// Derives the honest transcript (all 7s) only from the inputs the honest
/// server uses: this account, link and nonce. Anything else gives a
/// different hash, as the real derivation would.
class _BindingCrypto extends TestOnlyCryptoService {
  @override
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required String serverOrigin,
    required String linkId,
    required List<int> linkSecret,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  }) async {
    final honest = accountId == 'acct_owner' &&
        linkId == 'dlink_1' &&
        listEquals(linkNonce, _bytes(1));
    return DeviceLinkVerification(
      transcriptHash: _bytes(honest ? 7 : 3),
      sas: honest ? _localSas : '11111111',
      claimTag: _bytes(8),
      approvalTag: _bytes(9),
    );
  }
}

class _StrictLinkApi extends ApiClient {
  _StrictLinkApi() : super(baseUrl: _origin);

  /// The transcript the honest server computed for this link.
  final List<int> serverTranscript = _bytes(7);

  // Claimer-side mutation switches.
  int reservationNonceByte = 1;
  List<int> claimTranscript = _bytes(7);
  String claimAccountId = 'acct_owner';

  DeviceLinkVerification? claimedWith;
  List<int>? completedWith;
  final List<List<int>> approvedWith = <List<int>>[];

  DeviceLink _link({
    required String state,
    String? code,
    String accountId = 'acct_owner',
    List<int>? transcriptHash,
    String? approvedDeviceId,
  }) =>
      DeviceLink(
        id: 'dlink_1',
        state: state,
        verificationCode: _serverCode,
        expiresAt: DateTime.utc(2030),
        code: code,
        claimedDeviceName: state == 'pending' ? null : 'linked tablet',
        approvedDeviceId: approvedDeviceId,
        accountId: accountId,
        createdByDeviceId: 'dev_owner',
        protocolVersion: 'veritra-device-link-v2',
        linkNonce: _bytes(1),
        existingSigningKey: _bytes(2),
        claimedDeviceId: state == 'pending' ? null : 'dev_linked',
        claimedSigningKey: state == 'pending' ? null : _bytes(9),
        claimTag: _bytes(8),
        transcriptHash: transcriptHash,
      );

  @override
  Future<DeviceLink> createDeviceLink(String token, String locator) async =>
      _link(state: 'pending', code: locator);

  @override
  Future<DeviceLink> deviceLink(String token, String linkId) async =>
      _link(state: 'claimed', transcriptHash: serverTranscript);

  @override
  Future<DeviceLink> approveDeviceLink(
    String token,
    String linkId,
    List<int> transcriptHash,
    List<int> approvalTag,
  ) async {
    approvedWith.add(List<int>.of(transcriptHash));
    if (!listEquals(transcriptHash, serverTranscript) ||
        !listEquals(approvalTag, _bytes(9))) {
      throw ApiException(409, '{"error":"transcript_mismatch"}');
    }
    return _link(
        state: 'approved', code: 'a' * 64, approvedDeviceId: 'dev_linked');
  }

  @override
  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(
          String code) async =>
      EnrollmentReservation(
        id: 'dlink_1',
        accountId: 'acct_owner',
        deviceId: 'dev_linked',
        challenge: const <int>[1, 2, 3],
        protocolVersion: 'veritra-device-link-v2',
        linkNonce: _bytes(reservationNonceByte),
        existingDeviceId: 'dev_owner',
        existingSigningKey: _bytes(2),
      );

  @override
  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    required DeviceLinkVerification verification,
  }) async {
    claimedWith = verification;
    return DeviceLinkClaim(
      serverOrigin: baseUrl,
      deviceLink: _link(
        state: 'claimed',
        accountId: claimAccountId,
        transcriptHash: claimTranscript,
      ),
      claimToken: 'claim-token',
      deviceSecret: 'device-secret',
    );
  }

  @override
  Future<Session?> completeDeviceLinkClaim(
    String linkId,
    String claimToken,
    List<int> expectedTranscriptHash,
    List<int> expectedApprovalTag,
  ) async {
    completedWith = List<int>.of(expectedTranscriptHash);
    if (!listEquals(expectedTranscriptHash, serverTranscript)) {
      throw ApiException(409, '{"error":"transcript_mismatch"}');
    }
    return const Session(
      baseUrl: _origin,
      token: 'linked-token',
      accountId: 'acct_owner',
      deviceId: 'dev_linked',
    );
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<Invite>> listInvites(String token) async => const <Invite>[];

  @override
  Future<List<Community>> listCommunities(String token) async =>
      const <Community>[];

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async =>
      const <BlockedAccount>[];

  @override
  Future<bool> readReceiptsEnabled(String token) async => true;

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

AppState _state(_StrictLinkApi api, LocalStore store) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: _BindingCrypto(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

void main() {
  group('claiming device', () {
    test('shows the derived code and completes with the derived hash',
        () async {
      final api = _StrictLinkApi();
      final store = MemoryLocalStore();
      final state = _state(api, store);
      addTearDown(state.dispose);

      await state.claimDeviceLink(_origin, 'A' * 26);
      expect(state.error, isNull);
      expect(
          state.pendingDeviceLinkClaim?.deviceLink.verificationCode, _localSas,
          reason: 'the server-supplied code was shown');
      expect(api.claimedWith?.transcriptHash, _bytes(7));
      expect(state.session, isNull);

      await state.completeDeviceLinkClaim();
      expect(api.completedWith, _bytes(7),
          reason: 'completion did not send the locally derived transcript');
      expect(state.session?.token, 'linked-token');
      expect((await store.loadSession())?.token, 'linked-token');
    });

    for (final (name, mutate) in <(String, void Function(_StrictLinkApi))>[
      ('a different transcript', (api) => api.claimTranscript = _bytes(6)),
      (
        'a transcript differing in its last byte',
        (api) => api.claimTranscript = _bytes(7)..[31] = 6
      ),
      ('a different account', (api) => api.claimAccountId = 'acct_mallory'),
      (
        'a substituted nonce in the reservation',
        (api) => api.reservationNonceByte = 5
      ),
    ]) {
      test('rejects $name and saves no session', () async {
        final api = _StrictLinkApi();
        mutate(api);
        final store = MemoryLocalStore();
        final state = _state(api, store);
        addTearDown(state.dispose);

        await state.claimDeviceLink(_origin, 'A' * 26);
        expect(state.error, isNotNull);
        expect(state.pendingDeviceLinkClaim, isNull);
        await state.completeDeviceLinkClaim();
        expect(api.completedWith, isNull);
        expect(state.session, isNull);
        expect(await store.loadSession(), isNull);
      });
    }
  });

  group('existing device', () {
    AppState owner(_StrictLinkApi api) => _state(api, MemoryLocalStore())
      ..api = api
      ..session = const Session(baseUrl: _origin, token: 'owner-token');

    test('shows the derived code, never the server one', () async {
      final api = _StrictLinkApi();
      final state = owner(api);
      addTearDown(state.dispose);
      await state.createDeviceLink();
      expect(state.activeDeviceLink?.verificationCode, isEmpty);
      await state.refreshActiveDeviceLink();
      expect(state.error, isNull);
      expect(state.activeDeviceLink?.verificationCode, _localSas);
    });

    test('typing the server code approves nothing', () async {
      final api = _StrictLinkApi();
      final state = owner(api);
      addTearDown(state.dispose);
      await state.createDeviceLink();
      await state.refreshActiveDeviceLink();
      await state.approveActiveDeviceLink(_serverCode);
      expect(state.error, contains('did not match'));
      expect(state.activeDeviceLink?.state, isNot('approved'));
      expect(api.approvedWith, isEmpty);
    });

    test('approval sends the full derived transcript', () async {
      final api = _StrictLinkApi();
      final state = owner(api);
      addTearDown(state.dispose);
      await state.createDeviceLink();
      await state.refreshActiveDeviceLink();
      await state.approveActiveDeviceLink(_localSas);
      expect(state.error, isNull);
      expect(state.activeDeviceLink?.state, 'approved');
      expect(api.approvedWith, <List<int>>[_bytes(7)]);
    });
  });

  group('ApiClient.completeDeviceLinkClaim', () {
    late HttpServer server;
    late ApiClient client;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    Future<void> answer(int status, Map<String, Object?> body) async {
      final request = await server.first;
      expect(request.uri.path, '/api/v1/device-links/link/claim-status');
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }

    test('throws on a transcript_mismatch answer', () async {
      final completion = client.completeDeviceLinkClaim(
          'link', 'claim-token', _bytes(7), _bytes(9));
      final refused = expectLater(
          completion,
          throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 409)));
      await answer(409, <String, Object?>{'error': 'transcript_mismatch'});
      await refused;
    });

    test('throws when the session carries another transcript', () async {
      final completion = client.completeDeviceLinkClaim(
          'link', 'claim-token', _bytes(7), _bytes(9));
      final refused = expectLater(
          completion,
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.serverCode, 'code', 'transcript_mismatch')));
      final transcript = _bytes(7)..[31] = 6;
      await answer(200, <String, Object?>{
        'token': 'linked',
        'transcript_hash': base64Encode(transcript),
        'approval_tag': base64Encode(_bytes(9)),
        'account': <String, Object?>{'id': 'acct'},
        'device': <String, Object?>{'id': 'dev'},
      });
      await refused;
    });
  });
}
