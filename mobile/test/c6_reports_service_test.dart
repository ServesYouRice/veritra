import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/core/reports_service.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/owner_key_watch.dart';
import 'package:private_messenger/crypto/owner_proof_pins.dart';
import 'package:private_messenger/crypto/report_key_announcement.dart';
import 'package:private_messenger/crypto/report_key_pins.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// C6 step 4: the reporter's flow (pin, seal, file) and the owner's inbox
/// (key custody, open, verify, dismiss) against an in-memory server and the
/// real native seal. The in-memory server mimics the routes' rules: one
/// sealed copy per owner at the current keys, copies listed to their owner,
/// the envelope record only for a copy's conversation.

const _origin = 'https://chat.example.org';
const _conversation = 'conv_1';
const _sender = 'dev_sender';
const _action = 'action1';
const _envelope = 'msg_envelope_1';
const _reporterAccount = 'acct_reporter';
const _ownerAccount = 'acct_owner';
const _community = 'comm_1';
const _sharedGroup = 'conv_shared';
const _moderator = 'acct_mod';
const _moderator2 = 'acct_mod2';

class _Store extends MemoryLocalStore {
  final Map<String, FrankReveal> reveals = <String, FrankReveal>{};

  @override
  Future<FrankReveal?> loadFrankReveal(String messageKey) async =>
      reveals[messageKey];
}

class _Server extends ApiClient {
  _Server() : super(baseUrl: _origin);

  String kind = 'instance_owner';
  final Map<String, ReportInboxRecipient> keys = {};
  final List<ReportCopyRow> copies = [];
  ReportEnvelopeRecord? record;
  int nextId = 0;
  int filedReports = 0;
  final List<String> envelopeRequests = [];

  @override
  Future<ReportInbox> getReportInbox(
          String token, String conversationId) async =>
      ReportInbox(kind: kind, recipients: keys.values.toList());

  @override
  Future<ReportInboxRecipient?> getOwnReportKey(String token) async =>
      keys[token];

  @override
  Future<int> putInstanceReportKey(String token, List<int> publicKey) async {
    final old = keys[token];
    final same = old != null && _eq(old.publicKey, publicKey);
    final rev = old == null ? 1 : (same ? old.keyRev : old.keyRev + 1);
    // The token doubles as the owner's account id in this fake.
    keys[token] =
        ReportInboxRecipient(inboxId: token, publicKey: publicKey, keyRev: rev);
    return rev;
  }

  @override
  Future<int> putModeratorReportKey(
      String token, String communityId, List<int> publicKey) async {
    final inbox = communityModeratorInboxId(communityId, token);
    final old = keys[inbox];
    final same = old != null && _eq(old.publicKey, publicKey);
    final rev = old == null ? 1 : (same ? old.keyRev : old.keyRev + 1);
    keys[inbox] =
        ReportInboxRecipient(inboxId: inbox, publicKey: publicKey, keyRev: rev);
    return rev;
  }

  @override
  Future<ReportInboxRecipient?> getOwnModeratorReportKey(
          String token, String communityId) async =>
      keys[communityModeratorInboxId(communityId, token)];

  @override
  Future<List<ReportCopyRow>> listModeratorReports(
          String token, String communityId,
          {String? afterId, int limit = 50}) async =>
      [
        for (final c in copies)
          if (c.inboxId == communityModeratorInboxId(communityId, token)) c
      ];

  @override
  Future<void> createReport(
    String token, {
    required String conversationId,
    required String reportId,
    required List<Map<String, Object?>> copies,
  }) async {
    final wanted = keys.values.toList();
    // The server's rule: the instance owners exactly; for a community a
    // non-empty, duplicate-free subset of the listed keys.
    final community = kind == 'community';
    final inboxes = {for (final raw in copies) raw['inbox_id']};
    if (community
        ? copies.isEmpty || inboxes.length != copies.length
        : copies.length != wanted.length) {
      throw ApiException(409, '{"error":"report_inbox_changed"}');
    }
    for (final raw in copies) {
      final owner = keys[raw['inbox_id']];
      if (owner == null ||
          raw['key_rev'] != owner.keyRev ||
          raw['recipient_public_key'] != base64Encode(owner.publicKey)) {
        throw ApiException(409, '{"error":"report_inbox_changed"}');
      }
      this.copies.add(ReportCopyRow(
            id: 'row_${nextId++}',
            reportId: reportId,
            inboxKind: kind,
            inboxId: owner.inboxId,
            keyRev: owner.keyRev,
            recipientPublicKey: owner.publicKey,
            conversationId: conversationId,
            reporterAccountId: _reporterAccount,
            sealed: base64Decode(raw['sealed'] as String),
            createdAt: DateTime.utc(2026, 11, 7),
          ));
    }
    filedReports++;
  }

  @override
  Future<List<ReportCopyRow>> listOwnerReports(String token,
          {String? afterId, int limit = 50}) async =>
      [
        for (final c in copies)
          if (c.inboxId == token) c
      ];

  @override
  Future<void> deleteReport(String token, String reportRowId) async {
    copies.removeWhere((c) => c.id == reportRowId && c.inboxId == token);
  }

  @override
  Future<ReportEnvelopeRecord> getReportEnvelope(
      String token, String reportRowId, String envelopeId) async {
    envelopeRequests.add(envelopeId);
    final found = record;
    if (found == null || found.envelopeId != envelopeId) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    return found;
  }
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable.generate(a.length).every((i) => a[i] == b[i]);

void main() {
  late NativeCryptoService crypto;
  late _Store store;
  late _Server server;
  late MemoryReportSeedStore seeds;
  late Uint8List frankKey;
  late Uint8List payload;
  late Uint8List commit;

  ReportModerators? moderators;
  var seedChanges = 0;

  ReportsService serviceFor(String account) => ReportsService(
        api: server,
        // The fake server reads the caller's account id from the token.
        token: account,
        accountId: account,
        crypto: crypto,
        store: store,
        seeds: seeds,
        moderatorsOf: (conversationId) => moderators,
        onSeedChanged: () => seedChanges++,
      );

  /// Each moderator's own seed store, as each would hold on its own device.
  final moderatorSeeds = <String, MemoryReportSeedStore>{};

  ReportsService moderatorInbox(String account) => ReportsService(
        api: server,
        token: account,
        accountId: account,
        crypto: crypto,
        store: store,
        seeds: moderatorSeeds.putIfAbsent(account, MemoryReportSeedStore.new),
        onSeedChanged: () => seedChanges++,
      ).forCommunity(_community);

  /// [account]'s app publishes its moderator inbox key in the community.
  Future<List<int>> moderatorPublishes(String account) async {
    final (key, _) = await moderatorInbox(account).createKey();
    return key;
  }

  /// What the reporter's device commits when [account]'s `report_key`
  /// arrives in the shared group from an approved leaf.
  Future<void> announces(String account, List<int> key) async {
    final settings = reportKeySettingsFor(
      DecryptedAppPayload(
          type: AppPayloadType.reportKey,
          actionId: 'a',
          body: {'key': base64Encode(key)}),
      conversationId: _sharedGroup,
      senderAccountId: account,
      isRecordGroup: true,
      verdict: LeafVerdict.approved,
      selfAccountId: _reporterAccount,
      syncEventId: 1,
    );
    expect(settings, hasLength(1));
    for (final entry in settings.entries) {
      await store.saveSetting(entry.key, entry.value!);
    }
  }

  ReportModerators verified(Set<String> accounts) =>
      ReportModerators(_community, accounts, recordGroupId: _sharedGroup);

  void keepReveal(String action, String envelopeId) {
    store.reveals['$_sender:$action'] = FrankReveal(
      messageKey: '$_sender:$action',
      conversationId: _conversation,
      envelopeId: envelopeId,
      frankKey: frankKey,
      payload: payload,
    );
  }

  setUp(() async {
    moderators = null;
    seedChanges = 0;
    moderatorSeeds.clear();
    // The tests that need the native seal fail on `crypto` when the library
    // is required and missing; the model and store tests run without it.
    if (nativeCryptoLibraryPath == null) return;
    crypto = NativeCryptoService(
        bindings: NativeCryptoBindings.open(requireNativeCryptoLibrary()),
        localStore: MemoryLocalStore());
    store = _Store();
    server = _Server();
    seeds = MemoryReportSeedStore();
    frankKey = Uint8List.fromList(List<int>.filled(32, 9));
    payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 2,
      'type': 'text',
      'conversation_id': _conversation,
      'sender_device_id': _sender,
      'action_id': _action,
      'body': {'text': 'the reported words'},
    })));
    commit = await crypto.frankCommit(
      key: frankKey,
      conversationId: _conversation,
      senderDeviceId: _sender,
      actionId: _action,
      payload: payload,
    );
    store.reveals['$_sender:$_action'] = FrankReveal(
      messageKey: '$_sender:$_action',
      conversationId: _conversation,
      envelopeId: _envelope,
      frankKey: frankKey,
      payload: payload,
    );
    server.record = ReportEnvelopeRecord(
      envelopeId: _envelope,
      conversationId: _conversation,
      senderAccountId: 'acct_sender',
      senderDeviceId: _sender,
      frankCommit: commit,
      createdAt: DateTime.utc(2026, 11, 7),
    );
  });

  Future<void> ownerSetsUpKey() async {
    await serviceFor(_ownerAccount).createKey();
  }

  Future<void> reporterTrustsAndFiles() async {
    final reporter = serviceFor(_reporterAccount);
    final plan = await reporter.prepare(_conversation);
    await reporter.pinKeys(plan);
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:$_action');
  }

  final Object nativeSkip = nativeCryptoSkip();

  test(
      'owner key custody: the seed stays on this device, republishing is stable',
      () async {
    final owner = serviceFor(_ownerAccount);
    expect((await owner.keyStatus()).state, OwnerReportKeyState.none);
    final (key, rev) = await owner.createKey();
    expect(rev, 1);
    final status = await owner.keyStatus();
    expect(status.state, OwnerReportKeyState.active);
    expect(status.localKey, key);
    expect(status.listedKey, key);
    // Creating again would silently lose the seed: refused unless replacing.
    await expectLater(owner.createKey(), throwsStateError);
    final (again, sameRev) = await owner.publishKey();
    expect(again, key);
    expect(sameRev, 1);
    // A second device holds no seed: the key is held elsewhere, and making a
    // new one is an explicit replace.
    final other = ReportsService(
      api: server,
      token: _ownerAccount,
      accountId: _ownerAccount,
      crypto: crypto,
      store: store,
      seeds: MemoryReportSeedStore(),
    );
    expect((await other.keyStatus()).state, OwnerReportKeyState.heldElsewhere);
    final (replacement, newRev) = await other.createKey(replace: true);
    expect(replacement, isNot(key));
    expect(newRev, 2);
    // The first device now sees the key reporters see, and that it is not its
    // own.
    final first = await owner.keyStatus();
    expect(first.state, OwnerReportKeyState.replacedElsewhere);
    expect(first.listedKey, replacement);
    expect(first.localKey, key);
    // A seed whose key was never published reads as unpublished.
    server.keys.clear();
    expect((await owner.keyStatus()).state, OwnerReportKeyState.unpublished);
  }, skip: nativeSkip);

  test('report round trip: pin, file, open, verify, dismiss', () async {
    await ownerSetsUpKey();
    final reporter = serviceFor(_reporterAccount);

    // First sight of the owner's key: refused until a person pins it.
    final plan = await reporter.prepare(_conversation);
    expect(plan.canSend, isFalse);
    expect(plan.check.recipients.single.status, ReportKeyStatus.unpinned);
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.keysNotPinned)));
    expect(server.copies, isEmpty);

    await reporter.pinKeys(plan);
    expect((await reporter.prepare(_conversation)).canSend, isTrue);
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:$_action');
    expect(server.copies, hasLength(1));
    // The server sees no envelope id and no text in what it stored.
    final stored =
        utf8.decode(server.copies.single.sealed, allowMalformed: true);
    expect(stored, isNot(contains(_envelope)));
    expect(stored, isNot(contains('the reported words')));
    expect(server.envelopeRequests, isEmpty);

    // A second tap on the same message files nothing more.
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.alreadyReported)));
    expect(server.filedReports, 1);

    // The owner opens it; listing and opening touch the server not at all
    // about the envelope.
    final owner = serviceFor(_ownerAccount);
    final rows = await owner.list();
    final opened = await owner.open(rows.single);
    expect(opened.isOpen, isTrue);
    expect(opened.text, 'the reported words');
    expect(opened.body!.envelopeId, _envelope);
    expect(server.envelopeRequests, isEmpty);

    // Verifying asks the server for exactly that envelope.
    final verdict = await owner.verify(opened);
    expect(verdict.verdict, ReportVerdict.verified);
    expect(server.envelopeRequests, [_envelope]);

    await owner.dismiss(rows.single);
    expect(await owner.list(), isEmpty);
  }, skip: nativeSkip);

  test('verification refuses what the server record contradicts', () async {
    await ownerSetsUpKey();
    await reporterTrustsAndFiles();
    final owner = serviceFor(_ownerAccount);
    final opened = await owner.open((await owner.list()).single);

    Future<ReportVerdict> verdictFor(ReportEnvelopeRecord? record) async {
      server.record = record;
      return (await owner.verify(opened)).verdict;
    }

    ReportEnvelopeRecord with_({
      String? conversation,
      String? device,
      List<int>? commit_,
      bool noCommit = false,
    }) =>
        ReportEnvelopeRecord(
          envelopeId: _envelope,
          conversationId: conversation ?? _conversation,
          senderAccountId: 'acct_sender',
          senderDeviceId: device ?? _sender,
          frankCommit: noCommit ? null : (commit_ ?? commit),
          createdAt: DateTime.utc(2026, 11, 7),
        );

    expect(await verdictFor(with_()), ReportVerdict.verified);
    expect(await verdictFor(with_(commit_: List<int>.filled(32, 1))),
        ReportVerdict.mismatch);
    expect(
        await verdictFor(with_(device: 'dev_other')), ReportVerdict.mismatch);
    expect(await verdictFor(with_(conversation: 'conv_2')),
        ReportVerdict.mismatch);
    expect(await verdictFor(with_(noCommit: true)), ReportVerdict.unfranked);
    expect(await verdictFor(null), ReportVerdict.recordGone);
  }, skip: nativeSkip);

  test('a forged body (wrong key) does not verify', () async {
    await ownerSetsUpKey();
    // The reporter does not know kf: it reveals a made-up one.
    store.reveals['$_sender:$_action'] = FrankReveal(
      messageKey: '$_sender:$_action',
      conversationId: _conversation,
      envelopeId: _envelope,
      frankKey: List<int>.filled(32, 3),
      payload: payload,
    );
    await reporterTrustsAndFiles();
    final owner = serviceFor(_ownerAccount);
    final opened = await owner.open((await owner.list()).single);
    expect((await owner.verify(opened)).verdict, ReportVerdict.mismatch);
  }, skip: nativeSkip);

  test('a changed owner key is refused until pinned again', () async {
    await ownerSetsUpKey();
    final reporter = serviceFor(_reporterAccount);
    await reporter.pinKeys(await reporter.prepare(_conversation));
    // The owner replaces the key (new device): the old pin no longer matches.
    await ReportsService(
      api: server,
      token: _ownerAccount,
      accountId: _ownerAccount,
      crypto: crypto,
      store: store,
      seeds: MemoryReportSeedStore(),
    ).createKey(replace: true);
    final plan = await reporter.prepare(_conversation);
    expect(plan.check.recipients.single.status, ReportKeyStatus.changed);
    expect(plan.canSend, isFalse);
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.keysNotPinned)));
    expect(server.copies, isEmpty);
  }, skip: nativeSkip);

  // L2-3, owner decision 2026-11-12 ("Keep reports manual"): an owner key
  // pinned on first use goes to the sealed-message proofs only. Reporting
  // still shows the code first, and nothing is sealed to that key until the
  // person compared it.
  test('a key pinned on first use for proofs still needs the code to report',
      () async {
    await ownerSetsUpKey();
    final listed = server.keys[_ownerAccount]!.publicKey;
    final watch = OwnerKeyWatch(store, _origin);
    expect(
        await watch.observe(
            await server.getReportInbox(_reporterAccount, _conversation)),
        isTrue);
    expect([
      for (final pin in await OwnerProofPins(store, _origin).effective())
        pin.publicKey
    ], [
      listed
    ]);
    expect(await store.loadReportKeyPins(_origin), isEmpty);

    final reporter = serviceFor(_reporterAccount);
    final plan = await reporter.prepare(_conversation);
    expect(plan.canSend, isFalse);
    expect(plan.check.recipients.single.status, ReportKeyStatus.unpinned);
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.keysNotPinned)));
    expect(server.copies, isEmpty);
    expect(server.filedReports, 0);

    // The person compares the code: then, and only then, it is sent.
    await reporter.pinKeys(plan);
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:$_action');
    expect(server.copies.single.recipientPublicKey, listed);
  }, skip: nativeSkip);

  test('a key compared while reporting replaces a first-use proof key',
      () async {
    // The server lists a key of its own at first sight: pinned for proofs.
    final made = List<int>.filled(32, 0x5a);
    server.keys[_ownerAccount] = ReportInboxRecipient(
        inboxId: _ownerAccount, publicKey: made, keyRev: 1);
    final watch = OwnerKeyWatch(store, _origin);
    Future<bool> observe() async => watch
        .observe(await server.getReportInbox(_reporterAccount, _conversation));
    expect(await observe(), isTrue);

    // The real owner key is listed later; the person compares its code.
    await ownerSetsUpKey();
    final real = server.keys[_ownerAccount]!.publicKey;
    final reporter = serviceFor(_reporterAccount);
    await reporter.pinKeys(await reporter.prepare(_conversation));
    expect([
      for (final pin in await OwnerProofPins(store, _origin).effective())
        pin.publicKey
    ], [
      real
    ]);
    expect(await observe(), isFalse);
    expect(await watch.review(), isEmpty);
  }, skip: nativeSkip);

  test('a key accepted on the sealed key screen is not a report key', () async {
    await ownerSetsUpKey();
    final reporter = serviceFor(_reporterAccount);
    // The person compared the owner's first key while reporting.
    await reporter.pinKeys(await reporter.prepare(_conversation));
    final watch = OwnerKeyWatch(store, _origin);
    Future<void> observe() async => watch
        .observe(await server.getReportInbox(_reporterAccount, _conversation));
    await observe();
    expect(await watch.review(), isEmpty);

    // The server lists another key (the owner's new device, or its own),
    // and the person accepts it for proofs.
    await ReportsService(
      api: server,
      token: _ownerAccount,
      accountId: _ownerAccount,
      crypto: crypto,
      store: store,
      seeds: MemoryReportSeedStore(),
    ).createKey(replace: true);
    final replaced = server.keys[_ownerAccount]!.publicKey;
    await observe();
    expect(await watch.accept((await watch.review()).single), isTrue);
    expect([
      for (final pin in await OwnerProofPins(store, _origin).effective())
        pin.publicKey
    ], [
      replaced
    ]);

    // A report still asks for the code and seals nothing to that key.
    final plan = await reporter.prepare(_conversation);
    expect(plan.check.recipients.single.status, ReportKeyStatus.changed);
    expect(plan.canSend, isFalse);
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.keysNotPinned)));
    expect(server.copies, isEmpty);
  }, skip: nativeSkip);

  test('this device cannot open what is sealed to a key it does not hold',
      () async {
    await ownerSetsUpKey();
    await reporterTrustsAndFiles();
    final row = (await serviceFor(_ownerAccount).list()).single;
    // No seed on this device.
    final blank = ReportsService(
      api: server,
      token: _ownerAccount,
      accountId: _ownerAccount,
      crypto: crypto,
      store: store,
      seeds: MemoryReportSeedStore(),
    );
    expect((await blank.open(row)).failure, ReportOpenFailure.noSeed);
    // A different seed: sealed to an older key.
    await blank.createKey(replace: true);
    expect((await blank.open(row)).failure, ReportOpenFailure.otherKey);
    // A copy opened under another reporter or conversation does not open.
    final owner = serviceFor(_ownerAccount);
    final tampered = ReportCopyRow(
      id: row.id,
      reportId: row.reportId,
      inboxKind: row.inboxKind,
      inboxId: row.inboxId,
      keyRev: row.keyRev,
      recipientPublicKey: row.recipientPublicKey,
      conversationId: 'conv_other',
      reporterAccountId: row.reporterAccountId,
      sealed: row.sealed,
      createdAt: row.createdAt,
    );
    expect((await owner.open(tampered)).failure, ReportOpenFailure.cannotOpen);
  }, skip: nativeSkip);

  test('community conversations and unreportable messages are refused',
      () async {
    await ownerSetsUpKey();
    final reporter = serviceFor(_reporterAccount);
    server.kind = 'community';
    // No verified role record for the community: nobody to seal to.
    await expectLater(
        reporter.prepare(_conversation),
        throwsA(isA<ReportFailureException>().having(
            (e) => e.kind, 'kind', ReportFailure.communityUnavailable)));
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>().having(
            (e) => e.kind, 'kind', ReportFailure.communityUnavailable)));
    server.kind = 'instance_owner';
    await expectLater(
        reporter.file(conversationId: _conversation, messageKey: 'dev:none'),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.notReportable)));
    server.keys.clear();
    await expectLater(
        reporter.prepare(_conversation),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.noRecipients)));
    expect(server.copies, isEmpty);
  }, skip: nativeSkip);

  test(
      'community reports seal only to verified moderators at keys they '
      'announced over MLS, with no pin', () async {
    server.kind = 'community';
    final modKey = await moderatorPublishes(_moderator);
    await moderatorPublishes(_moderator2);
    expect(seedChanges, 2, reason: 'publishing asks the app to announce');
    // A plain member's key the server lists gets no copy either way.
    final memberKey = await moderatorPublishes('acct_member');
    moderators = verified({_moderator, _moderator2, _reporterAccount});
    final reporter = serviceFor(_reporterAccount);

    // Nothing announced yet: nothing can be sealed. (Preparing and filing
    // send nothing to the group; the app's background pass asks for keys.)
    await expectLater(
        reporter.prepare(_conversation),
        throwsA(isA<ReportFailureException>().having(
            (e) => e.kind, 'kind', ReportFailure.moderatorKeysPending)));
    await expectLater(
        reporter.file(
            conversationId: _conversation, messageKey: '$_sender:$_action'),
        throwsA(isA<ReportFailureException>().having(
            (e) => e.kind, 'kind', ReportFailure.moderatorKeysPending)));
    expect(server.copies, isEmpty);

    // The first moderator announced its key. For the second, the device
    // holds an announcement of a key the server does not list (the server
    // swapped it): no copy. The member's announcement makes it no moderator.
    await announces(_moderator, modKey);
    await announces(_moderator2, memberKey);
    await announces('acct_member', memberKey);
    final plan = await reporter.prepare(_conversation);
    expect(plan.canSend, isTrue, reason: 'no tap for moderator keys');
    expect(plan.check.recipients.map((r) => r.status),
        [ReportKeyStatus.authenticated]);
    expect(plan.check.recipients.single.recipient.inboxId,
        communityModeratorInboxId(_community, _moderator));
    expect(plan.check.missing, isEmpty);
    expect(plan.unconfirmed, [_moderator2]);
    await reporter.pinKeys(plan);
    expect(await store.loadReportKeyPins(_origin), isEmpty,
        reason: 'moderator keys are never pinned');
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:$_action');
    expect(server.copies.map((c) => c.inboxId),
        [communityModeratorInboxId(_community, _moderator)]);

    // The moderator opens it with its own seed.
    final inbox = moderatorInbox(_moderator);
    final opened = await inbox.open((await inbox.list()).single);
    expect(opened.text, 'the reported words');
  }, skip: nativeSkip);

  test(
      'a moderator the verified record removes gets no new reports, even '
      'while its announcement is kept and the server still lists its key',
      () async {
    server.kind = 'community';
    await announces(_moderator, await moderatorPublishes(_moderator));
    await announces(_moderator2, await moderatorPublishes(_moderator2));
    moderators = verified({_moderator, _moderator2});
    final reporter = serviceFor(_reporterAccount);
    keepReveal('second', 'msg_envelope_2');
    keepReveal('third', 'msg_envelope_3');
    final mod1 = communityModeratorInboxId(_community, _moderator);
    final mod2 = communityModeratorInboxId(_community, _moderator2);
    Set<String> inboxesOf(String reportId) => {
          for (final c in server.copies)
            if (c.reportId == reportId) c.inboxId
        };

    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:$_action');
    final first = server.copies.first.reportId;
    expect(inboxesOf(first), {mod1, mod2});

    // The record demotes the second moderator. Its announcement is still
    // stored and the server still lists its key, but the next report is
    // sealed to the first moderator only. The copy it already received
    // stays readable by it (accepted: it was a moderator when sealed).
    moderators = verified({_moderator});
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:second');
    final second = server.copies.last.reportId;
    expect(second, isNot(first));
    expect(inboxesOf(second), {mod1});
    final demoted = moderatorInbox(_moderator2);
    expect((await demoted.list()).map((c) => c.reportId), [first]);

    // With no moderator left in the record, nothing is sealed at all.
    moderators = verified(const <String>{});
    await expectLater(
        reporter.prepare(_conversation),
        throwsA(isA<ReportFailureException>()
            .having((e) => e.kind, 'kind', ReportFailure.noRecipients)));

    // Promoted again, same key: copies resume without a tap.
    moderators = verified({_moderator, _moderator2});
    await reporter.file(
        conversationId: _conversation, messageKey: '$_sender:third');
    expect(inboxesOf(server.copies.last.reportId), {mod1, mod2});
  }, skip: nativeSkip);

  test('verification shows nothing about the sender unless it matches',
      () async {
    await ownerSetsUpKey();
    await reporterTrustsAndFiles();
    final owner = serviceFor(_ownerAccount);
    final opened = await owner.open((await owner.list()).single);
    ReportEnvelopeRecord record(
            {String sender = 'acct_sender', List<int>? c}) =>
        ReportEnvelopeRecord(
          envelopeId: _envelope,
          conversationId: _conversation,
          senderAccountId: sender,
          senderDeviceId: _sender,
          frankCommit: c,
          createdAt: DateTime.utc(2026, 11, 7),
        );
    // Unfranked: no sender shown.
    server.record = record();
    var result = await owner.verify(opened);
    expect(result.verdict, ReportVerdict.unfranked);
    expect(result.record, isNull);
    // Wrong commitment: no sender shown.
    server.record = record(c: List<int>.filled(32, 1));
    result = await owner.verify(opened);
    expect(result.verdict, ReportVerdict.mismatch);
    expect(result.record, isNull);
    // Reporter is the sender: never verified.
    server.record = record(sender: _reporterAccount, c: commit);
    expect((await owner.verify(opened)).verdict, ReportVerdict.mismatch);
    server.record = record(c: commit);
    result = await owner.verify(opened);
    expect(result.verdict, ReportVerdict.verified);
    expect(result.record?.senderAccountId, 'acct_sender');
  }, skip: nativeSkip);

  test('the preview is the proof that is sealed, not the edited message',
      () async {
    final reporter = serviceFor(_reporterAccount);
    expect(
        await reporter.previewText('$_sender:$_action'), 'the reported words');
    expect(await reporter.previewText('dev:none'), isNull);
  }, skip: nativeSkip);

  test('a failed replace puts the old seed back', () async {
    final owner = serviceFor(_ownerAccount);
    final (key, _) = await owner.createKey();
    server.keys.clear();
    final failing = _FailingPut(server);
    final broken = ReportsService(
      api: failing,
      token: _ownerAccount,
      accountId: _ownerAccount,
      crypto: crypto,
      store: store,
      seeds: seeds,
    );
    await expectLater(broken.createKey(replace: true), throwsA(anything));
    expect((await owner.keyStatus()).localKey, key);
  }, skip: nativeSkip);

  test('report models bound what the server sends', () {
    Map<String, Object?> row() => {
          'id': 'row_1',
          'report_id': 'rpt_1',
          'inbox_kind': 'instance_owner',
          'inbox_id': 'acct_owner',
          'key_rev': 1,
          'recipient_public_key': base64Encode(List<int>.filled(32, 1)),
          'conversation_id': 'conv_1',
          'reporter_account_id': 'acct_reporter',
          'sealed': base64Encode(List<int>.filled(60, 2)),
          'created_at': '2026-11-07T10:00:00Z',
        };
    expect(ReportCopyRow.fromJson(row()).toString(), 'ReportCopyRow(row_1)');
    for (final bad in <Map<String, Object?>>[
      {...row(), 'key_rev': 0},
      {...row(), 'id': ''},
      {...row(), 'recipient_public_key': base64Encode(List<int>.filled(31, 1))},
      {...row(), 'created_at': 5},
      {...row(), 'sealed': 5},
    ]) {
      expect(() => ReportCopyRow.fromJson(bad), throwsA(anything));
    }
  });

  test('the seed store keeps one seed per server and account', () async {
    final store = MemoryReportSeedStore();
    final seed = Uint8List.fromList(List<int>.filled(32, 5));
    await store.save(_origin, 'a', seed);
    seed.fillRange(0, 32, 0);
    expect(await store.load(_origin, 'a'), List<int>.filled(32, 5));
    expect(await store.load(_origin, 'b'), isNull);
    expect(await store.load('https://other.example', 'a'), isNull);
    await store.delete(_origin, 'a');
    expect(await store.load(_origin, 'a'), isNull);
  });

  test('payload rules the screens rely on', () {
    expect(frankCommitBytes, 32);
    expect(AppPayloadType.text.wireName, 'text');
  });
}

class _FailingPut extends _Server {
  _FailingPut(_Server inner) {
    record = inner.record;
  }

  @override
  Future<int> putInstanceReportKey(String token, List<int> publicKey) async =>
      throw ApiException(500, '{"error":"x"}');
}
