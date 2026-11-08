import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/profile_models.dart';
import 'package:private_messenger/core/profile_service.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart'
    show profileKeyEffects;
import 'package:private_messenger/crypto/profile_key_payload.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// W11 service: publishing, fetching, key delivery, rotation and cleanup,
/// against a fake server and the real chunk AEAD.
const ana = 'acct_11111111111111111111111111111111';
const bob = 'acct_22222222222222222222222222222222';
const grp = 'conv_55555555555555555555555555555555';
const dm = 'conv_66666666666666666666666666666666';

class _Row {
  _Row(this.version, this.keyId, this.blob);
  int version;
  String keyId;
  Uint8List blob;
}

/// One server shared by every viewer; reads are not filtered by membership
/// here (the Go tests cover the read rule), only by [hidden].
class _Server {
  final Map<String, _Row> rows = {};
  final Set<String> hidden = {};
  int gets = 0;
  int puts = 0;
  int versionCalls = 0;
}

class _Api implements ProfileApi {
  _Api(this.server, this.me);
  final _Server server;
  final String me;

  String _k(String kind, String id) => '$kind/$id';

  @override
  Future<ProfileFetch> fetch(String kind, String subjectId,
      {int? ifNoneMatchVersion}) async {
    server.gets++;
    final key = _k(kind, subjectId);
    final row = server.rows[key];
    if (row == null || server.hidden.contains(key)) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    if (ifNoneMatchVersion == row.version) {
      return const ProfileFetch.notModified();
    }
    return ProfileFetch.record(
        version: row.version, keyId: row.keyId, blob: row.blob);
  }

  @override
  Future<int> put(String kind, String subjectId, Uint8List blob,
      {required String keyId, int? ifMatchVersion}) async {
    server.puts++;
    final key = _k(kind, subjectId);
    final row = server.rows[key];
    if ((row?.version ?? 0) != (ifMatchVersion ?? 0)) {
      throw ApiException(412, '{"error":"version_conflict"}');
    }
    final next = (row?.version ?? 0) + 1;
    server.rows[key] = _Row(next, keyId, blob);
    return next;
  }

  @override
  Future<List<ProfileVersion>> versions(
      {List<String> accountIds = const [],
      List<String> conversationIds = const []}) async {
    server.versionCalls++;
    return [
      for (final id in accountIds)
        if (server.rows['account/$id'] != null)
          ProfileVersion(
              kind: 'account',
              id: id,
              version: server.rows['account/$id']!.version,
              keyId: server.rows['account/$id']!.keyId),
      for (final id in conversationIds)
        if (server.rows['conversation/$id'] != null)
          ProfileVersion(
              kind: 'conversation',
              id: id,
              version: server.rows['conversation/$id']!.version,
              keyId: server.rows['conversation/$id']!.keyId),
    ];
  }
}

class _Sent {
  _Sent(this.conversationId, this.type, this.body);
  final String conversationId;
  final AppPayloadType type;
  final Map<String, Object?> body;
}

class _Device {
  _Device(this.account, this.server, this.codec,
      {List<String> postable = const [grp, dm], this.coMembers}) {
    service = ProfileService(
      store: store,
      codec: codec,
      api: _Api(server, account),
      accountId: account,
      sendKey: (conversationId, type, body) async {
        if (!sendOk) return false;
        sent.add(_Sent(conversationId, type, body));
        return true;
      },
      postableConversationIds: () => postable,
      coMemberAccountIds: () => coMembers,
    );
  }

  final String account;
  final _Server server;
  final ProfileRecordCodec codec;
  final MemoryLocalStore store = MemoryLocalStore();
  late final ProfileService service;
  final List<_Sent> sent = [];
  bool sendOk = true;
  Set<String>? coMembers;

  /// What receiving a key message does: store the key beside the MLS state.
  Future<void> receive(_Sent message, {required String from}) async {
    final effects = profileKeyEffects(
        DecryptedAppPayload(
            type: message.type, actionId: 'a', body: message.body),
        conversationId: message.conversationId,
        senderAccountId: from,
        receivedAt: 1,
        conversationKind: 'group');
    for (final effect in effects.cast<ProfileKeyEffect>()) {
      await store.saveProfileKey(effect);
    }
  }
}

void main() {
  final skip = nativeCryptoSkip();
  late ProfileRecordCodec codec;
  late _Server server;

  setUp(() {
    if (skip != false) return;
    codec = ProfileRecordCodec(
        NativeCryptoBindings.open(requireNativeCryptoLibrary()));
    server = _Server();
  });

  _Device device(String account, {Set<String>? coMembers}) =>
      _Device(account, server, codec, coMembers: coMembers);

  test('the first save makes a key, uploads, and queues the key to every chat',
      skip: skip, () async {
    final a = device(ana);
    await a.service.saveOwnProfile(name: '  Ana  ');
    expect(a.service.own?.name, 'Ana');
    expect(server.rows['account/$ana']!.version, 1);
    expect(a.sent.map((s) => s.conversationId).toSet(), {grp, dm});
    expect(a.sent.every((s) => s.type == AppPayloadType.profileKey), isTrue);
    final parsed = parseProfileKey(a.sent.first.body)!;
    expect(parsed.keyId, server.rows['account/$ana']!.keyId);
    expect(parsed.version, 1);
  });

  test('a later save keeps the key and sends nothing', skip: skip, () async {
    final a = device(ana);
    await a.service.saveOwnProfile(name: 'Ana');
    a.sent.clear();
    final keyId = server.rows['account/$ana']!.keyId;
    await a.service.saveOwnProfile(name: 'Ana B');
    expect(server.rows['account/$ana']!.version, 2);
    expect(server.rows['account/$ana']!.keyId, keyId);
    expect(a.sent, isEmpty);
    expect(a.service.own?.name, 'Ana B');
  });

  test('a contact reads the profile once the key arrives, not before',
      skip: skip, () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'Ana');
    await b.service.refresh('account', ana);
    expect(b.service.account(ana), isNull);
    await b.receive(a.sent.first, from: ana);
    await b.service.onKeysMayHaveArrived();
    expect(b.service.account(ana)?.name, 'Ana');
  });

  test('a photo is stored and shown', skip: skip, () async {
    final a = device(ana);
    final png = _png(64, 64);
    await a.service.saveOwnProfile(
        name: 'Ana', photo: ProfilePhoto(png: png, width: 64, height: 64));
    expect(a.service.own?.photoPng, png);
    final b = device(bob);
    await b.receive(a.sent.first, from: ana);
    await b.service.refresh('account', ana);
    expect(b.service.account(ana)?.photoPng, png);
  });

  test('a bad name is refused before anything is sent', skip: skip, () async {
    final a = device(ana);
    await expectLater(a.service.saveOwnProfile(name: 'A\u202eB'),
        throwsA(isA<ProfileRecordException>()));
    expect(server.puts, 0);
  });

  test('a 404 keeps the cached profile (S9)', skip: skip, () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'Ana');
    await b.receive(a.sent.first, from: ana);
    await b.service.refresh('account', ana);
    server.hidden.add('account/$ana');
    await b.service.refresh('account', ana);
    expect(b.service.account(ana)?.name, 'Ana');
  });

  test('a removed profile clears the name', skip: skip, () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'Ana');
    await b.receive(a.sent.first, from: ana);
    await b.service.refresh('account', ana);
    await a.service.saveOwnProfile();
    await b.service.refresh('account', ana);
    expect(b.service.account(ana), isNull);
  });

  test('a rolled-back record is ignored', skip: skip, () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'One');
    final first = server.rows['account/$ana']!.blob;
    await b.receive(a.sent.first, from: ana);
    await a.service.saveOwnProfile(name: 'Two');
    await b.service.refresh('account', ana);
    expect(b.service.account(ana)?.name, 'Two');
    // The server serves record 1 again, claiming version 1.
    server.rows['account/$ana'] =
        _Row(1, server.rows['account/$ana']!.keyId, first);
    await b.service.refresh('account', ana);
    expect(b.service.account(ana)?.name, 'Two');
  });

  test('the version floor from a key message blocks an old record', skip: skip,
      () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'One');
    final first = server.rows['account/$ana']!;
    final oldBlob = first.blob;
    final keyId = first.keyId;
    await a.service.saveOwnProfile(name: 'Two');
    // Bob learns the key with a hint of version 2 (sent after the edit).
    final body = Map<String, Object?>.of(a.sent.first.body)..['version'] = 2;
    await b.receive(_Sent(grp, AppPayloadType.profileKey, body), from: ana);
    server.rows['account/$ana'] = _Row(1, keyId, oldBlob);
    await b.service.refresh('account', ana);
    expect(b.service.account(ana), isNull);
  });

  test('a conflict from another device that wrote under an unknown key',
      skip: skip, () async {
    final one = device(ana);
    final two = device(ana);
    await one.service.saveOwnProfile(name: 'From one');
    await two.service.refresh('account', ana);
    expect(two.service.own, isNull); // no key yet, nothing readable
    // Device two edits: it has no key, so it makes its own and the server
    // refuses the stale precondition.
    await expectLater(two.service.saveOwnProfile(name: 'From two'),
        throwsA(isA<ProfileConflictException>()));
    expect(server.rows['account/$ana']!.version, 1);
  });

  test('the other device reads and edits once the key arrives', skip: skip,
      () async {
    final one = device(ana);
    final two = device(ana);
    await one.service.saveOwnProfile(name: 'From one');
    await two.receive(one.sent.first, from: ana);
    await two.service.refresh('account', ana);
    expect(two.service.own?.name, 'From one');
    await two.service.saveOwnProfile(name: 'From two');
    expect(server.rows['account/$ana']!.version, 2);
    expect(two.sent.length, 0);
  });

  group('rotation', () {
    test('a block makes the next write use a new key, sent everywhere',
        skip: skip, () async {
      final a = device(ana);
      await a.service.saveOwnProfile(name: 'Ana');
      final oldId = server.rows['account/$ana']!.keyId;
      a.sent.clear();
      await a.service.markOwnRotationDue();
      expect(await a.service.ownRotationDue(), isTrue);
      await a.service.saveOwnProfile(name: 'Ana');
      final newId = server.rows['account/$ana']!.keyId;
      expect(newId, isNot(oldId));
      expect(a.sent.map((s) => s.conversationId).toSet(), {grp, dm});
      expect(parseProfileKey(a.sent.first.body)!.keyId, newId);
      expect(await a.service.ownRotationDue(), isFalse);
      // The old key stays only while it opens something cached.
      a.sent.clear();
      await a.service.saveOwnProfile(name: 'Ana 2');
      expect(a.sent, isEmpty);
    });

    test('nothing is due before a key exists', skip: skip, () async {
      final a = device(ana);
      await a.service.markOwnRotationDue();
      expect(await a.service.ownRotationDue(), isFalse);
    });

    test('a departure marks a rotation, a join does not', skip: skip, () async {
      final a = device(ana);
      await a.service.saveOwnProfile(name: 'Ana');
      await a.service.noteCoMembers({bob});
      expect(await a.service.ownRotationDue(), isFalse);
      await a.service
          .noteCoMembers({bob, 'acct_33333333333333333333333333333333'});
      expect(await a.service.ownRotationDue(), isFalse);
      await a.service.noteCoMembers({'acct_33333333333333333333333333333333'});
      expect(await a.service.ownRotationDue(), isTrue);
    });

    test('a departed account cannot read the edit after rotation', skip: skip,
        () async {
      final a = device(ana);
      final b = device(bob);
      await a.service.saveOwnProfile(name: 'Ana');
      await b.receive(a.sent.first, from: ana);
      await b.service.refresh('account', ana);
      expect(b.service.account(ana)?.name, 'Ana');
      await a.service.markOwnRotationDue();
      a.sent.clear();
      await a.service.saveOwnProfile(name: 'Ana new');
      // Bob never receives the new key.
      await b.service.refresh('account', ana);
      expect(b.service.account(ana)?.name, 'Ana');
    });
  });

  group('groups', () {
    test('a group name is published and the key sent to that group only',
        skip: skip, () async {
      final a = device(ana);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      expect(a.service.conversation(grp)?.name, 'Walkers');
      expect(a.sent, hasLength(1));
      expect(a.sent.single.type, AppPayloadType.groupProfileKey);
      expect(a.sent.single.conversationId, grp);
      final b = device(bob);
      await b.receive(a.sent.single, from: ana);
      await b.service.refresh('conversation', grp);
      expect(b.service.conversation(grp)?.name, 'Walkers');
    });

    test('another member may rename with the same key', skip: skip, () async {
      final a = device(ana);
      final b = device(bob);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      await b.receive(a.sent.single, from: ana);
      await b.service.refresh('conversation', grp);
      await b.service.saveGroupProfile(grp, name: 'Hikers');
      expect(b.sent, isEmpty);
      await a.service.refresh('conversation', grp);
      expect(a.service.conversation(grp)?.name, 'Hikers');
    });

    test('ten junk keys do not stop the group profile opening', skip: skip,
        () async {
      final a = device(ana);
      final b = device(bob);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      await b.receive(a.sent.single, from: ana);
      for (var i = 0; i < 10; i++) {
        final junk = Uint8List(32)..[0] = i + 1;
        await b.receive(
            _Sent(
                grp,
                AppPayloadType.groupProfileKey,
                profileKeyBody(
                    key: junk,
                    keyId: ProfileRecordCodec.keyId(junk),
                    version: 999)),
            from: 'acct_33333333333333333333333333333333');
        await b.service.onKeysMayHaveArrived();
      }
      expect(b.service.conversation(grp)?.name, 'Walkers');
      final held = await b.store.loadProfileKeys('conversation', grp);
      expect(
          held.map((k) => k.keyId), [server.rows['conversation/$grp']!.keyId]);
    });

    test('a rotation after a removal uses a new key', skip: skip, () async {
      final a = device(ana);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      final oldId = server.rows['conversation/$grp']!.keyId;
      a.sent.clear();
      await a.service.markGroupRotationDue(grp);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      expect(server.rows['conversation/$grp']!.keyId, isNot(oldId));
      expect(a.sent.single.type, AppPayloadType.groupProfileKey);
    });

    test('leaving a group deletes its profile and keys', skip: skip, () async {
      final a = device(ana);
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      await a.service.forgetConversation(grp);
      expect(a.service.conversation(grp), isNull);
      expect(await a.store.loadProfileKeys('conversation', grp), isEmpty);
    });
  });

  group('delivery', () {
    test('a key that cannot be queued now is retried', skip: skip, () async {
      final a = device(ana);
      a.sendOk = false;
      await a.service.saveOwnProfile(name: 'Ana');
      expect(a.sent, isEmpty);
      a.sendOk = true;
      await a.service.retryDeliveries();
      expect(a.sent.map((s) => s.conversationId).toSet(), {grp, dm});
      a.sent.clear();
      await a.service.retryDeliveries();
      expect(a.sent, isEmpty);
    });

    test('a new conversation gets the account key once', skip: skip, () async {
      final a = device(ana);
      await a.service.saveOwnProfile(name: 'Ana');
      a.sent.clear();
      await a.service.onConversationAvailable(grp);
      expect(a.sent.single.conversationId, grp);
      a.sent.clear();
      await a.service.retryDeliveries();
      expect(a.sent, isEmpty);
    });

    test('with no key nothing goes to a new conversation', skip: skip,
        () async {
      final a = device(ana);
      await a.service.onConversationAvailable(grp);
      expect(a.sent, isEmpty);
    });

    test('sidecars: the account key always, the group key once flagged',
        skip: skip, () async {
      final a = device(ana);
      expect(await a.service.sidecars(grp), isEmpty);
      await a.service.saveOwnProfile(name: 'Ana');
      await a.service.saveGroupProfile(grp, name: 'Walkers');
      var sidecars = await a.service.sidecars(grp);
      expect(sidecars.keys, [profileKeyBodyName]);
      expect(parseProfileKey(sidecars[profileKeyBodyName])!.version, 1);
      await a.service.markGroupKeyForSidecar(grp);
      sidecars = await a.service.sidecars(grp);
      expect(
          sidecars.keys.toSet(), {profileKeyBodyName, groupProfileKeyBodyName});
      await a.service.sidecarsSent(grp);
      expect((await a.service.sidecars(grp)).keys, [profileKeyBodyName]);
    });

    test('the group sidecar needs a group key', skip: skip, () async {
      final a = device(ana);
      await a.service.markGroupKeyForSidecar(grp);
      expect(
          (await a.service.sidecars(grp)).containsKey(groupProfileKeyBodyName),
          isFalse);
    });
  });

  group('a second device of the same account', () {
    test('uses the key it was sent for sidecars, delivery and rotation',
        skip: skip, () async {
      final one = device(ana);
      final two = device(ana);
      await one.service.saveOwnProfile(name: 'Ana');
      await two.receive(one.sent.first, from: ana);
      await two.service.refresh('account', ana);
      final sidecars = await two.service.sidecars(grp);
      expect(parseProfileKey(sidecars[profileKeyBodyName])!.keyId,
          server.rows['account/$ana']!.keyId);
      await two.service.onConversationAvailable(grp);
      expect(two.sent.single.conversationId, grp);
      await two.service.markOwnRotationDue();
      expect(await two.service.ownRotationDue(), isTrue);
    });
  });

  group('events and checks', () {
    test('profile.updated fetches only a newer version', skip: skip, () async {
      final a = device(ana);
      final b = device(bob);
      await a.service.saveOwnProfile(name: 'Ana');
      await b.receive(a.sent.first, from: ana);
      await b.service.onProfileUpdated(
          {'subject_kind': 'account', 'subject_id': ana, 'version': 1});
      expect(b.service.account(ana)?.name, 'Ana');
      final before = server.gets;
      await b.service.onProfileUpdated(
          {'subject_kind': 'account', 'subject_id': ana, 'version': 1});
      expect(server.gets, before);
      await a.service.saveOwnProfile(name: 'Ana 2');
      await b.service.onProfileUpdated(
          {'subject_kind': 'account', 'subject_id': ana, 'version': 2});
      expect(b.service.account(ana)?.name, 'Ana 2');
    });

    test('junk events are ignored', skip: skip, () async {
      final b = device(bob);
      for (final payload in <Object?>[
        null,
        'x',
        {'subject_kind': 'channel', 'subject_id': ana, 'version': 5},
        {'subject_kind': 'account', 'subject_id': '', 'version': 5},
        {'subject_kind': 'account', 'subject_id': ana, 'version': '5'},
      ]) {
        await b.service.onProfileUpdated(payload);
      }
      expect(server.gets, 0);
    });

    test('the periodic check fetches only what changed', skip: skip, () async {
      final a = device(ana);
      final b = device(bob);
      await a.service.saveOwnProfile(name: 'Ana');
      await b.receive(a.sent.first, from: ana);
      await b.service.checkVersions(
          accountIds: [ana, 'acct_unknown'], conversationIds: []);
      expect(b.service.account(ana)?.name, 'Ana');
      final gets = server.gets;
      await b.service.checkVersions(accountIds: [ana], conversationIds: []);
      expect(server.gets, gets);
      expect(server.versionCalls, 2);
    });
  });

  test('forgetting an account deletes its profile and keys', skip: skip,
      () async {
    final a = device(ana);
    final b = device(bob);
    await a.service.saveOwnProfile(name: 'Ana');
    await b.receive(a.sent.first, from: ana);
    await b.service.refresh('account', ana);
    await b.service.forgetAccount(ana);
    expect(b.service.account(ana), isNull);
    expect(await b.store.loadProfileKeys('account', ana), isEmpty);
    expect(await b.store.loadProfile('account', ana), isNull);
  });

  test('load restores the cached profiles', skip: skip, () async {
    final a = device(ana);
    await a.service.saveOwnProfile(name: 'Ana');
    final again = ProfileService(
      store: a.store,
      codec: codec,
      api: _Api(server, ana),
      accountId: ana,
      sendKey: (_, __, ___) async => true,
      postableConversationIds: () => const [],
      coMemberAccountIds: () => null,
    );
    expect(again.own, isNull);
    await again.load();
    expect(again.own?.name, 'Ana');
  });
}

Uint8List _png(int w, int h) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final ihdr = ByteData(25);
  ihdr.setUint32(0, 13);
  ihdr.buffer.asUint8List().setRange(4, 8, 'IHDR'.codeUnits);
  ihdr.setUint32(8, w);
  ihdr.setUint32(12, h);
  out.add(ihdr.buffer.asUint8List());
  return out.toBytes();
}
