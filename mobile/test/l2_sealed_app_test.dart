import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/storage/local_store.dart';

/// L2-3 app step, without the native core: the sealed post client never
/// carries the session, a message chosen to go sealed is only ever posted
/// sealed and retried under its idempotency key, sync asks for sealed
/// events only when told to, and the token pass pins the issuer key and
/// stays within the server's count.
void main() {
  // C6 wire form of a sealed payload's frank member (pure Dart).
  test('the frank member reads in exactly one spelling of each form', () {
    final canonical = Uint8List.fromList(utf8.encode('{"t":"x"}'));
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final designation = _designation(3, seed: 5);
    final designated = frankWireJson(canonical, key, designation: designation);
    final plain = frankWireJson(canonical, key);
    final readDesignated = splitFrank(designated) as Franked;
    expect(readDesignated.designation, designation);
    expect(readDesignated.key, key);
    expect(readDesignated.canonical, canonical);
    final readPlain = splitFrank(plain) as Franked;
    expect(readPlain.designation, isNull);
    final text = utf8.decode(designated);
    // A bent infix, an empty `d`, padding, a short entry, unsorted or
    // repeated key ids and 17 entries are all refused.
    for (final bent in <String>[
      text.replaceFirst('","d":"', '","d" :"'),
      text.replaceFirst(RegExp(r'"d":"[^"]*"'), '"d":""'),
      text.replaceFirst(RegExp(r'"d":"[^"]*"'),
          '"d":"${base64.encode(designation.sublist(0, 47))}"'),
      text.replaceFirst(
          RegExp(r'"d":"[^"]*"'), '"d":"${base64.encode(designation)}=="'),
      text.replaceFirst(
          RegExp(r'"d":"[^"]*"'),
          '"d":"${base64.encode(<int>[
                ...designation.sublist(48, 96),
                ...designation.sublist(0, 48)
              ])}"'),
      text.replaceFirst(
          RegExp(r'"d":"[^"]*"'),
          '"d":"${base64.encode(<int>[
                ...designation.sublist(0, 48),
                ...designation.sublist(0, 48)
              ])}"'),
      text.replaceFirst(RegExp(r'"d":"[^"]*"'),
          '"d":"${base64.encode(_designation(17, seed: 1))}"'),
      text.replaceFirst(
          RegExp(r'"d":"[^"]*"'), '"d":"${base64Url.encode(designation)}"'),
    ]) {
      expect(splitFrank(Uint8List.fromList(utf8.encode(bent))),
          isA<MalformedFrank>(),
          reason: bent);
    }
    expect(() => frankWireJson(canonical, key, designation: Uint8List(47)),
        throwsFormatException);
    expect(() => frankWireJson(canonical, key, designation: Uint8List(0)),
        throwsFormatException);
    expect(
        () => frankWireJson(canonical, key,
            designation: _designation(17, seed: 2)),
        throwsFormatException);
  });

  // Item (g): splitFrank against random and mutated inputs. Whatever it
  // accepts must be the one spelling the encoder writes for what it read,
  // so two different byte strings never read as the same franked payload.
  test('splitFrank accepts only what the encoder writes (property)', () {
    final random = Random(20261112);
    var accepted = 0, refused = 0;
    for (var round = 0; round < 3000; round++) {
      final canonical = _randomObject(random);
      final key = Uint8List.fromList(
          List<int>.generate(32, (_) => random.nextInt(256)));
      final n = random.nextInt(17); // 0 = plain form
      final designation =
          n == 0 ? null : _designation(n, seed: random.nextInt(1 << 30));
      final wire = frankWireJson(canonical, key, designation: designation);
      final read = splitFrank(wire);
      expect(read, isA<Franked>());
      read as Franked;
      expect(read.canonical, canonical);
      expect(read.key, key);
      expect(read.designation, designation);
      // Mutations: flip, insert, delete or truncate one byte.
      final mutated = Uint8List.fromList(wire);
      final at = random.nextInt(mutated.length);
      final List<int> bent = switch (random.nextInt(4)) {
        0 => (mutated..[at] ^= 1 << random.nextInt(8)),
        1 => <int>[
            ...mutated.sublist(0, at),
            random.nextInt(128),
            ...mutated.sublist(at)
          ],
        2 => <int>[...mutated.sublist(0, at), ...mutated.sublist(at + 1)],
        _ => mutated.sublist(0, at),
      };
      final again = splitFrank(bent);
      if (again is Franked) {
        accepted++;
        expect(
            frankWireJson(again.canonical, again.key,
                designation: again.designation),
            bent,
            reason: utf8.decode(bent, allowMalformed: true));
      } else {
        refused++;
      }
    }
    // Most mutations break the form; a few land in P and stay valid.
    expect(refused, greaterThan(accepted));
  });

  group('sealed posts', () {
    late _Loopback server;
    setUp(() async => server = await _Loopback.start());
    tearDown(() => server.close());

    test('carry no session, no cookie, and nothing about the device', () async {
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      await poster.post(_envelope(_token(1)));
      final request = server.requests.single;
      expect(request.path, '/api/v1/sealed/messages');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body.keys.toSet(), <String>{
        'conversation_id',
        'token',
        'idempotency_key',
        'ciphertext',
        'crypto_protocol',
        'crypto_metadata',
        'frank_commit',
      });
      expect(request.body, isNot(contains('sender')));
      expect(request.body, isNot(contains('device')));
    });

    test('the session route refuses a sealed envelope', () async {
      final api = ApiClient(baseUrl: server.origin);
      addTearDown(api.close);
      await expectLater(api.sendEnvelope('session-token', _envelope(_token(1))),
          throwsStateError);
      expect(server.requests, isEmpty);
    });

    test('a lost answer is retried under the same key, and lands once',
        () async {
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      final tokens = _tokens();
      final envelope = _envelope(_token(1));
      // The first post lands but its answer is lost.
      server.dropNextAnswer = true;
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: envelope,
              tokens: tokens,
              rewrite: (_) async => true),
          throwsA(anything));
      // The outbox retries the same envelope; the server knows the post.
      await postSealedMessage(
          poster: poster,
          envelope: envelope,
          tokens: tokens,
          rewrite: (_) async => true);
      expect(server.stored, hasLength(1));
      expect(server.requests, hasLength(2));
      expect(server.requests[0].body, server.requests[1].body);
    });

    test('a spent or expired token is replaced and the same bytes posted',
        () async {
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      final store = MemoryLocalStore();
      final tokens = _tokens(store: store);
      await tokens.debugTrust(store, _conversation);
      server.refuseNext.add('sealed_token_spent');
      final rewritten = <MessageEnvelope>[];
      await postSealedMessage(
          poster: poster,
          envelope: _envelope(_token(1)),
          tokens: tokens,
          rewrite: (next) async {
            rewritten.add(next);
            return true;
          });
      expect(server.requests, hasLength(2));
      final first = jsonDecode(server.requests[0].body) as Map;
      final second = jsonDecode(server.requests[1].body) as Map;
      expect(second['idempotency_key'], first['idempotency_key']);
      expect(second['ciphertext'], first['ciphertext']);
      expect(second['frank_commit'], first['frank_commit']);
      expect(second['token'], isNot(first['token']));
      expect(rewritten.single.sealedToken!.nonce, isNot(_token(1).nonce));
      expect(
          rewritten.single.idempotencyKey, _envelope(_token(1)).idempotencyKey);
    });

    test('with no token to replace it the message waits, still sealed',
        () async {
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      server.refuseNext.add('sealed_token_expired');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: _envelope(_token(1)),
              tokens: _tokens(),
              rewrite: (_) async => true),
          throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 503)));
      expect(server.requests, hasLength(1));
    });

    test('not eligible fails the message and drops the tokens', () async {
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      final store = MemoryLocalStore();
      final tokens = _tokens(store: store);
      await tokens.debugTrust(store, _conversation);
      server.refuseNext.add('sealed_not_eligible');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: _envelope(_token(1)),
              tokens: tokens,
              rewrite: (_) async => true),
          throwsA(isA<ApiException>()
              .having((e) => e.serverCode, 'code', 'sealed_not_eligible')));
      expect(tokens.activeIn(_conversation), isFalse);
      expect(await tokens.takeFor(_conversation), isNull);
      expect(server.requests, hasLength(1));
    });

    test('not eligible never sends identified; the message waits for a choice',
        () async {
      // Owner decision 2026-11-12 ("Ask before re-sending"): a hostile
      // server could answer sealed_not_eligible to unmask the sender of a
      // post it chose. The refusal is rethrown and the outbox keeps the
      // message for the person; only their tap re-sends it identified.
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      final store = MemoryLocalStore();
      final tokens = _tokens(store: store);
      await tokens.debugTrust(store, _conversation);
      final envelope = _envelope(_token(1));
      server.refuseNext.add('sealed_not_eligible');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: envelope,
              tokens: tokens,
              rewrite: (_) async => true),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.serverCode, 'code', 'sealed_not_eligible')));
      expect(server.requests, hasLength(1));
      expect(server.stored, isEmpty);
      expect(tokens.activeIn(_conversation), isFalse);

      // The outbox records it terminal under the class that offers the
      // choice; nothing else does.
      PendingEnvelopeRecord record(MessageEnvelope envelope,
              {required bool terminal, String? failure}) =>
          PendingEnvelopeRecord(
              envelope: envelope,
              attemptCount: 1,
              terminal: terminal,
              failureClass: failure);
      expect(
          sealedNeedsResendChoice(record(envelope,
              terminal: true, failure: sealedRefusedFailureClass)),
          isTrue);
      expect(
          sealedNeedsResendChoice(record(envelope,
              terminal: false, failure: sealedRefusedFailureClass)),
          isFalse);
      expect(
          sealedNeedsResendChoice(record(envelope,
              terminal: true, failure: 'terminal:409:idempotency_conflict')),
          isFalse);
      final identified = MessageEnvelope(
        conversationId: envelope.conversationId,
        idempotencyKey: envelope.idempotencyKey,
        ciphertext: const <int>[4, 5, 6],
        cryptoProtocol: envelope.cryptoProtocol,
        cryptoMetadata: envelope.cryptoMetadata,
      );
      expect(
          sealedNeedsResendChoice(record(identified,
              terminal: true, failure: sealedRefusedFailureClass)),
          isFalse);
    });

    test('a 404 from the sealed routes waits instead of failing', () async {
      // Review low (a): the routes answer 404 while the switch is off.
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      server.refuseNext.add('404:not_found');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: _envelope(_token(1)),
              tokens: _tokens(),
              rewrite: (_) async => true),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.serverCode, 'code', 'sealed_unavailable')));
    });

    test('outcomes', () {
      SealedPostOutcome of(int status, String code) =>
          sealedPostOutcome(ApiException(status, '{"error":"$code"}'));
      expect(of(409, 'sealed_token_spent'), SealedPostOutcome.replaceToken);
      expect(of(409, 'sealed_token_expired'), SealedPostOutcome.replaceToken);
      expect(of(403, 'sealed_token_invalid'), SealedPostOutcome.replaceToken);
      expect(of(409, 'sealed_not_eligible'), SealedPostOutcome.terminal);
      expect(of(409, 'idempotency_conflict'), SealedPostOutcome.terminal);
      expect(
          of(400, 'sealed_request_authenticated'), SealedPostOutcome.terminal);
      expect(of(429, 'rate_limited'), SealedPostOutcome.retry);
      expect(of(503, 'unavailable'), SealedPostOutcome.retry);
      expect(sealedPostOutcome(const SocketException('x')),
          SealedPostOutcome.retry);
    });

    // The re-encryption "Send normally" runs (AppState.sendSealedNormally).
    test('send normally re-encrypts, waits, or refuses, and sends nothing',
        () async {
      final sealed = _envelope(_token(1));
      final identified = MessageEnvelope(
        conversationId: sealed.conversationId,
        idempotencyKey: sealed.idempotencyKey,
        ciphertext: const <int>[4, 5, 6],
        cryptoProtocol: sealed.cryptoProtocol,
        cryptoMetadata: sealed.cryptoMetadata,
      );
      final store = _MlsQueue();
      final crypto = _FakeCrypto();
      Future<SealedResend> resend(Object? with_, [MessageEnvelope? of]) =>
          reencryptSealedForResend(
              crypto: with_, localStore: store, sealed: of ?? sealed);

      // A crypto service that cannot seal: nothing to do.
      expect(await resend(Object()), SealedResend.unavailable);
      expect(await resend(null), SealedResend.unavailable);

      // The fresh identified copy takes the entry's place.
      crypto.reencrypt = (_) => identified;
      expect(await resend(crypto), SealedResend.queued);
      expect(crypto.reencrypts, 1);
      // Only a sealed message is ever re-encrypted.
      expect(await resend(crypto, identified), SealedResend.unavailable);
      expect(crypto.reencrypts, 1);

      // Nothing left to send it with, or a copy still sealed.
      crypto.reencrypt = (_) => null;
      expect(await resend(crypto), SealedResend.unavailable);
      crypto.reencrypt = (sealed) => sealed;
      expect(await resend(crypto), SealedResend.unavailable);

      // An MLS control message queued for this conversation: waits, and
      // nothing is encrypted.
      crypto.reencrypt = (_) => identified;
      crypto.reencrypts = 0;
      store.pending = <PendingMlsMessage>[
        PendingMlsMessage(
            idempotencyKey: 'mls_1',
            conversationId: sealed.conversationId,
            kind: 'commit',
            payload: const <int>[1]),
      ];
      expect(await resend(crypto), SealedResend.held);
      expect(crypto.reencrypts, 0);
      // One for another conversation does not hold it.
      store.pending = <PendingMlsMessage>[
        const PendingMlsMessage(
            idempotencyKey: 'mls_2',
            conversationId: 'conv_other',
            kind: 'commit',
            payload: <int>[1]),
      ];
      expect(await resend(crypto), SealedResend.queued);
      expect(crypto.reencrypts, 1);
    });
  });

  group('sync reads', () {
    late _Loopback server;
    setUp(() async => server = await _Loopback.start());
    tearDown(() => server.close());

    test('ask for sealed events only when the app reads them', () async {
      final api = ApiClient(baseUrl: server.origin);
      addTearDown(api.close);
      Future<void> readAll() async {
        await api.syncEvents('t');
        await api.syncEventsPage('t');
        await api.conversationSyncPage('t', _conversation);
      }

      await readAll();
      expect(
          server.requests.map((r) => r.query['sealed']), everyElement(isNull));
      server.requests.clear();
      api.readsSealedEvents = true;
      await readAll();
      expect(server.requests, hasLength(3));
      expect(server.requests.map((r) => r.query['sealed']), everyElement('1'));
    });
  });

  group('token pass', () {
    test('pins the key on first use and fetches within the count', () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final crypto = _FakeCrypto();
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: crypto,
          loadFrankContext: () async => _frank,
          clock: () => _now);
      sealed.enabled = true;
      api.remaining = 40;
      await sealed.refresh(api, 't', <Conversation>[
        Conversation(id: _conversation, kind: 'dm'),
        Conversation(id: 'conv_comm', kind: 'group', communityId: 'c1'),
      ]);
      final pin = (await store.loadSealedKeyPin('https://chat.example.org'))!;
      expect(pin.keyId, _keyId);
      // 32 for today, then the 8 left for tomorrow; nothing for the
      // community group (not eligible for sealed posts).
      expect(api.batches, <(int, int)>[(32, api.epoch), (8, api.epoch + 1)]);
      expect(api.asked, <String>[_conversation]);
      expect(sealed.activeIn(_conversation), isTrue);
      expect(await sealed.takeFor(_conversation), isNotNull);

      // A pass with tokens still held fetches nothing.
      api.batches.clear();
      await sealed.refresh(api, 't',
          <Conversation>[Conversation(id: _conversation, kind: 'dm')]);
      expect(api.batches, isEmpty); // inside the refresh interval
    });

    test('a changed key stops sealed sending until it is accepted', () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final crypto = _FakeCrypto();
      var now = _now;
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: crypto,
          loadFrankContext: () async => _frank,
          clock: () => now);
      sealed.enabled = true;
      final conversations = <Conversation>[
        Conversation(id: _conversation, kind: 'dm')
      ];
      await sealed.refresh(api, 't', conversations);
      expect(await sealed.takeFor(_conversation), isNotNull);

      api.keyId = 'b' * 32;
      api.publicKey = List<int>.filled(32, 7);
      api.batches.clear();
      now = now.add(const Duration(hours: 1));
      await sealed.refresh(api, 't', conversations);
      final pin = (await store.loadSealedKeyPin('https://chat.example.org'))!;
      expect(pin.changed, isTrue);
      expect(pin.keyId, _keyId);
      expect(pin.seenKeyId, 'b' * 32);
      expect(api.batches, isEmpty);
      expect(await sealed.takeFor(_conversation), isNull);

      await sealed.acceptChangedKey();
      now = now.add(const Duration(hours: 1));
      await sealed.refresh(api, 't', conversations);
      expect((await store.loadSealedKeyPin('https://chat.example.org'))!.keyId,
          'b' * 32);
      expect(api.batches, isNotEmpty);
      expect((await sealed.takeFor(_conversation))!.keyId, 'b' * 32);
    });

    test('an ineligible conversation keeps no tokens and stays identified',
        () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: _FakeCrypto(),
          loadFrankContext: () async => _frank,
          clock: () => _now);
      sealed.enabled = true;
      await store.saveSealedTokens(<SealedToken>[_token(9, epoch: api.epoch)]);
      api.eligible = false;
      await sealed.refresh(api, 't',
          <Conversation>[Conversation(id: _conversation, kind: 'group')]);
      expect(api.batches, isEmpty);
      expect(sealed.activeIn(_conversation), isFalse);
      expect(
          await store.countSealedTokens(_conversation,
              keyId: _keyId, epoch: api.epoch),
          0);
    });

    test('without its own franking key listed, nothing goes sealed', () async {
      // Fail safe: the context is null when this device's key is not on its
      // verified list, so a held token is never handed to a send.
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: _FakeCrypto(),
          loadFrankContext: () async => null,
          clock: () => _now);
      sealed.enabled = true;
      await sealed.refresh(api, 't',
          <Conversation>[Conversation(id: _conversation, kind: 'dm')]);
      expect(api.batches, isNotEmpty);
      expect(sealed.frankContext, isNull);
      expect(await sealed.takeFor(_conversation), isNull);
    });

    test('the designation context is read on the token pass, never on a send',
        () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      var reads = 0;
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: _FakeCrypto(),
          loadFrankContext: () async {
            reads++;
            return _frank;
          },
          clock: () => _now);
      sealed.enabled = true;
      await sealed.refresh(api, 't',
          <Conversation>[Conversation(id: _conversation, kind: 'dm')]);
      expect(reads, 1);
      for (var i = 0; i < 5; i++) {
        expect(await sealed.takeFor(_conversation), isNotNull);
        expect(sealed.frankContext, same(_frank));
      }
      expect(reads, 1);
    });

    test('off: nothing is fetched and no token is handed out', () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: _FakeCrypto(),
          loadFrankContext: () async => _frank,
          clock: () => _now);
      await sealed.refresh(api, 't',
          <Conversation>[Conversation(id: _conversation, kind: 'dm')]);
      expect(api.asked, isEmpty);
      expect(await sealed.takeFor(_conversation), isNull);
    });
  });
}

const _conversation = 'conv_1';
final _keyId = 'a' * 32;
final DateTime _now = DateTime.utc(2026, 11, 12, 10);

SealedToken _token(int seed, {int? epoch}) => SealedToken(
      conversationId: _conversation,
      keyId: _keyId,
      epoch: epoch ?? sealedUtcDay(_now),
      nonce: List<int>.generate(32, (i) => (seed * 31 + i) & 0xff),
      output: List<int>.generate(64, (i) => (seed + i) & 0xff),
    );

MessageEnvelope _envelope(SealedToken token) => MessageEnvelope(
      conversationId: _conversation,
      idempotencyKey: 'idem-aaaaaaaaaaaaaaaaaaaaaaaa',
      ciphertext: utf8.encode('ciphertext-bytes'),
      cryptoProtocol: 'mls10-openmls-v1',
      cryptoMetadata: const <String, Object?>{
        'protocol_version': 1,
        'group_id': _conversation,
        'content_type': 'application',
        'payload_version': 1,
        'mls_epoch': 3,
      },
      frankCommit: List<int>.filled(32, 4),
      sealedToken: token,
    );

SealedSender _tokens({MemoryLocalStore? store}) => SealedSender(
      origin: 'https://chat.example.org',
      localStore: store ?? MemoryLocalStore(),
      crypto: _FakeCrypto(),
      loadFrankContext: () async => _frank,
      clock: () => _now,
    )..enabled = true;

/// A designation context as the token pass would cache it.
final SealedFrankContext _frank = SealedFrankContext(
    listedKey: List<int>.filled(32, 9),
    ownerKeys: <List<int>>[List<int>.filled(32, 3)]);

/// [n] entries with strictly ascending random key ids.
Uint8List _designation(int n, {required int seed}) {
  final random = Random(seed);
  final kids = <String, List<int>>{};
  while (kids.length < n) {
    final kid = List<int>.generate(16, (_) => random.nextInt(256));
    kids[base64.encode(kid)] = kid;
  }
  final sorted = kids.values.toList()
    ..sort((a, b) {
      for (var i = 0; i < 16; i++) {
        if (a[i] != b[i]) return a[i] - b[i];
      }
      return 0;
    });
  return Uint8List.fromList(<int>[
    for (final kid in sorted) ...<int>[
      ...kid,
      ...List<int>.generate(32, (_) => random.nextInt(256))
    ],
  ]);
}

/// A random JSON object without `frank`, with values that try to look like
/// the frank member's own syntax.
Uint8List _randomObject(Random random) {
  const tricky = <String>[
    ',"frank":{"k":"',
    '","d":"',
    '"}}',
    'AAAA',
    '=',
    'frank',
    'd',
    '\u0022',
  ];
  final map = <String, Object?>{};
  final count = 1 + random.nextInt(4);
  for (var i = 0; i < count; i++) {
    final name = random.nextBool() ? 'f$i' : 'd$i';
    final value = switch (random.nextInt(4)) {
      0 => tricky[random.nextInt(tricky.length)] * (1 + random.nextInt(3)),
      1 => random.nextInt(1 << 20),
      2 => <String, Object?>{'frank': tricky[random.nextInt(tricky.length)]},
      _ => base64.encode(
          List<int>.generate(random.nextInt(70), (_) => random.nextInt(256))),
    };
    map[name] = value;
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(map)));
}

extension on SealedSender {
  /// Pins the test key and marks [conversationId] eligible, as a token pass
  /// would have.
  Future<void> debugTrust(MemoryLocalStore store, String conversationId) =>
      refresh(_SealedApi(), 't',
          <Conversation>[Conversation(id: conversationId, kind: 'dm')]);
}

class _MlsQueue extends MemoryLocalStore {
  List<PendingMlsMessage> pending = const <PendingMlsMessage>[];

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async => pending;
}

class _FakeCrypto implements SealedSendingCryptoService {
  @override
  set sealedTokenSource(SealedTokenSource? source) {}

  MessageEnvelope? Function(MessageEnvelope sealed)? reencrypt;
  int reencrypts = 0;

  @override
  Future<MessageEnvelope?> reencryptSealedAsIdentified(
      MessageEnvelope sealed) async {
    final answer = reencrypt;
    if (answer == null) throw UnimplementedError();
    reencrypts++;
    return answer(sealed);
  }

  @override
  Future<ReceivedMessageEnvelope> processSealedApplicationMessage(
          ReceivedMessageEnvelope envelope, int syncEventId,
          {void Function()? checkCanCommit}) =>
      throw UnimplementedError();

  @override
  ({Uint8List state, Uint8List request}) sealedTokenRequest({
    required List<int> publicKey,
    required String conversationId,
    required int epoch,
    required int count,
  }) =>
      (state: Uint8List.fromList(<int>[count]), request: Uint8List(count * 32));

  var _serial = 0;

  @override
  List<SealedToken> sealedTokenFinalize({
    required List<int> state,
    required List<int> response,
    required String conversationId,
    required String keyId,
    required int epoch,
  }) =>
      <SealedToken>[
        for (var i = 0; i < state.first; i++)
          SealedToken(
            conversationId: conversationId,
            keyId: keyId,
            epoch: epoch,
            nonce: List<int>.generate(32, (j) => (++_serial * 7 + j) & 0xff)
              ..[0] = _serial & 0xff
              ..[1] = (_serial >> 8) & 0xff,
            output: List<int>.filled(64, 1),
          ),
      ];
}

class _SealedApi extends ApiClient {
  _SealedApi() : super(baseUrl: 'https://chat.example.org');

  String keyId = 'a' * 32;
  List<int> publicKey = List<int>.filled(32, 3);
  bool eligible = true;
  int remaining = 200;
  int get epoch => sealedUtcDay(_now);
  final List<String> asked = <String>[];
  final List<(int, int)> batches = <(int, int)>[];

  @override
  Future<SealedServerKey> sealedKey() async =>
      SealedServerKey(keyId: keyId, publicKey: publicKey);

  @override
  Future<SealedConversationState> sealedConversation(
      String token, String conversationId) async {
    asked.add(conversationId);
    return SealedConversationState(
      key: SealedServerKey(keyId: keyId, publicKey: publicKey),
      eligible: eligible,
      remaining: remaining,
    );
  }

  @override
  Future<({String keyId, Uint8List response})> sealedTokens(
    String token,
    String conversationId, {
    required int epoch,
    required List<int> blinded,
  }) async {
    final count = blinded.length ~/ 32;
    batches.add((count, epoch));
    return (keyId: keyId, response: Uint8List(count * 32 + 64));
  }
}

class _Request {
  _Request(this.path, this.query, this.headers, this.body);
  final String path;
  final Map<String, String> query;
  final HttpHeaders headers;
  final String body;
}

/// A loopback server: stores sealed posts by idempotency key (a retry of a
/// stored post answers 200), refuses the next posts with the queued codes,
/// and answers sync reads with an empty page.
class _Loopback {
  _Loopback(this._server);

  final HttpServer _server;
  final List<_Request> requests = <_Request>[];
  final Map<String, String> stored = <String, String>{};
  final List<String> refuseNext = <String>[];
  bool dropNextAnswer = false;

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<_Loopback> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final loopback = _Loopback(server);
    server.listen(loopback._handle);
    return loopback;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    requests.add(_Request(
        request.uri.path, request.uri.queryParameters, request.headers, body));
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.uri.path == '/api/v1/sealed/messages') {
      final json = jsonDecode(body) as Map<String, Object?>;
      final key = json['idempotency_key'] as String;
      final known = stored[key];
      if (known != null) {
        response.write('{"id":"sealed_1"}');
        await response.close();
        return;
      }
      if (refuseNext.isNotEmpty) {
        var code = refuseNext.removeAt(0);
        var status = code == 'sealed_token_invalid' ? 403 : 409;
        // 'status:code' names the status too.
        final colon = code.indexOf(':');
        if (colon > 0) {
          status = int.parse(code.substring(0, colon));
          code = code.substring(colon + 1);
        }
        response.statusCode = status;
        response.write('{"error":"$code"}');
        await response.close();
        return;
      }
      stored[key] = json['ciphertext'] as String;
      if (dropNextAnswer) {
        dropNextAnswer = false;
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      response.write('{"id":"sealed_1"}');
      await response.close();
      return;
    }
    if (request.uri.path.endsWith('/sync-events')) {
      response.write(jsonEncode(<String, Object?>{
        'events': <Object?>[],
        'scope': 'conversation',
        'scope_id': _conversation,
      }));
    } else {
      response.write('{"events":[]}');
    }
    await response.close();
  }
}
