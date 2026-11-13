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

/// A store whose key-event reads for one subject kind fail while [failKind]
/// is set: a broken read in one rotation mark.
class _FailingKeyReadStore extends MemoryLocalStore {
  String? failKind;

  @override
  Future<List<CommunityInfoEvent>> loadCommunityInfoEvents(
      CommunityInfoEventKind kind, String subjectKind, String subjectId) async {
    if (failKind == subjectKind) throw StateError('store read failed');
    return super.loadCommunityInfoEvents(kind, subjectKind, subjectId);
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

  /// Each conversation's current MLS epoch: what a send is encrypted in and
  /// what a receiver authenticates on decryption.
  final epochs = <String, int>{};
  var held = false;
  var refuse = false;
  AppPayloadType? refuseType;
  Future<void> Function(AppPayloadType)? afterDeliver;

  Future<bool> deliver(_Device from, String conversation, AppPayloadType type,
          Map<String, Object?> body) =>
      deliverAs(from, 'dev_${from.name}', conversation, type, body);

  /// [epoch] overrides the conversation's current one: a message delivered
  /// late keeps the epoch it was encrypted in.
  Future<bool> deliverAs(_Device from, String device, String conversation,
      AppPayloadType type, Map<String, Object?> body,
      {int? epoch}) async {
    if (held ||
        refuse ||
        refuseType == type ||
        !from.members.contains(conversation)) {
      return false;
    }
    from.sent.add((conversation, type, body));
    final payload = DecryptedAppPayload(type: type, actionId: 'a', body: body);
    final at = epoch ?? epochs[conversation] ?? 0;
    // The sender keeps its own copy (outgoing transition).
    await from.store.recordOwnCommunityInfoEvents([
      communityInfoEventFor(payload,
          conversationId: conversation,
          senderAccountId: 'acct_${from.name}',
          senderDeviceId: device,
          epoch: at)
    ]);
    for (final d in devices) {
      if (d == from || !d.members.contains(conversation)) continue;
      await d.store.recordOwnCommunityInfoEvents([
        communityInfoEventFor(payload,
            conversationId: conversation,
            senderAccountId: 'acct_${from.name}',
            senderDeviceId: device,
            epoch: at)
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

/// Moves the clock past every deferred remote-removal turn (at most
/// base + 8 slots + jitter, about 4.5 minutes).
void pastTurn() => now = now.add(const Duration(minutes: 10));

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
      bool noRecord = false,
      String? deviceId,
      LocalStore? store,
      Duration Function()? answerDelay,
      bool roster = false}) {
    final d = _Device(name, store ?? MemoryLocalStore(), members);
    d.service = CommunityInfoService(
      store: d.store,
      api: server,
      send: (c, t, b) => deviceId == null
          ? net.deliver(d, c, t, b)
          : net.deliverAs(d, deviceId, c, t, b),
      topology: _Topology(admin, net),
      codec: CommunityInfoCodec(bindings,
          random: Random(name.hashCode + net.devices.length)),
      policyFor: (_) => GovernanceInfoEditPolicy(verified ?? roles),
      verifiedRolesOf: noRecord ? null : (_) => verified ?? roles,
      // With [roster], the group's members are the accounts of the devices
      // in it, as each device's MLS tree would say.
      membersOf: roster
          ? (conversation) => {
                for (final other in net.devices)
                  if (other.members.contains(conversation))
                    other.service.accountId,
              }
          : null,
      accountId: 'acct_$name',
      deviceId: deviceId ?? 'dev_$name',
      answerDelay: answerDelay ?? () => Duration.zero,
      clock: () => now,
      epochOf: (conversation) async => net.epochs[conversation] ?? 0,
    );
    net.devices.add(d);
    return d;
  }

  // A merged removal commit: the group moves to [epoch] and the device's
  // removal watermark (written with the MLS state) records it.
  Future<void> removedAt(
      LocalStore store, String conversation, int epoch) async {
    if ((net.epochs[conversation] ?? 0) < epoch)
      net.epochs[conversation] = epoch;
    await store.saveSetting(
        communityInfoRemovalSetting(conversation), '$epoch');
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

  for (final private in [false, true]) {
    test(
        'remote removal rotates ${private ? 'private' : 'shared'} info '
        'after restart and blocks edits before observation', () async {
      final admin = device('admin', {_shared, _privateConv}, admin: true);
      final subject = private
          ? InfoSubject(infoKindChannel, _private, _community)
          : community;
      CommunityInfoRecord record(int r) => private
          ? CommunityInfoRecord(
              kind: subject.kind,
              subjectId: subject.id,
              revision: r,
              name: 'Secret',
              privatePlace: const InfoPrivatePlace(position: 0))
          : named('Club', r);
      await admin.service.publish(subject, record, mint: true);
      final old = server.records[subject.key]!.keyId;
      final home = admin.service.homeOf(subject)!;
      // Written by the committed MLS removal, without a local remove request
      // or a pending-changes response.
      await removedAt(admin.store, home.conversationId, 2);
      final restarted = device('admin', {_shared, _privateConv},
          admin: true, store: admin.store);
      await expectLater(restarted.service.publish(subject, record),
          throwsA(isA<InfoRotationPending>()));
      expect(server.puts, 1);
      await restarted.service.observeRemoval(home, _community);
      // A removal this device did not make waits its turn first.
      expect(await restarted.service.runRotations((_, __) => [subject]), 0);
      pastTurn();
      expect(await restarted.service.runRotations((_, __) => [subject]), 1);
      expect(server.records[subject.key]!.keyId, isNot(old));
      expect(restarted.sent.every((e) => e.$1 == home.conversationId), isTrue);
      expect(await restarted.service.dueRotations(), isEmpty);
      final again = device('admin', {_shared, _privateConv},
          admin: true, store: admin.store);
      await again.service.observeRemoval(home, _community);
      expect(await again.service.runRotations((_, __) => [subject]), 0);
      await again.service.publish(subject, record);
      expect(server.puts, 3);
    }, skip: skip);
  }

  test('rotation completion cannot acknowledge a different key home', () async {
    final admin = device('admin', {_privateConv}, admin: true);
    // Even a server aliasing two homes to one conversation cannot let one
    // completed key rotation suppress the other's obligation.
    (admin.service.topology as _Topology).sharedConversation = _privateConv;
    final private = InfoSubject(infoKindChannel, _private, _community);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    await admin.service.publish(
        private,
        (r) => CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: _private,
            revision: r,
            name: 'Secret',
            privatePlace: const InfoPrivatePlace(position: 0)),
        mint: true);
    final oldPrivate = server.records[private.key]!.keyId;
    await removedAt(admin.store, _privateConv, 2);
    await admin.service
        .observeRemoval(admin.service.homeOf(community)!, _community);
    pastTurn();
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    await admin.service
        .observeRemoval(admin.service.homeOf(private)!, _community);
    pastTurn();
    expect(await admin.service.runRotations((_, __) => [private]), 1);
    expect(server.records[private.key]!.keyId, isNot(oldPrivate));
  }, skip: skip);

  test('remote removal during delivery invalidates the in-flight rotation',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await removedAt(admin.store, _shared, 2);
    await admin.service.observeRemoval(home, _community);
    var delivered = false;
    net.afterDeliver = (type) async {
      if (type == AppPayloadType.infoKey && !delivered) {
        delivered = true;
        await removedAt(admin.store, _shared, 3);
      }
    };
    pastTurn();
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    expect(server.puts, 1);
    await admin.service.observeRemoval(home, _community);
    pastTurn();
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    final keys =
        admin.sent.where((e) => e.$2 == AppPayloadType.infoKey).toList();
    expect(keys, hasLength(2));
    expect(keys[0].$3['key_id'], isNot(keys[1].$3['key_id']));
    expect(server.records[community.key]!.keyId, keys[1].$3['key_id']);
  }, skip: skip);

  test('remote removal stays pending on a non-admin and survives promotion',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await removedAt(admin.store, _shared, 2);
    // The same account and store, while the verified record made it a
    // plain member (the server's word "admin" does not count).
    final member = device('admin', {_shared},
        admin: true,
        store: admin.store,
        verified: GovernanceState(
            rev: 2,
            owner: 'acct_other',
            ownerRev: 2,
            joined: const {'acct_admin': 0, 'acct_other': 1}));
    await member.service.observeRemoval(home, _community);
    pastTurn();
    expect(await member.service.runRotations((_, __) => [community]), 0);
    expect(await member.service.dueRotations(), {community.key});
    await expectLater(
        member.service.publish(community, (r) => named('Edit', r)),
        throwsA(isA<InfoRotationPending>()));
    final promoted =
        device('admin', {_shared}, admin: true, store: admin.store);
    await promoted.service.observeRemoval(home, _community);
    pastTurn();
    expect(await promoted.service.runRotations((_, __) => [community]), 1);
  }, skip: skip);

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

  test('a removal during a key answer cancels announcements and permits retry',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final member = device('member', {_shared});
    final home = admin.service.homeOf(community)!;
    await member.service.requestKey(home);
    final before = admin.sent.length;
    net.afterDeliver = (type) async {
      if (type == AppPayloadType.infoKey) {
        net.afterDeliver = null;
        await admin.service.markRotationDue(home, _community);
      }
    };
    expect(await admin.service.answerRequests(home, _community), 0);
    expect(admin.sent.skip(before).map((s) => s.$2), [AppPayloadType.infoKey]);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    // No hourly allowance was consumed by the cancelled answer. This retry
    // re-announces the rotated record even though rotation delivered its key.
    final afterRotation = admin.sent.length;
    await admin.service.answerRequests(home, _community);
    expect(admin.sent.skip(afterRotation).map((s) => s.$2),
        contains(AppPayloadType.infoUpdate));
    expect(await member.service.refresh(community), isA<InfoAccepted>());
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

  for (final rotate in [false, true]) {
    test(
        'a relabelled private channel cannot leak through ${rotate ? 'rotation' : 'editing'}',
        () async {
      final admin = device('admin', {_shared, _privateConv}, admin: true);
      const subject = InfoSubject(
          infoKindChannel,
          'chan_00000000000000000000000000000003',
          'comm_00000000000000000000000000000001');
      await admin.service
          .publish(community, (r) => named('Club', r), mint: true);
      await admin.service.publish(
          subject,
          (r) => CommunityInfoRecord(
              kind: subject.kind,
              subjectId: subject.id,
              revision: r,
              name: 'Private name',
              topic: 'Private topic',
              privatePlace: const InfoPrivatePlace(position: 0)),
          mint: true);
      final original = server.records[subject.key]!;
      final puts = server.puts;
      admin.sent.clear();
      // The server now reports this private channel as an open channel.
      (admin.service.topology as _Topology).privateKnown = false;
      if (rotate) {
        final home = admin.service.homeOf(community)!;
        await admin.service.markRotationDue(home, _community);
        expect(await admin.service.runRotations((_, __) => [subject]), 0);
        expect(await admin.service.dueRotations(), {'community|$_community'});
      } else {
        await expectLater(
            admin.service.publish(
                subject,
                (r) => CommunityInfoRecord(
                    kind: subject.kind,
                    subjectId: subject.id,
                    revision: r,
                    name: 'Edited name',
                    topic:
                        admin.service.shown(subject.kind, subject.id)!.topic),
                expectedRevision: original.version),
            throwsA(isA<InfoKeyMissing>()));
      }
      expect(server.puts, puts);
      expect(server.records[subject.key], same(original));
      expect(await admin.service.healAnnouncement(subject), isFalse);
      expect(
          admin.sent.where((e) => e.$2 == AppPayloadType.infoUpdate), isEmpty);
    }, skip: skip);
  }

  test(
      'a C3 conversion moves a private channel\'s record to the community '
      'key explicitly; a relabel alone still cannot', () async {
    final admin = device('admin', {_shared, _privateConv}, admin: true);
    const subject = InfoSubject(
        infoKindChannel,
        'chan_00000000000000000000000000000003',
        'comm_00000000000000000000000000000001');
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    CommunityInfoRecord record(int r) => CommunityInfoRecord(
        kind: subject.kind,
        subjectId: subject.id,
        revision: r,
        name: 'Was private',
        topic: 'Kept topic');
    await admin.service.publish(
        subject,
        (r) => CommunityInfoRecord(
            kind: subject.kind,
            subjectId: subject.id,
            revision: r,
            name: 'Was private',
            topic: 'Kept topic',
            privatePlace: const InfoPrivatePlace(position: 0)),
        mint: true);
    final privateKey = server.records[subject.key]!.keyId;
    (admin.service.topology as _Topology).privateKnown = false;
    await expectLater(
        admin.service.publish(subject, record, expectedRevision: 1),
        throwsA(isA<InfoKeyMissing>()));
    await admin.service
        .publish(subject, record, expectedRevision: 1, rehome: true);
    final moved = server.records[subject.key]!;
    expect(moved.version, 2);
    expect(moved.keyId, isNot(privateKey));
    expect(moved.keyId, server.records['community|$_community']!.keyId);
    expect(admin.service.shown(subject.kind, subject.id)!.topic, 'Kept topic');
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

  // Freshness is the authenticated MLS epoch a key was sent in (docs/crypto.md,
  // C3 key freshness), never the order this device first saw it.
  Future<
      ({
        _Device admin,
        _Device member,
        InfoKeyHome home,
        CommunityInfoEvent retired
      })> rotatedPastDelayedKey({bool rotate = true}) async {
    net.epochs[_shared] = 1;
    final admin = device('admin', {_shared}, admin: true);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    final retired = (await admin.service.currentKey(home, _community))!;
    expect(retired.epoch, 1);
    // The member was in the group, but the message carrying K1 is delayed
    // (the server held it, or it sat behind a paused conversation).
    final member = device('member', {_shared});
    // A removal commit moves the group to epoch 2; both devices merged it.
    net.epochs[_shared] = 2;
    for (final d in [admin, member]) {
      await removedAt(d.store, _shared, 2);
    }
    if (rotate) {
      await admin.service.observeRemoval(home, _community);
      pastTurn();
      expect(await admin.service.runRotations((_, __) => [community]), 1);
    }
    return (admin: admin, member: member, home: home, retired: retired);
  }

  test('a retired key first delivered after its replacement never wins',
      () async {
    final (:admin, :member, :home, :retired) = await rotatedPastDelayedKey();
    final fresh = (await member.service.currentKey(home, _community))!;
    expect(fresh.keyId, isNot(retired.keyId));
    expect(fresh.epoch, 2);
    // The delayed original finally arrives, from the authenticated owner, in
    // the epoch it was encrypted in. First local arrival would make it win.
    await net.deliverAs(
        admin,
        'dev_admin',
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: retired.key!),
        epoch: 1);
    expect((await member.service.currentKey(home, _community))!.keyId,
        fresh.keyId);
    expect(
        (await admin.service.currentKey(home, _community))!.keyId, fresh.keyId);
  }, skip: skip);

  test('a key from before the last removal is never current, even alone',
      () async {
    final (:admin, :member, :home, :retired) =
        await rotatedPastDelayedKey(rotate: false);
    await net.deliverAs(
        admin,
        'dev_admin',
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: retired.key!),
        epoch: 1);
    // The removed member knows K1: fail closed until a rotated key arrives.
    expect(await member.service.currentKey(home, _community), isNull);
    expect(await admin.service.currentKey(home, _community), isNull);
  }, skip: skip);

  test('an untrusted copy at an old epoch cannot retire the current key',
      () async {
    final (:admin, :member, :home, :retired) = await rotatedPastDelayedKey();
    final fresh = (await member.service.currentKey(home, _community))!;
    // A member who kept epoch-1 secrets re-sends K2 there, and K1 at the
    // current epoch. Only owner/admin deliveries count.
    await net.deliverAs(
        member,
        'dev_member',
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: fresh.key!),
        epoch: 1);
    await net.deliverAs(
        member,
        'dev_member',
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: infoKindCommunity,
            subjectId: _community,
            key: retired.key!),
        epoch: 3);
    expect(
        (await admin.service.currentKey(home, _community))!.keyId, fresh.keyId);
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

  test('a failing mark backs off without stopping the marks after it',
      () async {
    final store = _FailingKeyReadStore();
    final admin =
        device('admin', {_shared, _privateConv}, admin: true, store: store);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    await admin.service
        .markRotationDue(admin.service.homeOf(community)!, _community);
    await admin.service.markRotationDue(
        const InfoKeyHome(
            keySubjectKind: infoKindChannel,
            keySubjectId: 'chan_00000000000000000000000000000003',
            conversationId: _privateConv),
        _community);
    // The community mark comes first and its key read throws.
    store.failKind = infoKindCommunity;
    expect(await admin.service.runRotations((_, __) => []), 1);
    expect(await admin.service.dueRotations(), {'community|$_community'});
    // The failure backs off: a retry at once does nothing even when the
    // read works again.
    store.failKind = null;
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    now = now.add(const Duration(minutes: 2));
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    expect(await admin.service.dueRotations(), isEmpty);
  }, skip: skip);

  test('a non-admin whose completion read fails keeps its mark and backs off',
      () async {
    final admin = device('admin', {_shared}, admin: true);
    final store = _FailingKeyReadStore();
    final member = device('member', {_shared}, store: store);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await member.service.markRotationDue(home, _community);
    await admin.service.markRotationDue(home, _community);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
    store.failKind = infoKindCommunity;
    // The throw stays inside the pass.
    expect(await member.service.runRotations((_, __) => [community]), 0);
    store.failKind = null;
    expect(await member.service.runRotations((_, __) => [community]), 0);
    expect(await member.service.dueRotations(), {'community|$_community'});
    now = now.add(const Duration(minutes: 2));
    expect(await member.service.runRotations((_, __) => [community]), 1);
    expect(await member.service.dueRotations(), isEmpty);
  }, skip: skip);

  test('answerers follow the verified record, not the server role', () async {
    final verified = GovernanceState(
      rev: 2,
      owner: 'acct_admin',
      ownerRev: 2,
      admins: const {'acct_boss': 2},
      moderators: const {'acct_mod'},
      joined: const {
        'acct_admin': 0,
        'acct_member': 1,
        'acct_mod': 2,
        'acct_boss': 3,
      },
    );
    final admin = device('admin', {_shared}, admin: true, verified: verified);
    // The server calls the moderator an admin and the admin a member.
    final mod = device('mod', {_shared}, admin: true, verified: verified);
    final boss = device('boss', {_shared}, admin: false, verified: verified);
    // The member joins after the key went round.
    final member = device('member', {}, verified: verified);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    expect(await mod.service.refresh(community), isA<InfoNeedsKey>());
    expect(await boss.service.refresh(community), isA<InfoNeedsKey>());
    expect(await admin.service.answerRequests(home, _community), 1);
    expect(await mod.service.refresh(community), isA<InfoAccepted>());
    expect(await boss.service.refresh(community), isA<InfoAccepted>());
    // Both now hold the key; the member joins and asks.
    member.members.add(_shared);
    expect(await member.service.requestKey(home), isTrue);
    expect(await mod.service.answerRequests(home, _community), 0);
    expect(mod.sent.where((s) => s.$2 == AppPayloadType.infoKey), isEmpty);
    expect(await boss.service.answerRequests(home, _community), 1);
    expect(
        boss.sent.where((s) => s.$2 == AppPayloadType.infoKey), hasLength(1));
  }, skip: skip);

  test(
      'a private channel mark with no verified owner, admin or moderator in '
      'its group is reported', () async {
    final verified = GovernanceState(
      rev: 2,
      owner: 'acct_admin',
      ownerRev: 2,
      admins: const {'acct_boss': 2},
      moderators: const {'acct_mod'},
      joined: const {'acct_admin': 0, 'acct_mod': 1, 'acct_boss': 2},
    );
    final member =
        device('member', {_shared, _privateConv}, verified: verified);
    const home = InfoKeyHome(
        keySubjectKind: infoKindChannel,
        keySubjectId: 'chan_00000000000000000000000000000003',
        conversationId: _privateConv);
    await member.service.markRotationDue(home, _community);
    await member.service
        .markRotationDue(member.service.homeOf(community)!, _community);
    // Only members are left in the private group: nobody can renew it.
    expect(
        await member.service
            .rotationsWithoutRotator((_) => {'acct_member', 'acct_other'}),
        {_privateConv});
    // A moderator in the group can (no owner or admin is a member), and so
    // can an admin or the owner.
    expect(
        await member.service
            .rotationsWithoutRotator((_) => {'acct_mod', 'acct_member'}),
        isEmpty);
    expect(
        await member.service
            .rotationsWithoutRotator((_) => {'acct_member', 'acct_boss'}),
        isEmpty);
    expect(await member.service.rotationsWithoutRotator((_) => {'acct_admin'}),
        isEmpty);
    // An unknown roster says nothing.
    expect(await member.service.rotationsWithoutRotator((_) => null), isEmpty);
  }, skip: skip);

  test('without a verified record no mark is reported as stuck', () async {
    final member = device('member', {_shared, _privateConv}, noRecord: true);
    await member.service.markRotationDue(
        const InfoKeyHome(
            keySubjectKind: infoKindChannel,
            keySubjectId: 'chan_00000000000000000000000000000003',
            conversationId: _privateConv),
        _community);
    expect(await member.service.rotationsWithoutRotator((_) => {}), isEmpty);
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

  test(
      'without a verified record, unknown and non-admin server roles keep '
      'rotations due for later promotion', () async {
    final admin = device('admin', {_shared}, admin: true, noRecord: true);
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

  // C3 remote removals: who rotates, and only once (design "Remote
  // removals: who rotates"). An owner, two admins, a moderator and a member.
  final staff = GovernanceState(
    rev: 3,
    owner: 'acct_admin',
    ownerRev: 3,
    admins: const {'acct_second': 2, 'acct_third': 3},
    moderators: const {'acct_mod'},
    joined: const {
      'acct_admin': 0,
      'acct_second': 1,
      'acct_third': 1,
      'acct_mod': 1,
      'acct_member': 1,
    },
  );

  /// Every [names] device in the shared group holds the community record
  /// under the owner's key; then a removal (not made by any of them) moves
  /// the group to epoch 2 and each one observes it.
  Future<Map<String, _Device>> staffAfterRemoval(List<String> names) async {
    final devices = <String, _Device>{
      for (final name in names)
        name: device(name, {_shared}, admin: true, verified: staff),
    };
    final owner = devices['admin']!;
    await owner.service.publish(community, (r) => named('Club', r), mint: true);
    final home = owner.service.homeOf(community)!;
    final key = (await owner.service.currentKey(home, _community))!;
    await net.deliver(
        owner,
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'community', subjectId: _community, key: key.key!));
    for (final d in devices.values) {
      await d.service.refresh(community);
      expect(d.service.shown(infoKindCommunity, _community)?.name, 'Club');
      await removedAt(d.store, _shared, 2);
      await d.service.observeRemoval(home, _community);
    }
    return devices;
  }

  int rankOf(String account) => remoteRotationRank(
      rotators: verifiedRotators(staff),
      accountId: account,
      home: const InfoKeyHome(
          keySubjectKind: infoKindCommunity,
          keySubjectId: 'comm_00000000000000000000000000000001',
          conversationId: _shared),
      epoch: 2);

  int keysSent(_Device d) =>
      d.sent.where((e) => e.$2 == AppPayloadType.infoKey).length;

  test(
      'two admins observe a removal: the first in turn rotates, the other '
      'adopts its key without a second key or upload', () async {
    final devices = await staffAfterRemoval(['admin', 'second']);
    final ordered = devices.values.toList()
      ..sort((a, b) =>
          rankOf(a.service.accountId).compareTo(rankOf(b.service.accountId)));
    final first = ordered[0];
    final later = ordered[1];
    final sentBefore = keysSent(later);
    // Past rank 0's turn (base + jitter) but before rank 1's (base + slot).
    now = now.add(remoteRotationBase + remoteRotationJitter);
    expect(await later.service.runRotations((_, __) => [community]), 0);
    expect(await first.service.runRotations((_, __) => [community]), 1);
    final puts = server.puts;
    final rotated = server.records[community.key]!.keyId;
    // The other admin has not reached its turn, yet the delivered key ends
    // its obligation: no key of its own, no upload.
    expect(await later.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(later), sentBefore);
    expect(server.puts, puts);
    expect(await later.service.dueRotations(), isEmpty);
    expect(await later.service.nextDeferredRotation(), isNull);
    // It edits again, under the rotated key.
    await later.service.publish(community, (r) => named('Edited', r));
    expect(server.records[community.key]!.keyId, rotated);
  }, skip: skip);

  test(
      'a moderator removes from a private channel: one admin rotates its '
      'key, the other adopts it', () async {
    final private = InfoSubject(infoKindChannel, _private, _community);
    final devices = <String, _Device>{
      for (final name in ['admin', 'second', 'mod'])
        name: device(name, {_privateConv},
            admin: true, verified: staff, roster: true),
    };
    final owner = devices['admin']!;
    await owner.service.publish(
        private,
        (r) => CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: _private,
            revision: r,
            name: 'Secret',
            privatePlace: const InfoPrivatePlace(position: 0)),
        mint: true);
    final home = owner.service.homeOf(private)!;
    expect(home.conversationId, _privateConv);
    final key = (await owner.service.currentKey(home, _community))!;
    await net.deliver(
        owner,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel', subjectId: _private, key: key.key!));
    // The moderator's removal commit, merged everywhere.
    for (final d in devices.values) {
      await d.service.refresh(private);
      expect(d.service.shown(infoKindChannel, _private)?.name, 'Secret');
      await removedAt(d.store, _privateConv, 2);
      await d.service.observeRemoval(home, _community);
    }
    int rank(_Device d) => remoteRotationRank(
        rotators: verifiedRotators(staff),
        accountId: d.service.accountId,
        home: home,
        epoch: 2);
    final admins = [devices['admin']!, devices['second']!]
      ..sort((a, b) => rank(a).compareTo(rank(b)));
    final before = {for (final d in devices.values) d: keysSent(d)};
    final old = server.records[private.key]!.keyId;
    now = now.add(remoteRotationBase + remoteRotationJitter);
    expect(await devices['mod']!.service.runRotations((_, __) => [private]), 0);
    expect(await admins[1].service.runRotations((_, __) => [private]), 0);
    expect(await admins[0].service.runRotations((_, __) => [private]), 1);
    final rotated = server.records[private.key]!.keyId;
    expect(rotated, isNot(old));
    final puts = server.puts;
    expect(await admins[1].service.runRotations((_, __) => [private]), 1);
    expect(await devices['mod']!.service.runRotations((_, __) => [private]), 1);
    expect(server.puts, puts);
    expect(keysSent(admins[0]), before[admins[0]]! + 1);
    expect(keysSent(admins[1]), before[admins[1]]);
    expect(keysSent(devices['mod']!), before[devices['mod']!]);
    // Every key went only into the private channel's own group.
    for (final d in devices.values) {
      expect(
          d.sent
              .where((e) => e.$2 == AppPayloadType.infoKey)
              .every((e) => e.$1 == _privateConv),
          isTrue);
    }
  }, skip: skip);

  // Owner decision 2026-11-11: with no owner or admin among a private
  // channel's members, its verified moderator members rotate.
  final modStaff = GovernanceState(
    rev: 3,
    owner: 'acct_admin',
    ownerRev: 3,
    admins: const {'acct_second': 2},
    moderators: const {'acct_mod', 'acct_mod2'},
    joined: const {
      'acct_admin': 0,
      'acct_second': 1,
      'acct_mod': 1,
      'acct_mod2': 1,
      'acct_member': 1,
      'acct_late': 2,
    },
  );

  CommunityInfoRecord secret(String name, int r) => CommunityInfoRecord(
      kind: infoKindChannel,
      subjectId: _private,
      revision: r,
      name: name,
      privatePlace: const InfoPrivatePlace(position: 0));

  test(
      'with no owner or admin in a private channel, one moderator member '
      'rotates, the other adopts, and an admin who joins later replaces its '
      'key', () async {
    final private = InfoSubject(infoKindChannel, _private, _community);
    final devices = <String, _Device>{
      for (final name in ['admin', 'mod', 'mod2', 'member'])
        name: device(name, {_privateConv},
            admin: name == 'admin', verified: modStaff, roster: true),
    };
    final owner = devices['admin']!;
    await owner.service
        .publish(private, (r) => secret('Secret', r), mint: true);
    final home = owner.service.homeOf(private)!;
    final key = (await owner.service.currentKey(home, _community))!;
    await net.deliver(
        owner,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel', subjectId: _private, key: key.key!));
    // The owner leaves the channel; the others merge that removal.
    owner.members.remove(_privateConv);
    final mod = devices['mod']!;
    final mod2 = devices['mod2']!;
    final member = devices['member']!;
    for (final d in [mod, mod2, member]) {
      await d.service.refresh(private);
      expect(d.service.shown(infoKindChannel, _private)?.name, 'Secret');
      await removedAt(d.store, _privateConv, 2);
      await d.service.observeRemoval(home, _community);
    }
    // The order runs over the moderators who are members.
    int rank(_Device d) => remoteRotationRank(
        rotators: const {'acct_mod', 'acct_mod2'},
        accountId: d.service.accountId,
        home: home,
        epoch: 2);
    final mods = [mod, mod2]..sort((a, b) => rank(a).compareTo(rank(b)));
    expect(await mods[1].service.nextDeferredRotation(), isNotNull);
    final before = {
      for (final d in [mod, mod2, member]) d: keysSent(d)
    };
    final old = server.records[private.key]!.keyId;
    now = now.add(remoteRotationBase + remoteRotationJitter);
    expect(await member.service.runRotations((_, __) => [private]), 0);
    expect(await mods[1].service.runRotations((_, __) => [private]), 0);
    expect(await mods[0].service.runRotations((_, __) => [private]), 1);
    final rotated = server.records[private.key]!.keyId;
    expect(rotated, isNot(old));
    final puts = server.puts;
    // The other moderator and the member complete on that delivery.
    expect(await mods[1].service.runRotations((_, __) => [private]), 1);
    expect(await member.service.runRotations((_, __) => [private]), 1);
    expect(server.puts, puts);
    expect(keysSent(mods[0]), before[mods[0]]! + 1);
    expect(keysSent(mods[1]), before[mods[1]]);
    expect(keysSent(member), before[member]);
    for (final d in [mod, mod2, member]) {
      expect(await d.service.dueRotations(), isEmpty);
      expect((await d.service.currentKey(home, _community))?.keyId, rotated);
    }
    await member.service.refresh(private);
    expect(
        (await member.store
                .loadAcceptedCommunityInfo(infoKindChannel, _private))
            ?.keyId,
        rotated);
    // An admin joins and is handed the moderator's key, so it can read
    // what is sealed under it. Owner decision B (2026-11-11): it then mints
    // its own key instead of editing under the moderator's.
    final second =
        device('second', {}, admin: true, verified: modStaff, roster: true);
    second.members.add(_privateConv);
    expect(await mods[0].service.deliverAfterAdd(home, _community, [private]),
        isTrue);
    expect(await second.service.refresh(private), isA<InfoAccepted>());
    expect((await second.service.currentKey(home, _community))?.keyId, rotated);
    // A moderator never replaces a key; the admin marks once.
    expect(
        await mods[0].service.replaceModeratorKey(home, _community), isFalse);
    expect(await member.service.replaceModeratorKey(home, _community), isFalse);
    expect(await second.service.replaceModeratorKey(home, _community), isTrue);
    expect(await second.service.replaceModeratorKey(home, _community), isFalse);
    expect(await second.service.dueRotations(), {'channel|$_private'});
    // While the mark is due it does not edit under the moderator's key.
    await expectLater(
        second.service.publish(private, (r) => secret('Early', r)),
        throwsA(isA<InfoRotationPending>()));
    // It waits its turn, as after a removal it did not make.
    final sentBefore = keysSent(second);
    expect(await second.service.nextDeferredRotation(), isNotNull);
    expect(await second.service.runRotations((_, __) => [private]), 0);
    expect(keysSent(second), sentBefore);
    pastTurn();
    expect(await second.service.runRotations((_, __) => [private]), 1);
    final minted = server.records[private.key]!.keyId;
    expect(minted, isNot(rotated));
    expect(keysSent(second), sentBefore + 1);
    expect(
        second.sent
            .where((e) => e.$2 == AppPayloadType.infoKey)
            .every((e) => e.$1 == _privateConv),
        isTrue,
        reason: 'the key goes only into the private channel\'s group');
    expect(await second.service.dueRotations(), isEmpty);
    for (final d in [mod, mod2, member, second]) {
      expect((await d.service.currentKey(home, _community))?.keyId, minted);
      expect(await d.service.refresh(private), isNot(isA<InfoNeedsKey>()));
    }
    // Its own key current, it marks nothing more.
    expect(await second.service.replaceModeratorKey(home, _community), isFalse);
    // With an admin in the group, the admin answers a joiner with its key,
    // the moderators no longer do.
    final late = device('late', {}, verified: modStaff, roster: true);
    late.members.add(_privateConv);
    expect(await late.service.requestKey(home), isTrue);
    expect(await mods[0].service.answerRequests(home, _community), 0);
    expect(await mods[1].service.answerRequests(home, _community), 0);
    expect(await second.service.answerRequests(home, _community), 1);
    expect((await late.service.currentKey(home, _community))?.keyId, minted);
    expect(await late.service.refresh(private), isA<InfoAccepted>());
    await second.service.publish(private, (r) => secret('Renamed', r));
    expect(server.records[private.key]!.keyId, minted);
  }, skip: skip);

  test(
      'with an admin in a private channel, a moderator key after a removal '
      'neither stands in for its rotation nor ends it', () async {
    final private = InfoSubject(infoKindChannel, _private, _community);
    final devices = <String, _Device>{
      for (final name in ['second', 'mod', 'member'])
        name: device(name, {_privateConv},
            admin: name != 'member', verified: modStaff, roster: true),
    };
    final admin = devices['second']!;
    await admin.service
        .publish(private, (r) => secret('Secret', r), mint: true);
    final home = admin.service.homeOf(private)!;
    final key = (await admin.service.currentKey(home, _community))!;
    await net.deliver(
        admin,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel', subjectId: _private, key: key.key!));
    final mod = devices['mod']!;
    final member = devices['member']!;
    for (final d in devices.values) {
      await d.service.refresh(private);
      await removedAt(d.store, _privateConv, 2);
      await d.service.observeRemoval(home, _community);
    }
    // The moderator's own removal: it still does not rotate.
    await mod.service.markRotationDue(home, _community);
    pastTurn();
    expect(await mod.service.runRotations((_, __) => [private]), 0);
    expect(keysSent(mod), 0);
    expect(await mod.service.nextDeferredRotation(), isNull);
    // A key the moderator sends anyway ends nobody's obligation.
    await net.deliver(
        mod,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel',
            subjectId: _private,
            key: mod.service.codec.newKey()));
    expect(await member.service.runRotations((_, __) => [private]), 0);
    expect(await member.service.dueRotations(), {private.key});
    // The admin rotates its own key, not the moderator's.
    expect(await admin.service.runRotations((_, __) => [private]), 1);
    final rotated = server.records[private.key]!.keyId;
    expect(rotated, isNot(key.keyId));
    expect((await admin.service.currentKey(home, _community))?.senderAccountId,
        'acct_second');
    expect(await member.service.runRotations((_, __) => [private]), 1);
    expect((await member.service.currentKey(home, _community))?.keyId, rotated);
  }, skip: skip);

  test(
      'a moderator re-sending a key retired by a removal never makes it '
      'current again', () async {
    final private = InfoSubject(infoKindChannel, _private, _community);
    final devices = <String, _Device>{
      for (final name in ['second', 'mod', 'member'])
        name: device(name, {_privateConv},
            admin: name == 'second', verified: modStaff, roster: true),
    };
    final admin = devices['second']!;
    await admin.service
        .publish(private, (r) => secret('Secret', r), mint: true);
    final home = admin.service.homeOf(private)!;
    final key = (await admin.service.currentKey(home, _community))!;
    await net.deliver(
        admin,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel', subjectId: _private, key: key.key!));
    final mod = devices['mod']!;
    for (final d in devices.values) {
      await d.service.refresh(private);
      await removedAt(d.store, _privateConv, 2);
      await d.service.observeRemoval(home, _community);
    }
    // The moderator sends the old key again, in an epoch after the removal.
    await net.deliverAs(mod, 'dev_mod', _privateConv, AppPayloadType.infoKey,
        infoKeyBody(subjectKind: 'channel', subjectId: _private, key: key.key!),
        epoch: 3);
    for (final d in devices.values) {
      expect((await d.service.currentKey(home, _community))?.keyId,
          isNot(key.keyId));
    }
  }, skip: skip);

  test(
      'a moderator re-sending a key from an admin demoted since never makes '
      'it current again after a removal', () async {
    // The minting admin is no longer an admin in the member's record, so
    // its row is not a trusted copy; it still dates the key.
    final demoted = GovernanceState(
      rev: 4,
      owner: 'acct_admin',
      ownerRev: 4,
      moderators: const {'acct_mod', 'acct_mod2'},
      joined: modStaff.joined,
    );
    final private = InfoSubject(infoKindChannel, _private, _community);
    final admin = device('second', {_privateConv},
        admin: true, verified: modStaff, roster: true);
    final mod = device('mod', {_privateConv}, verified: modStaff, roster: true);
    final member =
        device('member', {_privateConv}, verified: demoted, roster: true);
    await admin.service
        .publish(private, (r) => secret('Secret', r), mint: true);
    final home = admin.service.homeOf(private)!;
    final key = (await admin.service.currentKey(home, _community))!;
    await net.deliver(
        admin,
        _privateConv,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel', subjectId: _private, key: key.key!));
    for (final d in [admin, mod, member]) {
      await d.service.refresh(private);
      await removedAt(d.store, _privateConv, 2);
      await d.service.observeRemoval(home, _community);
    }
    await net.deliverAs(mod, 'dev_mod', _privateConv, AppPayloadType.infoKey,
        infoKeyBody(subjectKind: 'channel', subjectId: _private, key: key.key!),
        epoch: 3);
    expect((await member.service.currentKey(home, _community))?.keyId,
        isNot(key.keyId));
  }, skip: skip);

  test('with the first admin offline, the next one rotates after its turn',
      () async {
    final devices = await staffAfterRemoval(['admin', 'second', 'third']);
    final ordered = devices.values.toList()
      ..sort((a, b) =>
          rankOf(a.service.accountId).compareTo(rankOf(b.service.accountId)));
    final next = ordered[1];
    final nextBefore = keysSent(next);
    final turn = await next.service.nextDeferredRotation();
    expect(turn, isNotNull);
    expect(turn!.isBefore(now.add(remoteRotationBase + remoteRotationSlot)),
        isFalse);
    now = now.add(remoteRotationBase + remoteRotationJitter);
    expect(await next.service.runRotations((_, __) => [community]), 0);
    now = turn.add(const Duration(seconds: 1));
    final old = server.records[community.key]!.keyId;
    expect(await next.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(next), nextBefore + 1);
    expect(server.records[community.key]!.keyId, isNot(old));
    // The third admin, later still, adopts what the second sent.
    final last = ordered[2];
    final before = keysSent(last);
    pastTurn();
    expect(await last.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(last), before);
  }, skip: skip);

  test('the removing admin rotates at once; the commit epoch keeps it so',
      () async {
    final admin = device('admin', {_shared}, admin: true, verified: staff);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    // Its own kick marks the key before the commit is merged...
    await admin.service.markRotationDue(home, _community);
    // ...and the merged commit's epoch, observed later, does not defer it.
    await removedAt(admin.store, _shared, 2);
    await admin.service.observeRemoval(home, _community);
    expect(await admin.service.nextDeferredRotation(), isNull);
    expect(await admin.service.runRotations((_, __) => [community]), 1);
  }, skip: skip);

  test('a restart inside the wait keeps the mark and catches up first',
      () async {
    final admin = device('admin', {_shared}, admin: true, verified: staff);
    await admin.service.publish(community, (r) => named('Club', r), mint: true);
    final home = admin.service.homeOf(community)!;
    await removedAt(admin.store, _shared, 2);
    await admin.service.observeRemoval(home, _community);
    now = now.add(const Duration(seconds: 5));
    expect(await admin.service.runRotations((_, __) => [community]), 0);
    // Closed for an hour, then restarted: the turn the observation set has
    // long passed, but the wait counts again from the start, so what other
    // admins sent meanwhile is fetched before this device decides.
    now = now.add(const Duration(hours: 1));
    final restarted = device('admin', {_shared},
        admin: true, verified: staff, store: admin.store);
    expect(await restarted.service.runRotations((_, __) => [community]), 0);
    expect(await restarted.service.dueRotations(), {community.key});
    final turn = (await restarted.service.nextDeferredRotation())!;
    expect(turn.isAfter(now), isTrue);
    now = turn.add(const Duration(seconds: 1));
    expect(await restarted.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(restarted), 1);
    // Another restart neither repeats nor resurrects it.
    final again = device('admin', {_shared},
        admin: true, verified: staff, store: admin.store);
    await again.service.observeRemoval(home, _community);
    pastTurn();
    expect(await again.service.runRotations((_, __) => [community]), 0);
    expect(await again.service.dueRotations(), isEmpty);
    expect(keysSent(again), 0);
  }, skip: skip);

  test('a key made but never sent before a crash does not end the obligation',
      () async {
    final devices = await staffAfterRemoval(['admin', 'member']);
    final admin = devices['admin']!;
    final member = devices['member']!;
    final home = admin.service.homeOf(community)!;
    // The crash: a fresh key stored locally, its mark never updated, nothing
    // sent.
    final unsent = await admin.service.newKey(home);
    expect((await admin.service.currentKey(home, _community))!.keyId,
        unsent.keyId);
    final restarted = device('admin', {_shared},
        admin: true, verified: staff, store: admin.store);
    pastTurn();
    expect(await restarted.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(restarted), 1);
    final sentKey = restarted.sent
        .lastWhere((e) => e.$2 == AppPayloadType.infoKey)
        .$3['key_id'];
    expect(server.records[community.key]!.keyId, sentKey);
    final current = (await member.service.currentKey(home, _community))!;
    expect(current.keyId, sentKey);
    expect(await member.service.runRotations((_, __) => [community]), 1);
    // The orphan never wins on the admin either: its later edits are sealed
    // under the key the others hold.
    expect(
        (await restarted.service.currentKey(home, _community))!.keyId, sentKey);
    await restarted.service.publish(community, (r) => named('After', r));
    expect(server.records[community.key]!.keyId, sentKey);
    expect(await member.service.refresh(community), isA<InfoAccepted>());
    expect(member.service.shown(infoKindCommunity, _community)?.name, 'After');
  }, skip: skip);

  test(
      'a moderator never rotates, even when the server says admin, and '
      'completes only on an owner or admin key', () async {
    final devices = await staffAfterRemoval(['admin', 'mod', 'member']);
    final mod = devices['mod']!;
    final member = devices['member']!;
    final home = mod.service.homeOf(community)!;
    // The moderator's own kick does not let it rotate either.
    await mod.service.markRotationDue(home, _community);
    pastTurn();
    expect(await mod.service.runRotations((_, __) => [community]), 0);
    expect(keysSent(mod), 0);
    expect(await mod.service.dueRotations(), {community.key});
    expect(await mod.service.nextDeferredRotation(), isNull);
    // A key a moderator sends after the removal ends nobody's obligation.
    await net.deliver(
        mod,
        _shared,
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'community',
            subjectId: _community,
            key: mod.service.codec.newKey()));
    expect(await member.service.runRotations((_, __) => [community]), 0);
    expect(await member.service.dueRotations(), {community.key});
    await expectLater(
        member.service.publish(community, (r) => named('Edit', r)),
        throwsA(isA<InfoRotationPending>()));
    // The owner rotates; both then complete without a key of their own.
    expect(await devices['admin']!.service.runRotations((_, __) => [community]),
        1);
    expect(await mod.service.runRotations((_, __) => [community]), 1);
    expect(await member.service.runRotations((_, __) => [community]), 1);
    expect(keysSent(mod), 1);
    expect(keysSent(member), 0);
  }, skip: skip);
}
