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
  FakeControls({this.canShareScreen = true});
  @override
  bool micMuted = false;
  @override
  bool sharingScreen = false;
  @override
  final bool canShareScreen;

  @override
  Future<void> setMicMuted(bool muted) async {
    micMuted = muted;
    notifyListeners();
  }

  @override
  Future<void> setSharingScreen(bool on) async {
    sharingScreen = on;
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
    await tester.pumpWidget(_app(RoomScreen(engine: a.engine, nameFor: name)));
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
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(a.api.leaves, 1);
    expect(a.keys.keys, isEmpty);
  });

  testWidgets('a server seat that is not in the call group is not shown',
      (tester) async {
    final a = await activePair(tester);
    server.seats['acct_z/dev_z'] =
        const RoomSeat(deviceId: 'dev_z', accountId: 'acct_z', inGroup: false);
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
        _app(RoomScreen(engine: a.engine, nameFor: name, controls: controls)));
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
        _app(RoomScreen(engine: a.engine, nameFor: name, controls: noShare)));
    await tester.pump();
    expect(find.byKey(const Key('room-mute')), findsOneWidget);
    expect(find.byKey(const Key('room-share')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });

  testWidgets('a cryptor that is not fail-closed shows the refusal, not a call',
      (tester) async {
    late Device unsafe;
    await tester.runAsync(() async {
      unsafe = Device('a', server, clock, parent,
          settings: const RoomCryptorSettings(sharedKey: true));
      await unsafe.engine.join('conv_1');
    });
    await tester
        .pumpWidget(_app(RoomScreen(engine: unsafe.engine, nameFor: name)));
    await tester.pump();
    expect(
        find.text('This device cannot protect call media, so it did not join.'),
        findsOneWidget);
    expect(find.byKey(const Key('room-member-acct_a/dev_a')), findsNothing);
    expect(server.joins, 0);
  });

  testWidgets('strings exist in Serbian too', (tester) async {
    late Device a;
    await tester.runAsync(() async {
      a = Device('a', server, clock, parent);
      await a.engine.join('conv_1');
      await pump();
    });
    await tester.pumpWidget(_app(RoomScreen(engine: a.engine, nameFor: name),
        locale: const Locale('sr')));
    await tester.pump();
    expect(find.text('Напусти'), findsOneWidget);
    expect(find.text('У позиву'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => a.engine.leave());
  });
}
