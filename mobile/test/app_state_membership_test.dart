import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'invite_binding_fixtures.dart';
import 'test_crypto_service.dart';

/// An engine where this device (acct_owner on dev_owner) is in [groups] with
/// its own key, as an inviter must be in the group it anchors (v3).
TestOnlyCryptoService _inGroups(List<String> groups) {
  final crypto = TestOnlyCryptoService();
  for (final group in groups) {
    crypto.memberKeys['$group|acct_owner|dev_owner'] = testDeviceSigningKey;
  }
  return crypto;
}

/// C1 actions of [AppState]: what reaches the server, and what stays local.
void main() {
  test(
    'an invitation link is made locally and only its locator is sent',
    () async {
      final api = _Api();
      final state = _state(api, crypto: _inGroups(<String>['conv_1']));
      final url = await state.createInviteLink(
        InviteTargetKind.group,
        'conv_1',
      );

      expect(url, isNotNull);
      final link = MembershipInviteLink.tryParse(
        url!,
        expectedOrigin: 'https://localhost:8080',
      );
      expect(link, isNotNull);
      expect(api.createdLocators, <String>[link!.locator]);
      expect(api.createdTargets, <String>['group:conv_1']);
      expect(api.createdAnchors, <String>['conv_1']);
      final secret = Uri.parse(url).fragment.split('.')[1];
      expect(api.createdLocators.single, isNot(contains(secret)));
      expect(state.errorFor(Ops.membership), isNull);

      // The invitation is bound to this account's device key and the target:
      // the key the engine reports and a tag only the link can reproduce.
      expect(api.createdKeys.single, testDeviceSigningKey);
      final tag = api.createdTags.single;
      expect(tag, matches(RegExp(r'^[0-9a-f]{64}$')));
      final signature = api.createdSignatures.single;
      final binding = InviteBinding(
        kind: InviteTargetKind.group,
        targetId: 'conv_1',
        anchorGroupId: 'conv_1',
        inviterAccountId: 'acct_owner',
        inviterDeviceId: 'dev_owner',
        inviterSigningKey: testDeviceSigningKey,
        tag: tag,
        signature: Uint8List.fromList(signature),
      );
      // The link commits to the device key, the tag is the secret's, and the
      // device signed the fields and this link's locator.
      expect(link.matches(binding), isTrue);
      expect(
        signature,
        fakeInviteSignature(
          testDeviceSigningKey,
          link.bindingMessageOf(binding),
        ),
      );
      expect(tag, isNot(contains(secret)));
    },
  );

  test(
    'a link whose own signature does not verify is never handed out',
    () async {
      final api = _Api();
      final crypto = _inGroups(<String>['conv_1'])..forcedVerification = false;
      final state = _state(api, crypto: crypto);

      expect(
        await state.createInviteLink(InviteTargetKind.group, 'conv_1'),
        isNull,
      );
      expect(api.createdLocators, isEmpty);
      expect(state.errorFor(Ops.membership), isNotNull);
    },
  );

  test(
    'no invitation is made without an engine that reads the device key',
    () async {
      final api = _Api();
      final state = _state(api, crypto: UnavailableCryptoService());

      final url = await state.createInviteLink(
        InviteTargetKind.group,
        'conv_1',
      );

      expect(url, isNull);
      expect(api.createdLocators, isEmpty);
      expect(state.errorFor(Ops.membership), isNotNull);
    },
  );

  test('a link of another server is refused before any request', () async {
    final api = _Api();
    final state = _state(api);
    final foreign = newInviteLink(origin: 'https://evil.test');

    final result = await state.previewInviteLink(foreign.url);

    expect(result, isNull);
    expect(api.previewed, isEmpty);
    final message = state.errorFor(Ops.membership)!;
    expect(message, isNot(contains('evil.test')));
    final secret = Uri.parse(foreign.url).fragment.split('.')[1];
    expect(message, isNot(contains(secret)));
  });

  test(
    'a good link is previewed with its locator; a dead one says so',
    () async {
      final api = _Api();
      final state = _state(api);
      final link = _newLink();
      api.binding = honestBinding(link);

      final good = await state.previewInviteLink('  ${link.url}\n');
      expect(good, isNotNull);
      expect(good!.preview.inviterUsername, 'alice');
      expect(api.previewed, <String>[link.locator]);

      api.previewStatus = 404;
      final dead = await state.previewInviteLink(link.url);
      expect(dead, isNull);
      expect(state.errorFor(Ops.membership), isNotNull);
      expect(state.errorFor(Ops.membership), isNot(contains(link.locator)));
    },
  );

  test('a preview whose binding does not match the link is refused', () async {
    final link = _newLink();
    final honest = honestBinding(link);
    final other = _newLink();
    final swaps = <String, InviteBinding>{
      'another target': tampered(honest, targetId: 'conv_2'),
      'another target kind': tampered(honest, kind: InviteTargetKind.community),
      'another inviter account': tampered(honest, accountId: 'acct_mallory'),
      'another inviter device': tampered(honest, deviceId: 'dev_mallory'),
      'another signing key': tampered(honest, signingKey: _otherKey),
      'a short signing key': tampered(honest, signingKey: _otherKey.sublist(1)),
      'a tag of another link': honestBinding(other),
      'an empty tag': tampered(honest, tag: ''),
      'a tag in capitals': tampered(honest, tag: honest.tag.toUpperCase()),
      'a truncated tag': tampered(honest, tag: honest.tag.substring(1)),
      'no signature (made before v2)': tampered(
        honest,
        signature: Uint8List(0),
      ),
      'a short signature': tampered(
        honest,
        signature: honest.signature.sublist(1),
      ),
      'a signature that fits no message': tampered(
        honest,
        signature: List<int>.filled(64, 3),
      ),
      'a signature over another target': tampered(
        honest,
        signature: honestBinding(link, targetId: 'conv_2').signature,
      ),
      // A server holding the link and its own key: the key does not fit the
      // commitment in the link, however well it signs and recomputes the tag.
      'its own key, signed and tagged': (() {
        final forged = honestBinding(link, signingKey: _otherKey);
        return forged;
      })(),
    };
    for (final entry in swaps.entries) {
      final api = _Api()..binding = entry.value;
      final state = _state(api);

      final result = await state.previewInviteLink(link.url);

      expect(result, isNull, reason: entry.key);
      expect(state.errorFor(Ops.membership), isNotNull, reason: entry.key);
      expect(api.requested, isEmpty, reason: entry.key);
    }
    // The untouched binding passes.
    final api = _Api()..binding = honest;
    final good = await _state(api).previewInviteLink(link.url);
    expect(good, isNotNull);
    expect(good!.preview.binding.targetId, 'conv_1');
  });

  test(
    'a preview whose shown kind differs from the bound kind is refused',
    () async {
      final link = _newLink();
      final api = _Api()
        ..binding = honestBinding(link, kind: InviteTargetKind.community)
        ..previewKind = InviteTargetKind.group;

      expect(await _state(api).previewInviteLink(link.url), isNull);
    },
  );

  test(
    'a request answered with another target is withdrawn and refused',
    () async {
      final link = _newLink();
      final honest = honestBinding(link);
      final cases = <String, InviteBinding?>{
        'no binding': null,
        'another target': tampered(honest, targetId: 'conv_other'),
        'another inviter': tampered(honest, accountId: 'acct_mallory'),
        'the kind of another target': tampered(
          honest,
          kind: InviteTargetKind.community,
        ),
        'no signature': tampered(honest, signature: Uint8List(0)),
        'a signature of another target': tampered(
          honest,
          signature: honestBinding(link, targetId: 'conv_other').signature,
        ),
      };
      for (final entry in cases.entries) {
        final api = _Api()
          ..binding = honest
          ..requestBinding = entry.value
          ..requestAnswersWithoutBinding = entry.value == null;
        final state = _state(api);

        final request = await state.requestToJoin(link);

        expect(request, isNull, reason: entry.key);
        expect(api.cancelled, <String>['jreq_1'], reason: entry.key);
        expect(state.errorFor(Ops.membership), isNotNull, reason: entry.key);
      }
    },
  );

  test('a request answered with the link\'s own binding stands', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final state = _state(api);

    final request = await state.requestToJoin(link);

    expect(request, isNotNull);
    expect(api.cancelled, isEmpty);
    final anchor = await state.localStore.loadInviteAnchor('conv_1');
    expect(anchor, isNotNull);
    expect(anchor!.accountId, 'acct_alice');
    expect(anchor.signingKey, defaultInviterKey);
    expect(state.errorFor(Ops.membership), isNull);
  });

  test('a failed anchor write files no join request', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final state = _state(api, store: _FailingAnchorStore());
    expect(await state.requestToJoin(link), isNull);
    expect(api.requested, isEmpty);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test(
    'a preview is refused when the engine finds the signature invalid',
    () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final crypto = TestOnlyCryptoService()..forcedVerification = false;

      final result = await _state(
        api,
        crypto: crypto,
      ).previewInviteLink(link.url);

      expect(result, isNull);
      expect(api.requested, isEmpty);
    },
  );

  test('a join without the signing engine is refused (fail closed)', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final state = _state(api, crypto: UnavailableCryptoService());

    expect(await state.previewInviteLink(link.url), isNull);
    expect(await state.requestToJoin(link), isNull);
    expect(api.requested, isEmpty);
    expect(api.cancelled, isEmpty);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('a v1 link is not read', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final secret = Uri.parse(link.url).fragment.split('.')[1];

    expect(
      await _state(
        api,
      ).previewInviteLink('https://localhost:8080/join#v1.$secret'),
      isNull,
    );
    expect(api.previewed, isEmpty);
  });

  group('the MLS roster anchors the key where this device has the group', () {
    final conversations = <Conversation>[
      Conversation(id: 'conv_a', kind: 'direct'),
      Conversation(id: 'conv_b', kind: 'group'),
    ];

    test('a group naming the same key for the inviter passes', () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final crypto = TestOnlyCryptoService()
        ..memberKeys['conv_b|acct_alice|dev_alice'] = defaultInviterKey;
      final state = _state(api, crypto: crypto)..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNotNull);
    });

    test('a group naming another key for the inviter refuses', () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final crypto = TestOnlyCryptoService()
        ..memberKeys['conv_a|acct_alice|dev_alice'] = defaultInviterKey
        ..memberKeys['conv_b|acct_alice|dev_alice'] = Uint8List.fromList(
          _otherKey,
        );
      final state = _state(api, crypto: crypto)..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNull);
      expect(state.errorFor(Ops.membership), isNotNull);
      // Refuse before filing a request or persisting an anchor.
      expect(await state.requestToJoin(link), isNull);
      expect(api.requested, isEmpty);
      expect(api.cancelled, isEmpty);
      expect(await state.localStore.loadInviteAnchor('conv_1'), isNull);
    });

    test(
      'no shared group means the commitment in the link is the anchor',
      () async {
        final link = _newLink();
        final api = _Api()..binding = honestBinding(link);
        final state = _state(api)..conversations = conversations;

        expect(await state.previewInviteLink(link.url), isNotNull);
      },
    );

    test('a roster read that fails is no evidence either way', () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final state = _state(api, crypto: _ThrowingRosterCrypto())
        ..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNotNull);
    });
  });

  test(
    'approving asks reconcile for the target group; declining does not',
    () async {
      final api = _Api();
      final state = _state(api);
      final request = JoinRequest(
        id: 'jreq_1',
        kind: InviteTargetKind.group,
        status: JoinRequestStatus.pending,
        createdAt: DateTime.utc(2026, 11, 7),
        targetId: 'conv_1',
        accountId: 'acct_alice',
        username: 'alice',
      );

      expect(await state.decideJoinRequest(request, approve: false), isTrue);
      expect(api.decisions, <String>['jreq_1:reject']);

      expect(await state.decideJoinRequest(request, approve: true), isTrue);
      expect(api.decisions, <String>['jreq_1:reject', 'jreq_1:approve']);
    },
  );

  test(
    'a refused decision reports the server error and returns false',
    () async {
      final api = _Api()..decideStatus = 409;
      final state = _state(api);
      final request = JoinRequest(
        id: 'jreq_1',
        kind: InviteTargetKind.community,
        status: JoinRequestStatus.pending,
        createdAt: DateTime.utc(2026, 11, 7),
        targetId: 'comm_1',
      );
      expect(await state.decideJoinRequest(request, approve: true), isFalse);
      expect(state.errorFor(Ops.membership), isNotNull);
    },
  );

  test('leaving a community drops it and every one of its channels', () async {
    final api = _Api();
    final state = _state(api)
      ..communities = <Community>[
        Community(id: 'comm_1', name: 'Club'),
        Community(id: 'comm_2', name: 'Other'),
      ]
      ..channelsByCommunity = <String, List<Channel>>{
        'comm_1': <Channel>[
          Channel(
            id: 'chan_1',
            communityId: 'comm_1',
            name: 'general',
            kind: 'private',
          ),
        ],
        'comm_2': <Channel>[],
      }
      ..conversations = <Conversation>[
        Conversation(
          id: 'conv_1',
          kind: 'community_channel',
          communityId: 'comm_1',
        ),
        Conversation(
          id: 'conv_2',
          kind: 'community_channel',
          communityId: 'comm_1',
        ),
        Conversation(
          id: 'conv_3',
          kind: 'community_channel',
          communityId: 'comm_2',
        ),
        Conversation(id: 'conv_4', kind: 'group'),
      ];

    expect(await state.leaveCommunity('comm_1'), isTrue);

    expect(api.removed, <String>['comm_1:me']);
    expect(state.communities.map((c) => c.id), <String>['comm_2']);
    expect(state.channelsByCommunity.keys, <String>['comm_2']);
    expect(state.conversations.map((c) => c.id), <String>['conv_3', 'conv_4']);
  });

  test(
    'the last owner cannot leave: the server refusal is shown, nothing drops',
    () async {
      final api = _Api()..removeStatus = 409;
      final state = _state(api)
        ..communities = <Community>[Community(id: 'comm_1', name: 'Club')]
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'community_channel',
            communityId: 'comm_1',
          ),
        ];

      expect(await state.leaveCommunity('comm_1'), isFalse);

      expect(state.communities, hasLength(1));
      expect(state.conversations, hasLength(1));
      expect(state.errorFor(Ops.membership), isNotNull);
    },
  );

  test(
    'removing a member takes them off every cached channel roster',
    () async {
      final api = _Api();
      final state = _state(api)
        ..membersByConversation = <String, List<ConversationMember>>{
          'conv_1': <ConversationMember>[
            ConversationMember(accountId: 'acct_owner', role: 'owner'),
            ConversationMember(accountId: 'acct_bob', role: 'member'),
          ],
          'conv_9': <ConversationMember>[
            ConversationMember(accountId: 'acct_bob', role: 'member'),
          ],
        };

      expect(await state.removeCommunityMember('comm_1', 'acct_bob'), isTrue);

      expect(api.removed, <String>['comm_1:acct_bob']);
      expect(state.membersFor('conv_1').map((m) => m.accountId), <String>[
        'acct_owner',
      ]);
      // A roster of a conversation outside the community is left alone.
      expect(state.membersFor('conv_9'), hasLength(1));
    },
  );

  group('v3: the shared-group anchor', () {
    Community shared(String id, String? group) =>
        Community(id: id, name: '', sharedConversationId: group);

    test(
      'a community invitation is anchored to its shared group, signed',
      () async {
        final api = _Api();
        final state = _state(api, crypto: _inGroups(<String>['conv_s1']))
          ..communities = <Community>[shared('comm_1', 'conv_s1')];

        final url = await state.createInviteLink(
          InviteTargetKind.community,
          'comm_1',
        );

        expect(url, isNotNull);
        expect(api.createdTargets, <String>['community:comm_1']);
        expect(api.createdAnchors, <String>['conv_s1']);
        final link = MembershipInviteLink.tryParse(
          url!,
          expectedOrigin: 'https://localhost:8080',
        )!;
        final binding = InviteBinding(
          kind: InviteTargetKind.community,
          targetId: 'comm_1',
          anchorGroupId: 'conv_s1',
          inviterAccountId: 'acct_owner',
          inviterDeviceId: 'dev_owner',
          inviterSigningKey: testDeviceSigningKey,
          tag: api.createdTags.single,
          signature: Uint8List.fromList(api.createdSignatures.single),
        );
        expect(link.matches(binding), isTrue);
        expect(
          api.createdSignatures.single,
          fakeInviteSignature(
            testDeviceSigningKey,
            link.bindingMessageOf(binding),
          ),
        );
      },
    );

    test('no invitation without a group this device is in', () async {
      final cases = <String, AppState>{
        'a legacy community (no shared group)': _state(
          _Api(),
          crypto: _inGroups(<String>['conv_s1']),
        )..communities = <Community>[shared('comm_1', null)],
        'a community this device does not know': _state(
          _Api(),
          crypto: _inGroups(<String>['conv_s1']),
        ),
        'a shared group this device is not in': _state(
          _Api(),
          crypto: _inGroups(<String>['conv_other']),
        )..communities = <Community>[shared('comm_1', 'conv_s1')],
        'its own leaf with another key': _state(
          _Api(),
          crypto: TestOnlyCryptoService()
            ..memberKeys['conv_s1|acct_owner|dev_owner'] = Uint8List.fromList(
              _otherKey,
            ),
        )..communities = <Community>[shared('comm_1', 'conv_s1')],
        'a roster read that fails': _state(
          _Api(),
          crypto: _ThrowingRosterCrypto(),
        )..communities = <Community>[shared('comm_1', 'conv_s1')],
      };
      for (final entry in cases.entries) {
        final state = entry.value;
        final api = state.api! as _Api;
        expect(
          await state.createInviteLink(InviteTargetKind.community, 'comm_1'),
          isNull,
          reason: entry.key,
        );
        expect(api.createdLocators, isEmpty, reason: entry.key);
      }
      // A group: the same rule, the group itself.
      final api = _Api();
      expect(
        await _state(api).createInviteLink(InviteTargetKind.group, 'conv_1'),
        isNull,
      );
      expect(api.createdLocators, isEmpty);
    });

    test('a wrong or missing anchor is refused', () async {
      final link = _newLink();
      final community = honestBinding(
        link,
        kind: InviteTargetKind.community,
        targetId: 'comm_1',
        anchorGroupId: 'conv_s1',
      );
      final group = honestBinding(link);
      final cases = <String, InviteBinding>{
        // Signed and tagged by the inviter, but a group admits to itself.
        'a group anchored elsewhere, signed': honestBinding(
          link,
          anchorGroupId: 'conv_2',
        ),
        'a group with no anchor, signed': honestBinding(
          link,
          anchorGroupId: '',
        ),
        'a community with no anchor, signed': honestBinding(
          link,
          kind: InviteTargetKind.community,
          targetId: 'comm_1',
          anchorGroupId: '',
        ),
        // The server swaps the anchor: neither tag nor signature fits.
        'a community anchor swapped': tampered(
          community,
          anchorGroupId: 'conv_s2',
        ),
        'a community anchor dropped': tampered(community, anchorGroupId: ''),
        'a group anchor swapped': tampered(group, anchorGroupId: 'conv_2'),
        // A tag recomputed for the swap (a server holding the link) still
        // leaves the inviter's signature over the true anchor.
        'a swapped anchor with a recomputed tag': tampered(
          community,
          anchorGroupId: 'conv_s2',
          tag: link.bindingTag(
            kind: InviteTargetKind.community,
            targetId: 'comm_1',
            anchorGroupId: 'conv_s2',
            inviterAccountId: 'acct_alice',
            inviterDeviceId: 'dev_alice',
            inviterSigningKey: defaultInviterKey,
          ),
        ),
      };
      for (final entry in cases.entries) {
        final api = _Api()
          ..binding = entry.value
          ..previewKind = entry.value.kind;
        final state = _state(api);

        expect(
          await state.previewInviteLink(link.url),
          isNull,
          reason: entry.key,
        );
        expect(await state.requestToJoin(link), isNull, reason: entry.key);
        expect(api.requested, isEmpty, reason: entry.key);
        expect(
          await state.localStore.loadCommunityInviteAnchor('comm_1'),
          isNull,
          reason: entry.key,
        );
      }
      final api = _Api()
        ..binding = community
        ..previewKind = InviteTargetKind.community;
      expect(await _state(api).previewInviteLink(link.url), isNotNull);
    });

    test('a community request pins the shared group before filing', () async {
      final link = _newLink();
      final api = _Api()
        ..binding = honestBinding(
          link,
          kind: InviteTargetKind.community,
          targetId: 'comm_1',
          anchorGroupId: 'conv_s1',
        )
        ..previewKind = InviteTargetKind.community;
      final state = _state(api);

      expect(await state.requestToJoin(link), isNotNull);

      expect(api.cancelled, isEmpty);
      // The Welcome check (D99) reads this anchor by the group's id.
      final anchor = await state.localStore.loadInviteAnchor('conv_s1');
      expect(anchor, isNotNull);
      expect(anchor!.accountId, 'acct_alice');
      expect(anchor.deviceId, 'dev_alice');
      expect(anchor.signingKey, defaultInviterKey);
      expect(await state.localStore.loadInviteAnchor('comm_1'), isNull);
      expect(
        await state.localStore.loadCommunityInviteAnchor('comm_1'),
        'conv_s1',
      );
    });

    test(
      'a request answered with another anchor is withdrawn (replay into '
      'another group)',
      () async {
        final link = _newLink();
        final honest = honestBinding(
          link,
          kind: InviteTargetKind.community,
          targetId: 'comm_1',
          anchorGroupId: 'conv_s1',
        );
        // Even a binding the inviter really signed for this link, if it
        // names another group than the preview showed.
        final api = _Api()
          ..binding = honest
          ..previewKind = InviteTargetKind.community
          ..requestBinding = honestBinding(
            link,
            kind: InviteTargetKind.community,
            targetId: 'comm_1',
            anchorGroupId: 'conv_s2',
          );
        final state = _state(api);

        expect(await state.requestToJoin(link), isNull);
        expect(api.cancelled, <String>['jreq_1']);
      },
    );

    test(
      'a pinned community refuses a link anchored to another group',
      () async {
        final link = _newLink();
        final api = _Api()
          ..binding = honestBinding(
            link,
            kind: InviteTargetKind.community,
            targetId: 'comm_1',
            anchorGroupId: 'conv_s2',
          )
          ..previewKind = InviteTargetKind.community;
        final state = _state(api);
        await state.localStore.saveCommunityInviteAnchor('comm_1', 'conv_s1');

        expect(await state.previewInviteLink(link.url), isNull);
        expect(await state.requestToJoin(link), isNull);
        expect(api.requested, isEmpty);
        expect(
          await state.localStore.loadCommunityInviteAnchor('comm_1'),
          'conv_s1',
        );
        expect(await state.localStore.loadInviteAnchor('conv_s2'), isNull);
      },
    );

    test(
      'a community is shown only while the server names its pinned group',
      () async {
        Channel channel(String id, String kind, String? conversation) =>
            Channel(
              id: id,
              communityId: id.startsWith('a') ? 'comm_a' : 'comm_x',
              name: '',
              kind: kind,
              conversationId: conversation,
              layoutGeneration: conversation == null ? null : 1,
            );
        final cases = <String, (Community, List<Channel>, bool)>{
          'the pinned group': (
            shared('comm_1', 'conv_s1'),
            <Channel>[
              channel('a1', 'open', 'conv_s1'),
              channel('a2', 'announcement', 'conv_s1'),
              channel('a3', 'private', 'conv_p1'),
            ],
            true,
          ),
          'another shared group': (
            shared('comm_1', 'conv_s2'),
            <Channel>[channel('a1', 'open', 'conv_s2')],
            false,
          ),
          'no shared group (legacy)': (
            shared('comm_1', null),
            <Channel>[],
            false,
          ),
          'an open channel routed elsewhere': (
            shared('comm_1', 'conv_s1'),
            <Channel>[channel('a1', 'open', 'conv_s2')],
            false,
          ),
          'an announcement channel routed elsewhere': (
            shared('comm_1', 'conv_s1'),
            <Channel>[channel('a2', 'announcement', null)],
            false,
          ),
        };
        for (final entry in cases.entries) {
          final (community, channels, shown) = entry.value;
          final api = _Api()
            ..listedCommunities = <Community>[
              community,
              shared('comm_free', 'conv_f'),
            ]
            ..listedChannels = <String, List<Channel>>{'comm_1': channels};
          final state = _state(api);
          await state.localStore.saveCommunityInviteAnchor(
            'comm_1',
            'conv_s1',
          );

          await state.refreshCommunities();

          expect(
            state.communities.map((c) => c.id),
            shown ? <String>['comm_1', 'comm_free'] : <String>['comm_free'],
            reason: entry.key,
          );
          expect(
            state.channelsByCommunity.containsKey('comm_1'),
            shown,
            reason: entry.key,
          );
        }
        // A store that cannot answer hides a community rather than trust
        // the server's mapping.
        final api = _Api()
          ..listedCommunities = <Community>[shared('comm_1', 'conv_s1')];
        final state = _state(api, store: _FailingCommunityAnchorStore());
        await state.refreshCommunities();
        expect(state.communities, isEmpty);
      },
    );

    test('v1 and v2 links are not read (downgrade)', () async {
      final link = _newLink();
      final fragment = Uri.parse(link.url).fragment;
      final parts = fragment.split('.');
      expect(parts.first, 'v3');
      final api = _Api()..binding = honestBinding(link);
      final state = _state(api);
      for (final old in <String>[
        'v2.${parts[1]}.${parts[2]}',
        'v1.${parts[1]}',
      ]) {
        expect(
          await state.previewInviteLink('https://localhost:8080/join#$old'),
          isNull,
          reason: old,
        );
      }
      expect(api.previewed, isEmpty);
    });

    test('a v2-layout signature does not stand for a v3 binding', () async {
      final link = _newLink();
      final honest = honestBinding(link);
      // What the same inviter signed under v2 for the same link: no version
      // field and no anchor.
      List<int> lp(List<int> field) =>
          <int>[field.length >> 8, field.length & 0xff, ...field];
      final v2 = <int>[
        for (final field in <List<int>>[
          utf8.encode(link.origin),
          utf8.encode('group'),
          utf8.encode('conv_1'),
          utf8.encode('acct_alice'),
          utf8.encode('dev_alice'),
          defaultInviterKey,
          utf8.encode(link.locator),
        ])
          ...lp(field),
      ];
      final api = _Api()
        ..binding = tampered(
          honest,
          signature: fakeInviteSignature(defaultInviterKey, v2),
        );

      expect(await _state(api).previewInviteLink(link.url), isNull);
      expect(api.requested, isEmpty);
    });
  });
}

final List<int> _otherKey = List<int>.generate(32, (i) => 0x70 + i);

MembershipInviteLink _newLink() => newInviteLink();

AppState _state(ApiClient api, {CryptoService? crypto, LocalStore? store}) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto ?? TestOnlyCryptoService(),
    localStore: store ?? MemoryLocalStore(),
    syncServiceFactory: (_, __) => _SyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final List<String> createdLocators = <String>[];
  final List<String> createdTargets = <String>[];
  final List<String> createdAnchors = <String>[];
  List<Community> listedCommunities = <Community>[];
  Map<String, List<Channel>> listedChannels = <String, List<Channel>>{};
  final List<List<int>> createdKeys = <List<int>>[];
  final List<String> createdTags = <String>[];
  final List<List<int>> createdSignatures = <List<int>>[];
  final List<String> previewed = <String>[];
  final List<String> requested = <String>[];
  final List<String> cancelled = <String>[];
  InviteBinding? binding;
  InviteBinding? requestBinding;
  bool requestAnswersWithoutBinding = false;
  InviteTargetKind previewKind = InviteTargetKind.group;
  final List<String> decisions = <String>[];
  final List<String> removed = <String>[];
  int previewStatus = 200;
  int decideStatus = 200;
  int removeStatus = 200;

  @override
  Future<MembershipInvite> createMembershipInvite(
    String token,
    InviteTargetKind kind,
    String targetId, {
    required String locator,
    required String anchorGroupId,
    required List<int> signingKey,
    required String bindingTag,
    required List<int> bindingSignature,
    int maxUses = 10,
    Duration lifetime = const Duration(days: 7),
  }) async {
    createdLocators.add(locator);
    createdAnchors.add(anchorGroupId);
    createdKeys.add(signingKey);
    createdTags.add(bindingTag);
    createdSignatures.add(bindingSignature);
    createdTargets.add('${kind.wire}:$targetId');
    return MembershipInvite(
      id: 'minv_1',
      maxUses: maxUses,
      uses: 0,
      expiresAt: DateTime.utc(2026, 11, 14),
    );
  }

  @override
  Future<InvitePreview> previewMembershipInvite(
    String token,
    String locator,
  ) async {
    previewed.add(locator);
    if (previewStatus != 200) throw ApiException(previewStatus);
    return InvitePreview(
      kind: previewKind,
      targetName: 'Hikers',
      inviterUsername: 'alice',
      expiresAt: DateTime.utc(2026, 11, 14),
      alreadyMember: false,
      binding: binding!,
    );
  }

  @override
  Future<JoinRequest> requestToJoin(String token, String locator) async {
    requested.add(locator);
    return JoinRequest(
      id: 'jreq_1',
      kind: (requestBinding ?? binding)?.kind ?? InviteTargetKind.group,
      status: JoinRequestStatus.pending,
      createdAt: DateTime.utc(2026, 11, 7),
      binding: requestAnswersWithoutBinding ? null : requestBinding ?? binding,
    );
  }

  @override
  Future<List<Community>> listCommunities(String token) async =>
      listedCommunities;

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async =>
      listedChannels[communityId] ?? const <Channel>[];

  @override
  Future<List<ConversationMember>> communityMembers(
    String token,
    String communityId,
  ) async =>
      const <ConversationMember>[];

  @override
  Future<void> cancelJoinRequest(String token, String requestId) async {
    cancelled.add(requestId);
  }

  @override
  Future<JoinRequest> decideJoinRequest(
    String token,
    String requestId, {
    required bool approve,
  }) async {
    if (decideStatus != 200) {
      throw ApiException(decideStatus, '{"error":"join_request_resolved"}');
    }
    decisions.add('$requestId:${approve ? 'approve' : 'reject'}');
    return JoinRequest(
      id: requestId,
      kind: InviteTargetKind.group,
      status: approve ? JoinRequestStatus.approved : JoinRequestStatus.rejected,
      createdAt: DateTime.utc(2026, 11, 7),
    );
  }

  @override
  Future<CommunityRemoval> removeCommunityMember(
    String token,
    String communityId,
    String accountId,
  ) async {
    if (removeStatus != 200) {
      throw ApiException(removeStatus, '{"error":"last_owner_required"}');
    }
    removed.add('$communityId:$accountId');
    return const CommunityRemoval(<({String conversationId, int? eventId})>[
      (conversationId: 'conv_1', eventId: 7),
      (conversationId: 'conv_2', eventId: 8),
    ]);
  }
}

/// An engine whose roster read always fails.
class _ThrowingRosterCrypto extends TestOnlyCryptoService {
  @override
  Future<Uint8List?> memberSigningKey({
    required String conversationId,
    required String accountId,
    required String deviceId,
  }) async =>
      throw StateError('no readable group');
}

class _SyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}

class _FailingCommunityAnchorStore extends MemoryLocalStore {
  @override
  Future<String?> loadCommunityInviteAnchor(String communityId) async {
    throw StateError('storage unavailable');
  }
}

class _FailingAnchorStore extends MemoryLocalStore {
  @override
  Future<void> saveInviteAnchor(InviteAnchor anchor) async {
    throw StateError('storage unavailable');
  }
}
