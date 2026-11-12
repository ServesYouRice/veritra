import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/core/reports_service.dart';
import 'package:private_messenger/crypto/report_body.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

/// L2-3 app step on the real core: messages chosen to go sealed carry a tag
/// for each owner key the sender pinned (designated-verifier franking), are
/// opened with the sender MLS names, recognised when they come back to the
/// sending device, and refused when sealed and identified forms are mixed.
void main() {
  // Skipped without the library, unless VERITRA_REQUIRE_NATIVE_CRYPTO=1.
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    // Two instance owners' report keys the senders pinned.
    _ownerSeeds = <Uint8List>[
      bindings.generateReportKeySeed(),
      bindings.generateReportKeySeed(),
    ];
    _ownerKeys = <Uint8List>[
      for (final seed in _ownerSeeds) bindings.reportPublicKey(seed),
    ];
  });

  test('a sealed message reaches the other member with the MLS sender',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());

    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'quiet'});
    expect(sent.sealed, isTrue);
    expect(bob.tokens.taken, 1);
    // The post body names no device or account.
    final post = sent.toSealedPostJson();
    expect(post.keys.toSet(), <String>{
      'conversation_id',
      'token',
      'idempotency_key',
      'ciphertext',
      'crypto_protocol',
      'crypto_metadata',
      'frank_commit',
    });
    expect(jsonEncode(post), isNot(contains('dev_bob')));
    expect(jsonEncode(post), isNot(contains('acct_bob')));
    // The local outbox copy keeps the token; the session route refuses it.
    expect(MessageEnvelope.fromJson(sent.toJson()).sealed, isTrue);

    final event = alice.nextEvent();
    final opened = await alice.service
        .processSealedApplicationMessage(alice.sealedFrom(sent), event);
    expect(opened.senderAccountId, 'acct_bob');
    expect(opened.senderDeviceId, 'dev_bob');
    expect(await alice.store.loadSyncCursor(), event);
    final row = (await alice.history()).single;
    expect(row.body, 'quiet');
    expect(row.senderAccountId, 'acct_bob');
    expect(row.senderDeviceId, 'dev_bob');
    expect(row.kind, isNot(LocalMessageKind.invalid));

    // C6: the reveal keeps the designation and the sender account, so the
    // message can still be reported; it holds no signature anyone could
    // check, only one tag per pinned owner key.
    final reveal = (await alice.store.loadFrankReveal(row.key))!;
    expect(reveal.sealed, isTrue);
    expect(reveal.senderAccountId, 'acct_bob');
    expect(reveal.designation,
        hasLength(2 * NativeCryptoBindings.l2FrankEntryBytes));
    final bobFrankKey = await bob.service.currentFrankKey();
    for (final seed in _ownerSeeds) {
      expect(
          bindings.l2FrankDvVerify(
            seed: seed,
            senderFrankKey: bobFrankKey,
            conversationId: 'conv_1',
            accountId: 'acct_bob',
            deviceId: 'dev_bob',
            commit: sent.frankCommit!,
            designation: reveal.designation!,
          ),
          1);
    }
    // Alice's own report key (were she an owner nobody pinned) is not named.
    expect(
        bindings.l2FrankDvVerify(
          seed: bindings.generateReportKeySeed(),
          senderFrankKey: bobFrankKey,
          conversationId: 'conv_1',
          accountId: 'acct_bob',
          deviceId: 'dev_bob',
          commit: sent.frankCommit!,
          designation: reveal.designation!,
        ),
        2);
  }, skip: skip);

  test('with no token the message goes identified, and stays so', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'plain'});
    expect(sent.sealed, isFalse);
    expect(bob.tokens.asked, 1);
    await alice.receive(bob, sent);
    final row = (await alice.history()).single;
    expect(row.body, 'plain');
    final reveal = (await alice.store.loadFrankReveal(row.key))!;
    expect(reveal.sealed, isFalse);
  }, skip: skip);

  test('a community or unknown conversation kind sends identified', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    bob.authority.kind = 'announcement';
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'x'});
    expect(sent.sealed, isFalse);
    expect(bob.tokens.asked, 0);
  }, skip: skip);

  test('the sending device recognises its own sealed post by its ciphertext',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'mine'});
    final envelope = bob.sealedFrom(sent);
    final event = bob.nextEvent();
    final opened =
        await bob.service.processSealedApplicationMessage(envelope, event);
    expect(opened.senderDeviceId, 'dev_bob');
    expect(opened.senderAccountId, 'acct_bob');
    expect(await bob.store.loadSyncCursor(), event);
    final row = (await bob.history()).single;
    expect(row.body, 'mine');
    expect(row.serverMessageId, envelope.id);
    expect(row.kind, isNot(LocalMessageKind.invalid));
    // The choice stays with the message after its echo: the cached
    // envelope (what read receipts and the timeline read) is marked sealed,
    // under the server id, with the sender MLS named.
    final cached = (await bob.store.loadSnapshot())!
        .messagesByConversation[envelope.conversationId]!
        .where((item) => item.id == envelope.id)
        .single;
    expect(cached.sealed, isTrue);
    expect(cached.senderDeviceId, 'dev_bob');
    final reread = ReceivedMessageEnvelope.fromJson(cached.toJson());
    expect(reread.sealed, isTrue);
  }, skip: skip);

  // Review H1: a member copies the idempotency key of the victim's
  // identified message onto its own sealed post. The victim must neither
  // take it for its own post (hiding it) nor re-point its own row at it.
  test('a sealed post under the key of an own identified message is not own',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    final mine = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'alice says hi'});
    expect(mine.sealed, isFalse);
    final echo = alice.envelopeFrom(alice, mine);
    await alice.service.processApplicationMessage(echo, alice.nextEvent());
    expect((await alice.history()).single.serverMessageId, echo.id);
    await bob.receive(alice, mine);
    bob.tokens.add(_token());
    final attack = await bob
        .send(AppPayloadType.text, <String, Object?>{'text': 'hidden'});
    expect(attack.sealed, isTrue);
    final forged = ReceivedMessageEnvelope.fromJson(<String, Object?>{
      'id': 'sealed_attack',
      'conversation_id': attack.conversationId,
      'idempotency_key': mine.idempotencyKey,
      'ciphertext': base64Encode(attack.ciphertext),
      'crypto_protocol': attack.cryptoProtocol,
      'crypto_metadata': attack.cryptoMetadata,
      'frank_commit': base64Encode(attack.frankCommit!),
      'sealed': true,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final opened = await alice.service
        .processSealedApplicationMessage(forged, alice.nextEvent());
    // Not taken for Alice's own post: MLS names Bob's device (Bob's action
    // id inside differs from the clear key, so it is no readable message).
    expect(opened.senderDeviceId, isNot('dev_alice'));
    final rows = await alice.history();
    final own = rows.singleWhere((row) => row.senderDeviceId == 'dev_alice');
    expect(own.body, 'alice says hi');
    expect(own.serverMessageId, echo.id);
    expect(rows.any((row) => row.serverMessageId == 'sealed_attack'), isTrue);
  }, skip: skip);

  // Review H1, the store half: an own echo never re-points a row that is
  // already linked to another server id.
  test('an own echo never overwrites a linked server id', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    final mine = await alice
        .send(AppPayloadType.text, <String, Object?>{'text': 'linked'});
    final echo = alice.envelopeFrom(alice, mine);
    await alice.service.processApplicationMessage(echo, alice.nextEvent());
    final again = ReceivedMessageEnvelope(
      id: 'srv_other',
      conversationId: echo.conversationId,
      senderAccountId: echo.senderAccountId,
      senderDeviceId: echo.senderDeviceId,
      idempotencyKey: echo.idempotencyKey,
      ciphertext: echo.ciphertext,
      cryptoProtocol: echo.cryptoProtocol,
      createdAt: echo.createdAt,
      frankCommit: echo.frankCommit,
    );
    await alice.service.processApplicationMessage(again, alice.nextEvent());
    expect((await alice.history()).single.serverMessageId, echo.id);
  }, skip: skip);

  test('an own sealed post the device no longer holds becomes a placeholder',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'gone'});
    // A server replaying the post under a key this device never used: MLS
    // cannot open a message for its own sender, and sync moves on.
    final replayed = ReceivedMessageEnvelope(
      id: 'srv_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: '',
      senderDeviceId: '',
      idempotencyKey: 'another-key-aaaaaaaaaaaaaaaaaaaaaa',
      ciphertext: sent.ciphertext,
      cryptoProtocol: sent.cryptoProtocol,
      createdAt: DateTime.now().toUtc(),
      frankCommit: sent.frankCommit,
      sealed: true,
    );
    final event = bob.nextEvent();
    final opened =
        await bob.service.processSealedApplicationMessage(replayed, event);
    expect(opened.senderDeviceId, isEmpty);
    expect(await bob.store.loadSyncCursor(), event);
    final placeholder = (await bob.history())
        .firstWhere((row) => row.key.startsWith('undecryptable:'));
    expect(placeholder.kind, LocalMessageKind.invalid);
    expect(placeholder.senderAccountId, isEmpty);
  }, skip: skip);

  test('a designated payload is invalid when it comes identified', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'mixed'});
    expect(sent.sealed, isTrue);
    await alice.receive(bob, sent);
    final row = (await alice.history()).single;
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.body, isNull);
    expect(await alice.store.loadFrankReveal(row.key), isNull);
  }, skip: skip);

  // With no owner key pinned the message still goes sealed, in the plain
  // form: it is provable to nobody (owner decision 4).
  test('with no pinned owner key a sealed message goes in the plain form',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    bob.tokens.frankContext = SealedFrankContext(
        listedKey: await bob.service.currentFrankKey(),
        ownerKeys: const <List<int>>[]);
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'plain'});
    expect(sent.sealed, isTrue);
    await alice.service.processSealedApplicationMessage(
        alice.sealedFrom(sent), alice.nextEvent());
    final row = (await alice.history()).single;
    expect(row.body, 'plain');
    expect(row.kind, isNot(LocalMessageKind.invalid));
    final reveal = (await alice.store.loadFrankReveal(row.key))!;
    expect(reveal.sealed, isTrue);
    // The plain form is kept as no designation.
    expect(reveal.designation ?? const <int>[], isEmpty);
    expect(ReportBody.fromReveal(reveal).designation, isEmpty);
  }, skip: skip);

  // Fail safe: without a verified franking context (no listed key) the
  // token goes back and the message goes identified.
  test('with no franking context the message goes identified', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    bob.tokens.frankContext = null;
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'safe'});
    expect(sent.sealed, isFalse);
    expect(bob.tokens.held, 1);
    await alice.receive(bob, sent);
    expect((await alice.history()).single.body, 'safe');
  }, skip: skip);

  // A context naming a key that is not this device's own fails the send
  // closed (the listed key is the device's fixed key, or nothing is sent).
  test('a listed key that is not the own franking key refuses the send',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    bob.tokens.frankContext = SealedFrankContext(
        listedKey: await alice.service.currentFrankKey(),
        ownerKeys: _ownerKeys);
    await expectLater(
        bob.send(AppPayloadType.text, <String, Object?>{'text': 'no'}),
        throwsA(anything));
    expect(bob.tokens.held, 1);
    expect(await alice.history(), isEmpty);
  }, skip: skip);

  test('the sealed and identified paths refuse each other', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'y'});
    final cursor = await alice.store.loadSyncCursor();
    await expectLater(
        alice.service.processApplicationMessage(
            alice.sealedFrom(sent), alice.nextEvent()),
        throwsFormatException);
    await expectLater(
        alice.service.processSealedApplicationMessage(
            alice.envelopeFrom(bob, sent), alice.nextEvent()),
        throwsFormatException);
    expect(await alice.store.loadSyncCursor(), cursor);
    expect(await alice.history(), isEmpty);
  }, skip: skip);

  // Review M2: on sealed_not_eligible (nothing stored under the key) the
  // queued sealed message is encrypted afresh, identified, in its place.
  test('a refused sealed message is re-encrypted identified, afresh', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    const words = 'kept only on this device';
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': words});
    expect(sent.sealed, isTrue);
    // The plaintext kept for the fallback is never in the outbox JSON.
    expect(jsonEncode(sent.toJson()), isNot(contains(words)));
    expect(
        await bob.store
            .loadSealedOwnPostFallback('conv_1', sent.idempotencyKey),
        contains(words));
    await bob.store.recordOutboxFailure(sent.idempotencyKey,
        failureClass: 'terminal:409:sealed_not_eligible',
        terminal: true,
        nextAttemptAt: null);

    final again = await bob.service.reencryptSealedAsIdentified(sent);
    expect(again, isNotNull);
    expect(again!.sealed, isFalse);
    expect(again.idempotencyKey, sent.idempotencyKey);
    expect(again.ciphertext, isNot(sent.ciphertext));
    expect(again.frankCommit, isNot(sent.frankCommit));
    expect(bob.tokens.taken, 1);
    // What goes on the wire carries no token and no plaintext.
    final wire = jsonEncode(again.toJson());
    expect(wire, isNot(contains(words)));
    expect(wire, isNot(contains('l2_sealed_token')));
    // It took the sealed entry's place, failure cleared.
    final queued = (await bob.store.pendingEnvelopeRecords()).single;
    expect(queued.envelope.sealed, isFalse);
    expect(queued.envelope.ciphertext, again.ciphertext);
    expect(queued.terminal, isFalse);
    expect(queued.attemptCount, 0);
    // The digest stays, for a late echo of the sealed attempt; the
    // plaintext is gone.
    expect(
        await bob.store.loadSealedOwnPostDigest('conv_1', sent.idempotencyKey),
        hasLength(32));
    expect(
        await bob.store
            .loadSealedOwnPostFallback('conv_1', sent.idempotencyKey),
        isNull);
    // One message only, still pending.
    expect(await bob.history(), hasLength(1));
    // There is nothing left to fall back with.
    expect(await bob.service.reencryptSealedAsIdentified(sent), isNull);
    expect(await bob.service.reencryptSealedAsIdentified(again), isNull);

    // The other member reads it identified: no sealed signature inside.
    await alice.receive(bob, again);
    final row = (await alice.history()).single;
    expect(row.body, words);
    expect(row.senderDeviceId, 'dev_bob');
    expect((await alice.store.loadFrankReveal(row.key))!.sealed, isFalse);
  }, skip: skip);

  test('a token taken for a send that fails goes back', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    await expectLater(
        bob.service.encryptPayload(
            'conv_1', AppPayloadType.text, <String, Object?>{'text': 7}),
        throwsA(anything));
    expect(bob.tokens.held, 1);
    expect(bob.tokens.taken, 1);
  }, skip: skip);

  // Verification (b), (c), (d) on the real encrypted database: a processed
  // sealed ciphertext cannot be opened again, nothing kept is a signature
  // over the payload (database, history export), and the write-ahead log
  // holding the MLS state from before the message is truncated.
  test('a processed sealed message leaves nothing that proves it to others',
      () async {
    final directory = await Directory.systemTemp.createTemp('veritra-l2-res-');
    final databases = <EncryptedLocalDatabase>[];
    addTearDown(() async {
      for (final db in databases) {
        await db.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final drift = SecureLocalStore(
      storage: const FlutterSecureStorage(),
      directoryProvider: () async => directory,
      databaseFactory: (file, key) {
        final db = openEncryptedLocalDatabase(file, key);
        databases.add(db);
        return db;
      },
    );
    final alice =
        await _Client.enroll(bindings, 'acct_alice', 'dev_alice', store: drift);
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    const words = 'said once, provable to no one else';
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': words});
    expect(sent.sealed, isTrue);
    final first = alice.sealedFrom(sent);
    await alice.service
        .processSealedApplicationMessage(first, alice.nextEvent());
    final row = (await alice.history()).single;
    expect(row.body, words);
    final reveal = (await alice.store.loadFrankReveal(row.key))!;

    // (b) The same ciphertext again (a server replay under a new id, or a
    // copy kept by whoever took the device): MLS deleted the key with the
    // message, so it opens to a placeholder, never a second reading.
    final again = ReceivedMessageEnvelope.fromJson(<String, Object?>{
      ...first.toJson(),
      'id': 'sealed_replay_${++_serverIds}',
      'idempotency_key': 'replayed-key-aaaaaaaaaaaaaaaa',
    });
    final reopened = await alice.service
        .processSealedApplicationMessage(again, alice.nextEvent());
    expect(reopened.senderDeviceId, isEmpty);
    final rows = await alice.history();
    expect(rows.where((item) => item.body == words), hasLength(1));
    expect(
        rows.where((item) => item.key.startsWith('undecryptable:')).single.kind,
        LocalMessageKind.invalid);

    // (c) No column of any table holds a signature: the only signing-named
    // columns are device public keys (L1 pins, approval leaves, invite
    // anchors); the reveal keeps the C6 key and the designation alone.
    final db = databases.single;
    final tables = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
        .map((item) => item.read<String>('name'));
    final named = <String>{};
    for (final table in tables) {
      for (final column in (await db
              .customSelect("SELECT name FROM pragma_table_info('$table')")
              .get())
          .map((item) => item.read<String>('name'))) {
        // `designation` holds tags, not a signature (checked below).
        if (RegExp(r'(^|_)(sig|sign|signature|signing)(_|$)|signature',
                caseSensitive: false)
            .hasMatch(column)) {
          named.add('$table.$column');
        }
      }
    }
    expect(named, <String>{
      'local_device_list_keys.signing_key',
      'local_approval_leaves.signing_key',
      'local_invite_anchors.signing_key',
    });
    final revealColumns = (await db
            .customSelect("SELECT name FROM pragma_table_info"
                "('local_frank_reveals')")
            .get())
        .map((item) => item.read<String>('name'))
        .toSet();
    expect(revealColumns, <String>{
      'message_key',
      'conversation_id',
      'envelope_id',
      'frank_key',
      'payload',
      'stored_at',
      // Sealed is a reveal that names its sender account.
      'designation',
      'sender_account_id',
    });
    expect(reveal.designation,
        hasLength(2 * NativeCryptoBindings.l2FrankEntryBytes));
    // The history export (K1 backup, K2 transfer) carries the message, not
    // its franking: no key, no designation, no commitment.
    await alice.store.saveSession(const Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    ));
    final cached = await alice.store.loadSnapshot();
    await alice.store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
        cached?.messagesByConversation ??
            const <String, List<ReceivedMessageEnvelope>>{},
        await alice.store.loadSyncCursor());
    final exported = utf8.decode(await alice.store.exportHistorySnapshot());
    expect(exported, contains(words));
    for (final kept in <List<int>>[
      reveal.frankKey,
      reveal.designation!,
      sent.frankCommit!,
    ]) {
      expect(exported, isNot(contains(base64Encode(kept))));
    }
    expect(exported, isNot(contains('designation')));

    // (d) The log held the state from before the message; after the
    // checkpoint it is empty.
    final wal = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('-wal'))
        .single;
    expect(wal.lengthSync(), greaterThan(0));
    expect(await alice.store.checkpointSealedResidue(), isTrue);
    expect(wal.lengthSync(), 0);
  }, skip: skip);

  // Owner item 3: the key a list names is the device's fixed key. It is in
  // the stored state before anything can list it, and survives a reload.
  test('the franking key is sealed before it is listed and stays the same',
      () async {
    final store = MemoryLocalStore();
    final first =
        TestNativeCryptoService(bindings: bindings, localStore: store);
    await first.createEnrollmentCredential(const EnrollmentReservation(
      id: 'res_dev_keep',
      accountId: 'acct_keep',
      deviceId: 'dev_keep',
      challenge: <int>[1, 2, 3],
    ));
    const session = Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: 'acct_keep',
      deviceId: 'dev_keep',
    );
    await first.activateSession(session);
    final before = (await store.loadCryptoState())!.counter;
    final key = await first.currentFrankKey();
    expect((await store.loadCryptoState())!.counter, before + 1);
    // Sealed once per load, not on every read.
    expect(await first.currentFrankKey(), key);
    expect((await store.loadCryptoState())!.counter, before + 1);
    // Another process loading the same record has the same key.
    final again =
        TestNativeCryptoService(bindings: bindings, localStore: store);
    await again.activateSession(session);
    expect(await again.currentFrankKey(), key);
  }, skip: skip);

  test('a sealed message is proven only to the owners it designates', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    final bobFrankKey = await bob.service.currentFrankKey();

    Future<(ReportBody, MessageEnvelope, ReceivedMessageEnvelope)> sealedReport(
        String text) async {
      bob.tokens.add(_token());
      final sent =
          await bob.send(AppPayloadType.text, <String, Object?>{'text': text});
      expect(sent.sealed, isTrue);
      final envelope = alice.sealedFrom(sent);
      await alice.service
          .processSealedApplicationMessage(envelope, alice.nextEvent());
      final row =
          (await alice.history()).singleWhere((item) => item.body == text);
      final reveal = (await alice.store.loadFrankReveal(row.key))!;
      // The reporter's body is version 2 and survives the seal round trip.
      final body = ReportBody.decode(ReportBody.fromReveal(reveal).encode());
      expect(body.sealed, isTrue);
      expect(body.senderAccountId, 'acct_bob');
      expect(jsonDecode(utf8.decode(body.encode()))['v'], 2);
      return (body, sent, envelope);
    }

    final (body, sent, envelope) = await sealedReport('reportable');
    Map<String, Object?> recordJson(String key) => <String, Object?>{
          'envelope_id': envelope.id,
          'conversation_id': 'conv_1',
          'frank_commit': base64Encode(sent.frankCommit!),
          'sealed': true,
          'idempotency_key': key,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };
    final server = _ReportServer(
        ReportEnvelopeRecord.fromJson(recordJson(sent.idempotencyKey)));
    // A sealed record must name its key.
    expect(
        () => ReportEnvelopeRecord.fromJson(
            recordJson(sent.idempotencyKey)..remove('idempotency_key')),
        throwsFormatException);

    // An owner whose current report seed is [seed]; [frankKey] answers what
    // the claimed account's verified device list says.
    Future<ReportVerification> verifyAs(ReportBody reported, List<int>? seed,
        {Future<Uint8List?> Function(String, String)? frankKey}) async {
      final seeds = MemoryReportSeedStore();
      if (seed != null) {
        await seeds.save(
            server.baseUrl, 'acct_owner', Uint8List.fromList(seed));
      }
      final owner = ReportsService(
        api: server,
        token: 'acct_owner',
        accountId: 'acct_owner',
        crypto: alice.service,
        store: MemoryLocalStore(),
        seeds: seeds,
        senderFrankKey: frankKey,
      );
      return owner.verify(OpenedReport(_row(), body: reported));
    }

    var lookups = 0;
    Future<Uint8List?> bobsList(String account, String device) async {
      lookups++;
      return account == 'acct_bob' && device == 'dev_bob'
          ? Uint8List.fromList(bobFrankKey)
          : null;
    }

    Future<Uint8List?> anyAccount(String account, String device) async =>
        Uint8List.fromList(bobFrankKey);

    // Both pinned owners verify it, each with its own seed.
    for (final seed in _ownerSeeds) {
      final verified = await verifyAs(body, seed, frankKey: bobsList);
      expect(verified.verdict, ReportVerdict.verified);
      expect(verified.record!.senderAccountId, 'acct_bob');
      expect(verified.record!.senderDeviceId, 'dev_bob');
    }

    // Owner 2 rotates its report key: the old proof lapses, and no device
    // list is fetched for an owner the message does not name.
    lookups = 0;
    expect(
        (await verifyAs(body, bindings.generateReportKeySeed(),
                frankKey: bobsList))
            .verdict,
        ReportVerdict.notDesignated);
    expect(lookups, 0);
    // An owner with no seed at all.
    expect((await verifyAs(body, null, frankKey: bobsList)).verdict,
        ReportVerdict.notDesignated);

    // A tampered tag: the kid still names owner 1, the tag fails.
    final tampered = List<int>.of(body.designation!);
    tampered[tampered.length - 1] ^= 1;
    tampered[NativeCryptoBindings.l2FrankEntryBytes - 1] ^= 1;
    expect(
        (await verifyAs(_withBody(body, designation: tampered), _ownerSeeds[0],
                frankKey: bobsList))
            .verdict,
        ReportVerdict.proofFailed);

    // Review low (b): a member re-posts Bob's ciphertext and commitment
    // sealed under another key. A report naming that copy is not
    // attributed to Bob.
    final original = server.record;
    server.record = ReportEnvelopeRecord.fromJson(recordJson('k' * 48));
    expect((await verifyAs(body, _ownerSeeds[0], frankKey: bobsList)).verdict,
        ReportVerdict.mismatch);
    server.record = original;

    // No device-list check wired: never attributed (fails closed).
    expect((await verifyAs(body, _ownerSeeds[0])).verdict,
        ReportVerdict.senderUnverified);
    // The claimed account lists no franking key for the device.
    expect(
        (await verifyAs(body, _ownerSeeds[0], frankKey: (a, d) async => null))
            .verdict,
        ReportVerdict.senderUnverified);
    // Another device's key (Alice's) in place of Bob's.
    final aliceFrankKey = await alice.service.currentFrankKey();
    expect(
        (await verifyAs(body, _ownerSeeds[0],
                frankKey: (a, d) async => aliceFrankKey))
            .verdict,
        ReportVerdict.proofFailed);

    // Framing: the reporter names another account. The tag covers the
    // account, so even a list that answered Bob's key does not verify.
    expect(
        (await verifyAs(
                _withBody(body, senderAccountId: 'acct_carol'), _ownerSeeds[0],
                frankKey: anyAccount))
            .verdict,
        ReportVerdict.proofFailed);
    // A version-1 body about a sealed record cannot be attributed.
    expect(
        (await verifyAs(_withBody(body, plain: true), _ownerSeeds[0],
                frankKey: anyAccount))
            .verdict,
        ReportVerdict.mismatch);
    // The plain form (designation stripped) is provable to nobody.
    expect(
        (await verifyAs(
                _withBody(body, designation: const <int>[]), _ownerSeeds[0],
                frankKey: bobsList))
            .verdict,
        ReportVerdict.notDesignated);

    // A message sent with no pinned owner key: no owner can prove it.
    bob.tokens.frankContext = SealedFrankContext(
        listedKey: bobFrankKey, ownerKeys: const <List<int>>[]);
    final (unpinned, unpinnedSent, unpinnedEnvelope) =
        await sealedReport('unpinned');
    expect(unpinned.designation, isEmpty);
    server.record = ReportEnvelopeRecord.fromJson(<String, Object?>{
      'envelope_id': unpinnedEnvelope.id,
      'conversation_id': 'conv_1',
      'frank_commit': base64Encode(unpinnedSent.frankCommit!),
      'sealed': true,
      'idempotency_key': unpinnedSent.idempotencyKey,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    for (final seed in _ownerSeeds) {
      expect((await verifyAs(unpinned, seed, frankKey: bobsList)).verdict,
          ReportVerdict.notDesignated);
    }

    // Owner 1 alone pinned: owner 2 is not designated, owner 1 is.
    bob.tokens.frankContext = SealedFrankContext(
        listedKey: bobFrankKey, ownerKeys: <List<int>>[_ownerKeys[0]]);
    final (single, singleSent, singleEnvelope) = await sealedReport('single');
    expect(
        single.designation, hasLength(NativeCryptoBindings.l2FrankEntryBytes));
    server.record = ReportEnvelopeRecord.fromJson(<String, Object?>{
      'envelope_id': singleEnvelope.id,
      'conversation_id': 'conv_1',
      'frank_commit': base64Encode(singleSent.frankCommit!),
      'sealed': true,
      'idempotency_key': singleSent.idempotencyKey,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    expect((await verifyAs(single, _ownerSeeds[0], frankKey: bobsList)).verdict,
        ReportVerdict.verified);
    expect((await verifyAs(single, _ownerSeeds[1], frankKey: bobsList)).verdict,
        ReportVerdict.notDesignated);
  }, skip: skip);
}

ReportBody _withBody(ReportBody body,
        {String? senderAccountId,
        List<int>? designation,
        bool plain = false}) =>
    ReportBody(
      envelopeId: body.envelopeId,
      conversationId: body.conversationId,
      senderDeviceId: body.senderDeviceId,
      actionId: body.actionId,
      payload: body.payload,
      frankKey: body.frankKey,
      senderAccountId: plain ? null : (senderAccountId ?? body.senderAccountId),
      designation: plain ? null : (designation ?? body.designation),
    );

List<Uint8List> _ownerSeeds = <Uint8List>[];
List<Uint8List> _ownerKeys = <Uint8List>[];

int _serverIds = 0;

SealedToken _token() => SealedToken(
      conversationId: 'conv_1',
      keyId: 'k' * 32,
      epoch: 20000,
      nonce: List<int>.generate(32, (i) => i + _serverIds++ % 7),
      output: List<int>.filled(64, 9),
    );

class _Tokens implements SealedTokenSource {
  final List<SealedToken> _held = <SealedToken>[];

  @override
  SealedFrankContext? frankContext;
  int asked = 0;
  int taken = 0;
  int get held => _held.length;

  void add(SealedToken token) => _held.add(token);

  @override
  Future<SealedToken?> takeFor(String conversationId) async {
    asked++;
    if (_held.isEmpty) return null;
    taken++;
    return _held.removeAt(0);
  }

  @override
  Future<void> putBack(SealedToken token) async => _held.add(token);
}

class _Authority implements ConversationAuthority {
  String kind = 'dm';
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) =>
      const <String>{'acct_alice', 'acct_bob'};
  @override
  String? roleOf(String conversationId, String accountId) => 'member';
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: 'conv_1',
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: bundle.welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final LocalStore store;
  final String accountId;
  final String deviceId;
  final _Tokens tokens = _Tokens();
  final _Authority authority = _Authority();
  int _events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId,
      {LocalStore? store}) async {
    final local = store ?? MemoryLocalStore();
    final service =
        TestNativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    ));
    final client = _Client(service, local, accountId, deviceId);
    service.conversationAuthority = client.authority;
    service.sealedTokenSource = client.tokens;
    // What the token pass caches: the own key as the verified list names
    // it, and the owner keys this app pinned.
    client.tokens.frankContext = SealedFrankContext(
        listedKey: await service.currentFrankKey(), ownerKeys: _ownerKeys);
    return client;
  }

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<List<LocalMessage>> history() => store.loadMessages('conv_1');

  /// Encrypts; the outbox entry stays (as until the post is answered), so
  /// the device can recognise its own sealed post.
  Future<MessageEnvelope> send(
          AppPayloadType type, Map<String, Object?> body) =>
      service.encryptPayload('conv_1', type, body);

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
        frankCommit: sent.frankCommit,
      );

  /// What `message.sealed.created` carries: no sender at all.
  ReceivedMessageEnvelope sealedFrom(MessageEnvelope sent) =>
      ReceivedMessageEnvelope.fromJson(<String, Object?>{
        'id': 'sealed_${++_serverIds}',
        'conversation_id': sent.conversationId,
        'idempotency_key': sent.idempotencyKey,
        'ciphertext': base64Encode(sent.ciphertext),
        'crypto_protocol': sent.cryptoProtocol,
        'crypto_metadata': sent.cryptoMetadata,
        if (sent.frankCommit != null)
          'frank_commit': base64Encode(sent.frankCommit!),
        'sealed': true,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(envelopeFrom(from, sent), nextEvent());
}

ReportCopyRow _row() => ReportCopyRow(
      id: 'row_1',
      reportId: 'report_1',
      inboxKind: 'instance_owner',
      inboxId: 'acct_owner',
      keyRev: 1,
      recipientPublicKey: List<int>.filled(32, 1),
      conversationId: 'conv_1',
      reporterAccountId: 'acct_alice',
      sealed: const <int>[1],
      createdAt: DateTime.utc(2026, 11, 12),
    );

class _ReportServer extends ApiClient {
  _ReportServer(this.record) : super(baseUrl: 'https://chat.example.org');

  ReportEnvelopeRecord record;

  @override
  Future<ReportEnvelopeRecord> getReportEnvelope(
      String token, String reportRowId, String envelopeId) async {
    if (envelopeId != record.envelopeId) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    return record;
  }
}
