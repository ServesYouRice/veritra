import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/franking.dart'
    show reportInboxInstanceOwner;
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/owner_key_watch.dart';
import 'package:private_messenger/crypto/owner_proof_pins.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';

/// L2-3, owner decision 2026-11-12 ("auto-pin on first use"): the app pins
/// the instance owners' report keys the first time it sees any, and after
/// that tags a sealed message only to keys a person accepted. Through
/// AppState with the real native engine, real device-list pins and the
/// franking context the sealed token pass loads.
const _origin = 'https://localhost:8443';
const _account = 'acct_member';
const _own = 'dev_member';

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  late List<List<int>> keys;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    keys = [
      for (var i = 0; i < 4; i++)
        bindings.reportPublicKey(bindings.generateReportKeySeed()),
    ];
  });

  ReportInboxRecipient owner(String id, List<int> key, {int rev = 1}) =>
      ReportInboxRecipient(inboxId: id, publicKey: key, keyRev: rev);

  Future<({AppState state, _Api api, MemoryLocalStore store})> start() async {
    final api = _Api(bindings);
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = AppState(
      screenGuard: FakeScreenGuard(),
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    addTearDown(state.dispose);
    const session = Session(
        baseUrl: _origin, token: 'tok', accountId: _account, deviceId: _own);
    await crypto.createEnrollmentCredential(const EnrollmentReservation(
        id: 'enroll_own',
        accountId: _account,
        deviceId: _own,
        challenge: <int>[1, 2, 3]));
    await store.saveSession(session);
    await crypto.activateSession(session);
    // A tablet starts the list and adds this device; this device lists its
    // franking key with change 7 on its first pass.
    final tablet = bindings.createDevice(_account, 'dev_tablet');
    addTearDown(tablet.close);
    final tabletPair =
        DeviceListPair(idBytes('dev_tablet'), tablet.signingPublicKey());
    api.chain.add(tablet.signDeviceList(
        DeviceListBody(
          accountId: idBytes(_account),
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.genesis,
          entries: [tabletPair],
        ),
        idBytes('dev_tablet')));
    final genesis =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    api.chain.add(tablet.signDeviceList(
        DeviceListBody(
          accountId: idBytes(_account),
          version: 2,
          prevHash: genesis.listHash,
          createdAtMs: 2,
          change: DeviceListChange.add,
          entries: [
            DeviceListPair(idBytes(_own), await crypto.currentSigningKey()),
            tabletPair,
          ],
        ),
        idBytes('dev_tablet')));
    await DeviceListPins(store: store, source: _Lists(api), verifier: crypto)
        .pinChain(_account, api.chain, expectedHead: api.chain.last);
    state
      ..api = api
      ..session = session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_comm', kind: 'group', communityId: 'c1'),
        Conversation(id: 'conv_dm', kind: 'dm'),
      ];
    state.sealedSender =
        SealedSender(origin: _origin, localStore: store, crypto: crypto);
    return (state: state, api: api, store: store);
  }

  Future<List<List<int>>> tags(AppState state) async =>
      (await state.debugSealedFrankContext())!.ownerKeys;

  /// The proof recipients as stored, owner to key.
  Future<Map<String, List<int>>> proofPins(LocalStore store) async => {
        for (final pin in await OwnerProofPins(store, _origin).effective())
          pin.ownerAccountId: pin.publicKey
      };

  /// The D95 report pins, owner to key.
  Future<Map<String, List<int>>> reportPins(LocalStore store) async => {
        for (final pin in await store.loadReportKeyPins(_origin))
          pin.ownerAccountId: pin.publicKey
      };

  test('first sight pins the owner keys and the tags go to them', () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_b', keys[1]), owner('acct_a', keys[0])];

    expect(await tags(state), [keys[0], keys[1]]);
    // Through the conversation outside the community, members only.
    expect(api.inboxReads, ['conv_dm']);
    // Pinned for proofs only (owner decision 2026-11-12, "Keep reports
    // manual"): no report pin is made without a code comparison.
    expect(await proofPins(store), {'acct_a': keys[0], 'acct_b': keys[1]});
    expect(await store.loadReportKeyPins(_origin), isEmpty);
    expect(state.ownerKeyReview, isEmpty);
    expect(await state.sealedProvableOwnerCount(), 2);

    // A failed read is not "no owners": nothing is recorded as gone.
    api.failing = true;
    expect(await tags(state), [keys[0], keys[1]]);
    expect(state.ownerKeyReview, isEmpty);
  }, skip: skip);

  test('no owner key yet pins nothing, and the first listing later does',
      () async {
    final (:state, :api, :store) = await start();
    api.unavailable = true;
    expect(await tags(state), isEmpty);
    // Any other error records nothing and keeps the tags.
    api
      ..unavailable = false
      ..failing = true;
    expect(await tags(state), isEmpty);
    api
      ..failing = false
      ..owners = [owner('acct_a', keys[0])];
    expect(await tags(state), [keys[0]]);
  }, skip: skip);

  test('a changed key is not tagged until it is accepted', () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_a', keys[0]), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0], keys[1]]);

    api.owners = [owner('acct_a', keys[2], rev: 2), owner('acct_b', keys[1])];
    // The old key stays the one tagged; the new one waits.
    expect(await tags(state), [keys[0], keys[1]]);
    final review = state.ownerKeyReview;
    expect(review, hasLength(1));
    expect(review.single.inboxId, 'acct_a');
    expect(review.single.change, OwnerKeyChange.changed);
    expect(review.single.pin!.publicKey, keys[0]);
    expect(review.single.listed!.publicKey, keys[2]);

    // Rejected: still the old key, and no warning until it changes again.
    expect(await state.rejectOwnerKey(review.single), isTrue);
    expect(state.ownerKeyReview, isEmpty);
    expect(await tags(state), [keys[0], keys[1]]);

    api.owners = [owner('acct_a', keys[3], rev: 3), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0], keys[1]]);
    final again = state.ownerKeyReview.single;
    expect(again.listed!.publicKey, keys[3]);

    // A screen that read an older listing cannot accept it.
    api.owners = [owner('acct_a', keys[2], rev: 4), owner('acct_b', keys[1])];
    await tags(state);
    expect(await state.acceptOwnerKey(again), isFalse);
    expect(await tags(state), [keys[0], keys[1]]);

    expect(await state.acceptOwnerKey(state.ownerKeyReview.single), isTrue);
    expect(state.ownerKeyReview, isEmpty);
    expect(await tags(state), [keys[2], keys[1]]);
  }, skip: skip);

  test('an added key is not tagged until it is accepted', () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_b', keys[1])];
    expect(await tags(state), [keys[1]]);

    api.owners = [owner('acct_a', keys[0]), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[1]]);
    final added = state.ownerKeyReview.single;
    expect(added.change, OwnerKeyChange.added);
    expect(added.inboxId, 'acct_a');
    expect(added.pin, isNull);

    expect(await state.acceptOwnerKey(added), isTrue);
    expect(await tags(state), [keys[0], keys[1]]);
  }, skip: skip);

  test('a gone owner stays tagged until the person accepts that it is gone',
      () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_a', keys[0]), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0], keys[1]]);

    api.owners = [owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0], keys[1]]);
    final gone = state.ownerKeyReview.single;
    expect(gone.change, OwnerKeyChange.missing);
    expect(gone.inboxId, 'acct_a');

    expect(await state.acceptOwnerKey(gone), isTrue);
    expect(await tags(state), [keys[1]]);
    expect(state.ownerKeyReview, isEmpty);
  }, skip: skip);

  test('a key the server lists after the first pin is never tagged silently',
      () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_a', keys[0])];
    expect(await tags(state), [keys[0]]);

    // The server drops the owner and the person accepts it: no pin is
    // left. A key listed after that is still not pinned on first use.
    api.owners = [];
    api.unavailable = true;
    expect(await tags(state), [keys[0]]);
    expect(await state.acceptOwnerKey(state.ownerKeyReview.single), isTrue);
    expect(await tags(state), isEmpty);
    expect(await proofPins(store), isEmpty);
    expect(await store.loadReportKeyPins(_origin), isEmpty);

    api
      ..unavailable = false
      ..owners = [owner('acct_x', keys[3])];
    for (var pass = 0; pass < 3; pass++) {
      expect(await tags(state), isEmpty);
    }
    expect(await proofPins(store), isEmpty);
    expect(await store.loadReportKeyPins(_origin), isEmpty);
    expect(state.ownerKeyReview.single.change, OwnerKeyChange.added);

    // Nor when the person had pinned while reporting before any pass: a
    // pin made by a person counts as the first pin.
    final second = await start();
    await ReportKeyPinsShim.pin(second.store, owner('acct_a', keys[0]));
    second.api.owners = [owner('acct_a', keys[0]), owner('acct_x', keys[3])];
    expect(await tags(second.state), [keys[0]]);
    expect(second.state.ownerKeyReview.single.inboxId, 'acct_x');
  }, skip: skip);

  test('Settings and the sealed key screen read the review without a request',
      () async {
    final (:state, :api, :store) = await start();
    api.owners = [owner('acct_a', keys[0])];
    await tags(state);
    api.owners = [owner('acct_a', keys[1])];
    await tags(state);
    final reads = api.inboxReads.length;
    state.ownerKeyReview = const <OwnerKeyReviewItem>[];
    expect(await state.loadOwnerKeyReview(), hasLength(1));
    expect(state.ownerKeyReview, hasLength(1));
    expect(await state.sealedProvableOwnerCount(), 1);
    expect(api.inboxReads, hasLength(reads));
  }, skip: skip);

  // Owner decision 2026-11-12, "Keep reports manual": the tags go to the
  // proof recipients, which are the D95 pins a person made plus what was
  // pinned on first use or accepted on the sealed key screen; none of the
  // latter ever becomes a report pin.
  test('tags go to the proof pins, and the report pins stay manual', () async {
    final (:state, :api, :store) = await start();
    // A person pinned acct_a's key while reporting.
    await ReportKeyPinsShim.pin(store, owner('acct_a', keys[0]));
    api.owners = [owner('acct_a', keys[0]), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0]]);

    // acct_b is accepted on the sealed key screen: tagged, never a report
    // pin.
    expect(await state.acceptOwnerKey(state.ownerKeyReview.single), isTrue);
    expect(await tags(state), [keys[0], keys[1]]);
    expect(await reportPins(store), {'acct_a': keys[0]});

    // acct_a's listed key changes and is accepted: the proof follows, the
    // report pin stays the one the person compared.
    api.owners = [owner('acct_a', keys[2], rev: 2), owner('acct_b', keys[1])];
    expect(await tags(state), [keys[0], keys[1]]);
    expect(await state.acceptOwnerKey(state.ownerKeyReview.single), isTrue);
    expect(await tags(state), [keys[2], keys[1]]);
    expect(await reportPins(store), {'acct_a': keys[0]});

    // acct_a is gone and accepted as gone: no longer tagged, its report pin
    // stays (D95 reports it as missing), and no warning comes back.
    api.owners = [owner('acct_b', keys[1])];
    await tags(state);
    final gone = state.ownerKeyReview.single;
    expect(gone.change, OwnerKeyChange.missing);
    expect(await state.acceptOwnerKey(gone), isTrue);
    expect(await tags(state), [keys[1]]);
    expect(state.ownerKeyReview, isEmpty);
    expect(await reportPins(store), {'acct_a': keys[0]});
    expect(await state.sealedProvableOwnerCount(), 1);
  }, skip: skip);
}

/// Pins the way a report screen does after the person compared codes.
class ReportKeyPinsShim {
  static Future<void> pin(LocalStore store, ReportInboxRecipient recipient) =>
      store.saveReportKeyPin(ReportKeyPin(
        origin: _origin,
        ownerAccountId: recipient.inboxId,
        publicKey: recipient.publicKey,
        keyRev: recipient.keyRev,
        pinnedAt: 1,
      ));
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Lists implements DeviceListSource {
  _Lists(this.api);
  final _Api api;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
          {required int after}) =>
      api.fetchDeviceList('tok', accountId, after: after);
}

class _Api extends ApiClient {
  _Api(this.bindings) : super(baseUrl: _origin);

  final NativeCryptoBindings bindings;
  final List<Uint8List> chain = <Uint8List>[];
  List<ReportInboxRecipient> owners = <ReportInboxRecipient>[];
  bool unavailable = false;
  bool failing = false;
  final List<String> inboxReads = <String>[];

  @override
  Future<DeviceListPage?> fetchDeviceList(String token, String accountId,
      {required int after}) async {
    if (accountId != _account) return null;
    final rest = chain.skip(after).toList();
    return DeviceListPage(
      headVersion: chain.length,
      more: false,
      statements: [
        for (var i = 0; i < rest.length; i++)
          (version: after + i + 1, statement: rest[i]),
      ],
    );
  }

  @override
  Future<int> publishDeviceList(String token, List<int> statement) async {
    final list = [...chain, Uint8List.fromList(statement)];
    try {
      bindings.checkDeviceListChain(idBytes(_account), list);
    } on NativeCryptoException {
      throw ApiException(400, '{"error":"invalid_device_list"}');
    }
    chain.add(Uint8List.fromList(statement));
    return chain.length;
  }

  @override
  Future<ReportInbox> getReportInbox(
      String token, String conversationId) async {
    inboxReads.add(conversationId);
    if (failing) throw ApiException(503, '{"error":"unavailable"}');
    if (unavailable) {
      throw ApiException(409, '{"error":"report_inbox_unavailable"}');
    }
    return ReportInbox(kind: reportInboxInstanceOwner, recipients: owners);
  }
}
