import 'dart:async';
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
import 'package:private_messenger/crypto/profile_record_codec.dart';
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
  bool failPuts = false;
  Future<void> Function()? beforePut;
  Future<void> Function()? beforeGet;

  @override
  Future<ServedCommunityInfo?> get(
      {required String kind,
      required String subjectId,
      String? communityId}) async {
    final hook = beforeGet;
    beforeGet = null;
    await hook?.call();
    return records['$kind|$subjectId'];
  }

  @override
  Future<int> put(
      {required String kind,
      required String subjectId,
      String? communityId,
      required String keyId,
      required List<int> blob,
      required int expectedVersion}) async {
    final hook = beforePut;
    beforePut = null;
    await hook?.call();
    if (failPuts) throw StateError('server refused');
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
  _Topology(this.admin, [this.net]);
  bool? admin;
  final _Net? net;
  bool privateKnown = true;
  bool gone = false;
  String sharedConversation = _shared;
  @override
  bool sendHeld(String conversationId) => net?.held ?? false;
  @override
  bool communityGone(String communityId) => gone;
  @override
  String? sharedConversationOf(String communityId) =>
      communityId == _community ? sharedConversation : null;
  @override
  String? privateConversationOf(String channelId) =>
      privateKnown && channelId == _private ? _privateConv : null;
  @override
  bool? serverSaysAdmin(String communityId) => admin;
}

class _DelayedCacheStore extends MemoryLocalStore {
  bool delayNextRead = false;
  final reading = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<AcceptedCommunityInfo?> loadAcceptedCommunityInfo(
      String subjectKind, String subjectId) async {
    final snapshot =
        await super.loadAcceptedCommunityInfo(subjectKind, subjectId);
    if (delayNextRead) {
      delayNextRead = false;
      reading.complete();
      await resume.future;
    }
    return snapshot;
  }
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
  var refuse = false;
  AppPayloadType? refuseType;
  Future<void> Function(AppPayloadType)? afterDeliver;

  Future<bool> deliver(_Device from, String conversation, AppPayloadType type,
          Map<String, Object?> body) =>
      deliverAs(from, 'dev_${from.name}', conversation, type, body);

  Future<bool> deliverAs(_Device from, String device, String conversation,
      AppPayloadType type, Map<String, Object?> body) async {
    if (held ||
        refuse ||
        refuseType == type ||
        !from.members.contains(conversation)) {
      return false;
    }
    from.sent.add((conversation, type, body));
    final payload = DecryptedAppPayload(type: type, actionId: 'a', body: body);
    // The sender keeps its own copy (outgoing transition).
    await from.store.recordOwnCommunityInfoEvents([
      communityInfoEventFor(payload,
          conversationId: conversation,
          senderAccountId: 'acct_${from.name}',
          senderDeviceId: device)
    ]);
    for (final d in devices) {
      if (d == from || !d.members.contains(conversation)) continue;
      await d.store.recordOwnCommunityInfoEvents([
        communityInfoEventFor(payload,
            conversationId: conversation,
            senderAccountId: 'acct_${from.name}',
            senderDeviceId: device)
      ]);
    }
    await afterDeliver?.call(type);
    return true;
  }
}

void unawaitedMark(CommunityInfoService service, InfoKeyHome home) {
  // Made from inside a pass, as a kick during a rotation would.
  service.markRotationDue(home, 'comm_00000000000000000000000000000001');
}

DateTime now = DateTime.utc(2026, 11, 9, 12);

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
      {bool admin = false,
      GovernanceState? verified,
      LocalStore? store,
      Duration Function()? answerDelay}) {
    final d = _Device(name, store ?? MemoryLocalStore(), members);
    d.service = CommunityInfoService(
      store: d.store,
      api: server,
      send: (c, t, b) => net.deliver(d, c, t, b),
      topology: _Topology(admin, net),
      codec: CommunityInfoCodec(bindings, random: Random(name.hashCode)),
      policyFor: (_) => GovernanceInfoEditPolicy(verified ?? roles),
      accountId: 'acct_$name',
      deviceId: 'dev_$name',
      answerDelay: answerDelay ?? () => Duration.zero,
      clock: () => now,
    );
    net.devices.add(d);
    return d;
  }

  setUp(() {
    now = DateTime.utc(2026, 11, 9, 12);
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

  test('an adding admin delivers the key and announcements without a request',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final joiner = device('member', {_shared});
    expect(
        await joiner.service
            .currentKey(admin.service.homeOf(community)!, _community),
        isNull);
    expect(
        await admin.service.deliverAfterAdd(
            admin.service.homeOf(community)!, _community, [community]),
        isTrue);
    expect(admin.sent.map((e) => e.$2).toList().sublist(1),
        [AppPayloadType.infoKey, AppPayloadType.infoUpdate]);
    expect(await joiner.service.refresh(community), isA<InfoAccepted>());
    expect(joiner.service.shown(infoKindCommunity, _community)?.name, 'Club');
    expect(joiner.sent, isEmpty);
    expect(server.puts, 1);
  }, skip: skip);

  test('add delivery sends a private key only in its owning group', () async {
    final admin = device('admin', {_shared, _privateConv}, admin: true);
    final publicMember = device('other', {_shared});
    const private = InfoSubject(
        infoKindChannel,
        'chan_00000000000000000000000000000003',
        'comm_00000000000000000000000000000001');
    await admin.service.publish(
        private,
        (r) => CommunityInfoRecord(
            kind: private.kind,
            subjectId: private.id,
            revision: r,
            name: 'Private',
            privatePlace: const InfoPrivatePlace(position: 0)),
        mint: true);
    final joiner = device('member', {_shared, _privateConv});
    expect(
        await admin.service.deliverAfterAdd(
            admin.service.homeOf(private)!, _community, [community, private]),
        isTrue);
    expect(await joiner.service.refresh(private), isA<InfoAccepted>());
    expect(
        await publicMember.store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, infoKindChannel, _private),
        isEmpty);
    expect(admin.sent.every((e) => e.$1 == _privateConv), isTrue);
  }, skip: skip);

  test('add delivery waits for a removal and requests a missing key', () async {
    final admin = device('admin', {_shared}, admin: true);
    final home = admin.service.homeOf(community)!;
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isFalse);
    expect(admin.sent.single.$2, AppPayloadType.infoKeyRequest);
    expect(await admin.service.currentKey(home, _community), isNull);
    await admin.service.markRotationDue(home, _community);
    admin.sent.clear();
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isFalse);
    expect(admin.sent, isEmpty);
    expect(server.puts, 0);
  }, skip: skip);

  test('failed add delivery can retry without consuming a request allowance',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final joiner = device('member', {_shared});
    net.refuseType = AppPayloadType.infoUpdate;
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isFalse);
    net.refuseType = null;
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isTrue);
    expect(await joiner.service.refresh(community), isA<InfoAccepted>());
  }, skip: skip);

  test('a removal during add delivery cancels its remaining announcements',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    admin.sent.clear();
    net.afterDeliver = (type) async {
      if (type == AppPayloadType.infoKey) {
        net.afterDeliver = null;
        await admin.service.markRotationDue(home, _community);
      }
    };
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isFalse);
    expect(admin.sent.map((e) => e.$2), [AppPayloadType.infoKey]);
    expect(await admin.service.dueRotations(), {'community|$_community'});
  }, skip: skip);

  test('add delivery never re-announces a record under a different key',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final fresh = await admin.service.newKey(home);
    admin.sent.clear();
    expect(await admin.service.deliverAfterAdd(home, _community, [community]),
        isTrue);
    expect(admin.sent.map((e) => e.$2), [AppPayloadType.infoKey]);
    expect(admin.sent.single.$3['key_id'], fresh.keyId);
  }, skip: skip);

  test('a member delivering a key cannot author community info', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await admin.service.deliverAfterAdd(home, _community, [community]);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    member.sent.clear();
    expect(await member.service.deliverAfterAdd(home, _community, [community]),
        isTrue);
    expect(member.sent.map((e) => e.$2), [AppPayloadType.infoKey]);
  }, skip: skip);

  test('an admin publishes; a member asks for the key, gets it, and shows it',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
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
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    await other.service.refresh(community);
    // The member holds no trusted key and is no admin: silence.
    expect(
        await member.service
            .answerRequests(member.service.homeOf(community)!, _community),
        0);
    expect(member.sent, isEmpty);
  }, skip: skip);

  test('rotation stays pending until its announcement is queued', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    await admin.service.answerRequests(home, _community);
    await member.service.refresh(community);
    await admin.service.markRotationDue(home, _community);
    net.refuseType = AppPayloadType.infoUpdate;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(await admin.service.dueRotations(), {'community|$_community'});
    expect(await member.service.refresh(community), isA<InfoKept>());
    net.refuseType = null;
    now = now.add(const Duration(minutes: 2));
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(await admin.service.dueRotations(), isEmpty);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
  }, skip: skip);

  test('snapshot edits refuse newer metadata, including on conflict retry',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final original = server.records[community.key]!;
    final advanced = ServedCommunityInfo(
        subjectKind: original.subjectKind,
        subjectId: original.subjectId,
        version: 2,
        keyId: original.keyId,
        blob: original.blob);
    server.beforePut = () async => server.records[community.key] = advanced;
    await expectLater(
        admin.service.publish(community, (r) => named('Stale edit', r),
            expectedRevision: 1),
        throwsA(isA<InfoVersionConflict>()));
    expect(server.puts, 1);
    expect(server.records[community.key], same(advanced));
    await expectLater(
        admin.service.publish(community, (r) => named('Stale edit', r),
            expectedRevision: 1),
        throwsA(isA<InfoVersionConflict>()));
    expect(server.puts, 1);
  }, skip: skip);

  test('an unauthorized matching announcement cannot suppress healing',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    net.refuseType = AppPayloadType.infoUpdate;
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    net.refuseType = null;
    final served = server.records[community.key]!;
    await net.deliver(
        member,
        _shared,
        AppPayloadType.infoUpdate,
        infoUpdateBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            revision: served.version,
            keyId: served.keyId,
            recordSha256: CommunityInfoCodec.recordSha256(served.blob)));
    expect(await admin.service.healAnnouncement(community), isTrue);
    expect(admin.sent.single.$2, AppPayloadType.infoUpdate);
  }, skip: skip);

  test('an unrelated member key cannot suppress an admin answer', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final member = device('member', {_shared});
    final attacker = device('other', {_shared});
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    final unrelated = await attacker.service.newKey(home);
    await net.deliver(
        attacker,
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: unrelated.key!));
    expect(await admin.service.answerRequests(home, _community), 1);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(member.service.shown(infoKindCommunity, _community)?.name, 'Club');
  }, skip: skip);

  test('a failed joiner announcement retries immediately after key delivery',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final member = device('member', {_shared});
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    net.refuseType = AppPayloadType.infoUpdate;
    expect(await admin.service.answerRequests(home, _community), 0);
    expect(await member.service.refresh(community), isA<InfoKept>());
    net.refuseType = null;
    await admin.service.answerRequests(home, _community);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoKey), isNotEmpty);
  }, skip: skip);

  test('a removal during the answer delay waits for the rotated key', () async {
    late _Device admin;
    var markDuringDelay = true;
    admin = device('admin', {_shared}, admin: true, answerDelay: () {
      if (markDuringDelay) {
        markDuringDelay = false;
        unawaitedMark(admin.service, admin.service.homeOf(community)!);
      }
      return Duration.zero;
    });
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final member = device('member', {_shared});
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    expect(await admin.service.answerRequests(home, _community), 0);
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoKey), isEmpty);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    await admin.service.answerRequests(home, _community);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
  }, skip: skip);

  test('an answer selects a remote rotation received during its delay',
      () async {
    late _Device admin;
    final fresh = List<int>.filled(32, 19);
    var rotateDuringDelay = true;
    admin = device('admin', {_shared}, admin: true, answerDelay: () {
      if (rotateDuringDelay) {
        rotateDuringDelay = false;
        unawaited(net.deliverAs(
            admin,
            'dev_admin_other',
            _shared,
            AppPayloadType.infoKey,
            infoKeyBody(
                subjectKind: infoKindCommunity,
                subjectId: _community,
                key: fresh)));
      }
      return Duration.zero;
    });
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final member = device('member', {_shared});
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    await admin.service.answerRequests(home, _community);
    // Another admin already delivered the new key, so no stale response.
    final keys = admin.sent.where((s) => s.$2 == AppPayloadType.infoKey);
    expect(keys, hasLength(1));
    expect(
        keys.single.$3['key'],
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: fresh)['key']);
    // The cached record still uses the old key. Do not advertise it as
    // part of this answer: the joiner only received the new key.
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoUpdate),
        hasLength(1));
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
            privatePlace: const InfoPrivatePlace(position: 0)),
        mint: true);
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
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
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
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
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

  test('a newer removal cancels a rotation whose key was already sent',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final removed = device('other', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final original = server.records[community.key]!;
    await admin.service.markRotationDue(home, _community);
    String? exposedKey;
    net.afterDeliver = (type) async {
      if (type != AppPayloadType.infoKey) return;
      net.afterDeliver = null;
      exposedKey = admin.sent.last.$3['key_id'] as String;
      // This member received the first rotation key, then a second removal
      // completed before that send returned to the first rotation pass.
      removed.members.remove(_shared);
      await admin.service.markRotationDue(home, _community);
    };
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(exposedKey, isNotNull);
    expect(server.puts, 1);
    expect(server.records[community.key], same(original));
    expect(await admin.service.dueRotations(), {'community|$_community'});
    // The abandoned pass must not back off the new removal's rotation.
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    final safe = server.records[community.key]!;
    expect(safe.keyId, isNot(exposedKey));
    expect(
        (await removed.store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, infoKindCommunity, _community))
            .map((k) => k.keyId),
        contains(exposedKey));
    expect(
        (await removed.store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, infoKindCommunity, _community))
            .map((k) => k.keyId),
        isNot(contains(safe.keyId)));
  }, skip: skip);

  test('private rotation survives restart and excludes the removed member',
      () async {
    final admin = device('admin', {_shared, _privateConv}, admin: true);
    final member = device('member', {_shared, _privateConv});
    final removed = device('other', {_shared, _privateConv});
    final outsider = device('outsider', {_shared});
    final private = InfoSubject(infoKindChannel, _private, _community);
    CommunityInfoRecord record(int revision) => CommunityInfoRecord(
        kind: infoKindChannel,
        subjectId: _private,
        revision: revision,
        name: 'Private plans',
        topic: 'Members only',
        privatePlace: const InfoPrivatePlace(position: 0));
    await admin.service.publish(private, record, mint: true);
    final home = admin.service.homeOf(private)!;
    // Give the departing member the original key, as a real prior member
    // would have it. It must fail to open the later record even with that key.
    await removed.service.requestKey(home);
    await admin.service.answerRequests(home, _community);
    expect(await removed.service.refresh(private), isA<InfoAccepted>());
    final oldKey = (await admin.service.currentKey(home, _community))!;
    removed.members.remove(_privateConv);
    await admin.service.markRotationDue(home, _community);
    server.failPuts = true;
    expect(await admin.service.runRotations((_, __) => [private]), 0);
    final freshKey = (await admin.service.currentKey(home, _community))!;
    expect(freshKey.keyId, isNot(oldKey.keyId));
    expect(await admin.service.dueRotations(), {'channel|$_private'});

    // The new process uses the same durable store. It must reuse the key
    // already delivered and keep edits blocked until re-sealing succeeds.
    net.devices.remove(admin);
    final restarted = device('admin', {_shared, _privateConv},
        admin: true, store: admin.store);
    await expectLater(restarted.service.publish(private, record),
        throwsA(isA<InfoRotationPending>()));
    server.failPuts = false;
    expect(await restarted.service.runRotations((_, __) => [private]), 1);
    expect(await restarted.service.dueRotations(), isEmpty);
    final served = server.records[private.key]!;
    expect(served.keyId, freshKey.keyId);
    expect(served.version, 2);
    expect(
        restarted.sent.where((s) => s.$2 == AppPayloadType.infoKey), isEmpty);
    expect(await member.service.refresh(private), isA<InfoAccepted>());
    expect(
        member.service.shown(infoKindChannel, _private)?.topic, 'Members only');
    expect(
        () => CommunityInfoCodec(bindings).open(
            key: oldKey.key!,
            servedKeyId: served.keyId,
            servedVersion: served.version,
            kind: infoKindChannel,
            subjectId: _private,
            blob: served.blob),
        throwsA(isA<ProfileRecordException>()));
    for (final excluded in [removed, outsider]) {
      final keys = await excluded.store.loadCommunityInfoEvents(
          CommunityInfoEventKind.key, infoKindChannel, _private);
      expect(keys.map((k) => k.keyId), isNot(contains(freshKey.keyId)));
    }
  }, skip: skip);

  test('rotation refreshes a newer remote edit before re-sealing', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service
        .publish(community, (r) => named('Before', r), mint: true);
    final other = device('admin', {_shared}, admin: true);
    final home = admin.service.homeOf(community)!;
    await net.deliverAs(
        other,
        'dev_laptop',
        _shared,
        AppPayloadType.infoKeyRequest,
        infoKeyRequestBody(
            subjectKind: infoKindCommunity, subjectId: _community));
    await admin.service.answerRequests(home, _community);
    await other.service.refresh(community);
    await other.service.publish(community, (r) => named('Remote edit', r));
    expect(admin.service.shown(infoKindCommunity, _community)?.revision, 1);
    await admin.service.markRotationDue(home, _community);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(admin.service.shown(infoKindCommunity, _community)?.name,
        'Remote edit');
    expect(server.records[community.key]?.version, 3);
  }, skip: skip);

  for (final duringPut in [false, true]) {
    test(
        'rotation never overwrites an edit racing its ${duringPut ? 'PUT' : 'GET'}',
        () async {
      final admin = device('admin', {_shared}, admin: true);
      await admin.service
          .publish(community, (r) => named('Before', r), mint: true);
      final other = device('admin', {_shared}, admin: true);
      final home = admin.service.homeOf(community)!;
      await net.deliverAs(
          other,
          'dev_laptop',
          _shared,
          AppPayloadType.infoKeyRequest,
          infoKeyRequestBody(
              subjectKind: infoKindCommunity, subjectId: _community));
      await admin.service.answerRequests(home, _community);
      await other.service.refresh(community);
      await admin.service.markRotationDue(home, _community);
      Future<void> remoteEdit() async {
        await other.service.publish(community, (r) => named('Racing edit', r));
      }

      if (duringPut) {
        // Force an actual If-Match failure after reading the snapshot version.
        server.beforePut = remoteEdit;
      } else {
        // First GET refreshes the snapshot; the next GET races a remote edit.
        server.beforeGet = () async {
          server.beforeGet = remoteEdit;
        };
      }
      expect(await admin.service.runRotations((_, __) => [community]), 0);
      expect(server.records[community.key]?.version, 2);
      expect(await admin.service.dueRotations(), {'community|$_community'});
      now = now.add(const Duration(minutes: 2));
      expect(await admin.service.runRotations((_, __) => [community]), 1);
      expect(admin.service.shown(infoKindCommunity, _community)?.name,
          'Racing edit');
    }, skip: skip);
  }

  test('rotation retains its mark when a newer record cannot be verified',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service
        .publish(community, (r) => named('Before', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final old = server.records[community.key]!;
    server.records[community.key] = ServedCommunityInfo(
        subjectKind: old.subjectKind,
        subjectId: old.subjectId,
        version: 2,
        keyId: old.keyId,
        blob: old.blob);
    await admin.service.markRotationDue(home, _community);
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(server.puts, 1);
    expect(await admin.service.dueRotations(), {'community|$_community'});
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoKey), isEmpty);
  }, skip: skip);

  test('rotation does not skip an existing record missing from its cache',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final other = device('admin', {_shared}, admin: true);
    final home = other.service.homeOf(community)!;
    await other.service.markRotationDue(home, _community);
    expect(await other.service.runRotations((_, __) => [community]), 0);
    expect(await other.service.dueRotations(), {'community|$_community'});
    expect(server.puts, 1);
    expect(other.sent.where((s) => s.$2 == AppPayloadType.infoKey), isEmpty);
  }, skip: skip);

  test('rotation retains a cached record whose key cannot be loaded', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final other = device('admin', {_shared}, admin: true);
    await other.store.saveAcceptedCommunityInfo((await admin.store
        .loadAcceptedCommunityInfo(infoKindCommunity, _community))!);
    final home = other.service.homeOf(community)!;
    await other.service.markRotationDue(home, _community);
    expect(await other.service.runRotations((_, __) => [community]), 0);
    expect(await other.service.dueRotations(), {'community|$_community'});
    expect(server.puts, 1);
    expect(other.service.shown(infoKindCommunity, _community), isNull);
  }, skip: skip);

  test('a real If-Match conflict retries without dropping the edit', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    server.beforePut = () async {
      final old = server.records[community.key]!;
      server.records[community.key] = ServedCommunityInfo(
          subjectKind: old.subjectKind,
          subjectId: old.subjectId,
          version: 2,
          keyId: old.keyId,
          blob: old.blob);
    };
    await admin.service.publish(community, (r) => named('Retried edit', r));
    expect(server.records[community.key]?.version, 3);
    expect(server.puts, 2);
    expect(admin.service.shown(infoKindCommunity, _community)?.name,
        'Retried edit');
  }, skip: skip);

  test('edits wait for removal holds and pending rotations', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    net.held = true;
    await expectLater(admin.service.publish(community, (r) => named('Held', r)),
        throwsA(isA<InfoRotationPending>()));
    expect(server.puts, 1);
    final home = admin.service.homeOf(community)!;
    await admin.service.markRotationDue(home, _community);
    net.held = false;
    await expectLater(admin.service.publish(community, (r) => named('Due', r)),
        throwsA(isA<InfoRotationPending>()));
    expect(server.puts, 1);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    await admin.service.publish(community, (r) => named('After', r));
    expect(server.puts, 3);
    expect(admin.service.shown(infoKindCommunity, _community)?.name, 'After');
  }, skip: skip);

  test('a removal starting during the version read prevents the upload',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    server.beforeGet = () => admin.service.markRotationDue(home, _community);
    await expectLater(admin.service.publish(community, (r) => named('Late', r)),
        throwsA(isA<InfoRotationPending>()));
    expect(server.puts, 1);
  }, skip: skip);

  test('an edit selects a remote rotation delivered during its version read',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final fresh = List<int>.filled(32, 29);
    server.beforeGet = () async {
      await net.deliverAs(
          admin,
          'dev_admin_other',
          _shared,
          AppPayloadType.infoKey,
          infoKeyBody(
              subjectKind: infoKindCommunity,
              subjectId: _community,
              key: fresh));
    };
    await admin.service.publish(community, (r) => named('After rotation', r));
    final served = server.records[community.key]!;
    expect(served.keyId, ProfileRecordCodec.keyId(fresh));
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(member.service.shown(infoKindCommunity, _community)?.name,
        'After rotation');
  }, skip: skip);

  test('rotation preserves an edit whose upload was already in flight',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final uploading = Completer<void>();
    final resume = Completer<void>();
    server.beforePut = () async {
      uploading.complete();
      await resume.future;
    };
    final edit = admin.service.publish(community, (r) => named('Edited', r));
    await uploading.future;
    await admin.service.markRotationDue(home, _community);
    final rotation = admin.service.runRotations((_, __) => [community]);
    resume.complete();
    await edit;
    expect(await rotation, 1);
    expect(server.puts, 3);
    expect(admin.service.shown(infoKindCommunity, _community)?.name, 'Edited');
    final member = device('member', {_shared});
    await member.service.requestKey(home);
    await admin.service.answerRequests(home, _community);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(member.service.shown(infoKindCommunity, _community)?.name, 'Edited');
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
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    await member.service.refresh(community);
    await admin.service
        .answerRequests(admin.service.homeOf(community)!, _community);
    expect(await member.service.refresh(community), isA<InfoKept>());
    expect(member.service.shown(infoKindCommunity, _community), isNull);
  }, skip: skip);

  test('no key and no right to make one: ask, never mint a parallel key',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final second = device('member', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    await expectLater(
        second.service.publish(community, (r) => named('Mine', r)),
        throwsA(isA<InfoKeyMissing>()));
    expect(second.sent.single.$2, AppPayloadType.infoKeyRequest);
    expect(
        (await second.store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, infoKindCommunity, _community))
            .where((k) => k.senderAccountId == 'acct_member'),
        isEmpty);
    expect(server.records['community|$_community']!.version, 1);
  }, skip: skip);

  test('an old key delivered again never becomes current', () async {
    final admin = device('admin', {_shared}, admin: true);
    final verifiedAdmins = GovernanceState(
        rev: 1,
        owner: 'acct_admin',
        ownerRev: 1,
        admins: const {'acct_member': 1},
        joined: const {'acct_admin': 0, 'acct_member': 1});
    final other =
        device('member', {_shared}, admin: true, verified: verifiedAdmins);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final k1 = (await admin.service.currentKey(home, _community))!;
    // The other admin gets K1, then the owner rotates to K2.
    await other.service.requestKey(home);
    await admin.service.answerRequests(home, _community);
    await admin.service.markRotationDue(home, _community);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    final k2 = (await admin.service.currentKey(home, _community))!;
    expect(k2.keyId, isNot(k1.keyId));
    // The second admin re-sends K1 (it answered before seeing K2).
    await net.deliver(
        other,
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'community', subjectId: _community, key: k1.key!));
    expect((await admin.service.currentKey(home, _community))!.keyId, k2.keyId);
  }, skip: skip);

  test('retired key replay after eviction and service restart cannot win',
      () async {
    final verifiedAdmins = GovernanceState(
        rev: 1,
        owner: 'acct_admin',
        ownerRev: 1,
        admins: const {'acct_member': 1},
        joined: const {'acct_admin': 0, 'acct_member': 1});
    final admin =
        device('admin', {_shared}, admin: true, verified: verifiedAdmins);
    final stale =
        device('member', {_shared}, admin: true, verified: verifiedAdmins);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final retired = (await admin.service.currentKey(home, _community))!;
    // Evict K0 from both senders, including the accepted-record protection.
    for (var i = 0; i < 7; i++) {
      await admin.service.markRotationDue(home, _community);
      expect(await admin.service.runRotations((_, __) => [community]), 1);
    }
    final latest = (await admin.service.currentKey(home, _community))!;
    final rows = await admin.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, infoKindCommunity, _community);
    expect(rows.firstWhere((k) => k.keyId == retired.keyId).key, isNull);
    final restarted = device('admin', {_shared},
        admin: true, verified: verifiedAdmins, store: admin.store);
    await net.deliver(
        stale,
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'community',
            subjectId: _community,
            key: retired.key!));
    expect((await restarted.service.currentKey(home, _community))!.keyId,
        latest.keyId);
    await restarted.service
        .publish(community, (r) => named('After removal', r));
    expect(server.records['community|$_community']!.keyId, latest.keyId);
  }, skip: skip);

  test('rotation marks survive an unknown topology and a blocked pass',
      () async {
    final admin = device('admin', {_shared, _privateConv}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    // A private channel mark while that channel is not loaded yet stays,
    // and never falls back to the community key.
    final topology = admin.service.topology as _Topology;
    topology.privateKnown = false;
    await admin.service.markRotationDue(
        const InfoKeyHome(
            keySubjectKind: infoKindChannel,
            keySubjectId: 'chan_00000000000000000000000000000003',
            conversationId: _privateConv),
        _community);
    await admin.service.markRotationDue(home, _community);
    // Held: nothing runs, nothing is dropped.
    net.held = true;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(await admin.service.dueRotations(),
        {'community|$_community', 'channel|$_private'});
    net.held = false;
    final keysBefore = (await admin.store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, infoKindCommunity, _community))
        .length;
    // A new mark made while a pass runs survives that pass.
    final pass = admin.service.runRotations((_, __) {
      unawaitedMark(admin.service, home);
      return [community];
    });
    expect(await pass, 0);
    expect(
        await admin.service.dueRotations(), contains('community|$_community'));
    expect(await admin.service.dueRotations(), contains('channel|$_private'));
    // A superseded pass mints no key, nor does the unplaced channel.
    expect(
        (await admin.store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, infoKindCommunity, _community))
            .length,
        keysBefore);
    // Once the community is known gone, its marks go.
    topology.gone = true;
    await admin.service.runRotations((_, __) => []);
    expect(await admin.service.dueRotations(), isEmpty);
  }, skip: skip);

  test('a failed re-seal reuses its key and backs off', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await admin.service.markRotationDue(home, _community);
    server.failPuts = true;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    final sentKeys =
        admin.sent.where((s) => s.$2 == AppPayloadType.infoKey).length;
    // Backing off: an immediate retry does nothing.
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoKey).length,
        sentKeys);
    // Later, the retry seals under the same key and sends no new one.
    server.failPuts = false;
    now = now.add(const Duration(minutes: 2));
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(admin.sent.where((s) => s.$2 == AppPayloadType.infoKey).length,
        sentKeys);
    expect(await admin.service.dueRotations(), isEmpty);
  }, skip: skip);

  test('an own record whose announcement could not go out is announced later',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    net.held = false;
    net.refuse = true;
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    net.refuse = false;
    expect(admin.sent, isEmpty);
    await admin.service.refresh(community);
    expect(admin.sent.single.$2, AppPayloadType.infoUpdate);
    // Once announced, never again.
    await admin.service.refresh(community);
    expect(admin.sent, hasLength(1));
  }, skip: skip);

  test("an account's own other device is answered", () async {
    final phone = device('admin', {_shared}, admin: true);
    await phone.service.publish(community, (r) => named('Club', r), mint: true);
    final laptop = _Device('admin', MemoryLocalStore(), {_shared});
    laptop.service = CommunityInfoService(
      store: laptop.store,
      api: server,
      send: (c, t, b) => net.deliverAs(laptop, 'dev_laptop', c, t, b),
      topology: _Topology(true, net),
      codec: CommunityInfoCodec(bindings),
      policyFor: (_) => GovernanceInfoEditPolicy(roles),
      accountId: 'acct_admin',
      deviceId: 'dev_laptop',
      answerDelay: () => Duration.zero,
    );
    net.devices.add(laptop);
    expect(await laptop.service.refresh(community), isA<InfoNeedsKey>());
    expect(
        await phone.service
            .answerRequests(phone.service.homeOf(community)!, _community),
        1);
    expect(await laptop.service.refresh(community), isA<InfoAccepted>());
  }, skip: skip);

  test('unknown and non-admin roles keep rotations due for later promotion',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final topology = admin.service.topology as _Topology;
    await admin.service.markRotationDue(home, _community);
    topology.admin = null;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(await admin.service.dueRotations(), {'community|$_community'});
    topology.admin = true;
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    await admin.service.markRotationDue(home, _community);
    topology.admin = false;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(await admin.service.dueRotations(), {'community|$_community'});
    topology.admin = true;
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(await admin.service.dueRotations(), isEmpty);
  }, skip: skip);

  test('a device repeating its request is answered once an hour', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    Future<int> askAndCount() async {
      await net.deliver(member, _shared, AppPayloadType.infoKeyRequest,
          infoKeyRequestBody(subjectKind: 'community', subjectId: _community));
      return admin.service.answerRequests(home, _community);
    }

    expect(await askAndCount(), 1);
    expect(await askAndCount(), 0);
    expect(await askAndCount(), 0);
    now = now.add(const Duration(hours: 1));
    expect(await askAndCount(), 1);
  }, skip: skip);

  test('a request that was not queued can be retried immediately', () async {
    final member = device('member', {_shared});
    final home = member.service.homeOf(community)!;
    net.refuse = true;
    expect(await member.service.requestKey(home), isFalse);
    net.refuse = false;
    expect(await member.service.requestKey(home), isTrue);
    expect(await member.service.requestKey(home), isFalse);
    expect(member.sent, hasLength(1));
  }, skip: skip);

  test('a failed answer is retried without waiting an hour', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    net.refuse = true;
    expect(await admin.service.answerRequests(home, _community), 0);
    net.refuse = false;
    expect(await admin.service.answerRequests(home, _community), 1);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
  }, skip: skip);

  test('overlapping answer passes send one key', () async {
    final admin = device('admin', {_shared}, admin: true);
    final member = device('member', {_shared});
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    await Future.wait([
      admin.service.answerRequests(home, _community),
      admin.service.answerRequests(home, _community),
    ]);
    expect(
        admin.sent.where((s) => s.$2 == AppPayloadType.infoKey), hasLength(1));
  }, skip: skip);

  test('a slow cache read never replaces a newer displayed edit', () async {
    final store = _DelayedCacheStore();
    final admin = device('admin', {_shared}, admin: true, store: store);
    await admin.service
        .publish(community, (r) => named('Before', r), mint: true);
    store.delayNextRead = true;
    final loading = admin.service.loadAccepted(community);
    await store.reading.future;
    await admin.service.publish(community, (r) => named('After', r));
    store.resume.complete();
    await loading;
    expect(admin.service.shown(infoKindCommunity, _community)?.name, 'After');
    expect(admin.service.shown(infoKindCommunity, _community)?.revision, 2);
  }, skip: skip);

  test('cached records require a key from the current owning group', () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final otherHome =
        device('admin', {'conv_other'}, admin: true, store: admin.store);
    (otherHome.service.topology as _Topology).sharedConversation = 'conv_other';
    await otherHome.service.loadAccepted(community);
    expect(otherHome.service.shown(infoKindCommunity, _community), isNull);
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
