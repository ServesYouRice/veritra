// A refused pin (the device already has five pinned chats) shows a clean
// sentence, never a raw "Bad state: ..." exception string.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  testWidgets('a refused pin shows no raw exception text', (tester) async {
    final store = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..conversations = <Conversation>[
        for (var i = 1; i <= 6; i++)
          Conversation(id: 'conv_$i', kind: 'group', title: 'Group $i'),
      ]
      ..conversationsLoaded = true;
    for (var i = 1; i <= 5; i++) {
      await tester.runAsync(() => state.setChatPinned('conv_$i', true));
    }

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatListScreen(state: state),
    ));
    await tester.pump();

    await tester.longPress(find.text('Group 6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(state.l10n.w8PinChat));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(state.isChatPinned('conv_6'), isFalse);
    state.dispose();
  });
}

class _NoopSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
