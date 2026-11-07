import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// L1 (ABI 14): the approved-device list through the native calls, against
/// the shared vector testing/vectors/l1-device-list-v1.json that the Rust
/// core and the Go server tests check too, plus real devices signing,
/// holding a recovery seed and reading group leaves.
void main() {
  late NativeCryptoBindings bindings;
  late Map<String, dynamic> vector;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  DeviceListPair pairOf(Map<String, dynamic> json) =>
      DeviceListPair(json['device_id'] as String, hex(json['signing_key_hex']));

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    // A missing vector fails the test; it never skips.
    vector = jsonDecode(File('../testing/vectors/l1-device-list-v1.json')
        .readAsStringSync()) as Map<String, dynamic>;
  });

  Matcher failsWith(NativeCryptoError kind) =>
      throwsA(isA<NativeCryptoException>().having((e) => e.kind, 'kind', kind));

  group('vector', () {
    test('every chain verifies step by step and whole', () {
      final chains = (vector['outputs'] as Map)['chains'] as List;
      expect(chains, hasLength(2));
      for (final chain in chains.cast<Map<String, dynamic>>()) {
        final steps = (chain['steps'] as List).cast<Map<String, dynamic>>();
        List<int>? previous;
        final history = <DeviceListPair>[];
        for (final step in steps) {
          final statement = hex(step['statement_hex']);
          final summary = bindings.checkDeviceListStep(
              prev: previous, statement: statement, history: history);
          expect(summary.version, step['version']);
          expect(summary.change.code, step['change']);
          expect(summary.listHash, hex(step['list_hash_hex']));
          expect(summary.signerKind, step['signer_kind']);
          expect(summary.signerDeviceId, step['signer_device_id']);
          expect(summary.entries,
              [for (final e in step['entries'] as List) pairOf(e)]);
          expect(
              summary.recoveryKey,
              step['recovery_key_hex'] == null
                  ? isNull
                  : hex(step['recovery_key_hex']));
          // The Dart encoder writes the body Rust signed, byte for byte.
          final rebuilt = DeviceListBody(
            accountId: summary.accountId,
            version: summary.version,
            prevHash: summary.prevHash,
            createdAtMs: summary.createdAtMs,
            change: summary.change,
            entries: summary.entries.reversed.toList(),
            recoveryKey: summary.recoveryKey,
          ).encode();
          expect(toHex(rebuilt), step['body_hex']);
          expect(
              toHex(assembleDeviceListStatement(
                body: rebuilt,
                signerKind: summary.signerKind,
                signerDeviceId: summary.signerDeviceId,
                signature: hex(step['signature_hex']),
              )),
              step['statement_hex']);
          for (final pair in summary.entries) {
            if (!history.contains(pair)) history.add(pair);
          }
          previous = statement;
        }
        final whole = bindings.checkDeviceListChain([
          for (final step in steps) hex(step['statement_hex']),
        ]);
        expect(whole.listId, hex(chain['list_id_hex']));
        expect(whole.head.version, chain['head_version']);
        final pairs = (chain['pairs'] as List).cast<Map<String, dynamic>>();
        expect(whole.pairs, hasLength(pairs.length));
        for (var i = 0; i < pairs.length; i++) {
          expect(whole.pairs[i].pair, pairOf(pairs[i]));
          expect(whole.pairs[i].addedVersion, pairs[i]['added_version']);
          expect(whole.pairs[i].removedVersion, pairs[i]['removed_version']);
        }
      }
    }, skip: nativeCryptoSkip());

    test('every refusal reports its one reason', () {
      final kinds = {
        'malformed': NativeCryptoError.deviceListMalformed,
        'chain': NativeCryptoError.deviceListChain,
        'rule': NativeCryptoError.deviceListRule,
        'signature': NativeCryptoError.deviceListSignature,
      };
      final cases = ((vector['outputs'] as Map)['refused'] as List)
          .cast<Map<String, dynamic>>();
      expect(cases.length, greaterThanOrEqualTo(60));
      for (final refused in cases) {
        final statement = hex(refused['statement_hex']);
        final run = () => bindings.checkDeviceListStep(
              prev:
                  refused['prev_hex'] == null ? null : hex(refused['prev_hex']),
              statement: statement,
              history: [
                for (final pair in refused['history'] as List) pairOf(pair)
              ],
            );
        if (statement.length > 4096) {
          // The binding refuses an oversize statement before the call.
          expect(run, throwsArgumentError, reason: refused['name'] as String);
          continue;
        }
        expect(run, failsWith(kinds[refused['error']]!),
            reason: refused['name'] as String);
      }
    }, skip: nativeCryptoSkip());

    test('the recovery list key matches the vector, apart from the K0 keys',
        () {
      final recovery = ((vector['inputs'] as Map)['recovery'] as List)
          .cast<Map<String, dynamic>>();
      for (final entry in recovery) {
        final derived = bindings.deriveRecoveryKey(hex(entry['entropy_hex']));
        expect(derived.rkListPub, hex(entry['rk_list_pub_hex']));
        expect(derived.rkListPub, isNot(derived.rkAuthPub));
        expect(derived.rkListPub, isNot(derived.rkPub));
      }
    }, skip: nativeCryptoSkip());
  });

  group('real devices', () {
    DeviceListPair pairFor(NativeCryptoDevice device, String id) =>
        DeviceListPair(id, device.signingPublicKey());

    test('sign a genesis and a chain, and refuse what is not theirs', () {
      final alice = bindings.createDevice('acct_a', 'dev_a1');
      final bob = bindings.createDevice('acct_a', 'dev_b1');
      final aliceKey = pairFor(alice, 'dev_a1');
      final bobKey = pairFor(bob, 'dev_b1');
      final genesisBody = DeviceListBody(
        accountId: 'acct_a',
        version: 1,
        prevHash: DeviceListBody.zeroHash,
        createdAtMs: 1700000000000,
        change: DeviceListChange.genesis,
        entries: [aliceKey],
      );
      final genesis = alice.signDeviceList(genesisBody, 'dev_a1');
      final first = bindings.checkDeviceListStep(statement: genesis);
      expect(first.change, DeviceListChange.genesis);
      expect(first.entries, [aliceKey]);

      // A genesis for another device, or another account, is refused.
      expect(() => bob.signDeviceList(genesisBody, 'dev_b1'),
          failsWith(NativeCryptoError.deviceListRule));
      final foreign = DeviceListBody(
        accountId: 'acct_z',
        version: 1,
        prevHash: DeviceListBody.zeroHash,
        createdAtMs: 1,
        change: DeviceListChange.genesis,
        entries: [aliceKey],
      );
      expect(() => alice.signDeviceList(foreign, 'dev_a1'),
          failsWith(NativeCryptoError.deviceListRule));

      // Alice adds Bob; Bob, now listed, sets a recovery key.
      final add = alice.signDeviceList(
        DeviceListBody(
          accountId: 'acct_a',
          version: 2,
          prevHash: first.listHash,
          createdAtMs: 1700000001000,
          change: DeviceListChange.add,
          entries: [aliceKey, bobKey],
        ),
        'dev_a1',
      );
      final second = bindings.checkDeviceListStep(
          prev: genesis, statement: add, history: [aliceKey]);
      expect(second.entries, hasLength(2));
      final entropy = Uint8List.fromList(List<int>.filled(30, 0x21));
      final listKey = bindings.deriveRecoveryKey(entropy).rkListPub;
      final withKey = bob.signDeviceList(
        DeviceListBody(
          accountId: 'acct_a',
          version: 3,
          prevHash: second.listHash,
          createdAtMs: 1700000002000,
          change: DeviceListChange.recoveryKey,
          entries: [aliceKey, bobKey],
          recoveryKey: listKey,
        ),
        'dev_b1',
      );
      final head = bindings.checkDeviceListStep(
          prev: add, statement: withKey, history: [aliceKey, bobKey]);
      expect(head.recoveryKey, listKey);

      // A device that is not listed signs a statement the check refuses.
      final carol = bindings.createDevice('acct_a', 'dev_c1');
      final carolKey = pairFor(carol, 'dev_c1');
      final unlisted = carol.signDeviceList(
        DeviceListBody(
          accountId: 'acct_a',
          version: 4,
          prevHash: head.listHash,
          createdAtMs: 1700000003000,
          change: DeviceListChange.add,
          entries: [aliceKey, bobKey, carolKey],
          recoveryKey: listKey,
        ),
        'dev_c1',
      );
      expect(
          () => bindings.checkDeviceListStep(
              prev: withKey, statement: unlisted, history: [aliceKey, bobKey]),
          failsWith(NativeCryptoError.deviceListRule));
      for (final device in [alice, bob, carol]) {
        device.close();
      }
    }, skip: nativeCryptoSkip());

    test('a recovered device signs change 4 from the held seed or the typed RK',
        () {
      final old = bindings.createDevice('acct_a', 'dev_a1');
      final recovered = bindings.createDevice('acct_a', 'dev_r1');
      final oldKey = pairFor(old, 'dev_a1');
      final recoveredKey = pairFor(recovered, 'dev_r1');
      final entropy = Uint8List.fromList(List<int>.filled(30, 0x21));
      final listKey = bindings.deriveRecoveryKey(entropy).rkListPub;
      final genesis = old.signDeviceList(
        DeviceListBody(
          accountId: 'acct_a',
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.genesis,
          entries: [oldKey],
        ),
        'dev_a1',
      );
      final genesisSummary = bindings.checkDeviceListStep(statement: genesis);
      final head = old.signDeviceList(
        DeviceListBody(
          accountId: 'acct_a',
          version: 2,
          prevHash: genesisSummary.listHash,
          createdAtMs: 2,
          change: DeviceListChange.recoveryKey,
          entries: [oldKey],
          recoveryKey: listKey,
        ),
        'dev_a1',
      );
      final headSummary = bindings.checkDeviceListStep(
          prev: genesis, statement: head, history: [oldKey]);
      final body = DeviceListBody(
        accountId: 'acct_a',
        version: 3,
        prevHash: headSummary.listHash,
        createdAtMs: 3,
        change: DeviceListChange.recovery,
        entries: [recoveredKey],
        recoveryKey: listKey,
      );

      // No seed held, none typed.
      expect(() => recovered.signRecoveryDeviceList(prev: head, body: body),
          failsWith(NativeCryptoError.deviceListNoSeed));
      expect(recovered.heldRecoveryListPublic(), isNull);
      // The held seed is the one the RK derives, and it signs once.
      recovered.holdRecoveryListSeed(entropy);
      expect(recovered.heldRecoveryListPublic(), listKey);
      final signed = recovered
          .signRecoveryDeviceList(prev: head, body: body, history: [oldKey]);
      final summary = bindings.checkDeviceListStep(
          prev: head, statement: signed, history: [oldKey]);
      expect(summary.change, DeviceListChange.recovery);
      expect(summary.signerKind, deviceListSignerRecovery);
      expect(summary.entries, [recoveredKey]);
      expect(recovered.heldRecoveryListPublic(), isNull);
      expect(() => recovered.signRecoveryDeviceList(prev: head, body: body),
          failsWith(NativeCryptoError.deviceListNoSeed));
      // The typed RK signs the same statement; another RK signs nothing.
      expect(
          recovered.signRecoveryDeviceList(
              prev: head, body: body, history: [oldKey], entropy: entropy),
          signed);
      expect(
          () => recovered.signRecoveryDeviceList(
              prev: head,
              body: body,
              history: [oldKey],
              entropy: Uint8List.fromList(List<int>.filled(30, 0x22))),
          failsWith(NativeCryptoError.deviceListSignature));
      // A seed held and then dropped is gone.
      recovered.holdRecoveryListSeed(entropy);
      expect(recovered.dropRecoveryListHold(), isTrue);
      expect(recovered.dropRecoveryListHold(), isFalse);
      old.close();
      recovered.close();
    }, skip: nativeCryptoSkip());

    test('leaves, keyed adds and the pairs a commit brings in', () {
      final alice = bindings.createDevice('acct_alice', 'dev_alice');
      final bob = bindings.createDevice('acct_bob', 'dev_bob');
      final carol = bindings.createDevice('acct_carol', 'dev_carol');
      alice.createGroup('conv_l1');
      final bobAdd = alice.addMember(
          'conv_l1', bob.createKeyPackage(), 'acct_bob', 'dev_bob');
      bob.joinGroup('conv_l1', bobAdd.welcome);
      expect(alice.groupMembers('conv_l1'), [
        LeafPair('acct_alice', 'dev_alice', alice.signingPublicKey()),
        LeafPair('acct_bob', 'dev_bob', bob.signingPublicKey()),
      ]);

      final carolPackage = carol.createKeyPackage();
      expect(
          () => alice.stageCommitKeyed('conv_l1', adds: [
                (
                  keyPackage: carolPackage,
                  accountId: 'acct_carol',
                  deviceId: 'dev_carol',
                  signingKey: List<int>.filled(32, 0xEE),
                ),
              ]),
          failsWith(NativeCryptoError.operationFailed));
      expect(alice.groupEpoch('conv_l1').pending, isFalse);
      final staged = alice.stageCommitKeyed('conv_l1', adds: [
        (
          keyPackage: carolPackage,
          accountId: 'acct_carol',
          deviceId: 'dev_carol',
          signingKey: carol.signingPublicKey(),
        ),
      ]);
      final own = alice.mergePendingCommitWithPairs('conv_l1');
      expect(own.added, isTrue);
      expect(own.removed, isFalse);
      expect(own.root, isNull);
      expect(own.addedLeaves,
          [LeafPair('acct_carol', 'dev_carol', carol.signingPublicKey())]);
      expect(own.committer,
          LeafPair('acct_alice', 'dev_alice', alice.signingPublicKey()));
      final seen = bob.processCommitWithPairs('conv_l1', staged.commit);
      expect(seen.epoch, own.epoch);
      expect(seen.addedLeaves, own.addedLeaves);
      expect(seen.committer, own.committer);
      expect(bob.groupMembers('conv_l1'), hasLength(3));
      for (final device in [alice, bob, carol]) {
        device.close();
      }
    }, skip: nativeCryptoSkip());
  });
}
