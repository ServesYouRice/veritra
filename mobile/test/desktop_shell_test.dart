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

  @override
  Future<bool> isWindowActive() async => active;
}

class _FakeNotifier implements DesktopNotifier {
  final List<({String title, String body})> shown =
      <({String title, String body})>[];

  @override
  Future<void> show({required String title, required String body}) async {
    shown.add((title: title, body: body));
  }
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

  @override
  ConversationHistory historyFor(String conversationId) =>
      histories[conversationId] ?? ConversationHistory.empty(conversationId);

  @override
  Future<bool> loadConversationMuted(String conversationId) async {
    muteReads++;
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
    createdAt: 1,
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

  setUp(() {
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
      _local('old'),
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
    history(
        <LocalMessage>[_local('a', body: 'first'), _local('b', body: 'last')]);
    await messages.handle(<ReceivedMessageEnvelope>[
      _envelope('a', createdAt: _now.subtract(const Duration(seconds: 5))),
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
