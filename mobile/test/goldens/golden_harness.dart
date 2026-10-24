// Shared fixtures for the T43C visual and responsive tests.
//
// Everything here is deterministic: a fixed locale, fixed message and
// conversation dates, no network, and no real crypto. Conversation dates sit
// in 2025, so the chat list shows a short date that does not depend on the
// clock.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/appearance.dart';
import 'package:private_messenger/ui/theme.dart';

import '../test_crypto_service.dart';

/// Window sizes, in logical pixels, that the T43C tests cover.
const Size phoneSize = Size(360, 800);
const Size wideSize = Size(1280, 800);
const Size narrowPhoneSize = Size(320, 640);
const Size landscapePhoneSize = Size(800, 360);
const Size tabletSize = Size(820, 1180);

/// The conversation that the chat fixture opens.
const String chatConversationId = 'conv_alice';

/// Why golden comparisons are skipped here, or null when they run.
///
/// Font rasterisation differs between operating systems, so the PNGs are only
/// compared on Linux (the CI `mobile` job). Message bubbles show a local time
/// of day, so the host must also be on UTC, which GitHub's runners are; run
/// locally with `TZ=UTC flutter test`.
String? get goldenSkipReason {
  if (!Platform.isLinux) {
    return 'goldens are only compared on Linux';
  }
  if (DateTime.utc(2025, 3, 14, 9).toLocal().timeZoneOffset != Duration.zero) {
    return 'goldens need TZ=UTC (message times are local)';
  }
  return null;
}

/// Sets the test window to [size] at a device pixel ratio of 1.
void setWindowSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The app shell as `main.dart` composes it: the real themes and
/// localizations, an [AppearanceScope], and a rebuild on every [state]
/// change. The locale defaults to `en` and the clock format is 24 hours.
Widget veritraTestApp({
  required AppState state,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) {
  final appearance = AppearanceController(MemoryAppearanceStore(themeMode));
  unawaited(appearance.load());
  return AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[state, appearance]),
    builder: (context, _) => AppearanceScope(
      controller: appearance,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: veritraLightTheme(),
        darkTheme: veritraDarkTheme(),
        themeMode: themeMode,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        ),
        home: AppShell(state: state),
      ),
    ),
  );
}

/// A state with no session, so the shell shows the connect screen.
AppState disconnectedState() {
  return _FixtureState(_FixtureApi())..lifecycle = SessionLifecycle.ready;
}

/// A signed-in state with a few conversations and decrypted history for
/// [chatConversationId], including one message whose sender could not be
/// verified.
Future<AppState> connectedState() async {
  final api = _FixtureApi()
    ..envelopes = <ReceivedMessageEnvelope>[
      // Newest first, as the server pages them. Each matches a local
      // record below by sender device and idempotency key.
      _envelope('m4', 'acct_alice', 'dev_alice', '2025-03-14T09:12:00Z'),
      _envelope('m3', 'acct_alice', 'dev_unknown', '2025-03-14T09:05:00Z'),
      _envelope('m2', 'acct_owner', 'dev_owner', '2025-03-14T09:03:00Z'),
      _envelope('m1', 'acct_alice', 'dev_alice', '2025-03-14T09:00:00Z'),
    ];
  final store = MemoryLocalStore();
  final state = _FixtureState(api, store: store)
    ..api = api
    ..lifecycle = SessionLifecycle.ready
    ..connectionStatus = ConnectionStatus.online
    ..session = const Session(
      baseUrl: 'https://chat.example.org',
      token: 'fixture-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    )
    ..conversations = <Conversation>[
      Conversation(
        id: chatConversationId,
        kind: 'dm',
        peerAccountId: 'acct_alice',
        peerUsername: 'alice',
        lastMessageAt: DateTime.utc(2025, 3, 14, 9, 12),
        unreadCount: 2,
      ),
      Conversation(
        id: 'conv_design',
        kind: 'group',
        title: 'Design review',
        lastMessageAt: DateTime.utc(2025, 3, 13, 16, 40),
        retentionSeconds: 86400,
      ),
      Conversation(
        id: 'conv_bob',
        kind: 'dm',
        peerAccountId: 'acct_bob',
        peerUsername: 'bob',
        lastMessageAt: DateTime.utc(2025, 3, 10, 11),
        unreadCount: 1,
      ),
      Conversation(
        id: 'conv_ops',
        kind: 'group',
        title: 'Server operations',
        lastMessageAt: DateTime.utc(2025, 2, 27, 8, 5),
      ),
    ]
    ..conversationsLoaded = true
    ..devices = <Device>[
      Device(
        id: 'dev_owner',
        accountId: 'acct_owner',
        name: 'Pixel 8',
        createdAt: DateTime.utc(2025, 1, 6, 12),
        lastSeenAt: DateTime.utc(2025, 3, 14, 9),
      ),
      Device(
        id: 'dev_laptop',
        accountId: 'acct_owner',
        name: 'Laptop',
        createdAt: DateTime.utc(2025, 2, 2, 12),
        lastSeenAt: DateTime.utc(2025, 3, 12, 18),
      ),
    ]
    ..devicesLoaded = true
    ..blocksLoaded = true;

  await store.saveCryptoState(
    StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 1),
      sealedState: <int>[1],
    ),
    0,
  );
  int at(int hour, int minute) =>
      DateTime.utc(2025, 3, 14, hour, minute).millisecondsSinceEpoch;
  InsertMessageEffect text(String key, String sender, String body, int time) {
    final mine = sender == 'acct_owner';
    return InsertMessageEffect(
      key: '${mine ? 'dev_owner' : 'dev_alice'}:$key',
      conversationId: chatConversationId,
      senderAccountId: sender,
      senderDeviceId: mine ? 'dev_owner' : 'dev_alice',
      kind: LocalMessageKind.text,
      body: body,
      createdAt: time,
      state: mine ? LocalMessageState.sent : LocalMessageState.received,
    );
  }

  await store.commitMlsTransition(MlsStateTransition(
    messageId: 'event:1',
    conversationId: chatConversationId,
    expectedCounter: 1,
    expectedCursor: 0,
    state: StoredCryptoState(
      counter: 2,
      stateKey: List<int>.filled(32, 1),
      sealedState: <int>[2],
    ),
    cursor: 1,
    messageEffects: <MessageEffect>[
      text('m1', 'acct_alice', 'Morning! Is the new server up yet?', at(9, 0)),
      text('m2', 'acct_owner', 'Yes, it finished the restore test overnight.',
          at(9, 3)),
      const InsertMessageEffect(
        key: 'dev_unknown:m3',
        conversationId: chatConversationId,
        senderAccountId: 'acct_alice',
        senderDeviceId: 'dev_unknown',
        kind: LocalMessageKind.unverifiable,
        createdAt: 1741943100000, // 2025-03-14 09:05 UTC
        state: LocalMessageState.received,
      ),
      text('m4', 'acct_alice', 'Great. I will move the group over today.',
          at(9, 12)),
      ReactionEffect(
        targetKey: 'dev_alice:m4',
        reactorAccountId: 'acct_owner',
        reaction: '👍',
        at: at(9, 13),
      ),
    ],
  ));
  await state.refreshHistory(chatConversationId);
  return state;
}

ReceivedMessageEnvelope _envelope(
  String id,
  String sender,
  String device,
  String createdAt,
) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': chatConversationId,
    'sender_account_id': sender,
    'sender_device_id': device,
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': createdAt,
  });
}

class _FixtureState extends AppState {
  _FixtureState(ApiClient api, {LocalStore? store})
      : super(
          apiClientFactory: (_) => api,
          cryptoService: TestOnlyCryptoService(),
          localStore: store ?? MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async =>
      const SetupProbeResult(state: SetupProbeState.reachable);

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;
}

/// Answers every call the fixture screens make without touching the network.
class _FixtureApi extends ApiClient {
  _FixtureApi() : super(baseUrl: 'https://chat.example.org');

  List<ReceivedMessageEnvelope> envelopes = <ReceivedMessageEnvelope>[];

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      MessagePage(
        messages: conversationId == chatConversationId && before == null
            ? envelopes
            : const <ReceivedMessageEnvelope>[],
      );

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      const <ConversationMember>[];

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async =>
      const <BlockedAccount>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      const ConversationMute(muted: false);

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {}
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
