// W8 step 0: the receive policy (docs/crypto.md, rules P1-P6).
//
// A real native MLS sender encrypts hand-built payloads for a receiver whose
// store is either the in-memory twin or the Drift (SQLite) store. Needs
// VERITRA_CRYPTO_LIBRARY like native_outbox_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart'
    show quotedPreview;
import 'package:private_messenger/l10n/app_localizations_en.dart';
import 'package:private_messenger/crypto/app_payload.dart' show FrankingPolicy;
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

const _conversation = 'conv_11111111111111111111111111111111';
const _otherConversation = 'conv_99999999999999999999999999999999';
const _senderDevice = 'dev_alice';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final inCi = Platform.environment['CI'] == 'true';
  final skip = configured == null && !inCi
      ? 'native crypto library absent: set VERITRA_CRYPTO_LIBRARY'
      : false;
  final databases = <EncryptedLocalDatabase>[];
  MlsCommitFailureInjector? boundedFailure;

  final variants = <String, Future<LocalStore> Function(Directory)>{
    'in-memory store': (_) async => MemoryLocalStore(),
    'Drift store': (directory) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      return SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        mlsCommitFailureInjector: (stage) async {
          await boundedFailure?.call(stage);
        },
        databaseFactory: (file, key) {
          final db = openEncryptedLocalDatabase(file, key);
          databases.add(db);
          return db;
        },
      );
    },
  };

  for (final variant in variants.entries) {
    group(variant.key, skip: skip, () {
      late Directory directory;
      late _Pair pair;

      setUp(() async {
        boundedFailure = null;
        directory = await Directory.systemTemp.createTemp('veritra-policy-');
        final store = await variant.value(directory);
        pair = await _Pair.start(
          NativeCryptoBindings.open(
              configured ?? fail('set VERITRA_CRYPTO_LIBRARY')),
          store,
        );
      });

      tearDown(() async {
        await pair.dispose();
        for (final db in databases) {
          await db.close();
        }
        databases.clear();
        await SecureLocalStore.releaseInstanceLocks();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      test(
          'bounded cancellation preserves ratchet, cursor and history for retry',
          () async {
        for (final stage in variant.key == 'Drift store'
            ? [MlsCommitStage.afterState, MlsCommitStage.afterMessageEffects]
            : <MlsCommitStage?>[null]) {
          final before = (await pair.store.loadCryptoState())!;
          final cursor = await pair.store.loadSyncCursor();
          final beforeMessages = await pair.messages();
          var active = stage != null;
          final action = 'bounded_${stage?.name ?? 'entry'}';
          final item = pair.envelope(
              pair.alice.encrypt(_conversation,
                  _frame(_payload('text', action, actionId: action))),
              action);
          final event = ++pair.events;
          boundedFailure = (at) async {
            if (at == stage) active = false;
          };
          void fence() {
            if (!active) throw StateError('test permit revoked');
          }

          await expectLater(
              pair.bob.processApplicationMessageBounded(item, event,
                  checkCanCommit: fence),
              throwsStateError);
          final unchanged = (await pair.store.loadCryptoState())!;
          expect(unchanged.counter, before.counter);
          expect(unchanged.sealedState, before.sealedState);
          expect(await pair.store.loadSyncCursor(), cursor);
          expect(await pair.messages(), beforeMessages);
          expect(
              await pair.store
                  .hasProcessedMlsMessage('application:$event:${item.id}'),
              isFalse);
          boundedFailure = null;
          active = true;
          expect(
              utf8.decode((await pair.bob.processApplicationMessageBounded(
                  item, event,
                  checkCanCommit: fence))!),
              action);
          expect(await pair.store.loadSyncCursor(), event);
          expect(
              await pair.store
                  .hasProcessedMlsMessage('application:$event:${item.id}'),
              isTrue);
        }
      });

      test('bounded existing activation cannot create pending enrollment state',
          () async {
        final empty = MemoryLocalStore();
        final service = NativeCryptoService(
            bindings: NativeCryptoBindings.open(
                configured ?? fail('set VERITRA_CRYPTO_LIBRARY')),
            localStore: empty);
        addTearDown(service.dispose);
        await service.createEnrollmentCredential(const EnrollmentReservation(
            id: 'pending',
            accountId: 'acct_pending',
            deviceId: 'dev_pending',
            challenge: [1, 2, 3]));
        await expectLater(
            service.activateExistingSessionBounded(
                const Session(
                    baseUrl: 'https://example.test',
                    token: 'fixture',
                    accountId: 'acct_pending',
                    deviceId: 'dev_pending'),
                checkCanCommit: () {}),
            throwsStateError);
        expect(await empty.loadCryptoState(), isNull);
        expect(await empty.loadSyncCursor(), 0);
      });

      test('an invalid message commits, then a normal one still decrypts',
          () async {
        final bad = await pair.receive(Uint8List(256)); // no VAP1 framing
        expect(bad.text, isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        final row = (await pair.messages())
            .singleWhere((m) => m.kind == LocalMessageKind.invalid);
        expect(row.key, 'invalid:${pair.events}:${bad.envelopeId}');
        expect(row.body, isNull);

        final good = await pair.receive(_frame(_payload('text', 'ok1')));
        expect(good.text, 'ok1');
        expect(await pair.store.loadSyncCursor(), pair.events);
        expect(
            (await pair.messages())
                .where((m) => m.kind == LocalMessageKind.text),
            hasLength(1));
      });

      test('an unsupported message keeps its JSON, then a normal one decrypts',
          () async {
        final json = jsonEncode(<String, Object?>{
          ..._head(2, 'a1'),
          'type': 'sticker',
          'future_top': 1,
          'body': <String, Object?>{'id': 'x'},
        });
        final result = await pair.receive(_frame(json), actionId: 'a1');
        expect(result.text, isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        final row = (await pair.messages()).single;
        expect(row.kind, LocalMessageKind.unsupported);
        expect(row.key, messageKey(_senderDevice, 'a1'));
        expect(row.body, json);

        final good = await pair.receive(_frame(_payload('text', 'ok2')));
        expect(good.text, 'ok2');
        expect(await pair.store.loadSyncCursor(), pair.events);
      });

      test('the author deletes an unsupported row and its raw JSON goes',
          () async {
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(2, 'u1'),
              'type': 'sticker',
              'body': <String, Object?>{'id': 'x'},
            })),
            actionId: 'u1');
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'd1'),
              'type': 'delete',
              'body': <String, Object?>{
                'message_id': messageKey(_senderDevice, 'u1')
              },
            })),
            actionId: 'd1');
        final row = (await pair.messages())
            .singleWhere((m) => m.key == messageKey(_senderDevice, 'u1'));
        expect(row.body, isNull);
        expect(row.deletedAt, isNotNull);
      });

      test('a signal from a sibling device (wrong sender account) is dropped',
          () async {
        final before = (await pair.store.loadCryptoState())!.counter;
        final dropped = await pair.callSignal(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'sib'),
              'type': 'callSignal',
              'body': <String, Object?>{'signal': <String, Object?>{}},
            })),
            actionId: 'sib',
            createdBy: 'acct_carol');
        expect(dropped, isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        expect((await pair.store.loadCryptoState())!.counter, before + 1);
        expect(await pair.messages(), isEmpty);
        final next = await pair.callSignal(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'ok'),
              'type': 'callSignal',
              'body': <String, Object?>{
                'signal': <String, Object?>{'k': 2}
              },
            })),
            actionId: 'ok');
        expect(next, <String, Object?>{'k': 2});
      });

      test('reactions apply only to live text or attachment rows', () async {
        await pair.receive(_frame(_payload('text', 'live', actionId: 't1')),
            actionId: 't1');
        await pair.receive(_frame(_payload('text', 'gone', actionId: 't2')),
            actionId: 't2');
        await pair.receive(_frame(_reaction('t2-delete', 'delete', 't2')),
            actionId: 't2-delete');
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(2, 'u2'),
              'type': 'sticker',
              'body': <String, Object?>{},
            })),
            actionId: 'u2');
        for (final target in <String>['t1', 't2', 'u2', 'missing']) {
          await pair.receive(
              _frame(
                  _reaction('r-$target', 'reaction', target, reaction: '👍')),
              actionId: 'r-$target');
        }
        final reactions = await pair.store.loadReactions(_conversation);
        expect(reactions.map((r) => r.targetKey),
            <String>[messageKey(_senderDevice, 't1')]);
      });

      test('deleting a hidden unsupported row keeps it hidden', () async {
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(2, 'h1'),
              'type': 'admin_delete',
              'hidden': true,
              'body': <String, Object?>{'message_id': 'x'},
            })),
            actionId: 'h1');
        await pair.receive(_frame(_reaction('h-del', 'delete', 'h1')),
            actionId: 'h-del');
        final row = (await pair.messages())
            .singleWhere((m) => m.key == messageKey(_senderDevice, 'h1'));
        expect(row.deletedAt, isNotNull);
        expect(row.body, '{"hidden":true}');
        expect(row.senderHidden, true);
      });

      test('a reply to a placeholder row never quotes its JSON', () {
        final l10n = AppLocalizationsEn();
        LocalMessage row(String kind, {String? body}) => LocalMessage(
            key: 'k',
            conversationId: _conversation,
            senderAccountId: 'acct_alice',
            senderDeviceId: _senderDevice,
            kind: kind,
            body: body,
            createdAt: 0,
            state: LocalMessageState.received);
        expect(
            quotedPreview(
                l10n, row(LocalMessageKind.unsupported, body: '{"v":2}')),
            l10n.chatMessageUnsupported);
        expect(quotedPreview(l10n, row(LocalMessageKind.invalid)),
            l10n.chatMessageInvalid);
        expect(quotedPreview(l10n, row(LocalMessageKind.unverifiable)),
            l10n.chatMessageInvalid);
      });

      test('v1 stays strict and an unknown v1 type is unsupported', () async {
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'e1'),
              'type': 'text',
              'extra': 1,
              'body': <String, Object?>{'text': 'x'},
            })),
            actionId: 'e1');
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'e2'),
              'type': 'text',
              'body': <String, Object?>{'text': 'x', 'extra': 1},
            })),
            actionId: 'e2');
        await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'e3'),
              'type': 'admin_delete',
              'body': <String, Object?>{},
            })),
            actionId: 'e3');
        final kinds = (await pair.messages()).map((m) => m.kind).toList()
          ..sort();
        expect(kinds, <String>['invalid', 'invalid', 'unsupported']);
      });

      test('a call_signal inside a message envelope is invalid (P1)', () async {
        final result = await pair.receive(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'c1'),
              'type': 'callSignal',
              'body': <String, Object?>{'signal': <String, Object?>{}},
            })),
            actionId: 'c1');
        expect(result.text, isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        expect((await pair.messages()).single.kind, LocalMessageKind.invalid);
        expect((await pair.receive(_frame(_payload('text', 'next')))).text,
            'next');
      });

      test('a non-call payload on the call path is dropped (P4)', () async {
        final before = (await pair.store.loadCryptoState())!.counter;
        final signal = await pair.callSignal(_frame(_payload('text', 'hi')));
        expect(signal, isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        expect((await pair.store.loadCryptoState())!.counter, before + 1);
        expect(await pair.messages(), isEmpty);

        // A broken payload is dropped the same way; the next signal works.
        expect(await pair.callSignal(Uint8List(256)), isNull);
        final ok = await pair.callSignal(
            _frame(jsonEncode(<String, Object?>{
              ..._head(1, 'sig'),
              'type': 'callSignal',
              'body': <String, Object?>{
                'signal': <String, Object?>{'k': 1}
              },
            })),
            actionId: 'sig');
        expect(ok, <String, Object?>{'k': 1});
        expect(await pair.store.loadSyncCursor(), pair.events);
      });

      test('a context mismatch on a relabelled key is keyed by the event (P3)',
          () async {
        await pair.receive(_frame(_payload('text', 'first', actionId: 'k1')),
            actionId: 'k1');
        // The envelope claims action ID k1, the payload says k2.
        final result = await pair.receive(
            _frame(_payload('text', 'forged', actionId: 'k2')),
            actionId: 'k1');
        expect(result.text, isNull);
        final rows = await pair.messages();
        final existing =
            rows.singleWhere((m) => m.key == messageKey(_senderDevice, 'k1'));
        expect(existing.body, 'first');
        expect(existing.kind, LocalMessageKind.text);
        final invalid =
            rows.singleWhere((m) => m.kind == LocalMessageKind.invalid);
        expect(invalid.key, 'invalid:${pair.events}:${result.envelopeId}');
        expect(await pair.store.loadSyncCursor(), pair.events);

        // A payload for another conversation is invalid as well.
        await pair.receive(
            _frame(_payload('text', 'x', conversationId: _otherConversation)));
        expect(
            (await pair.messages())
                .where((m) => m.kind == LocalMessageKind.invalid),
            hasLength(2));
      });

      test('a franked message must match the envelope commitment (C6)',
          () async {
        final bindings = NativeCryptoBindings.open(
            configured ?? fail('set VERITRA_CRYPTO_LIBRARY'));
        final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
        String canonical(String action, String text) =>
            jsonEncode(<String, Object?>{
              ..._head(2, action),
              'type': 'text',
              'body': <String, Object?>{'text': text},
            });
        Uint8List commitFor(String action, String json) => bindings.frankCommit(
            key: key,
            conversationId: _conversation,
            senderDeviceId: _senderDevice,
            actionId: action,
            payload: Uint8List.fromList(utf8.encode(json)));
        String wire(String json, [String? member]) =>
            '${json.substring(0, json.length - 1)},'
            '"frank":${member ?? '{"k":"${base64Encode(key)}"}'}}';
        Future<_Received> deliver(String action, String text,
            {List<int>? commit,
            bool drop = false,
            String? member,
            String? commitAction}) async {
          final json = canonical(action, text);
          final item = pair.envelope(
              pair.alice.encrypt(_conversation, _frame(wire(json, member))),
              action,
              frankCommit: drop
                  ? null
                  : (commit ?? commitFor(commitAction ?? action, json)));
          final plain =
              await pair.bob.processApplicationMessage(item, ++pair.events);
          return _Received(plain == null ? null : utf8.decode(plain), item.id);
        }

        final first = await deliver('f1', 'franked ok');
        expect(first.text, 'franked ok');
        // The receiver keeps kf and the exact P with the message (schema 19),
        // so it can report it: they recompute the sender's commitment.
        final reveal = (await pair.store
            .loadFrankReveal(messageKey(_senderDevice, 'f1')))!;
        expect(reveal.frankKey, key);
        expect(reveal.payload, utf8.encode(canonical('f1', 'franked ok')));
        expect(reveal.envelopeId, first.envelopeId);
        expect(reveal.conversationId, _conversation);
        expect(
            bindings.frankCommit(
                key: Uint8List.fromList(reveal.frankKey),
                conversationId: _conversation,
                senderDeviceId: _senderDevice,
                actionId: 'f1',
                payload: Uint8List.fromList(reveal.payload)),
            commitFor('f1', canonical('f1', 'franked ok')));

        final flipped = commitFor('f2', canonical('f2', 'flipped'));
        flipped[0] ^= 1;
        expect((await deliver('f2', 'flipped', commit: flipped)).text, isNull);
        // A server that strips the commitment.
        expect((await deliver('f3', 'stripped', drop: true)).text, isNull);
        // A short commitment is not a commitment.
        expect(
            (await deliver('f4', 'short', commit: List<int>.filled(31, 7)))
                .text,
            isNull);
        // A commitment for another action of the same sender.
        expect(
            (await deliver('f5', 'rebound', commitAction: 'f1')).text, isNull);
        // A frank member that is not in the one fixed form.
        expect((await deliver('f6', 'spelled', member: '{"k":"AAAA"}')).text,
            isNull);
        expect(
            (await deliver('f7', 'extra',
                    member: '{"k":"${base64Encode(key)}","x":1}'))
                .text,
            isNull);

        // Sync moved past every refusal, and each left an invalid row.
        expect(await pair.store.loadSyncCursor(), pair.events);
        final rows = await pair.messages();
        expect(rows.where((m) => m.kind == LocalMessageKind.invalid),
            hasLength(6));
        expect(
            rows
                .where((m) => m.kind == LocalMessageKind.text)
                .map((m) => m.body),
            <String?>['franked ok']);

        // Nothing was kept for a refused message.
        for (final action in ['f2', 'f3', 'f4', 'f5', 'f6', 'f7']) {
          expect(
              await pair.store
                  .loadFrankReveal(messageKey(_senderDevice, action)),
              isNull,
              reason: action);
        }

        // No frank member is accepted, with or without an envelope
        // commitment: an older app's message, or a hidden type (G5).
        expect((await pair.receive(_frame(_payload('text', 'plain')))).text,
            'plain');
        expect(
            await pair.store.loadFrankReveal(messageKey(_senderDevice, 'auto')),
            isNull);
        final unfranked = pair.envelope(
            pair.alice.encrypt(
                _conversation, _frame(_payload('text', 'x', actionId: 'u1'))),
            'u1',
            frankCommit: List<int>.filled(32, 9));
        expect(
            utf8.decode((await pair.bob
                .processApplicationMessage(unfranked, ++pair.events))!),
            'x');
      });

      test('a malformed envelope stops before decryption (P2)', () async {
        final counter = (await pair.store.loadCryptoState())!.counter;
        final cursor = await pair.store.loadSyncCursor();
        final framed = _frame(_payload('text', 'late'));
        final ciphertext = pair.alice.encrypt(_conversation, framed);
        final long = 'd' * 200;
        await expectLater(
            pair.bob.processApplicationMessage(
                pair.envelope(ciphertext, 'auto', senderDeviceId: long),
                pair.events + 1),
            throwsA(isA<FormatException>()));
        expect((await pair.store.loadCryptoState())!.counter, counter);
        expect(await pair.store.loadSyncCursor(), cursor);
        // No ratchet step was used: the same ciphertext still decrypts.
        final text = await pair.bob.processApplicationMessage(
            pair.envelope(ciphertext, 'auto'), ++pair.events);
        expect(utf8.decode(text!), 'late');
      });
    });

    group('${variant.key}, refusing unfranked payloads', skip: skip, () {
      late Directory directory;
      late _Pair pair;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('veritra-refuse-');
        final store = await variant.value(directory);
        pair = await _Pair.start(
          NativeCryptoBindings.open(
              configured ?? fail('set VERITRA_CRYPTO_LIBRARY')),
          store,
          policy: const FrankingPolicy(acceptUnfranked: false),
        );
      });

      tearDown(() async {
        await pair.dispose();
        for (final db in databases) {
          await db.close();
        }
        databases.clear();
        await SecureLocalStore.releaseInstanceLocks();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      test('the switch that refuses unfranked payloads (D95)', () async {
        final bindings = NativeCryptoBindings.open(
            configured ?? fail('set VERITRA_CRYPTO_LIBRARY'));
        final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 9));
        Future<_Received> franked(String action, String text) async {
          final json = jsonEncode(<String, Object?>{
            ..._head(2, action),
            'type': 'text',
            'body': <String, Object?>{'text': text},
          });
          final wire = '${json.substring(0, json.length - 1)},'
              '"frank":{"k":"${base64Encode(key)}"}}';
          final item = pair.envelope(
              pair.alice.encrypt(_conversation, _frame(wire)), action,
              frankCommit: bindings.frankCommit(
                  key: key,
                  conversationId: _conversation,
                  senderDeviceId: _senderDevice,
                  actionId: action,
                  payload: Uint8List.fromList(utf8.encode(json))));
          final plain =
              await pair.bob.processApplicationMessage(item, ++pair.events);
          return _Received(plain == null ? null : utf8.decode(plain), item.id);
        }

        // Franked: accepted, and kept for a report.
        expect((await franked('s1', 'franked')).text, 'franked');
        expect(
            await pair.store.loadFrankReveal(messageKey(_senderDevice, 's1')),
            isNotNull);

        // Unfranked: refused as an invalid row, and sync still moves on.
        expect(
            (await pair.receive(_frame(_payload('text', 'plain')),
                    actionId: 's2'))
                .text,
            isNull);
        expect(await pair.store.loadSyncCursor(), pair.events);
        expect(
            await pair.store.loadFrankReveal(messageKey(_senderDevice, 's2')),
            isNull);
        // An unfranked payload of a type this app understands is refused
        // even when the envelope carries a commitment.
        final unfrankedWithCommit = pair.envelope(
            pair.alice.encrypt(
                _conversation, _frame(_payload('text', 'x', actionId: 's3'))),
            's3',
            frankCommit: List<int>.filled(32, 9));
        expect(
            await pair.bob
                .processApplicationMessage(unfrankedWithCommit, ++pair.events),
            isNull);

        // A hidden payload this app does not understand is never franked
        // (design item 9, the C7 hidden types): exempt after decoding.
        final hidden = jsonEncode(<String, Object?>{
          ..._head(2, 's4'),
          'type': 'history_change',
          'hidden': true,
          'body': <String, Object?>{'x': 1},
        });
        expect(
            (await pair.receive(_frame(hidden), actionId: 's4')).text, isNull);
        // An unknown type that is not hidden is not exempt.
        final visible = jsonEncode(<String, Object?>{
          ..._head(2, 's5'),
          'type': 'sticker',
          'body': <String, Object?>{'id': 'x'},
        });
        await pair.receive(_frame(visible), actionId: 's5');

        final kinds = {
          for (final row in await pair.messages()) row.key: row.kind
        };
        expect(kinds[messageKey(_senderDevice, 's1')], LocalMessageKind.text);
        expect(kinds[messageKey(_senderDevice, 's4')],
            LocalMessageKind.unsupported);
        expect(kinds.values.where((k) => k == LocalMessageKind.invalid),
            hasLength(3));
        expect(kinds.containsKey(messageKey(_senderDevice, 's5')), isFalse);
        expect(kinds.containsKey(messageKey(_senderDevice, 's2')), isFalse);
      });
    });
  }
  group('a storage failure after an invalid payload (Drift)', skip: skip, () {
    test('rolls everything back, and the retry commits the same row', () async {
      final directory =
          await Directory.systemTemp.createTemp('veritra-policy-inject-');
      addTearDown(() async {
        await SecureLocalStore.releaseInstanceLocks();
        await directory.delete(recursive: true);
      });
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      var armed = false;
      final store = SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, key) {
          final db = openEncryptedLocalDatabase(file, key);
          databases.add(db);
          return db;
        },
        mlsCommitFailureInjector: (stage) async {
          if (armed && stage == MlsCommitStage.afterMessageEffects) {
            armed = false;
            throw StateError('injected storage failure');
          }
        },
      );
      addTearDown(() async {
        for (final db in databases) {
          await db.close();
        }
        databases.clear();
      });
      final pair = await _Pair.start(
          NativeCryptoBindings.open(
              configured ?? fail('set VERITRA_CRYPTO_LIBRARY')),
          store);
      addTearDown(pair.dispose);
      armed = true;
      final counter = (await store.loadCryptoState())!.counter;
      final cursor = await store.loadSyncCursor();
      final item = pair.envelope(
          pair.alice.encrypt(_conversation, Uint8List(256)), 'auto');
      await expectLater(pair.bob.processApplicationMessage(item, cursor + 1),
          throwsA(anything));
      expect((await store.loadCryptoState())!.counter, counter);
      expect(await store.loadSyncCursor(), cursor);
      expect(await pair.messages(), isEmpty);

      await pair.bob.processApplicationMessage(item, cursor + 1);
      pair.events = cursor + 1;
      final rows = await pair.messages();
      expect(rows.single.kind, LocalMessageKind.invalid);
      expect(rows.single.key, 'invalid:${cursor + 1}:${item.id}');
      expect(await store.loadSyncCursor(), cursor + 1);
      expect(
          (await pair.receive(_frame(_payload('text', 'next')))).text, 'next');
    });
  });
}

Map<String, Object?> _head(int version, String actionId,
        {String conversationId = _conversation}) =>
    <String, Object?>{
      'v': version,
      'conversation_id': conversationId,
      'sender_device_id': _senderDevice,
      'action_id': actionId,
    };

String _payload(String type, String text,
        {String actionId = 'auto', String conversationId = _conversation}) =>
    jsonEncode(<String, Object?>{
      ..._head(1, actionId, conversationId: conversationId),
      'type': type,
      'body': <String, Object?>{'text': text},
    });

String _reaction(String actionId, String type, String target,
        {String? reaction}) =>
    jsonEncode(<String, Object?>{
      ..._head(1, actionId),
      'type': type,
      'body': <String, Object?>{
        'message_id': messageKey(_senderDevice, target),
        if (reaction != null) 'reaction': reaction,
      },
    });

/// VAP1, a big-endian u32 length, the JSON, zero padding to 256 bytes.
Uint8List _frame(String json) {
  final bytes = utf8.encode(json);
  final total = ((8 + bytes.length + 255) ~/ 256) * 256;
  final out = Uint8List(total)..setRange(0, 4, 'VAP1'.codeUnits);
  ByteData.sublistView(out).setUint32(4, bytes.length, Endian.big);
  out.setRange(8, 8 + bytes.length, bytes);
  return out;
}

class _Received {
  _Received(this.text, this.envelopeId);

  final String? text;
  final String envelopeId;
}

class _Pair {
  _Pair(this.alice, this.bob, this.store);

  final NativeCryptoDevice alice;
  final NativeCryptoService bob;
  final LocalStore store;
  int events = 0;
  int _counter = 0;

  static Future<_Pair> start(NativeCryptoBindings bindings, LocalStore store,
      {FrankingPolicy policy = const FrankingPolicy()}) async {
    final bob = NativeCryptoService(
        bindings: bindings, localStore: store, frankingPolicy: policy);
    await bob.createEnrollmentCredential(const EnrollmentReservation(
      id: 'res_bob',
      accountId: 'acct_bob',
      deviceId: 'dev_bob',
      challenge: <int>[1, 2, 3],
    ));
    await bob.activateSession(const Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_bob',
      deviceId: 'dev_bob',
    ));
    final alice = bindings.createDevice('acct_alice', _senderDevice);
    alice.createEnrollmentCredential(const <int>[1, 2, 3]);
    alice.createGroup(_conversation);
    final staged = alice.stageCommit(_conversation, adds: [
      (
        keyPackage: (await bob.createReplenishmentKeyPackages(count: 1)).single,
        accountId: 'acct_bob',
        deviceId: 'dev_bob',
      ),
    ]);
    alice.mergePendingCommit(_conversation);
    final pair = _Pair(alice, bob, store);
    await bob.processMlsMessage(MlsMessage(
      id: 'mls_welcome',
      conversationId: _conversation,
      senderAccountId: 'acct_alice',
      senderDeviceId: _senderDevice,
      kind: 'welcome',
      payload: staged.welcome,
      idempotencyKey: 'welcome',
      syncEventId: ++pair.events,
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: 'dev_bob',
    ));
    return pair;
  }

  ReceivedMessageEnvelope envelope(List<int> ciphertext, String actionId,
          {String senderDeviceId = _senderDevice, List<int>? frankCommit}) =>
      ReceivedMessageEnvelope(
        frankCommit: frankCommit,
        id: 'srv_${++_counter}',
        conversationId: _conversation,
        senderAccountId: 'acct_alice',
        senderDeviceId: senderDeviceId,
        idempotencyKey: actionId,
        ciphertext: ciphertext,
        cryptoProtocol: 'mls10-openmls-v1',
        createdAt: DateTime.utc(2026, 10, 24),
      );

  /// Encrypts [framed] and hands it to Bob as the next sync event. The
  /// envelope's idempotency key is [actionId], 'auto' by default.
  Future<_Received> receive(Uint8List framed,
      {String actionId = 'auto'}) async {
    final item = envelope(alice.encrypt(_conversation, framed), actionId);
    final text = await bob.processApplicationMessage(item, ++events);
    return _Received(text == null ? null : utf8.decode(text), item.id);
  }

  Future<Map<String, Object?>?> callSignal(Uint8List framed,
      {String actionId = 'auto', String createdBy = 'acct_alice'}) {
    final call = CallSession(
      id: 'call_1',
      conversationId: _conversation,
      createdBy: createdBy,
      invitedAccountId: 'acct_bob',
      state: 'ringing',
      version: 1,
      metadata: <String, Object?>{
        'version': 1,
        'protocol': 'mls10-openmls-v1',
        'sender_device_id': _senderDevice,
        'action_id': actionId,
        'ciphertext': base64Encode(alice.encrypt(_conversation, framed)),
      },
      createdAt: DateTime.utc(2026, 10, 24),
    );
    return bob.processCallSignal(call, ++events);
  }

  Future<List<LocalMessage>> messages() => store.loadMessages(_conversation);

  Future<void> dispose() async {
    alice.close();
    await bob.dispose();
  }
}
