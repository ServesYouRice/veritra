import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';

void main() {
  const owner = 'acct_owner';
  const admin = 'acct_admin';
  const mod = 'acct_mod';
  const bob = 'acct_bob';
  const carol = 'acct_carol';
  const members = {owner, admin, mod, bob, carol};

  GovernanceState base() {
    final g = GovernanceState.genesis(owner);
    return g.copyWith(
      assignments: {
        admin: {'admin'},
        mod: {'moderator'},
      },
    );
  }

  GovernanceCheck check(
    GovernanceState prev,
    GovernanceState next,
    String who, {
    Set<String> roster = members,
  }) =>
      validateTransition(prev, next, who, members: roster);

  ChannelOverride ov(
    String channel,
    String target, {
    bool role = true,
    Set<String> allow = const {},
    Set<String> deny = const {},
  }) =>
      ChannelOverride(
        channelId: channel,
        targetIsRole: role,
        targetId: target,
        allow: allow,
        deny: deny,
      );

  Map<String, ChannelOverride> keyed(Iterable<ChannelOverride> list) => {
        for (final o in list) o.key: o,
      };

  GovernanceState bump(
    GovernanceState s, {
    Map<String, Role>? roles,
    Map<String, Set<String>>? assignments,
    Map<String, ChannelOverride>? overrides,
    String? owner,
  }) =>
      s.copyWith(
        rev: s.rev + 1,
        roles: roles,
        assignments: assignments,
        overrides: overrides,
        owner: owner,
      );

  group('permissions', () {
    test('members get the open defaults, owner and admin get everything', () {
      final s = base();
      expect(s.can(bob, Perm.post, channelId: 'chan_a'), isTrue);
      expect(s.can(bob, Perm.pin), isTrue);
      expect(s.can(bob, Perm.kick), isFalse);
      expect(s.can(owner, Perm.manageRoles), isTrue);
      expect(s.can(admin, Perm.ban, channelId: 'chan_a'), isTrue);
      expect(s.can(mod, Perm.kick), isTrue);
    });

    test(
      'override order: member, then roles (deny then allow), then account',
      () {
        var s = base();
        final roles = Map.of(
          s.roles,
        )..['poster'] = const Role('poster', 'Poster', 100, {Perm.viewChannel});
        s = s.copyWith(
          roles: roles,
          assignments: {
            ...s.assignments,
            bob: {'poster'},
          },
        );
        ChannelOverride ov(
          String id,
          bool role, {
          Set<String> allow = const {},
          Set<String> deny = const {},
        }) =>
            ChannelOverride(
              channelId: 'chan_news',
              targetIsRole: role,
              targetId: id,
              allow: allow,
              deny: deny,
            );
        final denyMember = ov(memberRoleId, true, deny: {Perm.post});
        final allowPoster = ov('poster', true, allow: {Perm.post});
        s = s.copyWith(
          overrides: {denyMember.key: denyMember, allowPoster.key: allowPoster},
        );
        expect(s.can(carol, Perm.post, channelId: 'chan_news'), isFalse);
        expect(s.can(bob, Perm.post, channelId: 'chan_news'), isTrue);
        expect(s.can(bob, Perm.post, channelId: 'chan_a'), isTrue);
        final denyBob = ov(bob, false, deny: {Perm.post});
        s = s.copyWith(overrides: {...s.overrides, denyBob.key: denyBob});
        expect(s.can(bob, Perm.post, channelId: 'chan_news'), isFalse);
        // Moderators keep their own post switch; admins skip overrides.
        expect(s.can(admin, Perm.post, channelId: 'chan_news'), isTrue);
        expect(s.can(mod, Perm.post, channelId: 'chan_news'), isFalse);
      },
    );

    test('no view_channel means no channel-scoped switch', () {
      final s = base();
      final o = ChannelOverride(
        channelId: 'chan_a',
        targetIsRole: true,
        targetId: memberRoleId,
        deny: {Perm.viewChannel},
      );
      final t = s.copyWith(overrides: {o.key: o});
      expect(t.can(bob, Perm.post, channelId: 'chan_a'), isFalse);
      expect(t.can(bob, Perm.react, channelId: 'chan_a'), isFalse);
      expect(t.can(bob, Perm.post, channelId: 'chan_news'), isTrue);
    });

    test('an unknown role id on an account is ignored', () {
      final s = base().copyWith(
        assignments: {
          bob: {'ghost'},
        },
      );
      expect(s.can(bob, Perm.kick), isFalse);
      expect(s.can(bob, Perm.post), isTrue);
    });
  });

  group('transitions', () {
    test('rev must advance by exactly one', () {
      final s = base();
      expect(
        check(s, s.copyWith(rev: s.rev), owner).reject,
        GovernanceReject.badRev,
      );
      expect(
        check(s, s.copyWith(rev: s.rev + 2), owner).reject,
        GovernanceReject.badRev,
      );
      expect(check(s, bump(s), owner).ok, isTrue);
    });

    test('a plain member cannot create a role or assign one', () {
      final s = base();
      final withRole = bump(
        s,
        roles: {
          ...s.roles,
          'x': const Role('x', 'X', 500, {Perm.post}),
        },
      );
      expect(check(s, withRole, bob).reject, GovernanceReject.notAllowed);
      final assign = bump(
        s,
        assignments: {
          ...s.assignments,
          carol: {'moderator'},
        },
      );
      expect(check(s, assign, bob).reject, GovernanceReject.notAllowed);
    });

    test('admin creates a role below itself and assigns it', () {
      final s = base();
      final roles = {
        ...s.roles,
        'helper': const Role('helper', 'Helper', 100, {Perm.pin, Perm.kick}),
      };
      final created = bump(s, roles: roles);
      expect(check(s, created, admin).ok, isTrue);
      final assigned = bump(
        created,
        roles: roles,
        assignments: {
          ...created.assignments,
          bob: {'helper'},
        },
      );
      expect(check(created, assigned, admin).ok, isTrue);
      expect(assigned.can(bob, Perm.kick), isTrue);
    });

    test('hierarchy: no role at or above own rank, no touching peers', () {
      final s = base();
      final higher = bump(
        s,
        roles: {
          ...s.roles,
          'boss': const Role('boss', 'Boss', 5, {Perm.post}),
        },
      );
      expect(check(s, higher, admin).reject, GovernanceReject.hierarchy);
      final equal = bump(
        s,
        roles: {
          ...s.roles,
          'boss': const Role('boss', 'Boss', 10, {Perm.post}),
        },
      );
      expect(check(s, equal, admin).reject, GovernanceReject.badShape);
      // Admin may not demote the owner-level or a peer admin.
      final peer = s.copyWith(
        assignments: {
          ...s.assignments,
          carol: {'admin'},
        },
      );
      final strip = bump(
        peer,
        assignments: {
          admin: {'admin'},
          mod: {'moderator'},
        },
      );
      expect(check(peer, strip, admin).reject, GovernanceReject.hierarchy);
      expect(check(peer, strip, owner).ok, isTrue);
    });

    test('cannot grant a switch you do not hold', () {
      var s = base();
      final roles = {
        ...s.roles,
        'roleman': const Role('roleman', 'Roleman', 50, {Perm.manageRoles}),
      };
      s = bump(
        s,
        roles: roles,
        assignments: {
          ...s.assignments,
          bob: {'roleman'},
        },
      );
      final grant = bump(
        s,
        roles: {
          ...s.roles,
          'x': const Role('x', 'X', 200, {Perm.ban}),
        },
      );
      expect(check(s, grant, bob).reject, GovernanceReject.grantsMore);
      final self = bump(
        s,
        roles: {
          ...s.roles,
          'x': const Role('x', 'X', 200, {Perm.administrator}),
        },
      );
      expect(check(s, self, bob).reject, GovernanceReject.grantsMore);
    });

    test('only the owner moves ownership; owner is never a role holder', () {
      final s = base();
      expect(
        check(s, bump(s, owner: bob), admin).reject,
        GovernanceReject.ownerChange,
      );
      expect(check(s, bump(s, owner: bob), owner).ok, isTrue);
      final bad = bump(
        s,
        assignments: {
          ...s.assignments,
          owner: {'admin'},
        },
      );
      expect(check(s, bad, owner).reject, GovernanceReject.badShape);
    });

    test('a role holder may give up its own role, not take one', () {
      final s = base();
      final leave = bump(s, assignments: {mod: {}}..remove(mod));
      expect(check(s, leave, mod).ok, isFalse); // admin's role also dropped
      final onlyMod = bump(
        s,
        assignments: {
          admin: {'admin'},
        },
      );
      expect(check(s, onlyMod, mod).ok, isTrue);
      final take = bump(
        s,
        assignments: {
          ...s.assignments,
          mod: {'moderator', 'admin'},
        },
      );
      expect(check(s, take, mod).ok, isFalse);
    });

    test('assignments need members and known roles', () {
      final s = base();
      expect(
        check(
          s,
          bump(
            s,
            assignments: {
              ...s.assignments,
              'acct_stranger': {'moderator'},
            },
          ),
          owner,
        ).reject,
        GovernanceReject.notMember,
      );
      expect(
        check(
          s,
          bump(
            s,
            assignments: {
              ...s.assignments,
              bob: {'nope'},
            },
          ),
          owner,
        ).reject,
        GovernanceReject.unknownRole,
      );
    });

    test('channel overrides need manage_channels and held switches', () {
      final s = base();
      final o = ChannelOverride(
        channelId: 'chan_news',
        targetIsRole: true,
        targetId: memberRoleId,
        deny: {Perm.post},
      );
      final next = bump(s, overrides: {o.key: o});
      expect(check(s, next, bob).reject, GovernanceReject.notAllowed);
      expect(check(s, next, admin).ok, isTrue);
      // A moderator holds manage_channels only if given it.
      final withManage = bump(
        s,
        roles: {
          ...s.roles,
          'moderator': Role('moderator', 'Moderator', 20, {
            ...s.roles['moderator']!.perms,
            Perm.manageChannels,
          }),
        },
      );
      final s2 = withManage;
      final ov = ChannelOverride(
        channelId: 'chan_news',
        targetIsRole: true,
        targetId: memberRoleId,
        allow: {Perm.mentionAll},
      );
      // The moderator already holds mention_all, so it may allow it.
      expect(check(s2, bump(s2, overrides: {ov.key: ov}), mod).ok, isTrue);
      final unheld = ChannelOverride(
        channelId: 'chan_news',
        targetIsRole: true,
        targetId: memberRoleId,
        deny: {Perm.viewChannel},
        allow: {},
      );
      expect(
        check(s2, bump(s2, overrides: {unheld.key: unheld}), mod).ok,
        isTrue,
      );
      final groupWide = ChannelOverride(
        channelId: 'chan_news',
        targetIsRole: true,
        targetId: memberRoleId,
        allow: {Perm.kick},
      );
      expect(
        check(
          s2,
          bump(s2, overrides: {groupWide.key: groupWide}),
          admin,
        ).reject,
        GovernanceReject.badShape,
      );
    });

    test('limits and shape', () {
      final s = base();
      final many = {
        ...s.roles,
        for (var i = 0; i < maxRoles; i++)
          'r$i': Role('r$i', 'R$i', 100 + i, {Perm.post}),
      };
      expect(
        check(s, bump(s, roles: many), owner).reject,
        GovernanceReject.limits,
      );
      final noMember = bump(s, roles: Map.of(s.roles)..remove(memberRoleId));
      expect(check(s, noMember, owner).reject, GovernanceReject.badShape);
      final longName = bump(
        s,
        roles: {
          ...s.roles,
          'x': Role('x', 'n' * 33, 200, {Perm.post}),
        },
      );
      expect(check(s, longName, owner).reject, GovernanceReject.badShape);
    });

    test('two concurrent edits from the same prev: the second is stale', () {
      final s = base();
      final first = bump(
        s,
        assignments: {
          ...s.assignments,
          bob: {'moderator'},
        },
      );
      final second = bump(
        s,
        assignments: {
          ...s.assignments,
          carol: {'moderator'},
        },
      );
      expect(check(s, first, admin).ok, isTrue);
      // Applied in server order, the second now sees rev+1 already taken.
      expect(check(first, second, admin).reject, GovernanceReject.badRev);
    });
  });

  group('review 2026-11-01: escalation', () {
    // A "muted" role carrying a channel deny, Discord style.
    GovernanceState muted() {
      final s = base();
      return s.copyWith(
        roles: {
          ...s.roles,
          'muted': const Role('muted', 'Muted', 900, {}),
          'fan': const Role('fan', 'Fan', 800, {Perm.react}),
        },
        assignments: {
          ...s.assignments,
          carol: {'muted', 'fan'},
        },
        overrides: keyed([
          ov('chan_a', 'muted', deny: {Perm.post})
        ]),
      );
    }

    test('dropping your own role that carries a channel deny is refused', () {
      final s = muted();
      expect(s.can(carol, Perm.post, channelId: 'chan_a'), isFalse);
      final unmute = bump(
        s,
        assignments: {
          ...s.assignments,
          carol: {'fan'},
        },
      );
      expect(check(s, unmute, carol).reject, GovernanceReject.grantsMore);
      // A role whose loss gains nothing may still be given up.
      final dropFan = bump(
        s,
        assignments: {
          ...s.assignments,
          carol: {'muted'},
        },
      );
      expect(check(s, dropFan, carol).ok, isTrue);
      expect(check(s, unmute, mod).reject, GovernanceReject.notAllowed);
      expect(check(s, unmute, admin).ok, isTrue);
    });

    test('taking a role that carries a channel allow you lack is refused', () {
      final s0 = base();
      final s = s0.copyWith(
        roles: {
          ...s0.roles,
          'roleman': const Role('roleman', 'Roleman', 50, {Perm.manageRoles}),
          'poster': const Role('poster', 'Poster', 100, {Perm.viewChannel}),
        },
        assignments: {
          ...s0.assignments,
          bob: {'roleman'},
        },
        overrides: keyed([
          ov('chan_news', memberRoleId, deny: {Perm.post}),
          ov('chan_news', 'poster', allow: {Perm.post}),
        ]),
      );
      expect(s.can(bob, Perm.post, channelId: 'chan_news'), isFalse);
      final self = bump(
        s,
        assignments: {
          ...s.assignments,
          bob: {'roleman', 'poster'},
        },
      );
      expect(check(s, self, bob).reject, GovernanceReject.grantsMore);
      final other = bump(
        s,
        assignments: {
          ...s.assignments,
          carol: {'poster'},
        },
      );
      expect(check(s, other, bob).reject, GovernanceReject.grantsMore);
      expect(check(s, other, admin).ok, isTrue);
    });

    test('nobody writes an override for its own account', () {
      final s0 = base();
      final s = s0.copyWith(
        roles: {
          ...s0.roles,
          'moderator': Role('moderator', 'Moderator', 20, {
            ...s0.roles['moderator']!.perms,
            Perm.manageChannels,
          }),
        },
      );
      final self = bump(
        s,
        overrides: keyed([
          ov('chan_news', mod, role: false, allow: {Perm.post}),
        ]),
      );
      expect(check(s, self, mod).reject, GovernanceReject.hierarchy);
      final onBob = bump(
        s,
        overrides: keyed([
          ov('chan_news', bob, role: false, allow: {Perm.post}),
        ]),
      );
      expect(check(s, onBob, mod).ok, isTrue);
    });

    test('mayActOn needs the switch and a strictly higher rank', () {
      final s = base();
      expect(s.mayActOn(mod, bob, Perm.kick), isTrue);
      expect(s.mayActOn(mod, admin, Perm.kick), isFalse);
      expect(s.mayActOn(admin, owner, Perm.ban), isFalse);
      expect(s.mayActOn(mod, mod, Perm.kick), isFalse);
      expect(s.mayActOn(bob, carol, Perm.kick), isFalse);
      expect(s.mayActOn(owner, admin, Perm.ban), isTrue);
    });
  });

  group('review 2026-11-01: determinism and liveness', () {
    test('unknown switches in overrides are kept; group-wide refused', () {
      final s = base();
      final future = bump(
        s,
        overrides: keyed([
          ov('chan_a', memberRoleId, deny: {'post_polls'}),
        ]),
      );
      expect(check(s, future, admin).ok, isTrue);
      final wide = bump(
        s,
        overrides: keyed([
          ov('chan_a', memberRoleId, allow: {Perm.manageRoles}),
        ]),
      );
      expect(check(s, wide, admin).reject, GovernanceReject.badShape);
    });

    test('an override for a channel this device does not know is kept', () {
      final s = base();
      final next = bump(
        s,
        overrides: keyed([
          ov('chan_not_synced_yet', memberRoleId, deny: {Perm.post}),
        ]),
      );
      expect(check(s, next, admin).ok, isTrue);
    });

    test('a departed admin is pruned, so others can still write records', () {
      final s = base().copyWith(
        assignments: {
          admin: {'admin'},
          carol: {'admin'},
          mod: {'moderator'},
        },
      );
      const after = {owner, admin, mod, bob};
      final edit = bump(
        s,
        assignments: {
          ...s.assignments,
          bob: {'moderator'},
        },
      );
      // Without the prune every later record names carol and is refused.
      expect(
        check(s, edit, admin, roster: after).reject,
        GovernanceReject.notMember,
      );
      final pruned = s.removeAccount(carol, remaining: after);
      expect(pruned.rev, s.rev);
      expect(pruned.assignments.containsKey(carol), isFalse);
      final edit2 = bump(
        pruned,
        assignments: {
          ...pruned.assignments,
          bob: {'moderator'},
        },
      );
      expect(check(pruned, edit2, admin, roster: after).ok, isTrue);
      // Invited back, carol is a plain member.
      expect(pruned.isAdmin(carol), isFalse);
    });

    test('pruning drops the account override of the departed account', () {
      final s = base().copyWith(
        overrides: keyed([
          ov('chan_a', bob, role: false, deny: {Perm.post}),
          ov('chan_a', memberRoleId, deny: {Perm.attach}),
        ]),
      );
      final pruned = s.removeAccount(bob, remaining: {owner, admin, mod});
      expect(pruned.overrides.length, 1);
      expect(pruned.overrides.values.single.targetId, memberRoleId);
    });

    test('when the owner leaves, the strongest account inherits', () {
      final s = base().copyWith(
        assignments: {
          admin: {'admin'},
          'acct_aaa': {'admin'},
          mod: {'moderator'},
        },
      );
      const after = {admin, 'acct_aaa', mod, bob};
      final next = s.removeAccount(owner, remaining: after);
      // Both hold rank 10; the smaller account id wins.
      expect(next.owner, 'acct_aaa');
      expect(next.assignments.containsKey('acct_aaa'), isFalse);
      expect(next.assignments[admin], {'admin'});
      final rec = bump(
        next,
        assignments: {
          ...next.assignments,
          bob: {'moderator'},
        },
      );
      expect(check(next, rec, 'acct_aaa', roster: after).ok, isTrue);
      // With no roles left, the smallest account id inherits.
      final plain = GovernanceState.genesis(owner)
          .removeAccount(owner, remaining: {carol, bob});
      expect(plain.owner, bob);
    });
  });
}
