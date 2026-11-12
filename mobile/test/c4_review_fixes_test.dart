import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/sync/conversation_pause.dart';
import 'package:private_messenger/sync/sync_recovery.dart';

// C4/C5 review fixes (2026-11-11): held commits, owner decision B, and the
// deferred moderator delete. The native sequences are in
// c4_held_commits_native_test.dart.

const owner = 'acc_owner';
const mod = 'acc_mod';
const bob = 'acc_bob';

GovernanceState record() => GovernanceState(
      rev: 3,
      owner: owner,
      ownerRev: 1,
      moderators: {mod},
      joined: {owner: 0, mod: 1, bob: 2},
    );

class _Roles implements ConversationAuthority, VerifiedRoleSource {
  _Roles(this.state, {this.role});
  final GovernanceState? state;
  final String? role;
  @override
  GovernanceState? governanceOf(String conversationId) => state;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
  @override
  String? roleOf(String conversationId, String accountId) => role;
  @override
  Set<String> memberAccounts(String conversationId) => {owner, mod, bob};
  @override
  String? conversationKind(String conversationId) => 'community_shared';
  @override
  String? conversationChannel(String conversationId) => null;
}

void main() {
  group('held commits', () {
    final at = DateTime.utc(2026, 11, 11, 12);
    ConversationPause pause(SyncFailureKind kind, {int generation = 1}) =>
        ConversationPause(
          conversationId: 'conv',
          resumeAfter: 9,
          failedEventId: 10,
          kind: kind,
          recordedAt: at,
          generation: generation,
        );

    test('a held commit pauses only its conversation and stays retryable', () {
      expect(
          failurePausesConversation(const SyncEventFailure(
              SyncFailureKind.governanceHeld,
              eventId: 10,
              eventType: 'mls.message.created',
              conversationId: 'conv')),
          isTrue);
      final held = pause(SyncFailureKind.governanceHeld);
      expect(held.held, isTrue);
      expect(held.retryable, isTrue);
      expect(held.choices, contains(SyncRecoveryChoice.leaveConversation));
      expect(pause(SyncFailureKind.mlsState).held, isFalse);
    });

    test('sync replays it by itself, with a backoff bounded at six hours', () {
      expect(heldRetryDelay(1), const Duration(minutes: 1));
      expect(heldRetryDelay(2), const Duration(minutes: 2));
      expect(heldRetryDelay(5), const Duration(minutes: 16));
      expect(heldRetryDelay(40), const Duration(hours: 6));
      final held = pause(SyncFailureKind.governanceHeld, generation: 3);
      expect(held.heldRetryDue(at.add(const Duration(minutes: 3))), isFalse);
      expect(held.heldRetryDue(at.add(const Duration(minutes: 4))), isTrue);
      // Any other pause waits for the user.
      expect(
          pause(SyncFailureKind.mlsState)
              .heldRetryDue(at.add(const Duration(days: 1))),
          isFalse);
    });

    test('the exception names why, without content', () {
      expect(const GovernanceHeldException('removal_unproven').toString(),
          'GovernanceHeldException(removal_unproven)');
    });
  });

  group('owner decision B: a removed leaf acts with no role', () {
    DeleteMessageEffect delete({required bool actsWithRole}) =>
        messageEffectsFor(
          const DecryptedAppPayload(
              type: AppPayloadType.delete,
              actionId: 'd1',
              body: {'message_id': 'dev_bob:m1'}),
          conversationId: 'conv',
          senderAccountId: mod,
          senderDeviceId: 'dev_mod_old',
          createdAt: 1,
          state: LocalMessageState.received,
          authority: _Roles(record()),
          senderActsWithRole: actsWithRole,
        ).whereType<DeleteMessageEffect>().single;

    test('a moderator delete from a removed leaf is the author\'s own only',
        () {
      final approved = delete(actsWithRole: true);
      expect(approved.allows(bob), isTrue);
      final removed = delete(actsWithRole: false);
      expect(removed.moderatorProtects, isNull);
      expect(removed.allows(bob), isFalse);
      expect(removed.allows(mod), isTrue);
    });

    test('a pin from a removed leaf uses no community role', () {
      List<MessageEffect> pin(bool actsWithRole) => messageEffectsFor(
            const DecryptedAppPayload(
                type: AppPayloadType.pin,
                actionId: 'p1',
                body: {
                  'message_id': 'dev_bob:m1',
                  'pinned': true,
                  'duration_seconds': 86400
                }),
            conversationId: 'conv',
            senderAccountId: mod,
            senderDeviceId: 'dev_mod_old',
            createdAt: 1,
            state: LocalMessageState.received,
            authority: _Roles(record(), role: 'moderator'),
            senderActsWithRole: actsWithRole,
          );
      expect(pin(true).whereType<PinMessageEffect>(), hasLength(1));
      expect(pin(false).whereType<PinMessageEffect>(), isEmpty);
    });

    test('an admin\'s restricted post from a removed leaf is dropped', () {
      final admins = record().copyWith(admins: {mod: 1}, moderators: {});
      final restricted = admins.copyWith(adminsOnlyPosting: true);
      bool drop({bool removed = false}) => shouldDropRestrictedPost(
            record: restricted,
            sender: mod,
            channelId: null,
            serverRestricts: false,
            senderRemoved: removed,
          );
      expect(drop(), isFalse);
      expect(drop(removed: true), isTrue);
      // Unrestricted, an ordinary post from that leaf keeps its handling.
      expect(
          shouldDropRestrictedPost(
              record: admins,
              sender: mod,
              channelId: null,
              serverRestricts: false,
              senderRemoved: true),
          isFalse);
    });
  });

  group('deferred moderator delete', () {
    LocalMessage target(String sender) => LocalMessage(
        key: 'dev_x:m1',
        conversationId: 'conv',
        senderAccountId: sender,
        senderDeviceId: 'dev_x',
        kind: 'text',
        body: 'hello',
        createdAt: 1,
        state: 'received',
        senderHidden: false);

    HistoryNamespace deferred(Set<String>? protects) {
      final namespace = HistoryNamespace();
      deferHistoryEffect(
          namespace,
          DeleteMessageEffect(
            targetKey: 'dev_x:m1',
            deleterAccountId: mod,
            at: 5,
            conversationId: 'conv',
            moderatorProtects: protects,
          ),
          'acc_me');
      return namespace;
    }

    test('applies to a message the moderator outranks once it arrives', () {
      final namespace = deferred({mod, owner});
      final applied = applyDeferredHistory(namespace, target(bob), 'acc_me',
          targetAuthenticated: true);
      expect(applied.body, isNull);
      expect(applied.deletedAt, 5);
    });

    test('never to a protected sender, and an author-only delete as before',
        () {
      expect(
          applyDeferredHistory(deferred({mod, owner}), target(owner), 'acc_me',
                  targetAuthenticated: true)
              .body,
          'hello');
      expect(
          applyDeferredHistory(deferred(null), target(bob), 'acc_me',
                  targetAuthenticated: true)
              .body,
          'hello');
    });

    test('the reach survives the journal round trip; an edit carries none', () {
      final effect = deferred({owner, mod}).deferred.values.single;
      final json = effect.toJson();
      expect(json['protects'], [owner, mod]..sort());
      final back = DeferredHistoryEffect.fromJson(json);
      expect(back.protects, {owner, mod});
      // A journal entry from before this change has no reach.
      final legacy = Map<String, Object?>.of(json)..remove('protects');
      expect(DeferredHistoryEffect.fromJson(legacy).protects, isNull);
      final edit = <String, Object?>{
        ...json,
        'deleted': false,
        'body': 'x',
      };
      expect(() => DeferredHistoryEffect.fromJson(edit), throwsFormatException);
    });
  });
}
