import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// L1: clearing a contact's sticky list conflict
/// ([DeviceListPins.trustServedBranch]) with real native signatures, on the
/// in-memory store and on the SQLite tables. The server is a fake that
/// serves whatever a test hands it: every refusal here is something a
/// malicious server could try with the reset.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  /// dev_alice of acct_fork signs a genesis and three different version 2s
  /// (a real fork takes a key the pinned list holds); a server-made chain
  /// for the same account starts from another genesis.
  _Fork forkOf() {
    NativeCryptoDevice device(String id) {
      final made = bindings.createDevice('acct_fork', id);
      addTearDown(made.close);
      return made;
    }

    final alice = device('dev_alice');
    final bob = device('dev_bob');
    final carol = device('dev_carol');
    final dave = device('dev_dave');
    final server = device('dev_server');
    final aliceKey = Uint8List.fromList(alice.signingPublicKey());
    Uint8List genesisBy(NativeCryptoDevice signer, String id) =>
        signer.signDeviceList(
          DeviceListBody(
            accountId: idBytes('acct_fork'),
            version: 1,
            prevHash: DeviceListBody.zeroHash,
            createdAtMs: 1,
            change: DeviceListChange.genesis,
            entries: [DeviceListPair(idBytes(id), signer.signingPublicKey())],
          ),
          idBytes(id),
        );
    final genesis = genesisBy(alice, 'dev_alice');
    final head = bindings.checkDeviceListStep(
      expectedAccountId: idBytes('acct_fork'),
      statement: genesis,
    );
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
          idBytes('dev_alice'),
        );
    final right = add('dev_carol', carol.signingPublicKey());
    final rightHead = bindings.checkDeviceListStep(
      expectedAccountId: idBytes('acct_fork'),
      prev: genesis,
      statement: right,
      history: [DeviceListPair(idBytes('dev_alice'), aliceKey)],
    );
    // A third version on the right branch: the carol device removes itself.
    final rightNext = carol.signDeviceList(
      DeviceListBody(
        accountId: idBytes('acct_fork'),
        version: 3,
        prevHash: rightHead.listHash,
        createdAtMs: 3,
        change: DeviceListChange.remove,
        entries: [DeviceListPair(idBytes('dev_alice'), aliceKey)],
      ),
      idBytes('dev_carol'),
    );
    return _Fork(
      genesis: genesis,
      left: add('dev_bob', bob.signingPublicKey()),
      right: right,
      rightNext: rightNext,
      third: add('dev_dave', dave.signingPublicKey()),
      madeUp: genesisBy(server, 'dev_server'),
      carolKey: Uint8List.fromList(carol.signingPublicKey()),
      bobKey: Uint8List.fromList(bob.signingPublicKey()),
    );
  }

  for (final kind in ['memory', 'sqlite']) {
    group('on $kind', () {
      late LocalStore store;
      late _Server server;
      late DeviceListPins pins;
      late _Fork fork;
      var now = DateTime.utc(2026, 11, 21, 12);

      void later() => now = now.add(const Duration(minutes: 2));

      setUp(() async {
        now = DateTime.utc(2026, 11, 21, 12);
        if (kind == 'memory') {
          store = MemoryLocalStore();
        } else {
          final db = EncryptedLocalDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          store = _DatabaseStore(db);
        }
        server = _Server();
        pins = DeviceListPins(
          store: store,
          source: server,
          verifier: _Verifier(bindings),
          clock: () => now,
        );
        fork = forkOf();
        // Pinned on the left branch; then a validly signed right branch.
        server.chain = [fork.genesis, fork.left];
        expect(
          (await pins.refresh('acct_fork')).state,
          DeviceListState.ok,
        );
        later();
        server.chain = [fork.genesis, fork.right];
        expect(
          (await pins.refresh('acct_fork')).state,
          DeviceListState.conflict,
        );
      });

      Future<void> expectStillConflicted() async {
        final pin = (await store.loadDeviceListPin('acct_fork'))!;
        expect(pin.conflict, isTrue);
        expect(pin.version, 2);
        expect(pin.headStatement, fork.left);
        expect(
          await pins.judge(
            idBytes('acct_fork'),
            idBytes('dev_bob'),
            fork.bobKey,
          ),
          LeafVerdict.unapproved,
        );
      }

      test('the proof of the fork is kept', () async {
        final proofs = await store.loadDeviceListConflicts('acct_fork');
        expect(proofs, hasLength(1));
        expect(proofs.single.version, 2);
        expect(proofs.single.pinnedStatement, fork.left);
        expect(proofs.single.otherStatement, fork.right);
      }, skip: skip);

      test(
        'one of the proven branches replaces the pin; the first-pin time '
        'restarts and the proof stays',
        () async {
          final before = (await store.loadDeviceListPin('acct_fork'))!;
          later();
          server.chain = [fork.genesis, fork.right, fork.rightNext];
          final pin = await pins.trustServedBranch('acct_fork');
          expect(pin.conflict, isFalse);
          expect(pin.version, 3);
          expect(pin.listId, before.listId);
          final stored = (await store.loadDeviceListPin('acct_fork'))!;
          expect(stored.conflict, isFalse);
          expect(stored.headStatement, fork.rightNext);
          expect(stored.pinnedAt, now.millisecondsSinceEpoch);
          expect(stored.pinnedAt, isNot(before.pinnedAt));
          expect(
            await store.loadDeviceListConflicts('acct_fork'),
            hasLength(1),
          );
          // The chosen branch's history: carol added, then removed itself.
          expect(
            await pins.judge(
              idBytes('acct_fork'),
              idBytes('dev_carol'),
              fork.carolKey,
              refreshFirst: false,
            ),
            LeafVerdict.removed,
          );
          expect(
            await pins.judge(
              idBytes('acct_fork'),
              idBytes('dev_bob'),
              fork.bobKey,
              refreshFirst: false,
            ),
            LeafVerdict.unapproved,
          );
          // It moves forward again as usual, and a later fork is sticky.
          later();
          expect(
            (await pins.refresh('acct_fork')).state,
            DeviceListState.ok,
          );
        },
        skip: skip,
      );

      test('the pinned branch itself may be chosen again', () async {
        later();
        server.chain = [fork.genesis, fork.left];
        final pin = await pins.trustServedBranch('acct_fork');
        expect(pin.headStatement, fork.left);
        expect(
          await pins.judge(
            idBytes('acct_fork'),
            idBytes('dev_bob'),
            fork.bobKey,
          ),
          LeafVerdict.approved,
        );
      }, skip: skip);

      test(
        'a chain from another genesis is refused: the reset is no TOFU',
        () async {
          later();
          server.chain = [fork.madeUp];
          await expectLater(
            pins.trustServedBranch('acct_fork'),
            throwsA(isA<DeviceListResetRefused>()),
          );
          await expectStillConflicted();
        },
        skip: skip,
      );

      test(
        'a third validly signed branch, not in the proof, is refused',
        () async {
          later();
          server.chain = [fork.genesis, fork.third];
          await expectLater(
            pins.trustServedBranch('acct_fork'),
            throwsA(isA<DeviceListResetRefused>()),
          );
          await expectStillConflicted();
        },
        skip: skip,
      );

      test('a chain shorter than the fork is refused', () async {
        later();
        server.chain = [fork.genesis];
        await expectLater(
          pins.trustServedBranch('acct_fork'),
          throwsA(isA<DeviceListResetRefused>()),
        );
        await expectStillConflicted();
      }, skip: skip);

      test(
        'a damaged statement or an unreachable server leaves the conflict '
        'and the pin; a later refresh is no first sight',
        () async {
          later();
          final damaged = Uint8List.fromList(fork.right);
          damaged[damaged.length - 1] ^= 0x01;
          server.chain = [fork.genesis, damaged];
          await expectLater(
            pins.trustServedBranch('acct_fork'),
            throwsA(isA<DeviceListResetRefused>()),
          );
          await expectStillConflicted();
          server.fail = true;
          await expectLater(
            pins.trustServedBranch('acct_fork'),
            throwsA(isA<DeviceListResetRefused>()),
          );
          server.unknown = true;
          server.fail = false;
          await expectLater(
            pins.trustServedBranch('acct_fork'),
            throwsA(isA<DeviceListResetRefused>()),
          );
          await expectStillConflicted();
          // The account was never left pinless: a server-made chain served
          // to an ordinary refresh now is not taken on first sight.
          server.unknown = false;
          server.chain = [fork.madeUp];
          later();
          expect(
            (await pins.refresh('acct_fork', force: true)).state,
            DeviceListState.conflict,
          );
          await expectStillConflicted();
        },
        skip: skip,
      );

      test('an account in no conflict has nothing to reset', () async {
        later();
        server.chain = [fork.genesis, fork.right];
        await pins.trustServedBranch('acct_fork');
        await expectLater(
          pins.trustServedBranch('acct_fork'),
          throwsA(isA<DeviceListResetRefused>()),
        );
        await expectLater(
          pins.trustServedBranch('acct_nobody'),
          throwsA(isA<DeviceListResetRefused>()),
        );
      }, skip: skip);

      test(
        'the store refuses a replacement with another list identity, or of '
        'a pin that is not in conflict',
        () async {
          later();
          server.chain = [fork.madeUp];
          final madeUp = _Verifier(bindings).checkChain(
            'acct_fork',
            [fork.madeUp],
          );
          final stored = (await store.loadDeviceListPin('acct_fork'))!;
          final swapped = DeviceListPin(
            accountId: 'acct_fork',
            version: madeUp.head.version,
            listHash: madeUp.head.listHash,
            listId: madeUp.listId,
            headStatement: fork.madeUp,
            conflict: false,
            checkedAt: 1,
            keys: const [],
          );
          expect(await store.replaceConflictedDeviceListPin(swapped), isFalse);
          await expectStillConflicted();
          final honest = DeviceListPin(
            accountId: 'acct_fork',
            version: stored.version,
            listHash: stored.listHash,
            listId: stored.listId,
            headStatement: stored.headStatement,
            conflict: false,
            checkedAt: 2,
            keys: stored.keys,
          );
          expect(await store.replaceConflictedDeviceListPin(honest), isTrue);
          // Once cleared, a second replacement is refused (compare-and-swap).
          expect(await store.replaceConflictedDeviceListPin(honest), isFalse);
        },
        skip: skip,
      );
    });
  }
}

class _Fork {
  _Fork({
    required this.genesis,
    required this.left,
    required this.right,
    required this.rightNext,
    required this.third,
    required this.madeUp,
    required this.carolKey,
    required this.bobKey,
  });

  final Uint8List genesis;
  final Uint8List left;
  final Uint8List right;
  final Uint8List rightNext;
  final Uint8List third;
  final Uint8List madeUp;
  final Uint8List carolKey;
  final Uint8List bobKey;
}

class _Verifier implements DeviceListVerifier {
  _Verifier(this.bindings);
  final NativeCryptoBindings bindings;

  @override
  DeviceListChainResult checkChain(
    String accountId,
    List<List<int>> statements,
  ) =>
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
        history: history,
      );
}

class _Server implements DeviceListSource {
  List<Uint8List> chain = <Uint8List>[];
  bool fail = false;
  bool unknown = false;

  @override
  Future<DeviceListPage?> fetchDeviceList(
    String accountId, {
    required int after,
  }) async {
    if (fail) throw const SocketException('down');
    if (unknown) return null;
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

/// The L1 calls on the SQLite tables; everything else in memory.
class _DatabaseStore extends MemoryLocalStore {
  _DatabaseStore(this.db);
  final EncryptedLocalDatabase db;

  @override
  Future<DeviceListPin?> loadDeviceListPin(String accountId) =>
      db.readDeviceListPin(accountId);

  @override
  Future<bool> saveDeviceListPin(
    DeviceListPin pin, {
    required int? expectedVersion,
  }) =>
      db.writeDeviceListPin(pin, expectedVersion: expectedVersion);

  @override
  Future<void> touchDeviceListPin(String accountId, int checkedAt) =>
      db.touchDeviceListPin(accountId, checkedAt);

  @override
  Future<void> saveDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  }) =>
      db.writeDeviceListConflict(
        accountId: accountId,
        version: version,
        pinnedStatement: pinnedStatement,
        otherStatement: otherStatement,
        recordedAt: recordedAt,
      );

  @override
  Future<List<DeviceListConflictProof>> loadDeviceListConflicts(
    String accountId,
  ) =>
      db.readDeviceListConflicts(accountId);

  @override
  Future<bool> replaceConflictedDeviceListPin(DeviceListPin pin) =>
      db.replaceConflictedDeviceListPin(pin);
}
