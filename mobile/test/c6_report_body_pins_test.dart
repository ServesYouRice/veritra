import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/report_body.dart';
import 'package:private_messenger/crypto/report_key_pins.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

/// C6 (D95): the report body sealed once per owner with the envelope id
/// inside, and the pinned owner report keys.

const _origin = 'https://chat.example.org';

List<int> _key(int fill) => List<int>.filled(32, fill);

FrankReveal _reveal() => FrankReveal(
      messageKey: 'dev_sender:action1',
      conversationId: 'conv_1',
      envelopeId: 'msg_envelope_secret_id',
      frankKey: _key(7),
      payload: utf8.encode('{"v":2,"type":"text","body":{"text":"hi"}}'),
    );

ReportRecipientKey _owner(String id, int fill, {int rev = 1}) =>
    ReportRecipientKey(inboxId: id, publicKey: _key(fill), keyRev: rev);

void main() {
  group('report body', () {
    test('round trips what a report reveals', () {
      final body = ReportBody.fromReveal(_reveal());
      expect(body.senderDeviceId, 'dev_sender');
      expect(body.actionId, 'action1');
      final decoded = ReportBody.decode(body.encode());
      expect(decoded.envelopeId, 'msg_envelope_secret_id');
      expect(decoded.conversationId, 'conv_1');
      expect(decoded.senderDeviceId, 'dev_sender');
      expect(decoded.actionId, 'action1');
      expect(decoded.payload, _reveal().payload);
      expect(decoded.frankKey, _key(7));
    });

    test('never prints the message or its key', () {
      expect(ReportBody.fromReveal(_reveal()).toString(),
          isNot(contains('envelope')));
      expect(_reveal().toString(), isNot(contains('hi')));
    });

    test('a message key without a device or an action is refused', () {
      for (final key in ['nocolon', ':action', 'device:']) {
        expect(
            () => ReportBody.fromReveal(FrankReveal(
                messageKey: key,
                conversationId: 'c',
                envelopeId: 'e',
                frankKey: _key(1),
                payload: const [1])),
            throwsFormatException,
            reason: key);
      }
    });

    test('decode bounds every field and refuses anything unknown', () {
      Map<String, Object?> good() => {
            'v': 1,
            'envelope_id': 'msg_1',
            'conversation_id': 'conv_1',
            'sender_device_id': 'dev_1',
            'action_id': 'a1',
            'payload': base64Encode(const [1, 2, 3]),
            'frank_key': base64Encode(_key(1)),
          };
      List<int> bytes(Map<String, Object?> m) => utf8.encode(jsonEncode(m));
      expect(ReportBody.decode(bytes(good())).actionId, 'a1');
      final cases = <String, Map<String, Object?>>{
        'version': {...good(), 'v': 2},
        'extra field': {...good(), 'note': 'x'},
        'missing field': (good()..remove('action_id')),
        'empty id': {...good(), 'envelope_id': ''},
        'long id': {...good(), 'conversation_id': 'c' * 129},
        'not a string': {...good(), 'sender_device_id': 5},
        'short key': {...good(), 'frank_key': base64Encode(_key(1).sublist(1))},
        'bad base64': {...good(), 'payload': '***'},
        'empty payload': {...good(), 'payload': ''},
        'huge payload': {
          ...good(),
          'payload': base64Encode(List<int>.filled(64 * 1024 + 1, 1))
        },
      };
      for (final entry in cases.entries) {
        expect(
            () => ReportBody.decode(bytes(entry.value)), throwsFormatException,
            reason: entry.key);
      }
      for (final raw in [
        <int>[],
        utf8.encode('[]'),
        utf8.encode('not json'),
        [0xff, 0xfe],
      ]) {
        expect(() => ReportBody.decode(raw), throwsFormatException);
      }
    });
  });

  group('unfranked policy (D95)', () {
    const accepting = FrankingPolicy();
    const refusing = FrankingPolicy(acceptUnfranked: false);
    final text = DecodedAppPayload(DecryptedAppPayload(
        type: AppPayloadType.text, actionId: 'a', body: const {'text': 'x'}));
    final pin = DecodedAppPayload(DecryptedAppPayload(
        type: AppPayloadType.pin, actionId: 'a', body: const {}));
    const hiddenUnknown = UnsupportedAppPayload(rawJson: '{}', hidden: true);
    const visibleUnknown = UnsupportedAppPayload(rawJson: '{}', hidden: false);

    test('accepts every classified payload while the switch is on', () {
      for (final outcome in [text, pin, hiddenUnknown, visibleUnknown]) {
        expect(accepting.acceptsUnfranked(outcome), isTrue);
      }
      expect(accepting.acceptsUnfranked(const InvalidAppPayload()), isTrue);
      expect(const FrankingPolicy().acceptUnfranked, isTrue);
    });

    test('refuses a known type and a visible unknown one when it is off', () {
      expect(refusing.acceptsUnfranked(text), isFalse);
      expect(refusing.acceptsUnfranked(pin), isFalse);
      expect(refusing.acceptsUnfranked(visibleUnknown), isFalse);
      expect(refusing.acceptsUnfranked(const InvalidAppPayload()), isFalse);
    });

    test('keeps the C7 hidden types exempt when it is off', () {
      expect(refusing.acceptsUnfranked(hiddenUnknown), isTrue);
      expect(FrankingPolicy.unfrankedPayloadTypes, {
        // C7 hidden types, by enum name (their wire names are snake_case).
        'historyChange',
        'historySync',
        'historySyncRequest',
        // C3: info payloads are never reportable.
        'infoKey',
        'infoKeyRequest',
        'infoUpdate',
        // C4: a leave proof is never reportable.
        'memberLeave',
        // C6: moderator report key announcements and requests.
        'reportKey',
        'reportKeyRequest',
        // L2-5: an own-device alert is never reportable.
        'deviceListAlert',
      });
      // The policy matches decoded payloads by AppPayloadType.name, so every
      // entry must name a real type, and every C7 type must be exempt.
      final names = {for (final type in AppPayloadType.values) type.name};
      expect(names.containsAll(FrankingPolicy.unfrankedPayloadTypes), isTrue);
      for (final type in c7PayloadTypes) {
        expect(
            refusing.acceptsUnfranked(DecodedAppPayload(DecryptedAppPayload(
                type: type, actionId: 'a', body: const {}))),
            isTrue,
            reason: type.name);
      }
    });
  });

  group('pinned owner report keys', () {
    late MemoryLocalStore store;
    late ReportKeyPins pins;
    final now = DateTime.utc(2026, 11, 7);

    setUp(() {
      store = MemoryLocalStore();
      pins = ReportKeyPins(store, _origin, clock: () => now);
    });

    test('a key nobody pinned is unpinned and cannot be sealed to', () async {
      final check = await pins.check([_owner('acct_a', 1)]);
      expect(check.recipients.single.status, ReportKeyStatus.unpinned);
      expect(check.allPinned, isFalse);
      await expectLater(pins.requirePinned([_owner('acct_a', 1)]),
          throwsA(isA<ReportKeyNotPinned>()));
      expect(await store.loadReportKeyPins(_origin), isEmpty);
    });

    test('pinning is explicit; then the same key is pinned', () async {
      await pins.pin(_owner('acct_a', 1));
      await pins.pin(_owner('acct_b', 2, rev: 3));
      final check =
          await pins.requirePinned([_owner('acct_a', 1), _owner('acct_b', 2)]);
      expect(check.allPinned, isTrue);
      expect(check.missing, isEmpty);
      final stored = (await store.loadReportKeyPin(_origin, 'acct_b'))!;
      expect(stored.keyRev, 3);
      expect(stored.pinnedAt, now.millisecondsSinceEpoch);
      // A new revision of the same key is still the pinned key.
      expect(
          (await pins.check([_owner('acct_a', 1, rev: 9)]))
              .recipients
              .single
              .status,
          ReportKeyStatus.pinned);
    });

    test('a substituted key is refused until it is pinned again', () async {
      await pins.pin(_owner('acct_a', 1));
      final changed = [_owner('acct_a', 9, rev: 2)];
      final check = await pins.check(changed);
      expect(check.recipients.single.status, ReportKeyStatus.changed);
      expect(check.recipients.single.pin!.publicKey, _key(1));
      await expectLater(
          pins.requirePinned(changed), throwsA(isA<ReportKeyNotPinned>()));
      // The old pin is untouched by the refusal.
      expect((await store.loadReportKeyPin(_origin, 'acct_a'))!.publicKey,
          _key(1));
      await pins.pin(changed.single);
      expect((await pins.requirePinned(changed)).allPinned, isTrue);
    });

    test('an owner the server lists that was never pinned blocks the report',
        () async {
      await pins.pin(_owner('acct_a', 1));
      // A server that adds an owner key of its own.
      final check =
          await pins.check([_owner('acct_a', 1), _owner('acct_x', 8)]);
      expect(check.allPinned, isFalse);
      expect(check.recipients.map((r) => r.status),
          [ReportKeyStatus.pinned, ReportKeyStatus.unpinned]);
    });

    test('a pinned owner the server no longer lists is reported', () async {
      await pins.pin(_owner('acct_a', 1));
      await pins.pin(_owner('acct_b', 2));
      final check = await pins.check([_owner('acct_a', 1)]);
      expect(check.allPinned, isTrue);
      expect(check.missing.map((p) => p.ownerAccountId), ['acct_b']);
      await pins.forget('acct_b');
      expect((await pins.check([_owner('acct_a', 1)])).missing, isEmpty);
    });

    test('no recipients is not pinned', () async {
      expect((await pins.check(const [])).allPinned, isFalse);
    });

    test('pins are per origin, and the origin is canonical', () async {
      await pins.pin(_owner('acct_a', 1));
      final same = ReportKeyPins(store, 'HTTPS://chat.example.org/');
      expect(same.origin, _origin);
      expect((await same.check([_owner('acct_a', 1)])).allPinned, isTrue);
      final other = ReportKeyPins(store, 'https://elsewhere.example.org');
      expect((await other.check([_owner('acct_a', 1)])).allPinned, isFalse);
      expect(
          () => ReportKeyPins(store, 'not an origin'), throwsFormatException);
    });

    test('the fingerprint is the key in groups of four', () {
      expect(
          reportKeyFingerprint(_key(0xab)), List.filled(16, 'ABAB').join('-'));
      expect(reportKeyFingerprint(const [1, 2, 255]), '0102-FF');
    });
  });

  group('one sealed copy per owner', () {
    late NativeCryptoBindings bindings;
    late NativeCryptoService crypto;
    setUp(() {
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      crypto = TestNativeCryptoService(
          bindings: bindings, localStore: MemoryLocalStore());
    });

    test(
      'each owner opens only its copy, and the envelope id is not in the '
      'clear',
      () async {
        final seeds = [
          await crypto.generateReportKeySeed(),
          await crypto.generateReportKeySeed(),
        ];
        final recipients = [
          for (var i = 0; i < 2; i++)
            ReportRecipientKey(
                inboxId: 'acct_owner_$i',
                publicKey: await crypto.reportPublicKey(seeds[i]),
                keyRev: i + 1),
        ];
        final body = ReportBody.fromReveal(_reveal());
        final copies = await sealReportCopies(
          crypto: crypto,
          inboxKind: reportInboxInstanceOwner,
          recipients: recipients,
          conversationId: 'conv_1',
          reportId: 'rpt_00000000000000000000000000000001',
          reporterAccountId: 'acct_reporter',
          body: body,
        );
        expect(copies, hasLength(2));
        expect(copies.map((c) => c.inboxId), ['acct_owner_0', 'acct_owner_1']);
        expect(copies.map((c) => c.keyRev), [1, 2]);
        // Two seals of one body differ (fresh HPKE randomness).
        expect(copies[0].sealed, isNot(copies[1].sealed));

        Uint8List aadFor(int i, {String? reportId, String? reporter}) =>
            reportAad(
              inboxKind: reportInboxInstanceOwner,
              inboxId: recipients[i].inboxId,
              recipientKey: recipients[i].publicKey,
              conversationId: 'conv_1',
              reportId: reportId ?? 'rpt_00000000000000000000000000000001',
              reporterAccountId: reporter ?? 'acct_reporter',
            );

        for (var i = 0; i < 2; i++) {
          // What goes to the server, as JSON, holds no envelope id, text or
          // key.
          final wire = jsonEncode(copies[i].toJson());
          expect(wire, isNot(contains('msg_envelope_secret_id')));
          expect(wire, isNot(contains(base64Encode(_key(7)))));
          expect(copies[i].toJson().keys,
              {'inbox_id', 'key_rev', 'recipient_public_key', 'sealed'});

          final opened = await crypto.openReport(
              seed: seeds[i], aad: aadFor(i), sealed: copies[i].sealed);
          final decoded = ReportBody.decode(opened);
          expect(decoded.envelopeId, 'msg_envelope_secret_id');
          expect(decoded.frankKey, _key(7));
          expect(decoded.payload, _reveal().payload);

          // Not another owner's key, not another report id, not another
          // reporter, not the other owner's aad.
          await expectLater(
              crypto.openReport(
                  seed: seeds[1 - i], aad: aadFor(i), sealed: copies[i].sealed),
              throwsA(anything));
          await expectLater(
              crypto.openReport(
                  seed: seeds[i],
                  aad: aadFor(i,
                      reportId: 'rpt_00000000000000000000000000000002'),
                  sealed: copies[i].sealed),
              throwsA(anything));
          await expectLater(
              crypto.openReport(
                  seed: seeds[i],
                  aad: aadFor(i, reporter: 'acct_other'),
                  sealed: copies[i].sealed),
              throwsA(anything));
          await expectLater(
              crypto.openReport(
                  seed: seeds[i], aad: aadFor(1 - i), sealed: copies[i].sealed),
              throwsA(anything));
        }
      },
      skip: nativeCryptoSkip(),
    );

    test('sealing to nobody is refused', () async {
      await expectLater(
          sealReportCopies(
            crypto: crypto,
            inboxKind: reportInboxInstanceOwner,
            recipients: const [],
            conversationId: 'conv_1',
            reportId: 'rpt_00000000000000000000000000000001',
            reporterAccountId: 'acct_reporter',
            body: ReportBody.fromReveal(_reveal()),
          ),
          throwsArgumentError);
    }, skip: nativeCryptoSkip());
  });
}
