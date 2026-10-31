// Periodic MLS self-update: when a device refreshes its own leaf key
// (docs/crypto.md, change log 2026-10-31).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/mls_self_update_policy.dart';

typedef Policy = MlsSelfUpdatePolicy;

final _t0 = DateTime.utc(2026, 10, 31, 12);

Policy _policy({String device = 'dev_me'}) =>
    Policy(accountId: 'acct_me', deviceId: device);

SelfUpdateCandidate _chat(String id, {DateTime? activity, int members = 2}) =>
    (id: id, lastActivity: activity, members: members);

void main() {
  test('count trigger: due after 100 sent messages, not before', () {
    final policy = _policy()..recordPathCommit('conv', _t0);
    final later = _t0.add(const Duration(hours: 2));
    for (var i = 0; i < Policy.messageThreshold - 1; i++) {
      policy.recordSent('conv');
    }
    expect(policy.due([_chat('conv')], later), isEmpty);
    policy.recordSent('conv');
    expect(policy.due([_chat('conv')], later), ['conv']);
    // Never closer than the minimum interval to the last path commit.
    expect(policy.due([_chat('conv')], _t0.add(const Duration(minutes: 30))),
        isEmpty);
    // The accepted update resets the count.
    policy.recordPathCommit('conv', later);
    expect(policy.due([_chat('conv')], later.add(const Duration(hours: 2))),
        isEmpty);
  });

  test('time trigger: due after 7 days plus jitter, only with activity', () {
    final policy = _policy()..recordPathCommit('conv', _t0);
    final quiet =
        _chat('conv', activity: _t0.subtract(const Duration(days: 1)));
    final active = _chat('conv', activity: _t0.add(const Duration(days: 1)));
    final beforeAge = _t0.add(Policy.maxAge - const Duration(minutes: 1));
    final afterJitter = _t0.add(Policy.maxAge + Policy.maxAgeJitter);
    expect(policy.due([active], beforeAge), isEmpty);
    expect(policy.due([active], afterJitter), ['conv']);
    // A chat with nothing new since the last update does not churn epochs.
    expect(policy.due([quiet], afterJitter), isEmpty);
    // Sending counts as activity even when the list is stale.
    policy.recordSent('conv');
    expect(policy.due([quiet], afterJitter), ['conv']);
  });

  test('time trigger jitter differs between the devices of one group', () {
    final dues = <Duration>{};
    for (final device in ['dev_a', 'dev_b', 'dev_c', 'dev_d']) {
      final policy = _policy(device: device)..recordPathCommit('conv', _t0);
      final active = _chat('conv', activity: _t0.add(const Duration(days: 1)));
      var at = _t0.add(Policy.maxAge);
      while (policy.due([active], at).isEmpty) {
        at = at.add(const Duration(minutes: 10));
      }
      expect(at.difference(_t0),
          lessThanOrEqualTo(Policy.maxAge + Policy.maxAgeJitter));
      dues.add(at.difference(_t0));
    }
    expect(dues.length, greaterThan(1));
  });

  test('join trigger: due shortly after a Welcome, later in a big group', () {
    final policy = _policy()..recordJoined('conv', _t0);
    expect(policy.due([_chat('conv')], _t0), isEmpty);
    // Two members: at most 30 s plus 2 minutes of jitter.
    expect(policy.due([_chat('conv')], _t0.add(const Duration(minutes: 3))),
        ['conv']);

    final big = _policy()..recordJoined('big', _t0);
    var at = _t0;
    while (big.due([_chat('big', members: 100)], at).isEmpty) {
      at = at.add(const Duration(minutes: 1));
    }
    expect(
        at.difference(_t0),
        lessThanOrEqualTo(Policy.joinDelay +
            Policy.joinJitterMax +
            const Duration(minutes: 1)));
    // An unknown size (0) counts as a mid-sized group, not as a DM.
    final unknown = _policy()..recordJoined('unknown', _t0);
    expect(unknown.joinsPending, ['unknown']);
    expect(
        unknown.due(
            [_chat('unknown', members: 0)],
            _t0.add(Policy.joinDelay +
                Policy.joinJitterPerMember * Policy.unknownMembers)),
        ['unknown']);
    // Join updates come before count and time triggers.
    final mixed = _policy()
      ..recordPathCommit('busy', _t0.subtract(const Duration(days: 30)))
      ..recordJoined('new', _t0);
    for (var i = 0; i < Policy.messageThreshold; i++) {
      mixed.recordSent('busy');
    }
    expect(
        mixed.due(
            [_chat('busy'), _chat('new')], _t0.add(const Duration(hours: 1))),
        ['new', 'busy']);
  });

  test('a chat seen first after an upgrade is spread over the next week', () {
    final policy = _policy();
    final activity = _t0.add(const Duration(days: 30));
    final chats = [
      for (var i = 0; i < 50; i++) _chat('conv_$i', activity: activity),
    ];
    // Nothing is due at once: the whole fleet must not update together.
    expect(policy.due(chats, _t0), isEmpty);
    expect(policy.dirty, isTrue);
    final firstDay = policy.due(chats, _t0.add(const Duration(days: 1)));
    expect(firstDay.length, lessThan(25));
    expect(
        policy.due(chats, _t0.add(Policy.maxAge + Policy.maxAgeJitter)).length,
        50);
  });

  test('a back-off holds the conversation, then it is due again', () {
    final policy = _policy()..recordJoined('conv', _t0);
    final due = _t0.add(const Duration(hours: 1));
    expect(policy.due([_chat('conv')], due), ['conv']);
    policy.recordBackoff('conv', due, Policy.conflictBackoff);
    expect(policy.due([_chat('conv')], due.add(Policy.conflictBackoff ~/ 2)),
        isEmpty);
    expect(
        policy.due([_chat('conv')],
            due.add(Policy.conflictBackoff + Policy.conflictBackoff ~/ 2)),
        ['conv']);
  });

  test('state round-trips and is bound to this account and device', () {
    final policy = _policy()
      ..recordPathCommit('a', _t0)
      ..recordJoined('b', _t0)
      ..recordBackoff('b', _t0, Policy.refusedBackoff);
    for (var i = 0; i < 7; i++) {
      policy.recordSent('a');
    }
    final raw = policy.encode();
    final again = Policy.decode(raw, accountId: 'acct_me', deviceId: 'dev_me');
    expect(again.encode(), raw);
    // A re-linked device or another account starts over.
    final relinked =
        Policy.decode(raw, accountId: 'acct_me', deviceId: 'dev_new');
    expect(relinked.encode(), isNot(contains('"a"')));
    expect(Policy.decode('not json', accountId: 'x', deviceId: 'y').encode(),
        contains('"groups":{}'));
  });

  test('records of chats that left the list are dropped, joins kept', () {
    final policy = _policy()
      ..recordPathCommit('gone', _t0)
      ..recordJoined('joining', _t0)
      ..recordPathCommit('kept', _t0);
    policy.due([_chat('kept')], _t0.add(const Duration(minutes: 1)));
    final raw = policy.encode();
    expect(raw, isNot(contains('"gone"')));
    expect(raw, contains('"joining"'));
    // An empty list means nothing is loaded yet; nothing is dropped.
    policy.due(const [], _t0);
    expect(policy.encode(), contains('"kept"'));
  });
}
