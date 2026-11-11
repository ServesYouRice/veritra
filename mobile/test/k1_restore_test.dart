import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/k1_restore.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart'
    show BackupHeaderInfo, OpenedBackup;
import 'package:private_messenger/crypto/sha256.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'k0_recovery_fakes.dart';

/// K1-4: restoring history from a K1 backup (docs/designs/
/// K1-automatic-backups.md, "Restore"), against a fake server and a fake
/// container (the native container has its own tests).

final _rkId = Uint8List.fromList(List<int>.filled(16, 0xB2));
final _otherRkId = Uint8List.fromList(List<int>.filled(16, 0x77));
const _src = 'dev_src';
const _backupId = 'backup_00112233445566778899aabbccddeeff';

LocalMessage _msg(String action) => LocalMessage(
    key: '$_src:$action',
    conversationId: 'conv',
    senderAccountId: 'bob',
    senderDeviceId: _src,
    kind: 'text',
    body: action,
    createdAt: 1700000000000,
    state: 'received',
    senderHidden: false);

Uint8List _snapshotBytes({String account = 'acct_me', String device = _src}) =>
    Uint8List.fromList(HistorySnapshot(
        accountId: account,
        sourceDeviceId: device,
        counter: 7,
        createdAt: 1731000000000,
        conversations: const [
          HistoryConversation('conv', 'dm', title: 'old chat')
        ],
        messages: [_msg('hello')],
        reactions: const [],
        pins: const [],
        starred: const {},
        preferences: const []).encode());

class _RestoreCrypto extends K0Crypto implements BackupOpenCryptoService {
  Uint8List rkId = _rkId;
  List<Uint8List> entropies = <Uint8List>[];
  Uint8List snapshot = _snapshotBytes();
  String headerAccount = 'acct_me';
  String headerDevice = _src;
  int headerCounter = 3;
  bool failOpen = false;
  final List<String?> pinned = <String?>[];
  final List<Uint8List> plaintexts = <Uint8List>[];

  @override
  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List value) async {
    entropies.add(value);
    final base = await super.deriveRecoveryKey(value);
    return RecoveryKeyValues(
        rkPub: base.rkPub, rkId: rkId, rkAuthPub: base.rkAuthPub);
  }

  BackupHeaderInfo _header() => BackupHeaderInfo(
      accountId: headerAccount,
      sourceDeviceId: headerDevice,
      createdAtMs: 1731000000000,
      counter: headerCounter,
      rkId: _rkId,
      plaintextVersion: 1,
      paddedSize: 1 << 20);

  @override
  BackupHeaderInfo peekK1Backup(Uint8List prefix) => _header();

  @override
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) async {
    pinned.add(sourceDeviceId);
    if (failOpen) throw StateError('open failed');
    final copy = Uint8List.fromList(snapshot);
    plaintexts.add(copy);
    return OpenedBackup(header: _header(), plaintext: copy);
  }
}

class _RestoreApi extends K0Api {
  _RestoreApi(super.server, this.container, this.rows);

  Uint8List container;
  List<Map<String, Object?>> rows;
  final List<String> ranges = <String>[];
  Object? downloadFailure;

  @override
  Future<List<Map<String, Object?>>> listBackups(String token,
          {int limit = 100}) async =>
      rows;

  @override
  Future<Stream<List<int>>> downloadBackup(String token, String id,
      {int? start, int? end}) async {
    if (downloadFailure != null) throw downloadFailure!;
    ranges.add('$start-$end');
    final bytes = start == null
        ? container
        : Uint8List.sublistView(container, start, end! + 1);
    return Stream<List<int>>.value(bytes);
  }
}

Map<String, Object?> _row(Uint8List container,
        {String id = _backupId,
        String device = _src,
        int kind = 1,
        bool superseded = false,
        Uint8List? rk,
        String? sha}) =>
    <String, Object?>{
      'id': id,
      'device_id': device,
      'device_name': 'Old phone',
      'device_revoked': true,
      'kind': kind,
      'ciphertext_sha256': sha ??
          sha256(container)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
      'size_bytes': container.length,
      'created_at': '2026-11-08T09:00:00Z',
      'counter': 3,
      'rk_id': base64.encode(rk ?? _rkId),
      'superseded': superseded,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late K0Server server;
  late MemoryLocalStore store;
  late _RestoreCrypto crypto;
  late _RestoreApi api;
  late AppState state;
  late Uint8List container;

  setUp(() async {
    server = K0Server()..requireRecentAuth = false;
    store = MemoryLocalStore();
    crypto = _RestoreCrypto();
    container =
        Uint8List.fromList(List<int>.generate(2000, (i) => (i * 7 + 3) & 0xff));
    api = _RestoreApi(server, container, [_row(container)]);
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => K0QuietSync(),
    );
    state.k1DesktopTimerEnabled = false;
    server.status =
        RecoveryKeyStatus(available: true, configured: true, rkId: _rkId);
    await store.saveSession(k0SignedIn);
    await state.tryRestoreSession();
  });

  tearDown(() => state.dispose());

  Future<List<String>> bodies() async =>
      (await store.exportHistorySnapshot()).isEmpty
          ? <String>[]
          : HistorySnapshot.decode(await store.exportHistorySnapshot())
              .messages
              .map((m) => m.body ?? '')
              .toList();

  test('restores into an enrolled device, keeps the key, wipes buffers',
      () async {
    final list = (await state.loadK1RestoreList())!;
    expect(list, hasLength(1));
    final result = await state.restoreFromK1Backup(list.single, k0Display);
    expect(result, K1RestoreResult.done);
    expect(await bodies(), contains('hello'));
    // The header was peeked with a ranged request, then the whole file.
    expect(api.ranges, <String>['0-415', 'null-null']);
    // Rust was told which device the row names.
    expect(crypto.pinned, <String?>[_src]);
    expect(crypto.plaintexts.single, everyElement(0));
    expect(crypto.entropies.single, everyElement(0));
    // The typed key (also the account's current key) turns backups on here.
    final saved = state.k1BackupState!;
    expect(saved.rkId, _rkId);
    expect(saved.rkPub, isNotNull);
    expect(saved.lastSuccessAt, isNull);
    // Restoring again changes nothing (ledger).
    expect(await state.restoreFromK1Backup(list.single, k0Display),
        K1RestoreResult.done);
    expect((await bodies()).where((b) => b == 'hello'), hasLength(1));
  });

  test('another key than the copy is sealed to fails before any download',
      () async {
    crypto.rkId = _otherRkId;
    final entry = (await state.loadK1RestoreList())!.single;
    expect(
        await state.restoreFromK1Backup(entry, k0Display), K1RestoreResult.otherKey);
    expect(api.ranges, isEmpty);
    expect(crypto.entropies.single, everyElement(0));
  });

  test('a wrong header, digest or snapshot imports nothing', () async {
    final entry = (await state.loadK1RestoreList())!.single;
    Future<void> corrupt() async => expect(
        await state.restoreFromK1Backup(entry, k0Display), K1RestoreResult.corrupt);
    crypto.headerAccount = 'acct_other';
    await corrupt();
    crypto.headerAccount = 'acct_me';
    crypto.headerDevice = 'dev_other';
    await corrupt();
    crypto.headerDevice = _src;
    crypto.headerCounter = 9;
    await corrupt();
    crypto.headerCounter = 3;
    // A body that is not the one the row names.
    api.container = Uint8List.fromList(container.reversed.toList());
    await corrupt();
    api.container = container;
    // A snapshot of another account or device inside a good container.
    crypto.snapshot = _snapshotBytes(account: 'acct_other');
    await corrupt();
    crypto.snapshot = _snapshotBytes(device: 'dev_other');
    await corrupt();
    // A container Rust refuses.
    crypto.snapshot = _snapshotBytes();
    crypto.failOpen = true;
    await corrupt();
    expect(await bodies(), isNot(contains('hello')));
    expect(state.k1BackupState?.hasKey ?? false, isFalse);
  });

  test('a network failure is retryable and changes nothing', () async {
    final entry = (await state.loadK1RestoreList())!.single;
    api.downloadFailure = ApiException(503, '');
    expect(
        await state.restoreFromK1Backup(entry, k0Display), K1RestoreResult.network);
    expect(await bodies(), isNot(contains('hello')));
  });

  test('the list holds K1 copies of other devices only, current first', () {
    final rows = <Map<String, Object?>>[
      _row(container, id: 'backup_own', device: 'dev_old'),
      _row(container, id: 'backup_legacy', kind: 0),
      _row(container, id: 'backup_prev', superseded: true),
      _row(container, id: 'backup_cur'),
      _row(container, id: 'backup_junk', sha: 'zz'),
    ];
    final candidates = k1RestoreCandidates(
        rows.map(K1BackupEntry.tryParse).whereType<K1BackupEntry>(),
        'dev_old');
    expect(candidates.map((e) => e.id), <String>['backup_cur', 'backup_prev']);
  });

  test('a restore on the copy-source device itself is refused', () async {
    final entry = K1BackupEntry.tryParse(
        _row(container, id: 'backup_own', device: 'dev_old'))!;
    expect(await state.restoreFromK1Backup(entry, k0Display),
        K1RestoreResult.unavailable);
  });
}
