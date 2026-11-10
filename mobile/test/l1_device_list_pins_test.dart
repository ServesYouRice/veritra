import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// L1-3: the pins, against the shared vector chains and real signatures.
/// The server is a fake that serves whatever statements a test hands it, so
/// every case is "what a malicious or broken server could send".
class _Verifier implements DeviceListVerifier {
  _Verifier(this.bindings);
  final NativeCryptoBindings bindings;

  @override
  DeviceListChainResult checkChain(
          String accountId, List<List<int>> statements) =>
      bindings.checkDeviceListChain(idBytes(accountId), statements);

  @override
  DeviceListSummary checkStep({
    required String accountId,
    required List<int>? prev,
    required List<int> statement,
    required List<DeviceListPair> history,
  }) =>
      bindings.checkDeviceListStep(
          expectedAccountId: idBytes(accountId),
          prev: prev,
          statement: statement,
          history: history);
}

class _Server implements DeviceListSource {
  List<Uint8List> chain = <Uint8List>[];
  bool unknown = false;
  bool fail = false;
  int fetches = 0;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
      {required int after}) async {
    fetches++;
    if (fail) throw const SocketException('down');
    if (unknown) return null;
    final rest = chain.skip(after).toList();
    return DeviceListPage(
      headVersion: chain.length,
      more: false,
      statements: [
        for (var i = 0; i < rest.length; i++)
          (version: after + i + 1, statement: rest[i]),
      ],
    );
  }
}

void main() {
  // Skipped without the library, unless VERITRA_REQUIRE_NATIVE_CRYPTO=1.
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  late Map<String, dynamic> vector;
  late MemoryLocalStore store;
  late _Server server;
  late DeviceListPins pins;
  var now = DateTime.utc(2026, 11, 7, 12);

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  List<Map<String, dynamic>> chainSteps(int index) =>
      (((vector['outputs'] as Map)['chains'] as List)[index]
              as Map<String, dynamic>)['steps']
          .cast<Map<String, dynamic>>();

  List<Uint8List> statements(int index) =>
      [for (final step in chainSteps(index)) hex(step['statement_hex'])];

  String account(int index) =>
      (((vector['outputs'] as Map)['chains'] as List)[index]
          as Map<String, dynamic>)['account_id'] as String;

  Map<String, Uint8List> keysOf(int index) => {
        for (final step in chainSteps(index))
          for (final entry
              in (step['entries'] as List).cast<Map<String, dynamic>>())
            entry['device_id'] as String: hex(entry['signing_key_hex']),
      };

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    vector = jsonDecode(File('../testing/vectors/l1-device-list-v1.json')
        .readAsStringSync()) as Map<String, dynamic>;
    store = MemoryLocalStore();
    server = _Server();
    now = DateTime.utc(2026, 11, 7, 12);
    pins = DeviceListPins(
      store: store,
      source: server,
      verifier: _Verifier(bindings),
      clock: () => now,
    );
  });

  void later() => now = now.add(const Duration(minutes: 2));

  /// One genesis by dev_alice of acct_fork and two validly signed version
  /// 2s that each add another device: a real fork, which takes a key the
  /// pinned list holds.
  ({Uint8List genesis, Uint8List left, Uint8List right, Uint8List aliceKey})
      forkOf() {
    final alice = bindings.createDevice('acct_fork', 'dev_alice');
    final bob = bindings.createDevice('acct_fork', 'dev_bob');
    final carol = bindings.createDevice('acct_fork', 'dev_carol');
    addTearDown(alice.close);
    addTearDown(bob.close);
    addTearDown(carol.close);
    final aliceKey = Uint8List.fromList(alice.signingPublicKey());
    final genesis = alice.signDeviceList(
        DeviceListBody(
          accountId: idBytes('acct_fork'),
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.genesis,
          entries: [DeviceListPair(idBytes('dev_alice'), aliceKey)],
        ),
        idBytes('dev_alice'));
    final head = bindings.checkDeviceListStep(
        expectedAccountId: idBytes('acct_fork'), statement: genesis);
    Uint8List add(String id, List<int> key) => alice.signDeviceList(
        DeviceListBody(
          accountId: idBytes('acct_fork'),
          version: 2,
          prevHash: head.listHash,
          createdAtMs: 2,
          change: DeviceListChange.add,
          entries: [
            DeviceListPair(idBytes('dev_alice'), aliceKey),
            DeviceListPair(idBytes(id), key),
          ],
        ),
        idBytes('dev_alice'));
    return (
      genesis: genesis,
      left: add('dev_bob', bob.signingPublicKey()),
      right: add('dev_carol', carol.signingPublicKey()),
      aliceKey: aliceKey,
    );
  }

  group('refresh', () {
    test('first sight pins the whole chain with every pair it listed',
        () async {
      server.chain = statements(0);
      final status = await pins.refresh(account(0));
      expect(status.state, DeviceListState.ok);
      final pin = (await store.loadDeviceListPin(account(0)))!;
      expect(pin.version, 8);
      expect(pin.headStatement, server.chain.last);
      final keys = keysOf(0);
      // a0 was removed by the recovery version (6); d3 is listed.
      expect(
          pin.standing(
              idBytes('dev_a0a0a0a0a0a0a0a0'), keys['dev_a0a0a0a0a0a0a0a0']!),
          PinStanding.removed);
      expect(
          pin.standing(
              idBytes('dev_d3d3d3d3d3d3d3d3'), keys['dev_d3d3d3d3d3d3d3d3']!),
          PinStanding.approved);
      expect(pin.recoveryKey, isNotNull);
    });

    test('later versions move the pin forward step by step', () async {
      final full = statements(0);
      server.chain = full.sublist(0, 3);
      await pins.refresh(account(0));
      expect((await store.loadDeviceListPin(account(0)))!.version, 3);
      later();
      server.chain = full;
      final status = await pins.refresh(account(0));
      expect(status.state, DeviceListState.ok);
      final pin = (await store.loadDeviceListPin(account(0)))!;
      expect(pin.version, 8);
      final keys = keysOf(0);
      // b1 was removed at version 5 (seen as a step, not a whole chain).
      expect(
          pin.keys
              .firstWhere(
                  (key) => utf8.decode(key.deviceId) == 'dev_b1b1b1b1b1b1b1b1')
              .removedVersion,
          isNonZero);
      expect(
          pin.standing(
              idBytes('dev_e4e4e4e4e4e4e4e4'), keys['dev_e4e4e4e4e4e4e4e4']!),
          PinStanding.approved);
    });

    test('a lower head never replaces the pin', () async {
      server.chain = statements(0);
      await pins.refresh(account(0));
      later();
      server.chain = statements(0).sublist(0, 4);
      final status = await pins.refresh(account(0));
      expect(status.state, DeviceListState.ok);
      expect((await store.loadDeviceListPin(account(0)))!.version, 8);
    });

    test('a damaged version after the pin changes nothing', () async {
      final full = statements(0);
      server.chain = full.sublist(0, 2);
      await pins.refresh(account(0));
      later();
      final bad = Uint8List.fromList(full[2]);
      bad[bad.length - 1] ^= 1; // the signature
      server.chain = [...full.sublist(0, 2), bad, ...full.sublist(3)];
      await pins.refresh(account(0));
      final pin = (await store.loadDeviceListPin(account(0)))!;
      expect(pin.version, 2);
      expect(pin.conflict, isFalse);
    });

    test('a damaged first chain pins nothing (unavailable)', () async {
      final full = statements(0);
      final bad = Uint8List.fromList(full[1]);
      bad[bad.length - 1] ^= 1;
      server.chain = [full[0], bad];
      final status = await pins.refresh(account(0));
      expect(status.state, DeviceListState.unavailable);
      expect(await store.loadDeviceListPin(account(0)), isNull);
    });

    test('another chain of another account is refused', () async {
      server.chain = statements(0);
      final status = await pins.refresh('acct_someone_else');
      expect(status.state, DeviceListState.unavailable);
      expect(await store.loadDeviceListPin('acct_someone_else'), isNull);
    });

    test('no list, an unknown account and a dead server', () async {
      expect((await pins.refresh(account(0))).state, DeviceListState.empty);
      later();
      server.unknown = true;
      expect(
          (await pins.refresh(account(0))).state, DeviceListState.unavailable);
      later();
      server.fail = true;
      expect(
          (await pins.refresh(account(0))).state, DeviceListState.unavailable);
    });

    test('a chain from another genesis is not adopted and not sticky',
        () async {
      // Both vector chains belong to the same account with different
      // genesis versions: a server alone could make up the second. The pin
      // stays, nothing is sticky, and the honest chain carries on.
      server.chain = statements(0).sublist(0, 3);
      await pins.refresh(account(0));
      later();
      server.chain = statements(1);
      final status = await pins.refresh(account(0));
      expect(status.state, DeviceListState.ok);
      final pin = (await store.loadDeviceListPin(account(0)))!;
      expect(pin.conflict, isFalse);
      expect(pin.version, 3);
      expect(pin.headStatement, statements(0)[2]);
      later();
      server.chain = statements(0);
      expect((await pins.refresh(account(0))).state, DeviceListState.ok);
      expect((await store.loadDeviceListPin(account(0)))!.version, 8);
    });

    test('a validly signed fork of the pinned chain is a sticky conflict',
        () async {
      final fork = forkOf();
      server.chain = [fork.genesis, fork.left];
      await pins.refresh('acct_fork');
      later();
      server.chain = [fork.genesis, fork.right];
      expect((await pins.refresh('acct_fork')).state, DeviceListState.conflict);
      later();
      // Sticky: the pinned branch again does not clear it.
      server.chain = [fork.genesis, fork.left];
      expect((await pins.refresh('acct_fork')).state, DeviceListState.conflict);
      expect((await store.loadDeviceListPin('acct_fork'))!.version, 2);
    });

    test('refreshes at most once a minute unless forced', () async {
      server.chain = statements(0);
      await pins.refresh(account(0));
      await pins.refresh(account(0));
      expect(server.fetches, 1);
      await pins.refresh(account(0), force: true);
      expect(server.fetches, 2);
      pins.invalidate(account(0));
      await pins.refresh(account(0));
      expect(server.fetches, 3);
    });
  }, skip: skip);

  group('judge and the add gate', () {
    test('verdicts follow the pin', () async {
      server.chain = statements(0);
      final keys = keysOf(0);
      final acct = idBytes(account(0));
      Future<LeafVerdict> judge(String device, Uint8List key) =>
          pins.judge(acct, idBytes(device), key);
      expect(await judge('dev_d3d3d3d3d3d3d3d3', keys['dev_d3d3d3d3d3d3d3d3']!),
          LeafVerdict.approved);
      expect(await judge('dev_a0a0a0a0a0a0a0a0', keys['dev_a0a0a0a0a0a0a0a0']!),
          LeafVerdict.removed);
      // A listed id with a key the list never named: a ghost.
      expect(await judge('dev_d3d3d3d3d3d3d3d3', Uint8List(32)..[0] = 9),
          LeafVerdict.unapproved);
      expect(await judge('dev_ghost', Uint8List(32)..[0] = 7),
          LeafVerdict.unapproved);
      // Ids nobody can spell are never approved.
      expect(
          await pins.judge(
              [0xff, 0xfe], idBytes('dev_d3d3d3d3d3d3d3d3'), Uint8List(32)),
          LeafVerdict.unapproved);
    });

    test(
        'a device added within a minute of the last fetch is approved, not '
        'judged on the stale pin (review fix)', () async {
      final full = statements(0);
      final keys = keysOf(0);
      server.chain = full.sublist(0, 3);
      await pins.refresh(account(0));
      final e4 = keys['dev_e4e4e4e4e4e4e4e4']!;
      expect(
          (await store.loadDeviceListPin(account(0)))!
              .standing(idBytes('dev_e4e4e4e4e4e4e4e4'), e4),
          PinStanding.unknown);
      // The account links a device 30 s later; its leaf arrives at once.
      now = now.add(const Duration(seconds: 30));
      server.chain = full;
      expect(
          await pins.judge(
              idBytes(account(0)), idBytes('dev_e4e4e4e4e4e4e4e4'), e4),
          LeafVerdict.approved);
      expect(await pins.approvedKey(account(0), 'dev_e4e4e4e4e4e4e4e4'), e4);
      // A ghost the list never names forces at most one fetch per
      // [minForcedRefresh] per account.
      final before = server.fetches;
      for (var i = 0; i < 5; i++) {
        expect(
            await pins.judge(idBytes(account(0)), idBytes('dev_ghost'),
                Uint8List(32)..[0] = 7),
            LeafVerdict.unapproved);
      }
      expect(server.fetches, before);
      now = now.add(const Duration(seconds: 6));
      await pins.judge(
          idBytes(account(0)), idBytes('dev_ghost'), Uint8List(32)..[0] = 7);
      expect(server.fetches, before + 1);
    });

    test('an account with no list or an unreachable one is checking', () async {
      expect(
          await pins.judge(
              idBytes('acct_x'), idBytes('dev_x'), Uint8List(32)..[0] = 1),
          LeafVerdict.checking);
      server.fail = true;
      later();
      expect(
          await pins.judge(
              idBytes('acct_y'), idBytes('dev_y'), Uint8List(32)..[0] = 1),
          LeafVerdict.checking);
    });

    test('a conflicted account is unapproved', () async {
      final fork = forkOf();
      server.chain = [fork.genesis, fork.left];
      await pins.refresh('acct_fork');
      later();
      server.chain = [fork.genesis, fork.right];
      await pins.refresh('acct_fork');
      later();
      expect(
          await pins.judge(
              idBytes('acct_fork'), idBytes('dev_alice'), fork.aliceKey),
          LeafVerdict.unapproved);
    });

    test('the add gate returns only the pinned key, and none for removed',
        () async {
      server.chain = statements(0);
      final keys = keysOf(0);
      expect(await pins.approvedKey(account(0), 'dev_e4e4e4e4e4e4e4e4'),
          keys['dev_e4e4e4e4e4e4e4e4']);
      expect(
          await pins.approvedKey(account(0), 'dev_a0a0a0a0a0a0a0a0'), isNull);
      expect(await pins.approvedKey(account(0), 'dev_ghost'), isNull);
      expect(await pins.approvedKey('acct_no_list', 'dev_x'), isNull);
    });
  }, skip: skip);

  group('own versions', () {
    test('a device signs its genesis and an add; both pin forward', () async {
      final alice = bindings.createDevice('acct_own', 'dev_alice');
      final bob = bindings.createDevice('acct_own', 'dev_bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      final aliceKey = Uint8List.fromList(alice.signingPublicKey());
      final bobKey = Uint8List.fromList(bob.signingPublicKey());
      final genesis = alice.signDeviceList(
          DeviceListBody(
            accountId: idBytes('acct_own'),
            version: 1,
            prevHash: DeviceListBody.zeroHash,
            createdAtMs: 1,
            change: DeviceListChange.genesis,
            entries: [DeviceListPair(idBytes('dev_alice'), aliceKey)],
          ),
          idBytes('dev_alice'));
      final pinned =
          await pins.pinChain('acct_own', [genesis], expectedHead: genesis);
      expect(pinned.version, 1);
      final add = alice.signDeviceList(
          DeviceListBody(
            accountId: idBytes('acct_own'),
            version: 2,
            prevHash: pinned.listHash,
            createdAtMs: 2,
            change: DeviceListChange.add,
            entries: [
              DeviceListPair(idBytes('dev_alice'), aliceKey),
              DeviceListPair(idBytes('dev_bob'), bobKey),
            ],
          ),
          idBytes('dev_alice'));
      expect(await pins.pinOwnStep('acct_own', add), isTrue);
      final pin = (await store.loadDeviceListPin('acct_own'))!;
      expect(pin.version, 2);
      expect(pin.standing(idBytes('dev_bob'), bobKey), PinStanding.approved);
      // A refresh can pin our accepted step before its POST returns.
      expect(await pins.pinOwnStep('acct_own', add), isFalse);
      expect((await store.loadDeviceListPin('acct_own'))!.headStatement, add);
      // A different statement at that version still fails verification.
      final changed = Uint8List.fromList(add);
      changed[changed.length - 1] ^= 1;
      expect(() => pins.pinOwnStep('acct_own', changed),
          throwsA(isA<NativeCryptoException>()));
      expect((await store.loadDeviceListPin('acct_own'))!.headStatement, add);
    });

    test('pinChain refuses a chain that does not end in the head', () async {
      server.chain = statements(0);
      expect(
          () => pins.pinChain(account(0), statements(0),
              expectedHead: statements(0)[2]),
          throwsFormatException);
    });
  }, skip: skip);
}
