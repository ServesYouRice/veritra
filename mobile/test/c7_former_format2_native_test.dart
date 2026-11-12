import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// Round 8 integration: C7's review M2 ("a former member is named only when
/// a signed list of the named account has the device") with L1 format-2
/// device lists (L2-3: each listed device's franking key). The import's
/// proof step (`_c7FormerProven`) judges through the real [DeviceListPins]
/// and the native verifier, over chains whose every statement is format 2.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  test(
      'a named former member is proven from a format-2 list, and the '
      'server naming another account proves nothing', () async {
    final dave = await _Device.enroll(bindings, 'acct_dave', 'dev_dave');
    final carol = await _Device.enroll(bindings, 'acct_carol', 'dev_carol');
    final phone = await _Device.enroll(bindings, 'acct_carol', 'dev_phone');
    final erin = await _Device.enroll(bindings, 'acct_erin', 'dev_erin');
    final carolKey = await carol.service.currentSigningKey();
    final phoneKey = await phone.service.currentSigningKey();
    final erinKey = await erin.service.currentSigningKey();

    // Carol: genesis lists both devices with her own franking key; the
    // phone then sets its own; then the phone removes her old device.
    final carolGenesis = await carol.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_carol'),
      version: 1,
      prevHash: DeviceListBody.zeroHash,
      createdAtMs: 1,
      change: DeviceListChange.migrationGenesis,
      entries: [
        DeviceListPair(idBytes('dev_carol'), carolKey),
        DeviceListPair(idBytes('dev_phone'), phoneKey),
      ],
      frankKeys: [
        DeviceListFrankKey(
            idBytes('dev_carol'), await carol.service.currentFrankKey()),
      ],
    ));
    final phoneFrank = await phone.service.currentFrankKey();
    final carolFrank = await carol.service.currentFrankKey();
    final head1 = bindings.checkDeviceListStep(
        expectedAccountId: idBytes('acct_carol'), statement: carolGenesis);
    final carolSetsPhone = await phone.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_carol'),
      version: 2,
      prevHash: head1.listHash,
      createdAtMs: 2,
      change: DeviceListChange.frankKey,
      entries: [
        DeviceListPair(idBytes('dev_carol'), carolKey),
        DeviceListPair(idBytes('dev_phone'), phoneKey),
      ],
      frankKeys: [
        DeviceListFrankKey(idBytes('dev_carol'), carolFrank),
        DeviceListFrankKey(idBytes('dev_phone'), phoneFrank),
      ],
    ));
    final head2 = bindings.checkDeviceListStep(
        expectedAccountId: idBytes('acct_carol'),
        statement: carolSetsPhone,
        prev: carolGenesis);
    final carolRemoved = await phone.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_carol'),
      version: 3,
      prevHash: head2.listHash,
      createdAtMs: 3,
      change: DeviceListChange.remove,
      entries: [DeviceListPair(idBytes('dev_phone'), phoneKey)],
      frankKeys: [DeviceListFrankKey(idBytes('dev_phone'), phoneFrank)],
    ));
    final erinGenesis = await erin.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_erin'),
      version: 1,
      prevHash: DeviceListBody.zeroHash,
      createdAtMs: 1,
      change: DeviceListChange.migrationGenesis,
      entries: [DeviceListPair(idBytes('dev_erin'), erinKey)],
      frankKeys: [
        DeviceListFrankKey(
            idBytes('dev_erin'), await erin.service.currentFrankKey()),
      ],
    ));
    final chains = <String, List<Uint8List>>{
      'acct_carol': [carolGenesis, carolSetsPhone, carolRemoved],
      'acct_erin': [erinGenesis],
      'acct_alice': const <Uint8List>[],
    };
    // Every statement is format 2: "VDL1" then the format byte.
    for (final statement in chains.values.expand((chain) => chain)) {
      expect(String.fromCharCodes(statement.sublist(0, 4)), 'VDL1');
      expect(statement[4], 2);
    }

    final pins = _RecordingPins(
        store: dave.store, source: _Chains(chains), verifier: dave.service);
    dave.service.deviceListPins = pins;

    C7HistoryRow row(String id, String device) => C7HistoryRow(
          messageId: id,
          senderDeviceId: device,
          actionId: 'act_$id',
          channelId: 'chan_1',
          createdAt: DateTime.utc(2026, 11, 12),
          epoch: 1,
          body: Uint8List.fromList(<int>[1, 2, 3]),
        );
    await dave.service.c7ImportHistory(
      'conv_1',
      groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
      channels: <String, C7HistoryPage>{
        'chan_1': C7HistoryPage(<C7HistoryRow>[
          row('m1', 'dev_carol'),
          row('m2', 'dev_erin'),
          row('m3', 'dev_mallory'),
        ], complete: true),
      },
      formerKeys: <C7FormerKey>[
        // Carol's own list had the device with this key, then removed it:
        // named (a former device is still hers).
        C7FormerKey(
            deviceId: 'dev_carol',
            accountId: 'acct_carol',
            signingKey: carolKey),
        // Erin's list has her device now: named.
        C7FormerKey(
            deviceId: 'dev_erin', accountId: 'acct_erin', signingKey: erinKey),
        // The server names Carol for a device her list never had.
        C7FormerKey(
            deviceId: 'dev_mallory',
            accountId: 'acct_carol',
            signingKey: erinKey),
      ],
    );
    expect(pins.verdicts, {
      'acct_carol/dev_carol': LeafVerdict.removed,
      'acct_erin/dev_erin': LeafVerdict.approved,
      'acct_carol/dev_mallory': LeafVerdict.unapproved,
    });

    // The server naming another account for Carol's device (review M2):
    // that account's list never had it, so nothing is proven.
    pins.verdicts.clear();
    await dave.service.c7ImportHistory(
      'conv_2',
      groupLevel: const C7HistoryPage(<C7HistoryRow>[], complete: true),
      channels: <String, C7HistoryPage>{
        'chan_1': C7HistoryPage(<C7HistoryRow>[row('m4', 'dev_carol')],
            complete: true),
      },
      formerKeys: <C7FormerKey>[
        C7FormerKey(
            deviceId: 'dev_carol',
            accountId: 'acct_erin',
            signingKey: carolKey),
      ],
    );
    expect(pins.verdicts, {'acct_erin/dev_carol': LeafVerdict.unapproved});
  }, skip: skip);
}

class _RecordingPins extends DeviceListPins {
  _RecordingPins(
      {required super.store, required super.source, required super.verifier});

  final Map<String, LeafVerdict> verdicts = <String, LeafVerdict>{};

  @override
  Future<LeafVerdict> judge(
      List<int> accountId, List<int> deviceId, List<int> signingKey,
      {bool refreshFirst = true}) async {
    final verdict = await super
        .judge(accountId, deviceId, signingKey, refreshFirst: refreshFirst);
    verdicts['${String.fromCharCodes(accountId)}/'
        '${String.fromCharCodes(deviceId)}'] = verdict;
    return verdict;
  }
}

class _Chains implements DeviceListSource {
  _Chains(this.chains);
  final Map<String, List<Uint8List>> chains;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
      {required int after}) async {
    final chain = chains[accountId] ?? const <Uint8List>[];
    return DeviceListPage(
      headVersion: chain.length,
      more: false,
      statements: [
        for (var i = after; i < chain.length; i++)
          (version: i + 1, statement: chain[i]),
      ],
    );
  }
}

class _Device {
  _Device(this.service, this.store);
  final NativeCryptoService service;
  final MemoryLocalStore store;

  static Future<_Device> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    ));
    return _Device(service, local);
  }
}
