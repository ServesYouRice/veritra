import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/membership_models.dart';

class _Call {
  _Call(this.method, this.path, this.body);

  final String method;
  final String path;
  final String body;
}

/// A loopback server that records what the client sends and answers
/// [respond] with JSON.
Future<(ApiClient, List<_Call>)> _client(
  Object? Function(_Call call) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final calls = <_Call>[];
  server.listen((request) async {
    final body = await utf8.decodeStream(request);
    final call = _Call(
      request.method,
      request.uri.toString(),
      body,
    );
    calls.add(call);
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(respond(call)));
    await request.response.close();
  });
  final client = ApiClient(
    baseUrl: 'http://${server.address.address}:${server.port}',
  );
  addTearDown(() async {
    client.close();
    await server.close(force: true);
  });
  return (client, calls);
}

Map<String, Object?> _bodyOf(_Call call) =>
    jsonDecode(call.body) as Map<String, Object?>;

/// A binding as the server sends it: the key is standard base64 of 32 bytes.
final Map<String, Object?> _bindingJson = <String, Object?>{
  'target_kind': 'group',
  'target_id': 'conv_1',
  'inviter_account_id': 'acct_alice',
  'inviter_device_id': 'dev_alice',
  'inviter_signing_key': base64.encode(List<int>.generate(32, (i) => i)),
  'tag': 'cd' * 32,
};

void main() {
  final link =
      MembershipInviteLink.generate(origin: 'https://chat.example.org');

  test('creating an invitation sends the locator and never the secret',
      () async {
    final (client, calls) = await _client((_) => <String, Object?>{
          'id': 'minv_1',
          'target_kind': 'community',
          'target_id': 'comm_1',
          'max_uses': 10,
          'uses': 0,
          'expires_at': '2026-11-14T10:00:00Z',
          'created_at': '2026-11-07T10:00:00Z',
        });
    final invite = await client.createMembershipInvite(
      'tok',
      InviteTargetKind.community,
      'comm_1',
      locator: link.locator,
      signingKey: List<int>.generate(32, (i) => i),
      bindingTag: 'ab' * 32,
    );
    expect(invite.id, 'minv_1');
    expect(invite.maxUses, 10);
    final call = calls.single;
    expect(call.method, 'POST');
    expect(call.path, '/api/v1/communities/comm_1/invites');
    expect(_bodyOf(call).keys.toSet(), <String>{
      'locator',
      'signing_key',
      'binding_tag',
      'max_uses',
      'expires_in_seconds',
    });
    expect(_bodyOf(call)['locator'], link.locator);
    // The device key goes as standard base64, as the server's JSON bytes do.
    expect(base64.decode(_bodyOf(call)['signing_key']! as String),
        List<int>.generate(32, (i) => i));
    expect(_bodyOf(call)['binding_tag'], 'ab' * 32);
    expect(_bodyOf(call)['expires_in_seconds'], 7 * 24 * 3600);
    // The secret is the part of the link after "v1." in its fragment.
    final secret = Uri.parse(link.url).fragment.substring(3);
    expect(call.body, isNot(contains(secret)));
    expect(call.path, isNot(contains(secret)));
  });

  test('a group invitation lives under the conversation', () async {
    final (client, calls) = await _client((_) => <String, Object?>{
          'invites': <Object?>[
            <String, Object?>{
              'id': 'minv_2',
              'max_uses': 3,
              'uses': 1,
              'expires_at': '2026-11-14T10:00:00Z',
            },
          ],
        });
    final invites = await client.listMembershipInvites(
        'tok', InviteTargetKind.group, 'conv_9');
    expect(calls.single.method, 'GET');
    expect(calls.single.path, '/api/v1/conversations/conv_9/invites');
    expect(invites.single.uses, 1);
  });

  test('preview and request carry the locator in a body, not the path',
      () async {
    final (client, calls) = await _client((call) {
      if (call.path.endsWith('/preview')) {
        return <String, Object?>{
          'target_kind': 'group',
          'target_name': 'Hikers',
          'inviter_username': 'alice',
          'expires_at': '2026-11-14T10:00:00Z',
          'already_member': false,
          'binding': _bindingJson,
        };
      }
      return <String, Object?>{
        'id': 'jreq_1',
        'target_kind': 'group',
        'status': 'pending',
        'created_at': '2026-11-07T10:00:00Z',
        'binding': _bindingJson,
      };
    });
    final preview = await client.previewMembershipInvite('tok', link.locator);
    expect(preview.kind, InviteTargetKind.group);
    expect(preview.targetName, 'Hikers');
    expect(preview.inviterUsername, 'alice');
    expect(preview.binding.targetId, 'conv_1');
    expect(preview.binding.inviterAccountId, 'acct_alice');
    expect(preview.binding.inviterDeviceId, 'dev_alice');
    expect(preview.binding.inviterSigningKey, List<int>.generate(32, (i) => i));
    expect(preview.binding.tag, 'cd' * 32);
    final request = await client.requestToJoin('tok', link.locator);
    expect(request.status, JoinRequestStatus.pending);
    expect(request.binding!.tag, 'cd' * 32);
    expect(calls.map((c) => c.path), <String>[
      '/api/v1/membership-invites/preview',
      '/api/v1/membership-invites/requests',
    ]);
    for (final call in calls) {
      expect(call.method, 'POST');
      expect(_bodyOf(call), <String, Object?>{'locator': link.locator});
      expect(call.path, isNot(contains(link.locator)));
      expect(call.path, isNot(contains('#')));
    }
  });

  test('admins list requests with usernames and decide them', () async {
    final (client, calls) = await _client((call) {
      if (call.method == 'GET') {
        return <String, Object?>{
          'requests': <Object?>[
            <String, Object?>{
              'id': 'jreq_1',
              'target_kind': 'community',
              'target_id': 'comm_1',
              'account_id': 'acct_a',
              'username': 'alice',
              'status': 'pending',
              'created_at': '2026-11-07T10:00:00Z',
            },
          ],
        };
      }
      return <String, Object?>{
        'status': 'approved',
        'request': <String, Object?>{
          'id': 'jreq_1',
          'target_kind': 'community',
          'target_id': 'comm_1',
          'account_id': 'acct_a',
          'status': 'approved',
          'created_at': '2026-11-07T10:00:00Z',
          'decided_at': '2026-11-07T10:05:00Z',
        },
      };
    });
    final listed = await client.listJoinRequests(
        'tok', InviteTargetKind.community, 'comm_1');
    expect(calls.single.path, '/api/v1/communities/comm_1/join-requests');
    expect(listed.single.username, 'alice');
    expect(listed.single.accountId, 'acct_a');
    final decided =
        await client.decideJoinRequest('tok', 'jreq_1', approve: true);
    expect(decided.status, JoinRequestStatus.approved);
    expect(decided.decidedAt, isNotNull);
    await client.decideJoinRequest('tok', 'jreq_1', approve: false);
    expect(calls[1].path, '/api/v1/join-requests/jreq_1/approve');
    expect(calls[2].path, '/api/v1/join-requests/jreq_1/reject');
  });

  test('leaving a community returns the channels it took the account out of',
      () async {
    final (client, calls) = await _client((_) => <String, Object?>{
          'status': 'membership_removed',
          'mls_coordination': 'pending',
          'channels': <Object?>[
            <String, Object?>{'conversation_id': 'conv_1', 'event_id': 41},
            <String, Object?>{'conversation_id': 'conv_2', 'event_id': 0},
          ],
        });
    final removal = await client.removeCommunityMember('tok', 'comm_1', 'me');
    expect(calls.single.method, 'DELETE');
    expect(calls.single.path, '/api/v1/communities/comm_1/members/me');
    expect(removal.channels.map((c) => c.conversationId),
        <String>['conv_1', 'conv_2']);
    expect(removal.channels.first.eventId, 41);
    // An unusable event id is read as none.
    expect(removal.channels.last.eventId, isNull);
  });

  test('the community roster carries usernames', () async {
    final (client, calls) = await _client((_) => <String, Object?>{
          'members': <Object?>[
            <String, Object?>{
              'account_id': 'acct_a',
              'role': 'owner',
              'username': 'alice',
              'created_at': '2026-11-07T10:00:00Z',
            },
          ],
        });
    final members = await client.communityMembers('tok', 'comm_1');
    expect(calls.single.path, '/api/v1/communities/comm_1/members');
    expect(members.single.username, 'alice');
    expect(members.single.role, 'owner');
  });

  test('malformed rows fail as a bad response, without the body', () async {
    final (client, _) = await _client((_) => <String, Object?>{
          'requests': <Object?>[
            <String, Object?>{
              'id': 'jreq_1',
              'target_kind': 'planet',
              'status': 'pending',
              'created_at': '2026-11-07T10:00:00Z',
            },
          ],
        });
    await expectLater(
      client.listOwnJoinRequests('tok'),
      throwsA(isA<ApiResponseException>()),
    );
  });

  test('a preview without a usable binding is a bad response', () async {
    final broken = <Map<String, Object?>?>[
      null,
      <String, Object?>{..._bindingJson, 'target_kind': 'planet'},
      <String, Object?>{..._bindingJson, 'target_id': ''},
      <String, Object?>{..._bindingJson, 'inviter_signing_key': 7},
      <String, Object?>{..._bindingJson, 'inviter_signing_key': '!!not base64'},
      <String, Object?>{..._bindingJson, 'tag': null},
    ];
    for (final binding in broken) {
      final (client, _) = await _client((_) => <String, Object?>{
            'target_kind': 'group',
            'target_name': 'Hikers',
            'inviter_username': 'alice',
            'expires_at': '2026-11-14T10:00:00Z',
            'already_member': false,
            if (binding != null) 'binding': binding,
          });
      await expectLater(
        client.previewMembershipInvite('tok', link.locator),
        throwsA(isA<ApiResponseException>()),
        reason: '$binding',
      );
    }
  });

  test('the new server error codes have client mappings', () {
    for (final code in <String>[
      'already_member',
      'join_request_resolved',
      'invite_unavailable',
      'join_request_limit_reached',
    ]) {
      expect(apiErrorKinds[code], ApiErrorKind.conflict, reason: code);
    }
    expect(apiErrorKinds['invalid_expires_in'], ApiErrorKind.invalidRequest);
  });

  test('moderation calls use the C5 routes and bodies', () async {
    final (client, calls) = await _client((call) {
      if (call.path.endsWith('/bans') && call.method == 'GET') {
        return <String, Object?>{
          'bans': <Object?>[
            <String, Object?>{
              'account_id': 'acct_bob',
              'username': 'bob',
              'banned_by': 'acct_owner',
              'created_at': '2026-11-07T10:00:00Z',
            },
          ],
        };
      }
      if (call.path.endsWith('/moderation-state')) {
        return <String, Object?>{
          'invites_paused_until': '2026-11-08T10:00:00Z',
          'channels': <Object?>[
            <String, Object?>{'channel_id': 'chan_1', 'slow_mode_seconds': 30},
          ],
        };
      }
      if (call.path.endsWith('/moderation-events')) {
        return <String, Object?>{
          'events': <Object?>[
            <String, Object?>{
              'id': 'mod_1',
              'actor_account_id': 'acct_owner',
              'target_account_id': 'acct_bob',
              'action': 'ban',
              'created_at': '2026-11-07T10:00:00Z',
            },
          ],
        };
      }
      return <String, Object?>{
        'status': 'ok',
        'channels': <Object?>[
          <String, Object?>{'conversation_id': 'conv_1', 'event_id': 7},
        ],
      };
    });
    final kicked =
        await client.kickCommunityMember('tok', 'comm_1', 'acct_bob');
    expect(kicked.channels.single.conversationId, 'conv_1');
    await client.banCommunityMember('tok', 'comm_1', 'acct_bob');
    await client.unbanCommunityMember('tok', 'comm_1', 'acct_bob');
    await client.setMemberTimeout('tok', 'comm_1', 'acct_bob', 600);
    await client.setChannelSlowMode('tok', 'comm_1', 'chan_1', 30);
    await client.setInvitesPaused('tok', 'comm_1', 3600);
    final bans = await client.communityBans('tok', 'comm_1');
    final state = await client.moderationState('tok', 'comm_1');
    final events = await client.moderationEvents('tok', 'comm_1');

    expect(bans.single.username, 'bob');
    expect(state.slowModeSeconds, <String, int>{'chan_1': 30});
    expect(state.invitesPausedUntil, isNotNull);
    expect(events.single.action, 'ban');
    expect(events.single.target, 'acct_bob');
    expect(calls.map((c) => '${c.method} ${c.path}').toList(), <String>[
      'POST /api/v1/communities/comm_1/members/acct_bob/kick',
      'POST /api/v1/communities/comm_1/bans',
      'DELETE /api/v1/communities/comm_1/bans/acct_bob',
      'PUT /api/v1/communities/comm_1/members/acct_bob/timeout',
      'PUT /api/v1/communities/comm_1/channels/chan_1/slow-mode',
      'PUT /api/v1/communities/comm_1/invites-pause',
      'GET /api/v1/communities/comm_1/bans',
      'GET /api/v1/communities/comm_1/moderation-state',
      'GET /api/v1/communities/comm_1/moderation-events',
    ]);
    expect(_bodyOf(calls[1]), <String, Object?>{'account_id': 'acct_bob'});
    expect(_bodyOf(calls[3]), <String, Object?>{'seconds': 600});
    expect(_bodyOf(calls[5]), <String, Object?>{'seconds': 3600});
  });
}
