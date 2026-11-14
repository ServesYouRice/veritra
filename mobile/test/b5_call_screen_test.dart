import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_controller.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/calls/call_host.dart';
import 'package:private_messenger/l10n/app_localizations.dart';

import 'call_service_fakes.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('incoming call shows accept and decline', (tester) async {
    // The native WebRTC plugin does not exist in tests: refuse its calls.
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async => throw PlatformException(code: 'none'));
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), null));

    final log = <String>[];
    final api = FakeCallApi(log);
    final incoming = StreamController<IncomingCallSignal>.broadcast();
    late NativeCallService service;
    late CallController controller;
    // Service work runs on real time, outside the widget tester's fake clock.
    await tester.runAsync(() async {
      service = NativeCallService(
          api: api,
          token: 't',
          crypto: FakeCallCrypto(log),
          incoming: incoming.stream,
          media: FakeMediaFactory(log));
      controller =
          CallController(service: service, selfAccountId: 'acc_callee');
      final call = callSession();
      api.server[call.id] = call;
      incoming.add(IncomingCallSignal(call, const <String, Object?>{
        'kind': 'offer',
        'sdp': 'x',
        'sdp_type': 'offer'
      }));
      await Future<void>.delayed(Duration.zero);
    });

    await tester
        .pumpWidget(_app(CallScreen(controller: controller, title: 'Ana')));
    await tester.pump();
    expect(find.byKey(const Key('call-accept')), findsOneWidget);
    expect(find.byKey(const Key('call-decline')), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.byKey(const Key('call-mute')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await service.dispose();
      await incoming.close();
    });
  });

  testWidgets('call controls build above the Navigator (no Overlay)',
      (tester) async {
    final log = <String>[];
    late NativeCallService service;
    late CallController controller;
    await tester.runAsync(() async {
      service = NativeCallService(
          api: FakeCallApi(log),
          token: 't',
          crypto: FakeCallCrypto(log),
          incoming: const Stream<IncomingCallSignal>.empty(),
          media: FakeMediaFactory(log));
      controller =
          CallController(service: service, selfAccountId: 'acc_callee');
    });
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SizedBox(),
      builder: (context, child) => Stack(children: <Widget>[
        child!,
        Positioned.fill(
            child: CallScreen(controller: controller, title: 'Ana')),
      ]),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('call-hangup')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await service.dispose();
    });
  });

  testWidgets('notice card is localized', (tester) async {
    await tester.pumpWidget(_app(
        CallNoticeCard(
            notice: const CallNotice(CallNoticeKind.missed, 'conv_1'),
            title: 'Ana',
            onDismiss: () {}),
        locale: const Locale('sr')));
    expect(find.text('Пропуштен позив: Ana'), findsOneWidget);
  });

  // U6: the call shows the person, every round button has a spoken name and
  // the missed-call card offers Call back.
  testWidgets('call screen shows the avatar; buttons speak; notice calls back',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    late NativeCallService service;
    late CallController controller;
    await tester.runAsync(() async {
      service = NativeCallService(
          api: FakeCallApi(log),
          token: 't',
          crypto: FakeCallCrypto(log),
          incoming: const Stream<IncomingCallSignal>.empty(),
          media: FakeMediaFactory(log));
      controller =
          CallController(service: service, selfAccountId: 'acc_callee');
    });
    await tester.pumpWidget(_app(CallScreen(
        controller: controller,
        title: 'Ana Petrovic',
        avatar: const CircleAvatar(radius: 48, child: Text('AP')))));
    await tester.pump();
    expect(find.text('Ana Petrovic'), findsOneWidget);
    expect(find.byKey(const Key('call-avatar')), findsOneWidget);
    expect(find.text('AP'), findsOneWidget);
    // The name is spoken once: the visible caption is not read again.
    expect(find.bySemanticsLabel('Hang up'), findsOneWidget);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);

    var calledBack = false;
    await tester.pumpWidget(_app(CallNoticeCard(
        notice: const CallNotice(CallNoticeKind.missed, 'conv_1'),
        title: 'Ana Petrovic',
        avatar: const CircleAvatar(child: Text('AP')),
        onCallBack: () => calledBack = true,
        onDismiss: () {})));
    expect(find.text('Missed call from Ana Petrovic'), findsOneWidget);
    expect(find.text('AP'), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-notice-call-back')));
    expect(calledBack, isTrue);

    // Only a missed call offers it.
    await tester.pumpWidget(_app(CallNoticeCard(
        notice: const CallNotice(CallNoticeKind.declined, 'conv_1'),
        title: 'Ana Petrovic',
        onDismiss: () {})));
    expect(find.byKey(const Key('call-notice-call-back')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await service.dispose();
    });
    semantics.dispose();
  });
}
