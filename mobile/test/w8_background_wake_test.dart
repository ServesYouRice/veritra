// W8/D52: muted-chat mentions decided on the device after decryption.
//
// The notice processor turns the private notice outbox into opaque generic
// notice requests; AppState runs one bounded background pass on its own sync
// owner. Native cold execution and server opt-in stay disabled; these tests
// drive the Dart side through a fake native bridge and a fake bounded
// crypto service that commits through the real stores.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/desktop/desktop_shell.dart';
import 'package:private_messenger/desktop/message_notifications.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/push/background_wake_runner.dart';
import 'package:private_messenger/push/notice_decisions.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/push/wake_worker_bridge.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _origin = 'https://example.test';
const _owner =
    LocalNoticeOwner(origin: _origin, accountId: 'alice', deviceId: 'phone');
const _session = Session(
    baseUrl: _origin, token: 'token', accountId: 'alice', deviceId: 'phone');

String _mention(String account) => jsonEncode({
      'mentions': [
        {'account_id': account, 'offset': 0, 'length': 6}
      ]
    });

/// Commits one received text row, with a notice reference when [capture].
Future<void> _receive(LocalStore store, String key,
    {String sender = 'bob',
    String conversation = 'conv',
    String? format,
    int? createdAt,
    bool capture = true,
    void Function()? fence}) async {
  final state = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  final at = createdAt ?? DateTime.now().millisecondsSinceEpoch;
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'event-${cursor + 1}',
      conversationId: conversation,
      expectedCounter: state.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: state.counter + 1,
          stateKey: state.stateKey,
          sealedState: [state.counter + 1]),
      cursor: cursor + 1,
      messageEffects: [
        InsertMessageEffect(
            key: 'dev_$sender:$key',
            serverMessageId: 'srv-$key',
            conversationId: conversation,
            senderAccountId: sender,
            senderDeviceId: 'dev_$sender',
            kind: LocalMessageKind.text,
            body: '@alice hello',
            formatJson: format,
            createdAt: at,
            state: LocalMessageState.received)
      ],
      noticeReferences: [
        if (capture)
          LocalNoticeReference(
              owner: _owner,
              eventId: cursor + 1,
              messageKey: 'dev_$sender:$key',
              serverMessageId: 'srv-$key',
              conversationId: conversation,
              senderAccountId: sender,
              senderDeviceId: 'dev_$sender',
              createdAt: at)
      ],
      checkCanCommit: fence));
}

Future<LocalStore> _store(
    bool sql, Directory directory, List<EncryptedLocalDatabase> opened) async {
  final LocalStore store = sql
      ? SecureLocalStore(
          directoryProvider: () async => directory,
          databaseFactory: (_, __) {
            final database = EncryptedLocalDatabase(NativeDatabase.memory());
            opened.add(database);
            return database;
          })
      : MemoryLocalStore();
  await store.saveSession(_session);
  await store.saveCryptoState(
      StoredCryptoState(
          counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
      0);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sql in [false, true]) {
    group(sql ? 'SQLite notice processor' : 'memory notice processor', () {
      late Directory directory;
      late LocalStore store;
      final opened = <EncryptedLocalDatabase>[];
      late List<String> presented;
      late LocalNoticeOutcome answer;
      bool? muted;
      bool? blocked;
      bool? accepted;
      var mentions = true;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('veritra-wake-');
        FlutterSecureStorage.setMockInitialValues({});
        store = await _store(sql, directory, opened);
        presented = [];
        answer = LocalNoticeOutcome.shown;
        muted = true;
        blocked = false;
        accepted = true;
        mentions = true;
      });
      tearDown(() async {
        for (final database in opened) {
          await database.close();
        }
        opened.clear();
        await SecureLocalStore.releaseInstanceLocks();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      LocalNoticeProcessor processor() => LocalNoticeProcessor(
          store: store,
          session: _session,
          policy: NoticePolicy(
              blocked: (_) async => blocked,
              conversationAccepted: (_) => accepted,
              muted: (_) async => muted,
              mentionsInMutedChats: mentions),
          present: (id) async {
            presented.add(id);
            return answer;
          });
      Future<List<LocalNoticeReference>> pending() =>
          store.pendingNoticeReferences(_owner);

      test('a muted mention alerts once and a plain muted message stays quiet',
          () async {
        await _receive(store, 'plain');
        await _receive(store, 'mention', format: _mention('alice'));
        await _receive(store, 'other', format: _mention('carol'));
        final result = await processor().run();
        expect(result.durable, isTrue);
        expect(result.shown, 1);
        expect(presented, hasLength(1));
        expect(presented.single, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(await pending(), isEmpty);
        // A second pass has nothing left to say.
        expect((await processor().run()).shown, 0);
        expect(presented, hasLength(1));
      });

      test('the muted-mention switch off keeps a muted chat silent', () async {
        mentions = false;
        await _receive(store, 'mention', format: _mention('alice'));
        final result = await processor().run();
        expect(result.durable, isTrue);
        expect(presented, isEmpty);
      });

      test('an unmuted chat alerts for an ordinary message', () async {
        muted = false;
        await _receive(store, 'plain');
        expect((await processor().run()).shown, 1);
      });

      test('unknown mute, block or acceptance leaves the reference pending',
          () async {
        await _receive(store, 'mention', format: _mention('alice'));
        for (final setUnknown in <void Function()>[
          () => muted = null,
          () => blocked = null,
          () => accepted = null,
        ]) {
          muted = true;
          blocked = false;
          accepted = true;
          setUnknown();
          final result = await processor().run();
          expect(result.durable, isFalse);
          expect(presented, isEmpty);
          expect(await pending(), hasLength(1));
        }
      });

      test('blocked senders and message requests never alert', () async {
        muted = false;
        blocked = true;
        await _receive(store, 'a');
        expect((await processor().run()).durable, isTrue);
        blocked = false;
        accepted = false;
        await _receive(store, 'b');
        expect((await processor().run()).durable, isTrue);
        expect(presented, isEmpty);
        expect(await pending(), isEmpty);
      });

      test('a lost native answer retries the same opaque decision', () async {
        await _receive(store, 'mention', format: _mention('alice'));
        answer = LocalNoticeOutcome.unavailable;
        expect((await processor().run()).durable, isFalse);
        answer = LocalNoticeOutcome.shown;
        expect((await processor().run()).durable, isTrue);
        expect(presented, hasLength(2));
        expect(presented.toSet(), hasLength(1),
            reason: 'native deduplicates by this stable ID');
      });

      test('a frozen decision whose message is now muted is suppressed',
          () async {
        muted = false;
        await _receive(store, 'plain');
        answer = LocalNoticeOutcome.unavailable;
        await processor().run();
        muted = true;
        answer = LocalNoticeOutcome.shown;
        final result = await processor().run();
        expect(result.durable, isTrue);
        expect(presented, hasLength(1), reason: 'not presented again');
        expect(await store.pendingNoticeDecision(_owner), isNull);
      });

      test('a stale message from catch-up never alerts', () async {
        muted = false;
        await _receive(store, 'old',
            createdAt: DateTime.now()
                .subtract(const Duration(minutes: 11))
                .millisecondsSinceEpoch);
        await processor().run();
        expect(presented, isEmpty);
      });

      test('the foreground watermark suppresses captured references', () async {
        await _receive(store, 'mention', format: _mention('alice'));
        await store.suppressNoticesThrough(
            _owner, await store.loadSyncCursor());
        await processor().run();
        expect(presented, isEmpty);
      });
    });
  }

  test(
      'Linux desktop: a muted mention notifies after decryption, '
      'a plain muted message does not', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
    await store.saveSnapshot([
      Conversation(id: 'conv', kind: 'group', title: 'Team', createdBy: 'bob')
    ], const {}, 0);
    final api = _FakeApi()..muted = true;
    api.events
      ..add(api.event(1, 'plain'))
      ..add(api.event(2, 'mention', mention: 'alice'));
    final crypto = _FakeCrypto(store);
    final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: crypto,
        localStore: store,
        config: const ClientConfig(syncWhileUnfocused: true),
        syncServiceFactory: (_, __) => _QuietSync());
    addTearDown(state.dispose);
    // An unfocused desktop window keeps syncing (W4) and notifies (W3).
    state.handleAppLifecycleState(AppLifecycleState.inactive);
    final notifier = _Notifier();
    MessageNotifier(
        state: state,
        shell: _Shell(),
        notifier: notifier,
        settings: NotificationSettings(MemoryNotificationSettingsStore()),
        l10n: () => englishL10n).attach();
    await state.tryRestoreSession();
    await _until(() async => notifier.shown.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await store.loadSyncCursor(), 2);
    expect(crypto.unboundedCalls, 2);
    expect(notifier.shown, ['@alice hello'],
        reason: 'only the mention; the plain muted message stays quiet');

    // The switch off: the next mention in the muted chat stays quiet.
    await state.setMentionsInMutedChats(false);
    api.events.add(api.event(3, 'again', mention: 'alice'));
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    state.handleAppLifecycleState(AppLifecycleState.inactive);
    await _until(() async => await store.loadSyncCursor() == 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(notifier.shown, hasLength(1));
  });

  group('AppState background wake', () {
    late MemoryLocalStore store;
    late _FakeApi api;
    late _FakeCrypto crypto;
    late _FakeBridge bridge;
    late _CountingPush push;
    late AppState state;
    late BackgroundWakeRunner runner;
    var sockets = 0;

    setUp(() async {
      store = MemoryLocalStore();
      await store.saveSession(_session);
      await store.saveCryptoState(
          StoredCryptoState(
              counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
          0);
      await store.saveSnapshot([
        Conversation(id: 'conv', kind: 'group', title: 'Team', createdBy: 'bob')
      ], const {}, 0);
      api = _FakeApi();
      crypto = _FakeCrypto(store)..noticeCaptureEnabled = true;
      bridge = _FakeBridge();
      push = _CountingPush();
      sockets = 0;
      state = AppState(
          apiClientFactory: (_) => api,
          cryptoService: crypto,
          localStore: store,
          pushService: push,
          syncServiceFactory: (_, __) {
            sockets++;
            return _QuietSync();
          });
      // A headless engine has no view; main_demo does the same.
      state.handleAppLifecycleState(AppLifecycleState.detached);
      runner = BackgroundWakeRunner(
          profile: 'demo',
          bridge: bridge,
          restoreExisting: state.restoreForBackgroundWake,
          catchUp: state.catchUpForBackgroundWake,
          mayStart: () => !state.foregroundActive);
    });
    tearDown(() => state.dispose());

    WakePermit permit([int generation = 1]) => WakePermit(
        permit: 'permit-$generation',
        profile: 'demo',
        wakeGeneration: generation,
        budgetMs: 20000,
        deadlineEpochMs: DateTime.now().millisecondsSinceEpoch + 20000);

    test('a cold wake decrypts, alerts once for a muted mention, sends nothing',
        () async {
      api.muted = true;
      api.events.add(api.event(1, 'mention', mention: 'alice'));
      api.events.add(api.event(2, 'plain'));
      expect(await runner.run(permit()), WakeOutcome.committed);
      expect(await store.loadSyncCursor(), 2);
      expect(crypto.boundedCalls, 2);
      expect(crypto.unboundedCalls, 0);
      expect(bridge.presented, hasLength(1));
      expect(push.acknowledged, isEmpty, reason: 'native acknowledges');
      expect(push.registered, 0);
      expect(sockets, 0, reason: 'no websocket from a background pass');
      expect(api.writes, isEmpty, reason: 'a background pass only receives');
      expect(api.closed, greaterThan(0), reason: 'job client is closed');
      expect(state.foregroundActive, isFalse);
      expect(await store.pendingNoticeReferences(_owner), isEmpty);
    });

    test('an unreadable mute commits messages but keeps the wake pending',
        () async {
      api.muteFails = true;
      api.events.add(api.event(1, 'mention', mention: 'alice'));
      expect(await runner.run(permit()), WakeOutcome.retry);
      expect(await store.loadSyncCursor(), 1);
      expect(bridge.presented, isEmpty);
      expect(await store.pendingNoticeReferences(_owner), hasLength(1));
      // The person opens the app: nothing captured before becomes a late
      // phone notice, and the foreground owner takes over.
      state.handleAppLifecycleState(AppLifecycleState.resumed);
      await _until(
          () async => (await store.pendingNoticeReferences(_owner)).isEmpty);
      expect(bridge.presented, isEmpty);
    });

    test('a revoked permit stops before any commit', () async {
      bridge.active = false;
      api.events.add(api.event(1, 'mention', mention: 'alice'));
      expect(await runner.run(permit()), WakeOutcome.retry);
      expect(await store.loadSyncCursor(), 0);
      expect(bridge.presented, isEmpty);
    });

    test('a second wake in a warm process reuses the same owner', () async {
      api.muted = true;
      api.events.add(api.event(1, 'plain'));
      expect(await runner.run(permit()), WakeOutcome.committed);
      api.events.add(api.event(2, 'mention', mention: 'alice'));
      expect(await runner.run(permit(2)), WakeOutcome.committed);
      expect(bridge.presented, hasLength(1));
      expect(await runner.run(permit(3)), WakeOutcome.noChange);
    });

    test('a UI resume during a running wake pass still syncs in the foreground',
        () async {
      api.events.add(api.event(1, 'plain'));
      api.events.add(api.event(2, 'plain'));
      final gate = api.gate = Completer<void>();
      final run = runner.run(permit());
      await api.reached.future.timeout(const Duration(seconds: 5));
      // The person opens the app while the wake pass waits on the network:
      // the wake is cancelled and the foreground asks the same owner to sync.
      state.handleAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(await run.timeout(const Duration(seconds: 5)),
          isNot(WakeOutcome.committed));
      await _until(() async => await store.loadSyncCursor() == 2);
      expect(crypto.unboundedCalls, 2,
          reason: 'the foreground pass, not the cancelled wake, decrypted');
      expect(bridge.presented, isEmpty);
    });

    test('a foreground UI refuses a background run', () async {
      state.handleAppLifecycleState(AppLifecycleState.resumed);
      expect(await runner.run(permit()), WakeOutcome.unavailable);
    });

    test('sign-out revokes native work before private state is cleared',
        () async {
      api.events.add(api.event(1, 'plain'));
      api.muteFails = true;
      expect(await runner.run(permit()), WakeOutcome.retry);
      var revokedWithState = -1;
      state.beforeLocalSessionClear = () async {
        revokedWithState = (await store.pendingNoticeReferences(_owner)).length;
      };
      await state.logout();
      expect(revokedWithState, 1);
      expect(crypto.noticeCaptureEnabled, isFalse);
    });
  });
}

class _Shell extends NoopDesktopShell {
  @override
  Future<bool> isWindowActive() async => false;
}

class _Notifier implements DesktopNotifier {
  final List<String> shown = [];
  @override
  Future<void> show({required String title, required String body}) async =>
      shown.add(body);
}

Future<void> _until(Future<bool> Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not reached');
}

class _FakeBridge extends PlatformWakeWorkerBridge {
  bool active = true;
  final List<String> presented = [];
  @override
  Future<WakePermitStatus> validatePermit(WakePermit permit) async =>
      WakePermitStatus(active, active ? 20000 : 0);
  @override
  Future<WakeNoticeResult> presentGenericNotice(
      WakePermit permit, String noticeId) async {
    presented.add(noticeId);
    return WakeNoticeResult.shown;
  }
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: _origin);
  final List<SyncEvent> events = [];
  final List<String> writes = [];
  bool muted = false;
  bool muteFails = false;
  int closed = 0;

  /// When set, the next sync page waits here (after [reached] completes).
  Completer<void>? gate;
  Completer<void> reached = Completer<void>();

  SyncEvent event(int id, String key, {String? mention}) => SyncEvent(
          id: id,
          type: 'message.envelope.created',
          createdAt: DateTime.now().toUtc(),
          conversationId: 'conv',
          payload: {
            'message_id': 'srv-$key',
            'envelope': ReceivedMessageEnvelope(
                    id: 'srv-$key',
                    conversationId: 'conv',
                    senderAccountId: 'bob',
                    senderDeviceId: 'dev_bob',
                    idempotencyKey: key,
                    ciphertext: utf8.encode(jsonEncode({'mention': mention})),
                    cryptoProtocol: 'test',
                    createdAt: DateTime.now().toUtc())
                .toJson()
          });

  @override
  void close() => closed++;
  @override
  Future<List<SyncEvent>> syncEvents(String token,
      {int after = 0, int limit = 100}) async {
    final wait = gate;
    if (wait != null) {
      gate = null;
      if (!reached.isCompleted) reached.complete();
      await wait.future;
    }
    return events.where((e) => e.id > after).take(limit).toList();
  }

  @override
  Future<ConversationMute> conversationMute(
      String token, String conversationId) async {
    if (muteFails) throw const SocketException('offline');
    return ConversationMute(muted: muted);
  }

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async => const [];
  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      [
        ConversationMember(accountId: 'alice', role: 'member'),
        ConversationMember(accountId: 'bob', role: 'owner'),
      ];
  @override
  Future<void> logout(String token) async => writes.add('logout');
  @override
  dynamic noSuchMethod(Invocation invocation) {
    writes.add('${invocation.memberName}');
    throw const SocketException('not available in this test');
  }
}

class _FakeCrypto
    implements
        BoundedMlsConversationCryptoService,
        NoticeCaptureConsumer,
        ConversationAuthorityConsumer {
  _FakeCrypto(this.store);
  final MemoryLocalStore store;
  int boundedCalls = 0, unboundedCalls = 0;
  @override
  bool noticeCaptureEnabled = false;
  @override
  set conversationAuthority(ConversationAuthority authority) {}

  @override
  Future<void> activateExistingSessionBounded(Session session,
      {required void Function() checkCanCommit}) async {
    checkCanCommit();
  }

  @override
  Future<List<int>?> processApplicationMessageBounded(
      ReceivedMessageEnvelope envelope, int syncEventId,
      {required void Function() checkCanCommit}) async {
    boundedCalls++;
    checkCanCommit();
    final mention = (jsonDecode(utf8.decode(envelope.ciphertext))
        as Map)['mention'] as String?;
    await _receive(store, envelope.idempotencyKey,
        format: mention == null ? null : _mention(mention),
        createdAt: envelope.createdAt.millisecondsSinceEpoch,
        capture: noticeCaptureEnabled,
        fence: checkCanCommit);
    return utf8.encode('@alice hello');
  }

  @override
  Future<List<int>?> processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId) async {
    unboundedCalls++;
    final mention = (jsonDecode(utf8.decode(envelope.ciphertext))
        as Map)['mention'] as String?;
    await _receive(store, envelope.idempotencyKey,
        format: mention == null ? null : _mention(mention),
        createdAt: envelope.createdAt.millisecondsSinceEpoch,
        capture: noticeCaptureEnabled);
    return utf8.encode('@alice hello');
  }

  @override
  Future<void> activateSession(Session session) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _CountingPush extends DisabledMobilePushService {
  final List<int> acknowledged = [];
  int registered = 0;
  @override
  Future<bool> acknowledgeWake(int generation) async {
    acknowledged.add(generation);
    return true;
  }

  @override
  Future<void> register(
      {required String instance,
      String vapid = '',
      List<String> providers = const <String>[]}) async {
    registered++;
  }
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
