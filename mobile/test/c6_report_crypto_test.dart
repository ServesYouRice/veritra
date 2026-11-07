import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// C6 (ABI 12): franking v1 wire form, the commitment and the report seal,
/// against testing/vectors/c6-franking-v1.json, which the Rust core and the
/// Go reference check too. A missing vector fails; it never skips.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/c6-franking-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final commitment = vector['commitment'] as Map<String, dynamic>;
  final report = vector['report_hpke'] as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  Uint8List utf(Object? value) => utf8.encode(value as String);

  /// The inner JSON of a framed payload: after `VAP1` and the u32 length.
  Uint8List inner(Uint8List padded) {
    final length = ByteData.sublistView(padded).getUint32(4, Endian.big);
    return Uint8List.sublistView(padded, 8, 8 + length);
  }

  final key = hex(commitment['key_hex']);
  final payload = utf(commitment['payload']);
  final wire = utf(commitment['wire_json']);
  final conversation = commitment['conversation_id'] as String;
  final device = commitment['sender_device_id'] as String;
  final action = commitment['action_id'] as String;

  group('report aad (condition G4)', () {
    final aadVector = jsonDecode(
      File('../testing/vectors/c6-report-aad-v2.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    Uint8List build(Map<String, dynamic> c) => reportAad(
          inboxKind: c['inbox_kind'] as String,
          inboxId: c['inbox_id'] as String,
          recipientKey: hex(c['recipient_key_hex']),
          conversationId: c['conversation_id'] as String,
          reportId: c['report_id'] as String,
          reporterAccountId: c['reporter_account_id'] as String,
        );

    test('matches the shared vector the Go server checks', () {
      final cases = (aadVector['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases.length, greaterThanOrEqualTo(2));
      for (final c in cases) {
        expect(build(c), hex(c['aad_hex']), reason: c['name'] as String);
      }
    });

    test('binds every field and refuses bad input', () {
      final base = (aadVector['cases'] as List).first as Map<String, dynamic>;
      final want = build(base);
      for (final field in const [
        'inbox_id',
        'conversation_id',
        'report_id',
        'reporter_account_id',
      ]) {
        final changed = Map<String, dynamic>.of(base)
          ..[field] = '${base[field]}x';
        expect(build(changed), isNot(want), reason: field);
      }
      final otherKey = Map<String, dynamic>.of(base)
        ..['recipient_key_hex'] = 'ff' * 32;
      expect(build(otherKey), isNot(want));
      final otherKind = Map<String, dynamic>.of(base)
        ..['inbox_kind'] = 'community';
      expect(build(otherKind), isNot(want));
      expect(
        () => build(Map<String, dynamic>.of(base)..['inbox_kind'] = 'mods'),
        throwsFormatException,
      );
      expect(
        () => build(Map<String, dynamic>.of(base)..['report_id'] = ''),
        throwsFormatException,
      );
      expect(
        () => build(
            Map<String, dynamic>.of(base)..['recipient_key_hex'] = 'ab' * 31),
        throwsFormatException,
      );
      // The Rust core takes at most 1024 bytes of aad.
      expect(want.length, lessThanOrEqualTo(1024));
    });
  });

  group('franking v1 wire form', () {
    test('encodeFranked writes the vector bytes and classifies as text', () {
      final codec = AppPayloadCodec();
      final encoded = codec.encodeFranked(
        type: AppPayloadType.text,
        conversationId: conversation,
        senderDeviceId: device,
        actionId: action,
        body: const <String, Object?>{'text': 'hi'},
        frankKey: key,
      );
      expect(encoded.canonical, payload);
      expect(inner(encoded.padded), wire);
      // P is the v2 encoding without `frank`: what a v2 receiver ignoring
      // the extra key (P6) reads anyway.
      final outcome = codec.classify(
        encoded.padded,
        conversationId: conversation,
        senderDeviceId: device,
        actionId: action,
      );
      expect(outcome, isA<DecodedAppPayload>());
      expect((outcome as DecodedAppPayload).payload.body['text'], 'hi');
    });

    test('splitFrank recovers P and kf from the vector', () {
      final split = splitFrank(wire);
      expect(split, isA<Franked>());
      expect((split as Franked).canonical, payload);
      expect(split.key, key);
      expect(splitFrank(payload), isA<Unfranked>());
      expect(frankWireJson(payload, key), wire);
    });

    test('frankOf reads a framed payload and never throws', () {
      final encoded = AppPayloadCodec().encodeFranked(
        type: AppPayloadType.text,
        conversationId: conversation,
        senderDeviceId: device,
        actionId: action,
        body: const <String, Object?>{'text': 'hi'},
        frankKey: key,
      );
      final franked = AppPayloadCodec.frankOf(encoded.padded);
      expect(franked, isA<Franked>());
      expect((franked as Franked).canonical, payload);
      expect(franked.key, key);
      final plain = AppPayloadCodec().encode(
        type: AppPayloadType.text,
        conversationId: conversation,
        senderDeviceId: device,
        actionId: action,
        body: const <String, Object?>{'text': 'hi'},
      );
      expect(AppPayloadCodec.frankOf(plain), isA<Unfranked>());
      expect(AppPayloadCodec.frankOf(Uint8List(256)), isA<MalformedFrank>());
      expect(AppPayloadCodec.frankOf(const <int>[]), isA<MalformedFrank>());
      final truncated = Uint8List.fromList(encoded.padded)
        ..[7] = 255; // a length that runs past the padded bytes
      expect(AppPayloadCodec.frankOf(truncated), isA<MalformedFrank>());
    });

    test('a v1 payload carrying frank is invalid on every receiver', () {
      final codec = AppPayloadCodec();
      final v1 = utf8.encode(utf8.decode(wire).replaceFirst('"v":2', '"v":1'));
      final padded = Uint8List((8 + v1.length + 255) ~/ 256 * 256)
        ..setAll(0, const [0x56, 0x41, 0x50, 0x31]);
      ByteData.sublistView(padded).setUint32(4, v1.length, Endian.big);
      padded.setRange(8, 8 + v1.length, v1);
      expect(
        codec.classify(
          padded,
          conversationId: conversation,
          senderDeviceId: device,
          actionId: action,
        ),
        isA<InvalidAppPayload>(),
      );
    });

    test('any other spelling of frank is malformed, never unfranked', () {
      // The cases live in the shared vector; Rust and Go check them too.
      final cases = (vector['malformed_frank'] as List).cast<String>();
      expect(cases.length, greaterThanOrEqualTo(11));
      for (final candidate in cases) {
        expect(
          splitFrank(utf8.encode(candidate)),
          isA<MalformedFrank>(),
          reason: candidate,
        );
      }
      // `frank` inside the body is not the reserved top-level member.
      final nested = vector['unfranked_frank_in_body'] as List;
      for (final candidate in nested.cast<String>()) {
        expect(splitFrank(utf8.encode(candidate)), isA<Unfranked>());
      }
    });

    test('extra commitment cases split and rebuild byte for byte', () {
      for (final raw in vector['commitment_cases'] as List) {
        final c = raw as Map<String, dynamic>;
        final split = splitFrank(utf(c['wire_json']));
        expect(split, isA<Franked>(), reason: c['name'] as String);
        expect((split as Franked).canonical, utf(c['payload']));
        expect(split.key, hex(c['key_hex']));
        expect(
          frankWireJson(utf(c['payload']), split.key),
          utf(c['wire_json']),
        );
      }
    });

    test('frankWireJson refuses bad input', () {
      expect(
        () => frankWireJson(payload, key.sublist(1)),
        throwsFormatException,
      );
      expect(() => frankWireJson(wire, key), throwsFormatException);
      // An empty object would produce `{,"frank":...}`, which is not JSON.
      expect(
        () => frankWireJson(utf8.encode('{}'), key),
        throwsFormatException,
      );
      expect(
        () => frankWireJson(utf8.encode('[1]'), key),
        throwsFormatException,
      );
    });

    test('commitments compare in full', () {
      final c = hex(commitment['commit_hex']);
      expect(frankCommitEquals(c, Uint8List.fromList(c)), isTrue);
      final other = Uint8List.fromList(c)..[31] ^= 1;
      expect(frankCommitEquals(c, other), isFalse);
      expect(frankCommitEquals(c, c.sublist(1)), isFalse);
      expect(generateFrankKey(), hasLength(frankKeyBytes));
    });
  });

  test('release crypto refuses every report operation', () async {
    final crypto = UnavailableCryptoService();
    final calls = <Future<Object?> Function()>[
      () => crypto.generateReportKeySeed(),
      () => crypto.reportPublicKey(Uint8List(32)),
      () => crypto.sealReport(
            recipientPublicKey: Uint8List(32),
            aad: const [1],
            plaintext: Uint8List(1),
          ),
      () => crypto.openReport(
            seed: Uint8List(32),
            aad: const [1],
            sealed: Uint8List(53),
          ),
      () => crypto.frankCommit(
            key: key,
            conversationId: conversation,
            senderDeviceId: device,
            actionId: action,
            payload: payload,
          ),
    ];
    for (final call in calls) {
      await expectLater(call(), throwsStateError);
    }
  });

  group('native ABI 12', () {
    late NativeCryptoBindings bindings;
    setUp(() {
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    });

    Matcher failsWith(NativeCryptoError kind) => throwsA(
          isA<NativeCryptoException>().having((e) => e.kind, 'kind', kind),
        );

    test(
      'commitment and report key match the shared vector',
      () {
        final commit = bindings.frankCommit(
          key: key,
          conversationId: conversation,
          senderDeviceId: device,
          actionId: action,
          payload: payload,
        );
        expect(commit, hex(commitment['commit_hex']));
        final seed = hex(report['seed_hex']);
        expect(bindings.reportPublicKey(seed), hex(report['public_hex']));
        expect(
          bindings.openReport(
            seed: seed,
            aad: utf(report['aad']),
            sealed: hex(report['sealed_hex']),
          ),
          utf(report['plaintext']),
        );
        for (final raw in vector['commitment_cases'] as List) {
          final c = raw as Map<String, dynamic>;
          expect(
            bindings.frankCommit(
              key: hex(c['key_hex']),
              conversationId: c['conversation_id'] as String,
              senderDeviceId: c['sender_device_id'] as String,
              actionId: c['action_id'] as String,
              payload: utf(c['payload']),
            ),
            hex(c['commit_hex']),
            reason: c['name'] as String,
          );
        }
        // Sealed by Go's crypto/hpke; Rust and Dart open it.
        final goSealed =
            vector['report_hpke_go_sealed'] as Map<String, dynamic>;
        final goSeed = hex(goSealed['seed_hex']);
        expect(bindings.reportPublicKey(goSeed), hex(goSealed['public_hex']));
        expect(
          bindings.openReport(
            seed: goSeed,
            aad: utf(goSealed['aad']),
            sealed: hex(goSealed['sealed_hex']),
          ),
          utf(goSealed['plaintext']),
        );
      },
      skip: nativeCryptoSkip(),
    );

    test(
      'seal and open round trip; any change fails closed',
      () {
        final seed = bindings.generateReportKeySeed();
        expect(seed, hasLength(32));
        final public = bindings.reportPublicKey(seed);
        final plaintext = Uint8List.fromList(utf8.encode('reported'));
        final sealed = bindings.sealReport(
          recipientPublicKey: public,
          aad: const [1, 2],
          plaintext: plaintext,
        );
        expect(
          bindings.openReport(seed: seed, aad: const [1, 2], sealed: sealed),
          plaintext,
        );
        final tampered = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
        expect(
          () => bindings.openReport(
            seed: seed,
            aad: const [1, 2],
            sealed: tampered,
          ),
          failsWith(NativeCryptoError.operationFailed),
        );
        expect(
          () => bindings.openReport(
            seed: seed,
            aad: const [1, 3],
            sealed: sealed,
          ),
          failsWith(NativeCryptoError.operationFailed),
        );
        expect(
          () => bindings.openReport(
            seed: bindings.generateReportKeySeed(),
            aad: const [1, 2],
            sealed: sealed,
          ),
          failsWith(NativeCryptoError.operationFailed),
        );
        expect(
          () => bindings.sealReport(
            recipientPublicKey: Uint8List(32),
            aad: const [1],
            plaintext: plaintext,
          ),
          failsWith(NativeCryptoError.invalidArgument),
        );
        expect(
          () => bindings.sealReport(
            recipientPublicKey: public,
            aad: const [],
            plaintext: plaintext,
          ),
          throwsArgumentError,
        );
        expect(
          () => bindings.frankCommit(
            key: key.sublist(1),
            conversationId: conversation,
            senderDeviceId: device,
            actionId: action,
            payload: payload,
          ),
          throwsArgumentError,
        );
      },
      skip: nativeCryptoSkip(),
    );
  });
}
