import 'dart:convert';
import 'dart:typed_data';

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

/// L1-3 (D94, TASK-006) with real OpenMLS devices: the add gate stages only
/// devices the approved-device list names, with the pinned key; a commit or
/// Welcome that brings a device the list does not approve is applied, then
/// holds the conversation and hides that device's messages; a removal
/// releases the hold from local evidence.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Future<_Client> client(String account, String device) =>
      _Client.enroll(bindings, account, device);

  test('an approved device is added with its pinned key and messages flow',
      () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    await bob.trust(alice);
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);

    expect(await alice.service.refreshApprovalHold('conv_1'), isFalse);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
    final leaves = await bob.store.loadApprovalLeaves('conv_1');
    expect(leaves, hasLength(2));
    expect(
        leaves.every((leaf) => leaf.verdict == LeafVerdict.approved), isTrue);
    final sent = await alice.send('hello');
    await bob.receive(alice, sent);
    expect((await bob.history()).single.body, 'hello');
  }, skip: skip);

  test('signed-list discovery finds siblings omitted by the server', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    final phone = await client('acct_bob', 'dev_phone');
    await alice.trust(bob);
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);
    final genesis = await bob.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_bob'),
      version: 1,
      prevHash: DeviceListBody.zeroHash,
      createdAtMs: 1,
      change: DeviceListChange.migrationGenesis,
      entries: [
        DeviceListPair(
            idBytes('dev_bob'), await bob.service.currentSigningKey()),
        DeviceListPair(
            idBytes('dev_phone'), await phone.service.currentSigningKey()),
      ],
    ));
    final source = _ListSource()..chain = [genesis];
    final pins = DeviceListPins(
        store: alice.store, source: source, verifier: alice.service);
    alice.service.deviceListPins = pins;
    expect(
        await alice.service
            .missingApprovedDevices('conv_1', ['acct_bob', 'acct_bob']),
        [(accountId: 'acct_bob', deviceId: 'dev_phone')]);
    expect(
        await alice.service.missingApprovedDevices(null, ['acct_bob']),
        unorderedEquals([
          (accountId: 'acct_bob', deviceId: 'dev_bob'),
          (accountId: 'acct_bob', deviceId: 'dev_phone'),
        ]));
    final head = bindings.checkDeviceListStep(
        expectedAccountId: idBytes('acct_bob'), statement: genesis);
    final removed = await bob.service.signDeviceList(DeviceListBody(
      accountId: idBytes('acct_bob'),
      version: 2,
      prevHash: head.listHash,
      createdAtMs: 2,
      change: DeviceListChange.remove,
      entries: [
        DeviceListPair(
            idBytes('dev_bob'), await bob.service.currentSigningKey())
      ],
    ));
    source.chain.add(removed);
    pins.invalidate('acct_bob');
    expect(await alice.service.missingApprovedDevices('conv_1', ['acct_bob']),
        isEmpty);
    // A sticky conflict authorizes nothing, even with a previously pinned key.
    await alice.store.saveDeviceListConflict(
        accountId: 'acct_bob',
        version: 2,
        pinnedStatement: removed,
        otherStatement: removed,
        recordedAt: 3);
    expect(await alice.service.missingApprovedDevices(null, ['acct_bob']),
        isEmpty);
    alice.service.deviceListPins = null;
    expect(await alice.service.missingApprovedDevices(null, ['acct_bob']),
        isEmpty);
  }, skip: skip);

  test('a device the list does not approve is never staged', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    final ghost = await client('acct_bob', 'dev_ghost');
    await alice.trust(bob);
    // The server lists dev_ghost for acct_bob; bob's list does not.
    await alice.service
        .initializeConversation('conv_1', [await ghost.keyPackage()]);
    final item = (await alice.store.pendingMlsMessages()).single;
    final bundle = MlsCommitBundle.decode(item.payload);
    expect(bundle.hasCommit, isFalse);
    expect(bundle.added, isEmpty);
    await alice.service.completeCommitBundle(item);

    await expectLater(
        alice.service
            .stageMembershipChange('conv_1', adds: [await ghost.keyPackage()]),
        throwsA(isA<DeviceListNotApprovedException>()));
    expect(await alice.store.pendingMlsMessages(), isEmpty);
  }, skip: skip);

  test(
    'a signed removal overrides cached approval before encryption',
    () async {
      final alice = await client('acct_alice', 'dev_alice');
      final sibling = await client('acct_alice', 'dev_sibling');
      final bob = await client('acct_bob', 'dev_bob');
      await alice.trust(bob);
      final aliceKey = await alice.service.currentSigningKey();
      final siblingKey = await sibling.service.currentSigningKey();
      final genesis = await alice.service.signDeviceList(
        DeviceListBody(
          accountId: idBytes('acct_alice'),
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.migrationGenesis,
          entries: [
            DeviceListPair(idBytes('dev_alice'), aliceKey),
            DeviceListPair(idBytes('dev_sibling'), siblingKey),
          ],
        ),
      );
      final source = _ListSource()..chain = [genesis];
      var now = DateTime.utc(2026, 11, 10);
      final pins = DeviceListPins(
        store: bob.store,
        source: source,
        verifier: bob.service,
        clock: () => now,
      );
      bob.service.deviceListPins = pins;
      await alice.service.initializeConversation('conv_1', [
        await bob.keyPackage(),
      ]);
      await _accept(alice, [bob], const []);
      expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
      expect(
        (await bob.store.loadApprovalLeaves(
          'conv_1',
        ))
            .every((leaf) => leaf.verdict == LeafVerdict.approved),
        isTrue,
      );

      final head = bindings.checkDeviceListStep(
        expectedAccountId: idBytes('acct_alice'),
        statement: genesis,
      );
      final removal = await sibling.service.signDeviceList(
        DeviceListBody(
          accountId: idBytes('acct_alice'),
          version: 2,
          prevHash: head.listHash,
          createdAtMs: 2,
          change: DeviceListChange.remove,
          entries: [DeviceListPair(idBytes('dev_sibling'), siblingKey)],
        ),
      );
      source.chain.add(removal);
      // The normal refresh discovers the signed update, without any MLS
      // removal or change in pending-changes/roster responses.
      now = now.add(const Duration(minutes: 2));
      final held = throwsA(isA<ConversationApprovalHeldException>());
      await expectLater(bob.send('must not reach the removed device'), held);
      expect((await bob.store.loadDeviceListPin('acct_alice'))?.version, 2);
      await expectLater(
        bob.service.encryptCallSignal('conv_1', <String, Object?>{
          'type': 'offer',
          'sdp': 'v=0',
        }),
        held,
      );
      await expectLater(bob.service.stageSelfUpdate('conv_1'), held);
      expect(await bob.store.pendingEnvelopes(), isEmpty);
      expect(await bob.store.pendingMlsMessages(), isEmpty);
      expect(
        (await bob.store.loadApprovalLeaves('conv_1'))
            .firstWhere(
              (leaf) => String.fromCharCodes(leaf.deviceId) == 'dev_alice',
            )
            .verdict,
        LeafVerdict.removed,
      );

      // Incoming messages still follow the formerly-approved sender policy.
      await bob.receive(alice, await alice.send('sent before MLS removal'));
      expect((await bob.history()).single.body, 'sent before MLS removal');
      expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);

      // A removal is permitted while held. Only removing the leaf from the
      // actual MLS tree clears the hold.
      await bob.service.stageMembershipChange(
        'conv_1',
        removes: [(accountId: 'acct_alice', deviceId: 'dev_alice')],
      );
      await _accept(bob, const [], const []);
      expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
      await bob.send('safe after MLS removal');
    },
    skip: skip,
  );

  test(
    'incoming sender approval is rechecked against a changed list',
    () async {
      final alice = await client('acct_alice', 'dev_alice');
      final bob = await client('acct_bob', 'dev_bob');
      await alice.trust(bob);
      await bob.trust(alice);
      await alice.service.initializeConversation('conv_1', [
        await bob.keyPackage(),
      ]);
      await _accept(alice, [bob], const []);
      expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
      bob.lists.remove('acct_alice', 'dev_alice');
      await bob.receive(alice, await alice.send('must stay hidden'));
      final message = (await bob.history()).single;
      expect(message.body, isNull);
      expect(message.key, startsWith('unapproved:'));
      expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);
    },
    skip: skip,
  );

  test('a key package with another key than the pinned one is refused',
      () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    // A server-made twin of dev_bob: same ids, its own signing key.
    final twin = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    await alice.service.initializeConversation('conv_1', const []);
    await alice.service
        .completeCommitBundle((await alice.store.pendingMlsMessages()).single);
    await expectLater(
        alice.service
            .stageMembershipChange('conv_1', adds: [await twin.keyPackage()]),
        throwsA(isA<NativeCryptoException>()));
    expect(await alice.store.pendingMlsMessages(), isEmpty);
  }, skip: skip);

  test('without pins nothing is added (fail closed)', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    alice.service.deviceListPins = null;
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    final bundle = MlsCommitBundle.decode(
        (await alice.store.pendingMlsMessages()).single.payload);
    expect(bundle.added, isEmpty);
  }, skip: skip);

  test(
      'a commit adding an unapproved device is applied, holds sends and '
      'hides its messages; its removal releases the hold', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final carol = await client('acct_carol', 'dev_carol');
    final ghost = await client('acct_alice', 'dev_ghost');
    await alice.trust(carol);
    await carol.trust(alice);
    await alice.service
        .initializeConversation('conv_1', [await carol.keyPackage()]);
    await _accept(alice, [carol], const []);
    // Alice's device trusts the ghost (a stolen device signed it onto her
    // view, say); Carol's view of acct_alice's list does not have it.
    await alice.trust(ghost);
    await ghost.trust(alice);
    await ghost.trust(carol);
    await alice.service
        .stageMembershipChange('conv_1', adds: [await ghost.keyPackage()]);
    await _accept(alice, [ghost], [carol]);

    // Carol applied the commit (sync goes on) and holds the conversation.
    expect(
        await carol.service.groupEpoch('conv_1'), (epoch: 2, pending: false));
    final held = (await carol.store.loadApprovalLeaves('conv_1'))
        .where((leaf) => leaf.verdict != LeafVerdict.approved)
        .toList();
    expect(held, hasLength(1));
    expect(held.single.verdict, LeafVerdict.unapproved);
    await expectLater(carol.send('to everyone'),
        throwsA(isA<ConversationApprovalHeldException>()));
    await expectLater(carol.service.stageSelfUpdate('conv_1'),
        throwsA(isA<ConversationApprovalHeldException>()));

    // The ghost's words never speak as acct_alice on Carol's device.
    final spoken = await ghost.send('i am alice');
    final event = carol.nextEvent();
    final envelope = carol.envelopeFrom(ghost, spoken);
    expect(
        await carol.service.processApplicationMessage(envelope, event), isNull);
    final row = (await carol.history()).single;
    expect(row.key, 'unapproved:$event:${envelope.id}');
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.body, isNull);
    expect(await carol.store.loadSyncCursor(), event);

    // Nor does it ring as acct_alice (review fix): its call signal is
    // dropped, the cursor moves on.
    final ring = await ghost.service.encryptCallSignal(
        'conv_1', <String, Object?>{'type': 'offer', 'sdp': 'v=0'});
    final ringEvent = carol.nextEvent();
    expect(
        await carol.service.processCallSignal(
            CallSession(
              id: 'call_1',
              conversationId: 'conv_1',
              createdBy: 'acct_alice',
              invitedAccountId: 'acct_carol',
              state: 'ringing',
              version: 1,
              metadata: ring.metadata,
              createdAt: DateTime.now().toUtc(),
            ),
            ringEvent),
        isNull);
    expect(await carol.store.loadSyncCursor(), ringEvent);

    // Alice's real device still speaks normally.
    final real = await alice.send('really me');
    await carol.receive(alice, real);
    expect((await carol.history()).last.body, 'really me');

    // A removal commit is allowed while held, and releases the hold.
    await alice.service.stageMembershipChange('conv_1', removes: [
      (accountId: 'acct_alice', deviceId: 'dev_ghost'),
    ]);
    await _accept(alice, const [], [carol]);
    expect(await carol.service.refreshApprovalHold('conv_1'), isFalse);
    await carol.send('safe again');
  }, skip: skip);

  test('a Welcome into a group with an unapproved leaf joins and holds',
      () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    // Bob's view does not approve dev_alice.
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);
    expect(await bob.service.groupEpoch('conv_1'), isNotNull);
    expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);
    await expectLater(
        bob.send('x'), throwsA(isA<ConversationApprovalHeldException>()));
    // Once Bob's list approves it (a fresher pin), the hold lifts.
    await bob.trust(alice);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
    await bob.send('now');
  }, skip: skip);

  test(
      'a Welcome leaf of a non-participant stays held: a later re-judge by '
      'list alone does not approve it (review fix)', () async {
    final mallory = await client('acct_mallory', 'dev_mallory');
    final bob = await client('acct_bob', 'dev_bob');
    // Mallory's real list approves her device, and Bob's view knows it; but
    // conv_1 is Bob's chat with Alice, so Mallory is no participant.
    await mallory.trust(bob);
    await bob.trust(mallory);
    bob.service.conversationAuthority = _Members({'acct_alice', 'acct_bob'});
    await mallory.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(mallory, [bob], const []);
    final held = (await bob.store.loadApprovalLeaves('conv_1'))
        .where((leaf) => leaf.verdict != LeafVerdict.approved)
        .toList();
    expect(held.map((leaf) => String.fromCharCodes(leaf.deviceId)),
        ['dev_mallory']);
    // The first send judges the held leaf again; it must stay held.
    await expectLater(
        bob.send('x'), throwsA(isA<ConversationApprovalHeldException>()));
    expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);
  }, skip: skip);

  test(
      'a message from a leaf judged unapproved on a stale view is judged '
      'again before it is hidden (review fix)', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);
    // Bob judged dev_alice before his view of her list had it.
    expect(
        (await bob.store.loadApprovalLeaves('conv_1'))
            .firstWhere(
                (leaf) => String.fromCharCodes(leaf.deviceId) == 'dev_alice')
            .verdict,
        LeafVerdict.unapproved);
    await bob.trust(alice);
    await bob.receive(alice, await alice.send('hello'));
    expect((await bob.history()).single.body, 'hello');
  }, skip: skip);

  test('an unreachable list is "checking": held, then released', () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    await bob.trust(alice);
    bob.lists.unavailable.add('acct_alice');
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);
    final leaves = await bob.store.loadApprovalLeaves('conv_1');
    expect(
        leaves
            .firstWhere(
                (leaf) => String.fromCharCodes(leaf.deviceId) == 'dev_alice')
            .verdict,
        LeafVerdict.checking);
    // A message from a leaf still being checked is hidden, never shown.
    final sent = await alice.send('early');
    final event = bob.nextEvent();
    final envelope = bob.envelopeFrom(alice, sent);
    await bob.service.processApplicationMessage(envelope, event);
    expect((await bob.history()).single.key, startsWith('unapproved:'));
    bob.lists.unavailable.clear();
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);
    await bob.receive(alice, await alice.send('later'));
    expect((await bob.history()).last.body, 'later');
  }, skip: skip);

  test('a group from before L1 (no rows) is judged before it is used',
      () async {
    final alice = await client('acct_alice', 'dev_alice');
    final bob = await client('acct_bob', 'dev_bob');
    await alice.trust(bob);
    await bob.trust(alice);
    await alice.service
        .initializeConversation('conv_1', [await bob.keyPackage()]);
    await _accept(alice, [bob], const []);
    // As if the rows were never written (an upgrade from schema 20).
    await bob.store.saveApprovalLeaves(const ApprovalLeafChange(
        conversationId: 'conv_1', leaves: [], replaceAll: true));
    expect(await bob.store.loadApprovalLeaves('conv_1'), isEmpty);
    bob.lists.remove('acct_alice', 'dev_alice');
    await expectLater(
        bob.send('x'), throwsA(isA<ConversationApprovalHeldException>()));
    expect(await bob.store.loadApprovalLeaves('conv_1'), hasLength(2));
  }, skip: skip);

  // L2-5 (D94): the own-device alert.
  DeviceListPin pin(String accountId, int version,
          {int listId = 0xab,
          List<DeviceListKeyRow> keys = const <DeviceListKeyRow>[]}) =>
      DeviceListPin(
        accountId: accountId,
        version: version,
        listHash: List<int>.filled(32, 1),
        listId: List<int>.filled(32, listId),
        headStatement: const <int>[1],
        conflict: false,
        checkedAt: 0,
        keys: keys,
      );

  Future<MessageEnvelope> alert(_Client from, Map<String, Object?> body) async {
    final envelope = await from.service
        .encryptPayload('conv_1', AppPayloadType.deviceListAlert, body);
    await from.store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  test(
      'a device that finds an unapproved leaf of its own account alerts the '
      'group once per head, past its own hold', () async {
    final alice = await client('acct_alice', 'dev_alice');
    // A device the server slipped into acct_alice; bob's stale pin lists it.
    final ghost = await client('acct_alice', 'dev_ghost');
    final bob = await client('acct_bob', 'dev_bob');
    await bob.trust(alice);
    await bob.trust(ghost);
    await alice.trust(bob);
    await bob.service.initializeConversation(
        'conv_1', [await alice.keyPackage(), await ghost.keyPackage()]);
    await _accept(bob, [alice, ghost], const []);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);

    // Alice's own list does not have dev_ghost: held, and an alert is owed.
    expect(await alice.service.refreshApprovalHold('conv_1'), isTrue);
    expect(
        await alice.store
            .saveDeviceListPin(pin('acct_alice', 3), expectedVersion: null),
        isTrue);
    final due = await alice.service.ownDeviceAlertsDue();
    expect(due, hasLength(1));
    expect(due.single.conversationId, 'conv_1');
    expect(due.single.body, {
      'account_id': 'acct_alice',
      'head_version': 3,
      'list_id': 'ab' * 32,
    });
    await expectLater(
        alice.send('held'), throwsA(isA<ConversationApprovalHeldException>()));

    // A forged alert (about another account) changes nothing at bob. Sent
    // first: once bob holds acct_alice's leaves, ghost's messages hide.
    final forged = await alert(ghost, <String, Object?>{
      'account_id': 'acct_bob',
      'head_version': 9,
      'list_id': 'cd' * 32,
    });
    await bob.receive(ghost, forged);
    expect(
        await bob.store
            .loadSetting(NativeCryptoService.alertHeadSetting('acct_bob')),
        isNull);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);

    // The alert itself goes out although the chat is held.
    final sent = await alert(alice, due.single.body);
    await alice.service.markOwnDeviceAlertSent('conv_1', 3);
    expect(await alice.service.ownDeviceAlertsDue(), isEmpty);
    // Judged again at the same head: still not owed again.
    expect(await alice.service.refreshApprovalHold('conv_1'), isTrue);
    expect(await alice.service.ownDeviceAlertsDue(), isEmpty);

    // Bob's pin of acct_alice is behind the alerted head: every leaf of
    // acct_alice is "checking" and the chat is held, nothing shown.
    expect(await bob.receive(alice, sent), isNull);
    expect(
        await bob.store
            .loadSetting(NativeCryptoService.alertHeadSetting('acct_alice')),
        '3:${'ab' * 32}:dev_alice');
    expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);
    final leaves = await bob.store.loadApprovalLeaves('conv_1');
    for (final leaf in leaves) {
      final account = String.fromCharCodes(leaf.accountId);
      expect(leaf.verdict,
          account == 'acct_alice' ? LeafVerdict.checking : LeafVerdict.approved,
          reason: String.fromCharCodes(leaf.deviceId));
    }
    expect((await bob.history()).where((m) => m.body != null), isEmpty);

    // A pin at that head of another list (another genesis) still holds.
    expect(
        await bob.store.saveDeviceListPin(pin('acct_alice', 3, listId: 0xcd),
            expectedVersion: null),
        isTrue);
    expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);

    // Once bob's pin is the alerted list at that head, the list alone
    // decides again.
    expect(
        await bob.store
            .saveDeviceListPin(pin('acct_alice', 3), expectedVersion: 3),
        isTrue);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);

    // A rogue device of acct_alice alerting a head never published holds
    // the account's leaves only until a pin shows that device removed.
    await bob.receive(
        ghost,
        await alert(ghost, <String, Object?>{
          'account_id': 'acct_alice',
          'head_version': 9,
          'list_id': 'ab' * 32,
        }));
    expect(
        await bob.store
            .loadSetting(NativeCryptoService.alertHeadSetting('acct_alice')),
        '9:${'ab' * 32}:dev_ghost');
    expect(await bob.service.refreshApprovalHold('conv_1'), isTrue);
    expect(
        await bob.store.saveDeviceListPin(
            pin('acct_alice', 4, keys: [
              DeviceListKeyRow(
                  deviceId: utf8.encode('dev_ghost'),
                  signingKey: List<int>.filled(32, 7),
                  addedVersion: 1,
                  removedVersion: 4),
            ]),
            expectedVersion: 3),
        isTrue);
    expect(await bob.service.refreshApprovalHold('conv_1'), isFalse);

    // A new own head makes the alert due again.
    expect(
        await alice.store
            .saveDeviceListPin(pin('acct_alice', 4), expectedVersion: 3),
        isTrue);
    expect(await alice.service.refreshApprovalHold('conv_1'), isTrue);
    expect(
        (await alice.service.ownDeviceAlertsDue()).single.body['head_version'],
        4);
  }, skip: skip);
}

int _serverIds = 0;

class _ListSource implements DeviceListSource {
  List<Uint8List> chain = [];

  @override
  Future<DeviceListPage?> fetchDeviceList(
    String accountId, {
    required int after,
  }) async =>
      DeviceListPage(
        headVersion: chain.length,
        more: false,
        statements: [
          for (var i = after; i < chain.length; i++)
            (version: i + 1, statement: chain[i]),
        ],
      );
}

class _Members implements ConversationAuthority {
  _Members(this.members);
  final Set<String> members;
  @override
  Set<String> memberAccounts(String conversationId) => members;
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationKind(String conversationId) => null;
  @override
  String? conversationChannel(String conversationId) => null;
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId, this.lists);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  final TestDeviceLists lists;
  int _events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    final lists = TestDeviceLists();
    service.deviceListPins = lists;
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
    return _Client(service, local, accountId, deviceId, lists);
  }

  /// This device's view of [other]'s account list now approves [other].
  Future<void> trust(_Client other) async => lists.approve(
      other.accountId, other.deviceId, await other.service.currentSigningKey());

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
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
        'conv_1', AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
        frankCommit: sent.frankCommit,
      );

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(envelopeFrom(from, sent), nextEvent());
}

Future<void> _accept(
    _Client from, List<_Client> joiners, List<_Client> members) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: bundle.commit,
      idempotencyKey: item.idempotencyKey,
      syncEventId: member.nextEvent(),
      createdAt: DateTime.now().toUtc(),
    ));
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.deviceId}',
      syncEventId: joiner.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: joiner.deviceId,
    ));
  }
}
