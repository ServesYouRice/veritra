import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/community_info_payload.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'schema_fixtures.dart';

// C3 (docs/designs/C3-private-channels-and-info.md): the info_key,
// info_key_request and info_update payloads, and the schema 31 tables that
// keep what they carry.

String _id(String prefix, int n) =>
    '${prefix}_${n.toRadixString(16).padLeft(32, '0')}';

final _community = _id('comm', 1);
final _channel = _id('chan', 2);
final _category = _id('cat', 3);
final _key = Uint8List.fromList(List<int>.generate(32, (i) => i));
final _digest = 'ab' * 32;

Uint8List _frame(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  final result = Uint8List(((bytes.length + 8 + 255) ~/ 256) * 256);
  result.setRange(0, 4, [86, 65, 80, 49]);
  ByteData.sublistView(result).setUint32(4, bytes.length);
  result.setRange(8, 8 + bytes.length, bytes);
  return result;
}

CommunityInfoEvent _event(CommunityInfoEventKind kind,
        {int n = 0,
        String? subject,
        String conversation = 'conv_shared',
        String sender = 'acct_alice'}) =>
    CommunityInfoEvent(
      kind: kind,
      subjectKind: 'community',
      subjectId: subject ?? _community,
      conversationId: conversation,
      senderAccountId: sender,
      senderDeviceId: 'dev_$sender',
      keyId: kind == CommunityInfoEventKind.keyRequest
          ? null
          : n.toRadixString(16).padLeft(32, '0'),
      key: kind == CommunityInfoEventKind.key ? List<int>.filled(32, n) : null,
      revision: kind == CommunityInfoEventKind.update ? n + 1 : null,
      recordSha256: kind == CommunityInfoEventKind.update ? _digest : null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = AppPayloadCodec();

  AppPayloadOutcome classify(String type, Map<String, Object?> body,
          {int v = 2}) =>
      codec.classify(
          _frame({
            'v': v,
            'type': type,
            'conversation_id': 'conv',
            'sender_device_id': 'dev',
            'action_id': 'action',
            'hidden': true,
            'body': body,
          }),
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action');

  group('payloads', () {
    final keyBody =
        infoKeyBody(subjectKind: 'channel', subjectId: _channel, key: _key);

    test('the three types are v2, hidden, unfranked and snake_case', () {
      for (final type in infoPayloadTypes) {
        expect(type.sendsHidden, isTrue);
        expect(FrankingPolicy.unfrankedPayloadTypes, contains(type.name));
      }
      expect(AppPayloadType.infoKey.wireName, 'info_key');
      expect(AppPayloadType.infoKeyRequest.wireName, 'info_key_request');
      expect(AppPayloadType.infoUpdate.wireName, 'info_update');
      final framed = codec.encode(
          type: AppPayloadType.infoKey,
          conversationId: 'conv',
          senderDeviceId: 'dev',
          actionId: 'action',
          body: keyBody,
          hidden: true);
      final length = ByteData.sublistView(framed).getUint32(4);
      final wire =
          jsonDecode(utf8.decode(framed.sublist(8, 8 + length))) as Map;
      expect(wire['v'], 2);
      expect(wire['hidden'], isTrue);
      expect(wire['type'], 'info_key');
      // Even when refusing unfranked payloads, these stay accepted.
      final outcome = classify('info_key', keyBody);
      expect(outcome, isA<DecodedAppPayload>());
      expect(
          const FrankingPolicy(acceptUnfranked: false)
              .acceptsUnfranked(outcome),
          isTrue);
    });

    test('info_key: a well-formed key whose id matches, for a keyed kind', () {
      expect(keyBody['key_id'], ProfileRecordCodec.keyId(_key));
      expect(classify('info_key', keyBody), isA<DecodedAppPayload>());
      expect(classify('info_key', keyBody, v: 1), isA<InvalidAppPayload>());
      for (final bad in <Map<String, Object?>>[
        {...keyBody, 'key_id': '0' * 32},
        {...keyBody, 'key': base64.encode(Uint8List(31))},
        // Non-canonical base64 of the same key.
        {...keyBody, 'key': '${keyBody['key']}\n'},
        {...keyBody, 'subject_kind': 'category', 'subject_id': _category},
        {...keyBody, 'subject_kind': 'community', 'subject_id': _channel},
        {...keyBody, 'subject_kind': 'account'},
        {...keyBody}..remove('key'),
      ]) {
        expect(classify('info_key', bad), isA<InvalidAppPayload>(),
            reason: '$bad');
      }
    });

    test('info_key_request and info_update', () {
      expect(
          classify(
              'info_key_request',
              infoKeyRequestBody(
                  subjectKind: 'community', subjectId: _community)),
          isA<DecodedAppPayload>());
      expect(
          classify(
              'info_key_request',
              infoKeyRequestBody(
                  subjectKind: 'category', subjectId: _category)),
          isA<InvalidAppPayload>());
      final update = infoUpdateBody(
          subjectKind: 'category',
          subjectId: _category,
          revision: 3,
          keyId: '1' * 32,
          recordSha256: _digest);
      expect(classify('info_update', update), isA<DecodedAppPayload>());
      for (final bad in <Map<String, Object?>>[
        {...update, 'revision': 0},
        {...update, 'record_sha256': 'AB' * 32},
        {...update, 'record_sha256': 'ab'},
        {...update, 'key_id': 'x' * 32},
        {...update, 'subject_id': _channel},
      ]) {
        expect(classify('info_update', bad), isA<InvalidAppPayload>(),
            reason: '$bad');
      }
    });

    test('a received payload becomes a stored event tied to its sender', () {
      final event = communityInfoEventFor(
        DecryptedAppPayload(
            type: AppPayloadType.infoKey, actionId: 'a', body: keyBody),
        conversationId: 'conv_private',
        senderAccountId: 'acct_alice',
        senderDeviceId: 'dev_alice',
      );
      expect(event.kind, CommunityInfoEventKind.key);
      expect(event.subjectKind, 'channel');
      expect(event.subjectId, _channel);
      expect(event.conversationId, 'conv_private');
      expect(event.key, _key);
      expect(event.isStorable, isTrue);
      // Keys never print.
      expect(event.toString(), isNot(contains(base64.encode(_key))));
      expect(event.toString(), isNot(contains('0, 1, 2')));
    });
  });

  for (final encrypted in [false, true]) {
    group(encrypted ? 'SQLite store' : 'memory store', () {
      late LocalStore store;
      EncryptedLocalDatabase? database;
      late Directory dir;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        dir = await Directory.systemTemp.createTemp('veritra-c3-');
        database = null;
        store = encrypted
            ? SecureLocalStore(
                directoryProvider: () async => dir,
                databaseFactory: (_, __) => database ??=
                    EncryptedLocalDatabase(NativeDatabase.memory()))
            : MemoryLocalStore();
        await store.saveSession(const Session(
            baseUrl: 'https://example.test',
            token: 'token',
            accountId: 'alice',
            deviceId: 'dev'));
        await store.saveCryptoState(
            StoredCryptoState(
                counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
            0);
      });
      tearDown(() async {
        await database?.close();
        await SecureLocalStore.releaseInstanceLocks();
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      Future<void> commit(List<CommunityInfoEvent> events) async {
        final state = (await store.loadCryptoState())!,
            cursor = await store.loadSyncCursor();
        await store.commitMlsTransition(MlsStateTransition(
            messageId: 'event:${cursor + 1}',
            conversationId: 'conv_shared',
            expectedCounter: state.counter,
            expectedCursor: cursor,
            state: StoredCryptoState(
                counter: state.counter + 1,
                stateKey: state.stateKey,
                sealedState: [2]),
            cursor: cursor + 1,
            communityInfo: events));
      }

      Future<List<CommunityInfoEvent>> keys() => store.loadCommunityInfoEvents(
          CommunityInfoEventKind.key, 'community', _community);

      test('events commit with the MLS state; repeats are one row', () async {
        await commit([
          _event(CommunityInfoEventKind.key, n: 1),
          _event(CommunityInfoEventKind.update, n: 1),
          _event(CommunityInfoEventKind.keyRequest),
        ]);
        await commit([_event(CommunityInfoEventKind.key, n: 1)]);
        final held = await keys();
        expect(held, hasLength(1));
        expect(held.single.key, List<int>.filled(32, 1));
        expect(held.single.conversationId, 'conv_shared');
        expect(held.single.senderAccountId, 'acct_alice');
        final updates = await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.update, 'community', _community);
        expect(updates.single.revision, 2);
        expect(updates.single.recordSha256, _digest);
        expect(
            await store.loadCommunityInfoEvents(
                CommunityInfoEventKind.keyRequest, 'community', _community),
            hasLength(1));
        // Another subject sees none of it.
        expect(
            await store.loadCommunityInfoEvents(
                CommunityInfoEventKind.key, 'community', _id('comm', 9)),
            isEmpty);
      });

      test('at most four keys per sender and group: the oldest go', () async {
        for (var n = 1; n <= 6; n++) {
          await commit([_event(CommunityInfoEventKind.key, n: n)]);
        }
        expect((await keys()).map((k) => k.key!.first), [3, 4, 5, 6]);
      });

      test('another sender flooding keys never pushes out the real key',
          () async {
        await commit([_event(CommunityInfoEventKind.key, n: 1)]);
        for (var n = 10; n < 20; n++) {
          await commit([
            _event(CommunityInfoEventKind.key, n: n, sender: 'acct_mallory')
          ]);
        }
        final held = await keys();
        expect(
            held.where((k) => k.senderAccountId == 'acct_alice'), hasLength(1));
        expect(held.where((k) => k.senderAccountId == 'acct_mallory'),
            hasLength(infoKeysPerSubject));
      });

      test('a key an accepted record uses is never evicted', () async {
        final first = 1.toRadixString(16).padLeft(32, '0');
        await commit([_event(CommunityInfoEventKind.key, n: 1)]);
        await store.saveAcceptedCommunityInfo(AcceptedCommunityInfo(
            subjectKind: 'channel',
            subjectId: _channel,
            revision: 1,
            keyId: first,
            blob: const [1]));
        for (var n = 2; n <= 8; n++) {
          await commit([_event(CommunityInfoEventKind.key, n: n)]);
        }
        final ids = (await keys()).map((k) => k.keyId).toList();
        expect(ids, contains(first));
        expect(ids, hasLength(infoKeysPerSubject + 1));
      });

      test('a copy sent first by someone else does not hide the editor\'s',
          () async {
        // A member (or another group) replays an editor's announcement or
        // key first; the editor's own copy still becomes its own row.
        await commit([
          _event(CommunityInfoEventKind.update, n: 1, sender: 'acct_mallory'),
          _event(CommunityInfoEventKind.key,
              n: 1, conversation: 'conv_dm', sender: 'acct_mallory'),
        ]);
        await commit([
          _event(CommunityInfoEventKind.update, n: 1),
          _event(CommunityInfoEventKind.key, n: 1),
        ]);
        final updates = await store.loadCommunityInfoEvents(
            CommunityInfoEventKind.update, 'community', _community);
        expect(updates.map((u) => u.senderAccountId),
            ['acct_mallory', 'acct_alice']);
        expect((await keys()).map((k) => k.conversationId),
            ['conv_dm', 'conv_shared']);
      });

      test('an unstorable event is skipped, never thrown on', () async {
        await commit([
          CommunityInfoEvent(
            kind: CommunityInfoEventKind.key,
            subjectKind: 'community',
            subjectId: _community,
            conversationId: 'conv_shared',
            senderAccountId: 'acct_alice',
            senderDeviceId: 'dev_alice',
            keyId: '1' * 32,
            key: List<int>.filled(16, 1),
          ),
        ]);
        expect(await keys(), isEmpty);
        expect(await store.loadSyncCursor(), 1);
      });

      test('an accepted record never goes back to a lower revision', () async {
        AcceptedCommunityInfo record(int revision) => AcceptedCommunityInfo(
            subjectKind: 'community',
            subjectId: _community,
            revision: revision,
            keyId: '1' * 32,
            blob: [revision]);
        await store.saveAcceptedCommunityInfo(record(3));
        await store.saveAcceptedCommunityInfo(record(2));
        expect(
            (await store.loadAcceptedCommunityInfo('community', _community))!
                .revision,
            3);
        await store.saveAcceptedCommunityInfo(record(4));
        expect(
            (await store.loadAcceptedCommunityInfo('community', _community))!
                .blob,
            [4]);
      });
    });
  }

  test('schema 26 upgrades to the current schema with the C3 tables', () async {
    final dir = await Directory.systemTemp.createTemp('veritra-c3-schema-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/schema26.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await stripCommunityInfoSchema(db);
    await db.customStatement('PRAGMA user_version = 26');
    await db.close();
    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final version = (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');
    expect(version, EncryptedLocalDatabase.currentSchemaVersion);
    expect(db.upgradeStarted, isTrue);
    final names = {
      for (final row in await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE name LIKE 'local_info%'")
          .get())
        row.read<String>('name')
    };
    expect(names, containsAll(CommunityInfoSql.tables));
  });
}
