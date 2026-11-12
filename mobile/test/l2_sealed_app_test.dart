import 'dart:convert';
import 'dart:io';
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
    final signature =
        Uint8List.fromList(List<int>.generate(64, (i) => 255 - i));
    final sealed = frankWireJson(canonical, key, signature: signature);
    final plain = frankWireJson(canonical, key);
    final readSealed = splitFrank(sealed) as Franked;
    expect(readSealed.signature, signature);
    expect(readSealed.key, key);
    expect(readSealed.canonical, canonical);
    final readPlain = splitFrank(plain) as Franked;
    expect(readPlain.signature, isNull);
    // A non-canonical signature spelling is refused.
    final text = utf8.decode(sealed);
    final bent = text.replaceFirst('","s":"', '","s" :"');
    expect(splitFrank(Uint8List.fromList(utf8.encode(bent))),
        isA<MalformedFrank>());
    expect(() => frankWireJson(canonical, key, signature: Uint8List(63)),
        throwsFormatException);
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

    test('not eligible, and only that, may send the message identified',
        () async {
      // Review M2: the server answers sealed_not_eligible only after
      // finding nothing stored under the key.
      final poster = SealedPostClient(baseUrl: server.origin);
      addTearDown(poster.close);
      final store = MemoryLocalStore();
      final tokens = _tokens(store: store);
      await tokens.debugTrust(store, _conversation);
      final envelope = _envelope(_token(1));
      final asked = <MessageEnvelope>[];
      Future<bool> identified(MessageEnvelope sealed) async {
        asked.add(sealed);
        return true;
      }

      server.refuseNext.add('sealed_not_eligible');
      await postSealedMessage(
          poster: poster,
          envelope: envelope,
          tokens: tokens,
          rewrite: (_) async => true,
          sendIdentified: identified);
      expect(asked.single.idempotencyKey, envelope.idempotencyKey);
      expect(server.stored, isEmpty);
      expect(tokens.activeIn(_conversation), isFalse);

      // Without a fallback to offer, the refusal fails the message.
      server.refuseNext.add('sealed_not_eligible');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: envelope,
              tokens: tokens,
              rewrite: (_) async => true,
              sendIdentified: (_) async => false),
          throwsA(isA<ApiException>()
              .having((e) => e.serverCode, 'code', 'sealed_not_eligible')));

      // Every other answer keeps it sealed: it waits or fails, never goes
      // identified.
      asked.clear();
      for (final refusal in <String>[
        '409:idempotency_conflict',
        '400:invalid_encrypted_envelope',
        '403:forbidden',
        '404:not_found',
        '429:rate_limited',
        '503:unavailable',
        '400:sealed_not_eligible',
      ]) {
        server.refuseNext.add(refusal);
        await expectLater(
            postSealedMessage(
                poster: poster,
                envelope: _envelope(_token(2)),
                tokens: _tokens(),
                rewrite: (_) async => true,
                sendIdentified: identified),
            throwsA(isA<ApiException>()),
            reason: refusal);
      }
      // A refused token with none to replace it waits too.
      server.refuseNext.add('sealed_token_spent');
      await expectLater(
          postSealedMessage(
              poster: poster,
              envelope: _envelope(_token(2)),
              tokens: _tokens(),
              rewrite: (_) async => true,
              sendIdentified: identified),
          throwsA(isA<ApiException>()));
      expect(asked, isEmpty);
      expect(server.stored, isEmpty);
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

    test('off: nothing is fetched and no token is handed out', () async {
      final store = MemoryLocalStore();
      final api = _SealedApi();
      final sealed = SealedSender(
          origin: 'https://chat.example.org',
          localStore: store,
          crypto: _FakeCrypto(),
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
      clock: () => _now,
    )..enabled = true;

extension on SealedSender {
  /// Pins the test key and marks [conversationId] eligible, as a token pass
  /// would have.
  Future<void> debugTrust(MemoryLocalStore store, String conversationId) =>
      refresh(_SealedApi(), 't',
          <Conversation>[Conversation(id: conversationId, kind: 'dm')]);
}

class _FakeCrypto implements SealedSendingCryptoService {
  @override
  set sealedTokenSource(SealedTokenSource? source) {}

  @override
  Future<MessageEnvelope?> reencryptSealedAsIdentified(
          MessageEnvelope sealed) =>
      throw UnimplementedError();

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
