// The read-receipts switch in the UI (TASK-046): a choice this device could
// not store is shown, not silently lost at the next launch, and ticks show
// read state only once the stored choice is known to be on.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/features/chat/message_ticks.dart';
import 'package:private_messenger/features/settings/read_receipts_tile.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// A store whose reads wait for the test and whose writes can fail.
class _Store implements ReceiptPreferenceStore {
  Completer<bool?> read = Completer<bool?>();
  bool failWrites = false;

  @override
  Future<bool?> load() => read.future;

  @override
  Future<void> save(bool sendReadReceipts) async {
    if (failWrites) throw StateError('keystore unavailable');
  }
}

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('a choice the device could not store is shown on the tile',
      (tester) async {
    final store = _Store()..failWrites = true;
    store.read.complete(null);
    final preferences = ReceiptPreferences(store);
    await preferences.loaded;

    await tester.pumpWidget(_app(ReadReceiptsTile(
      preferences: preferences,
      // The server took the change; only the local save fails, as in
      // AppState.setSendReadReceipts.
      onChanged: (value) async {
        await preferences.setSendReadReceipts(value);
        return true;
      },
    )));
    expect(find.text(englishL10n.settingsReadReceiptsNotSaved), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(preferences.sendReadReceipts, isFalse,
        reason: 'the choice still applies for this run');
    expect(find.text(englishL10n.settingsReadReceiptsNotSaved), findsOneWidget);

    store.failWrites = false;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.settingsReadReceiptsNotSaved), findsNothing);
  });

  testWidgets('ticks show read state only once the stored choice is known',
      (tester) async {
    final store = _Store();
    final api = ApiClient(baseUrl: 'https://localhost:8080');
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
      receiptPreferences: ReceiptPreferences(store),
    );
    final sent = DateTime.utc(2026, 10, 1, 12);
    state.receipts.set('c1', <MemberReceipt>[
      MemberReceipt(
        accountId: 'acct_bob',
        deliveredThrough: sent,
        readThrough: sent,
      ),
    ]);

    await tester.pumpWidget(_app(MessageTickBuilder(
      state: state,
      conversationId: 'c1',
      createdAt: sent,
      enabled: true,
      builder: (context, tick) => Text('tick:${tick?.name}'),
    )));
    // The keystore has not answered: a stored "off" may be hidden, so no
    // read state is shown yet.
    expect(find.text('tick:delivered'), findsOneWidget);

    // Nothing was stored, which means on: read state appears.
    store.read.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('tick:read'), findsOneWidget);
  });
}
