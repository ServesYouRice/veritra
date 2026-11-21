import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/ban_verdict.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

/// C4 against a hostile member, through the app's real receive path
/// (`NativeCryptoService.processMlsMessage`: stage, judge, merge or discard;
/// docs/crypto.md, "C4 app wiring"). Mallory runs a modified client: a raw
/// native device that stages whatever record it likes, so nothing on her
/// side checks the rules. Every honest app must refuse or hold her commits
/// and keep the record it had. Each case fails if its guard is removed:
/// the rules engine (`validateCommit`), the L1 gate on privileged committers,
/// the removal proofs, MLS epoch order, and the producer's own check.
void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  final raw = <NativeCryptoDevice>[];

  setUp(() {
    _now = DateTime.utc(2026, 11, 1);
    if (skip != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  tearDown(() {
    for (final device in raw) {
      device.close();
    }
    raw.clear();
  });

  const group = 'conv_1';

  /// Alice (owner), Bob (admin), Carol (member) on honest apps, and Mallory
  /// (moderator) on a modified client. Everyone trusts everyone's list.
  Future<_World> world() async {
    final alice = await _Client.enroll(bindings, 'alice');
    final bob = await _Client.enroll(bindings, 'bob');
    final carol = await _Client.enroll(bindings, 'carol');
    final mallory = bindings.createDevice('acct_mallory', 'dev_mallory');
    raw.add(mallory);
    final honest = [alice, bob, carol];
    for (final a in honest) {
      for (final b in honest) {
        if (!identical(a, b)) await a.trust(b);
      }
      a.lists
          .approve('acct_mallory', 'dev_mallory', mallory.signingPublicKey());
    }
    final w = _World(alice, bob, carol, mallory);
    await alice.service.initializeConversation(group, [
      await bob.keyPackage(),
      await carol.keyPackage(),
      DeviceKeyPackage(
        id: 'kp_mallory${++_serverIds}',
        deviceId: 'dev_mallory',
        accountId: 'acct_mallory',
        keyPackage: mallory.createKeyPackage(),
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      ),
    ]);
    final first = await _complete(alice);
    for (final joiner in [bob, carol]) {
      await joiner.welcome(alice, first);
    }
    mallory.joinGroup(group, first.welcome);

    await alice.service.stageRoleChange(
      group,
      (c, _, __) => c.setRole(bob.account, BuiltInRole.admin),
    );
    await w.deliverHonest(alice, await _complete(alice));
    await alice.service.stageRoleChange(
      group,
      (c, _, __) => c.setRole('acct_mallory', BuiltInRole.moderator),
    );
    await w.deliverHonest(alice, await _complete(alice));
    final record = await w.record(carol);
    expect(record.owner, alice.account);
    expect(record.admins.keys, [bob.account]);
    expect(record.moderators, {'acct_mallory'});
    expect(
      decodeGovernance(mallory.groupRoleState(group).record!),
      record,
    );
    return w;
  }

  test(
    'forged role records from a moderator are refused by every honest app',
    () async {
      final w = await world();
      final before = await w.record(w.carol);
      final epoch = w.mallory.groupEpoch(group).epoch;
      final next = before.rev + 1;

      // Each forgery is a whole commit Mallory signs; the server would
      // accept any of them (it cannot read the record).
      final forgeries = <String, (GovernanceState, GovernanceReject)>{
        'takes ownership': (
          before.copyWith(
            rev: next,
            owner: 'acct_mallory',
            moderators: <String>{},
            admins: {...before.admins, w.alice.account: next},
          ),
          GovernanceReject.ownerChange,
        ),
        'makes herself admin': (
          before.copyWith(
            rev: next,
            moderators: <String>{},
            admins: {...before.admins, 'acct_mallory': next},
          ),
          GovernanceReject.hierarchy,
        ),
        'makes a member admin': (
          before.copyWith(
            rev: next,
            admins: {...before.admins, w.carol.account: next},
          ),
          GovernanceReject.hierarchy,
        ),
        'demotes the admin who outranks her': (
          before.copyWith(
            rev: next,
            admins: const <String, int>{},
            electors: const <String>{},
          ),
          GovernanceReject.hierarchy,
        ),
        'restricts posting (admins and up only)': (
          before.copyWith(rev: next, adminsOnlyPosting: true),
          GovernanceReject.notAllowed,
        ),
        'adds an announcement channel': (
          before.copyWith(
            rev: next,
            announcementChannels: {'channel_forged'},
          ),
          GovernanceReject.notAllowed,
        ),
        'skips a revision (an allowed grant at rev + 2)': (
          before.copyWith(
            rev: next + 1,
            moderators: {...before.moderators, w.carol.account},
          ),
          GovernanceReject.badRev,
        ),
        'replays an older revision with a change': (
          before.copyWith(
            moderators: {...before.moderators, w.carol.account},
          ),
          GovernanceReject.badRev,
        ),
        'stamps ownerRev as if she were the owner': (
          before.copyWith(
            rev: next,
            ownerRev: next,
            moderators: {...before.moderators, w.carol.account},
          ),
          GovernanceReject.badShape,
        ),
        'opens an election (only electors may)': (
          before.copyWith(
            rev: next,
            election: Election(opened: next, electorate: {'acct_mallory'}),
          ),
          GovernanceReject.election,
        ),
      };
      for (final MapEntry(key: what, value: (forged, reason))
          in forgeries.entries) {
        // The rules engine alone already refuses it, for the reason named.
        final check = validateCommit(
          before,
          forged,
          'acct_mallory',
          before: before.joined.keys.toSet(),
          after: before.joined.keys.toSet(),
          epoch: epoch + 1,
        );
        expect(check.reject, reason, reason: what);

        final staged = w.mallory.stageCommitWithRoles(
          group,
          record: encodeGovernance(forged),
        );
        w.mallory.clearPendingCommit(group);
        for (final victim in [w.alice, w.bob, w.carol]) {
          await expectLater(
            victim.applyRaw('acct_mallory', 'dev_mallory', staged.commit),
            throwsA(
              isA<GovernanceRefusedException>()
                  .having((e) => e.reason, 'reason', reason.name),
            ),
            reason: what,
          );
          // Nothing merged: same record, same epoch, nothing held in Rust.
          expect(await w.record(victim), before, reason: what);
          expect(await victim.epoch(), epoch, reason: what);
        }
      }

      // Control: the same plumbing merges what the rules allow (a
      // moderator may make a member a moderator), so the refusals above
      // are the rules, not the harness.
      final allowed = before.copyWith(
        rev: next,
        moderators: {...before.moderators, w.carol.account},
      );
      final ok = w.mallory.stageCommitWithRoles(
        group,
        record: encodeGovernance(allowed),
      );
      w.mallory.mergePendingCommit(group);
      for (final victim in [w.alice, w.bob, w.carol]) {
        await victim.applyRaw('acct_mallory', 'dev_mallory', ok.commit);
        expect(await w.record(victim), allowed);
        expect(await victim.epoch(), epoch + 1);
      }
    },
    skip: skip,
  );

  test(
    'a refused commit stays refused on every retry and after a restart',
    () async {
      final w = await world();
      final before = await w.record(w.bob);
      final forged = before.copyWith(
        rev: before.rev + 1,
        owner: 'acct_mallory',
        moderators: <String>{},
        admins: {...before.admins, w.alice.account: before.rev + 1},
      );
      final staged = w.mallory.stageCommitWithRoles(
        group,
        record: encodeGovernance(forged),
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          w.bob.applyRaw('acct_mallory', 'dev_mallory', staged.commit),
          throwsA(isA<GovernanceRefusedException>()),
        );
      }
      // A fresh service over the same store (an app restart) reads the
      // committed state, which never held the forged record.
      final restarted = await w.bob.restart(bindings);
      expect(
        (await restarted.service.governanceView(group))!.record,
        before,
      );
      await expectLater(
        restarted.applyRaw('acct_mallory', 'dev_mallory', staged.commit),
        throwsA(isA<GovernanceRefusedException>()),
      );
    },
    skip: skip,
  );

  test(
    'stale epoch: a commit built before a newer one is not merged, and a '
    'replayed commit is not applied twice',
    () async {
      final w = await world();
      final start = await w.record(w.carol);
      final epoch = await w.carol.epoch();

      // Mallory stages an allowed grant on the current epoch, but Alice's
      // commit for the same epoch reaches the server first.
      final late = w.mallory.stageCommitWithRoles(
        group,
        record: encodeGovernance(
          start.copyWith(
            rev: start.rev + 1,
            moderators: {...start.moderators, w.carol.account},
          ),
        ),
      );
      await w.alice.service.stageRoleChange(
        group,
        (c, _, __) => c.setPosting(
          adminsOnly: true,
          announcementChannels: const <String>{},
        ),
      );
      final winner = await _complete(w.alice);
      await w.bob.applyCommit(w.alice, winner);
      await w.carol.applyCommit(w.alice, winner);
      final after = await w.record(w.carol);
      expect(after.adminsOnlyPosting, isTrue);
      expect(after.rev, start.rev + 1);

      // The losing commit names an epoch the group has left. MLS refuses it
      // before any judgment, and the record keeps the winner's change.
      for (final victim in [w.bob, w.carol]) {
        await expectLater(
          victim.applyRaw('acct_mallory', 'dev_mallory', late.commit),
          throwsA(anything),
        );
        expect(await w.record(victim), after);
        expect(await victim.epoch(), epoch + 1);
      }

      // The winner delivered again under a new sync event (a server replay)
      // is not a second change.
      await expectLater(
        w.carol.applyRaw(w.alice.account, w.alice.device, winner.commit),
        throwsA(anything),
      );
      expect(await w.record(w.carol), after);
      expect(await w.carol.epoch(), epoch + 1);
    },
    skip: skip,
  );

  test(
    'removal proofs: a moderator cannot force out the admin above her; '
    'the admin may remove the moderator',
    () async {
      final w = await world();
      final before = await w.record(w.carol);
      final roster = before.joined.keys.toSet();
      final without = roster.difference({w.bob.account});

      // Mallory removes Bob (an admin she does not outrank) and carries the
      // pruned record, so the rules engine alone would accept it.
      final pruned = requiredRecord(
        before,
        'acct_mallory',
        before: roster,
        after: without,
      );
      expect(
        validateCommit(
          before,
          pruned,
          'acct_mallory',
          before: roster,
          after: without,
        ).ok,
        isTrue,
      );
      final kick = w.mallory.stageCommitWithRoles(
        group,
        record: encodeGovernance(pruned),
        removes: [
          (accountId: idBytes(w.bob.account), deviceId: idBytes(w.bob.device)),
        ],
      );
      w.mallory.clearPendingCommit(group);
      for (final victim in [w.alice, w.carol]) {
        // Held (sync retries it), never merged: no proof arrives.
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            victim.applyRaw('acct_mallory', 'dev_mallory', kick.commit),
            throwsA(
              isA<GovernanceHeldException>()
                  .having((e) => e.reason, 'reason', 'removal_unproven'),
            ),
          );
          expect(await w.record(victim), before);
        }
      }

      // Bob outranks Mallory: his app commits her removal, every member
      // merges it, and her role is gone.
      await w.bob.service.stageMembershipChange(
        group,
        removes: [(accountId: 'acct_mallory', deviceId: 'dev_mallory')],
      );
      final removal = await _complete(w.bob);
      for (final member in [w.alice, w.carol]) {
        await member.applyCommit(w.bob, removal);
        final record = await w.record(member);
        expect(record.moderators, isEmpty);
        expect(record.joined.containsKey('acct_mallory'), isFalse);
        expect(record.admins.keys, [w.bob.account]);
      }
    },
    skip: skip,
  );

  test(
    'impersonation: a leaf Mallory adds under the owner\'s account id '
    'cannot act as the owner',
    () async {
      final w = await world();
      final before = await w.record(w.carol);

      // The add itself is allowed (D94: a commit is never refused for a
      // list reason) and changes no role: the account is already a member.
      final ghost = bindings.createDevice(w.alice.account, 'dev_ghost');
      raw.add(ghost);
      final add = w.mallory.stageCommitKeyed(
        group,
        adds: [
          (
            keyPackage: ghost.createKeyPackage(),
            accountId: idBytes(w.alice.account),
            deviceId: idBytes('dev_ghost'),
            signingKey: ghost.signingPublicKey(),
          ),
        ],
      );
      w.mallory.mergePendingCommit(group);
      ghost.joinGroup(group, add.welcome);
      for (final victim in [w.alice, w.bob, w.carol]) {
        await victim.applyRaw('acct_mallory', 'dev_mallory', add.commit);
        expect(await w.record(victim), before);
      }

      // The ghost (committer account: Alice) makes Mallory an admin. The
      // rules engine sees the owner granting a role and would allow it;
      // the L1 gate holds it, because Alice's list never approved the leaf.
      final grant = before.copyWith(
        rev: before.rev + 1,
        moderators: <String>{},
        admins: {...before.admins, 'acct_mallory': before.rev + 1},
        ownerRev: before.rev + 1,
      );
      expect(
        validateCommit(
          before,
          grant,
          w.alice.account,
          before: before.joined.keys.toSet(),
          after: before.joined.keys.toSet(),
        ).ok,
        isTrue,
      );
      final forged = ghost.stageCommitWithRoles(
        group,
        record: encodeGovernance(grant),
      );
      for (final victim in [w.alice, w.bob, w.carol]) {
        await expectLater(
          victim.applyRaw(w.alice.account, 'dev_ghost', forged.commit),
          throwsA(
            isA<GovernanceHeldException>()
                .having((e) => e.reason, 'reason', 'committer_unapproved'),
          ),
        );
        expect(await w.record(victim), before);
      }
    },
    skip: skip,
  );

  test(
    'the producer refuses a record its own receivers would refuse',
    () async {
      final w = await world();
      final before = await w.record(w.carol);
      // Carol (a plain member) on an honest app, with a builder that skips
      // GovernanceCommands' own checks: nothing is staged or queued.
      await expectLater(
        w.carol.service.stageRoleChange(
          group,
          (c, _, __) => c.state.copyWith(
            rev: c.state.rev + 1,
            admins: {...c.state.admins, w.carol.account: c.state.rev + 1},
          ),
        ),
        throwsA(
          isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'hierarchy'),
        ),
      );
      expect(await w.carol.store.pendingMlsMessages(), isEmpty);
      expect(await w.record(w.carol), before);
      expect(
        (await w.carol.epoch()),
        (await w.alice.epoch()),
      );
    },
    skip: skip,
  );

  // D81 owner handover.
  {
    /// Bob (an elector: the owner made him admin) opens and wins alone.
    /// [honest] uses Bob's own saved clocks; otherwise his client claims
    /// the waits are over (a modified client: receivers cannot check time).
    Future<void> handover(_World w, {required bool honest}) async {
      GovernanceObservations lying(GovernanceState state) =>
          GovernanceObservations(
            owner: state.owner,
            ownerRev: state.ownerRev,
            lastOwnerActivity: _now.subtract(const Duration(days: 40)),
            electionOpened: state.election?.opened,
            electionSeen: _now.subtract(const Duration(days: 8)),
          );
      await w.bob.service.stageRoleChange(
        group,
        (c, observed, now) =>
            c.openElection(honest ? observed! : lying(c.state), now),
      );
      await w.deliverHonest(w.bob, await _complete(w.bob));
      if (honest) _now = _now.add(const Duration(days: 8));
      await w.bob.service.stageRoleChange(
        group,
        (c, observed, now) => c.vote(
          w.bob.account,
          honest ? observed! : lying(c.state),
          now,
        ),
      );
      await w.deliverHonest(w.bob, await _complete(w.bob));
    }

    test('D81: after the waits: ownership moves and nobody is warned',
        () async {
      final w = await world();
      // Bob's app refuses to open while the owner was active here.
      await expectLater(
        w.bob.service.stageRoleChange(
          group,
          (c, observed, now) => c.openElection(observed!, now),
        ),
        throwsA(
          isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'owner_active'),
        ),
      );
      _now = _now.add(const Duration(days: 31));
      await handover(w, honest: true);
      for (final member in [w.alice, w.carol]) {
        final record = await w.record(member);
        expect(record.owner, w.bob.account);
        expect(record.election, isNull);
        expect(record.admins.keys, contains(w.alice.account));
        expect(
          await member.store.loadSetting(governanceEarlyWinSetting(group)),
          isNull,
        );
        // The server's owner row is asked to follow.
        expect(
          await member.store.loadSetting(governanceSuccessionSetting(group)),
          governanceSuccessionValue(record.rev, w.bob.account),
        );
      }
    }, skip: skip);

    test(
      'D81: a handover faster than this device\'s clocks allow is merged '
      '(every app must agree) but flagged for the roles screen',
      () async {
        final w = await world();
        await handover(w, honest: false);
        for (final member in [w.alice, w.carol]) {
          final record = await w.record(member);
          expect(record.owner, w.bob.account);
          expect(record.ownerRev, record.rev);
          expect(
            await member.store.loadSetting(governanceEarlyWinSetting(group)),
            '${record.rev}',
          );
        }
      },
      skip: skip,
    );

    test(
      'D81: the owner\'s own commit while an election is open must cancel it',
      () async {
        final w = await world();
        _now = _now.add(const Duration(days: 31));
        await w.bob.service.stageRoleChange(
          group,
          (c, observed, now) => c.openElection(observed!, now),
        );
        await w.deliverHonest(w.bob, await _complete(w.bob));
        final open = await w.record(w.carol);
        expect(open.election, isNotNull);

        // A modified owner client that keeps the election open while
        // making a decision is refused by every honest app.
        final keepOpen = open.copyWith(
          rev: open.rev + 1,
          ownerRev: open.rev + 1,
          moderators: {...open.moderators, w.carol.account},
        );
        expect(
          validateCommit(
            open,
            keepOpen,
            w.alice.account,
            before: open.joined.keys.toSet(),
            after: open.joined.keys.toSet(),
          ).reject,
          GovernanceReject.election,
        );

        // The owner's explicit cancel (the roles screen, and the automatic
        // cancel's timer: closeOwnerElection) goes through stageRoleChange
        // and its producer check, and every receiver merges it.
        await w.alice.service.stageRoleChange(
          group,
          (c, _, __) => c.closeElection(),
        );
        await w.deliverHonest(w.alice, await _complete(w.alice));
        final closed = await w.record(w.carol);
        expect(closed.election, isNull);
        expect(closed.owner, w.alice.account);
        expect(closed.ownerRev, open.ownerRev);
        expect(await w.record(w.bob), closed);

        // The cancel was owner activity: Bob's app waits another 30 days.
        await expectLater(
          w.bob.service.stageRoleChange(
            group,
            (c, observed, now) => c.openElection(observed!, now),
          ),
          throwsA(
            isA<GovernanceCommandException>()
                .having((e) => e.reason, 'reason', 'owner_active'),
          ),
        );
        _now = _now.add(const Duration(days: 31));
        await w.bob.service.stageRoleChange(
          group,
          (c, observed, now) => c.openElection(observed!, now),
        );
        await w.deliverHonest(w.bob, await _complete(w.bob));
        expect((await w.record(w.carol)).election, isNotNull);

        // Alice's honest app: her periodic self-update is the cancel.
        await w.alice.service.stageSelfUpdate(group);
        await w.deliverHonest(w.alice, await _complete(w.alice));
        final cancelled = await w.record(w.carol);
        expect(cancelled.election, isNull);
        expect(cancelled.owner, w.alice.account);
        // The cancel is not an owner decision: ownerRev stays.
        expect(cancelled.ownerRev, open.ownerRev);
      },
      skip: skip,
    );
  }

  // C4 record format 3 (docs/crypto.md, "C4 record format 3"): the C3 and
  // W8 switches and the C5 ban list, against Mallory's modified client.
  {
    /// Mallory's forged record [forged] is refused by every honest app for
    /// [reason], and nothing merges.
    Future<void> refusedEverywhere(
      _World w,
      List<_Client> victims,
      ({List<int> commit, List<int> welcome, int epoch}) staged,
      GovernanceReject reason,
      String what,
    ) async {
      for (final victim in victims) {
        final before = await w.record(victim);
        final epoch = await victim.epoch();
        await expectLater(
          victim.applyRaw('acct_mallory', 'dev_mallory', staged.commit),
          throwsA(
            isA<GovernanceRefusedException>()
                .having((e) => e.reason, 'reason', reason.name),
          ),
          reason: what,
        );
        expect(await w.record(victim), before, reason: what);
        expect(await victim.epoch(), epoch, reason: what);
      }
    }

    test(
      'record format 3: a moderator cannot switch the rules or lift a ban; the owner can, '
      'and the record moves to format 3',
      () async {
        final w = await world();
        final start = await w.record(w.carol);
        final next = start.rev + 1;
        for (final (what, forged) in [
          ('pins admins only', start.copyWith(rev: next, adminsOnlyPins: true)),
          (
            'channel info restricted',
            start.copyWith(rev: next, channelInfoRestricted: true),
          ),
          ('a ban of someone gone', start.copyWith(rev: next, bans: {'x'})),
        ]) {
          final staged = w.mallory.stageCommitWithRoles(
            group,
            record: encodeGovernance(forged),
          );
          w.mallory.clearPendingCommit(group);
          await refusedEverywhere(
            w,
            [w.alice, w.bob, w.carol],
            staged,
            GovernanceReject.notAllowed,
            what,
          );
        }
        // Format 2 until something needs format 3.
        expect(w.mallory.groupRoleState(group).record!.first, 2);

        // Alice's honest app switches pins to admins only and bans an
        // account that is not in the group.
        await w.alice.service.stageRoleChange(
          group,
          (c, _, __) => c.setAdminsOnlyPins(true),
        );
        await w.deliverHonest(w.alice, await _complete(w.alice));
        await w.alice.service.stageRoleChange(
          group,
          (c, _, __) => c.ban('acct_dave'),
        );
        await w.deliverHonest(w.alice, await _complete(w.alice));
        final ruled = await w.record(w.carol);
        expect(ruled.adminsOnlyPins, isTrue);
        expect(ruled.bans, {'acct_dave'});
        // Not an owner role decision: ownerRev stays.
        expect(ruled.ownerRev, start.ownerRev);
        expect(w.mallory.groupRoleState(group).record!.first, 3);

        // Mallory tries to undo both.
        for (final (what, forged) in [
          (
            'pins back to everyone',
            ruled.copyWith(rev: ruled.rev + 1, adminsOnlyPins: false),
          ),
          (
            'lifts the ban',
            ruled.copyWith(rev: ruled.rev + 1, bans: const <String>{}),
          ),
        ]) {
          final staged = w.mallory.stageCommitWithRoles(
            group,
            record: encodeGovernance(forged),
          );
          w.mallory.clearPendingCommit(group);
          await refusedEverywhere(
            w,
            [w.alice, w.bob, w.carol],
            staged,
            GovernanceReject.notAllowed,
            what,
          );
        }
      },
      skip: skip,
    );

    test(
      'record format 3: a moderator cannot kick and ban the admin above her',
      () async {
        final w = await world();
        final before = await w.record(w.carol);
        final roster = before.joined.keys.toSet();
        final without = roster.difference({w.bob.account});
        final pruned = requiredRecord(
          before,
          'acct_mallory',
          before: roster,
          after: without,
        );
        final banned = pruned.copyWith(
          rev: before.rev + 1,
          bans: {w.bob.account},
        );
        final kick = w.mallory.stageCommitWithRoles(
          group,
          record: encodeGovernance(banned),
          removes: [
            (
              accountId: idBytes(w.bob.account),
              deviceId: idBytes(w.bob.device),
            ),
          ],
        );
        w.mallory.clearPendingCommit(group);
        await refusedEverywhere(
          w,
          [w.alice, w.carol],
          kick,
          GovernanceReject.hierarchy,
          'kick and ban of an admin',
        );
      },
      skip: skip,
    );

    test(
      'record format 3: a ban rides in its removal commit, and nobody adds the account back '
      'until an admin lifts it',
      () async {
        final w = await world();
        // Alice's app owes Carol's ban (the server has just banned her).
        await w.alice.store.saveSetting(
          banRecordOwedSetting(group),
          encodeOwedBans({
            w.carol.account:
                _now.add(banRecordOwedLifetime).millisecondsSinceEpoch,
          }),
        );
        await w.alice.service.stageMembershipChange(
          group,
          removes: [(accountId: w.carol.account, deviceId: w.carol.device)],
        );
        final removal = await _complete(w.alice);
        await w.bob.applyCommit(w.alice, removal);
        w.mallory.stageIncomingCommit(group, removal.commit);
        w.mallory.mergeIncomingCommit(group, removal.commit);
        final banned = await w.record(w.bob);
        expect(banned.bans, {w.carol.account});
        expect(banned.joined.containsKey(w.carol.account), isFalse);
        expect(await w.record(w.alice), banned);

        // Mallory re-adds Carol: with no record change, with the `joined`
        // stamp and the ban lifted (only admins lift), and with the stamp and
        // the ban kept (bytes she builds by hand, since no honest encoder
        // writes a banned account that holds a place). Every honest app
        // refuses all three.
        final roster = banned.joined.keys.toSet();
        final withCarol = {...roster, w.carol.account};
        final package = await w.carol.keyPackage();
        final add = (
          keyPackage: package.keyPackage,
          accountId: idBytes(w.carol.account),
          deviceId: idBytes(w.carol.device),
          signingKey: await w.carol.service.currentSigningKey(),
        );
        final plain = w.mallory.stageCommitKeyed(group, adds: [add]);
        w.mallory.clearPendingCommit(group);
        await refusedEverywhere(
          w,
          [w.alice, w.bob],
          plain,
          GovernanceReject.banned,
          'add with no record change',
        );
        final stamped = requiredRecord(
          banned,
          'acct_mallory',
          before: roster,
          after: withCarol,
        );
        final lifted = w.mallory.stageCommitWithRoles(
          group,
          record: encodeGovernance(stamped.copyWith(bans: const <String>{})),
          adds: [add],
        );
        w.mallory.clearPendingCommit(group);
        await refusedEverywhere(
          w,
          [w.alice, w.bob],
          lifted,
          GovernanceReject.notAllowed,
          'add that lifts the ban',
        );
        // Same length as Carol's id, so swapping the bytes keeps the layout.
        final stand = 'acct_carox';
        expect(stand.length, w.carol.account.length);
        final handmade = encodeGovernance(stamped.copyWith(bans: {stand}));
        final at = handmade.length - stand.length;
        expect(String.fromCharCodes(handmade.sublist(at)), stand);
        handmade.setAll(at, w.carol.account.codeUnits);
        final kept = w.mallory.stageCommitWithRoles(
          group,
          record: handmade,
          adds: [add],
        );
        w.mallory.clearPendingCommit(group);
        for (final victim in [w.alice, w.bob]) {
          await expectLater(
            victim.applyRaw('acct_mallory', 'dev_mallory', kept.commit),
            throwsA(
              isA<GovernanceRefusedException>()
                  .having((e) => e.reason, 'reason', 'record_unreadable'),
            ),
          );
          expect(await w.record(victim), banned);
        }

        // Bob's honest app does not even stage the add.
        await expectLater(
          w.bob.service.stageMembershipChange(
            group,
            adds: [await w.carol.keyPackage()],
          ),
          throwsA(isA<BannedAddRefusedException>()),
        );
        expect(await w.bob.store.pendingMlsMessages(), isEmpty);

        // Alice (the owner) lifts the ban; then Bob's add goes through.
        await w.alice.service.stageRoleChange(
          group,
          (c, _, __) => c.liftBan(w.carol.account),
        );
        final lift = await _complete(w.alice);
        await w.bob.applyCommit(w.alice, lift);
        w.mallory.stageIncomingCommit(group, lift.commit);
        w.mallory.mergeIncomingCommit(group, lift.commit);
        expect((await w.record(w.bob)).bans, isEmpty);
        // Format 2 again, byte for byte, once nothing needs format 3.
        expect(w.mallory.groupRoleState(group).record!.first, 2);
        await w.bob.service.stageMembershipChange(
          group,
          adds: [await w.carol.keyPackage()],
        );
        final readd = await _complete(w.bob);
        await w.alice.applyCommit(w.bob, readd);
        expect(
          (await w.record(w.alice)).joined.containsKey(w.carol.account),
          isTrue,
        );
      },
      skip: skip,
    );
  }
}

int _serverIds = 0;

/// Every honest app's clock (D81's waits are local rules).
DateTime _now = DateTime.utc(2026, 11, 1);

class _World {
  _World(this.alice, this.bob, this.carol, this.mallory);

  final _Client alice;
  final _Client bob;
  final _Client carol;
  final NativeCryptoDevice mallory;

  Future<GovernanceState> record(_Client client) async =>
      (await client.service.governanceView('conv_1'))!.record;

  /// [from]'s accepted commit to the other honest apps and to Mallory.
  Future<void> deliverHonest(
    _Client from,
    ({String key, List<int> commit, List<int> welcome}) staged,
  ) async {
    for (final member in [alice, bob, carol]) {
      if (identical(member, from)) continue;
      await member.applyCommit(from, staged);
    }
    mallory.stageIncomingCommit('conv_1', staged.commit);
    mallory.mergeIncomingCommit('conv_1', staged.commit);
  }
}

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
    String name,
  ) async {
    final account = 'acct_$name';
    final device = 'dev_$name';
    final local = MemoryLocalStore();
    final service = NativeCryptoService(
      bindings: bindings,
      localStore: local,
      clock: () => _now,
    );
    final lists = TestDeviceLists();
    service.deviceListPins = lists;
    service.conversationAuthority = _Group();
    await service.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$device',
        accountId: account,
        deviceId: device,
        challenge: const <int>[1, 2, 3],
      ),
    );
    await service.activateSession(_session(account, device));
    final client = _Client(service, local, account, device, lists);
    lists.approve(account, device, await service.currentSigningKey());
    return client;
  }

  static Session _session(String account, String device) => Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: account,
        deviceId: device,
      );

  /// The same device after an app restart: a new service over this store.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    final again = NativeCryptoService(
      bindings: bindings,
      localStore: store,
      clock: () => _now,
    );
    again.deviceListPins = lists;
    again.conversationAuthority = _Group();
    await again.activateSession(_session(account, device));
    return _Client(again, store, account, device, lists).._events = _events;
  }

  Future<void> trust(_Client other) async => lists.approve(
        other.account,
        other.device,
        await other.service.currentSigningKey(),
      );

  Future<int> epoch() async => (await service.groupEpoch('conv_1'))!.epoch;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$device${++_serverIds}',
        deviceId: device,
        accountId: account,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<void> applyCommit(
    _Client from,
    ({String key, List<int> commit, List<int> welcome}) staged,
  ) =>
      _apply(from.account, from.device, staged.commit, key: staged.key);

  /// A commit as the server relays it, under a new sync event each time.
  Future<void> applyRaw(String account, String device, List<int> commit) =>
      _apply(account, device, commit, key: 'raw_${++_serverIds}');

  Future<void> _apply(
    String fromAccount,
    String fromDevice,
    List<int> commit, {
    required String key,
  }) {
    final event = ++_events;
    return service.processMlsMessage(
      MlsMessage(
        id: 'mls_${++_serverIds}',
        conversationId: 'conv_1',
        senderAccountId: fromAccount,
        senderDeviceId: fromDevice,
        kind: 'commit',
        payload: commit,
        idempotencyKey: key,
        syncEventId: event,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> welcome(
    _Client from,
    ({String key, List<int> commit, List<int> welcome}) staged,
  ) =>
      service.processMlsMessage(
        MlsMessage(
          id: 'mls_${++_serverIds}',
          conversationId: 'conv_1',
          senderAccountId: from.account,
          senderDeviceId: from.device,
          kind: 'welcome',
          payload: staged.welcome,
          idempotencyKey: '${staged.key}:welcome:$device',
          syncEventId: ++_events,
          createdAt: DateTime.now().toUtc(),
          recipientDeviceId: device,
        ),
      );
}

/// Completes [from]'s one pending commit bundle as the server accepting it.
Future<({String key, List<int> commit, List<int> welcome})> _complete(
  _Client from,
) async {
  final item = (await from.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await from.service.completeCommitBundle(item);
  return (
    key: item.idempotencyKey,
    commit: bundle.commit,
    welcome: bundle.welcome
  );
}
