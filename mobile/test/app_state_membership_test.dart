import 'dart:async';
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

/// C1 actions of [AppState]: what reaches the server, and what stays local.
void main() {
  test('an invitation link is made locally and only its locator is sent',
      () async {
    final api = _Api();
    final state = _state(api);
    final url = await state.createInviteLink(InviteTargetKind.group, 'conv_1');

    expect(url, isNotNull);
    final link = MembershipInviteLink.tryParse(
      url!,
      expectedOrigin: 'https://localhost:8080',
    );
    expect(link, isNotNull);
    expect(api.createdLocators, <String>[link!.locator]);
    expect(api.createdTargets, <String>['group:conv_1']);
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
            testDeviceSigningKey, link.bindingMessageOf(binding)));
    expect(tag, isNot(contains(secret)));
  });

  test('a link whose own signature does not verify is never handed out',
      () async {
    final api = _Api();
    final crypto = TestOnlyCryptoService()..forcedVerification = false;
    final state = _state(api, crypto: crypto);

    expect(
        await state.createInviteLink(InviteTargetKind.group, 'conv_1'), isNull);
    expect(api.createdLocators, isEmpty);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('no invitation is made without an engine that reads the device key',
      () async {
    final api = _Api();
    final state = _state(api, crypto: UnavailableCryptoService());

    final url = await state.createInviteLink(InviteTargetKind.group, 'conv_1');

    expect(url, isNull);
    expect(api.createdLocators, isEmpty);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

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

  test('a good link is previewed with its locator; a dead one says so',
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
  });

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
      'no signature (made before v2)':
          tampered(honest, signature: Uint8List(0)),
      'a short signature':
          tampered(honest, signature: honest.signature.sublist(1)),
      'a signature that fits no message':
          tampered(honest, signature: List<int>.filled(64, 3)),
      'a signature over another target': tampered(honest,
          signature: honestBinding(link, targetId: 'conv_2').signature),
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

  test('a preview whose shown kind differs from the bound kind is refused',
      () async {
    final link = _newLink();
    final api = _Api()
      ..binding = honestBinding(link, kind: InviteTargetKind.community)
      ..previewKind = InviteTargetKind.group;

    expect(await _state(api).previewInviteLink(link.url), isNull);
  });

  test('a request answered with another target is withdrawn and refused',
      () async {
    final link = _newLink();
    final honest = honestBinding(link);
    final cases = <String, InviteBinding?>{
      'no binding': null,
      'another target': tampered(honest, targetId: 'conv_other'),
      'another inviter': tampered(honest, accountId: 'acct_mallory'),
      'the kind of another target':
          tampered(honest, kind: InviteTargetKind.community),
      'no signature': tampered(honest, signature: Uint8List(0)),
      'a signature of another target': tampered(honest,
          signature: honestBinding(link, targetId: 'conv_other').signature),
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
  });

  test('a request answered with the link\'s own binding stands', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final state = _state(api);

    final request = await state.requestToJoin(link);

    expect(request, isNotNull);
    expect(api.cancelled, isEmpty);
    expect(state.errorFor(Ops.membership), isNull);
  });

  test('a preview is refused when the engine finds the signature invalid',
      () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final crypto = TestOnlyCryptoService()..forcedVerification = false;

    final result =
        await _state(api, crypto: crypto).previewInviteLink(link.url);

    expect(result, isNull);
    expect(api.requested, isEmpty);
  });

  test('a join without the signing engine is refused (fail closed)', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final state = _state(api, crypto: UnavailableCryptoService());

    expect(await state.previewInviteLink(link.url), isNull);
    expect(await state.requestToJoin(link), isNull);
    expect(api.cancelled, <String>['jreq_1']);
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('a v1 link is not read', () async {
    final link = _newLink();
    final api = _Api()..binding = honestBinding(link);
    final secret = Uri.parse(link.url).fragment.split('.')[1];

    expect(
        await _state(api)
            .previewInviteLink('https://localhost:8080/join#v1.$secret'),
        isNull);
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
        ..memberKeys['conv_b|acct_alice|dev_alice'] =
            Uint8List.fromList(_otherKey);
      final state = _state(api, crypto: crypto)..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNull);
      expect(state.errorFor(Ops.membership), isNotNull);
      // And a request answered with the same binding is withdrawn.
      expect(await state.requestToJoin(link), isNull);
      expect(api.cancelled, <String>['jreq_1']);
    });

    test('no shared group means the commitment in the link is the anchor',
        () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final state = _state(api)..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNotNull);
    });

    test('a roster read that fails is no evidence either way', () async {
      final link = _newLink();
      final api = _Api()..binding = honestBinding(link);
      final state = _state(api, crypto: _ThrowingRosterCrypto())
        ..conversations = conversations;

      expect(await state.previewInviteLink(link.url), isNotNull);
    });
  });

  test('approving asks reconcile for the target group; declining does not',
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
  });

  test('a refused decision reports the server error and returns false',
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
  });

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
              kind: 'private'),
        ],
        'comm_2': <Channel>[],
      }
      ..conversations = <Conversation>[
        Conversation(
            id: 'conv_1', kind: 'community_channel', communityId: 'comm_1'),
        Conversation(
            id: 'conv_2', kind: 'community_channel', communityId: 'comm_1'),
        Conversation(
            id: 'conv_3', kind: 'community_channel', communityId: 'comm_2'),
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
            id: 'conv_1', kind: 'community_channel', communityId: 'comm_1'),
      ];

    expect(await state.leaveCommunity('comm_1'), isFalse);

    expect(state.communities, hasLength(1));
    expect(state.conversations, hasLength(1));
    expect(state.errorFor(Ops.membership), isNotNull);
  });

  test('removing a member takes them off every cached channel roster',
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
    expect(state.membersFor('conv_1').map((m) => m.accountId),
        <String>['acct_owner']);
    // A roster of a conversation outside the community is left alone.
    expect(state.membersFor('conv_9'), hasLength(1));
  });
}

final List<int> _otherKey = List<int>.generate(32, (i) => 0x70 + i);

MembershipInviteLink _newLink() => newInviteLink();

AppState _state(ApiClient api, {CryptoService? crypto}) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto ?? TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
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
    required List<int> signingKey,
    required String bindingTag,
    required List<int> bindingSignature,
    int maxUses = 10,
    Duration lifetime = const Duration(days: 7),
  }) async {
    createdLocators.add(locator);
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
