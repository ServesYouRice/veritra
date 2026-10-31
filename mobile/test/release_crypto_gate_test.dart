import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// TASK-116: pins what release builds do today. `lib/main.dart` wires
/// [UnavailableCryptoService] until a reviewed production engine ships
/// (section-c0f810f71b16f6684b576132/UQ-001, D11), and
/// `scripts/check-demo-boundary.sh` holds it there. These tests describe
/// that gate; they do not decide when it opens.
void main() {
  const reservation = EnrollmentReservation(
    id: 'enr_1',
    accountId: 'acct_1',
    deviceId: 'dev_1',
    challenge: <int>[1, 2, 3],
  );

  Future<Object> thrownBy(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (error) {
      return error;
    }
    fail('expected the release crypto service to throw');
  }

  test('release crypto is unavailable on every method', () async {
    final crypto = UnavailableCryptoService();
    final errors = <Object>[
      await thrownBy(() => crypto.createEnrollmentCredential(reservation)),
      await thrownBy(() => crypto.encrypt('conv_1', 'hello')),
      await thrownBy(() => crypto.deriveDeviceLinkVerification(
            accountId: 'acct_1',
            protocolVersion: 'v1',
            serverOrigin: 'https://chat.example.org',
            linkId: 'dl_1',
            linkSecret: <int>[1],
            linkNonce: <int>[2],
            peerDeviceId: 'dev_2',
            peerSigningKey: <int>[3],
            localIsExistingDevice: true,
          )),
      await thrownBy(() => crypto.deviceLinkLocator(<int>[1, 2, 3])),
    ];
    expect(errors, everyElement(isA<StateError>()));
    // It is not an MLS service either, so AppState never routes
    // conversations through it.
    expect(crypto, isNot(isA<MlsConversationCryptoService>()));
  });

  test('release crypto errors surface as the encryption engine message',
      () async {
    final crypto = UnavailableCryptoService();
    for (final call in <Future<Object?> Function()>[
      () => crypto.createEnrollmentCredential(reservation),
      () => crypto.encrypt('conv_1', 'hello'),
    ]) {
      expect(describeError(await thrownBy(call), englishL10n),
          englishL10n.errorEncryptionUnavailable);
    }
    // The device-link errors name neither MLS nor encryption, so they read
    // as their own capitalised sentence (today's behaviour, pinned here).
    final sas = await thrownBy(() => crypto.deriveDeviceLinkVerification(
          accountId: 'acct_1',
          protocolVersion: 'v1',
          serverOrigin: 'https://chat.example.org',
          linkId: 'dl_1',
          linkSecret: <int>[1],
          linkNonce: <int>[2],
          peerDeviceId: 'dev_2',
          peerSigningKey: <int>[3],
          localIsExistingDevice: true,
        ));
    final locator = await thrownBy(() => crypto.deviceLinkLocator(<int>[1]));
    for (final error in <Object>[sas, locator]) {
      expect(describeError(error, englishL10n), (error as StateError).message);
    }
  });

  test('release crypto cannot register: nothing is sent or stored', () async {
    final api = _RegisterApi();
    final store = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: UnavailableCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    );
    addTearDown(state.dispose);

    await state.registerWithInvite(
        'https://chat.example.org', 'INVITE', 'alice', 'alice-password-123');

    expect(api.reservations, 1, reason: 'the enrollment was reserved');
    expect(api.registrations, 0, reason: 'no credential, no registration');
    expect(state.session, isNull);
    expect(await store.loadSession(), isNull);
    expect(state.error, englishL10n.errorEncryptionUnavailable);
  });
}

class _RegisterApi extends ApiClient {
  _RegisterApi() : super(baseUrl: 'https://chat.example.org');

  int reservations = 0;
  int registrations = 0;

  @override
  Future<EnrollmentReservation> reserveRegistrationEnrollment(
      String inviteCode) async {
    reservations++;
    return const EnrollmentReservation(
      id: 'enr_1',
      accountId: 'acct_1',
      deviceId: 'dev_1',
      challenge: <int>[1, 2, 3],
    );
  }

  @override
  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
  }) async {
    registrations++;
    throw StateError('registration must not be reached');
  }
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
