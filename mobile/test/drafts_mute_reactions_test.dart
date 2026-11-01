import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/composer_drafts.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/reaction_emoji.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/features/chat/emoji_data.dart';
import 'package:private_messenger/features/chat/emoji_picker.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// W6: reactions with any emoji, mute for 8 hours / 1 week / always, and
/// drafts that survive a restart in the encrypted local database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reaction emoji', () {
    test('any single emoji grapheme reacts, however many code points', () {
      for (final emoji in <String>[
        '\u{1F44D}', // thumbs up
        '❤️', // heart with presentation selector
        '\u{1F44D}\u{1F3FD}', // skin tone
        '\u{1F1E9}\u{1F1EA}', // flag
        '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}', // family
        '\u{1F3F3}️‍\u{1F308}', // rainbow flag
        '1️⃣', // keycap
        '✅',
        '\u{1FAE0}', // newer than most keyboards
      ]) {
        expect(asSingleEmoji(emoji), emoji, reason: emoji.runes.toString());
        // The payload accepts it unchanged: the wire format is untouched.
        expect(emoji.length <= maxReactionLength, isTrue);
      }
      expect(asSingleEmoji('  \u{1F600}  '), '\u{1F600}');
    });

    test('text, several emoji and nothing do not', () {
      for (final input in <String>[
        '',
        '  ',
        'a',
        '1',
        '#',
        'ab',
        '\u{1F600}\u{1F600}',
        '\u{1F600}a',
        '中',
        'x' * 40,
      ]) {
        expect(asSingleEmoji(input), isNull, reason: input);
      }
    });

    test('the payload still takes a long ZWJ sequence', () {
      const family = '\u{1F468}\u{1F3FD}‍\u{1F469}\u{1F3FD}‍'
          '\u{1F467}\u{1F3FD}‍\u{1F466}\u{1F3FD}';
      expect(family.length <= maxReactionLength, isTrue);
      final codec = AppPayloadCodec();
      final encoded = codec.encode(
        type: AppPayloadType.reaction,
        body: <String, Object?>{'message_id': 'dev:1', 'reaction': family},
        conversationId: 'conv_1',
        senderDeviceId: 'dev_1',
        actionId: 'act_1',
      );
      final decoded = codec.decode(
        encoded,
        conversationId: 'conv_1',
        senderDeviceId: 'dev_1',
        actionId: 'act_1',
      );
      expect(decoded.body['reaction'], family);
    });

    test('the catalog is grouped, complete enough and free of duplicates', () {
      expect(emojiCatalog.keys, EmojiGroup.values);
      var total = 0;
      final seen = <String>{};
      for (final entries in emojiCatalog.values) {
        expect(entries, isNotEmpty);
        for (final entry in entries) {
          total++;
          expect(seen.add(entry.emoji), isTrue,
              reason: 'duplicate ${entry.name}');
          expect(entry.name, isNotEmpty);
          expect(asSingleEmoji(entry.emoji), entry.emoji, reason: entry.name);
        }
      }
      expect(total, greaterThan(1500));
      expect(
          emojiCatalog[EmojiGroup.flags]!
              .any((entry) => entry.name == 'flag: germany'),
          isTrue);
    });

    test('search finds emoji by every word of the name', () {
      List<String> names(String query) =>
          searchEmoji(query).map((entry) => entry.name).toList();
      expect(names('thumbs up'), contains('thumbs up sign'));
      expect(names('flag germany'), <String>['flag: germany']);
      expect(names('zzzz'), isEmpty);
    });

    testWidgets(
        'the picker returns a tapped emoji, a searched one and a '
        'pasted one', (tester) async {
      String? result;
      Future<void> open() async {
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async =>
                      result = await showEmojiPicker(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      await open();
      // Grouped list: tapping the first smiley.
      await tester
          .tap(find.text(emojiCatalog[EmojiGroup.smileys]!.first.emoji));
      await tester.pumpAndSettle();
      expect(result, emojiCatalog[EmojiGroup.smileys]!.first.emoji);

      // Search by name.
      result = null;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'rocket');
      await tester.pumpAndSettle();
      await tester.tap(find.text('\u{1F680}'));
      await tester.pumpAndSettle();
      expect(result, '\u{1F680}');

      // Any emoji pasted or typed, even one not in the list.
      result = null;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '\u{1F9CC}');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use \u{1F9CC}'));
      await tester.pumpAndSettle();
      expect(result, '\u{1F9CC}');
    });
  });

  group('drafts in the encrypted database', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-drafts-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    SecureLocalStore createStore() => SecureLocalStore(
          storage: const FlutterSecureStorage(),
          directoryProvider: () async => directory,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );

    Future<void> reopen() async {
      for (final database in databases) {
        await database.close();
      }
      databases.clear();
    }

    test('a draft and its reply target survive a restart', () async {
      final store = createStore();
      await store.saveDraft('conv_1', 'half a thought', replyTo: 'dev:1');
      await store.saveDraft('conv_2', 'another');
      await store.saveDraft('conv_2', 'another, edited');
      await reopen();

      final drafts = await createStore().loadDrafts();
      expect(drafts.keys, unorderedEquals(<String>['conv_1', 'conv_2']));
      expect(drafts['conv_1']!.text, 'half a thought');
      expect(drafts['conv_1']!.replyTo, 'dev:1');
      expect(drafts['conv_2']!.text, 'another, edited');
      expect(drafts['conv_2']!.replyTo, isNull);

      final again = createStore();
      await again.deleteDraft('conv_1');
      expect((await again.loadDrafts()).keys, <String>['conv_2']);
    });

    test('sending the draft deletes it in the same transaction', () async {
      final store = createStore();
      await store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[1],
        ),
        0,
      );
      await store.saveDraft('conv_1', '  hello  ');
      await store.saveDraft('conv_2', 'unrelated');
      await store.commitOutgoingApplicationTransition(
        OutgoingApplicationStateTransition(
          expectedCounter: 1,
          expectedCursor: 0,
          state: StoredCryptoState(
            counter: 2,
            stateKey: List<int>.filled(32, 1),
            sealedState: <int>[2],
          ),
          envelope: MessageEnvelope(
            conversationId: 'conv_1',
            idempotencyKey: 'act_1',
            ciphertext: <int>[1, 2, 3],
            cryptoProtocol: 'mls10-openmls-v1',
          ),
          draftText: 'hello',
        ),
      );
      expect((await store.loadDrafts()).keys, <String>['conv_2']);

      // A draft edited since is a different draft and stays.
      await store.saveDraft('conv_1', 'hello again');
      await store.commitOutgoingApplicationTransition(
        OutgoingApplicationStateTransition(
          expectedCounter: 2,
          expectedCursor: 0,
          state: StoredCryptoState(
            counter: 3,
            stateKey: List<int>.filled(32, 1),
            sealedState: <int>[3],
          ),
          envelope: MessageEnvelope(
            conversationId: 'conv_1',
            idempotencyKey: 'act_2',
            ciphertext: <int>[1, 2, 3],
            cryptoProtocol: 'mls10-openmls-v1',
          ),
          draftText: 'something else',
        ),
      );
      expect((await store.loadDrafts())['conv_1']?.text, 'hello again');
    });

    test('drafts and mutes: a session expiry keeps drafts, sign-out wipes both',
        () async {
      final store = createStore();
      await store.saveDraft('conv_1', 'secret draft');
      await store.saveConversationMute('conv_1', muted: true);
      // Clearing the cache for a sign-out drops the drafts with it.
      await store.clearCachedState(preserveOutbox: true);
      expect(await store.loadDrafts(), isEmpty);
      expect(await store.loadConversationMutes(), isEmpty);

      await store.saveDraft('conv_1', 'secret draft');
      await store.saveConversationMute('conv_1', muted: true);
      expect(await store.loadConversationMutes(), hasLength(1));
      // A session that expired keeps the drafts for the next sign-in; the
      // mute copies are refetched from the server.
      await store.clearCachedState(preserveOutbox: true, keepDrafts: true);
      expect((await store.loadDrafts())['conv_1']?.text, 'secret draft');
      expect(await store.loadConversationMutes(), isEmpty);

      await store.saveDraft('conv_1', 'secret draft');
      await store.saveConversationMute('conv_1', muted: true);
      await store.clear();
      expect(await store.loadDrafts(), isEmpty);
      expect(await store.loadConversationMutes(), isEmpty);
      // Not just hidden: the text is not in the file's rows.
      final left = await databases.last
          .customSelect('SELECT count(*) AS n FROM local_drafts')
          .getSingle();
      expect(left.read<int>('n'), 0);
    });

    test('a mute is kept until it ends, then forgotten', () async {
      final store = createStore();
      final soon = DateTime.now().toUtc().add(const Duration(seconds: 1));
      await store.saveConversationMute('timed', muted: true, until: soon);
      await store.saveConversationMute('always', muted: true);
      await store.saveConversationMute('off', muted: true);
      await store.saveConversationMute('off', muted: false);
      var mutes = await store.loadConversationMutes();
      expect(mutes.keys, unorderedEquals(<String>['timed', 'always']));
      expect(mutes['always'], isNull);
      expect(
          mutes['timed']!.millisecondsSinceEpoch, soon.millisecondsSinceEpoch);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      mutes = await store.loadConversationMutes();
      expect(mutes.keys, <String>['always']);
    });
  });

  group('drafts through sign-out and session expiry', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-drafts-app-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final stores =
        <String, LocalStore Function(List<EncryptedLocalDatabase>, Directory)>{
      'memory store': (_, __) => MemoryLocalStore(),
      'encrypted store': (databases, directory) => SecureLocalStore(
            storage: const FlutterSecureStorage(),
            directoryProvider: () async => directory,
            databaseFactory: (file, keyHex) {
              final database = openEncryptedLocalDatabase(file, keyHex);
              databases.add(database);
              return database;
            },
          ),
    };

    for (final entry in stores.entries) {
      Future<(AppState, LocalStore, _MuteApi)> start() async {
        final store = entry.value(databases, directory);
        await store.saveSession(const Session(
          baseUrl: 'https://localhost:8080',
          token: 'token',
          accountId: 'acct_own',
          deviceId: 'dev_own',
          deviceSecret: 'secret',
        ));
        await store.saveDraft('conv_1', 'unsent words', replyTo: 'dev:3');
        final api = _MuteApi();
        final state = AppState(
          apiClientFactory: (_) => api,
          cryptoService: TestOnlyCryptoService(),
          localStore: store,
          syncServiceFactory: (_, __) => _IdleSync(),
        );
        await state.tryRestoreSession();
        expect(state.composerDrafts.textFor('conv_1'), 'unsent words');
        return (state, store, api);
      }

      test('${entry.key}: signing out deletes the drafts', () async {
        final (state, store, _) = await start();
        await state.logout();
        expect(await store.loadDrafts(), isEmpty);
        expect(state.composerDrafts.textFor('conv_1'), isEmpty);
        state.dispose();
      });

      test(
          '${entry.key}: an edit still waiting to be saved does not come '
          'back after sign-out', () async {
        final (state, store, _) = await start();
        state.composerDrafts.setText('conv_1', 'typed just before');
        await state.logout();
        // Longer than the save delay: a timer that survived would write now.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(await store.loadDrafts(), isEmpty);
        state.dispose();
      });

      test(
          '${entry.key}: an edit still waiting to be saved survives a '
          'rejected session', () async {
        final (state, store, api) = await start();
        state.composerDrafts.setText('conv_1', 'typed just before');
        api.rejectToken = true;
        await state.refreshConversations();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(state.session, isNull);
        expect((await store.loadDrafts())['conv_1']?.text, 'typed just before');
        state.dispose();
        // D65 (UQ-003): keepDrafts means the same person signs in again to
        // their drafts, so a pending edit is flushed before the data is
        // cleared, not dropped.
      });

      test(
          '${entry.key}: a rejected session keeps the drafts and the next '
          'sign-in puts them back in the composer', () async {
        final (state, store, api) = await start();
        api.rejectToken = true;
        await state.refreshConversations();
        await Future<void>.delayed(Duration.zero);
        expect(state.session, isNull);
        expect(state.composerDrafts.textFor('conv_1'), isEmpty);
        expect((await store.loadDrafts())['conv_1']?.text, 'unsent words');

        api.rejectToken = false;
        await state.login('https://localhost:8080', 'me', 'password');
        expect(state.session, isNotNull);
        expect(state.composerDrafts.textFor('conv_1'), 'unsent words');
        expect(state.composerDrafts.replyTargetFor('conv_1'), 'dev:3');
        // Typing continues from the restored text and is saved over it.
        state.composerDrafts.setText('conv_1', 'unsent words, more');
        state.flushDrafts();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
            (await store.loadDrafts())['conv_1']?.text, 'unsent words, more');
        state.dispose();
      });
    }
  });

  group('app state', () {
    late MemoryLocalStore store;
    late _MuteApi api;
    late AppState state;

    Future<void> start() async {
      store = MemoryLocalStore();
      await store.saveSession(const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_own',
        deviceId: 'dev_own',
      ));
      api = _MuteApi();
      state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) => _IdleSync(),
      );
    }

    tearDown(() => state.dispose());

    test('typing saves a draft after a pause, sending removes it', () async {
      await start();
      await state.tryRestoreSession();
      state.composerDrafts.setText('conv_1', 'hel');
      state.composerDrafts.setText('conv_1', 'hello');
      expect(await store.loadDrafts(), isEmpty, reason: 'debounced');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect((await store.loadDrafts())['conv_1']?.text, 'hello');

      state.composerDrafts.setReplyTarget('conv_1', 'dev:9');
      state.flushDrafts();
      await Future<void>.delayed(Duration.zero);
      expect((await store.loadDrafts())['conv_1']?.replyTo, 'dev:9');

      state.composerDrafts.clearSent('conv_1', text: 'hello', replyTo: 'dev:9');
      await Future<void>.delayed(Duration.zero);
      expect(await store.loadDrafts(), isEmpty);
    });

    test('a restart puts drafts back before any chat opens', () async {
      await start();
      await store.saveDraft('conv_1', 'left open', replyTo: 'dev:3');
      await state.tryRestoreSession();
      expect(state.composerDrafts.textFor('conv_1'), 'left open');
      expect(state.composerDrafts.replyTargetFor('conv_1'), 'dev:3');
    });

    test('the app pausing writes a pending draft at once', () async {
      await start();
      await state.tryRestoreSession();
      state.composerDrafts.setText('conv_1', 'unsaved');
      state.handleAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect((await store.loadDrafts())['conv_1']?.text, 'unsaved');
    });

    test('mute 8 hours, 1 week and always reach the server and the device',
        () async {
      await start();
      await state.tryRestoreSession();
      final before = DateTime.now().toUtc();

      expect(await state.setConversationMute('conv_1', MuteDuration.eightHours),
          isTrue);
      expect(api.lastUntil!.difference(before).inMinutes,
          inInclusiveRange(479, 481));
      expect(state.isMuted('conv_1'), isTrue);
      expect(state.mutedUntil('conv_1'), api.lastUntil);
      expect((await store.loadConversationMutes())['conv_1'], api.lastUntil);

      await state.setConversationMute('conv_1', MuteDuration.oneWeek);
      expect(api.lastUntil!.difference(before).inHours,
          inInclusiveRange(167, 169));

      await state.setConversationMute('conv_1', MuteDuration.always);
      expect(api.lastMuted, isTrue);
      expect(api.lastUntil, isNull);
      expect(state.mutedUntil('conv_1'), isNull);
      expect(state.isMuted('conv_1'), isTrue);

      await state.setConversationMute('conv_1', MuteDuration.off);
      expect(state.isMuted('conv_1'), isFalse);
      expect(await store.loadConversationMutes(), isEmpty);
    });

    test('a timed mute ends by itself on the device, also after a restart',
        () async {
      await start();
      await store.saveConversationMute('ended',
          muted: true,
          until: DateTime.now().toUtc().subtract(const Duration(minutes: 1)));
      await store.saveConversationMute('later',
          muted: true,
          until: DateTime.now().toUtc().add(const Duration(hours: 1)));
      await state.tryRestoreSession();
      expect(state.isMuted('ended'), isFalse);
      expect(state.isMuted('later'), isTrue);

      var notified = 0;
      state.addListener(() => notified++);
      api.nextMute = ConversationMute(
          muted: true,
          until: DateTime.now().toUtc().add(const Duration(milliseconds: 600)));
      await state.loadConversationMuted('conv_1');
      expect(state.isMuted('conv_1'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(state.isMuted('conv_1'), isFalse);
      expect(notified, greaterThanOrEqualTo(2), reason: 'set, then ended');
    });

    test('the server answer is the truth when it differs', () async {
      await start();
      await store.saveConversationMute('conv_1', muted: true);
      await state.tryRestoreSession();
      expect(state.isMuted('conv_1'), isTrue);
      api.nextMute = const ConversationMute(muted: false);
      await state.loadConversationMuted('conv_1');
      expect(state.isMuted('conv_1'), isFalse);
      expect(await store.loadConversationMutes(), isEmpty);
    });
  });

  test('ComposerDrafts reports changes but not loads or session clears', () {
    final drafts = ComposerDrafts();
    final changed = <String>[];
    drafts.onChanged = changed.add;
    drafts.load({'conv_1': (text: 'kept', replyTo: 'dev:1')});
    expect(changed, isEmpty);
    expect(drafts.textFor('conv_1'), 'kept');
    drafts.setText('conv_1', 'kept');
    expect(changed, isEmpty, reason: 'same text is not a change');
    drafts.setText('conv_1', 'kept more');
    drafts.setReplyTarget('conv_1', null);
    drafts.retainOnly(<String>[]);
    expect(changed, <String>['conv_1', 'conv_1', 'conv_1']);
    drafts.clear();
    expect(changed, hasLength(3));
  });
}

class _MuteApi extends ApiClient {
  _MuteApi() : super(baseUrl: 'https://localhost:8080');

  bool? lastMuted;
  DateTime? lastUntil;
  ConversationMute? nextMute;
  bool rejectToken = false;

  @override
  Future<List<Conversation>> conversations(String token) async {
    if (rejectToken) throw ApiException(401, '{"error":"unauthorized"}');
    return <Conversation>[Conversation(id: 'conv_1', kind: 'group')];
  }

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async =>
      Session(
        baseUrl: baseUrl,
        token: 'token_2',
        accountId: 'acct_own',
        deviceId: deviceId,
        deviceSecret: deviceSecret,
      );

  @override
  Future<void> logout(String token) async {}

  @override
  Future<List<Device>> devices(String token) async => <Device>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      nextMute ?? const ConversationMute(muted: false);

  @override
  Future<ConversationMute> setConversationMute(
    String token,
    String conversationId, {
    required bool muted,
    Duration? forDuration,
  }) async {
    final until =
        forDuration == null ? null : DateTime.now().toUtc().add(forDuration);
    lastMuted = muted;
    lastUntil = until;
    return ConversationMute(muted: muted, until: muted ? until : null);
  }
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
