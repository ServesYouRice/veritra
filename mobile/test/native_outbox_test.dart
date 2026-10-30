// Card I31: MLS payloads leave the outbox through the real native library.
//
// AppState encrypts with NativeCryptoService (OpenMLS over FFI), its outbox
// workers post the commit bundle and every envelope with the real ApiClient
// over HTTP to a loopback stand-in server, and a second member decrypts what
// the server received with its own native device. Only the read endpoints
// AppState polls are stubbed in Dart.
//
// Needs VERITRA_CRYPTO_LIBRARY, the path of a built libprivate_messenger_crypto
// (CI sets it; locally run scripts/build-desktop-crypto.sh linux). Without it
// a local run skips the tests; in CI (CI=true) they fail instead, and a path
// to a missing file always fails.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/app_payload.dart' show AppPayloadType;
import 'package:private_messenger/crypto/crypto_service.dart'
    show ConversationAuthority;
import 'package:private_messenger/crypto/mls_commit_bundle.dart'
    show MlsPendingChange;
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final inCi = Platform.environment['CI'] == 'true';
  final skip = configured == null && !inCi
      ? 'native crypto library absent: set VERITRA_CRYPTO_LIBRARY to a built '
          'libprivate_messenger_crypto (scripts/build-desktop-crypto.sh linux)'
      : false;
  String library() =>
      configured ?? fail('CI must run this test with VERITRA_CRYPTO_LIBRARY');

  test(
    'every MLS payload type goes from the outbox to another member',
    () async {
      final harness = await _Harness.start(library());
      addTearDown(harness.dispose);
      final alice = harness.alice;

      expect(await alice.sendMessageTo(_conversation, 'hello bob'), isTrue);
      final hello = await harness.nextEnvelope();
      await harness.deliverToBob(hello);
      final helloKey = messageKey(
        'dev_alice',
        hello['idempotency_key']! as String,
      );
      expect((await harness.bobHistory()).single.body, 'hello bob');

      // Reply, edit, reaction and delete take the second enqueue path
      // (MlsConversationCryptoService.encryptPayload).
      expect(
        await alice.replyTo(_conversation, helloKey, 'and a reply'),
        isTrue,
      );
      await harness.deliverToBob(await harness.nextEnvelope());
      final reply = (await harness.bobHistory()).firstWhere(
        (message) => message.key != helloKey,
      );
      expect(reply.body, 'and a reply');
      expect(reply.replyTo, helloKey);

      expect(
        await alice.editMessage(_conversation, helloKey, 'hello, bob'),
        isTrue,
      );
      await harness.deliverToBob(await harness.nextEnvelope());
      final edited = (await harness.bobHistory()).firstWhere(
        (message) => message.key == helloKey,
      );
      expect(edited.body, 'hello, bob');
      expect(edited.editedAt, isNotNull);

      expect(await alice.react(_conversation, helloKey, '👍'), isTrue);
      await harness.deliverToBob(await harness.nextEnvelope());
      final reaction = (await harness.bob.store.loadReactions(
        _conversation,
      ))
          .single;
      expect(reaction.reaction, '👍');

      expect(await alice.deleteMessage(_conversation, helloKey), isTrue);
      await harness.deliverToBob(await harness.nextEnvelope());
      final deleted = (await harness.bobHistory()).firstWhere(
        (message) => message.key == helloKey,
      );
      expect(deleted.body, isNull);
      expect(deleted.deletedAt, isNotNull);

      // Delivered once each, and the outbox is empty again.
      await _waitFor(
        () async => (await harness.aliceStore.pendingEnvelopes()).isEmpty,
      );
      expect(harness.server.envelopes, hasLength(5));
      expect(
        harness.server.envelopes.map((json) => json['idempotency_key']).toSet(),
        hasLength(5),
      );

      // The server saw ciphertext only, and the same metadata shape for every
      // payload type (D22).
      final shapes = harness.server.envelopes
          .map((json) => ((json['crypto_metadata']! as Map).keys.toList()
                ..sort())
              .join(','))
          .toSet();
      expect(shapes, hasLength(1));
      for (final json in harness.server.envelopes) {
        expect(json['crypto_protocol'], 'mls10-openmls-v1');
        expect(
          (json['crypto_metadata']! as Map)['content_type'],
          'application',
        );
        final ciphertext = base64Decode(json['ciphertext']! as String);
        final readable = latin1.decode(ciphertext);
        for (final plaintext in <String>['hello', 'reply', 'bob']) {
          expect(readable, isNot(contains(plaintext)));
        }
        expect(
          utf8.decode(ciphertext, allowMalformed: true),
          isNot(contains('👍')),
        );
      }
    },
    skip: skip,
  );

  test(
    'W8 formatted text, mentions, pins and forwards cross the native outbox',
    () async {
      final harness = await _Harness.start(library());
      addTearDown(harness.dispose);
      final alice = harness.alice;
      await alice.loadConversationMembers(_conversation);
      harness.bob.service.conversationAuthority = alice;
      await harness.aliceStore.saveDraft(_conversation, '*hello* @bob');
      expect(await alice.sendMessageTo(_conversation, '*hello* @bob'), isTrue);
      expect(await harness.aliceStore.loadDrafts(), isEmpty);
      final formattedEnvelope = await harness.nextEnvelope();
      await harness.deliverToBob(formattedEnvelope);
      final key = messageKey(
          'dev_alice', formattedEnvelope['idempotency_key'] as String);
      final formatted = (await harness.bobHistory()).single;
      expect(formatted.body, 'hello @bob');
      final decoration = jsonDecode(formatted.formatJson!) as Map;
      expect((decoration['entities'] as List).single,
          {'type': 'bold', 'offset': 0, 'length': 5});
      expect(((decoration['mentions'] as List).single as Map)['account_id'],
          'acct_bob');

      expect(
          await alice.pinMessage(_conversation, key,
              pinned: true, durationSeconds: 86400),
          isTrue);
      final pinEnvelope = await harness.nextEnvelope();
      await harness.deliverToBob(pinEnvelope);
      expect((await harness.bob.store.loadPins(_conversation)).single.targetKey,
          key);

      final source = alice.historyFor(_conversation).forKey(key)!;
      await harness.aliceStore.saveDraft(_conversation, 'hello @bob');
      expect(await alice.forwardMessage(source, [_conversation]), isTrue);
      expect((await harness.aliceStore.loadDrafts())[_conversation]?.text,
          'hello @bob');
      final forwardEnvelope = await harness.nextEnvelope();
      await harness.deliverToBob(forwardEnvelope);
      final forward =
          (await harness.bobHistory()).firstWhere((m) => m.forwardHops != null);
      expect(forward.key, isNot(key));
      expect(forward.replyTo, isNull);
      expect(forward.forwardHops, 1);
      final forwardDecoration = jsonDecode(forward.formatJson!) as Map;
      expect(forwardDecoration['entities'], decoration['entities']);
      expect(forwardDecoration.containsKey('mentions'), false);
      for (final json in [formattedEnvelope, pinEnvelope, forwardEnvelope]) {
        expect((json['crypto_metadata'] as Map)['payload_version'], 1);
        expect((json['crypto_metadata'] as Map).keys.toSet(),
            (formattedEnvelope['crypto_metadata'] as Map).keys.toSet());
      }
      final many = await harness.aliceCrypto
          .encryptPayload(_conversation, AppPayloadType.text, {
        'text': 'many',
        'forwarded': {'hops': 5}
      });
      await alice.refreshHistory(_conversation);
      await alice.retryEnvelope(many.idempotencyKey);
      await harness.deliverToBob(await harness.nextEnvelope());
      final manySource = alice
          .historyFor(_conversation)
          .forKey(messageKey('dev_alice', many.idempotencyKey))!;
      alice.conversations = [
        ...alice.conversations,
        for (var i = 1; i <= 5; i++)
          Conversation(id: 'other$i', kind: 'dm', createdBy: 'acct_alice')
      ];
      final before = harness.aliceCrypto.encryptCalls;
      expect(await alice.forwardMessage(manySource, [_conversation, 'other1']),
          false);
      expect(
          await alice.forwardMessage(
              source, [_conversation, for (var i = 1; i <= 5; i++) 'other$i']),
          false);
      expect(harness.aliceCrypto.encryptCalls, before,
          reason: 'a refused multi-chat forward must not partly send');
    },
    skip: skip,
  );

  test(
    'a pending own pin rechecks role at echo and cannot replay after promotion',
    () async {
      final harness = await _Harness.start(library());
      addTearDown(harness.dispose);
      final alice = harness.alice;
      expect(await alice.sendMessageTo(_conversation, 'target'), true);
      final first = await harness.nextEnvelope();
      final target =
          messageKey('dev_alice', first['idempotency_key'] as String);
      final authority = _ChangingAuthority();
      harness.aliceCrypto.conversationAuthority = authority;
      expect(await alice.pinMessage(_conversation, target, pinned: true), true);
      final json = await harness.nextEnvelope();
      authority.role = 'member';
      final echo = ReceivedMessageEnvelope(
          id: 'own-pin',
          conversationId: _conversation,
          senderAccountId: 'acct_alice',
          senderDeviceId: 'dev_alice',
          idempotencyKey: json['idempotency_key'] as String,
          ciphertext: base64Decode(json['ciphertext'] as String),
          cryptoProtocol: 'mls10-openmls-v1',
          cryptoMetadata: json['crypto_metadata'],
          createdAt: DateTime.now());
      await harness.aliceCrypto.processApplicationMessage(
          echo, (await harness.aliceStore.loadSyncCursor()) + 1);
      expect(await harness.aliceStore.loadPins(_conversation), isEmpty);
      expect(
          (jsonDecode(utf8.decode(await harness.aliceStore.exportBackup()))
              as Map)['pending_pins'],
          isEmpty);
      authority.role = 'admin';
      await harness.aliceCrypto.processApplicationMessage(
          echo, (await harness.aliceStore.loadSyncCursor()) + 1);
      expect(await harness.aliceStore.loadPins(_conversation), isEmpty);
    },
    skip: skip,
  );

  test(
    'the MLS payload path refuses the 101st message before encrypting',
    () async {
      final harness = await _Harness.start(library());
      addTearDown(harness.dispose);
      final alice = harness.alice;
      expect(await alice.sendMessageTo(_conversation, 'hello bob'), isTrue);
      final hello = await harness.nextEnvelope();
      await harness.deliverToBob(hello);
      final helloKey = messageKey(
        'dev_alice',
        hello['idempotency_key']! as String,
      );
      await _waitFor(
        () async => (await harness.aliceStore.pendingEnvelopes()).isEmpty,
      );

      // The server stops answering, so everything queued stays queued.
      harness.server.hold = Completer<void>();
      for (var index = 0; index < maxPendingEnvelopes - 1; index++) {
        await harness.aliceStore.enqueueEnvelope(
          MessageEnvelope(
            conversationId: 'conv_other',
            idempotencyKey: 'queued_$index',
            ciphertext: const <int>[1],
            cryptoProtocol: 'mls10-openmls-v1',
          ),
        );
      }
      final before = (await harness.aliceStore.loadCryptoState())!.counter;
      final calls = harness.aliceCrypto.encryptCalls;

      expect(await alice.react(_conversation, helloKey, '🎉'), isTrue);
      expect(
        await harness.aliceStore.pendingEnvelopes(),
        hasLength(maxPendingEnvelopes),
      );
      expect(harness.aliceCrypto.encryptCalls, calls + 1);
      final accepted = (await harness.aliceStore.loadCryptoState())!.counter;
      expect(accepted, before + 1, reason: 'the 100th was not encrypted once');

      expect(
        await alice.editMessage(_conversation, helloKey, 'one too many'),
        isFalse,
      );
      expect(alice.errorFor(Ops.send), isNotNull);
      expect(
        harness.aliceCrypto.encryptCalls,
        calls + 1,
        reason: 'the refused message reached MLS encryption',
      );
      expect(
        (await harness.aliceStore.loadCryptoState())!.counter,
        accepted,
        reason: 'the MLS state advanced for a refused message',
      );
      final queued = (await harness.aliceStore.pendingEnvelopes()).map(
        (envelope) => envelope.idempotencyKey,
      );
      expect(queued, hasLength(maxPendingEnvelopes));
      expect(queued, contains('queued_0'));

      // Once the server answers again the queue drains, and the accepted
      // reaction decrypts on the other member; the refused edit never left.
      harness.server.hold!.complete();
      harness.server.hold = null;
      await _waitFor(
        () async => (await harness.aliceStore.pendingEnvelopes()).isEmpty,
        timeout: const Duration(seconds: 30),
      );
      final sent = harness.server.envelopes
          .where((json) => json['conversation_id'] == _conversation)
          .toList();
      expect(sent, hasLength(2));
      await harness.deliverToBob(sent.last);
      expect(
        (await harness.bob.store.loadReactions(_conversation)).single.reaction,
        '🎉',
      );
      expect(
        (await harness.bobHistory())
            .firstWhere((message) => message.key == helloKey)
            .body,
        'hello bob',
      );
    },
    skip: skip,
  );
}

const _conversation = 'conv_1';

Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

/// Alice runs the app (AppState + native crypto + outbox); Bob is a second
/// native member fed with exactly the bytes the server received.
class _Harness {
  _Harness._(
    this.server,
    this.alice,
    this.aliceStore,
    this.aliceCrypto,
    this.bob,
  );

  final _StandInServer server;
  final AppState alice;
  final MemoryLocalStore aliceStore;
  final _CountingNativeCrypto aliceCrypto;
  final _Member bob;
  int _read = 0;

  static Future<_Harness> start(String libraryPath) async {
    final bindings = NativeCryptoBindings.open(libraryPath);
    final server = await _StandInServer.start();
    final bob = await _Member.enroll(bindings, 'acct_bob', 'dev_bob');

    // Alice enrolls, then stages the new group with Bob in it. The commit
    // bundle waits in her MLS outbox until AppState delivers it.
    final aliceStore = MemoryLocalStore();
    final aliceCrypto = _CountingNativeCrypto(bindings, aliceStore);
    final session = Session(
      baseUrl: server.baseUrl,
      token: 'alice-token',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    );
    await aliceCrypto.createEnrollmentCredential(
      const EnrollmentReservation(
        id: 'res_dev_alice',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
        challenge: <int>[1, 2, 3],
      ),
    );
    await aliceCrypto.activateSession(session);
    await aliceStore.saveSession(session);
    await aliceCrypto.initializeConversation(_conversation, <DeviceKeyPackage>[
      await bob.keyPackage(),
    ]);

    final alice = AppState(
      apiClientFactory: _StandInApi.new,
      cryptoService: aliceCrypto,
      localStore: aliceStore,
      syncServiceFactory: (_, __) => _QuietSync(),
      config: const ClientConfig(
        transport: TransportPolicy(allowLoopbackHttp: true),
      ),
    );
    final harness = _Harness._(server, alice, aliceStore, aliceCrypto, bob);
    await alice.tryRestoreSession();
    expect(alice.session?.deviceId, 'dev_alice');

    // The MLS outbox posts the bundle; Bob joins from its Welcome.
    await _waitFor(
      () async =>
          server.commits.isNotEmpty &&
          (await aliceStore.pendingMlsMessages()).isEmpty,
    );
    final commit = server.commits.single;
    expect(commit['conversation_id'], _conversation);
    await bob.join(
      base64Decode(commit['welcome']! as String),
      commit['idempotency_key']! as String,
    );
    expect(
      await bob.service.groupEpoch(_conversation),
      await aliceCrypto.groupEpoch(_conversation),
    );
    return harness;
  }

  /// The next envelope the server received, in arrival order.
  Future<Map<String, Object?>> nextEnvelope() async {
    await _waitFor(() => server.envelopes.length > _read);
    return server.envelopes[_read++];
  }

  Future<void> deliverToBob(Map<String, Object?> json) => bob.receive(
        ReceivedMessageEnvelope(
          id: 'srv_${++bob.events}',
          conversationId: json['conversation_id']! as String,
          senderAccountId: 'acct_alice',
          senderDeviceId: 'dev_alice',
          idempotencyKey: json['idempotency_key']! as String,
          ciphertext: base64Decode(json['ciphertext']! as String),
          cryptoProtocol: json['crypto_protocol']! as String,
          cryptoMetadata: json['crypto_metadata'],
          createdAt: DateTime.now().toUtc(),
        ),
      );

  Future<List<LocalMessage>> bobHistory() =>
      bob.store.loadMessages(_conversation);

  Future<void> dispose() async {
    server.hold?.complete();
    alice.dispose();
    await bob.service.dispose();
    await server.close();
  }
}

/// The real native service; it only counts calls into MLS encryption.
class _CountingNativeCrypto extends NativeCryptoService {
  _CountingNativeCrypto(NativeCryptoBindings bindings, LocalStore store)
      : super(bindings: bindings, localStore: store);

  int encryptCalls = 0;

  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) {
    encryptCalls++;
    return super.encryptPayload(
      conversationId,
      type,
      body,
      attachmentRefs: attachmentRefs,
      draftText: draftText,
    );
  }
}

class _Member {
  _Member(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events = 0;

  static Future<_Member> enroll(
    NativeCryptoBindings bindings,
    String accountId,
    String deviceId,
  ) async {
    final store = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(
      EnrollmentReservation(
        id: 'res_$deviceId',
        accountId: accountId,
        deviceId: deviceId,
        challenge: const <int>[1, 2, 3],
      ),
    );
    await service.activateSession(
      Session(
        baseUrl: 'https://localhost:8443',
        token: 'token',
        accountId: accountId,
        deviceId: deviceId,
      ),
    );
    return _Member(service, store, accountId, deviceId);
  }

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<void> join(List<int> welcome, String idempotencyKey) =>
      service.processMlsMessage(
        MlsMessage(
          id: 'mls_welcome',
          conversationId: _conversation,
          senderAccountId: 'acct_alice',
          senderDeviceId: 'dev_alice',
          kind: 'welcome',
          payload: welcome,
          idempotencyKey: '$idempotencyKey:welcome:$deviceId',
          syncEventId: ++events,
          createdAt: DateTime.now().toUtc(),
          recipientDeviceId: deviceId,
        ),
      );

  Future<void> receive(ReceivedMessageEnvelope envelope) async {
    await service.processApplicationMessage(envelope, ++events);
  }
}

/// A loopback HTTP server standing in for the Veritra server's write
/// endpoints. It records the JSON bodies exactly as the ApiClient sent them.
class _StandInServer {
  _StandInServer._(this._server) {
    _server.listen(_handle);
  }

  static final _commitPath = RegExp(
    r'^/api/v1/conversations/([^/]+)/mls/commits$',
  );

  final HttpServer _server;
  final List<Map<String, Object?>> envelopes = <Map<String, Object?>>[];
  final List<Map<String, Object?>> commits = <Map<String, Object?>>[];

  /// While set, envelope posts wait for it before they are answered.
  Completer<void>? hold;

  static Future<_StandInServer> start() async =>
      _StandInServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response..headers.contentType = ContentType.json;
    try {
      final body = await utf8.decodeStream(request);
      final path = request.uri.path;
      final commit = _commitPath.firstMatch(path);
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer alice-token') {
        response.statusCode = HttpStatus.unauthorized;
        response.write('{"error":"unauthorized"}');
      } else if (request.method == 'POST' &&
          path == '/api/v1/messages/envelopes') {
        await hold?.future;
        envelopes.add(jsonDecode(body) as Map<String, Object?>);
        response.statusCode = HttpStatus.created;
        response.write('{}');
      } else if (request.method == 'POST' && commit != null) {
        final json = jsonDecode(body) as Map<String, Object?>;
        commits.add(<String, Object?>{
          ...json,
          'conversation_id': Uri.decodeComponent(commit.group(1)!),
        });
        response.write(jsonEncode(<String, Object?>{'epoch': json['epoch']}));
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write('{"error":"not_found"}');
      }
    } finally {
      await response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// The real ApiClient; only the read endpoints AppState polls are stubbed,
/// so commits and envelopes cross real HTTP to [_StandInServer].
class _StandInApi extends ApiClient {
  _StandInApi(String baseUrl) : super(baseUrl: baseUrl);

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: _conversation, kind: 'dm')];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      [
        ConversationMember(
            accountId: 'acct_alice', username: 'alice', role: 'member'),
        ConversationMember(
            accountId: 'acct_bob', username: 'bob', role: 'member'),
      ];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      const <SyncEvent>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async =>
      const <MlsPendingChange>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

class _ChangingAuthority implements ConversationAuthority {
  String role = 'admin';
  @override
  String? conversationKind(String conversationId) => 'group';
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) =>
      {'acct_alice', 'acct_bob'};
  @override
  String? roleOf(String conversationId, String accountId) => role;
}
