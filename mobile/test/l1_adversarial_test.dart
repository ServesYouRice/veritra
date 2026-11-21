import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

/// L1 adversarial evidence (`testing/evidence/L1-adversarial.md`): the
/// server is the attacker. Every client runs the real OpenMLS engine, signs
/// real VDL1 statements, and keeps real pins ([DeviceListPins] verified in
/// Rust); the only fake is the server, which serves any statements, key
/// packages and commits a test hands it. A compromised member device (a
/// client whose own list check is switched off) stands in for "a commit
/// the server got from somewhere".
///
/// 1. A device and key package the server made up for a real account
///    (no list version names it) is never staged, by creation, a reported
///    add, or a forged list version; carried in by a commit, it holds the
///    chat, its words are hidden, and the account's own device alerts.
/// 2. Rollback: a lower head or a truncated chain never undoes a signed
///    removal, also after the pin store is closed and opened again.
/// 3. Forged signatures: a damaged statement, one signed by an unlisted key
///    and a made-up genesis change nothing and are not sticky; a validly
///    signed fork (a stolen listed key) is a sticky conflict, and its reset
///    takes only one of the two proven branches.
/// 4. Removed then re-added: the same pair, the same id with a new key and
///    the old key under a new id are refused, by a pinned peer and on first
///    sight; a commit bringing the removed leaf back holds the chat.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  late _EvilServer server;
  var now = DateTime.utc(2026, 11, 21, 12);

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    server = _EvilServer();
    now = DateTime.utc(2026, 11, 21, 12);
  });

  /// Past the per-account one-minute refresh limit.
  void later() => now = now.add(const Duration(minutes: 2));

  Future<_Client> client(
    String account,
    String device, {
    LocalStore? store,
  }) =>
      _Client.enroll(
        bindings,
        account,
        device,
        server: server,
        clock: () => now,
        store: store,
      );

  /// A member device whose own list check is off: it stages whatever the
  /// server hands it (the source of a hostile commit).
  Future<_Client> compromised(String account, String device) async {
    final made = await client(account, device);
    final lists = TestDeviceLists();
    made.service.deviceListPins = lists;
    made.everything = lists;
    return made;
  }

  /// acct_alice signs v1 {alice, phone} and every account in [others]
  /// signs its own genesis; returns Alice's chain.
  Future<_Chain> honestLists(
    _Client alice,
    _Client phone,
    List<_Client> others,
  ) async {
    final chain = _Chain(bindings, 'acct_alice');
    await chain.genesis(alice, [alice, phone], migration: true);
    server.chains['acct_alice'] = chain.statements;
    for (final other in others) {
      final own = _Chain(bindings, other.accountId);
      await own.genesis(other, [other]);
      server.chains[other.accountId] = own.statements;
    }
    return chain;
  }

  group('1. a device the server injects', () {
    test(
      'is never staged by creation, a reported add or a forged version',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        // The server made dev_ghost for acct_alice: a device row and a
        // valid key package, and no list version that names it.
        final ghost = await client('acct_alice', 'dev_ghost');
        final chain = await honestLists(alice, phone, [carol]);

        await carol.service.initializeConversation('conv_1', [
          await alice.keyPackage(),
          await phone.keyPackage(),
          await ghost.keyPackage(),
        ]);
        final item = (await carol.store.pendingMlsMessages()).single;
        final bundle = MlsCommitBundle.decode(item.payload);
        expect(
          bundle.added.map((ref) => ref.deviceId).toSet(),
          {'dev_alice', 'dev_phone'},
        );
        await _deliver(carol, item, joiners: [alice, phone]);
        expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);

        // A reported add of the ghost alone stages nothing.
        await expectLater(
          carol.service.stageMembershipChange(
            'conv_1',
            adds: [await ghost.keyPackage()],
          ),
          throwsA(isA<DeviceListNotApprovedException>()),
        );
        expect(await carol.store.pendingMlsMessages(), isEmpty);

        // Nor once the server serves a version 2 that adds it, signed by
        // the ghost itself (a key no version of the list holds), or one
        // signed correctly by Alice's key but with a damaged signature.
        final forged = await chain.addSigned(ghost, ghost);
        final damaged = _damage(await chain.addSigned(alice, ghost));
        for (final bad in [forged, damaged]) {
          server.chains['acct_alice'] = [...chain.statements, bad];
          later();
          await expectLater(
            carol.service.stageMembershipChange(
              'conv_1',
              adds: [await ghost.keyPackage()],
            ),
            throwsA(isA<DeviceListNotApprovedException>()),
          );
          final pin = (await carol.store.loadDeviceListPin('acct_alice'))!;
          expect(pin.version, 1);
          expect(pin.conflict, isFalse);
        }
        expect(await carol.store.pendingMlsMessages(), isEmpty);
      },
      skip: skip,
    );

    test(
      'carried in by a commit, it holds the chat, never speaks as the '
      'account, and the account\'s own device alerts the group',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        final mallory = await compromised('acct_mallory', 'dev_mallory');
        final ghost = await client('acct_alice', 'dev_ghost');
        await honestLists(alice, phone, [carol, mallory]);
        for (final member in [alice, carol]) {
          mallory.everything!.approve(
            member.accountId,
            member.deviceId,
            await member.service.currentSigningKey(),
          );
        }
        await mallory.service.initializeConversation('conv_1', [
          await alice.keyPackage(),
          await carol.keyPackage(),
        ]);
        await _deliver(
          mallory,
          (await mallory.store.pendingMlsMessages()).single,
          joiners: [alice, carol],
        );
        expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);
        expect(await alice.service.refreshApprovalHold('conv_1'), isFalse);

        // The hostile commit adds the server's ghost as acct_alice.
        mallory.everything!.approve(
          'acct_alice',
          'dev_ghost',
          await ghost.service.currentSigningKey(),
        );
        await mallory.service.stageMembershipChange(
          'conv_1',
          adds: [await ghost.keyPackage()],
        );
        await _deliver(
          mallory,
          (await mallory.store.pendingMlsMessages()).single,
          joiners: [ghost],
          members: [alice, carol],
        );

        for (final member in [carol, alice]) {
          // Applied (sync goes on), then held for the ghost alone.
          expect(
            (await member.service.groupEpoch('conv_1'))?.epoch,
            2,
          );
          final held = (await member.store.loadApprovalLeaves('conv_1'))
              .where((leaf) => leaf.verdict != LeafVerdict.approved)
              .toList();
          expect(held, hasLength(1));
          expect(String.fromCharCodes(held.single.deviceId), 'dev_ghost');
          expect(held.single.verdict, LeafVerdict.unapproved);
          await expectLater(
            member.send('to everyone'),
            throwsA(isA<ConversationApprovalHeldException>()),
          );
          expect(await member.store.pendingEnvelopes(), isEmpty);
        }

        // Its words are hidden, never stored as acct_alice's.
        final spoken = await ghost.send('i am alice');
        await carol.receive(ghost, spoken);
        final row = (await carol.history()).single;
        expect(row.body, isNull);
        expect(row.kind, LocalMessageKind.invalid);
        expect(row.key, startsWith('unapproved:'));

        // Alice's own device knows its list does not name dev_ghost and
        // owes the group an alert with its head (L2-5).
        final due = await alice.service.ownDeviceAlertsDue();
        expect(due.single.conversationId, 'conv_1');
        expect(due.single.body['head_version'], 1);

        // Only an MLS removal (local evidence) releases the hold.
        await carol.service.stageMembershipChange(
          'conv_1',
          removes: [(accountId: 'acct_alice', deviceId: 'dev_ghost')],
        );
        await _deliver(
          carol,
          (await carol.store.pendingMlsMessages()).single,
          members: [alice],
        );
        expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);
        expect(await alice.service.refreshApprovalHold('conv_1'), isFalse);
      },
      skip: skip,
    );
  });

  group('2. rollback', () {
    test(
      'a lower head or a truncated chain never undoes a signed removal, '
      'also after the pin store is opened again',
      () async {
        final dir = await Directory.systemTemp.createTemp('l1-adv-');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/carol.db');
        var db = EncryptedLocalDatabase(NativeDatabase(file));
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client(
          'acct_carol',
          'dev_carol',
          store: _PinsOnDisk(db),
        );
        final chain = await honestLists(alice, phone, [carol]);
        await carol.service.initializeConversation('conv_1', [
          await alice.keyPackage(),
          await phone.keyPackage(),
        ]);
        await _deliver(
          carol,
          (await carol.store.pendingMlsMessages()).single,
          joiners: [alice, phone],
        );

        // Alice removes the phone (a stolen phone, say).
        await chain.remove(alice, [phone]);
        server.chains['acct_alice'] = [...chain.statements];
        later();
        await expectLater(
          carol.send('not to the stolen phone'),
          throwsA(isA<ConversationApprovalHeldException>()),
        );
        expect((await carol.store.loadDeviceListPin('acct_alice'))!.version, 2);

        // The server rolls back: the old head alone, then a chain that
        // stops before the removal while claiming nothing newer.
        for (final served in [
          [chain.statements.first],
          <Uint8List>[],
        ]) {
          server.chains['acct_alice'] = served;
          later();
          await expectLater(
            carol.send('still not to the phone'),
            throwsA(isA<ConversationApprovalHeldException>()),
          );
          final pin = (await carol.store.loadDeviceListPin('acct_alice'))!;
          expect(pin.version, 2);
          expect(pin.conflict, isFalse);
          expect(await carol.verdictOf('dev_phone'), LeafVerdict.removed);
        }

        // Closed and opened again (a restart): the removal is still there,
        // and the rolled-back server cannot bring the phone back.
        await db.close();
        db = EncryptedLocalDatabase(NativeDatabase(file));
        addTearDown(db.close);
        final reopened = DeviceListPins(
          store: _PinsOnDisk(db),
          source: server.viewOf('acct_carol'),
          verifier: carol.service,
          clock: () => now,
        );
        server.chains['acct_alice'] = [chain.statements.first];
        final phoneKey = await phone.service.currentSigningKey();
        expect(
          await reopened.judge(
            idBytes('acct_alice'),
            idBytes('dev_phone'),
            phoneKey,
          ),
          LeafVerdict.removed,
        );
        expect(await reopened.approvedKey('acct_alice', 'dev_phone'), isNull);
        expect((await db.readDeviceListPin('acct_alice'))!.version, 2);
      },
      skip: skip,
    );
  });

  group('3. forged signatures', () {
    test(
      'a damaged statement, an unlisted signer and a made-up genesis change '
      'nothing and are not sticky',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        final ghost = await client('acct_alice', 'dev_ghost');
        final chain = await honestLists(alice, phone, [carol]);
        final ghostKey = await ghost.service.currentSigningKey();
        expect(
            await carol.pins.approvedKey('acct_alice', 'dev_phone'), isNotNull);

        final madeUp = _Chain(bindings, 'acct_alice');
        await madeUp.genesis(ghost, [ghost]);
        for (final served in [
          [...chain.statements, _damage(await chain.addSigned(alice, ghost))],
          [...chain.statements, await chain.addSigned(ghost, ghost)],
          madeUp.statements,
        ]) {
          server.chains['acct_alice'] = served;
          later();
          expect(
            (await carol.pins.refresh('acct_alice')).state,
            DeviceListState.ok,
          );
          final pin = (await carol.store.loadDeviceListPin('acct_alice'))!;
          expect(pin.version, 1);
          expect(pin.conflict, isFalse);
          expect(
            await carol.pins.judge(
              idBytes('acct_alice'),
              idBytes('dev_ghost'),
              ghostKey,
            ),
            LeafVerdict.unapproved,
          );
        }

        // First sight: a damaged genesis pins nothing.
        final dave = await client('acct_dave', 'dev_dave');
        server.chains['acct_alice'] = [_damage(chain.statements.first)];
        expect(
          (await dave.pins.refresh('acct_alice')).state,
          DeviceListState.unavailable,
        );
        expect(await dave.store.loadDeviceListPin('acct_alice'), isNull);

        // The honest chain carries on afterwards.
        await chain.addSigned(alice, ghost, keep: true);
        server.chains['acct_alice'] = [...chain.statements];
        later();
        expect(
          await carol.pins.judge(
            idBytes('acct_alice'),
            idBytes('dev_ghost'),
            ghostKey,
          ),
          LeafVerdict.approved,
        );
      },
      skip: skip,
    );

    test(
      'a validly signed fork (a stolen listed key) holds the chat as a '
      'sticky conflict; the reset takes only a proven branch',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        final ghost = await client('acct_alice', 'dev_ghost');
        final chain = await honestLists(alice, phone, [carol]);
        await carol.service.initializeConversation('conv_1', [
          await alice.keyPackage(),
          await phone.keyPackage(),
        ]);
        await _deliver(
          carol,
          (await carol.store.pendingMlsMessages()).single,
          joiners: [alice, phone],
        );
        // The honest version 2 removes nothing and Carol pins it.
        await chain.recoveryKey(
          alice,
          await carol.service.currentSigningKey(),
        );
        server.chains['acct_alice'] = [...chain.statements];
        later();
        await carol.send('before the fork');

        // The stolen phone signs another version 2 that adds the ghost.
        final fork = await chain.addSigned(phone, ghost, version: 2);
        server.chains['acct_alice'] = [chain.statements.first, fork];
        later();
        await expectLater(
          carol.send('during the fork'),
          throwsA(isA<ConversationApprovalHeldException>()),
        );
        final pin = (await carol.store.loadDeviceListPin('acct_alice'))!;
        expect(pin.conflict, isTrue);
        final proofs = await carol.store.loadDeviceListConflicts('acct_alice');
        expect(proofs.single.otherStatement, fork);

        // The server cannot use the reset to bring in a chain of its own.
        final madeUp = _Chain(bindings, 'acct_alice');
        await madeUp.genesis(ghost, [ghost]);
        server.chains['acct_alice'] = madeUp.statements;
        await expectLater(
          carol.pins.trustServedBranch('acct_alice'),
          throwsA(isA<DeviceListResetRefused>()),
        );
        expect(
          (await carol.store.loadDeviceListPin('acct_alice'))!.conflict,
          isTrue,
        );
        await expectLater(
          carol.send('still held'),
          throwsA(isA<ConversationApprovalHeldException>()),
        );

        // Alice confirms her devices; the honest branch is shown again and
        // chosen. The chat is released from local evidence.
        server.chains['acct_alice'] = [...chain.statements];
        await carol.pins.trustServedBranch('acct_alice');
        expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);
        await carol.send('after the reset');
      },
      skip: skip,
    );
  });

  group('4. removed then re-added', () {
    test(
      'the same pair, the same id with a new key and the old key under a new '
      'id are refused by a pinned peer and on first sight',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        final chain = await honestLists(alice, phone, [carol]);
        await chain.remove(alice, [phone]);
        server.chains['acct_alice'] = [...chain.statements];
        expect(
          (await carol.pins.refresh('acct_alice')).state,
          DeviceListState.ok,
        );
        final phoneKey = await phone.service.currentSigningKey();
        final newPhone = await client('acct_alice', 'dev_phone_new');
        final newKey = await newPhone.service.currentSigningKey();
        final returns = <String, Uint8List>{
          'same pair': await chain.addPair(
            alice,
            DeviceListPair(idBytes('dev_phone'), phoneKey),
          ),
          'same id, new key': await chain.addPair(
            alice,
            DeviceListPair(idBytes('dev_phone'), newKey),
          ),
          'old key, new id': await chain.addPair(
            alice,
            DeviceListPair(idBytes('dev_phone_2'), phoneKey),
          ),
        };
        var viewers = 0;
        for (final entry in returns.entries) {
          server.chains['acct_alice'] = [...chain.statements, entry.value];
          later();
          expect(
            (await carol.pins.refresh('acct_alice')).state,
            DeviceListState.ok,
            reason: entry.key,
          );
          final pin = (await carol.store.loadDeviceListPin('acct_alice'))!;
          expect(pin.version, 2, reason: entry.key);
          expect(
            await carol.pins.judge(
              idBytes('acct_alice'),
              idBytes('dev_phone'),
              phoneKey,
            ),
            LeafVerdict.removed,
            reason: entry.key,
          );
          expect(
            await carol.pins.approvedKey('acct_alice', 'dev_phone'),
            isNull,
            reason: entry.key,
          );
          expect(
            await carol.pins.approvedKey('acct_alice', 'dev_phone_2'),
            isNull,
            reason: entry.key,
          );
          // First sight of the whole chain refuses it too.
          final viewer = await client('acct_viewer${++viewers}', 'dev_v');
          expect(
            (await viewer.pins.refresh('acct_alice')).state,
            DeviceListState.unavailable,
            reason: entry.key,
          );
          expect(await viewer.store.loadDeviceListPin('acct_alice'), isNull);
        }
      },
      skip: skip,
    );

    test(
      'a commit that brings the removed device back holds the chat',
      () async {
        final alice = await client('acct_alice', 'dev_alice');
        final phone = await client('acct_alice', 'dev_phone');
        final carol = await client('acct_carol', 'dev_carol');
        final mallory = await compromised('acct_mallory', 'dev_mallory');
        final chain = await honestLists(alice, phone, [carol, mallory]);
        for (final member in [alice, phone, carol]) {
          mallory.everything!.approve(
            member.accountId,
            member.deviceId,
            await member.service.currentSigningKey(),
          );
        }
        await mallory.service.initializeConversation('conv_1', [
          await alice.keyPackage(),
          await phone.keyPackage(),
          await carol.keyPackage(),
        ]);
        await _deliver(
          mallory,
          (await mallory.store.pendingMlsMessages()).single,
          joiners: [alice, phone, carol],
        );
        // The phone is removed from the list and from the group.
        await chain.remove(alice, [phone]);
        server.chains['acct_alice'] = [...chain.statements];
        later();
        await alice.service.stageMembershipChange(
          'conv_1',
          removes: [(accountId: 'acct_alice', deviceId: 'dev_phone')],
        );
        await _deliver(
          alice,
          (await alice.store.pendingMlsMessages()).single,
          members: [carol, mallory],
        );
        expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);

        // A hostile commit brings the removed phone back.
        await mallory.service.stageMembershipChange(
          'conv_1',
          adds: [await phone.keyPackage()],
        );
        // (The phone still holds its old group; no Welcome is delivered.)
        await _deliver(
          mallory,
          (await mallory.store.pendingMlsMessages()).single,
          members: [alice, carol],
        );
        later();
        expect(await carol.verdictOf('dev_phone'), LeafVerdict.removed);
        await expectLater(
          carol.send('not to the returned phone'),
          throwsA(isA<ConversationApprovalHeldException>()),
        );
        await expectLater(
          alice.send('not to my removed phone'),
          throwsA(isA<ConversationApprovalHeldException>()),
        );
        expect(await carol.store.pendingEnvelopes(), isEmpty);
      },
      skip: skip,
    );
  });
}

int _ids = 0;

Uint8List _damage(List<int> statement) {
  final out = Uint8List.fromList(statement);
  out[out.length - 1] ^= 0x01;
  return out;
}

/// Serves each account's chain as a test sets it: any statements at all.
class _EvilServer {
  final Map<String, List<Uint8List>> chains = <String, List<Uint8List>>{};

  DeviceListSource viewOf(String viewer) => _View(this);
}

class _View implements DeviceListSource {
  _View(this.server);
  final _EvilServer server;

  @override
  Future<DeviceListPage?> fetchDeviceList(
    String accountId, {
    required int after,
  }) async {
    final chain = server.chains[accountId];
    if (chain == null) return null;
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

/// One account's list as its devices sign it, version by version.
class _Chain {
  _Chain(this.bindings, this.accountId);
  final NativeCryptoBindings bindings;
  final String accountId;
  final List<Uint8List> statements = <Uint8List>[];
  final List<DeviceListPair> history = <DeviceListPair>[];
  final List<DeviceListSummary> heads = <DeviceListSummary>[];
  List<DeviceListPair> listed = <DeviceListPair>[];
  DeviceListSummary? head;

  int get _next => statements.length + 1;

  Future<DeviceListPair> _pair(_Client device) async => DeviceListPair(
        idBytes(device.deviceId),
        await device.service.currentSigningKey(),
      );

  Future<Uint8List> _sign(
    _Client signer,
    DeviceListChange change,
    List<DeviceListPair> entries, {
    int? version,
    List<int>? recoveryKey,
    DeviceListSummary? prev,
  }) async {
    final before = prev ?? head;
    final at = version ?? _next;
    return signer.service.signDeviceList(
      DeviceListBody(
        accountId: idBytes(accountId),
        version: at,
        prevHash: before?.listHash ?? DeviceListBody.zeroHash,
        createdAtMs: at,
        change: change,
        entries: entries,
        recoveryKey: recoveryKey ?? before?.recoveryKey,
      ),
    );
  }

  void _keep(Uint8List statement) {
    final summary = bindings.checkDeviceListStep(
      expectedAccountId: idBytes(accountId),
      prev: statements.lastOrNull,
      statement: statement,
      history: history,
    );
    statements.add(statement);
    heads.add(summary);
    head = summary;
    listed = summary.entries;
    for (final entry in summary.entries) {
      if (!history.any((pair) => _samePair(pair, entry))) history.add(entry);
    }
  }

  Future<void> genesis(
    _Client signer,
    List<_Client> devices, {
    bool migration = false,
  }) async {
    final entries = [for (final device in devices) await _pair(device)];
    _keep(await _sign(
      signer,
      migration ? DeviceListChange.migrationGenesis : DeviceListChange.genesis,
      entries,
    ));
  }

  Future<void> remove(_Client signer, List<_Client> devices) async {
    final gone = [for (final device in devices) await _pair(device)];
    _keep(await _sign(signer, DeviceListChange.remove, [
      for (final pair in listed)
        if (!gone.any((other) => _samePair(pair, other))) pair,
    ]));
  }

  /// A change-5 version (recovery key [key] set) that lists the same
  /// devices.
  Future<void> recoveryKey(_Client signer, List<int> key) async =>
      _keep(await _sign(
        signer,
        DeviceListChange.recoveryKey,
        listed,
        recoveryKey: key,
      ));

  /// An add of [device] signed by [signer], at [version] (default: next).
  /// Not kept unless [keep]: most callers serve it as an attack.
  Future<Uint8List> addSigned(
    _Client signer,
    _Client device, {
    int? version,
    bool keep = false,
  }) async {
    final prev = version == null ? head : heads[version - 2];
    final statement = await _sign(
      signer,
      DeviceListChange.add,
      [...prev!.entries, await _pair(device)],
      version: version,
      prev: prev,
    );
    if (keep) _keep(statement);
    return statement;
  }

  /// An add of [pair] signed by [signer] at the next version (not kept).
  Future<Uint8List> addPair(_Client signer, DeviceListPair pair) =>
      _sign(signer, DeviceListChange.add, [...listed, pair]);
}

bool _samePair(DeviceListPair a, DeviceListPair b) =>
    _same(a.deviceId, b.deviceId) && _same(a.signingKey, b.signingKey);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId, this.pins);

  final NativeCryptoService service;
  final LocalStore store;
  final String accountId;
  final String deviceId;
  final DeviceListPins pins;

  /// Set on a compromised client: its "list" approves what a test says.
  TestDeviceLists? everything;
  int _events = 0;

  static Future<_Client> enroll(
    NativeCryptoBindings bindings,
    String accountId,
    String deviceId, {
    required _EvilServer server,
    required DateTime Function() clock,
    LocalStore? store,
  }) async {
    final local = store ?? MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    final pins = DeviceListPins(
      store: local,
      source: server.viewOf(accountId),
      verifier: service,
      clock: clock,
    );
    service.deviceListPins = pins;
    await service.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$accountId$deviceId',
        accountId: accountId,
        deviceId: deviceId,
        challenge: const <int>[1, 2, 3],
      ),
    );
    await service.activateSession(
      Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: accountId,
        deviceId: deviceId,
      ),
    );
    return _Client(service, local, accountId, deviceId, pins);
  }

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_ids}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<List<LocalMessage>> history() => store.loadMessages('conv_1');

  Future<MessageEnvelope> send(String text) async {
    final envelope = await service.encryptPayload(
      'conv_1',
      AppPayloadType.text,
      <String, Object?>{'text': text},
    );
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(
        ReceivedMessageEnvelope(
          id: 'srv_${++_ids}',
          conversationId: sent.conversationId,
          senderAccountId: from.accountId,
          senderDeviceId: from.deviceId,
          idempotencyKey: sent.idempotencyKey,
          ciphertext: sent.ciphertext,
          cryptoProtocol: sent.cryptoProtocol,
          createdAt: DateTime.now().toUtc(),
          frankCommit: sent.frankCommit,
        ),
        nextEvent(),
      );

  /// The verdict this device holds for [device]'s leaf after judging the
  /// group again.
  Future<LeafVerdict?> verdictOf(String device) async {
    await service.refreshApprovalHold('conv_1');
    for (final leaf in await store.loadApprovalLeaves('conv_1')) {
      if (String.fromCharCodes(leaf.deviceId) == device) return leaf.verdict;
    }
    return null;
  }
}

/// Applies [item] on its committer, then on [members] (commit) and
/// [joiners] (Welcome), as the server would deliver it.
Future<void> _deliver(
  _Client from,
  PendingMlsMessage item, {
  List<_Client> joiners = const [],
  List<_Client> members = const [],
}) async {
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member.service.processMlsMessage(
      MlsMessage(
        id: 'mls_${++_ids}',
        conversationId: 'conv_1',
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        kind: 'commit',
        payload: bundle.commit,
        idempotencyKey: item.idempotencyKey,
        syncEventId: member.nextEvent(),
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(
      MlsMessage(
        id: 'mls_${++_ids}',
        conversationId: 'conv_1',
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        kind: 'welcome',
        payload: bundle.welcome,
        idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.deviceId}',
        syncEventId: joiner.nextEvent(),
        createdAt: DateTime.now().toUtc(),
        recipientDeviceId: joiner.deviceId,
      ),
    );
  }
}

/// The L1 pin calls on a SQLite file; everything else in memory.
class _PinsOnDisk extends MemoryLocalStore {
  _PinsOnDisk(this.db);
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
