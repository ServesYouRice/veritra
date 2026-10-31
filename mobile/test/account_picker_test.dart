// AccountPicker: a lookup that is out of date can never put results on screen
// or be tapped, and the selection never goes over its limit (TASK-092).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/account_picker.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// A search whose answer to each query waits for the test.
class _SearchApi extends ApiClient {
  _SearchApi() : super(baseUrl: 'https://localhost');

  final Map<String, Completer<List<MetadataSearchResult>>> pending =
      <String, Completer<List<MetadataSearchResult>>>{};
  final List<String> queries = <String>[];

  @override
  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) {
    queries.add(query);
    return (pending[query] = Completer<List<MetadataSearchResult>>()).future;
  }

  /// Answers the lookup for [query] with accounts named [names].
  void answer(String query, List<String> names) {
    pending[query]!.complete(<MetadataSearchResult>[
      for (final name in names)
        MetadataSearchResult(type: 'account', id: 'acct_$name', label: name),
    ]);
  }
}

const _debounce = Duration(milliseconds: 400);

Future<(_SearchApi, List<List<SelectedAccount>>)> _show(
  WidgetTester tester, {
  int? maxSelection,
}) async {
  final api = _SearchApi();
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  final changes = <List<SelectedAccount>>[];
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: AccountPicker(
          state: state,
          maxSelection: maxSelection,
          onChanged: changes.add,
        ),
      ),
    ),
  ));
  return (api, changes);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

void main() {
  testWidgets('an answer for text that was edited since is never shown',
      (tester) async {
    final (api, _) = await _show(tester);
    await _type(tester, 'a');
    await tester.pump(_debounce);
    expect(api.queries, <String>['a']);

    await _type(tester, 'ab');
    // The older answer arrives while the newer text waits out the debounce.
    api.answer('a', <String>['anna']);
    await tester.pump();
    expect(find.text('anna'), findsNothing);

    await tester.pump(_debounce);
    api.answer('ab', <String>['abel']);
    await tester.pump();
    expect(find.text('abel'), findsOneWidget);
    expect(find.text('anna'), findsNothing);
  });

  testWidgets('clearing the field removes results at once', (tester) async {
    final (api, _) = await _show(tester);
    await _type(tester, 'sam');
    await tester.pump(_debounce);
    api.answer('sam', <String>['samuel']);
    await tester.pump();
    expect(find.text('samuel'), findsOneWidget);

    await _type(tester, '');
    expect(find.text('samuel'), findsNothing,
        reason: 'results for text that is gone must not stay tappable');
  });

  /// The tap handler of the tile for [name], as it was drawn at this moment.
  /// A tap can land on a tile that a later edit has already replaced.
  VoidCallback tapOf(WidgetTester tester, String name) =>
      tester.widget<ListTile>(find.widgetWithText(ListTile, name)).onTap!;

  testWidgets('a lookup in flight when an account is chosen is dropped',
      (tester) async {
    final (api, changes) = await _show(tester);
    await _type(tester, 'sam');
    await tester.pump(_debounce);
    api.answer('sam', <String>['samuel']);
    await tester.pump();
    final chooseSamuel = tapOf(tester, 'samuel');

    // The text changes and its lookup starts; then the tap lands on the tile
    // that was drawn before the change.
    await _type(tester, 'sa');
    await tester.pump(_debounce);
    expect(api.queries, <String>['sam', 'sa']);
    chooseSamuel();
    await tester.pump();
    expect(changes.last.map((account) => account.label), <String>['samuel']);

    api.answer('sa', <String>['sasha']);
    await tester.pump();
    expect(find.text('sasha'), findsNothing,
        reason: 'the field was cleared by the choice; old results stay away');
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
      'a lookup still waiting out its debounce is cancelled by a '
      'choice', (tester) async {
    final (api, changes) = await _show(tester);
    await _type(tester, 'sa');
    await tester.pump(_debounce);
    api.answer('sa', <String>['sasha']);
    await tester.pump();
    final chooseSasha = tapOf(tester, 'sasha');

    await _type(tester, 'sam'); // the debounce for 'sam' is now pending
    chooseSasha();
    await tester.pump();
    expect(changes.last, hasLength(1));

    await tester.pump(_debounce * 2);
    expect(api.queries, <String>['sa'], reason: 'no lookup after the choice');
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('the selection never goes over maxSelection', (tester) async {
    final (api, changes) = await _show(tester, maxSelection: 2);
    await _type(tester, 'a');
    await tester.pump(_debounce);
    api.answer('a', <String>['ann', 'abe', 'amy']);
    await tester.pump();
    // Three tiles drawn at once; a late tap can reach any of them.
    final ann = tapOf(tester, 'ann');
    final abe = tapOf(tester, 'abe');
    final amy = tapOf(tester, 'amy');

    ann();
    await tester.pump();
    abe();
    await tester.pump();
    expect(changes.last, hasLength(2));
    // At the limit the field is off.
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    amy();
    await tester.pump();
    expect(changes.last, hasLength(2), reason: 'a third account is refused');
    expect(find.byType(InputChip), findsNWidgets(2));
    for (final change in changes) {
      expect(change.length, lessThanOrEqualTo(2));
    }
  });

  testWidgets('a single-account picker still replaces the choice',
      (tester) async {
    final (api, changes) = await _show(tester, maxSelection: 1);
    for (final name in <String>['first', 'second']) {
      await _type(tester, 'q-$name');
      await tester.pump(_debounce);
      api.answer('q-$name', <String>[name]);
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pump();
    }
    expect(changes.last.map((account) => account.label), <String>['second']);
    expect(find.byType(InputChip), findsOneWidget);
  });

  testWidgets('an account that is already chosen is not offered again',
      (tester) async {
    final (api, _) = await _show(tester, maxSelection: 3);
    await _type(tester, 'q1');
    await tester.pump(_debounce);
    api.answer('q1', <String>['sam']);
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'sam'));
    await tester.pump();

    await _type(tester, 'q2');
    await tester.pump(_debounce);
    api.answer('q2', <String>['sam', 'sammy']);
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'sam'), findsNothing);
    expect(find.widgetWithText(ListTile, 'sammy'), findsOneWidget);
  });

  testWidgets('the caller\'s own account is never offered', (tester) async {
    final (api, _) = await _show(tester);
    await _type(tester, 'me');
    await tester.pump(_debounce);
    api.pending['me']!.complete(<MetadataSearchResult>[
      MetadataSearchResult(type: 'account', id: 'acct_me', label: 'me'),
      MetadataSearchResult(type: 'account', id: 'acct_you', label: 'you'),
    ]);
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'me'), findsNothing);
    expect(find.widgetWithText(ListTile, 'you'), findsOneWidget);
  });

  testWidgets('a lookup with no account in it says so', (tester) async {
    final (api, _) = await _show(tester);
    await _type(tester, 'nobody');
    await tester.pump(_debounce);
    api.answer('nobody', <String>[]);
    await tester.pump();
    expect(find.text(englishL10n.accountPickerNoMatch), findsOneWidget);
  });

  testWidgets('leaving while a lookup runs is harmless', (tester) async {
    final (api, _) = await _show(tester);
    await _type(tester, 'sam');
    await tester.pump(_debounce);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    api.answer('sam', <String>['samuel']);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
