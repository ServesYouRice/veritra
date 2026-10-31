import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/message_history.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/desktop/desktop_shell.dart';
import 'package:private_messenger/desktop/message_notifications.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _FakeShell extends NoopDesktopShell {
  bool active = false;

  /// When set, the window check waits for it.
  Completer<void>? gate;

  @override
  Future<bool> isWindowActive() async {
    await gate?.future;
    return active;
  }
}

class _FakeNotifier implements DesktopNotifier {
  final List<({String title, String body})> shown =
      <({String title, String body})>[];

  /// When set, showing waits for it first, like the real notifier's setup.
  Completer<void>? setupGate;

  @override
  Future<void> show({
    required String title,
    required String body,
    bool Function()? stillWanted,
  }) async {
    await setupGate?.future;
    if (stillWanted != null && !stillWanted()) return;
    shown.add((title: title, body: body));
  }
}

/// A store whose read finishes only when the test releases it.
class _HeldStore implements NotificationSettingsStore {
  _HeldStore(this.saved);

  final bool? saved;
  final Completer<void> release = Completer<void>();

  @override
  Future<bool?> loadHidePreview() async {
    await release.future;
    return saved;
  }

  @override
  Future<void> saveHidePreview(bool value) async {}
}

/// A store whose read fails, like a locked or broken keychain.
class _UnreadableStore implements NotificationSettingsStore {
  @override
  Future<bool?> loadHidePreview() async => throw StateError('keychain');

  @override
  Future<void> saveHidePreview(bool value) async {}
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

class _State extends AppState {
  _State()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final Map<String, ConversationHistory> histories =
      <String, ConversationHistory>{};
  final Set<String> mutedOnServer = <String>{};
  bool muteReadable = true;
  int muteReads = 0;

  /// When set, the mute lookup waits for it.
  Completer<void>? muteGate;

  @override
  ConversationHistory historyFor(String conversationId) =>
      histories[conversationId] ?? ConversationHistory.empty(conversationId);

  @override
  Future<bool> loadConversationMuted(String conversationId) async {
    muteReads++;
    await muteGate?.future;
    return muteReadable;
  }

  @override
  bool isMuted(String conversationId) => mutedOnServer.contains(conversationId);
}

final _now = DateTime.utc(2026, 10, 24, 12);

ReceivedMessageEnvelope _envelope(
  String id, {
  String conversation = 'conv_1',
  String account = 'acct_other',
  String device = 'dev_other',
  DateTime? createdAt,
  DateTime? deletedAt,
}) {
  return ReceivedMessageEnvelope(
    id: id,
    conversationId: conversation,
    senderAccountId: account,
    senderDeviceId: device,
    idempotencyKey: 'key_$id',
    ciphertext: const <int>[1],
    cryptoProtocol: 'mls',
    createdAt: createdAt ?? _now,
    deletedAt: deletedAt,
  );
}

LocalMessage _local(
  String id, {
  String conversation = 'conv_1',
  String account = 'acct_other',
  String device = 'dev_other',
  String kind = LocalMessageKind.text,
  String body = 'secret words',
  String? formatJson,
  int? hiddenAt,
  DateTime? createdAt,
}) {
  return LocalMessage(
    key: 'dev_other:key_$id'.replaceFirst('dev_other', device),
    conversationId: conversation,
    senderAccountId: account,
    senderDeviceId: device,
    kind: kind,
    body: body,
    formatJson: formatJson,
    hiddenAt: hiddenAt,
    // The notice policy compares the row's time with the envelope's.
    createdAt: (createdAt ?? _now).millisecondsSinceEpoch,
    state: LocalMessageState.received,
  );
}

void main() {
  late _State state;
  late _FakeShell shell;
  late _FakeNotifier notifier;
  late NotificationSettings settings;
  late MessageNotifier messages;

  void history(List<LocalMessage> items, {String conversation = 'conv_1'}) {
    state.histories[conversation] = ConversationHistory(
      conversationId: conversation,
      messages: items,
      reactions: const <LocalMessageReaction>[],
    );
  }

  setUp(() async {
    state = _State()
      ..session = const Session(
        baseUrl: 'https://localhost',
        token: 't',
        accountId: 'acct_me',
        deviceId: 'dev_me',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', title: 'Family'),
      ];
    shell = _FakeShell();
    notifier = _FakeNotifier();
    settings = NotificationSettings(MemoryNotificationSettingsStore());
    // Previews wait for the saved choice to be known.
    await settings.load();
    messages = MessageNotifier(
      state: state,
      shell: shell,
      notifier: notifier,
      settings: settings,
      l10n: () => englishL10n,
      now: () => _now,
    );
  });

  test('a message while the window is in the background raises a notification',
      () async {
    history(<LocalMessage>[_local('m1')]);
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, 'Family');
    expect(notifier.shown.single.body, 'secret words');
  });

  test('a message request stays silent until it is accepted', () async {
    state.conversations = <Conversation>[
      Conversation(
        id: 'conv_1',
        kind: 'group',
        title: 'Family',
        createdBy: 'acct_stranger',
      ),
    ];
    history(<LocalMessage>[_local('m1')]);
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    expect(notifier.shown, isEmpty);
  });

  test('nothing is shown while the window is in front', () async {
    shell.active = true;
    history(<LocalMessage>[_local('m1')]);
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    expect(notifier.shown, isEmpty);
  });

  test('a muted chat stays quiet, and so does one whose mute is unreadable',
      () async {
    history(<LocalMessage>[_local('m1')]);
    state.mutedOnServer.add('conv_1');
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    expect(notifier.shown, isEmpty);

    state.mutedOnServer.clear();
    state.muteReadable = false;
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m2')]);
    expect(notifier.shown, isEmpty);
  });

  test('hide preview makes the text generic', () async {
    await settings.setHidePreview(true);
    history(<LocalMessage>[_local('m1')]);
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    expect(notifier.shown.single.title, 'Veritra');
    expect(notifier.shown.single.body, 'New message');
  });

  group('previews wait for the saved choice', () {
    MessageNotifier notifierFor(NotificationSettings choice) => MessageNotifier(
          state: state,
          shell: shell,
          notifier: notifier,
          settings: choice,
          l10n: () => englishL10n,
          now: () => _now,
        );

    void expectGeneric() {
      expect(notifier.shown, hasLength(1));
      expect(notifier.shown.single.title, 'Veritra');
      expect(notifier.shown.single.body, 'New message');
    }

    test('a saved "hide" is honoured before the load finishes', () async {
      final store = _HeldStore(true);
      final pending = NotificationSettings(store);
      final loading = pending.load();
      history(<LocalMessage>[_local('m1')]);
      await notifierFor(pending)
          .handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      expectGeneric();
      expect(notifier.shown.single.body, isNot(contains('secret')));
      store.release.complete();
      await loading;
    });

    test('an unreadable store hides previews for the run', () async {
      final unreadable = NotificationSettings(_UnreadableStore());
      await unreadable.load();
      history(<LocalMessage>[_local('m1'), _local('m2')]);
      final notifier2 = notifierFor(unreadable);
      await notifier2.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      await unreadable.load();
      await notifier2.handle(<ReceivedMessageEnvelope>[_envelope('m2')]);
      expect(notifier.shown, hasLength(2));
      for (final item in notifier.shown) {
        expect(item.title, 'Veritra');
        expect(item.body, 'New message');
      }
    });

    test('a store that holds no choice shows previews after loading', () async {
      final empty = NotificationSettings(MemoryNotificationSettingsStore());
      await empty.load();
      history(<LocalMessage>[_local('m1')]);
      await notifierFor(empty)
          .handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      expect(notifier.shown.single.body, 'secret words');
    });

    test('a choice made before the load finishes wins', () async {
      final store = _HeldStore(true);
      final pending = NotificationSettings(store);
      final loading = pending.load();
      await pending.setHidePreview(false);
      store.release.complete();
      await loading;
      expect(pending.hidePreview, isFalse);
      history(<LocalMessage>[_local('m1')]);
      await notifierFor(pending)
          .handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      expect(notifier.shown.single.body, 'secret words');
    });

    test('an explicit "show" is honoured even when the store is unreadable',
        () async {
      final unreadable = NotificationSettings(_UnreadableStore());
      await unreadable.load();
      await unreadable.setHidePreview(false);
      history(<LocalMessage>[_local('m1')]);
      await notifierFor(unreadable)
          .handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      expect(notifier.shown.single.body, 'secret words');
    });

    test('a saved "hide" still applies after the load', () async {
      final saved = NotificationSettings(MemoryNotificationSettingsStore(true));
      await saved.load();
      history(<LocalMessage>[_local('m1')]);
      await notifierFor(saved)
          .handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
      expectGeneric();
    });
  });

  group('work in flight is dropped when the session ends', () {
    const other = Session(
      baseUrl: 'https://localhost',
      token: 't2',
      accountId: 'acct_other_me',
      deviceId: 'dev_me',
    );

    /// Starts handling one message and returns the pending call.
    Future<void> start() {
      history(<LocalMessage>[_local('m1')]);
      return messages.handle(<ReceivedMessageEnvelope>[_envelope('m1')]);
    }

    // Each wait in handle: the window check, the mute lookup and the
    // notifier's own setup.
    final waits = <String, void Function(Completer<void>)>{
      'the window check': (gate) => shell.gate = gate,
      'the mute lookup': (gate) => state.muteGate = gate,
      'the notifier setup': (gate) => notifier.setupGate = gate,
    };
    for (final wait in waits.entries) {
      test('sign-out during ${wait.key} shows nothing', () async {
        final gate = Completer<void>();
        wait.value(gate);
        final pending = start();
        await Future<void>.delayed(Duration.zero);
        state.session = null;
        gate.complete();
        await pending;
        expect(notifier.shown, isEmpty);
      });

      test('a sign-out that has started during ${wait.key} shows nothing',
          () async {
        // The session stays set for several awaits while sign-out runs.
        final entered = Completer<void>();
        final release = Completer<void>();
        state.beforeLocalSessionClear = () async {
          entered.complete();
          await release.future;
        };
        final gate = Completer<void>();
        wait.value(gate);
        final pending = start();
        await Future<void>.delayed(Duration.zero);
        final signOut = state.logout();
        await entered.future;
        expect(state.session, isNotNull);
        gate.complete();
        await pending;
        expect(notifier.shown, isEmpty);
        release.complete();
        await signOut;
      });

      test('an account switch during ${wait.key} shows nothing', () async {
        final gate = Completer<void>();
        wait.value(gate);
        final pending = start();
        await Future<void>.delayed(Duration.zero);
        state.session = other;
        gate.complete();
        await pending;
        expect(notifier.shown, isEmpty);
      });

      test('detach during ${wait.key} shows nothing', () async {
        final gate = Completer<void>();
        wait.value(gate);
        messages.attach();
        final pending = start();
        await Future<void>.delayed(Duration.zero);
        messages.detach();
        gate.complete();
        await pending;
        expect(notifier.shown, isEmpty);
      });

      test('a token refresh during ${wait.key} does not drop it', () async {
        final gate = Completer<void>();
        wait.value(gate);
        final pending = start();
        await Future<void>.delayed(Duration.zero);
        state.session = const Session(
          baseUrl: 'https://localhost',
          token: 'rotated',
          accountId: 'acct_me',
          deviceId: 'dev_me',
        );
        gate.complete();
        await pending;
        expect(notifier.shown, hasLength(1));
      });
    }

    test('a message handled while a sign-out runs shows nothing', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      state.beforeLocalSessionClear = () async {
        entered.complete();
        await release.future;
      };
      final signOut = state.logout();
      await entered.future;
      expect(state.session, isNotNull);
      await start();
      expect(notifier.shown, isEmpty);
      release.complete();
      await signOut;
    });

    test('a notification after re-attaching is shown', () async {
      messages.attach();
      messages.detach();
      messages.attach();
      await start();
      expect(notifier.shown, hasLength(1));
    });
  });

  test('a kept mention alerts in a muted chat, and its switch turns that off',
      () async {
    state.mutedOnServer.add('conv_1');
    final format = jsonEncode({
      'mentions': [
        {'account_id': 'acct_me', 'offset': 0, 'length': 3}
      ]
    });
    history([_local('mention', body: '@me hello', formatJson: format)]);
    await messages.handle([_envelope('mention')]);
    expect(notifier.shown.single.body, '@me hello');
    state.mentionsInMutedChats = false;
    history([_local('disabled', body: '@me hello', formatJson: format)]);
    await messages.handle([_envelope('disabled')]);
    expect(notifier.shown, hasLength(1));
    state.mentionsInMutedChats = true;
    history([
      _local('hidden', body: '@me hello', formatJson: format, hiddenAt: 1),
      _local('edit',
          body: '@me hello', kind: LocalMessageKind.action, formatJson: format)
    ]);
    await messages.handle([_envelope('hidden'), _envelope('edit')]);
    expect(notifier.shown, hasLength(1));
  });

  test('notification previews conceal spoiler text', () async {
    history([
      _local('spoiler',
          body: 'secret words',
          formatJson: jsonEncode({
            'entities': [
              {'type': 'spoiler', 'offset': 0, 'length': 6}
            ]
          }))
    ]);
    await messages.handle([_envelope('spoiler')]);
    expect(notifier.shown.single.body, englishL10n.w8HiddenSpoiler);
    expect(notifier.shown.single.body, isNot(contains('secret words')));
  });

  test('own, edited-away, action, stale and repeated messages are skipped',
      () async {
    history(<LocalMessage>[
      _local('own', account: 'acct_me', device: 'dev_me'),
      _local('act', kind: LocalMessageKind.action),
      _local('old', createdAt: _now.subtract(const Duration(hours: 1))),
      _local('gone'),
      _local('ok'),
    ]);
    await messages.handle(<ReceivedMessageEnvelope>[
      _envelope('own', account: 'acct_me', device: 'dev_me'),
      _envelope('act'),
      _envelope('old', createdAt: _now.subtract(const Duration(hours: 1))),
      _envelope('gone', deletedAt: _now),
    ]);
    expect(notifier.shown, isEmpty);
    expect(state.muteReads, 0);

    await messages.handle(<ReceivedMessageEnvelope>[_envelope('ok')]);
    await messages.handle(<ReceivedMessageEnvelope>[_envelope('ok')]);
    expect(notifier.shown, hasLength(1));
  });

  test('a burst in one chat gives one notification with the newest text',
      () async {
    final earlier = _now.subtract(const Duration(seconds: 5));
    history(<LocalMessage>[
      _local('a', body: 'first', createdAt: earlier),
      _local('b', body: 'last'),
    ]);
    await messages.handle(<ReceivedMessageEnvelope>[
      _envelope('a', createdAt: earlier),
      _envelope('b'),
    ]);
    expect(notifier.shown.single.body, 'last');
  });

  test('state forwards published messages to the listener', () async {
    messages.attach();
    expect(state.onMessagesPublished, isNotNull);
    messages.detach();
    expect(state.onMessagesPublished, isNull);
  });

  testWidgets('settings screen offers the hide preview switch on desktop',
      (tester) async {
    await tester.pumpWidget(NotificationSettingsScope(
      settings: settings,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(state: state),
      ),
    ));
    final tile = find.text('Hide message preview');
    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pump();
    expect(settings.hidePreview, isTrue);
  });

  test('the notification setting is kept in its store', () async {
    final store = MemoryNotificationSettingsStore(true);
    final loaded = NotificationSettings(store);
    await loaded.load();
    expect(loaded.hidePreview, isTrue);
    await loaded.setHidePreview(false);
    expect(store.hidePreview, isFalse);
  });
}
