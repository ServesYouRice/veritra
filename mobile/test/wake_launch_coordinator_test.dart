import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/push/wake_launch_coordinator.dart';
import 'package:private_messenger/push/wake_worker_bridge.dart';

class _Bridge extends PlatformWakeWorkerBridge {
  _Bridge(this.response);
  final Future<WakeBootstrap> response;
  void Function(bool)? attachment;
  @override
  Future<WakeBootstrap> bootstrap() => response;
  @override
  void observeUiAttachment(void Function(bool) observer) =>
      attachment = observer;
}

WakeBootstrap background({String? profile = 'demo'}) => WakeBootstrap(
    launchBackground: true,
    boundProfile: profile,
    uiAttached: false,
    nativeSilent: true,
    canOptIn: false);

void main() {
  test('unknown background profile cannot construct storage or crypto',
      () async {
    for (final profile in [null, 'different']) {
      final bridge = _Bridge(Future.value(background(profile: profile)));
      var ui = 0, bg = 0;
      final gate = WakeLaunchCoordinator(
          bridge: bridge,
          profile: 'demo',
          onUi: () async {
            ui++;
          },
          onBackground: () async {
            bg++;
          });
      await gate.start();
      expect(ui, 0);
      expect(bg, 0);
      bridge.attachment!(true);
      await Future<void>.delayed(Duration.zero);
      expect(ui, 1);
      expect(bg, 0);
    }
  });

  test('release without a background crypto callback stays quiet until UI',
      () async {
    final bridge = _Bridge(Future.value(background(profile: 'release')));
    var ui = 0;
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'release',
        onUi: () async {
          ui++;
        });
    await gate.start();
    expect(ui, 0);
    bridge.attachment!(true);
    bridge.attachment!(true);
    await Future<void>.delayed(Duration.zero);
    expect(ui, 1);
  });

  test('UI attachment cancels before draining pending background setup',
      () async {
    final bridge = _Bridge(Future.value(background()));
    final entered = Completer<void>(), release = Completer<void>();
    final events = <String>[];
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'demo',
        onBackground: () async {
          events.add('background');
          entered.complete();
          await release.future;
        },
        beforeUi: () async {
          events.add('cancel');
        },
        onUi: () async {
          events.add('ui');
        });
    final start = gate.start();
    await entered.future;
    bridge.attachment!(true);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['background', 'cancel']);
    release.complete();
    await start;
    await Future<void>.delayed(Duration.zero);
    expect(events, ['background', 'cancel', 'cancel', 'ui']);
  });

  test('UI attachment during bootstrap cannot start a second owner', () async {
    final bootstrap = Completer<WakeBootstrap>();
    final bridge = _Bridge(bootstrap.future);
    var ui = 0, bg = 0;
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'demo',
        onUi: () async {
          ui++;
        },
        onBackground: () async {
          bg++;
        });
    final start = gate.start();
    bridge.attachment!(true);
    bootstrap.complete(background());
    await start;
    await gate.start();
    expect(ui, 1);
    expect(bg, 0);
  });

  test('malformed bootstrap never infers foreground permission', () async {
    final bridge = _Bridge(Future.error(const FormatException('protocol')));
    var ui = 0, bg = 0;
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'demo',
        onUi: () async {
          ui++;
        },
        onBackground: () async {
          bg++;
        });
    await gate.start();
    expect(ui, 0);
    expect(bg, 0);
    bridge.attachment!(true);
    await Future<void>.delayed(Duration.zero);
    expect(ui, 1);
  });

  test('late setup owner is cancelled before UI can use the shared state',
      () async {
    final bridge = _Bridge(Future.value(background()));
    final entered = Completer<void>(), release = Completer<void>();
    var activeWorker = false, ui = false;
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'demo',
        onBackground: () async {
          entered.complete();
          await release.future;
          activeWorker = true;
        },
        beforeUi: () async {
          activeWorker = false;
        },
        onUi: () async {
          expect(activeWorker, isFalse);
          ui = true;
        });
    final started = gate.start();
    await entered.future;
    bridge.attachment!(true);
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await started;
    await Future<void>.delayed(Duration.zero);
    expect(ui, isTrue);
  });

  test('latest detach event overrides a stale attached bootstrap snapshot',
      () async {
    final response = Completer<WakeBootstrap>();
    final bridge = _Bridge(response.future);
    var ui = 0, bg = 0;
    final gate = WakeLaunchCoordinator(
        bridge: bridge,
        profile: 'demo',
        onUi: () async {
          ui++;
        },
        onBackground: () async {
          bg++;
        });
    final started = gate.start();
    bridge.attachment!(false);
    response.complete(const WakeBootstrap(
        launchBackground: true,
        boundProfile: 'demo',
        uiAttached: true,
        nativeSilent: true,
        canOptIn: false));
    await started;
    expect(ui, 0);
    expect(bg, 1);
  });
}
