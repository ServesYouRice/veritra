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

  final variants = <String, Future<LocalStore> Function(Directory)>{
    'in-memory store': (_) async => MemoryLocalStore(),
    'Drift store': (directory) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      return SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
      );
    },
  };

  for (final variant in variants.entries) {
    group(variant.key, skip: skip, () {
      late Directory directory;
      late _Pair pair;

      setUp(() async {
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
        if (await directory.exists()) await directory.delete(recursive: true);
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
              'type': 'pin',
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
              'type': 'poll',
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
  }
  group('a storage failure after an invalid payload (Drift)', skip: skip, () {
    test('rolls everything back, and the retry commits the same row', () async {
      final directory =
          await Directory.systemTemp.createTemp('veritra-policy-inject-');
      addTearDown(() => directory.delete(recursive: true));
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      var armed = false;
      final store = SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        mlsCommitFailureInjector: (stage) async {
          if (armed && stage == MlsCommitStage.afterMessageEffects) {
            armed = false;
            throw StateError('injected storage failure');
          }
        },
      );
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

  static Future<_Pair> start(
      NativeCryptoBindings bindings, LocalStore store) async {
    final bob = NativeCryptoService(bindings: bindings, localStore: store);
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
          {String senderDeviceId = _senderDevice}) =>
      ReceivedMessageEnvelope(
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
