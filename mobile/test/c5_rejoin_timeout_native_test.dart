import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/core/roles/record_timeout_gap.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

/// C5 rejoin gap with real OpenMLS devices (docs/designs/C5-moderation.md,
/// "Timeouts after a rejoin"): a timed-out member's removal prunes the
/// record entry; after the rejoin, an owner's "Apply to the record" commit
/// (the same builder the app stages) is accepted by every other member's
/// device, whose record then holds the timeout at the commit's epoch. The
/// builder refuses before the rejoiner's device is in the group.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Future<List<_Client>> trusted(List<_Client> all) async {
    for (final a in all) {
      for (final b in all) {
        if (!identical(a, b)) await a.trust(b);
      }
    }
    return all;
  }

  test(
    'a rejoined member\'s server timeout is written back and accepted',
    () async {
      final alice = await _Client.enroll(bindings, 'alice');
      final bob = await _Client.enroll(bindings, 'bob');
      final carol = await _Client.enroll(bindings, 'carol');
      // Bob rejoins later from a fresh device of the same account.
      final bob2 = await _Client.enroll(
        bindings,
        'bob2',
        account: 'acct_bob',
      );
      await trusted([alice, bob, carol, bob2]);
      await alice.service.initializeConversation(_conv, [
        await bob.keyPackage(),
        await carol.keyPackage(),
      ]);
      await _deliver(alice, joiners: [bob, carol]);

      // The timeout as the server set it, recorded.
      final start = DateTime.now().toUtc();
      final until = start.add(const Duration(hours: 2));
      await alice.service.stageRoleChange(
        _conv,
        (c, _, __) => c.setTimeout(
          bob.account,
          fromMs: start.millisecondsSinceEpoch,
          untilMs: until.millisecondsSinceEpoch,
        ),
      );
      await _deliver(alice, members: [bob, carol]);
      expect(
        (await carol.service.governanceView(_conv))!.record.timeouts,
        contains(bob.account),
      );

      // Bob is removed: the record entry goes with him (removeAccount).
      await alice.service.stageMembershipChange(
        _conv,
        removes: [(accountId: bob.account, deviceId: bob.device)],
      );
      await _deliver(alice, members: [carol]);
      final pruned = (await carol.service.governanceView(_conv))!;
      expect(pruned.record.timeouts, isEmpty);
      expect(pruned.roster, isNot(contains(bob.account)));

      // Before his device is back in the group, the builder refuses.
      await expectLater(
        alice.service.stageRoleChange(
          _conv,
          (c, _, now) => applyServerTimeout(
            c,
            bob.account,
            serverUntil: until,
            now: now,
          ),
        ),
        throwsA(
          isA<GovernanceCommandException>().having(
            (e) => e.reason,
            'reason',
            'not_member',
          ),
        ),
      );
      expect(await alice.store.pendingMlsMessages(), isEmpty);

      // He rejoins: the server would restore its timeout (migration 0095);
      // the record has none.
      await alice.service.stageMembershipChange(
        _conv,
        adds: [await bob2.keyPackage()],
      );
      await _deliver(alice, joiners: [bob2], members: [carol]);
      final view = (await alice.service.governanceView(_conv))!;
      expect(view.roster, contains(bob.account));
      expect(view.record.timeouts, isEmpty);
      expect(
        mayApplyServerTimeout(
          record: view.record,
          roster: view.roster,
          actor: alice.account,
          account: bob.account,
          serverUntil: until,
          now: DateTime.now().toUtc(),
        ),
        isTrue,
      );

      // The owner applies it: every other device accepts the commit.
      final before = DateTime.now().millisecondsSinceEpoch;
      await alice.service.stageRoleChange(
        _conv,
        (c, _, now) => applyServerTimeout(
          c,
          bob.account,
          serverUntil: until,
          now: now,
        ),
      );
      // Receivers refuse an entry that does not name the epoch this commit
      // produces (badShape), so acceptance below also checks the epoch.
      await _deliver(alice, members: [carol, bob2]);
      final mine = (await alice.service.governanceView(_conv))!.record;
      final entry = mine.timeouts[bob.account]!;
      expect(entry.untilMs, until.millisecondsSinceEpoch);
      expect(entry.fromMs, greaterThanOrEqualTo(before));
      for (final member in [carol, bob2]) {
        final record = (await member.service.governanceView(_conv))!.record;
        expect(record, mine, reason: member.device);
        expect(record.timeouts[bob.account], entry, reason: member.device);
      }

      // A second tap (or another admin's) after it landed changes nothing.
      await expectLater(
        alice.service.stageRoleChange(
          _conv,
          (c, _, now) => applyServerTimeout(
            c,
            bob.account,
            serverUntil: until,
            now: now,
          ),
        ),
        throwsA(
          isA<GovernanceCommandException>().having(
            (e) => e.reason,
            'reason',
            'no_change',
          ),
        ),
      );
    },
    skip: skip,
  );
}

const _conv = 'conv_1';
int _serverIds = 0;

class _Group implements ConversationAuthority {
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationKind(String conversationId) => 'group';
  @override
  String? conversationChannel(String conversationId) => null;
}

class _Client {
  _Client(this.service, this.store, this.account, this.device, this.lists);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String account;
  final String device;
  final TestDeviceLists lists;
  int _events = 0;

  static Future<_Client> enroll(
    NativeCryptoBindings bindings,
    String name, {
    String? account,
  }) async {
    final owner = account ?? 'acct_$name';
    final device = 'dev_$name';
    final local = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: local);
    final lists = TestDeviceLists();
    service.deviceListPins = lists;
    service.conversationAuthority = _Group();
    await service.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$device',
        accountId: owner,
        deviceId: device,
        challenge: const <int>[1, 2, 3],
      ),
    );
    await service.activateSession(
      Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: owner,
        deviceId: device,
      ),
    );
    final client = _Client(service, local, owner, device, lists);
    lists.approve(owner, device, await service.currentSigningKey());
    addTearDown(service.dispose);
    return client;
  }

  Future<void> trust(_Client other) async => lists.approve(
        other.account,
        other.device,
        await other.service.currentSigningKey(),
      );

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$device${++_serverIds}',
        deviceId: device,
        accountId: account,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<void> applyCommit(_Client from, String key, List<int> commit) =>
      service.processMlsMessage(
        MlsMessage(
          id: 'mls_$key',
          conversationId: _conv,
          senderAccountId: from.account,
          senderDeviceId: from.device,
          kind: 'commit',
          payload: commit,
          idempotencyKey: key,
          syncEventId: nextEvent(),
          createdAt: DateTime.now().toUtc(),
        ),
      );
}

/// Completes [from]'s pending bundle and delivers it: the commit to
/// [members], the Welcome to [joiners].
Future<void> _deliver(
  _Client from, {
  List<_Client> joiners = const [],
  List<_Client> members = const [],
}) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  for (final member in members) {
    await member.applyCommit(from, item.idempotencyKey, bundle.commit);
  }
  for (final joiner in joiners) {
    await joiner.service.processMlsMessage(
      MlsMessage(
        id: 'mls_${++_serverIds}',
        conversationId: _conv,
        senderAccountId: from.account,
        senderDeviceId: from.device,
        kind: 'welcome',
        payload: bundle.welcome,
        idempotencyKey: '${item.idempotencyKey}:welcome:${joiner.device}',
        syncEventId: joiner.nextEvent(),
        createdAt: DateTime.now().toUtc(),
        recipientDeviceId: joiner.device,
      ),
    );
  }
}
