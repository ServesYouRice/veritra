import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// A server answer read before the user changed the read-receipts switch must
/// never undo that change (a stale "on" would share read state).
void main() {
  const session = Session(
    baseUrl: 'https://localhost:8080',
    token: 'token',
    accountId: 'acct_me',
    deviceId: 'dev_me',
    username: 'me',
  );

  ({AppState state, _Api api, MemoryReceiptPreferenceStore store}) build() {
    final api = _Api();
    final store = MemoryReceiptPreferenceStore(true);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
      receiptPreferences: ReceiptPreferences(store),
    )
      ..api = api
      ..session = session;
    return (state: state, api: api, store: store);
  }

  test('an in-flight refresh does not undo a switch turned off', () async {
    final h = build();
    addTearDown(h.state.dispose);
    final answer = Completer<bool>();
    h.api.nextRead = answer;

    final refresh = h.state.refreshReadReceiptsSetting();
    expect(await h.state.setSendReadReceipts(false), isTrue);
    // The server answered "on" before it saw the change.
    answer.complete(true);
    await refresh;

    expect(h.state.receiptPreferences.sendReadReceipts, isFalse);
    expect(h.state.receiptPreferences.shareReadReceipts, isFalse);
    expect(h.store.value, isFalse);
  });

  test('a refresh started while the change is being sent is ignored',
      () async {
    final h = build();
    addTearDown(h.state.dispose);
    final put = Completer<void>();
    h.api.nextWrite = put;
    final change = h.state.setSendReadReceipts(false);
    final answer = Completer<bool>();
    h.api.nextRead = answer;
    final refresh = h.state.refreshReadReceiptsSetting();
    put.complete();
    expect(await change, isTrue);
    answer.complete(true);
    await refresh;

    expect(h.state.receiptPreferences.sendReadReceipts, isFalse);
    expect(h.store.value, isFalse);
  });

  test('a refresh with no change in between is still adopted', () async {
    final h = build();
    addTearDown(h.state.dispose);
    h.api.server = false;
    await h.state.refreshReadReceiptsSetting();
    expect(h.state.receiptPreferences.sendReadReceipts, isFalse);
    expect(h.store.value, isFalse);
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  bool server = true;
  Completer<bool>? nextRead;
  Completer<void>? nextWrite;

  @override
  Future<bool> readReceiptsEnabled(String token) {
    final pending = nextRead;
    nextRead = null;
    return pending?.future ?? Future<bool>.value(server);
  }

  @override
  Future<void> setReadReceiptsEnabled(String token, bool enabled) async {
    final pending = nextWrite;
    nextWrite = null;
    if (pending != null) await pending.future;
    server = enabled;
  }
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async => _controller.close();
}
