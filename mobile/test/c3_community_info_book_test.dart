import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/community_info_book.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/local_store.dart';

// C3 receive rules (docs/designs/C3-private-channels-and-info.md,
// "Authorship" and "Keys"), without native crypto: the opener is a fake that
// stands in for CommunityInfoCodec.open.

String _id(String prefix, int n) =>
    '${prefix}_${n.toRadixString(16).padLeft(32, '0')}';

final _community = _id('comm', 1);
final _private = _id('chan', 2);
final _open = _id('chan', 3);
const _shared = 'conv_shared';
const _privateConv = 'conv_private';
final _keyId = '1' * 32;
final _key = List<int>.filled(32, 9);
final _blob = List<int>.filled(64, 5);
final _digest = CommunityInfoCodec.recordSha256(_blob);

final _roles = GovernanceState(
  rev: 3,
  owner: 'acct_owner',
  ownerRev: 1,
  admins: const {'acct_admin': 1},
  moderators: const {'acct_mod'},
  joined: const {
    'acct_owner': 0,
    'acct_admin': 1,
    'acct_mod': 2,
    'acct_member': 3
  },
);

const _communityHome = InfoKeyHome(
    keySubjectKind: infoKindCommunity,
    keySubjectId: 'comm_00000000000000000000000000000001',
    conversationId: _shared);
const _privateHome = InfoKeyHome(
    keySubjectKind: infoKindChannel,
    keySubjectId: 'chan_00000000000000000000000000000002',
    conversationId: _privateConv);

CommunityInfoEvent _keyEvent(InfoKeyHome home, {String? conversation}) =>
    CommunityInfoEvent(
      kind: CommunityInfoEventKind.key,
      subjectKind: home.keySubjectKind,
      subjectId: home.keySubjectId,
      conversationId: conversation ?? home.conversationId,
      senderAccountId: 'acct_admin',
      senderDeviceId: 'dev_admin',
      keyId: _keyId,
      key: _key,
    );

CommunityInfoEvent _update(String kind, String subject,
        {String sender = 'acct_admin',
        String conversation = _shared,
        int revision = 2,
        String? digest}) =>
    CommunityInfoEvent(
      kind: CommunityInfoEventKind.update,
      subjectKind: kind,
      subjectId: subject,
      conversationId: conversation,
      senderAccountId: sender,
      senderDeviceId: 'dev',
      keyId: _keyId,
      revision: revision,
      recordSha256: digest ?? _digest,
    );

ServedCommunityInfo _served(String kind, String subject, {int version = 2}) =>
    ServedCommunityInfo(
        subjectKind: kind,
        subjectId: subject,
        version: version,
        keyId: _keyId,
        blob: _blob);

InfoOpener _opener({ProfileRecordFailure? fails}) => (key, served, cached) {
      if (fails != null) throw ProfileRecordException(fails);
      expect(key, _key);
      return CommunityInfoRecord(
          kind: served.subjectKind,
          subjectId: served.subjectId,
          revision: served.version,
          name: 'Club');
    };

void main() {
  InfoVerdict judge({
    required ServedCommunityInfo served,
    InfoKeyHome home = _communityHome,
    List<CommunityInfoEvent>? keys,
    required List<CommunityInfoEvent> updates,
    AcceptedCommunityInfo? accepted,
    InfoEditPolicy policy = const GovernanceInfoEditPolicy(null),
    InfoOpener? open,
  }) =>
      judgeCommunityInfo(
        served: served,
        home: home,
        keys: keys ?? [_keyEvent(home)],
        updates: updates,
        accepted: accepted,
        policy: policy,
        open: open ?? _opener(),
      );

  final policy = GovernanceInfoEditPolicy(_roles);

  test('an admin-announced community record with the shared key is shown', () {
    final verdict = judge(
        served: _served(infoKindCommunity, _community),
        updates: [_update(infoKindCommunity, _community)],
        policy: policy);
    expect(verdict, isA<InfoAccepted>());
    final accepted = (verdict as InfoAccepted).accepted;
    expect(accepted.revision, 2);
    expect(accepted.blob, _blob);
  });

  test('editors: community and category need an admin; channels any member',
      () {
    for (final (kind, subject) in [
      (infoKindCommunity, _community),
      (infoKindCategory, _id('cat', 4)),
    ]) {
      for (final (sender, shown) in [
        ('acct_owner', true),
        ('acct_admin', true),
        ('acct_mod', false),
        ('acct_member', false),
      ]) {
        expect(
            judge(
                served: _served(kind, subject),
                updates: [_update(kind, subject, sender: sender)],
                policy: policy) is InfoAccepted,
            shown,
            reason: '$kind by $sender');
      }
    }
    expect(
        judge(
            served: _served(infoKindChannel, _open),
            updates: [_update(infoKindChannel, _open, sender: 'acct_member')],
            policy: policy),
        isA<InfoAccepted>());
    // Admins restricting channel info (the seam C4's wiring fills).
    expect(
        judge(
            served: _served(infoKindChannel, _open),
            updates: [_update(infoKindChannel, _open, sender: 'acct_member')],
            policy:
                GovernanceInfoEditPolicy(_roles, channelInfoRestricted: true)),
        isA<InfoKept>());
    // No verified role record: nothing is trusted (D80).
    expect(
        judge(served: _served(infoKindCommunity, _community), updates: [
          _update(infoKindCommunity, _community, sender: 'acct_owner')
        ]),
        isA<InfoKept>());
  });

  test('a record nobody announced, or announced differently, is not shown', () {
    for (final updates in <List<CommunityInfoEvent>>[
      [],
      [_update(infoKindCommunity, _community, digest: 'cd' * 32)],
      [_update(infoKindCommunity, _community, revision: 3)],
      [_update(infoKindCommunity, _community, conversation: _privateConv)],
      [_update(infoKindCategory, _community)],
    ]) {
      final verdict = judge(
          served: _served(infoKindCommunity, _community),
          updates: updates,
          policy: policy);
      expect(verdict, isA<InfoKept>(), reason: '$updates');
      expect((verdict as InfoKept).reason, InfoKeptReason.notAnnounced);
    }
  });

  test('a key counts only from the group that owns it', () {
    // The community key arriving in a private channel's group, and a private
    // channel key arriving in the shared group, are both ignored.
    expect(
        judge(
            served: _served(infoKindCommunity, _community),
            keys: [_keyEvent(_communityHome, conversation: _privateConv)],
            updates: [_update(infoKindCommunity, _community)],
            policy: policy),
        isA<InfoNeedsKey>());
    expect(
        judge(
            served: _served(infoKindChannel, _private),
            home: _privateHome,
            keys: [_keyEvent(_privateHome, conversation: _shared)],
            updates: [
              _update(infoKindChannel, _private, conversation: _shared)
            ],
            policy: policy),
        isA<InfoNeedsKey>());
    // From its own group, with the announcement there too, it is shown.
    expect(
        judge(
            served: _served(infoKindChannel, _private),
            home: _privateHome,
            updates: [
              _update(infoKindChannel, _private,
                  conversation: _privateConv, sender: 'acct_member')
            ],
            policy: policy),
        isA<InfoAccepted>());
    // An announcement for a private channel made in the shared group does
    // not count, even with the right key.
    expect(
        judge(
            served: _served(infoKindChannel, _private),
            home: _privateHome,
            updates: [
              _update(infoKindChannel, _private, conversation: _shared)
            ],
            policy: policy),
        isA<InfoKept>());
    expect(mayDeliverInfoKey(_privateHome, _shared), isFalse);
    expect(mayDeliverInfoKey(_communityHome, _privateConv), isFalse);
    expect(mayDeliverInfoKey(_communityHome, _shared), isTrue);
  });

  test('rollback: an older or equal revision keeps the cache', () {
    final cache = AcceptedCommunityInfo(
        subjectKind: infoKindCommunity,
        subjectId: _community,
        revision: 2,
        keyId: _keyId,
        blob: _blob);
    final verdict = judge(
        served: _served(infoKindCommunity, _community),
        updates: [_update(infoKindCommunity, _community)],
        accepted: cache,
        policy: policy);
    expect((verdict as InfoKept).reason, InfoKeptReason.notNewer);
  });

  test('a key that fails on an announced record is dropped as forged', () {
    final verdict = judge(
        served: _served(infoKindCommunity, _community),
        updates: [_update(infoKindCommunity, _community)],
        policy: policy,
        open: _opener(fails: ProfileRecordFailure.authFailed));
    expect(verdict, isA<InfoBadKey>());
    expect((verdict as InfoBadKey).keyId, _keyId);
    // A record that opens but breaks the content rules keeps the key.
    expect(
        judge(
            served: _served(infoKindCommunity, _community),
            updates: [_update(infoKindCommunity, _community)],
            policy: policy,
            open: _opener(fails: ProfileRecordFailure.badName)),
        isA<InfoKept>());
  });

  test('one key request per subject per hour', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    expect(mayRequestInfoKey(null, now), isTrue);
    expect(mayRequestInfoKey(now.subtract(const Duration(minutes: 59)), now),
        isFalse);
    expect(
        mayRequestInfoKey(now.subtract(const Duration(hours: 1)), now), isTrue);
  });
}
