import 'dart:convert';
import 'dart:typed_data';

import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

/// An approved-device list for tests that are about something else: a
/// device is approved once a test [approve]s it, with exactly the key it was
/// approved with, and nothing else is. The real pins are tested in
/// `l1_device_list_pins_test.dart`; this keeps the add gate and the leaf
/// judge in force everywhere else instead of switching them off.
class TestDeviceLists extends DeviceListPins {
  TestDeviceLists()
      : super(
          store: MemoryLocalStore(),
          source: _NoServer(),
          verifier: _NoVerifier(),
        );

  final Map<String, Uint8List> _keys = <String, Uint8List>{};

  /// Accounts whose list cannot be read (judged "checking").
  final Set<String> unavailable = <String>{};

  static String _key(String account, String device) => '$account\u0000$device';

  void approve(String accountId, String deviceId, List<int> signingKey) =>
      _keys[_key(accountId, deviceId)] = Uint8List.fromList(signingKey);

  void remove(String accountId, String deviceId) =>
      _keys.remove(_key(accountId, deviceId));

  @override
  Future<Uint8List?> approvedKey(String accountId, String deviceId) async =>
      unavailable.contains(accountId) ? null : _keys[_key(accountId, deviceId)];

  @override
  Future<List<DeviceListPair>> approvedDevices(String accountId,
          {bool refreshFirst = true}) async =>
      [
        if (!unavailable.contains(accountId))
          for (final entry in _keys.entries)
            if (entry.key.split('\u0000').first == accountId)
              DeviceListPair(
                  idBytes(entry.key.split('\u0000').last), entry.value),
      ];

  @override
  Future<LeafVerdict> judge(
      List<int> accountId, List<int> deviceId, List<int> signingKey,
      {bool refreshFirst = true}) async {
    final String account;
    final String device;
    try {
      account = utf8.decode(accountId);
      device = utf8.decode(deviceId);
    } on FormatException {
      return LeafVerdict.unapproved;
    }
    if (unavailable.contains(account)) return LeafVerdict.checking;
    final key = _keys[_key(account, device)];
    if (key == null) return LeafVerdict.unapproved;
    if (key.length != signingKey.length) return LeafVerdict.unapproved;
    for (var i = 0; i < key.length; i++) {
      if (key[i] != signingKey[i]) return LeafVerdict.unapproved;
    }
    return LeafVerdict.approved;
  }
}

class _NoServer implements DeviceListSource {
  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
          {required int after}) =>
      throw UnsupportedError('TestDeviceLists has no server');
}

class _NoVerifier implements DeviceListVerifier {
  @override
  DeviceListChainResult checkChain(
          String accountId, List<List<int>> statements) =>
      throw UnsupportedError('TestDeviceLists verifies nothing');

  @override
  DeviceListSummary checkStep({
    required String accountId,
    required List<int>? prev,
    required List<int> statement,
    required List<DeviceListPair> history,
  }) =>
      throw UnsupportedError('TestDeviceLists verifies nothing');
}

/// One list for tests that are not about L1: every device a
/// [TestNativeCryptoService] enrolled in this test process is approved with
/// the key it enrolled with. A device no service enrolled (a server-made
/// one) is still refused.
final TestDeviceLists sharedTestDeviceLists = TestDeviceLists();

/// [NativeCryptoService] on [sharedTestDeviceLists]: the add gate and the
/// leaf judge stay in force, and the devices the test enrolls are on it.
class TestNativeCryptoService extends NativeCryptoService {
  TestNativeCryptoService({
    required super.bindings,
    required super.localStore,
    super.clock,
    super.frankingPolicy,
  }) {
    super.deviceListPins = sharedTestDeviceLists;
  }

  /// An app wiring its own pins in (AppState) still gets the shared list:
  /// the fake servers in these tests serve no lists.
  @override
  set deviceListPins(DeviceListPins? pins) =>
      super.deviceListPins = sharedTestDeviceLists;

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation) async {
    final credential = await super.createEnrollmentCredential(reservation);
    sharedTestDeviceLists.approve(
        reservation.accountId, reservation.deviceId, credential.signingKey);
    return credential;
  }
}
