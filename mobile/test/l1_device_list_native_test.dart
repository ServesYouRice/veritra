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

  DeviceListPair pairOf(Map<String, dynamic> json) => DeviceListPair(
      idBytes(json['device_id'] as String), hex(json['signing_key_hex']));

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
              expectedAccountId: idBytes(chain['account_id'] as String),
              prev: previous,
              statement: statement,
              history: history);
          expect(summary.version, step['version']);
          expect(summary.change.code, step['change']);
          expect(summary.listHash, hex(step['list_hash_hex']));
          expect(summary.signerKind, step['signer_kind']);
          expect(summary.signerDeviceId,
              idBytes(step['signer_device_id'] as String));
          expect(summary.accountId, idBytes(chain['account_id'] as String));
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
        final whole = bindings
            .checkDeviceListChain(idBytes(chain['account_id'] as String), [
          for (final step in steps) hex(step['statement_hex']),
        ]);
        // The same valid chain, asked for as another account, is refused.
        expect(
            () => bindings.checkDeviceListChain(idBytes('acct_other'), [
                  for (final step in steps) hex(step['statement_hex']),
                ]),
            failsWith(NativeCryptoError.deviceListChain));
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
              expectedAccountId:
                  idBytes(refused['expected_account_id'] as String),
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

    test('a chain of another account is refused, whole and step by step', () {
      final cases = ((vector['outputs'] as Map)['refused_chains'] as List)
          .cast<Map<String, dynamic>>();
      expect(cases.map((c) => c['name']), contains('chain of another account'));
      for (final refused in cases) {
        final packed = hex(refused['chain_hex']);
        // chain_hex is u16 count | count x (u16 len | statement).
        final statements = <Uint8List>[];
        var offset = 2;
        while (offset < packed.length) {
          final length = (packed[offset] << 8) | packed[offset + 1];
          statements.add(
              Uint8List.sublistView(packed, offset + 2, offset + 2 + length));
          offset += 2 + length;
        }
        expect(
            () => bindings.checkDeviceListChain(
                idBytes(refused['expected_account_id'] as String), statements),
            failsWith(NativeCryptoError.deviceListChain),
            reason: refused['name'] as String);
        // The first version alone (a genesis) is refused the same way.
        expect(
            () => bindings.checkDeviceListStep(
                expectedAccountId:
                    idBytes(refused['expected_account_id'] as String),
                statement: statements.first),
            failsWith(NativeCryptoError.deviceListChain),
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
    final acctA = idBytes('acct_a');
    DeviceListPair pairFor(NativeCryptoDevice device, String id) =>
        DeviceListPair(idBytes(id), device.signingPublicKey());

    test('sign a genesis and a chain, and refuse what is not theirs', () {
      final alice = bindings.createDevice('acct_a', 'dev_a1');
      final bob = bindings.createDevice('acct_a', 'dev_b1');
      final aliceKey = pairFor(alice, 'dev_a1');
      final bobKey = pairFor(bob, 'dev_b1');
      final genesisBody = DeviceListBody(
        accountId: acctA,
        version: 1,
        prevHash: DeviceListBody.zeroHash,
        createdAtMs: 1700000000000,
        change: DeviceListChange.genesis,
        entries: [aliceKey],
      );
      final genesis = alice.signDeviceList(genesisBody, idBytes('dev_a1'));
      final first = bindings.checkDeviceListStep(
          expectedAccountId: acctA, statement: genesis);
      expect(first.change, DeviceListChange.genesis);
      expect(first.entries, [aliceKey]);

      // A genesis for another device, or another account, is refused.
      expect(() => bob.signDeviceList(genesisBody, idBytes('dev_b1')),
          failsWith(NativeCryptoError.deviceListRule));
      final foreign = DeviceListBody(
        accountId: idBytes('acct_z'),
        version: 1,
        prevHash: DeviceListBody.zeroHash,
        createdAtMs: 1,
        change: DeviceListChange.genesis,
        entries: [aliceKey],
      );
      expect(() => alice.signDeviceList(foreign, idBytes('dev_a1')),
          failsWith(NativeCryptoError.deviceListRule));

      // Alice adds Bob; Bob, now listed, sets a recovery key.
      final add = alice.signDeviceList(
        DeviceListBody(
          accountId: acctA,
          version: 2,
          prevHash: first.listHash,
          createdAtMs: 1700000001000,
          change: DeviceListChange.add,
          entries: [aliceKey, bobKey],
        ),
        idBytes('dev_a1'),
      );
      final second = bindings.checkDeviceListStep(
          expectedAccountId: acctA,
          prev: genesis,
          statement: add,
          history: [aliceKey]);
      expect(second.entries, hasLength(2));
      final entropy = Uint8List.fromList(List<int>.filled(30, 0x21));
      final listKey = bindings.deriveRecoveryKey(entropy).rkListPub;
      final withKey = bob.signDeviceList(
        DeviceListBody(
          accountId: acctA,
          version: 3,
          prevHash: second.listHash,
          createdAtMs: 1700000002000,
          change: DeviceListChange.recoveryKey,
          entries: [aliceKey, bobKey],
          recoveryKey: listKey,
        ),
        idBytes('dev_b1'),
      );
      final head = bindings.checkDeviceListStep(
          expectedAccountId: acctA,
          prev: add,
          statement: withKey,
          history: [aliceKey, bobKey]);
      expect(head.recoveryKey, listKey);

      // A device that is not listed signs a statement the check refuses.
      final carol = bindings.createDevice('acct_a', 'dev_c1');
      final carolKey = pairFor(carol, 'dev_c1');
      final unlisted = carol.signDeviceList(
        DeviceListBody(
          accountId: acctA,
          version: 4,
          prevHash: head.listHash,
          createdAtMs: 1700000003000,
          change: DeviceListChange.add,
          entries: [aliceKey, bobKey, carolKey],
          recoveryKey: listKey,
        ),
        idBytes('dev_c1'),
      );
      expect(
          () => bindings.checkDeviceListStep(
              expectedAccountId: acctA,
              prev: withKey,
              statement: unlisted,
              history: [aliceKey, bobKey]),
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
          accountId: acctA,
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.genesis,
          entries: [oldKey],
        ),
        idBytes('dev_a1'),
      );
      final genesisSummary = bindings.checkDeviceListStep(
          expectedAccountId: acctA, statement: genesis);
      final head = old.signDeviceList(
        DeviceListBody(
          accountId: acctA,
          version: 2,
          prevHash: genesisSummary.listHash,
          createdAtMs: 2,
          change: DeviceListChange.recoveryKey,
          entries: [oldKey],
          recoveryKey: listKey,
        ),
        idBytes('dev_a1'),
      );
      final headSummary = bindings.checkDeviceListStep(
          expectedAccountId: acctA,
          prev: genesis,
          statement: head,
          history: [oldKey]);
      final body = DeviceListBody(
        accountId: acctA,
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
          expectedAccountId: acctA,
          prev: head,
          statement: signed,
          history: [oldKey]);
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
        LeafPair(idBytes('acct_alice'), idBytes('dev_alice'),
            alice.signingPublicKey()),
        LeafPair(
            idBytes('acct_bob'), idBytes('dev_bob'), bob.signingPublicKey()),
      ]);

      final carolPackage = carol.createKeyPackage();
      expect(
          () => alice.stageCommitKeyed('conv_l1', adds: [
                (
                  keyPackage: carolPackage,
                  accountId: idBytes('acct_carol'),
                  deviceId: idBytes('dev_carol'),
                  signingKey: List<int>.filled(32, 0xEE),
                ),
              ]),
          failsWith(NativeCryptoError.operationFailed));
      expect(alice.groupEpoch('conv_l1').pending, isFalse);
      final staged = alice.stageCommitKeyed('conv_l1', adds: [
        (
          keyPackage: carolPackage,
          accountId: idBytes('acct_carol'),
          deviceId: idBytes('dev_carol'),
          signingKey: carol.signingPublicKey(),
        ),
      ]);
      final own = alice.mergePendingCommitWithPairs('conv_l1');
      expect(own.added, isTrue);
      expect(own.removed, isFalse);
      expect(own.root, isNull);
      expect(own.addedLeaves, [
        LeafPair(idBytes('acct_carol'), idBytes('dev_carol'),
            carol.signingPublicKey())
      ]);
      expect(
          own.committer,
          LeafPair(idBytes('acct_alice'), idBytes('dev_alice'),
              alice.signingPublicKey()));
      final seen = bob.processCommitWithPairs('conv_l1', staged.commit);
      expect(seen.epoch, own.epoch);
      expect(seen.addedLeaves, own.addedLeaves);
      expect(seen.committer, own.committer);
      expect(bob.groupMembers('conv_l1'), hasLength(3));
      for (final device in [alice, bob, carol]) {
        device.close();
      }
    }, skip: nativeCryptoSkip());

    test('an Add with a non-UTF-8 id is merged and reported, never thrown', () {
      // D94: apply the commit, then hold. A member can commit an Add whose
      // credential ids are not UTF-8 (Rust only checks their lengths), and
      // the commit is already merged when the pairs come back. Dart must
      // return them as bytes, not throw after the merge.
      final badAccount = [0xc3, 0x28, 0x5f, 0x61]; // not UTF-8
      final badDevice = [0xff, 0xfe]; // not UTF-8
      expect(() => utf8.decode(badAccount), throwsFormatException);
      expect(() => utf8.decode(badDevice), throwsFormatException);
      final alice = bindings.createDevice('acct_alice', 'dev_alice');
      final bob = bindings.createDevice('acct_bob', 'dev_bob');
      // `createDevice` writes each character as one byte.
      final mallory = bindings.createDevice(
          String.fromCharCodes(badAccount), String.fromCharCodes(badDevice));
      alice.createGroup('conv_l1_bytes');
      final bobAdd = alice.addMember(
          'conv_l1_bytes', bob.createKeyPackage(), 'acct_bob', 'dev_bob');
      bob.joinGroup('conv_l1_bytes', bobAdd.welcome);

      final staged = alice.stageCommitKeyed('conv_l1_bytes', adds: [
        (
          keyPackage: mallory.createKeyPackage(),
          accountId: badAccount,
          deviceId: badDevice,
          signingKey: mallory.signingPublicKey(),
        ),
      ]);
      final malloryLeaf =
          LeafPair(badAccount, badDevice, mallory.signingPublicKey());
      final seen = bob.processCommitWithPairs('conv_l1_bytes', staged.commit);
      expect(seen.unreadable, isFalse);
      expect(seen.epoch, 2);
      expect(seen.added, isTrue);
      expect(seen.addedLeaves, [malloryLeaf]);
      expect(seen.addedLeaves.single.deviceId, badDevice);
      expect(
          seen.committer,
          LeafPair(idBytes('acct_alice'), idBytes('dev_alice'),
              alice.signingPublicKey()));
      expect(bob.groupEpoch('conv_l1_bytes').epoch, 2,
          reason: 'the commit is applied');
      final own = alice.mergePendingCommitWithPairs('conv_l1_bytes');
      expect(own.addedLeaves, [malloryLeaf]);
      // The members read back as bytes too.
      expect(bob.groupMembers('conv_l1_bytes').last, malloryLeaf);

      // The leaf can be removed by its bytes: a String could never name it.
      final removal = alice.stageCommitKeyed('conv_l1_bytes', removes: [
        (accountId: badAccount, deviceId: badDevice),
      ]);
      final removed =
          bob.processCommitWithPairs('conv_l1_bytes', removal.commit);
      expect(removed.removed, isTrue);
      expect(removed.root, isNotNull);
      expect(removed.unreadable, isFalse);
      expect(bob.groupMembers('conv_l1_bytes'), hasLength(2));
      for (final device in [alice, bob, mallory]) {
        device.close();
      }
    }, skip: nativeCryptoSkip());
  });
}
