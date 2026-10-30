import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/push/wake_worker_bridge.dart';

const name = 'org.veritra.private_messenger/wake_worker';
const channel = MethodChannel(name);
const id = '01234567-0123-4123-8123-0123456789ab';
Map<String, Object> runRequest() => {
      'protocol': 1,
      'permit': id,
      'profile': 'demo',
      'wake_generation': 7,
      'budget_ms': 19000,
      'deadline_epoch_ms': 1790000000000
    };
Future<Object?> nativeCall(String method, Object? args) async {
  final result = Completer<Object?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
          name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall(method, args)), (reply) {
    try {
      result.complete(reply == null
          ? null
          : const StandardMethodCodec().decodeEnvelope(reply));
    } catch (e, s) {
      result.completeError(e, s);
    }
  });
  return result.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformWakeWorkerBridge bridge;
  final calls = <MethodCall>[];
  setUp(() {
    bridge = PlatformWakeWorkerBridge();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'bootstrap' => {
            'protocol': 1,
            'launch': 'background',
            'bound_profile': 'demo',
            'ui_attached': false,
            'native_silent': true,
            'can_opt_in': false
          },
        'install' => {
            'protocol': 1,
            'native_silent': true,
            'worker_attached': true,
            'can_opt_in': false
          },
        'validatePermit' => {'active': true, 'remaining_ms': 15000},
        'presentGenericNotice' => 'shown',
        'uninstall' => true,
        _ => throw MissingPluginException(),
      };
    });
  });
  tearDown(() {
    bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
      'bootstrap is advisory; run result binds permit/profile/generation exactly',
      () async {
    final boot = await bridge.bootstrap();
    expect(boot.launchBackground, true);
    expect(boot.canOptIn, false);
    WakePermit? received;
    expect(
        await bridge.install(
            profile: 'demo',
            onRun: (p) async {
              received = p;
              return WakeOutcome.committed;
            },
            onCancel: (_) async {}),
        true);
    expect(await nativeCall('run', runRequest()), {
      ...runRequest()
        ..remove('budget_ms')
        ..remove('deadline_epoch_ms'),
      'outcome': 'committed'
    });
    expect(received!.budgetMs, 19000);
    final status = await bridge.validatePermit(received!);
    expect(status.active, true);
    expect(status.remainingMs, 15000);
    expect(await bridge.presentGenericNotice(received!, 'a' * 32),
        WakeNoticeResult.shown);
    final notice = calls.last.arguments as Map;
    expect(notice.keys,
        unorderedEquals(['protocol', 'permit', 'profile', 'notice_id']));
  });

  test('single process owner, concurrent run refusal and exact cancellation',
      () async {
    final pending = Completer<WakeOutcome>();
    final cancelled = <WakeCancellation>[];
    await bridge.install(
        profile: 'demo',
        onRun: (_) => pending.future,
        onCancel: (c) async {
          cancelled.add(c);
        });
    final second = PlatformWakeWorkerBridge();
    addTearDown(second.dispose);
    expect(
        await second.install(
            profile: 'demo',
            onRun: (_) async => WakeOutcome.committed,
            onCancel: (_) async {}),
        false);
    final first = nativeCall('run', runRequest());
    await Future<void>.delayed(Duration.zero);
    expect(
        (await nativeCall('run', {
          ...runRequest(),
          'permit': '11234567-0123-4123-8123-0123456789ab'
        }) as Map)['outcome'],
        'unavailable');
    expect(
        await nativeCall('cancel', {
          'protocol': 1,
          'permit': id,
          'profile': 'demo',
          'reason': 'os_stop'
        }),
        true);
    expect(cancelled.single.reason, 'os_stop');
    pending.complete(WakeOutcome.retry);
    expect((await first as Map)['outcome'], 'retry');
    expect(await bridge.uninstall('demo'), true);
  });

  test(
      'malformed native fields and budget never reach worker; errors omit payload',
      () async {
    var executions = 0;
    await bridge.install(
        profile: 'demo',
        onRun: (_) async {
          executions++;
          return WakeOutcome.noChange;
        },
        onCancel: (_) async {});
    for (final args in [
      {...runRequest(), 'budget_ms': 20001},
      {...runRequest(), 'budget_ms': 1.5},
      {...runRequest(), 'wake_generation': 0},
      {...runRequest(), 'profile': 'demo\n'},
      {...runRequest(), 'text': 'sensitive-forbidden'},
      {...runRequest(), 'protocol': 2},
    ]) {
      await expectLater(
          nativeCall('run', args),
          throwsA(isA<PlatformException>().having((e) => e.message, 'message',
              isNot(contains('sensitive-forbidden')))));
    }
    expect(executions, 0);
  });

  test(
      'worker failure is retry; native installation cannot opt subscriptions in',
      () async {
    await bridge.install(
        profile: 'demo',
        onRun: (_) async => throw StateError('private failure'),
        onCancel: (_) async {});
    expect((await nativeCall('run', runRequest()) as Map)['outcome'], 'retry');
    await bridge.uninstall('demo');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (_) async => {
                  'protocol': 1,
                  'native_silent': true,
                  'worker_attached': true,
                  'can_opt_in': true
                });
    await expectLater(
        bridge.install(
            profile: 'demo',
            onRun: (_) async => WakeOutcome.noChange,
            onCancel: (_) async {}),
        throwsFormatException);
  });
  test(
      'UI observer needs no profile and survives unavailable worker installation',
      () async {
    final attachments = <bool>[];
    bridge.observeUiAttachment(attachments.add);
    await nativeCall('uiAttached', {'protocol': 1, 'attached': true});
    expect(attachments, [true]);
    expect((await nativeCall('run', runRequest()) as Map)['outcome'],
        'unavailable');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw MissingPluginException());
    expect(
        await bridge.install(
            profile: 'demo',
            onRun: (_) async => WakeOutcome.committed,
            onCancel: (_) async {}),
        false);
    await nativeCall('uiAttached', {'protocol': 1, 'attached': false});
    expect(attachments, [true, false]);
    expect((await nativeCall('run', runRequest()) as Map)['outcome'],
        'unavailable');
  });
  test('unavailable notification metadata preserves native UI launch facts',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (_) async => {
                  'protocol': 1,
                  'launch': 'ui',
                  'bound_profile': null,
                  'ui_attached': true,
                  'native_silent': false,
                  'can_opt_in': false
                });
    final bootstrap = await bridge.bootstrap();
    expect(bootstrap.launchBackground, false);
    expect(bootstrap.uiAttached, true);
    expect(bootstrap.boundProfile, isNull);
    expect(bootstrap.nativeSilent, false);
    expect(bootstrap.canOptIn, false);
  });
}
