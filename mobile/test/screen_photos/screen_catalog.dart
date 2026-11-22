// U38: every screen of mobile/lib/features, and how to photograph it.
//
// One entry per state worth a picture. The guard test
// (screen_catalog_guard_test.dart) fails when a Screen, Page, Dialog or Sheet
// class in lib/features has neither an entry here nor an explicit
// [PhotoScreen.skipped]. To add a screen: add a [PhotoScreen.direct] with the
// fixtures it needs (see photo_fixtures.dart and the fakes the feature's own
// tests use), run
//   SCREEN_PHOTOS=1 TZ=UTC flutter test test/screen_photos --plain-name '<name>'
// and read the "networkCalls" of its JSON: a request there is something the
// fixtures do not answer yet.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_controller.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/calls/room/room_ports.dart';
import 'package:private_messenger/core/account_host.dart';
import 'package:private_messenger/core/admin_models.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/models.dart' hide Device;
import 'package:private_messenger/core/passkeys.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/core/reports_service.dart' show OpenedReport;
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/report_body.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart'
    show BackupHeaderInfo, OpenedBackup;
import 'package:private_messenger/features/auth/account_recovery_screen.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/auth/recovery_follow_up_screen.dart';
import 'package:private_messenger/features/calls/call_host.dart';
import 'package:private_messenger/features/calls/room_screen.dart';
import 'package:private_messenger/features/chat/attachment_views.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/conversation_details_screen.dart';
import 'package:private_messenger/features/chat/copied_history_screen.dart';
import 'package:private_messenger/features/chat/emoji_picker.dart';
import 'package:private_messenger/features/chat/message_request_screen.dart';
import 'package:private_messenger/features/chat/mute_sheet.dart';
import 'package:private_messenger/features/chat/new_conversation_sheet.dart';
import 'package:private_messenger/features/chat/poll_widgets.dart';
import 'package:private_messenger/features/chat/roles_screen.dart';
import 'package:private_messenger/features/chat/safety_number_screen.dart';
import 'package:private_messenger/features/communities/channel_conversion.dart';
import 'package:private_messenger/features/communities/community_info_screen.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/features/communities/create_channel_screen.dart';
import 'package:private_messenger/features/communities/edit_info_dialog.dart';
import 'package:private_messenger/features/communities/membership_screens.dart';
import 'package:private_messenger/features/communities/moderation_screen.dart';
import 'package:private_messenger/features/reports/owner_reports_screen.dart';
import 'package:private_messenger/features/reports/report_message_screen.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/features/settings/accounts_screen.dart';
import 'package:private_messenger/features/settings/admin_screen.dart';
import 'package:private_messenger/features/settings/auto_backup_screen.dart';
import 'package:private_messenger/features/settings/blocked_accounts_screen.dart';
import 'package:private_messenger/features/settings/device_link_screen.dart';
import 'package:private_messenger/features/settings/invite_screen.dart';
import 'package:private_messenger/features/settings/k1_restore_screen.dart';
import 'package:private_messenger/features/settings/linked_devices_screen.dart';
import 'package:private_messenger/features/settings/passkeys_screen.dart';
import 'package:private_messenger/features/settings/profile_edit_screen.dart';
import 'package:private_messenger/features/settings/profile_screen.dart';
import 'package:private_messenger/features/settings/reauth_dialog.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/features/settings/sealed_key_screen.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/storage/account_slots.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/app_shell.dart';

import '../b6_room_fakes.dart';
import '../b7_passkey_fakes.dart';
import '../call_service_fakes.dart';
import '../k0_recovery_fakes.dart';
import '../test_crypto_service.dart';
import 'photo_fixtures.dart';
import 'photo_screen.dart';

// ---------------------------------------------------------------------------
// Small helpers.

/// A signed-in state on the recovery fakes (a server that keeps one
/// account's recovery state).
AppState _k0State(K0Server server, {K0Crypto? crypto}) =>
    k0App(server, MemoryLocalStore(), crypto ?? K0Crypto())
      ..session = k0SignedIn
      ..api = K0Api(server);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<AppState> _rich(PhotoEnv env, {String role = 'owner'}) async {
  final state = env.own(await richState(role: role));
  env.listenables.add(state);
  env.state = state;
  return state;
}

/// The community of [richState].
Community _community(AppState state) => state.communities.single;

/// Shows a dialog or sheet over an empty page.
Widget _host() => const Scaffold(body: SizedBox.expand());

Future<void> _showAfterFrame(
  WidgetTester tester,
  Future<Object?> Function(BuildContext context) show,
) async {
  unawaited(show(photoContext(tester)));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// The goldens' screens, reached the way a person reaches them.

final List<PhotoScreen> _shellScreens = <PhotoScreen>[
  PhotoScreen.shell('chat_details', 'ConversationDetailsScreen',
      connected: true, open: (tester, _) async {
    await tester.tap(find.text('@alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conversation details'));
  }),
  for (final row in <String>[
    'Change password',
    'Export account data',
    'Delete account',
    'Link a new device',
  ])
    PhotoScreen.shell('settings_${row.toLowerCase().replaceAll(' ', '_')}',
        row == 'Link a new device' ? 'DeviceLinkScreen' : 'SettingsScreen',
        connected: true, open: (tester, _) async {
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(row),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(row));
    }),
  const PhotoScreen.shell('connect', 'ConnectScreen', connected: false),
  const PhotoScreen.shell('chats', 'ChatListScreen', connected: true),
  PhotoScreen.shell('chat', 'ChatScreen', connected: true,
      open: (tester, _) async {
    await tester.tap(find.text('@alice'));
  }),
  PhotoScreen.shell('settings', 'SettingsScreen', connected: true,
      open: (tester, _) async {
    await tester.tap(find.byIcon(Icons.settings_outlined));
  }),
];

// ---------------------------------------------------------------------------
// auth

final List<PhotoScreen> _authScreens = <PhotoScreen>[
  PhotoScreen.direct('recovery_start', 'AccountRecoveryStartScreen',
      (env) async {
    final state = env.own(_k0State(K0Server()));
    return AccountRecoveryStartScreen(
      state: state,
      initialServer: k0Origin,
    );
  }),
  PhotoScreen.direct('recovery_waiting', 'AccountRecoveryWaitingScreen',
      (env) async {
    final server = K0Server();
    final state = env.own(
      k0App(server, MemoryLocalStore(), K0Crypto()),
    );
    await env.tester.runAsync(
      () => state.startAccountRecovery(
        baseUrl: k0Origin,
        username: 'alice',
        password: 'pw',
        recoveryKey: k0Display,
      ),
    );
    // The server fake says ready on 2099-11-08 10:00 UTC; a fixed clock keeps
    // the countdown the same on every run.
    return AccountRecoveryWaitingScreen(
      state: state,
      clock: () => DateTime.utc(2099, 11, 5, 8),
    );
  }),
  for (final step in <(String, RecoveryFollowUpStep, bool)>[
    ('password', RecoveryFollowUpStep.password, false),
    ('restore', RecoveryFollowUpStep.restore, true),
    ('key', RecoveryFollowUpStep.recoveryKey, false),
  ])
    PhotoScreen.direct(
        'recovery_follow_up_${step.$1}', 'RecoveryFollowUpScreen', (env) async {
      final state = env.own(
        _k0State(
          K0Server(),
          crypto: step.$3 ? K0RestoringCrypto() : K0Crypto(),
        ),
      )..recoveryFollowUp = step.$2;
      env.listenables.add(state);
      return RecoveryFollowUpScreen(state: state);
    }),
  // There is no camera here: the picture is the scanner's own "camera
  // unavailable" or starting state, with its frame and hint.
  PhotoScreen.direct('qr_scan', 'QrScanScreen', (env) async {
    return const QrScanScreen();
  }),
];

// ---------------------------------------------------------------------------
// calls

/// The native WebRTC plugin does not exist in tests: refuse its calls.
void _refuseWebRtc(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  const channel = MethodChannel('FlutterWebRTC.Method');
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => throw PlatformException(code: 'none'),
  );
  // The plugin's event stream: listening answers, nothing is ever sent.
  const events = MethodChannel('FlutterWebRTC.Event');
  messenger.setMockMethodCallHandler(events, (call) async => null);
  addTearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });
}

class _RoomControls extends ChangeNotifier implements RoomMediaControls {
  @override
  bool micMuted = false;
  @override
  bool sharingScreen = false;
  @override
  bool cameraOn = false;
  @override
  bool get canUseCamera => true;
  @override
  bool get canShareScreen => true;
  @override
  bool get screenNeedsSource => false;

  @override
  bool get requestingPermission => false;
  @override
  RoomMediaNotice? get notice => null;
  @override
  void dismissNotice() {}
  @override
  List<RoomVideoTile> get videoTiles => const <RoomVideoTile>[];

  @override
  Future<List<ScreenSource>> screenSources() async => const <ScreenSource>[];

  @override
  Future<void> setMicMuted(bool muted) async {
    micMuted = muted;
    notifyListeners();
  }

  @override
  Future<void> setCameraOn(bool on) async {
    cameraOn = on;
    notifyListeners();
  }

  @override
  Future<void> setSharingScreen(bool on, {String? sourceId}) async {
    sharingScreen = on;
    notifyListeners();
  }
}

String _roomName(String accountId) =>
    accountId.replaceFirst('acct_', '').toUpperCase();

final List<PhotoScreen> _callScreens = <PhotoScreen>[
  PhotoScreen.direct('room', 'RoomScreen', (env) async {
    final server = FakeServer('conv_1');
    final clock = FakeClock();
    final parent = FakeParent(<CallMember>[member('a'), member('b')]);
    late Device a;
    await env.tester.runAsync(() async {
      a = Device('a', server, clock, parent);
      await a.engine.join('conv_1');
      await pump();
      final b = Device('b', server, clock, parent);
      await b.engine.join('conv_1');
      await pump();
      a.engine.refresh();
      await pump();
      await clock.advance(const Duration(milliseconds: 250));
    });
    addTearDown(() => a.engine.leave());
    return RoomScreen(
      engine: a.engine,
      nameFor: _roomName,
      controls: _RoomControls(),
    );
  }),
  PhotoScreen.direct('call_incoming', 'CallScreen', (env) async {
    _refuseWebRtc(env.tester);
    final log = <String>[];
    final api = FakeCallApi(log);
    final incoming = StreamController<IncomingCallSignal>.broadcast();
    late NativeCallService service;
    late CallController controller;
    await env.tester.runAsync(() async {
      service = NativeCallService(
        api: api,
        token: 't',
        crypto: FakeCallCrypto(log),
        incoming: incoming.stream,
        media: FakeMediaFactory(log),
      );
      controller = CallController(
        service: service,
        selfAccountId: 'acc_callee',
      );
      final call = callSession();
      api.server[call.id] = call;
      incoming.add(
        IncomingCallSignal(call, const <String, Object?>{
          'kind': 'offer',
          'sdp': 'x',
          'sdp_type': 'offer',
        }),
      );
      await Future<void>.delayed(Duration.zero);
    });
    addTearDown(() async {
      controller.dispose();
      await env.tester.runAsync(() async {
        await service.dispose();
        await incoming.close();
      });
    });
    return Scaffold(body: CallScreen(controller: controller, title: 'Ana'));
  }),
];

// ---------------------------------------------------------------------------
// search

final List<PhotoScreen> _searchScreens = <PhotoScreen>[
  PhotoScreen.direct('search', 'SearchScreen', (env) async {
    return SearchScreen(state: await _rich(env));
  }),
];

// ---------------------------------------------------------------------------
// chat

class _FakeMls implements MlsConversationCryptoService {
  @override
  Future<ConversationSafetyNumber> conversationSafetyNumber(
    String conversationId,
  ) async =>
      ConversationSafetyNumber(
        digits: '0123456789' * 6,
        transcriptHash: List<int>.generate(32, (index) => index),
        qrPayload: 'veritra-safety:v2:$conversationId:AAECAwQ',
      );

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MlsStub implements MlsConversationCryptoService {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _HistoryState extends AppState {
  _HistoryState(LocalStore store)
      : super(
          apiClientFactory: (_) => offlineApi('https://example.test'),
          cryptoService: _MlsStub(),
          localStore: store,
          syncServiceFactory: (_, __) => PhotoSync(),
        );
}

/// A copy of another device's history holding one chat that is still live
/// here and one this device was never added to (K2).
Future<AppState> _historyState(PhotoEnv env) async {
  const origin = 'https://example.test';
  const source = 'source';
  // A fixed clock keeps the pictures the same every day.
  final now = DateTime.utc(2026, 11, 14, 12).millisecondsSinceEpoch;
  const session = Session(
    baseUrl: origin,
    token: 'receiver-token',
    accountId: 'alice',
    deviceId: 'receiver',
    deviceSecret: 'receiver-secret',
  );
  LocalMessage message(String conversation, String action, String body,
          {String sender = 'bob'}) =>
      LocalMessage(
        key: '$source:$action',
        conversationId: conversation,
        senderAccountId: sender,
        senderDeviceId: source,
        kind: 'text',
        body: body,
        createdAt: now - 60000,
        state: 'received',
        senderHidden: false,
      );
  final store = MemoryLocalStore();
  await store.saveSession(session);
  await store.saveCryptoState(
    StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 7),
      sealedState: <int>[8],
    ),
    0,
  );
  await store.importHistorySnapshot(
    HistorySnapshot(
      accountId: 'alice',
      sourceDeviceId: source,
      counter: 1,
      createdAt: now,
      conversations: const <HistoryConversation>[
        HistoryConversation('live', 'dm', title: 'Live chat'),
        HistoryConversation('old', 'group', title: 'Old team'),
      ],
      messages: <LocalMessage>[
        message('live', 'l1', 'live words'),
        message('old', 'o1', 'See you at the trailhead at nine.'),
        message('old', 'o2', 'I will bring the map.', sender: 'alice'),
      ],
      reactions: const [],
      pins: const [],
      starred: const {},
      preferences: const [],
    ).encode(),
    HistoryImportContext(
      origin: origin,
      accountId: 'alice',
      sourceDeviceId: source,
      recipientDeviceId: 'receiver',
      transferId: 'transfer',
      snapshotCounter: 1,
      snapshotCreatedAt: now,
      digest: 'a' * 64,
    ),
  );
  final state = env.own(
    _HistoryState(store)
      ..session = session
      ..conversations = <Conversation>[
        Conversation(
            id: 'live', kind: 'dm', title: 'Live chat', createdBy: 'bob'),
      ]
      ..conversationsLoaded = true,
  );
  await env.tester.runAsync(state.refreshCopiedHistory);
  env.listenables.add(state);
  return state;
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _ImageState extends AppState {
  _ImageState(this.bytes)
      : super(
          apiClientFactory: (_) => offlineApi(),
          cryptoService: _MlsStub(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => PhotoSync(),
        );
  final Uint8List bytes;

  @override
  Future<Uint8List> loadAttachment(
    AttachmentEntry entry, {
    required String conversationId,
  }) async =>
      Uint8List.fromList(bytes);
}

final List<PhotoScreen> _chatScreens = <PhotoScreen>[
  PhotoScreen.direct('chat_group', 'ChatScreen', (env) async {
    final state = await _rich(env);
    return ChatScreen(state: state, conversationId: 'conv_design');
  }),
  PhotoScreen.direct('chat_details_group', 'ConversationDetailsScreen',
      (env) async {
    final state = await _rich(env);
    return ConversationDetailsScreen(
      state: state,
      conversationId: 'conv_design',
    );
  }),
  PhotoScreen.direct('chats_archived', 'ChatListScreen', (env) async {
    final state = await _rich(env);
    return ChatListScreen(state: state, archived: true);
  }),
  PhotoScreen.direct('chats_requests', 'ChatListScreen', (env) async {
    final state = await _rich(env);
    // Loads the request state, so a stranger waits behind the Requests row.
    await env.tester.runAsync(state.refreshConversations);
    return AppShell(state: state);
  }),
  PhotoScreen.direct('chat_requests_list', '_RequestsScreen', (env) async {
    final state = await _rich(env);
    await env.tester.runAsync(state.refreshConversations);
    return AppShell(state: state);
  }, open: (tester, _) async {
    await _tap(tester, find.byKey(const Key('requests-row')));
  }),
  PhotoScreen.direct('message_request', 'MessageRequestScreen', (env) async {
    final state = await _rich(env);
    return MessageRequestScreen(
      state: state,
      conversation: state.conversations.firstWhere((c) => c.id == 'conv_carol'),
    );
  }),
  PhotoScreen.direct('roles', 'RolesScreen', (env) async {
    // A group with a verified role record: needs a crypto double that
    // answers it (the engine's own record reading is covered natively).
    final state = env.own(
      plainState(role: 'owner', api: PhotoApi(), crypto: PhotoRolesCrypto()),
    )
      ..conversations = <Conversation>[
        Conversation(
          id: 'conv_design',
          kind: 'group',
          title: 'Design review',
          createdBy: 'acct_owner',
        ),
      ]
      ..membersByConversation = <String, List<ConversationMember>>{
        'conv_design': photoMembers,
      };
    env.listenables.add(state);
    return RolesScreen(state: state, conversationId: 'conv_design');
  }),
  PhotoScreen.direct('attachment_image', 'AttachmentImageScreen', (env) async {
    final bytes = (await env.tester.runAsync(() => _png(64, 48)))!;
    final state = env.own(_ImageState(bytes));
    final screen = AttachmentImageScreen(
      state: state,
      entry: const AttachmentEntry(
        id: 'att_1',
        fileName: 'trailhead.png',
        mediaType: 'image/png',
        plaintextSize: 100,
        ciphertextSize: 130,
        manifest: <String, Object?>{},
      ),
      conversationId: 'conv_1',
    );
    return screen;
  }, open: (tester, _) async {
    // The size probe and the decode are real engine work.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }
  }),
  PhotoScreen.direct('safety_number', 'SafetyNumberScreen', (env) async {
    final state = env.own(
      AppState(
        apiClientFactory: (_) => offlineApi(),
        cryptoService: _FakeMls(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => PhotoSync(),
      ),
    );
    return SafetyNumberScreen(
      state: state,
      conversation: Conversation(
        id: 'conv_dm',
        kind: 'dm',
        peerAccountId: 'acct_peer',
        peerUsername: 'sam',
      ),
    );
  }, open: (tester, _) async {
    // The first thing the screen asks is how the two people are talking.
    final choice = find.text('We are on a call');
    if (choice.evaluate().isNotEmpty) await _tap(tester, choice);
  }),
  PhotoScreen.direct('copied_history_list', 'CopiedHistoryListScreen',
      (env) async {
    return CopiedHistoryListScreen(state: await _historyState(env));
  }),
  PhotoScreen.direct('copied_history', 'CopiedHistoryScreen', (env) async {
    final state = await _historyState(env);
    return CopiedHistoryScreen(
      state: state,
      conversation: state.historyOnlyConversations.first,
    );
  }),
  // Sheets and dialogs of the chat feature.
  PhotoScreen.direct('mute_sheet', 'chooseMuteDuration', (env) async {
    return _host();
  },
      open: (tester, _) => _showAfterFrame(
            tester,
            (context) => chooseMuteDuration(context, muted: true),
          )),
  PhotoScreen.direct('new_conversation_sheet', '_NewConversationForm',
      (env) async {
    await _rich(env);
    return _host();
  }, open: (tester, env) async {
    await _showAfterFrame(
      tester,
      (context) => showNewConversationSheet(context, env.state!),
    );
  }),
  PhotoScreen.direct('emoji_picker', 'EmojiPicker', (env) async {
    return _host();
  }, open: (tester, _) => _showAfterFrame(tester, showEmojiPicker)),
  PhotoScreen.direct('poll_composer_dialog', '_PollComposerDialog',
      (env) async {
    return _host();
  }, open: (tester, _) => _showAfterFrame(tester, showPollComposer)),
];

// ---------------------------------------------------------------------------
// communities

final List<PhotoScreen> _communityScreens = <PhotoScreen>[
  PhotoScreen.direct('community', 'CommunityScreen', (env) async {
    return CommunityScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('community_moderation', 'ModerationScreen', (env) async {
    final state = await _rich(env);
    return ModerationScreen(
      state: state,
      community: _community(state),
      canManageInvites: true,
    );
  }),
  PhotoScreen.direct('community_create_channel', 'CreateChannelScreen',
      (env) async {
    final state = await _rich(env);
    return CreateChannelScreen(state: state, community: _community(state));
  }),
  PhotoScreen.direct('community_join_by_link', 'JoinByLinkScreen', (env) async {
    return JoinByLinkScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('community_invites', 'MembershipManageScreen',
      (env) async {
    final state = await _rich(env);
    return MembershipManageScreen(
      state: state,
      kind: InviteTargetKind.community,
      targetId: _community(state).id,
    );
  }),
  PhotoScreen.direct('community_details', 'CommunityDetailsScreen',
      (env) async {
    final state = await _rich(env);
    return CommunityDetailsScreen(state: state, community: _community(state));
  }),
  PhotoScreen.direct('community_info', 'CommunityInfoScreen', (env) async {
    final state = await _rich(env);
    return CommunityInfoScreen(state: state, community: _community(state));
  }),
  PhotoScreen.direct('community_edit_info_dialog', 'EditInfoDialog',
      (env) async {
    final state = await _rich(env);
    return Scaffold(
      body: EditInfoDialog(state: state, community: _community(state)),
    );
  }),
  PhotoScreen.direct('channel_conversion_dialog', '_ConversionMembersDialog',
      (env) async {
    await _rich(env);
    return _host();
  }, open: (tester, env) async {
    final channel = env.state!.channelsByCommunity.values.first.first;
    await _showAfterFrame(
      tester,
      (context) => pickChannelConversionMembers(context, env.state!, channel),
    );
  }),
];

// ---------------------------------------------------------------------------
// settings

class _NoIoEraser implements SlotErasing {
  @override
  Future<void> erase(String namespace) async {}
}

class _AccountState extends AppState {
  _AccountState()
      : super(
          apiClientFactory: (_) => offlineApi(),
          cryptoService: _MlsStub(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => PhotoSync(),
        );

  void signInAs(String account, String origin) {
    session = Session(
      baseUrl: origin,
      token: 't',
      accountId: account,
      username: 'user$account',
    );
    notifyListeners();
  }

  @override
  Future<bool> prepareToLeave() async => true;

  @override
  Future<void> closeForSwitch() async => dispose();

  @override
  Future<void> logout() async {}
}

class _AdminApi extends PhotoApi {
  @override
  Future<AdminPage<AdminAccount>> listAdminAccounts(
    String token, {
    String? after,
    int limit = 50,
  }) async =>
      AdminPage<AdminAccount>(<AdminAccount>[
        AdminAccount(
          id: 'acct_owner',
          username: 'owner',
          role: 'owner',
          status: 'active',
        ),
        AdminAccount(
          id: 'acct_bob',
          username: 'bob',
          role: 'member',
          status: 'active',
          deviceCount: 2,
        ),
      ], null);

  @override
  Future<AdminPage<AdminAuditEvent>> listAdminAuditEvents(
    String token, {
    String? before,
    int limit = 50,
  }) async =>
      AdminPage<AdminAuditEvent>(<AdminAuditEvent>[
        AdminAuditEvent(
          id: 1,
          eventType: 'account.status.updated',
          actorAccountId: 'acct_owner',
          metadata: const <String, String>{
            'status': 'suspended',
            'target_account_id': 'acct_bob',
          },
        ),
      ], null);
}

Future<AppState> _adminState(PhotoEnv env) async {
  final state = env.own(plainState(role: 'owner', api: _AdminApi()));
  env.listenables.add(state);
  return state;
}

/// Backups of other devices, as the K1 screens' own tests fake them.
class _BackupCrypto extends K0Crypto
    implements BackupSealCryptoService, BackupOpenCryptoService {
  @override
  int get k1BackupMaxPlaintextBytes => 1 << 20;

  @override
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) async =>
      Uint8List.fromList(<int>[1, 2, 3]);

  @override
  BackupHeaderInfo peekK1Backup(Uint8List prefix) => throw UnimplementedError();

  @override
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) async =>
      throw UnimplementedError();
}

class _BackupApi extends K0Api {
  _BackupApi(super.server);

  @override
  Future<List<Map<String, Object?>>> listBackups(
    String token, {
    int limit = 100,
  }) async =>
      <Map<String, Object?>>[
        <String, Object?>{
          'id': 'backup_a',
          'device_id': 'dev_src',
          'device_name': 'Old phone',
          'device_revoked': true,
          'kind': 1,
          'ciphertext_sha256': 'a' * 64,
          'size_bytes': 10,
          'created_at': '2026-11-08T09:00:00Z',
          'counter': 2,
          'rk_id': base64.encode(List<int>.filled(16, 0xB2)),
          'superseded': false,
        },
        <String, Object?>{
          'id': 'backup_prev',
          'device_id': 'dev_spare',
          'device_name': 'Spare tablet',
          'device_revoked': false,
          'kind': 1,
          'ciphertext_sha256': 'b' * 64,
          'size_bytes': 10,
          'created_at': '2026-11-07T09:00:00Z',
          'counter': 1,
          'rk_id': base64.encode(List<int>.filled(16, 0xB2)),
          'superseded': true,
        },
      ];
}

AppState _backupState(PhotoEnv env) {
  final server = K0Server()
    ..status = RecoveryKeyStatus(
      available: true,
      configured: true,
      rkId: Uint8List.fromList(List<int>.filled(16, 0xB2)),
    );
  final state = env.own(
    k0App(server, MemoryLocalStore(), _BackupCrypto())
      ..session = k0SignedIn
      ..api = _BackupApi(server),
  )
    ..k1DesktopTimerEnabled = false
    ..recoveryKeyStatus = server.status;
  env.listenables.add(state);
  return state;
}

final List<PhotoScreen> _settingsScreens = <PhotoScreen>[
  PhotoScreen.direct('settings_member', 'SettingsScreen', (env) async {
    final state = await _rich(env, role: 'member');
    return SettingsScreen(state: state);
  }),
  PhotoScreen.direct('linked_devices', 'LinkedDevicesScreen', (env) async {
    return LinkedDevicesScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('profile', 'ProfileScreen', (env) async {
    return ProfileScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('profile_edit_account', 'ProfileEditScreen', (env) async {
    return ProfileEditScreen.account(state: await _rich(env));
  }),
  PhotoScreen.direct('profile_edit_group', 'ProfileEditScreen', (env) async {
    return ProfileEditScreen.group(
      state: await _rich(env),
      conversationId: 'conv_design',
    );
  }),
  PhotoScreen.direct('invite', 'InviteScreen', (env) async {
    return InviteScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('device_link', 'DeviceLinkScreen', (env) async {
    final state = await _rich(env);
    state.activeDeviceLink = DeviceLinkV3View(
      id: 'dl_1',
      state: 'claimed',
      verificationCode: '24681357',
      claimedDeviceName: 'Linked pixel',
      expiresAt: DateTime.utc(2030),
    );
    return DeviceLinkScreen(state: state);
  }),
  PhotoScreen.direct('blocked_accounts', 'BlockedAccountsScreen', (env) async {
    return BlockedAccountsScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('recovery_key', 'RecoveryKeyScreen', (env) async {
    return RecoveryKeyScreen(state: env.own(_k0State(K0Server())));
  }),
  PhotoScreen.direct('recovery_key_shown', 'RecoveryKeyScreen', (env) async {
    return RecoveryKeyScreen(state: env.own(_k0State(K0Server())));
  }, open: (tester, _) async {
    await _tap(tester, find.text('Create a recovery key'));
  }),
  PhotoScreen.direct('auto_backup', 'AutoBackupScreen', (env) async {
    return AutoBackupScreen(state: _backupState(env), isPhone: true);
  }),
  PhotoScreen.direct('auto_backup_key_dialog', 'RecoveryKeyTypeDialog',
      (env) async {
    return const Scaffold(body: RecoveryKeyTypeDialog());
  }),
  PhotoScreen.direct('k1_restore', 'K1RestoreScreen', (env) async {
    return K1RestoreScreen(state: _backupState(env));
  }),
  PhotoScreen.direct('passkeys', 'PasskeysScreen', (env) async {
    final h = PkHarness();
    await h.enrolled();
    await env.tester.runAsync(() async {
      await h.state.signInWithPasskey(pkOrigin);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    addTearDown(h.dispose);
    h.api.records = <PasskeyRecord>[
      PasskeyRecord(
        id: 'pk_1',
        name: 'Work phone',
        createdAt: DateTime.utc(2026, 11, 1),
        synced: true,
      ),
    ];
    env.listenables.add(h.state);
    return PasskeysScreen(state: h.state);
  }),
  PhotoScreen.direct('sealed_key', 'SealedKeyScreen', (env) async {
    return SealedKeyScreen(state: await _rich(env));
  }),
  PhotoScreen.direct('accounts', 'AccountsScreen', (env) async {
    final states = <String, _AccountState>{};
    final host = AccountHost(
      registryStore: AccountRegistryStore(storage: MemorySlotKeyValue()),
      eraser: _NoIoEraser(),
      primaryNamespace: '',
      build: (ns) async {
        final state = states[ns] = _AccountState();
        return AccountRuntime(
          namespace: ns,
          state: state,
          closeStore: () async {},
        );
      },
    );
    Future<void> settle() => env.realTime(80);
    await env.tester.runAsync(host.start);
    (host.runtime!.state as _AccountState).signInAs('one', 'https://a.example');
    await settle();
    await env.tester.runAsync(() => host.beginAdd());
    await settle();
    (host.runtime!.state as _AccountState).signInAs('two', 'https://b.example');
    await settle();
    await env.tester.runAsync(() => host.idle());
    await env.tester.runAsync(() => host.switchTo(''));
    await settle();
    addTearDown(host.dispose);
    env.listenables.add(host);
    return AccountsScreen(host: host);
  }),
  PhotoScreen.direct('admin', 'AdminScreen', (env) async {
    return AdminScreen(
      state: await _adminState(env),
      reauthenticate: (_) async => true,
    );
  }),
  PhotoScreen.direct('admin_account', '_AdminAccountPage', (env) async {
    return AdminScreen(
      state: await _adminState(env),
      reauthenticate: (_) async => true,
    );
  }, open: (tester, _) async {
    await _tap(tester, find.text('@bob'));
  }),
  PhotoScreen.direct('reauth_dialog', '_PasswordDialog', (env) async {
    await _rich(env);
    return _host();
  }, open: (tester, env) async {
    await _showAfterFrame(
      tester,
      (context) => confirmPasswordForRecentAuth(context, env.state!),
    );
  }),
];

// ---------------------------------------------------------------------------
// reports

class _ReportCrypto extends TestOnlyCryptoService
    implements ReportCryptoService {
  @override
  Future<Uint8List> generateReportKeySeed() async =>
      Uint8List.fromList(List<int>.filled(32, 1));

  @override
  Future<Uint8List> reportPublicKey(Uint8List seed) async =>
      Uint8List.fromList(seed);

  @override
  Future<Uint8List> sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  }) async =>
      Uint8List.fromList(<int>[...recipientPublicKey, ...plaintext]);

  @override
  Future<Uint8List> openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  }) async =>
      Uint8List.fromList(sealed.sublist(32));

  @override
  Future<Uint8List> frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  }) async =>
      Uint8List.fromList(List<int>.filled(32, 4));
}

class _ReportApi extends ApiClient {
  _ReportApi() : super(baseUrl: 'https://example.test');

  List<ReportInboxRecipient> recipients = <ReportInboxRecipient>[
    ReportInboxRecipient(
      inboxId: 'acct_owner',
      publicKey: List<int>.filled(32, 0xab),
      keyRev: 1,
    ),
  ];

  @override
  Future<ReportInbox> getReportInbox(
    String token,
    String conversationId,
  ) async =>
      ReportInbox(kind: 'instance_owner', recipients: recipients);

  @override
  Future<ReportInboxRecipient?> getOwnReportKey(String token) async => null;

  @override
  Future<List<ReportCopyRow>> listOwnerReports(
    String token, {
    String? afterId,
    int limit = 50,
  }) async =>
      const <ReportCopyRow>[];
}

AppState _reportState(PhotoEnv env, {required String role}) {
  final api = _ReportApi();
  final state = env.own(
    AppState(
      apiClientFactory: (_) => api,
      cryptoService: _ReportCrypto() as CryptoService,
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => PhotoSync(),
      reportSeedStore: MemoryReportSeedStore(),
    )
      ..api = api
      ..session = Session(
        baseUrl: 'https://example.test',
        token: 'acct_me',
        accountId: 'acct_me',
        deviceId: 'dev_current',
        username: 'me',
        role: role,
      ),
  );
  env.listenables.add(state);
  return state;
}

final List<PhotoScreen> _reportScreens = <PhotoScreen>[
  PhotoScreen.direct('report_message', 'ReportMessageScreen', (env) async {
    return ReportMessageScreen(
      state: _reportState(env, role: 'member'),
      conversationId: 'conv_1',
      messageKey: 'dev_sender:a1',
    );
  }),
  PhotoScreen.direct('owner_reports', 'OwnerReportsScreen', (env) async {
    return OwnerReportsScreen(
      state: _reportState(env, role: 'owner'),
      reauthenticate: (_) async => true,
    );
  }),
  PhotoScreen.direct('owner_report_detail', 'OwnerReportDetailScreen',
      (env) async {
    final state = _reportState(env, role: 'owner')
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', title: 'Team'),
      ];
    return OwnerReportDetailScreen(
      service: state.reportsService!,
      state: state,
      report: OpenedReport(
        ReportCopyRow(
          id: 'row_1',
          reportId: 'rep_1',
          inboxKind: 'instance_owner',
          inboxId: 'acct_me',
          keyRev: 1,
          recipientPublicKey: List<int>.filled(32, 1),
          conversationId: 'conv_1',
          reporterAccountId: 'acct_reporter',
          sealed: List<int>.filled(40, 2),
          createdAt: DateTime.utc(2026, 11, 7),
        ),
        body: ReportBody(
          envelopeId: 'env_1',
          conversationId: 'conv_1',
          senderDeviceId: 'dev_sender',
          actionId: 'a1',
          payload:
              utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
          frankKey: List<int>.filled(32, 7),
        ),
        text: 'the exact words',
      ),
    );
  }),
];

/// Every entry, in the order the harness runs them.
final List<PhotoScreen> photoScreens = <PhotoScreen>[
  ..._shellScreens,
  ..._authScreens,
  ..._callScreens,
  ..._searchScreens,
  ..._chatScreens,
  ..._communityScreens,
  ..._settingsScreens,
  ..._reportScreens,
];
