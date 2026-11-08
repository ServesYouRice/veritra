import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/profile_models.dart';
import 'package:private_messenger/core/profile_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/settings/profile_edit_screen.dart';
import 'package:private_messenger/features/settings/profile_screen.dart';
import 'package:private_messenger/core/profile_photo.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/photo_avatar.dart';

import 'native_test_env.dart';
import 'test_crypto_service.dart';

/// W11 screens: the editors, and a shared name or photo shown wherever a
/// person or a group appears, with the username as the fallback.
const ana = 'acct_11111111111111111111111111111111';
const bob = 'acct_22222222222222222222222222222222';
const grp = 'conv_55555555555555555555555555555555';

class _NoBindings implements NativeCryptoBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unused in a display test');
}

class _Server implements ProfileApi {
  final Map<String, (int, String, Uint8List)> rows = {};
  @override
  Future<ProfileFetch> fetch(String kind, String subjectId,
          {int? ifNoneMatchVersion}) async =>
      throw ApiException(404, '');
  @override
  Future<int> put(String kind, String subjectId, Uint8List blob,
      {required String keyId, int? ifMatchVersion}) async {
    final next = (rows['$kind/$subjectId']?.$1 ?? 0) + 1;
    rows['$kind/$subjectId'] = (next, keyId, blob);
    return next;
  }

  @override
  Future<List<ProfileVersion>> versions(
          {List<String> accountIds = const [],
          List<String> conversationIds = const []}) async =>
      const [];
}

class _FakeSync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() => _events.close();
}

AppState _state({ProfileService? profiles}) => AppState(
      apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSync(),
    )
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: ana,
        deviceId: 'dev_current',
        username: 'ana',
        role: 'member',
      )
      ..profiles = profiles;

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<ProfileService> _service(
  MemoryLocalStore store, {
  ProfileApi? api,
  ProfileRecordCodec? codec,
}) async {
  final service = ProfileService(
    store: store,
    codec: codec ?? ProfileRecordCodec(_NoBindings()),
    api: api ?? _Server(),
    accountId: ana,
    sendKey: (_, __, ___) async => true,
    postableConversationIds: () => const [grp],
    coMemberAccountIds: () => null,
  );
  await service.load();
  return service;
}

Future<Uint8List> _pngBytes(int side) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..color = const ui.Color(0xff3366cc));
  final image = await recorder.endRecording().toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Lets real asynchronous work (the image engine) finish while the fake
/// clock stays under the test's control, until [done] holds.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 40 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final skip = nativeCryptoSkip();

  group('display', () {
    late MemoryLocalStore store;
    setUp(() => store = MemoryLocalStore());

    Future<void> shared(String kind, String id, String? name,
        {Uint8List? photo}) async {
      await store.saveProfile(StoredProfile(
          kind: kind,
          subjectId: id,
          serverVersion: 1,
          keyId: '0' * 32,
          revision: 1,
          name: name,
          photoPng: photo,
          fetchedAt: 1));
    }

    final dm = Conversation(
        id: 'conv_dm', kind: 'dm', peerAccountId: bob, peerUsername: 'bob');
    final group = Conversation(id: grp, kind: 'group', title: 'Old title');

    testWidgets('a DM shows the shared name, else the username',
        (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Text(conversationTitle(context.l10n, dm)),
      )));
      expect(find.text('@bob'), findsOneWidget);
      await shared('account', bob, 'Bobby');
      final service = await _service(store);
      await tester.pumpWidget(_app(Builder(
        builder: (context) =>
            Text(conversationTitle(context.l10n, dm, profiles: service)),
      )));
      expect(find.text('Bobby'), findsOneWidget);
    });

    testWidgets('a group shows its shared name over the old server title',
        (tester) async {
      await shared('conversation', grp, 'Walkers');
      final service = await _service(store);
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Column(children: [
          Text(conversationTitle(context.l10n, group)),
          Text(conversationTitle(context.l10n, group, profiles: service)),
        ]),
      )));
      expect(find.text('Old title'), findsOneWidget);
      expect(find.text('Walkers'), findsOneWidget);
    });

    testWidgets('a removed profile falls back to the username', (tester) async {
      await shared('account', bob, null);
      final service = await _service(store);
      await tester.pumpWidget(_app(Builder(
        builder: (context) =>
            Text(conversationTitle(context.l10n, dm, profiles: service)),
      )));
      expect(find.text('@bob'), findsOneWidget);
    });

    testWidgets('a photo is drawn, and a broken one shows the initials',
        (tester) async {
      final good = await tester.runAsync(() => _pngBytes(16));
      await shared('account', bob, 'Bobby', photo: good);
      var service = await _service(store);
      await tester.pumpWidget(_app(Builder(
        builder: (context) =>
            conversationAvatar(context, dm, profiles: service, radius: 20),
      )));
      expect(find.byType(PhotoAvatar), findsOneWidget);

      await shared('account', bob, 'Bobby',
          photo: Uint8List.fromList(List.filled(40, 7)));
      service = await _service(store);
      await tester.pumpWidget(_app(Builder(
        builder: (context) =>
            conversationAvatar(context, dm, profiles: service, radius: 20),
      )));
      await tester.pump();
      await tester.pump();
      expect(find.text('BO'), findsOneWidget);
    });

    testWidgets('the profile screen offers the editor only with profiles',
        (tester) async {
      await tester.pumpWidget(_app(ProfileScreen(state: _state())));
      expect(find.byKey(const Key('profile-edit-tile')), findsNothing);
      final service = await _service(store);
      await tester
          .pumpWidget(_app(ProfileScreen(state: _state(profiles: service))));
      expect(find.byKey(const Key('profile-edit-tile')), findsOneWidget);
    });

    testWidgets('the profile screen shows the shared name above the username',
        (tester) async {
      await shared('account', ana, 'Ana Banana');
      final service = await _service(store);
      await tester
          .pumpWidget(_app(ProfileScreen(state: _state(profiles: service))));
      expect(find.text('Ana Banana'), findsWidgets);
      expect(find.text('@ana'), findsWidgets);
    });
  });

  group('editor', () {
    testWidgets('a name with direction characters never enters the field',
        (tester) async {
      final service = await _service(MemoryLocalStore());
      await tester.pumpWidget(
          _app(ProfileEditScreen.account(state: _state(profiles: service))));
      await tester.enterText(
          find.byKey(const Key('profile-name')), 'A\u202eB\u0007C');
      await tester.pump();
      final field =
          tester.widget<TextField>(find.byKey(const Key('profile-name')));
      expect(field.controller!.text, 'ABC');
    });

    testWidgets('a name longer than the limit is held at the limit',
        (tester) async {
      final service = await _service(MemoryLocalStore());
      await tester.pumpWidget(
          _app(ProfileEditScreen.account(state: _state(profiles: service))));
      await tester.enterText(find.byKey(const Key('profile-name')), 'x' * 100);
      await tester.pump();
      final field =
          tester.widget<TextField>(find.byKey(const Key('profile-name')));
      expect(field.controller!.text.length, profileAccountNameMax);
    });

    testWidgets('a group editor allows a longer name', (tester) async {
      final service = await _service(MemoryLocalStore());
      await tester.pumpWidget(_app(ProfileEditScreen.group(
          state: _state(profiles: service), conversationId: grp)));
      await tester.enterText(find.byKey(const Key('profile-name')), 'x' * 100);
      await tester.pump();
      final field =
          tester.widget<TextField>(find.byKey(const Key('profile-name')));
      expect(field.controller!.text.length, profileConversationNameMax);
      expect(find.text('Group name'), findsOneWidget);
    });

    testWidgets('a picture that cannot be read shows a message',
        (tester) async {
      final service = await _service(MemoryLocalStore());
      await tester.pumpWidget(_app(ProfileEditScreen.account(
        state: _state(profiles: service),
        pickPhoto: () async => Uint8List.fromList([1, 2, 3]),
      )));
      await tester.tap(find.byKey(const Key('profile-photo-choose')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text("That picture can't be used. Try another one."),
          findsOneWidget);
    });

    testWidgets('cancelling the chooser changes nothing', (tester) async {
      final service = await _service(MemoryLocalStore());
      await tester.pumpWidget(_app(ProfileEditScreen.account(
        state: _state(profiles: service),
        pickPhoto: () async => null,
      )));
      await tester.tap(find.byKey(const Key('profile-photo-choose')));
      await tester.pump();
      expect(find.byKey(const Key('profile-photo-remove')), findsNothing);
    });

    testWidgets('choosing then saving uploads an encrypted record',
        skip: skip != false, (tester) async {
      final server = _Server();
      final store = MemoryLocalStore();
      final codec = ProfileRecordCodec(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final service = await _service(store, api: server, codec: codec);
      final png = await tester.runAsync(() => _pngBytes(300));
      final state = _state(profiles: service);
      await tester.pumpWidget(_app(ProfileEditScreen.account(
        state: state,
        pickPhoto: () async => png,
      )));
      await tester.tap(find.byKey(const Key('profile-photo-choose')));
      await _settle(
          tester,
          () => find
              .byKey(const Key('profile-photo-remove'))
              .evaluate()
              .isNotEmpty);
      expect(find.byKey(const Key('profile-photo-remove')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile-name')), '  Ana  ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('profile-save')));
      await _settle(tester, () => server.rows.isNotEmpty);
      await _settle(tester, () => service.own != null);
      final row = server.rows['account/$ana']!;
      expect(row.$3.length, 4 + 8 + 16 + 256 * 1024);
      expect(service.own?.name, 'Ana');
      expect(service.own?.photoPng, isNotNull);
    });

    testWidgets('removing the photo keeps the name', skip: skip != false,
        (tester) async {
      final server = _Server();
      final store = MemoryLocalStore();
      final codec = ProfileRecordCodec(
          NativeCryptoBindings.open(requireNativeCryptoLibrary()));
      final service = await _service(store, api: server, codec: codec);
      final png = await tester.runAsync(() => _pngBytes(300));
      final state = _state(profiles: service);
      final photo = await tester.runAsync(() => prepareProfilePhoto(png!));
      unawaited(service.saveOwnProfile(name: 'Ana', photo: photo));
      await _settle(tester, () => server.rows.isNotEmpty);
      await tester.pumpWidget(_app(ProfileEditScreen.account(state: state)));
      expect(find.byKey(const Key('profile-photo-remove')), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile-photo-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('profile-save')));
      await _settle(tester, () => server.rows['account/$ana']!.$1 == 2);
      expect(service.own?.name, 'Ana');
      expect(service.own?.photoPng, isNull);
      expect(server.rows['account/$ana']!.$1, 2);
    });
  });
}
