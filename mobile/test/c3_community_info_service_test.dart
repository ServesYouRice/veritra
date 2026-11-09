import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/community_info_book.dart';
import 'package:private_messenger/core/community_info_service.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/community_info_payload.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart'
    show communityInfoEventFor;
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

// C3 senders and fetch loop, end to end between two devices of different
// accounts sharing a fake server and a fake MLS group: whatever one device
// "sends" lands in the other's store exactly as the receive path stores it.

String _id(String prefix, int n) =>
    '${prefix}_${n.toRadixString(16).padLeft(32, '0')}';

final _community = _id('comm', 1);
final _open = _id('chan', 2);
final _private = _id('chan', 3);
const _shared = 'conv_shared';
const _privateConv = 'conv_private';

class _Server implements InfoApi {
  final Map<String, ServedCommunityInfo> records = {};
  int puts = 0;

  @override
  Future<ServedCommunityInfo?> get(
          {required String kind,
          required String subjectId,
          String? communityId}) async =>
      records['$kind|$subjectId'];

  @override
  Future<int> put(
      {required String kind,
      required String subjectId,
      String? communityId,
      required String keyId,
      required List<int> blob,
      required int expectedVersion}) async {
    final current = records['$kind|$subjectId']?.version ?? 0;
    if (current != expectedVersion) throw const InfoVersionConflict();
    puts++;
    records['$kind|$subjectId'] = ServedCommunityInfo(
        subjectKind: kind,
        subjectId: subjectId,
        version: current + 1,
        keyId: keyId,
        blob: List<int>.from(blob));
    return current + 1;
  }
}

class _Topology implements InfoTopology {
  _Topology(this.admin);
  final bool admin;
  @override
  String? sharedConversationOf(String communityId) =>
      communityId == _community ? _shared : null;
  @override
  String? privateConversationOf(String channelId) =>
      channelId == _private ? _privateConv : null;
  @override
  bool serverSaysAdmin(String communityId) => admin;
}

/// One device: its store and service. [members] says which conversations it
/// is in; a send reaches every other device in that conversation.
class _Device {
  _Device(this.name, this.store, this.members);
  final String name;
  final LocalStore store;
  final Set<String> members;
  late CommunityInfoService service;
  final sent = <(String, AppPayloadType, Map<String, Object?>)>[];
}

class _Net {
  final devices = <_Device>[];
  var held = false;

  Future<bool> deliver(_Device from, String conversation, AppPayloadType type,
      Map<String, Object?> body) async {
    if (held || !from.members.contains(conversation)) return false;
    from.sent.add((conversation, type, body));
    final payload = DecryptedAppPayload(type: type, actionId: 'a', body: body);
    // The sender keeps its own copy (outgoing transition).
    await from.store.recordOwnCommunityInfoEvents([
      communityInfoEventFor(payload,
          conversationId: conversation,
          senderAccountId: 'acct_${from.name}',
          senderDeviceId: 'dev_${from.name}')
    ]);
    for (final d in devices) {
      if (d == from || !d.members.contains(conversation)) continue;
      await d.store.recordOwnCommunityInfoEvents([
        communityInfoEventFor(payload,
            conversationId: conversation,
            senderAccountId: 'acct_${from.name}',
            senderDeviceId: 'dev_${from.name}')
      ]);
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  late _Server server;
  late _Net net;

  final roles = GovernanceState(
    rev: 1,
    owner: 'acct_admin',
    ownerRev: 1,
    joined: const {'acct_admin': 0, 'acct_member': 1, 'acct_other': 2},
  );

  _Device device(String name, Set<String> members,
      {bool admin = false, GovernanceState? verified}) {
    final d = _Device(name, MemoryLocalStore(), members);
    d.service = CommunityInfoService(
      store: d.store,
      api: server,
      send: (c, t, b) => net.deliver(d, c, t, b),
      topology: _Topology(admin),
      codec: CommunityInfoCodec(bindings, random: Random(name.hashCode)),
      policyFor: (_) => GovernanceInfoEditPolicy(verified ?? roles),
      accountId: 'acct_$name',
      deviceId: 'dev_$name',
      answerDelay: () => Duration.zero,
    );
    net.devices.add(d);
    return d;
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = _Server();
    net = _Net();
    if (skip != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  const community = InfoSubject(
      infoKindCommunity,
      'comm_00000000000000000000000000000001',
      'comm_00000000000000000000000000000001');

  CommunityInfoRecord named(String name, int revision) => CommunityInfoRecord(
      kind: infoKindCommunity,
      subjectId: _community,
      revision: revision,
      name: name,
      categories: const [],
      channels: [InfoChannelPlace(channelId: _open)]);

  test('an admin publishes; a member asks for the key, gets it, and shows it',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r));
    expect(admin.service.shown(infoKindCommunity, _community)?.name, 'Club');
    expect(server.records['community|$_community']?.version, 1);
    // The announcement went into the shared group.
    expect(admin.sent.single.$1, _shared);
    expect(admin.sent.single.$2, AppPayloadType.infoUpdate);

    // The member has the announcement but no key: it asks at once.
    expect(await member.service.refresh(community), isA<InfoNeedsKey>());
    expect(member.sent.last.$2, AppPayloadType.infoKeyRequest);
    expect(member.sent.last.$1, _shared);
    // Asking again within the hour sends nothing.
    await member.service.refresh(community);
    expect(member.sent.where((s) => s.$2 == AppPayloadType.infoKeyRequest),
        hasLength(1));

    // The admin answers once, in the shared group.
    expect(
        await admin.service
            .answerRequests(admin.service.homeOf(community)!, _community),
        1);
    expect(
        await admin.service
            .answerRequests(admin.service.homeOf(community)!, _community),
        0);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(member.service.shown(infoKindCommunity, _community)?.name, 'Club');
  }, skip: skip);

  test('a member who is not an admin never answers', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    final other = device('other', {_shared});
    await admin.service.publish(community, (r) => named('Club', r));
    await other.service.refresh(community);
    // The member holds no trusted key and is no admin: silence.
    expect(
        await member.service
            .answerRequests(member.service.homeOf(community)!, _community),
        0);
    expect(member.sent, isEmpty);
  }, skip: skip);

  test('a private channel key never goes into the shared group', () async {
    final admin = device('admin', {_shared, _privateConv}, admin: true);
    final insider = device('member', {_shared, _privateConv});
    final outsider = device('other', {_shared});
    const private = InfoSubject(
        infoKindChannel,
        'chan_00000000000000000000000000000003',
        'comm_00000000000000000000000000000001');
    await admin.service.publish(
        private,
        (r) => CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: _private,
            revision: r,
            name: 'staff',
            topic: '',
            privatePlace: const InfoPrivatePlace(position: 0)));
    expect(admin.sent.single.$1, _privateConv);
    // The outsider cannot even ask in the private group; a forged request in
    // the shared group is not answered there.
    await outsider.service.requestKey(InfoKeyHome(
        keySubjectKind: infoKindChannel,
        keySubjectId: _private,
        conversationId: _shared));
    expect(
        await admin.service
            .answerRequests(admin.service.homeOf(private)!, _community),
        0);
    // The insider asks in the private group and gets it there.
    expect(await insider.service.refresh(private), isA<InfoNeedsKey>());
    expect(insider.sent.last.$1, _privateConv);
    expect(
        await admin.service
            .answerRequests(admin.service.homeOf(private)!, _community),
        1);
    expect(admin.sent.last.$1, _privateConv);
    expect(await insider.service.refresh(private), isA<InfoAccepted>());
    // Nothing about it reached the outsider.
    expect(
        await outsider.store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, infoKindChannel, _private),
        isEmpty);
  }, skip: skip);

  test('a stale If-Match is retried; a 404 never clears what is shown',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r));
    // Someone else wrote meanwhile: the next publish reads the version again.
    server.records['community|$_community'] = ServedCommunityInfo(
        subjectKind: infoKindCommunity,
        subjectId: _community,
        version: 5,
        keyId: '0' * 32,
        blob: const [1]);
    await admin.service.publish(community, (r) => named('Club 2', r));
    expect(server.records['community|$_community']?.version, 6);
    server.records.clear();
    expect(await admin.service.refresh(community), isNull);
    expect(admin.service.shown(infoKindCommunity, _community)?.name, 'Club 2');
  }, skip: skip);

  test('rotation: a new key after the removal, records sealed again', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    final kicked = device('other', {_shared});
    await admin.service.publish(community, (r) => named('Club', r));
    final oldKey = server.records['community|$_community']!.keyId;
    final home = admin.service.homeOf(community)!;
    await admin.service.markRotationDue(home, _community);
    // The kicked member has left the group by the time the key goes out.
    kicked.members.remove(_shared);
    // While the removal holds sends, the rotation waits and stays due.
    net.held = true;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    net.held = false;
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    final served = server.records['community|$_community']!;
    expect(served.keyId, isNot(oldKey));
    expect(served.version, 2);
    // The new key went to the remaining member only.
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(
        (await kicked.store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, infoKindCommunity, _community))
            .map((k) => k.keyId),
        isNot(contains(served.keyId)));
  }, skip: skip);

  test('without verified roles nothing from others is trusted', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared}, verified: null);
    // Replace the member's policy with "no role record".
    member.service = CommunityInfoService(
      store: member.store,
      api: server,
      send: (c, t, b) => net.deliver(member, c, t, b),
      topology: _Topology(false),
      codec: CommunityInfoCodec(bindings),
      policyFor: (_) => const GovernanceInfoEditPolicy(null),
      accountId: 'acct_member',
      deviceId: 'dev_member',
      answerDelay: () => Duration.zero,
    );
    await admin.service.publish(community, (r) => named('Club', r));
    await member.service.refresh(community);
    await admin.service
        .answerRequests(admin.service.homeOf(community)!, _community);
    expect(await member.service.refresh(community), isA<InfoKept>());
    expect(member.service.shown(infoKindCommunity, _community), isNull);
  }, skip: skip);

  test('info bodies the service sends pass the payload codec', () {
    final key = List<int>.filled(32, 3);
    final codec = AppPayloadCodec();
    for (final (type, body) in [
      (
        AppPayloadType.infoKey,
        infoKeyBody(subjectKind: 'community', subjectId: _community, key: key)
      ),
      (
        AppPayloadType.infoKeyRequest,
        infoKeyRequestBody(subjectKind: 'channel', subjectId: _private)
      ),
    ]) {
      final framed = codec.encode(
          type: type,
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'a',
          body: body,
          hidden: true);
      expect(
          codec.classify(framed,
              conversationId: 'conv', senderDeviceId: 'dev', actionId: 'a'),
          isA<DecodedAppPayload>());
    }
  });
}
