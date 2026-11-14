import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/reauthenticate.dart';

import 'test_crypto_service.dart';

/// U9: a refused password keeps the re-authentication dialog open with the
/// error under the field, instead of closing it and flashing a snackbar.
void main() {
  late _Api api;
  late AppState state;

  setUp(() {
    api = _Api();
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
        username: 'me',
        deviceSecret: 'secret',
        role: 'member',
      );
  });

  tearDown(() => state.dispose());

  Widget app(void Function(Future<bool>) onAsked) => MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => onAsked(promptReauthenticate(context, state)),
              child: const Text('Ask'),
            ),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('a wrong password keeps the dialog open with the error',
      (tester) async {
    Future<bool>? result;
    await tester.pumpWidget(app((f) => result = f));
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm your password'), findsOneWidget);

    api.failure = ApiException(401, '{"error":"invalid_credentials"}');
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Continue'));
    await settle(tester);

    expect(find.text('Confirm your password'), findsOneWidget);
    expect(state.error, isNotNull);
    expect(find.text(state.error!), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    var completed = false;
    unawaited(result!.then((_) => completed = true));
    await tester.pump();
    expect(completed, isFalse);

    // Typing again clears the error; the right password then closes the
    // dialog and the action goes on.
    await tester.enterText(find.byType(TextField), 'right');
    await tester.pump();
    expect(find.text(state.error!), findsNothing);
    api.failure = null;
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('Confirm your password'), findsNothing);
    expect(await result, isTrue);
    expect(api.passwords, <String>['wrong', 'right']);
  });

  testWidgets('Cancel returns false and sends nothing', (tester) async {
    Future<bool>? result;
    await tester.pumpWidget(app((f) => result = f));
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(api.passwords, isEmpty);
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  Object? failure;
  final List<String> passwords = <String>[];

  @override
  Future<String?> reauthenticate(
    String token,
    String password,
    String deviceSecret,
  ) async {
    passwords.add(password);
    final error = failure;
    if (error != null) throw error;
    return null;
  }
}

class _Sync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}
