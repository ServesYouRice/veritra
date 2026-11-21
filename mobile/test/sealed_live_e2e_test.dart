import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'live_e2e_harness.dart';

/// L2-3 sealed sender against the real server with
/// `PRIVATE_MESSENGER_SEALED_SENDER=1`: a message in a DM goes sealed (no
/// session, no sender on the post), and when the app is killed in the
/// middle of the post, the next start posts it again under the same
/// idempotency key and it arrives exactly once, still sealed. Both kill
/// points are run: after the server stored the post (the answer is lost),
/// and before the request left the device.
void main() {
  final env = LiveE2eEnv.load();

  test(
    'L2-3: a sealed post survives the app being killed mid-post',
    () async {
      final server = LiveServer(
        env.serverPath!,
        '${env.dataDir}/sealed',
        env.portBase + 3,
        environment: const <String, String>{
          'PRIVATE_MESSENGER_SEALED_SENDER': '1',
        },
      );
      addTearDown(server.stop);
      await server.start();
      final baseUrl = server.baseUrl;
      final bindings = NativeCryptoBindings.open(env.libraryPath!);
      final owner = LiveClient(bindings, baseUrl);
      addTearDown(owner.dispose);
      await owner.state.createOwner(
        baseUrl,
        'sealowner',
        'owner-password-123',
        liveSetupToken,
      );
      owner.expectOk();
      var alice = await owner.invite('sealalice');
      addTearDown(() => alice.dispose());

      final dm = await owner.state.startConversation(
        kind: 'dm',
        memberAccountIds: <String>[alice.accountId],
      );
      owner.expectOk();
      final conv = dm!.id;
      expect(await owner.state.sendMessageTo(conv, 'hello alice'), isTrue);
      await alice.waitFor(conv, (m) => m.body == 'hello alice');
      expect(await alice.state.acceptMessageRequest(conv), isTrue);

      // The server's switch reached the app, and the token pass filled
      // Alice's tokens for this conversation.
      Future<void> waitSealedReady(LiveClient client) => client.waitUntil(
            () async {
              final sealed = client.state.sealedSender;
              if (sealed == null || !sealed.enabled) {
                await client.state.refreshConversations();
                return false;
              }
              if (!sealed.activeIn(conv)) {
                sealed.contextChanged();
                await sealed.refresh(
                  client.state.api!,
                  client.state.session!.token,
                  client.state.conversations,
                );
                return false;
              }
              return true;
            },
            timeout: const Duration(seconds: 120),
          );
      await waitSealedReady(alice);

      Future<void> killedMidPost(String text, {required bool landed}) async {
        final reached = Completer<void>();
        // The post goes to the real server (or not, for the early kill);
        // then the process "dies": the answer never comes back.
        alice.state.sealedPostClientFactory = (origin) => _KilledPost(
              origin,
              sendFirst: landed,
              reached: reached,
            );
        expect(await alice.state.sendMessageTo(conv, text), isTrue);
        await reached.future.timeout(const Duration(seconds: 90));
        final queued = await alice.store.pendingEnvelopeRecords();
        final record = queued.singleWhere(
          (r) => r.envelope.conversationId == conv,
        );
        // Chosen to go sealed: the queued copy carries a token.
        expect(record.envelope.sealed, isTrue);
        if (landed) {
          // The server stored it before the kill.
          await owner.waitFor(conv, (m) => m.body == text);
        }
        alice = await alice.restart();
        // The next start posts it again, sealed, and the outbox empties.
        await alice.waitUntil(
          () async => (await alice.store.pendingEnvelopeRecords()).isEmpty,
          timeout: const Duration(seconds: 120),
        );
        final received = await owner.waitFor(conv, (m) => m.body == text);
        // Opened with the sender MLS names, not a sender the post named.
        expect(received.senderAccountId, alice.accountId);
        // Give a duplicate every chance to arrive, then count.
        expect(
          await owner.state.sendMessageTo(conv, 'barrier $text'),
          isTrue,
        );
        await alice.waitFor(conv, (m) => m.body == 'barrier $text');
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(
          (await owner.bodies(conv)).where((body) => body == text),
          hasLength(1),
          reason: 'one copy of a sealed message posted twice',
        );
        // The receiver keeps, with the message's proof, whether it came
        // sealed: its server row named no sender.
        final reveal = await owner.store.loadFrankReveal(received.key);
        expect(reveal, isNotNull);
        expect(reveal!.sealed, isTrue, reason: 'arrived identified');
        expect(reveal.senderAccountId, alice.accountId);
      }

      await killedMidPost('sealed after the server stored it', landed: true);
      await waitSealedReady(alice);
      await killedMidPost('sealed before the request left', landed: false);

      // Still a working chat both ways afterwards.
      expect(await alice.state.sendMessageTo(conv, 'still here'), isTrue);
      await owner.waitFor(conv, (m) => m.body == 'still here');
      expect(
          await owner.state.sendMessageTo(conv, 'barrier still here'), isTrue);
      await alice.waitFor(conv, (m) => m.body == 'barrier still here');

      // A blocked sender's sealed message: the server cannot tell who sent
      // it, so the app hides it by the sender MLS named, also once the
      // server's copy is no longer what the chat shows from (a restart).
      expect(await owner.state.blockAccount(alice.accountId), isTrue);
      await waitSealedReady(alice);
      expect(await alice.state.sendMessageTo(conv, 'while blocked'), isTrue);
      await alice.waitUntil(
        () async => (await alice.store.pendingEnvelopeRecords()).isEmpty,
        timeout: const Duration(seconds: 120),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      await owner.state.refreshHistory(conv);
      List<String?> shown(LiveClient client) => [
            for (final e in client.state.timelineFor(conv))
              client.state.historyFor(conv).forEnvelope(e)?.body,
          ];
      expect(shown(owner), isNot(contains('while blocked')));
      final reopened = await owner.restart();
      addTearDown(reopened.dispose);
      await reopened.waitUntil(
        () async => reopened.state.isBlocked(alice.accountId),
      );
      await reopened.state.loadMessages(conv);
      // The owner's own messages stay; every sealed one of the blocked
      // account is hidden, as the server hides its identified ones.
      expect(shown(reopened), contains('barrier still here'));
      expect(shown(reopened), isNot(contains('while blocked')));
      expect(shown(reopened), isNot(contains('still here')));
      // Unblocked, they show again: hiding deletes nothing.
      expect(await reopened.state.unblockAccount(alice.accountId), isTrue);
      expect(shown(reopened),
          containsAll(<String>['while blocked', 'still here']));
    },
    skip: env.skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// A sealed post client whose app is killed in the middle of the post:
/// with [sendFirst] the request reaches the server and the answer is lost;
/// without, the request never leaves. Either way the call never returns,
/// as nothing returns in a killed process.
class _KilledPost extends SealedPostClient {
  _KilledPost(String origin, {required this.sendFirst, required this.reached})
      : super(baseUrl: origin);

  final bool sendFirst;
  final Completer<void> reached;

  @override
  Future<void> post(MessageEnvelope envelope) async {
    if (sendFirst) await super.post(envelope);
    if (!reached.isCompleted) reached.complete();
    await Completer<void>().future;
  }
}
