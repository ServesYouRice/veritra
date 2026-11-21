import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_ports.dart';
import 'package:private_messenger/features/calls/room_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';

import 'b6_room_fakes.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

class FakeControls extends ChangeNotifier implements RoomMediaControls {
  FakeControls({
    this.canShareScreen = true,
    this.canUseCamera = true,
    this.screenNeedsSource = false,
  });
  @override
  bool micMuted = false;
  @override
  bool sharingScreen = false;
  @override
  bool cameraOn = false;
  @override
  final bool canShareScreen;
  @override
  final bool canUseCamera;
  @override
  final bool screenNeedsSource;
  @override
  bool requestingPermission = false;
  @override
  RoomMediaNotice? notice;
  @override
  List<RoomVideoTile> videoTiles = const [];
  List<ScreenSource> sources = const [];
  String? pickedSource;

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
  Future<List<ScreenSource>> screenSources() async => sources;

  @override
  Future<void> setSharingScreen(bool on, {String? sourceId}) async {
    sharingScreen = on;
    pickedSource = sourceId;
    if (on && screenNeedsSource && sourceId == null) {
      notice = RoomMediaNotice.screenNoSource;
      sharingScreen = false;
    }
    notifyListeners();
  }

  @override
  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  void setRequesting(bool on) {
    requestingPermission = on;
    notifyListeners();
  }
}

String name(String accountId) =>
    accountId.replaceFirst('acct_', '').toUpperCase();

void main() {
  late FakeServer server;
  late FakeClock clock;
  late FakeParent parent;

  setUp(() {
    server = FakeServer('conv_1');
    clock = FakeClock();
    parent = FakeParent([member('a'), member('b')]);
  });

  Future<Device> activePair(WidgetTester tester) async {
    late Device a;
    await tester.runAsync(() async {
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
    return a;
  }

  testWidgets(
    'the roster is the MLS roster, with the end-to-end note and a leave button',
    (tester) async {
      final a = await activePair(tester);
      expect(a.engine.roster.length, 2);
      await tester.pumpWidget(
        _app(RoomScreen(engine: a.engine, nameFor: name)),
      );
      await tester.pump();
      expect(find.text('In the call'), findsOneWidget);
      expect(find.text('2 people'), findsOneWidget);
      expect(find.byKey(const Key('room-member-acct_a/dev_a')), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('B'), findsWidgets);
      expect(find.byKey(const Key('room-e2e-note')), findsOneWidget);
      // No media transport in this build: no mute and no screen share.
      expect(find.byKey(const Key('room-mute')), findsNothing);
      expect(find.byKey(const Key('room-share')), findsNothing);

      await tester.tap(find.byKey(const Key('room-leave')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(a.api.leaves, 1);
      expect(a.keys.keys, isEmpty);
    },
  );

  testWidgets('a server seat that is not in the call group is not shown', (
    tester,
  ) async {
    final a = await activePair(tester);
    server.seats['acct_z/dev_z'] = const RoomSeat(
      deviceId: 'dev_z',
      accountId: 'acct_z',
      inGroup: false,
    );
    await tester.pumpWidget(_app(RoomScreen(engine: a.engine, nameFor: name)));
    await tester.pump();
    expect(find.byKey(const Key('room-member-acct_z/dev_z')), findsNothing);
    expect(find.text('2 people'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets(
    'mute and screen share show only with controls, and iOS-style builds get no share',
    (tester) async {
      final a = await activePair(tester);
      final controls = FakeControls();
      await tester.pumpWidget(
        _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
      );
      await tester.pump();
      expect(find.text('Mute'), findsOneWidget);
      await tester.tap(find.byKey(const Key('room-mute')));
      await tester.pump();
      expect(controls.micMuted, isTrue);
      expect(find.text('Unmute'), findsOneWidget);
      expect(find.text('Share screen'), findsOneWidget);
      await tester.tap(find.byKey(const Key('room-share')));
      await tester.pump();
      expect(controls.sharingScreen, isTrue);
      expect(find.text('Stop sharing'), findsOneWidget);

      final noShare = FakeControls(canShareScreen: false);
      await tester.pumpWidget(
        _app(RoomScreen(engine: a.engine, nameFor: name, controls: noShare)),
      );
      await tester.pump();
      expect(find.byKey(const Key('room-mute')), findsOneWidget);
      expect(find.byKey(const Key('room-share')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => a.engine.leave());
    },
  );

  testWidgets(
    'a cryptor that is not fail-closed shows the refusal, not a call',
    (tester) async {
      late Device unsafe;
      await tester.runAsync(() async {
        unsafe = Device(
          'a',
          server,
          clock,
          parent,
          settings: const RoomCryptorSettings(sharedKey: true),
        );
        await unsafe.engine.join('conv_1');
      });
      await tester.pumpWidget(
        _app(RoomScreen(engine: unsafe.engine, nameFor: name)),
      );
      await tester.pump();
      expect(
        find.text('This device cannot protect call media, so it did not join.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('room-member-acct_a/dev_a')), findsNothing);
      expect(server.joins, 0);
    },
  );

  testWidgets('camera button toggles and a notice can be dismissed', (
    tester,
  ) async {
    final a = await activePair(tester);
    final controls = FakeControls();
    await tester.pumpWidget(
      _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
    );
    await tester.pump();
    expect(find.text('Turn on camera'), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-camera')));
    await tester.pump();
    expect(controls.cameraOn, isTrue);
    expect(find.text('Turn off camera'), findsOneWidget);

    controls.notice = RoomMediaNotice.cameraUnavailable;
    controls.notifyListeners();
    await tester.pump();
    expect(find.text('The camera could not be started.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-notice-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('room-notice')), findsNothing);

    final none = FakeControls(canUseCamera: false);
    await tester.pumpWidget(
      _app(RoomScreen(engine: a.engine, nameFor: name, controls: none)),
    );
    await tester.pump();
    expect(find.byKey(const Key('room-camera')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('every notice has its text, in both languages', (tester) async {
    final a = await activePair(tester);
    final controls = FakeControls();
    const english = {
      RoomMediaNotice.cameraUnavailable: 'The camera could not be started.',
      RoomMediaNotice.screenUnavailable: 'The screen could not be shared.',
      RoomMediaNotice.screenNoSource: 'There is no screen or window to share.',
      RoomMediaNotice.videoRoomFull:
          'This call has too many people for video. Voice only.',
    };
    for (final locale in [const Locale('en'), const Locale('sr')]) {
      for (final entry in english.entries) {
        controls.notice = entry.key;
        await tester.pumpWidget(
          _app(
            RoomScreen(engine: a.engine, nameFor: name, controls: controls),
            locale: locale,
          ),
        );
        await tester.pump();
        final shown = tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('room-notice')),
                matching: find.byType(Text),
              ),
            )
            .data!;
        if (locale.languageCode == 'en') {
          expect(shown, entry.value);
        } else {
          expect(shown, isNot(entry.value));
          expect(shown, isNotEmpty);
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('desktop picks a screen or window by name, then shares it', (
    tester,
  ) async {
    final a = await activePair(tester);
    final controls = FakeControls(screenNeedsSource: true)
      ..sources = const [
        ScreenSource(id: 'screen_0', name: 'Screen 1'),
        ScreenSource(id: 'win_7', name: 'Notes', isWindow: true),
      ];
    await tester.pumpWidget(
      _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-share')));
    await tester.pumpAndSettle();
    expect(find.text('Choose what to share'), findsOneWidget);
    expect(find.text('Screen 1'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-source-win_7')));
    await tester.pumpAndSettle();
    expect(controls.sharingScreen, isTrue);
    expect(controls.pickedSource, 'win_7');
    expect(find.byKey(const Key('room-sharing-note')), findsOneWidget);
    expect(find.text('You are sharing your screen'), findsOneWidget);
    // Stopping needs no picker.
    await tester.tap(find.byKey(const Key('room-share')));
    await tester.pumpAndSettle();
    expect(controls.sharingScreen, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('cancelling the picker shares nothing; no sources says so', (
    tester,
  ) async {
    final a = await activePair(tester);
    final controls = FakeControls(screenNeedsSource: true)
      ..sources = const [ScreenSource(id: 'screen_0', name: 'Screen 1')];
    await tester.pumpWidget(
      _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-share')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(2, 2)); // dismiss the dialog
    await tester.pumpAndSettle();
    expect(controls.sharingScreen, isFalse);
    expect(controls.pickedSource, isNull);

    controls.sources = const [];
    await tester.tap(find.byKey(const Key('room-share')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-source-picker')), findsNothing);
    expect(
      find.text('There is no screen or window to share.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('Android-style share starts at once, with no picker', (
    tester,
  ) async {
    final a = await activePair(tester);
    final controls = FakeControls();
    await tester.pumpWidget(
      _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-share')));
    await tester.pumpAndSettle();
    expect(controls.sharingScreen, isTrue);
    expect(find.byKey(const Key('room-source-picker')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('video tiles go to the builder, labelled by who sent them', (
    tester,
  ) async {
    final a = await activePair(tester);
    final controls = FakeControls()
      ..videoTiles = const [
        RoomVideoTile(id: 'local-camera', slot: 1, stream: 'mine'),
        RoomVideoTile(
          id: 'TR_b_1',
          slot: 1,
          stream: 'cam_b',
          memberId: 'acct_b/dev_b',
        ),
        RoomVideoTile(
          id: 'TR_b_2',
          slot: 2,
          stream: 'scr_b',
          memberId: 'acct_b/dev_b',
        ),
      ];
    final built = <String>[];
    await tester.pumpWidget(
      _app(
        RoomScreen(
          engine: a.engine,
          nameFor: name,
          controls: controls,
          videoTileBuilder: (context, tile) {
            built.add('${tile.id}:${tile.stream}');
            return const ColoredBox(color: Colors.blue);
          },
        ),
      ),
    );
    await tester.pump();
    expect(built, ['local-camera:mine', 'TR_b_1:cam_b', 'TR_b_2:scr_b']);
    expect(find.byKey(const Key('room-videos')), findsOneWidget);
    expect(find.text('You'), findsWidgets);
    expect(find.text('B'), findsWidgets);
    expect(find.text("B's screen"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  group('leaving when the app goes away (O5)', () {
    Future<void> settleLeave(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    testWidgets('a pause leaves the room', (tester) async {
      final a = await activePair(tester);
      await tester.pumpWidget(
        _app(
          RoomScreen(engine: a.engine, nameFor: name, controls: FakeControls()),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settleLeave(tester);
      expect(a.engine.phase, RoomPhase.left);
    });

    testWidgets(
      'an OS permission or consent screen does not: it pauses the app only '
      'while the question is up',
      (tester) async {
        final a = await activePair(tester);
        final controls = FakeControls()..requestingPermission = true;
        await tester.pumpWidget(
          _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await settleLeave(tester);
        expect(a.engine.phase, RoomPhase.active);
        // The person answers and the app comes back: still in the room.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        controls.setRequesting(false);
        await settleLeave(tester);
        expect(a.engine.phase, RoomPhase.active);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => a.engine.leave());
      },
    );

    testWidgets(
      'a person who went home during the question leaves when it ends',
      (tester) async {
        final a = await activePair(tester);
        final controls = FakeControls()..requestingPermission = true;
        await tester.pumpWidget(
          _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)),
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await settleLeave(tester);
        expect(a.engine.phase, RoomPhase.active);
        controls.setRequesting(false);
        await settleLeave(tester);
        expect(a.engine.phase, RoomPhase.left);
      },
    );
  });

  testWidgets('strings exist in Serbian too', (tester) async {
    late Device a;
    await tester.runAsync(() async {
      a = Device('a', server, clock, parent);
      await a.engine.join('conv_1');
      await pump();
    });
    await tester.pumpWidget(
      _app(
        RoomScreen(engine: a.engine, nameFor: name),
        locale: const Locale('sr'),
      ),
    );
    await tester.pump();
    expect(find.text('Напусти'), findsOneWidget);
    expect(find.text('У позиву'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });
}
