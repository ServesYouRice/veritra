import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_link_v3_models.dart';
import 'package:private_messenger/core/history_transfer_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/sha256.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

/// K2 v3 link and history copy through two real [AppState]s on the real
/// native engine: the existing device creates a link, the new device claims
/// it, the safety code is confirmed natively, the approval promotes the new
/// identity through the ledger, and the history moves as one encrypted
/// bundle over an in-memory server. Only the HTTP servers are fakes.

const _origin = 'https://chat.example.org';
const _account = 'acct_me';
const _sourceDevice = 'dev_src';
const _newDevice = 'dev_new';

const _sourceSession = Session(
  baseUrl: _origin,
  token: 'tok_src',
  accountId: _account,
  deviceId: _sourceDevice,
  username: 'alice',
  deviceSecret: 'secret_src',
  role: 'member',
);

String _iso(DateTime time) => time.toUtc().toIso8601String();

/// The link service, in memory: the v3 state machine as the real server
/// answers it, with the checks the real server makes on credentials.
class _LinkServer {
  _LinkServer(this.sourceSigningKey);

  final List<int> sourceSigningKey;
  int links = 0;
  Map<String, Object?>? link;
  Map<String, Object?>? claim;
  String? reservationRequestId;
  int completes = 0;
  bool revoked = false;

  /// A failure the claim-status endpoint answers with, when set.
  ApiException? statusFailure;

  /// When set, claim-status relays this random instead of the source's
  /// revealed one (a relay that substitutes the reveal, L1-3).
  List<int>? substitutedReveal;
  int reveals = 0;

  Map<String, Object?> get record => Map<String, Object?>.from(link!);

  DeviceLinkV3Record view() => DeviceLinkV3Record.fromJson(
      revoked ? {...record, 'state': 'revoked'} : record,
      transport: TransportPolicy.production);
}

class _LinkApi extends ApiClient {
  _LinkApi(this.server) : super(baseUrl: _origin);

  final _LinkServer server;

  @override
  Future<DeviceLinkV3Record> createDeviceLinkV3(
      Session owner, String locator, List<int> sourceCommitment,
      {int expiresInSeconds = 600}) async {
    final now = DateTime.now().toUtc();
    server
      ..links += 1
      ..claim = null
      ..revoked = false
      ..link = <String, Object?>{
        'id': 'link_${server.links}',
        'code': locator,
        'protocol_version': deviceLinkV3Protocol,
        'state': 'pending',
        'account_id': owner.accountId,
        'created_by_device_id': owner.deviceId,
        'server_origin': _origin,
        'link_nonce': base64Encode(List<int>.generate(32, (i) => i + 1)),
        'existing_signing_key': base64Encode(server.sourceSigningKey),
        'source_commitment': base64Encode(sourceCommitment),
        'created_at': _iso(now),
        'expires_at': _iso(now.add(Duration(seconds: expiresInSeconds))),
      };
    return server.view();
  }

  @override
  Future<DeviceLinkV3Reservation> reserveDeviceLinkV3(
      String locator, String requestId) async {
    final link = server.link;
    if (link == null || link['code'] != locator) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    if (server.reservationRequestId != null &&
        server.reservationRequestId != requestId) {
      throw ApiException(409, '{"error":"idempotency_conflict"}');
    }
    server.reservationRequestId = requestId;
    return DeviceLinkV3Reservation.fromJson(<String, Object?>{
      'id': link['id'],
      'account_id': link['account_id'],
      'device_id': _newDevice,
      'challenge': base64Encode(<int>[5, 4, 3, 2, 1]),
      'expires_at': link['expires_at'],
      'protocol_version': deviceLinkV3Protocol,
      'link_nonce': link['link_nonce'],
      'existing_device_id': link['created_by_device_id'],
      'existing_signing_key': link['existing_signing_key'],
      'source_commitment': link['source_commitment'],
    });
  }

  @override
  Future<DeviceLinkV3Record> submitDeviceLinkV3Claim(
      FrozenDeviceLinkV3Claim claim,
      DeviceLinkV3Reservation reservation) async {
    final link = server.link!;
    final fields = claim.fields;
    final stored = server.claim;
    if (stored != null) {
      // An exact retry only.
      expect(fields, stored, reason: 'the claim was rebuilt, not replayed');
    } else {
      server.claim = Map<String, Object?>.of(fields);
      server.link = <String, Object?>{
        ...link,
        'state': 'claimed',
        'claimed_device_id': reservation.fields['device_id'],
        'claimed_device_name': fields['device_name'],
        'claimed_signing_key': fields['signing_key'],
        'transfer_public_key': fields['transfer_public_key'],
        'recipient_random': fields['recipient_random'],
        'transcript_hash': fields['transcript_hash'],
        'claim_tag': fields['claim_tag'],
        'claim_request_hash': claim.requestHash,
        'claimed_at': _iso(DateTime.now().toUtc()),
      };
    }
    return server.view();
  }

  @override
  Future<DeviceLinkV3Record> deviceLinkV3(Session owner, String id) async {
    if (server.link?['id'] != id) throw ApiException(404, '');
    return server.view();
  }

  void _checkClaimToken(String token) {
    expect(sha256Hex(utf8.encode(token)), server.claim!['claim_token_hash'],
        reason: 'the claim token does not match its stored hash');
  }

  @override
  Future<DeviceLinkV3Record> deviceLinkV3ClaimStatus(
      DeviceLinkV3Record expected, String claimToken) async {
    // The real endpoint loads the link inside its valid window: a revoked,
    // expired or unknown link is a 400 invalid_device_link, never a 410 and
    // never the state 'revoked'. An approved or consumed link keeps
    // answering 200 (the transfer window).
    final link = server.link!;
    final open = link['state'] == 'pending' || link['state'] == 'claimed';
    final expired =
        DateTime.parse(link['expires_at'] as String).isBefore(DateTime.now());
    if (server.revoked || (open && expired)) {
      throw ApiException(400, '{"error":"invalid_device_link"}');
    }
    final failure = server.statusFailure;
    if (failure != null) throw failure;
    _checkClaimToken(claimToken);
    final substituted = server.substitutedReveal;
    if (substituted != null && link.containsKey('source_random')) {
      return DeviceLinkV3Record.fromJson(
          {...server.record, 'source_random': base64Encode(substituted)},
          transport: TransportPolicy.production);
    }
    return server.view();
  }

  @override
  Future<DeviceLinkV3Record> revealDeviceLinkV3(Session owner,
      DeviceLinkV3Record expected, List<int> sourceRandom) async {
    final link = server.link!;
    expect(expected.fields['claim_request_hash'], link['claim_request_hash']);
    expect(link['state'], 'claimed', reason: 'a reveal comes after the claim');
    server.reveals++;
    if (link.containsKey('source_random')) {
      expect(link['source_random'], base64Encode(sourceRandom),
          reason: 'a repeat must reveal the same random');
    } else {
      server.link = <String, Object?>{
        ...link,
        'source_random': base64Encode(sourceRandom),
        'revealed_at': _iso(DateTime.now().toUtc()),
      };
    }
    return server.view();
  }

  @override
  Future<DeviceLinkV3Record> approveDeviceLinkV3(
      Session owner, DeviceLinkV3Record expected, List<int> approvalTag,
      {List<int>? deviceList}) async {
    final link = server.link!;
    expect(expected.fields['claim_request_hash'], link['claim_request_hash']);
    if (link['state'] == 'claimed') {
      // The real server refuses an approval before the reveal (L1-3).
      if (!link.containsKey('source_random')) {
        throw ApiException(409, '{"error":"reveal_required"}');
      }
      final approved = DateTime.now().toUtc();
      server.link = <String, Object?>{
        ...link,
        'state': 'approved',
        'approval_tag': base64Encode(approvalTag),
        'approved_at': _iso(approved),
        'transfer_expires_at': _iso(approved.add(const Duration(days: 7))),
      };
    } else {
      expect(link['approval_tag'], base64Encode(approvalTag),
          reason: 'a replay must carry the same approval tag');
    }
    return server.view();
  }

  @override
  Future<DeviceLinkV3Completion> completeDeviceLinkV3(
      DeviceLinkV3Record expected,
      String claimToken,
      String initialSessionTokenHash) async {
    _checkClaimToken(claimToken);
    expect(
        initialSessionTokenHash, server.claim!['initial_session_token_hash']);
    final link = server.link!;
    expect(link['state'], anyOf('approved', 'consumed'));
    server.completes++;
    final completed = link['completed_at'] ?? _iso(DateTime.now().toUtc());
    server.link = <String, Object?>{
      ...link,
      'state': 'consumed',
      'completed_at': completed,
    };
    return DeviceLinkV3Completion.fromJson(<String, Object?>{
      'completion': <String, Object?>{
        'link_id': link['id'],
        'account_id': link['account_id'],
        'device_id': link['claimed_device_id'],
        'server_origin': _origin,
        'claim_request_hash': link['claim_request_hash'],
        'transcript_hash': link['transcript_hash'],
        'initial_session_token_hash': initialSessionTokenHash,
        'completed_at': completed,
      },
      'approval_tag': link['approval_tag'],
    }, transport: TransportPolicy.production);
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {}

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      const <MlsMessage>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<Invite>> listInvites(String token) async => const <Invite>[];

  @override
  Future<List<Community>> listCommunities(String token) async =>
      const <Community>[];

  @override
  Future<void> logout(String token) async {}
}

/// The history transfer resource, in memory.
class _Transfer implements HistoryTransferTransport {
  HistoryTransferReceipt? stored;
  Uint8List? ciphertext;
  Uint8List? handoff;
  String state = 'active';
  int uploads = 0;
  int cancels = 0;

  HistoryTransferReceipt _receipt() {
    final base = stored!;
    return HistoryTransferReceipt(
      transferId: base.transferId,
      linkId: base.linkId,
      accountId: base.accountId,
      sourceDeviceId: base.sourceDeviceId,
      recipientDeviceId: base.recipientDeviceId,
      claimRequestHash: base.claimRequestHash,
      transcriptHash: base.transcriptHash,
      ciphertextSha256: base.ciphertextSha256,
      sizeBytes: base.sizeBytes,
      state: state,
      createdAt: base.createdAt,
      expiresAt: base.expiresAt,
      handoff: state == 'active' ? handoff : null,
    );
  }

  @override
  Future<HistoryTransferReceipt> upload({
    required String token,
    required String linkId,
    required HistoryTransferMetadata metadata,
    required Stream<List<int>> Function() ciphertext,
  }) async {
    uploads++;
    if (stored == null) {
      final body = BytesBuilder(copy: false);
      await for (final chunk in ciphertext()) {
        body.add(chunk);
      }
      this.ciphertext = body.takeBytes();
      handoff = Uint8List.fromList(metadata.handoff);
      stored = HistoryTransferReceipt(
        transferId: metadata.transferId,
        linkId: linkId,
        accountId: _account,
        sourceDeviceId: _sourceDevice,
        recipientDeviceId: _newDevice,
        claimRequestHash: metadata.claimRequestHash,
        transcriptHash: Uint8List.fromList(metadata.transcriptHash),
        ciphertextSha256: metadata.ciphertextSha256,
        sizeBytes: metadata.sizeBytes,
        state: 'active',
        createdAt: DateTime.utc(2026, 11, 7),
        expiresAt: DateTime.utc(2026, 11, 14),
      );
    }
    return _receipt();
  }

  @override
  Future<HistoryTransferReceipt> status(
      String linkId, HistoryTransferAuth auth) async {
    if (stored == null) throw ApiException(404, '{"error":"not_found"}');
    return _receipt();
  }

  @override
  Future<int> download({
    required String linkId,
    required HistoryTransferAuth auth,
    required String expectedSha256,
    required int expectedSize,
    required File target,
    required Future<bool> Function(File complete) verifyDigest,
  }) async {
    target.writeAsBytesSync(ciphertext!);
    if (!await verifyDigest(target)) {
      target.deleteSync();
      throw const HistoryTransferMismatch();
    }
    return ciphertext!.length;
  }

  @override
  Future<HistoryTransferReceipt> acknowledge({
    required String linkId,
    required HistoryTransferAuth auth,
    required String transferId,
    required String ciphertextSha256,
  }) async {
    if (state == 'cancelled') throw ApiException(409, '');
    state = 'acknowledged';
    return _receipt();
  }

  @override
  Future<void> cancel(String linkId, HistoryTransferAuth auth) async {
    cancels++;
    state = 'cancelled';
  }
}

class _Store extends MemoryLocalStore {
  _Store([this.snapshot]);
  List<int>? snapshot;

  @override
  Future<List<int>> exportHistorySnapshot(
          {bool omitDisappearing = false}) async =>
      snapshot == null
          ? super.exportHistorySnapshot(omitDisappearing: omitDisappearing)
          : List.of(snapshot!);
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

List<int> _snapshot(int now, List<String> bodies) => HistorySnapshot(
      accountId: _account,
      sourceDeviceId: _sourceDevice,
      counter: 3,
      createdAt: now,
      conversations: const [
        HistoryConversation('conv', 'dm', title: 'historical'),
      ],
      messages: [
        for (var i = 0; i < bodies.length; i++)
          LocalMessage(
            key: '$_sourceDevice:m$i',
            conversationId: 'conv',
            senderAccountId: 'bob',
            senderDeviceId: _sourceDevice,
            kind: 'text',
            body: bodies[i],
            createdAt: now - 1000,
            state: 'received',
            senderHidden: false,
          ),
      ],
      reactions: const [],
      pins: const [],
      starred: const {},
      preferences: const [],
    ).encode();

class _World {
  _World(this.dir);
  final Directory dir;
  late NativeCryptoBindings bindings;
  late _LinkServer server;
  late _LinkApi api;
  final transfer = _Transfer();
  late _Store sourceStore;
  final newStore = _Store();
  late NativeCryptoService sourceCrypto;
  late AppState source;
  late AppState fresh;
  NativeCryptoService? newCrypto;

  /// How far the new device's clock runs behind the server's.
  Duration newClockLag = Duration.zero;

  AppState newDevice() {
    final crypto = newCrypto = TestNativeCryptoService(
        bindings: bindings,
        localStore: newStore,
        clock: () => DateTime.now().subtract(newClockLag));
    return AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: newStore,
      syncServiceFactory: (_, __) => _QuietSync(),
    )
      ..historyTransferDirectory = (() async => '${dir.path}/new')
      ..historyTransferTransportFactory = ((_) => transfer);
  }

  Future<void> setUp(List<String> bodies) async {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    sourceStore =
        _Store(_snapshot(DateTime.now().millisecondsSinceEpoch, bodies));
    sourceCrypto = TestNativeCryptoService(
        bindings: bindings, localStore: sourceStore, clock: DateTime.now);
    final credential = await sourceCrypto.createEnrollmentCredential(
        const EnrollmentReservation(
            id: 'res_src',
            accountId: _account,
            deviceId: _sourceDevice,
            challenge: <int>[1, 2, 3]));
    await sourceStore.saveSession(_sourceSession);
    await sourceCrypto.activateSession(_sourceSession);
    server = _LinkServer(credential.signingKey);
    api = _LinkApi(server);
    source = AppState(
      apiClientFactory: (_) => api,
      cryptoService: sourceCrypto,
      localStore: sourceStore,
      syncServiceFactory: (_, __) => _QuietSync(),
    )
      ..api = api
      ..session = _sourceSession
      ..historyTransferDirectory = (() async => '${dir.path}/source')
      ..historyTransferTransportFactory = ((_) => transfer);
    fresh = newDevice();
  }

  /// Creates, claims and refreshes: the source then shows the safety code.
  Future<String> claimAndRefresh() async {
    await source.createDeviceLink();
    expect(source.errorFor(Ops.deviceLink), isNull);
    final code = source.activeDeviceLinkCode;
    expect(code, isNotNull);
    await fresh.claimDeviceLink(_origin, code!);
    expect(fresh.errorFor(Ops.deviceLinkClaim), isNull);
    // L1-3: no code before the source reveals the random it committed to.
    expect(fresh.pendingDeviceLinkClaim!.verificationCode, isEmpty);
    await source.refreshActiveDeviceLink();
    expect(source.errorFor(Ops.deviceLink), isNull);
    expect(server.link!['source_random'], isNotNull,
        reason: 'the source reveals once it accepted the claim');
    await fresh.completeDeviceLinkClaim();
    expect(fresh.errorFor(Ops.deviceLinkClaim), isNull,
        reason: fresh.errorFor(Ops.deviceLinkClaim));
    final sas = fresh.pendingDeviceLinkClaim!.verificationCode;
    expect(sas, matches(RegExp(r'^\d{8}$')));
    expect(source.activeDeviceLink?.verificationCode, sas);
    return sas;
  }

  /// The new device restarts over its stored waiting claim, whose link
  /// expiry is first moved to [expiresAt] (epoch milliseconds) when given.
  /// The restart resumes the claim by itself, as at app start.
  Future<void> restartFresh({int? expiresAt}) async {
    if (expiresAt != null) {
      final stored = (await newStore.loadPendingEnrollment())!;
      final payload = jsonDecode(stored.payloadJson) as Map<String, Object?>;
      payload['expires_at'] = expiresAt;
      await newStore.savePendingEnrollment(PendingEnrollment(
          kind: stored.kind,
          origin: stored.origin,
          accountId: stored.accountId,
          deviceId: stored.deviceId,
          payloadJson: jsonEncode(payload)));
    }
    retire(fresh);
    fresh = newDevice();
    await fresh.tryRestoreSession();
  }

  /// Runs [step] until [done], at most [limit] of wall-clock time: a slow
  /// runner may need seconds for the export, the encryption and the import.
  Future<void> until(Future<bool> Function() done,
      {Future<void> Function()? step,
      Duration limit = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(limit);
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out after ${limit.inSeconds} s');
      }
      await step?.call();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Runs both devices' transfer steps until neither has a row.
  Future<void> drain() => until(
          () async =>
              (await sourceStore.loadHistoryTransfers()).isEmpty &&
              (await newStore.loadHistoryTransfers()).isEmpty, step: () async {
        await source.resumeHistoryTransfers();
        if (fresh.session != null) await fresh.resumeHistoryTransfers();
      });

  /// Calls the source's transfer step until the copy is on the server (a
  /// step already running, started by the approval, makes a call a no-op).
  Future<void> sourceUploads() async {
    await until(() async => transfer.stored != null,
        step: source.resumeHistoryTransfers);
    expect(transfer.stored, isNotNull);
  }

  final _gone = <AppState>{};
  void _drop(AppState state) {
    if (_gone.add(state)) state.dispose();
  }

  void retire(AppState state) => _drop(state);

  Future<void> dispose() async {
    _drop(source);
    _drop(fresh);
  }
}

Future<void> _withWorld(
  Future<void> Function(_World world) body, {
  List<String> bodies = const ['first', 'second'],
}) async {
  final dir = Directory.systemTemp.createTempSync('k2-link-v3');
  final world = _World(dir);
  try {
    await world.setUp(bodies);
    await body(world);
  } finally {
    await world.dispose();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  final skip = nativeCryptoSkip();

  test(
      'a reveal that does not open the commitment shows no code and ends the '
      'claim with its own message (L1-3)',
      () => _withWorld((w) async {
            await w.source.createDeviceLink();
            await w.fresh
                .claimDeviceLink(_origin, w.source.activeDeviceLinkCode!);
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull);
            // The relay saw the commitment and the new device's random, and
            // after the source's reveal hands the new device another one.
            w.server.substitutedReveal = List<int>.filled(32, 0x42);
            await w.source.refreshActiveDeviceLink();
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            expect(w.server.reveals, 1);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains("link check did not match"));
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(w.fresh.session, isNull);
          }),
      skip: skip);

  test(
      'the source reveals only after it accepted the claim, and only once',
      () => _withWorld((w) async {
            await w.source.createDeviceLink();
            // Nothing to reveal before a claim.
            await w.source.refreshActiveDeviceLink();
            expect(w.server.reveals, 0);
            expect(w.server.link!['source_commitment'], isNotNull);
            await w.fresh
                .claimDeviceLink(_origin, w.source.activeDeviceLinkCode!);
            await w.source.refreshActiveDeviceLink();
            expect(w.server.reveals, 1);
            final revealed = w.server.link!['source_random'];
            // A second refresh finds its own reveal and sends nothing new.
            await w.source.refreshActiveDeviceLink();
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            expect(w.server.reveals, 1);
            expect(w.server.link!['source_random'], revealed);
          }),
      skip: skip);

  test(
      'a new device is linked and receives the history, and both clean up',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            expect(w.fresh.session, isNull);

            // A wrong code is refused natively and approves nothing.
            await w.source.approveActiveDeviceLink(
                sas == '00000000' ? '11111111' : '00000000');
            expect(w.source.errorFor(Ops.deviceLink),
                contains('does not match the one on the new device'));
            expect(w.server.link!['state'], 'claimed');

            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNull,
                reason: w.source.errorFor(Ops.deviceLink));
            expect(w.source.activeDeviceLink?.state, 'approved');
            expect(w.source.activeDeviceLinkCode, isNull,
                reason: 'the link secret is cleared on approval');

            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull,
                reason: w.fresh.errorFor(Ops.deviceLinkClaim));
            expect(w.fresh.session?.deviceId, _newDevice);
            expect(w.fresh.session?.accountId, _account);
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect((await w.newStore.loadSession())?.deviceId, _newDevice);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(w.server.completes, 1);

            await w.drain();
            expect(await w.sourceStore.loadHistoryTransfers(), isEmpty);
            expect(await w.newStore.loadHistoryTransfers(), isEmpty);
            expect(w.transfer.state, 'acknowledged');
            final messages = await w.newStore.loadMessages('conv');
            expect(messages.map((m) => m.body), ['first', 'second']);
            expect(w.fresh.historyOnlyConversations.map((c) => c.id), ['conv']);
            expect(w.fresh.historyTransferStatus, isNull);
            expect(w.source.historyTransferStatus, isNull);
            expect(
                Directory('${w.dir.path}/source/source').existsSync() &&
                    Directory('${w.dir.path}/source/source')
                        .listSync()
                        .isNotEmpty,
                isFalse);
            expect(
                Directory('${w.dir.path}/new/incoming').existsSync() &&
                    Directory('${w.dir.path}/new/incoming')
                        .listSync()
                        .isNotEmpty,
                isFalse);
          }),
      skip: skip);

  test(
      'L1: a server that swaps the claimed signing key after the code was '
      'checked gets no approval and no change-2 version',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            // The record the source fetches again at approval names another
            // key; its transcript_hash field is left as the real one.
            w.server.link = <String, Object?>{
              ...w.server.link!,
              'claimed_signing_key': base64Encode(List<int>.filled(32, 7)),
            };
            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNotNull);
            expect(w.server.link!['state'], 'claimed',
                reason: 'nothing may be approved for a swapped key');
          }),
      skip: skip);

  test(
      'a restart while the claim waits resumes it, and the claim is replayed '
      'byte for byte',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            final stored = (await w.newStore.loadPendingEnrollment())!;
            expect(stored.kind, PendingEnrollment.kindDeviceLinkV3);
            expect(stored.state, isNotNull);
            expect(stored.toString(), isNot(contains('claim_token')));
            // The app restarts: a new service and a new AppState over the
            // same store. The identity comes back from the sealed state.
            w.retire(w.fresh);
            w.fresh = w.newDevice();
            await w.fresh.tryRestoreSession();
            expect(w.fresh.session, isNull);

            // A lost claim answer: the same signed claim goes again. The
            // code is never stored; the read-only reveal derives it again.
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull);
            expect(w.fresh.session, isNull);
            expect(w.fresh.pendingDeviceLinkClaim?.verificationCode, sas);
            expect(stored.payloadJson, isNot(contains(sas)));

            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull,
                reason: w.fresh.errorFor(Ops.deviceLinkClaim));
            expect(w.fresh.session?.deviceId, _newDevice);
            await w.drain();
            expect((await w.newStore.loadMessages('conv')).map((m) => m.body),
                ['first', 'second']);
          }),
      skip: skip);

  test(
      'a restart after the approval resumes the copy from its stored rows',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            await w.source.approveActiveDeviceLink(sas);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.session?.deviceId, _newDevice);
            // Both apps stop before any transfer step ran far.
            w.retire(w.source);
            w.retire(w.fresh);
            await w.sourceCrypto.dispose();
            await w.newCrypto?.dispose();
            // The source comes back first and uploads; the new device then
            // comes back and receives, each from its stored row.
            w.sourceCrypto = TestNativeCryptoService(
                bindings: w.bindings,
                localStore: w.sourceStore,
                clock: DateTime.now);
            w.source = AppState(
              apiClientFactory: (_) => w.api,
              cryptoService: w.sourceCrypto,
              localStore: w.sourceStore,
              syncServiceFactory: (_, __) => _QuietSync(),
            )
              ..historyTransferDirectory = (() async => '${w.dir.path}/source')
              ..historyTransferTransportFactory = ((_) => w.transfer);
            await w.source.tryRestoreSession();
            expect(w.source.session?.deviceId, _sourceDevice);
            await w.sourceUploads();
            w.fresh = w.newDevice();
            await w.fresh.tryRestoreSession();
            expect(w.fresh.session?.deviceId, _newDevice);
            await w.drain();
            expect(await w.sourceStore.loadHistoryTransfers(), isEmpty);
            expect(await w.newStore.loadHistoryTransfers(), isEmpty);
            expect((await w.newStore.loadMessages('conv')).map((m) => m.body),
                ['first', 'second']);
          }),
      skip: skip);

  test(
      'a copy the server closed ends on both devices and keeps the link',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            await w.source.approveActiveDeviceLink(sas);
            await w.fresh.completeDeviceLinkClaim();
            await w.sourceUploads();
            // The server cancels the copy before the new device fetched it.
            w.transfer.state = 'cancelled';
            await w.fresh.resumeHistoryTransfers();
            expect(w.fresh.historyTransferStatus?.phase,
                HistoryTransferPhase.ended);
            expect(await w.newStore.loadHistoryTransfers(), isEmpty);
            await w.source.resumeHistoryTransfers();
            expect(w.source.historyTransferStatus?.phase,
                HistoryTransferPhase.ended);
            expect(await w.sourceStore.loadHistoryTransfers(), isEmpty);
            // The device is linked all the same; no history came.
            expect(w.fresh.session?.deviceId, _newDevice);
            expect(await w.newStore.loadMessages('conv'), isEmpty);
            w.fresh.dismissHistoryCopyNotice();
            expect(w.fresh.historyTransferStatus, isNull);
          }),
      skip: skip);

  test(
      'an approval the source never made is refused before the link completes',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            // A server that substituted the link answers with a tag of its
            // own; the new device pinned the real context when it claimed.
            w.server.link = <String, Object?>{
              ...w.server.link!,
              'approval_tag': base64Encode(List<int>.filled(32, 7)),
            };
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains('approval could not be verified'));
            expect(w.server.completes, 0);
            expect(w.fresh.session, isNull);
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(await w.newStore.loadSession(), isNull);
            expect(await w.newStore.loadHistoryTransfers(), isEmpty);
          }),
      skip: skip);

  test(
      'a revoked link ends the waiting claim and drops the pending identity',
      () => _withWorld((w) async {
            await w.claimAndRefresh();
            w.server.revoked = true;
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains('cancelled or has expired'));
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(w.fresh.session, isNull);
          }),
      skip: skip);

  test(
      'an approval read after the link window still finishes (L1-3: the '
      'reveal is checked only while the code is shown)',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            // The new device looks again only after its 10-minute link window
            // (it was in the background): native would refuse any reveal now.
            w.newClockLag = const Duration(minutes: -11);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull,
                reason: w.fresh.errorFor(Ops.deviceLinkClaim));
            expect(w.fresh.session?.deviceId, _newDevice);
            expect(w.server.completes, 1);
            w.newClockLag = Duration.zero;
          }),
      skip: skip);

  test(
      'a clock behind the server does not make a genuine approval read as '
      'forged',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            await w.source.approveActiveDeviceLink(sas);
            expect(w.source.errorFor(Ops.deviceLink), isNull);
            // The server stamped approved_at on its own clock, a few seconds
            // ahead of this device's: native would refuse an approval from
            // the future, so the scratch check lifts its time to approved_at.
            w.newClockLag = const Duration(seconds: 5);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNull,
                reason: w.fresh.errorFor(Ops.deviceLinkClaim));
            expect(w.fresh.session?.deviceId, _newDevice);
            expect(w.server.completes, 1);
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            // The clock is right again: the copy goes on as usual.
            w.newClockLag = Duration.zero;
            await w.drain();
            expect((await w.newStore.loadMessages('conv')).map((m) => m.body),
                ['first', 'second']);
          }),
      skip: skip);

  test(
      'an expired waiting claim ends when the server answers 400 '
      'invalid_device_link',
      () => _withWorld((w) async {
            await w.claimAndRefresh();
            final past = DateTime.now().subtract(const Duration(seconds: 1));
            w.server.link = <String, Object?>{
              ...w.server.link!,
              'expires_at': _iso(past),
            };
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains('cancelled or has expired'));
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(w.fresh.session, isNull);
          }),
      skip: skip);

  test(
      'a waiting claim past its expiry ends on any status error',
      () => _withWorld((w) async {
            await w.claimAndRefresh();
            w.server.statusFailure = ApiException(503, '');
            // The stored expiry is in the past; the restart resumes the claim
            // and its status call fails with an error that names nothing.
            final past = DateTime.now().subtract(const Duration(seconds: 1));
            await w.restartFresh(expiresAt: past.millisecondsSinceEpoch);
            await w.fresh.completeDeviceLinkClaim();
            await w.until(() async => w.fresh.pendingDeviceLinkClaim == null);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
            expect(w.fresh.session, isNull);
          }),
      skip: skip);

  test(
      'a waiting claim inside its expiry survives a status error',
      () => _withWorld((w) async {
            final sas = await w.claimAndRefresh();
            w.server.statusFailure = ApiException(503, '');
            await w.restartFresh();
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNotNull);
            expect(w.fresh.pendingDeviceLinkClaim, isNotNull);
            expect(await w.newStore.loadPendingEnrollment(), isNotNull);
            // The server comes back and the claim goes on to be approved.
            w.server.statusFailure = null;
            await w.source.approveActiveDeviceLink(sas);
            await w.fresh.completeDeviceLinkClaim();
            expect(w.fresh.session?.deviceId, _newDevice);
          }),
      skip: skip);

  test(
      'a second claim while one waits is refused and a recovery in progress '
      'refuses the link',
      () => _withWorld((w) async {
            await w.claimAndRefresh();
            await w.fresh
                .claimDeviceLink(_origin, w.source.activeDeviceLinkCode!);
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains('already waiting'));
            await w.fresh.abandonDeviceLinkClaim();
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);

            // Another kind of pending enrollment blocks a claim before any
            // network call.
            await w.newStore.savePendingEnrollment(PendingEnrollment(
                kind: PendingEnrollment.kindAccountRecovery,
                origin: _origin,
                accountId: _account,
                deviceId: 'dev_other',
                payloadJson: '{}'));
            final reservations = w.server.reservationRequestId;
            await w.fresh
                .claimDeviceLink(_origin, w.source.activeDeviceLinkCode!);
            expect(w.fresh.errorFor(Ops.deviceLinkClaim),
                contains('account recovery is waiting'));
            expect(w.server.reservationRequestId, reservations);
          }),
      skip: skip);

  test(
      'a code that is not a link code fails before any request',
      () => _withWorld((w) async {
            await w.fresh.claimDeviceLink(_origin, 'PAIRCODE');
            expect(w.fresh.errorFor(Ops.deviceLinkClaim), isNotNull);
            expect(w.server.reservationRequestId, isNull);
            expect(w.fresh.pendingDeviceLinkClaim, isNull);
            expect(await w.newStore.loadPendingEnrollment(), isNull);
          }),
      skip: skip);
}
