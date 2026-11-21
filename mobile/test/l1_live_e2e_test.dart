import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'live_e2e_harness.dart';

/// L1-5 (docs/designs/L1-approved-device-list.md, "L1-5 Review and demo"),
/// live against the real server: register, link a second device, message,
/// revoke it, then recover the account on a new device with the recovery
/// key, with a malicious server in between. The server is a test-hook build
/// (`veritra_testhooks`, development only) whose offline hook inserts a
/// device of the owner's account that no signed list version names, with a
/// real key package, and indexes it on the head so the server offers it to
/// every peer: listed as a pending add and handed out on claim. The run
/// shows that no peer, and no device of the owner, ever adds it, while the
/// chat keeps working.
void main() {
  final env = LiveE2eEnv.load();

  test(
    'L1-5: register, link, message, revoke, recover; an unlisted device '
    'the server offers is never added',
    () async {
      final port = env.portBase + 5;
      final server = LiveServer(
        env.testHookServerPath!,
        '${env.dataDir}/l1',
        port,
        environment: <String, String>{
          // K0-R recovery stays off without it; the proof names it.
          'PRIVATE_MESSENGER_PUBLIC_ORIGIN': 'http://127.0.0.1:$port',
        },
      );
      addTearDown(server.stop);
      await server.start();
      final baseUrl = server.baseUrl;
      final bindings = NativeCryptoBindings.open(env.libraryPath!);

      // Device links, reauthentication and recovery share the server's
      // fixed credential budget of one address (10 a minute), and every
      // client here is on the same address: a refused step is tried again
      // once the window has moved on.
      Future<void> paced(
        LiveClient client,
        Future<bool> Function() step, {
        Duration timeout = const Duration(seconds: 150),
      }) =>
          client.waitUntil(() async {
            if (await step()) return true;
            await Future<void>.delayed(const Duration(seconds: 5));
            return false;
          }, timeout: timeout);
      Future<void> reauth(LiveClient client, String password) =>
          paced(client, () => client.state.reauthenticate(password));

      // Register.
      final owner = LiveClient(bindings, baseUrl);
      addTearDown(owner.dispose);
      await owner.state.createOwner(
        baseUrl,
        'l1owner',
        'owner-password-123',
        liveSetupToken,
      );
      owner.expectOk();
      final alice = await owner.invite('l1alice');
      addTearDown(alice.dispose);
      final ownerId = owner.accountId;

      // Message.
      final dm = await owner.state.startConversation(
        kind: 'dm',
        memberAccountIds: <String>[alice.accountId],
      );
      owner.expectOk();
      final conv = dm!.id;
      expect(await owner.state.sendMessageTo(conv, 'hello alice'), isTrue);
      await alice.waitFor(conv, (m) => m.body == 'hello alice');
      expect(await alice.state.acceptMessageRequest(conv), isTrue);
      expect(await alice.state.sendMessageTo(conv, 'hi owner'), isTrue);
      await owner.waitFor(conv, (m) => m.body == 'hi owner');

      // Link a second device (v3: commit, reveal, compare, approve). The
      // owner's device signs it onto the list.
      final second = LiveClient(bindings, baseUrl);
      addTearDown(second.dispose);
      await reauth(owner, 'owner-password-123');
      await owner.state.createDeviceLink();
      expect(owner.state.errorFor(Ops.deviceLink), isNull);
      await second.state.claimDeviceLink(
        baseUrl,
        owner.state.activeDeviceLinkCode!,
      );
      second.expectOk();
      await owner.state.refreshActiveDeviceLink();
      await second.state.completeDeviceLinkClaim();
      second.expectOk();
      await owner.state.approveActiveDeviceLink(
        second.state.pendingDeviceLinkClaim!.verificationCode,
      );
      expect(
        owner.state.errorFor(Ops.deviceLink),
        isNull,
        reason: owner.state.errorFor(Ops.deviceLink),
      );
      await second.state.completeDeviceLinkClaim();
      second.expectOk();
      expect(second.accountId, ownerId);
      final secondDevice = second.deviceId;
      // A member device adds it to the chat (I51); the owner's coordinator
      // fallback can take three minutes.
      await second.waitUntil(
        () async => await second.epoch(conv) != null,
        timeout: const Duration(minutes: 4),
      );
      // Alice's pin of the owner's list predates the link: her first send
      // can meet the approval hold until her device has checked the new
      // version (a refused send refreshes it).
      await alice.waitUntil(
        () => alice.state.sendMessageTo(conv, 'to both'),
        timeout: const Duration(seconds: 60),
      );
      await second.waitFor(conv, (m) => m.body == 'to both');
      await owner.waitFor(conv, (m) => m.body == 'to both');

      // Revoke: the owner's device signs the removal; peers remove the leaf
      // and the revoked device gets nothing sent after it.
      final beforeRevoke = (await alice.epoch(conv))!;
      await reauth(owner, 'owner-password-123');
      await owner.state.revokeDevice(secondDevice);
      owner.expectOk();
      // The server tells the group live (no other traffic here wakes the
      // coordinator, which may be Alice's device), so the removal lands
      // within seconds, not at some later catch-up.
      await alice.waitUntil(
        () async {
          final leaves = await alice.crypto.debugGroupLeaves(conv);
          return ((await alice.epoch(conv)) ?? 0) > beforeRevoke &&
              leaves != null &&
              !leaves.any((l) => l.deviceId == secondDevice);
        },
        timeout: const Duration(seconds: 60),
      );
      expect(await alice.state.sendMessageTo(conv, 'after revoke'), isTrue);
      await owner.waitFor(conv, (m) => m.body == 'after revoke');
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await second.bodies(conv), isNot(contains('after revoke')));

      // The recovery key, on the owner's only device now, for the end.
      await owner.state.refreshRecoveryKeyStatus();
      final key = await owner.state.createRecoveryKeyDraft();
      final typed = key.display;
      var saved = await owner.state.saveRecoveryKey(key);
      if (saved == RecoveryActionResult.needsRecentAuth) {
        await reauth(owner, 'owner-password-123');
        saved = await owner.state.saveRecoveryKey(key);
      }
      expect(
        saved,
        RecoveryActionResult.done,
        reason: owner.state.errorFor(Ops.recoveryKey),
      );
      key.dispose();

      // The malicious server: with the server stopped, a device of the
      // owner's account goes in with a real key package for its id, on no
      // signed version, and indexed on the head so every gate offers it.
      final random = Random.secure();
      final ghostId = 'dev_${[
        for (var i = 0; i < 16; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join()}';
      final ghost = bindings.createDevice(ownerId, ghostId);
      final credential = ghost.createEnrollmentCredential(
        Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256))),
      );
      ghost.close();
      final packageFile = File(
        '${Directory.systemTemp.createTempSync('veritra-l1-ghost-').path}'
        '/key-package',
      )..writeAsBytesSync(credential.deviceKeyPackage);
      await server.stop();
      final inserted = await server.runOffline(<String>[
        'test-insert-unlisted-device',
        ownerId,
        ghostId,
        packageFile.path,
      ]);
      expect(inserted.exitCode, 0, reason: '${inserted.stderr}');
      await server.start();

      // The server now offers it to Alice as a pending add in the chat.
      final aliceApi = alice.state.api!;
      await alice.waitUntil(() async {
        final pending = await aliceApi.mlsPendingChanges(
          alice.state.session!.token,
        );
        return pending.any(
          (change) =>
              change.conversationId == conv &&
              change.add.any((ref) => ref.deviceId == ghostId),
        );
      });

      Future<void> neverAdded(List<LiveClient> clients) async {
        for (final client in clients) {
          final leaves = await client.crypto.debugGroupLeaves(conv);
          expect(leaves, isNotNull);
          expect(
            leaves!.map((l) => l.deviceId),
            isNot(contains(ghostId)),
            reason: 'a device no signed list names joined the chat',
          );
        }
      }

      // Messages both ways drive reconcile passes on both ends while the
      // offer stands; neither adds the device.
      for (var round = 0; round < 3; round++) {
        expect(
          await alice.state.sendMessageTo(conv, 'alice $round'),
          isTrue,
        );
        await owner.waitFor(conv, (m) => m.body == 'alice $round');
        expect(
          await owner.state.sendMessageTo(conv, 'owner $round'),
          isTrue,
        );
        await alice.waitFor(conv, (m) => m.body == 'owner $round');
        await alice.state.refreshConversations();
        await owner.state.refreshConversations();
        await Future<void>.delayed(const Duration(seconds: 2));
        await neverAdded(<LiveClient>[alice, owner]);
      }
      // Still offered: no commit adding it ever reached the server.
      final stillPending = await aliceApi.mlsPendingChanges(
        alice.state.session!.token,
      );
      expect(
        stillPending.any(
          (change) =>
              change.conversationId == conv &&
              change.add.any((ref) => ref.deviceId == ghostId),
        ),
        isTrue,
      );

      // Recover: the owner loses the device; a new one recovers the
      // account with the recovery key (L1 change 4, signed with it), and
      // Alice's device adds the recovered device, never the ghost.
      final lostDevice = owner.deviceId;
      await owner.state.logout();
      owner.dispose();
      final recovered = LiveClient(bindings, baseUrl);
      addTearDown(recovered.dispose);
      expect(
        await recovered.state.startAccountRecovery(
          baseUrl: baseUrl,
          username: 'l1owner',
          password: 'owner-password-123',
          recoveryKey: typed,
        ),
        isTrue,
        reason: recovered.state.errorFor(Ops.accountRecovery),
      );
      await recovered.waitUntil(() async {
        if (recovered.state.session != null) return true;
        // Each check spends the credential budget: not every poll.
        await recovered.state.checkAccountRecovery();
        if (recovered.state.session != null) return true;
        await Future<void>.delayed(const Duration(seconds: 3));
        return false;
      }, timeout: const Duration(minutes: 2));
      expect(recovered.accountId, ownerId);
      expect(recovered.deviceId, isNot(lostDevice));
      await recovered.state.finishRecoveryRestoreStep();
      final fresh = await recovered.state.createRecoveryKeyDraft();
      var savedFresh = await recovered.state.saveRecoveryKey(fresh);
      if (savedFresh == RecoveryActionResult.needsRecentAuth) {
        await reauth(recovered, 'owner-password-123');
        savedFresh = await recovered.state.saveRecoveryKey(fresh);
      }
      expect(savedFresh, RecoveryActionResult.done);
      fresh.dispose();
      await recovered.state.changePassword('owner-password-456');
      recovered.expectOk();
      await recovered.waitUntil(
        () async => await recovered.epoch(conv) != null,
        timeout: const Duration(minutes: 4),
      );
      expect(
        await recovered.state.sendMessageTo(conv, 'after recovery'),
        isTrue,
      );
      await alice.waitFor(
        conv,
        (m) => m.body == 'after recovery',
        timeout: const Duration(minutes: 2),
      );
      expect(await alice.state.sendMessageTo(conv, 'welcome back'), isTrue);
      await recovered.waitFor(
        conv,
        (m) => m.body == 'welcome back',
        timeout: const Duration(minutes: 2),
      );
      await neverAdded(<LiveClient>[alice, recovered]);
      final leaves = (await alice.crypto.debugGroupLeaves(conv))!;
      expect(
        leaves.map((l) => l.deviceId).toSet(),
        <String>{alice.deviceId, recovered.deviceId},
      );
    },
    skip: env.skipTestHooks,
    timeout: const Timeout(Duration(minutes: 16)),
  );
}
