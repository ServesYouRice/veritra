// A community's name never leaves the device (owner, 2026-11-21): the
// people-and-communities search sends a request only for a query that
// clearly names a person. This runs the real AppState and ApiClient over an
// HTTP client that records every request it is asked to open, so a
// community-name term cannot reach the server by any route, not only the
// account lookup.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/community_name_search.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// Records each request the app opens and fails it as unreachable, so no
/// byte is sent and the test sees every URL the app tried.
class _RecordingHttpClient implements HttpClient {
  final requests = <Uri>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    requests.add(url);
    return Future<HttpClientRequest>.error(
      const SocketException('blocked by test'),
    );
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(scheme: 'https', host: host, port: port, path: path));

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Settings such as connectionTimeout and close() are harmless; any
    // other way to open a request fails the test.
    if (invocation.isSetter || invocation.memberName == #close) return null;
    fail('unexpected HttpClient call ${invocation.memberName}');
  }
}

/// The real AppState and its server search; only the decrypted names stand
/// in for the C3 records this device would hold.
class _NamesState extends AppState {
  _NamesState(HttpClient http)
      : super(
          // Every client the state builds goes through the recorder too.
          apiClientFactory: (baseUrl) =>
              ApiClient(baseUrl: baseUrl, httpClient: http),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final names = <String, String>{
    'comm_rust': 'Rustaceans',
    'chan_lounge': 'lounge',
  };

  @override
  List<MetadataSearchResult> searchCommunityNamesLocally(String query) =>
      searchCommunityNames(
        query,
        communities: communities,
        channelsByCommunity: channelsByCommunity,
        conversations: conversations,
        communityName: (community) => names[community.id],
        channelName: (channel) => names[channel.id],
      );
}

Future<(_NamesState, _RecordingHttpClient)> _openSearch(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final http = _RecordingHttpClient();
  final state = _NamesState(http)
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    )
    ..api = ApiClient(baseUrl: 'https://localhost', httpClient: http)
    ..communities = <Community>[
      Community(id: 'comm_rust', name: '', sharedConversationId: 'conv_rust'),
    ]
    ..channelsByCommunity = <String, List<Channel>>{
      'comm_rust': <Channel>[
        Channel(
          id: 'chan_lounge',
          communityId: 'comm_rust',
          name: '',
          kind: 'open',
          conversationId: 'conv_rust',
          layoutGeneration: 1,
        ),
      ],
    }
    ..conversations = <Conversation>[
      Conversation(
        id: 'conv_rust',
        kind: 'community_shared',
        communityId: 'comm_rust',
      ),
    ];
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SearchScreen(state: state),
    ),
  );
  await tester.tap(find.text('People'));
  await tester.pumpAndSettle();
  return (state, http);
}

/// Types [text], waits past any debounce, then submits it both ways: Enter
/// and the search button.
Future<void> _typeAndSubmit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('search-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no request carries a community or channel name', (
    tester,
  ) async {
    final (_, http) = await _openSearch(tester);
    // One word each, and each a valid username: the old rule sent them.
    for (final term in <String>['Rustaceans', 'rustaceans', 'rust', 'lounge']) {
      await _typeAndSubmit(tester, term);
      expect(
        find.text(term == 'lounge' ? 'lounge' : 'Rustaceans'),
        findsWidgets,
        reason: 'found on the device',
      );
    }
    expect(
      http.requests,
      isEmpty,
      reason: 'a community or channel name never leaves the device',
    );
  });

  testWidgets('the recorder sees an @username lookup (control)', (
    tester,
  ) async {
    final (_, http) = await _openSearch(tester);
    await tester.enterText(find.byType(TextField), '@alice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(http.requests, hasLength(1));
    final sent = http.requests.single;
    expect(sent.path, '/api/v1/search/metadata');
    expect(sent.queryParameters['q'], 'alice');
    // The failed lookup is reported; nothing else was sent.
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
