import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';

/// C2 receiver rule: drop a restricted post from a sender below admin, judged
/// only from the signed role record; nothing is dropped without one.
void main() {
  GovernanceState record({
    bool adminsOnly = false,
    Set<String> announcement = const {},
  }) =>
      GovernanceState(
        rev: 5,
        owner: 'own',
        ownerRev: 0,
        admins: {'adm': 2},
        moderators: {'mod'},
        adminsOnlyPosting: adminsOnly,
        announcementChannels: announcement,
        joined: {'own': 0, 'adm': 2, 'mod': 3, 'mem': 4},
      );

  bool drop(
    GovernanceState? r,
    String sender, {
    String? channel,
    bool server = false,
  }) =>
      shouldDropRestrictedPost(
        record: r,
        sender: sender,
        channelId: channel,
        serverRestricts: server,
      );

  test('an admins-only group drops members and moderators, keeps admins', () {
    final r = record(adminsOnly: true);
    expect(drop(r, 'mem'), isTrue);
    expect(drop(r, 'mod'), isTrue);
    expect(drop(r, 'adm'), isFalse);
    expect(drop(r, 'own'), isFalse);
  });

  test('an unrestricted group drops nothing', () {
    final r = record();
    for (final who in ['mem', 'mod', 'adm', 'own']) {
      expect(drop(r, who), isFalse, reason: who);
    }
  });

  test('an announcement channel restricts only that channel', () {
    final r = record(announcement: {'news'});
    expect(drop(r, 'mem', channel: 'news'), isTrue);
    expect(drop(r, 'mem', channel: 'general'), isFalse);
    expect(drop(r, 'adm', channel: 'news'), isFalse);
  });

  test('the server can narrow but never widen', () {
    expect(drop(record(), 'mem', server: true), isTrue);
    expect(drop(record(), 'adm', server: true), isFalse);
    // The record restricts; a server saying "open" changes nothing.
    expect(drop(record(adminsOnly: true), 'mem', server: false), isTrue);
  });

  test(
    'no verified record: nothing is dropped, even where the server restricts',
    () {
      expect(drop(null, 'mem', server: true), isFalse);
      expect(drop(null, 'adm', server: true), isFalse);
    },
  );

  test('a sender the record does not name is a member', () {
    expect(drop(record(adminsOnly: true), 'stranger'), isTrue);
  });

  test('only visible post types are judged', () {
    expect(restrictedPostTypes.map((t) => t.name).toSet(), {
      'text',
      'reply',
      'attachmentManifest',
      'poll',
    });
  });
}
