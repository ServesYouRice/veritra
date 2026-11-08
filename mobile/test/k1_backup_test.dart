import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_recovery.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/k1_backup.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage, LocalMessageReaction;
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'k0_recovery_fakes.dart';

/// K1-3: the daily backup run on the client (docs/designs/
/// K1-automatic-backups.md, "The daily run"), against a fake server.

final _rkId = Uint8List.fromList(List<int>.filled(16, 0xB2));
final _otherRkId = Uint8List.fromList(List<int>.filled(16, 0x77));

class K1Crypto extends K0Crypto implements BackupSealCryptoService {
  final List<Map<String, Object?>> k1Seals = <Map<String, Object?>>[];
  final List<Uint8List> plaintexts = <Uint8List>[];
  final List<Uint8List> ciphertexts = <Uint8List>[];
  int maxPlaintext = 1 << 20;

  @override
  int get k1BackupMaxPlaintextBytes => maxPlaintext;

  @override
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) async {
    k1Seals.add(<String, Object?>{
      'account': accountId,
      'device': sourceDeviceId,
      'counter': counter,
      'rk_pub': List<int>.of(rkPub),
      'plain': utf8.decode(plaintext),
    });
    plaintexts.add(plaintext);
    final sealed = Uint8List.fromList(<int>[0x56, 0x48, 0x43, 0x31, counter]);
    ciphertexts.add(sealed);
    return sealed;
  }
}

class K1Upload {
  K1Upload(this.bytes, this.rkId, this.counter);
  final List<int> bytes;
  final List<int> rkId;
  final int counter;
}

class K1Api extends K0Api {
  K1Api(super.server, this.uploads, this.failures, [super.baseUrl]);

  final List<K1Upload> uploads;
  final List<Object> failures;

  @override
  Future<RecoveryKeyStatus> putRecoveryKey(String token,
      {required List<int> rkAuthPub,
      required List<int> rkId,
      List<int>? deviceList}) async {
    await super.putRecoveryKey(token,
        rkAuthPub: rkAuthPub, rkId: rkId, deviceList: deviceList);
    server.status = RecoveryKeyStatus(
        available: true,
        configured: true,
        setAt: DateTime.utc(2026, 11, 1),
        rkId: Uint8List.fromList(rkId));
    return server.status;
  }

  @override
  Future<void> uploadK1Backup(String token, Uint8List ciphertext,
      {required List<int> rkId, required int counter}) async {
    if (failures.isNotEmpty) throw failures.removeAt(0);
    uploads
        .add(K1Upload(List<int>.of(ciphertext), List<int>.of(rkId), counter));
  }
}

void main() {
  late K0Server server;
  late MemoryLocalStore store;
  late K1Crypto crypto;
  late List<K1Upload> uploads;
  late List<Object> failures;
  late AppState state;
  late DateTime now;

  AppState app(LocalStore store) {
    final created = AppState(
      apiClientFactory: (url) => K1Api(server, uploads, failures, url),
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => K0QuietSync(),
    );
    created.k1Clock = () => now;
    created.k1DesktopTimerEnabled = false;
    return created;
  }

  setUp(() {
    server = K0Server()..requireRecentAuth = false;
    store = MemoryLocalStore();
    crypto = K1Crypto();
    uploads = <K1Upload>[];
    failures = <Object>[];
    now = DateTime.utc(2026, 11, 8, 9);
    state = app(store);
  });

  tearDown(() => state.dispose());

  Future<void> signIn() async {
    await store.saveSession(k0SignedIn);
    await state.tryRestoreSession();
    expect(state.session?.token, 'tok_old');
  }

  Future<void> settle() async {
    for (var i = 0; i < 50 && state.k1BackupRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  Future<void> saveKey() async {
    final draft = await state.createRecoveryKeyDraft();
    expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
    draft.dispose();
    await settle();
  }

  test('saving the key stores rk_pub and backs up at once, then daily',
      () async {
    await signIn();
    expect(state.k1BackupSupported, isTrue);
    expect(state.k1BackupView, K1BackupView.noKey);
    expect(state.k1ShouldOfferRecoveryKey, isTrue);
    await saveKey();

    expect(state.k1BackupView, K1BackupView.on);
    expect(state.k1ShouldOfferRecoveryKey, isFalse);
    expect(uploads, hasLength(1));
    expect(uploads.single.counter, 1);
    expect(uploads.single.rkId, _rkId);
    final seal = crypto.k1Seals.single;
    expect(seal['account'], 'acct_me');
    expect(seal['device'], 'dev_old');
    expect(seal['rk_pub'], List<int>.filled(32, 0xC3));
    // The plaintext is the history snapshot, and it is wiped after sealing;
    // so is the ciphertext once uploaded.
    expect(jsonDecode(seal['plain']! as String)['version'], 1);
    expect(crypto.plaintexts.single, everyElement(0));
    expect(crypto.ciphertexts.single, everyElement(0));
    expect(state.k1BackupState!.lastSuccessAt, now);

    // Stored, scoped to this account and device; a reload reads it back.
    final saved =
        K1BackupState.decode(await store.loadSetting(k1BackupStateSetting))!;
    expect(saved.belongsTo(k0Origin, 'acct_me', 'dev_old'), isTrue);
    expect(saved.rkPub, List<int>.filled(32, 0xC3));
    expect(saved.counter, 1);

    // Not due within a day, even on every open.
    now = now.add(const Duration(hours: 23));
    expect(await state.runK1BackupIfDue(), isFalse);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(uploads, hasLength(1));
    // Due after a day; the counter goes up.
    now = now.add(const Duration(hours: 1));
    expect(await state.runK1BackupIfDue(), isTrue);
    expect(uploads.last.counter, 2);
    // "Back up now" runs regardless.
    expect(await state.runK1BackupIfDue(force: true), isTrue);
    expect(uploads.last.counter, 3);
  });

  test('a changed key pauses backups until the new key is typed here',
      () async {
    await signIn();
    await saveKey();
    // Another device replaced the key.
    server.status =
        RecoveryKeyStatus(available: true, configured: true, rkId: _otherRkId);
    now = now.add(const Duration(days: 1));
    expect(await state.runK1BackupIfDue(), isFalse);
    expect(uploads, hasLength(1));
    expect(state.k1BackupState!.lastError, K1BackupError.keyChanged);
    expect(state.k1BackupView, K1BackupView.needsKeyHere);
    // It waits for the user, not the clock.
    now = now.add(const Duration(days: 2));
    expect(await state.runK1BackupIfDue(), isFalse);

    // A key that is not the account's is refused, without saying why.
    expect(await state.enableK1BackupsWithKey('not a key'), isFalse);
    // The fake derives rk_id B2, which is no longer the account's key.
    expect(await state.enableK1BackupsWithKey(k0Display), isFalse);
    server.status =
        RecoveryKeyStatus(available: true, configured: true, rkId: _rkId);
    expect(await state.enableK1BackupsWithKey(k0Display), isTrue);
    await settle();
    expect(state.k1BackupView, K1BackupView.on);
    expect(uploads, hasLength(2));
    expect(uploads.last.counter, 2);
    // The typed key's entropy was wiped.
    expect(crypto.handedOut.last, everyElement(0));
  });

  test('another device of the account backs up nothing until the key is typed',
      () async {
    server.status =
        RecoveryKeyStatus(available: true, configured: true, rkId: _rkId);
    await signIn();
    await settle();
    expect(state.k1BackupView, K1BackupView.needsKeyHere);
    expect(state.k1ShouldOfferRecoveryKey, isFalse);
    expect(state.k1BackupNeedsAttention, isTrue);
    expect(await state.runK1BackupIfDue(force: true), isFalse);
    expect(uploads, isEmpty);
    expect(await state.enableK1BackupsWithKey(k0Display), isTrue);
    await settle();
    expect(uploads.single.counter, 1);
  });

  test('failures back off 1 h, 4 h, then a day, and keep their kind', () async {
    await signIn();
    failures.add(ApiException(503, '{"error":"unavailable"}'));
    await saveKey();
    final backup = state.k1BackupState!;
    expect(backup.lastError, K1BackupError.network);
    // The counter was committed before the upload, so the retry uses 2.
    expect(backup.counter, 1);
    expect(backup.nextAttemptAt, now.add(const Duration(hours: 1)));
    expect(await state.runK1BackupIfDue(), isFalse);

    now = now.add(const Duration(hours: 1));
    failures.add(k0Error(507, 'storage_quota_exceeded'));
    expect(await state.runK1BackupIfDue(), isFalse);
    expect(backup.lastError, K1BackupError.spaceFull);
    expect(backup.nextAttemptAt, now.add(const Duration(hours: 4)));

    now = now.add(const Duration(hours: 4));
    failures.add(k0Error(500, 'backup_record_failed'));
    expect(await state.runK1BackupIfDue(), isFalse);
    expect(backup.nextAttemptAt, now.add(const Duration(hours: 24)));

    now = now.add(const Duration(hours: 24));
    expect(await state.runK1BackupIfDue(), isTrue);
    expect(uploads.single.counter, 4);
    expect(backup.lastError, isNull);
    expect(backup.failures, 0);
  });

  test('a week with no good copy warns', () async {
    await signIn();
    await saveKey();
    expect(state.k1BackupStale, isFalse);
    now = now.add(const Duration(days: 7));
    failures.add(ApiException(503, ''));
    await state.runK1BackupIfDue();
    expect(state.k1BackupStale, isTrue);
    expect(state.k1BackupNeedsAttention, isTrue);
  });

  test('a stale counter jumps past the server once and retries', () async {
    await signIn();
    failures.add(k0Error(409, 'backup_counter_stale'));
    await saveKey();
    expect(uploads, hasLength(1));
    expect(uploads.single.counter, now.millisecondsSinceEpoch);
    expect(state.k1BackupState!.lastError, isNull);
    // Two stale answers in one run end it as a failure.
    now = now.add(const Duration(days: 1));
    failures
      ..add(k0Error(409, 'backup_counter_stale'))
      ..add(k0Error(409, 'backup_counter_stale'));
    expect(await state.runK1BackupIfDue(), isFalse);
    expect(state.k1BackupState!.lastError, K1BackupError.failed);
  });

  test('a history above the cap is not sent; the last copy is kept', () async {
    await signIn();
    crypto.maxPlaintext = 10;
    await saveKey();
    expect(uploads, isEmpty);
    expect(crypto.k1Seals, isEmpty);
    expect(state.k1BackupState!.lastError, K1BackupError.tooLarge);
  });

  test('a server with recovery off backs up nothing', () async {
    await signIn();
    await saveKey();
    server.status = const RecoveryKeyStatus(available: false, configured: true);
    expect(await state.runK1BackupIfDue(force: true), isFalse);
    expect(state.k1BackupState!.lastError, K1BackupError.unavailable);
    expect(state.k1BackupView, K1BackupView.serverOff);
  });

  test('"Not now" hides the prompt for three days', () async {
    await signIn();
    expect(state.k1ShouldOfferRecoveryKey, isTrue);
    await state.snoozeRecoveryKeyPrompt();
    expect(state.k1ShouldOfferRecoveryKey, isFalse);
    expect(state.k1BackupNeedsAttention, isTrue);
    now = now.add(const Duration(days: 3));
    expect(state.k1ShouldOfferRecoveryKey, isTrue);
  });

  test('a build without the backup seal offers no K1 backups', () async {
    final plain = AppState(
      apiClientFactory: (url) => K1Api(server, uploads, failures, url),
      cryptoService: K0Crypto(),
      localStore: store,
      syncServiceFactory: (_, __) => K0QuietSync(),
    );
    addTearDown(plain.dispose);
    expect(plain.k1BackupSupported, isFalse);
    expect(plain.k1ShouldOfferRecoveryKey, isFalse);
    expect(await plain.runK1BackupIfDue(force: true), isFalse);
  });

  test('the state of another account or device is never used', () async {
    await store.saveSetting(
        k1BackupStateSetting,
        (K1BackupState(
                baseUrl: k0Origin, accountId: 'acct_other', deviceId: 'dev_old')
              ..setKey(Uint8List(32), _rkId))
            .encode());
    server.status =
        RecoveryKeyStatus(available: true, configured: true, rkId: _rkId);
    await signIn();
    await settle();
    expect(state.k1BackupView, K1BackupView.needsKeyHere);
    expect(uploads, isEmpty);
  });

  test('no k1 setting or key bytes ride in a snapshot or a backup', () async {
    await signIn();
    await saveKey();
    final rkPub = base64.encode(List<int>.filled(32, 0xC3));
    final snapshot = utf8.decode(await store.exportHistorySnapshot());
    final k1Snapshot =
        utf8.decode(await store.exportHistorySnapshot(omitDisappearing: true));
    for (final text in <String>[snapshot, k1Snapshot]) {
      expect(text, isNot(contains(k1SettingPrefix)));
      expect(text, isNot(contains(rkPub)));
    }
    // What was sealed is the same kind of snapshot.
    expect(crypto.k1Seals.single['plain'], isNot(contains(k1SettingPrefix)));
  });

  group('state and schedule', () {
    test('backoff steps', () {
      expect(k1BackupBackoff(1), const Duration(hours: 1));
      expect(k1BackupBackoff(2), const Duration(hours: 4));
      expect(k1BackupBackoff(3), const Duration(hours: 24));
      expect(k1BackupBackoff(9), const Duration(hours: 24));
    });

    test('encode and decode round trip; garbage reads as null', () {
      final at = DateTime.utc(2026, 11, 1);
      final original = K1BackupState(
          baseUrl: k0Origin, accountId: 'a', deviceId: 'd', counter: 7)
        ..setKey(Uint8List(32)..[0] = 1, _rkId)
        ..recordFailure(K1BackupError.spaceFull, at)
        ..keyPromptSnoozedUntil = at;
      final copy = K1BackupState.decode(original.encode())!;
      expect(copy.counter, 7);
      expect(copy.rkPub![0], 1);
      expect(copy.rkId, _rkId);
      expect(copy.lastError, K1BackupError.spaceFull);
      expect(copy.failures, 1);
      expect(copy.nextAttemptAt, at.add(const Duration(hours: 1)));
      expect(copy.keyPromptSnoozedUntil, at);
      for (final bad in <String?>[
        null,
        '',
        'x',
        '{"v":2}',
        '[]',
        '{"v":1,"base_url":"u","account_id":"a","device_id":"d","counter":-1}',
      ]) {
        expect(K1BackupState.decode(bad), isNull, reason: bad);
      }
      // A malformed key is dropped, the counter kept.
      final broken = jsonDecode(original.encode()) as Map<String, Object?>;
      broken['rk_pub'] = base64.encode(<int>[1, 2, 3]);
      final read = K1BackupState.decode(jsonEncode(broken))!;
      expect(read.hasKey, isFalse);
      expect(read.counter, 7);
    });

    test('views', () {
      final withKey =
          K1BackupState(baseUrl: k0Origin, accountId: 'a', deviceId: 'd')
            ..setKey(Uint8List(32), _rkId);
      K1BackupView view(bool? available, bool? configured, List<int>? id,
              K1BackupState? s) =>
          computeK1BackupView(
              serverAvailable: available,
              accountConfigured: configured,
              accountRkId: id,
              state: s);
      expect(view(null, null, null, null), K1BackupView.unknown);
      expect(view(null, null, null, withKey), K1BackupView.on);
      expect(view(false, true, _rkId, withKey), K1BackupView.serverOff);
      expect(view(true, false, null, null), K1BackupView.noKey);
      expect(view(true, true, _rkId, null), K1BackupView.needsKeyHere);
      expect(view(true, true, _otherRkId, withKey), K1BackupView.needsKeyHere);
      expect(view(true, true, _rkId, withKey), K1BackupView.on);
    });
  });

  group('snapshot for a backup', () {
    final at = DateTime.now().millisecondsSinceEpoch;
    LocalMessage message(String key, {int? expires}) => LocalMessage(
        key: 'source:$key',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'source',
        kind: 'text',
        body: 'body $key',
        createdAt: at - 1000,
        state: 'received',
        expiresAt: expires,
        senderHidden: false);

    HistorySnapshot capture({required bool omit}) => captureHistory(
        session: const Session(
            baseUrl: k0Origin,
            token: 't',
            accountId: 'alice',
            deviceId: 'source'),
        namespace: HistoryNamespace(),
        conversations: [Conversation(id: 'conv', kind: 'dm', title: 't')],
        messages: [message('kept'), message('vanishing', expires: at + 60000)],
        reactions: [
          const LocalMessageReaction(
              targetKey: 'source:vanishing',
              reactorAccountId: 'bob',
              reaction: 'x',
              updatedAt: 1)
        ],
        pins: const [],
        starred: {'source:vanishing': 1},
        preferences: const [],
        now: at,
        omitDisappearing: omit);

    test('leaves out every disappearing message and what points at it', () {
      final k1 = capture(omit: true);
      expect(k1.messages.map((m) => m.key), <String>['source:kept']);
      expect(k1.reactions, isEmpty);
      expect(k1.starred, isEmpty);
      // It stays a valid snapshot the K2 importer reads.
      final decoded = HistorySnapshot.decode(k1.encode());
      expect(decoded.messages, hasLength(1));
      // A K2 hand-off is unchanged: the unexpired message still goes.
      expect(capture(omit: false).messages, hasLength(2));
    });
  });
}
