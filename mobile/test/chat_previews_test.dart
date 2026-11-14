// U12: the last message on a chat row. It comes from this device's local store
// only, never from a request, and a Settings switch hides it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_preview.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind, LocalMessageState;
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// A store whose history is whatever the test says, and which records every
/// conversation whose history was read.
class _Store extends MemoryLocalStore {
  final Map<String, List<LocalMessage>> rows = <String, List<LocalMessage>>{};
  final List<String> reads = <String>[];

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async {
    reads.add(conversationId);
    return rows[conversationId] ?? const <LocalMessage>[];
  }
}

class _Api extends ApiClient {
  _Api(this.list) : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list;

  @override
  Future<List<Conversation>> conversations(String token) async => list;
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

LocalMessage _row(
  String conversationId, {
  String key = 'dev:m1',
  String sender = 'acct_pal',
  String kind = LocalMessageKind.text,
  String? body = 'see you at eight',
  int createdAt = 1000,
  int? deletedAt,
  int? expiresAt,
  int? hiddenAt,
  String? formatJson,
}) =>
    LocalMessage(
      key: key,
      conversationId: conversationId,
      senderAccountId: sender,
      senderDeviceId: 'dev',
      kind: kind,
      body: body,
      createdAt: createdAt,
      deletedAt: deletedAt,
      expiresAt: expiresAt,
      hiddenAt: hiddenAt,
      formatJson: formatJson,
      state: LocalMessageState.received,
    );

Conversation _dm(String id, String peer, {String? createdBy}) => Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      peerUsername: peer.replaceFirst('acct_', ''),
      createdBy: createdBy ?? 'acct_me',
      createdAt: DateTime.utc(2026, 6, 1),
      lastMessageAt: DateTime.utc(2026, 6, 2),
    );

Conversation _group(String id, String title) => Conversation(
      id: id,
      kind: 'group',
      title: title,
      createdBy: 'acct_me',
      createdAt: DateTime.utc(2026, 6, 1),
      lastMessageAt: DateTime.utc(2026, 6, 2),
    );

Future<AppState> _state(
  WidgetTester tester,
  _Store store,
  List<Conversation> list,
) async {
  final api = _Api(list);
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: store,
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  await tester.runAsync(state.refreshConversations);
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  group('the preview line', () {
    late AppState state;

    setUp(() {
      state = AppState(
        apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost:8080'),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _NoSync(),
      )..session = const Session(
          baseUrl: 'https://localhost:8080',
          token: 'token',
          accountId: 'acct_me',
          deviceId: 'dev_me',
        );
    });
    tearDown(() => state.dispose());

    String? line(Conversation conversation, LocalMessage? row) =>
        chatPreviewLine(englishL10n, state, conversation, row);

    test('a chat of two quotes the other person without a name', () {
      expect(line(_dm('c', 'acct_pal'), _row('c')), 'see you at eight');
    });

    test('your own message starts with You', () {
      expect(
        line(_dm('c', 'acct_pal'), _row('c', sender: 'acct_me')),
        'You: see you at eight',
      );
    });

    test('a group names the sender, from the local row', () {
      state.membersByConversation = <String, List<ConversationMember>>{
        'g': <ConversationMember>[
          ConversationMember(
              accountId: 'acct_pal', username: 'pal', role: 'member'),
        ],
      };
      expect(
        line(_group('g', 'Family'), _row('g')),
        '@pal: see you at eight',
      );
      // Without a member record the short account ID stands in.
      expect(
        line(_group('g', 'Family'), _row('g', sender: 'acct_zed1234567890')),
        startsWith('acct_'),
      );
    });

    test('whitespace collapses, direction overrides go, long text is cut', () {
      expect(
        line(_dm('c', 'acct_pal'),
            _row('c', body: 'a\n\n b\u202e\u2066c\t d  ')),
        'a bc d',
      );
      final long = line(_dm('c', 'acct_pal'), _row('c', body: 'x' * 500))!;
      expect(long.length, 100);
    });

    test('attachments, voice notes and polls get a placeholder', () {
      String attachment(String type, String name) => jsonEncode(<Object?>[
            <String, Object?>{
              'id': 'att_1',
              'file_name': name,
              'media_type': type,
              'plaintext_size': 10,
              'ciphertext_size': 40,
              'conversation_id': 'c',
            },
          ]);
      final dm = _dm('c', 'acct_pal');
      expect(
        line(
            dm,
            _row('c',
                kind: LocalMessageKind.attachment,
                body: attachment('application/pdf', 'invoice.pdf'))),
        'Attachment',
      );
      expect(
        line(
            dm,
            _row('c',
                kind: LocalMessageKind.attachment,
                body: attachment('image/png', 'me.png'))),
        'Photo',
      );
      expect(
        line(
            dm,
            _row('c',
                kind: LocalMessageKind.attachment,
                body: attachment('audio/mp4', 'note.m4a'))),
        'Voice note',
      );
      expect(
        line(
            dm, _row('c', kind: LocalMessageKind.poll, body: '{"q":"Pizza?"}')),
        'Poll',
      );
      // Never the file name or the question.
      expect(
        line(
            dm,
            _row('c',
                kind: LocalMessageKind.attachment,
                body: attachment('application/pdf', 'invoice.pdf'))),
        isNot(contains('invoice')),
      );
    });

    test('a spoiler is hidden', () {
      expect(
        line(_dm('c', 'acct_pal'),
            _row('c', formatJson: '{"spoilers":[{"offset":0,"length":3}]}')),
        englishL10n.w8HiddenSpoiler,
      );
    });

    test('nothing quotes what the chat would not show as text', () {
      final dm = _dm('c', 'acct_pal');
      expect(line(dm, null), isNull);
      expect(line(dm, _row('c', deletedAt: 5)), isNull);
      expect(line(dm, _row('c', kind: LocalMessageKind.unverifiable)), isNull);
      expect(line(dm, _row('c', kind: LocalMessageKind.invalid)), isNull);
      expect(
          line(dm, _row('c', kind: LocalMessageKind.unsupported, body: '{}')),
          isNull);
      expect(line(dm, _row('c', body: null)), isNull);
    });

    test('a request is never quoted, even with its history in memory', () {
      // A stranger's DM: created by them, so it is a request until accepted.
      final request = _dm('r', 'acct_stranger', createdBy: 'acct_stranger');
      state.conversations = <Conversation>[request];
      expect(state.requestBucket(request), RequestBucket.request);
      expect(line(request, _row('r', sender: 'acct_stranger')), isNull);
    });

    test('a blocked sender is never quoted', () {
      state.blockedAccounts = <BlockedAccount>[
        BlockedAccount(accountId: 'acct_pal'),
      ];
      expect(line(_dm('c', 'acct_pal'), _row('c')), isNull);
    });
  });

  testWidgets('a cold start shows the last message from the local store',
      (tester) async {
    final store = _Store()
      ..rows['c'] = <LocalMessage>[
        _row('c', key: 'dev:old', body: 'older', createdAt: 100),
        _row('c', key: 'dev:new', body: 'see you at eight', createdAt: 200),
        // An edit or reaction envelope is not a message.
        _row('c',
            key: 'dev:act',
            kind: LocalMessageKind.action,
            body: '{}',
            createdAt: 300),
      ];
    final state = await _state(tester, store, <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();

    expect(find.text('see you at eight'), findsOneWidget);
    expect(find.text('older'), findsNothing);
    // The kind line is gone from a row that has a preview.
    expect(find.text(englishL10n.conversationEncrypted), findsNothing);
  });

  testWidgets('a row without a message keeps its kind line', (tester) async {
    final state = await _state(tester, _Store(), <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();
    expect(find.text(englishL10n.conversationEncrypted), findsOneWidget);
  });

  testWidgets('a message that arrives updates the row it belongs to',
      (tester) async {
    final store = _Store()
      ..rows['c'] = <LocalMessage>[_row('c', body: 'first')];
    final state = await _state(tester, store, <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();
    expect(find.text('first'), findsOneWidget);

    store.rows['c'] = <LocalMessage>[
      _row('c', body: 'first'),
      _row('c', key: 'dev:m2', body: 'second', createdAt: 2000),
    ];
    await tester.runAsync(() => state.refreshHistory('c'));
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });

  testWidgets('a message that expires leaves the row', (tester) async {
    final soon = DateTime.now().millisecondsSinceEpoch + 300;
    final store = _Store()
      ..rows['c'] = <LocalMessage>[
        _row('c', key: 'dev:m1', body: 'self-destructing', expiresAt: soon),
      ];
    final state = await _state(tester, store, <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();
    expect(find.text('self-destructing'), findsOneWidget);

    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    // Any change notifies; the purge that would normally follow can lag.
    await tester.runAsync(() => state.setMentionsInMutedChats(true));
    await tester.pump();
    expect(find.text('self-destructing'), findsNothing);
    expect(find.text(englishL10n.conversationEncrypted), findsOneWidget);
  });

  testWidgets('the switch hides every preview and is remembered',
      (tester) async {
    final store = _Store()..rows['c'] = <LocalMessage>[_row('c')];
    final state = await _state(tester, store, <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();
    expect(find.text('see you at eight'), findsOneWidget);

    await tester.runAsync(() => state.setShowChatPreviews(false));
    await tester.pump();
    expect(find.text('see you at eight'), findsNothing);
    expect(find.text(englishL10n.conversationEncrypted), findsOneWidget);
    expect(await store.loadSetting('u12.chat_previews'), 'false');

    await tester.runAsync(() => state.setShowChatPreviews(true));
    await tester.pump();
    expect(find.text('see you at eight'), findsOneWidget);
  });

  testWidgets('no history is read for a request or a chat with no message',
      (tester) async {
    final store = _Store()
      ..rows['req'] = <LocalMessage>[
        _row('req', sender: 'acct_stranger', body: 'buy my coin'),
      ]
      ..rows['mine'] = <LocalMessage>[_row('mine')];
    final state = await _state(tester, store, <Conversation>[
      _dm('mine', 'acct_pal'),
      _dm('req', 'acct_stranger', createdBy: 'acct_stranger'),
      Conversation(
        id: 'empty',
        kind: 'group',
        title: 'Nobody yet',
        createdBy: 'acct_me',
        createdAt: DateTime.utc(2026, 6, 1),
      ),
    ]);
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();

    expect(store.reads, <String>['mine']);
    expect(find.text('buy my coin'), findsNothing);
    // The stranger stays behind one row, and no preview is built for it.
    expect(find.byKey(const Key('requests-row')), findsOneWidget);
    expect(state.chatPreviewFor('req'), isNull);
  });

  testWidgets('with the switch off nothing is read at all', (tester) async {
    final store = _Store()..rows['c'] = <LocalMessage>[_row('c')];
    final state = await _state(tester, store, <Conversation>[
      _dm('c', 'acct_pal'),
    ]);
    await tester.runAsync(() => state.setShowChatPreviews(false));
    await tester.pumpWidget(_app(ChatListScreen(state: state)));
    await tester.pump();
    await tester.pump();
    expect(store.reads, isEmpty);
  });

  testWidgets('Settings has the switch, on by default', (tester) async {
    final store = _Store();
    final state = await _state(tester, store, <Conversation>[]);
    state.devicesLoaded = true;
    await tester.pumpWidget(_app(Scaffold(body: SettingsScreen(state: state))));
    await tester.pump();

    const key = ValueKey<String>('settings-chat-previews');
    await tester.scrollUntilVisible(find.byKey(key), 300);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isTrue);
    expect(find.text(englishL10n.chatPreviewsSetting), findsOneWidget);

    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(state.showChatPreviews, isFalse);
    expect(await store.loadSetting('u12.chat_previews'), 'false');
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isFalse);
  });
}
