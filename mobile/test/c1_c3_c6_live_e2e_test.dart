import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/reports_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/report_body.dart';

import 'live_e2e_harness.dart';

/// Communities against the real server with its default switches (as in
/// production): C1 joining by link with an admin's approval, a declined
/// request and a removal; C3 private channels and conversion both ways; and
/// C6 reports reaching the community's moderators and the instance owner.
void main() {
  final env = LiveE2eEnv.load();

  late LiveServer server;
  late NativeCryptoBindings bindings;
  late LiveClient owner;

  Future<void> startOwner(String name) async {
    server = LiveServer(
      env.serverPath!,
      '${env.dataDir}/$name',
      env.portBase + 1,
    );
    addTearDown(server.stop);
    await server.start();
    bindings = NativeCryptoBindings.open(env.libraryPath!);
    owner = LiveClient(bindings, server.baseUrl);
    addTearDown(owner.dispose);
    await owner.state.createOwner(
      server.baseUrl,
      '${name}owner',
      'owner-password-123',
      liveSetupToken,
    );
    owner.expectOk();
  }

  Future<LiveClient> member(String username) async {
    final client = await owner.invite(username);
    addTearDown(client.dispose);
    return client;
  }

  /// A community with the C0 layout and an open channel, its shared group
  /// set up on the owner's device.
  Future<({Community community, String shared, Channel general})>
      community() async {
    final made = await owner.state.createCommunity('club');
    owner.expectOk();
    final shared = made!.sharedConversationId;
    expect(shared, isNotNull, reason: 'C0 layout: one shared group');
    await owner.waitUntil(() async => await owner.epoch(shared!) != null);
    final general = await owner.state.createChannel(
      made.id,
      'general',
      kind: 'open',
    );
    owner.expectOk();
    return (community: made, shared: shared!, general: general!);
  }

  Future<void> post(
      LiveClient client, String conv, String channelId, String text) async {
    client.state.selectChannel(conv, channelId);
    expect(await client.state.sendMessageTo(conv, text), isTrue,
        reason: client.state.error);
  }

  /// [client]'s copy of the channel [channelId] once its list has it.
  Future<Channel> channelOf(
    LiveClient client,
    String communityId,
    String channelId, {
    bool Function(Channel channel)? where,
  }) async {
    Channel? found;
    await client.waitUntil(() async {
      await client.state.refreshCommunities();
      found = client.state.channelsByCommunity[communityId]
          ?.where((c) => c.id == channelId && (where?.call(c) ?? true))
          .firstOrNull;
      return found != null;
    });
    return found!;
  }

  test(
    'C1: a link, an admin approval, a declined request and a removal',
    () async {
      await startOwner('c1');
      final carol = await member('c1carol');
      final dave = await member('c1dave');
      final erin = await member('c1erin');
      final made = await community();
      final id = made.community.id;
      final shared = made.shared;

      // Carol files a request through a link; nothing reaches her until an
      // admin approves it.
      final link = await owner.state.createInviteLink(
        InviteTargetKind.community,
        id,
      );
      owner.expectOk();
      final parsed = MembershipInviteLink.tryParse(
        link!,
        expectedOrigin: server.baseUrl,
      );
      // The link's secret stays after the `#`: never sent to the server.
      expect(link, contains('#'));
      expect(await carol.state.requestToJoin(parsed!), isNotNull);
      carol.expectOk();
      await post(owner, shared, made.general.id, 'before approval');
      var requests = await owner.state.loadJoinRequests(
        InviteTargetKind.community,
        id,
      );
      final request = requests!.singleWhere(
        (r) => r.accountId == carol.accountId,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await carol.epoch(shared), isNull);
      expect(
          await owner.state.decideJoinRequest(request, approve: true), isTrue);
      owner.expectOk();
      await carol.waitUntil(() async {
        await carol.state.refreshConversations();
        await carol.state.refreshCommunities();
        return await carol.epoch(shared) != null;
      }, timeout: const Duration(seconds: 120));
      // Joined after it was sent: MLS keeps the earlier post from her.
      await post(owner, shared, made.general.id, 'welcome carol');
      await carol.waitFor(shared, (m) => m.body == 'welcome carol');
      expect(await carol.bodies(shared), isNot(contains('before approval')));
      // The member list names her, with her username.
      await owner.state.loadConversationMembers(shared);
      expect(
        owner.state.membersByConversation[shared]!.map((m) => m.accountId),
        contains(carol.accountId),
      );

      // Dave's request is declined: he never joins.
      expect(await dave.state.requestToJoin(parsed), isNotNull);
      requests = await owner.state.loadJoinRequests(
        InviteTargetKind.community,
        id,
      );
      final daves = requests!.singleWhere((r) => r.accountId == dave.accountId);
      expect(
          await owner.state.decideJoinRequest(daves, approve: false), isTrue);
      owner.expectOk();

      // Erin joins too, to see what Carol no longer does.
      await owner.join(erin, id, shared);
      await post(owner, shared, made.general.id, 'with erin');
      await carol.waitFor(shared, (m) => m.body == 'with erin');
      await erin.waitFor(shared, (m) => m.body == 'with erin');

      // Carol is removed: her device leaves the group by a commit before
      // the next post goes out (D68), so it never reaches her.
      final before = (await owner.epoch(shared))!;
      expect(
          await owner.state.removeCommunityMember(id, carol.accountId), isTrue);
      owner.expectOk();
      await owner.waitUntil(
        () async => ((await owner.epoch(shared)) ?? 0) > before,
      );
      await post(owner, shared, made.general.id, 'after carol');
      await erin.waitFor(shared, (m) => m.body == 'after carol');
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        await carol.state.refreshHistory(shared);
      } on Object {
        // A refused read is the expected outcome for a former member.
      }
      expect(await carol.bodies(shared), contains('with erin'));
      expect(await carol.bodies(shared), isNot(contains('after carol')));
      await carol.waitUntil(() async {
        await carol.state.refreshCommunities();
        return !carol.state.communities.any((c) => c.id == id);
      });
      // Dave was never in.
      await dave.state.refreshConversations();
      expect(
          dave.state.conversations.map((c) => c.id), isNot(contains(shared)));
      expect(await dave.epoch(shared), isNull);
    },
    skip: env.skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'C3: a private channel reaches only its picks, and converts both ways',
    () async {
      await startOwner('c3');
      final carol = await member('c3carol');
      final dave = await member('c3dave');
      final made = await community();
      final id = made.community.id;
      final shared = made.shared;
      await owner.join(carol, id, shared);
      await owner.join(dave, id, shared);

      // A private channel: its own group, with the owner's pick only.
      final staff =
          await owner.state.createChannel(id, 'staff', kind: 'private');
      owner.expectOk();
      expect(staff!.kind, 'private');
      final staffConv = staff.conversationId!;
      expect(staffConv, isNot(shared));
      await owner.waitUntil(() async => await owner.epoch(staffConv) != null);
      expect(
        await owner.state.addConversationMember(staffConv, carol.accountId),
        isTrue,
        reason: owner.state.error,
      );
      await carol.waitUntil(() async {
        await carol.state.refreshConversations();
        return await carol.epoch(staffConv) != null;
      }, timeout: const Duration(seconds: 120));
      expect(await owner.state.sendMessageTo(staffConv, 'staff only'), isTrue);
      await carol.waitFor(staffConv, (m) => m.body == 'staff only');
      // Dave is not in it: no group, no rows, and the server's list for him
      // has no such conversation.
      await post(owner, shared, made.general.id, 'barrier one');
      await dave.waitFor(shared, (m) => m.body == 'barrier one');
      await dave.state.refreshConversations();
      expect(
        dave.state.conversations.map((c) => c.id),
        isNot(contains(staffConv)),
      );
      expect(await dave.epoch(staffConv), isNull);
      expect(await dave.bodies(staffConv), isEmpty);

      // Open to private: Carol is ticked, Dave is not. The earlier post
      // carries over for the reader who stays.
      final lobby = await owner.state.createChannel(id, 'lobby', kind: 'open');
      owner.expectOk();
      await post(owner, shared, lobby!.id, 'lobby before');
      await carol.waitFor(shared, (m) => m.body == 'lobby before');
      await dave.waitFor(shared, (m) => m.body == 'lobby before');
      final lobbyOwner = await channelOf(owner, id, lobby.id);
      expect(
        await owner.state.convertChannel(
          lobbyOwner,
          toPrivate: true,
          members: <String>[carol.accountId],
        ),
        isTrue,
        reason: owner.state.error,
      );
      final privateLobby = await channelOf(
        owner,
        id,
        lobby.id,
        where: (c) => c.kind == 'private',
      );
      final lobbyConv = privateLobby.conversationId!;
      expect(lobbyConv, isNot(shared));
      await carol.waitUntil(() async {
        await carol.state.refreshConversations();
        return await carol.epoch(lobbyConv) != null;
      }, timeout: const Duration(seconds: 120));
      expect(
          await owner.state.sendMessageTo(lobbyConv, 'lobby private'), isTrue);
      await carol.waitFor(lobbyConv, (m) => m.body == 'lobby private');
      await post(owner, shared, made.general.id, 'barrier two');
      await dave.waitFor(shared, (m) => m.body == 'barrier two');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await dave.epoch(lobbyConv), isNull);
      expect(await dave.bodies(lobbyConv), isNot(contains('lobby private')));
      expect(await dave.bodies(shared), isNot(contains('lobby private')));

      // Private to open: the staff channel moves into the shared group;
      // Dave reads what is posted there from now on.
      final staffOwner = await channelOf(owner, id, staff.id);
      expect(
        await owner.state.convertChannel(staffOwner, toPrivate: false),
        isTrue,
        reason: owner.state.error,
      );
      final openStaff = await channelOf(
        owner,
        id,
        staff.id,
        where: (c) => c.kind == 'open',
      );
      expect(openStaff.conversationId, shared);
      await channelOf(
        dave,
        id,
        staff.id,
        where: (c) => c.conversationId == shared,
      );
      await post(owner, shared, staff.id, 'staff now open');
      final seen = await dave.waitFor(
        shared,
        (m) => m.body == 'staff now open',
      );
      expect(seen.channelId, staff.id);
    },
    skip: env.skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'C6: a report reaches the community moderators and the instance owner',
    () async {
      await startOwner('c6');
      final carol = await member('c6carol');
      final dave = await member('c6dave');
      final made = await community();
      final id = made.community.id;
      final shared = made.shared;
      await owner.join(carol, id, shared);
      await owner.join(dave, id, shared);

      // The owner (moderator by the community's verified record) makes a
      // moderator report key; it is announced to members over MLS.
      final moderatorInbox = owner.state.reportsService!.forCommunity(id);
      await moderatorInbox.createKey(expectedKey: null);
      // Dave posts; Carol reports it to the moderators.
      await post(dave, shared, made.general.id, 'rude words');
      final rude = await carol.waitFor(shared, (m) => m.body == 'rude words');
      final reporter = carol.state.reportsService!;
      await carol.waitUntil(() async {
        try {
          await reporter.prepare(shared);
          return true;
        } on ReportFailureException catch (err) {
          if (err.kind != ReportFailure.moderatorKeysPending &&
              err.kind != ReportFailure.noRecipients) {
            rethrow;
          }
          // The foreground pass asks for missing announcements.
          await carol.state.refreshConversations();
          return false;
        }
      }, timeout: const Duration(seconds: 120));
      await reporter.file(
        conversationId: shared,
        messageKey: rude.key,
        reason: ReportReason.harassment,
      );
      final moderatorRows = await moderatorInbox.list();
      expect(moderatorRows, hasLength(1));
      final opened = await moderatorInbox.open(moderatorRows.single);
      expect(opened.isOpen, isTrue, reason: '${opened.failure}');
      expect(opened.text, 'rude words');
      expect(opened.reason, ReportReason.harassment);
      expect(
        (await moderatorInbox.verify(opened)).verdict,
        ReportVerdict.verified,
      );
      // Dave, a plain member, holds no moderator inbox.
      expect(
        await dave.state.reportsService!.forCommunity(id).list(),
        isEmpty,
      );

      // From a DM, a report goes to the instance owner, after Carol
      // compared and pinned the owner's key.
      final ownerInbox = owner.state.reportsService!;
      await ownerInbox.createKey(replace: true, expectedKey: null);
      final dm = await dave.state.startConversation(
        kind: 'dm',
        memberAccountIds: <String>[carol.accountId],
      );
      dave.expectOk();
      expect(await dave.state.sendMessageTo(dm!.id, 'spam link'), isTrue);
      final spam = await carol.waitFor(dm.id, (m) => m.body == 'spam link');
      final plan = await reporter.prepare(dm.id);
      expect(plan.check.allPinned, isFalse);
      await reporter.pinKeys(plan);
      await reporter.file(
        conversationId: dm.id,
        messageKey: spam.key,
        reason: ReportReason.spam,
      );
      final ownerRows = await ownerInbox.list();
      expect(ownerRows, hasLength(1));
      final ownerOpened = await ownerInbox.open(ownerRows.single);
      expect(ownerOpened.text, 'spam link');
      expect(ownerOpened.reason, ReportReason.spam);
      expect(
        (await ownerInbox.verify(ownerOpened)).verdict,
        ReportVerdict.verified,
      );
      // A second report of the same message is refused on the device.
      await expectLater(
        reporter.file(
          conversationId: dm.id,
          messageKey: spam.key,
          reason: ReportReason.spam,
        ),
        throwsA(isA<ReportFailureException>()),
      );
    },
    skip: env.skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
