// PluginDesktopShell.start must not leave the window unable to close when the
// tray cannot be created (TASK-059). The real window_manager and tray_manager
// plugins run here; only their method channels are replaced.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/desktop/desktop_services.dart';
import 'package:private_messenger/desktop/desktop_shell.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'test_crypto_service.dart';

const _windowChannel = MethodChannel('window_manager');
const _trayChannel = MethodChannel('tray_manager');

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// Records every call made on the two plugin channels, in order, and fails
/// the ones named in [failing].
class _Plugins {
  final List<String> calls = <String>[];
  final Set<String> failing = <String>{};

  /// The last value passed to `setPreventClose`, or null if never called.
  bool? get preventClose {
    bool? last;
    for (final call in calls) {
      if (call == 'setPreventClose:true') last = true;
      if (call == 'setPreventClose:false') last = false;
    }
    return last;
  }

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments;
    final name = call.method == 'setPreventClose'
        ? 'setPreventClose:${(args as Map)['isPreventClose']}'
        : call.method;
    calls.add(name);
    if (failing.contains(name)) {
      throw PlatformException(code: 'failed', message: name);
    }
    return null;
  }

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_windowChannel, handle);
    messenger.setMockMethodCallHandler(_trayChannel, handle);
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_windowChannel, null);
    messenger.setMockMethodCallHandler(_trayChannel, null);
  }
}

/// Sends the native "window is closing" event to the Dart side.
Future<void> _closeWindow() async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _windowChannel.name,
    codec.encodeMethodCall(
      const MethodCall('onEvent', <String, Object?>{'eventName': 'close'}),
    ),
    (_) {},
  );
}

Future<void> _start(PluginDesktopShell shell) => shell.start(
      openLabel: 'Open',
      quitLabel: 'Quit',
      tooltip: 'Veritra',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Plugins plugins;

  setUp(() {
    plugins = _Plugins()..install();
  });

  tearDown(() {
    // The plugin managers are process-wide; leave them as found.
    for (final listener in windowManager.listeners) {
      windowManager.removeListener(listener);
    }
    plugins.uninstall();
  });

  // setToolTip is skipped on Linux, so it cannot fail there.
  final traySteps = <String>[
    'setIcon',
    if (!Platform.isLinux) 'setToolTip',
    'setContextMenu',
  ];

  test('a started shell hides the window on close', () async {
    final shell = PluginDesktopShell();
    addTearDown(shell.dispose);
    await _start(shell);
    expect(plugins.preventClose, isTrue);
    expect(windowManager.listeners, contains(shell));
    expect(trayManager.hasListeners, isTrue);

    await _closeWindow();
    expect(plugins.calls, contains('hide'));
  });

  test('the tray is created before closing the window is intercepted',
      () async {
    final shell = PluginDesktopShell();
    addTearDown(shell.dispose);
    await _start(shell);
    final preventClose = plugins.calls.indexOf('setPreventClose:true');
    for (final step in traySteps) {
      expect(plugins.calls.indexOf(step), lessThan(preventClose),
          reason: '$step must come before setPreventClose(true)');
    }
  });

  for (final step in traySteps) {
    test('when $step fails, closing the window still closes the app', () async {
      plugins.failing.add(step);
      final shell = PluginDesktopShell();
      addTearDown(shell.dispose);

      await expectLater(_start(shell), throwsA(isA<PlatformException>()));

      expect(plugins.preventClose, isNot(isTrue),
          reason: 'prevent-close must not stay on');
      expect(windowManager.listeners, isNot(contains(shell)));
      expect(trayManager.hasListeners, isFalse);

      plugins.calls.clear();
      await _closeWindow();
      expect(plugins.calls, isNot(contains('hide')),
          reason: 'the window must not be hidden without a tray');
    });
  }

  test('when setPreventClose fails, nothing is left registered', () async {
    plugins.failing.add('setPreventClose:true');
    final shell = PluginDesktopShell();
    addTearDown(shell.dispose);

    await expectLater(_start(shell), throwsA(isA<PlatformException>()));

    expect(plugins.preventClose, isFalse);
    expect(windowManager.listeners, isNot(contains(shell)));
    expect(trayManager.hasListeners, isFalse);
  });

  test('cleanup that itself fails does not hide the original error', () async {
    plugins.failing.addAll(<String>['setIcon', 'setPreventClose:false']);
    final shell = PluginDesktopShell();
    addTearDown(shell.dispose);

    await expectLater(
      _start(shell),
      throwsA(isA<PlatformException>()
          .having((e) => e.message, 'message', 'setIcon')),
    );
    expect(windowManager.listeners, isNot(contains(shell)));
  });

  group('DesktopServices.startIfSupported', () {
    late AppState state;

    setUp(() {
      state = AppState(
        apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _NoSync(),
      );
    });

    test('returns null and leaves the window closable when the tray fails',
        () async {
      plugins.failing.add('setContextMenu');
      final desktop = await DesktopServices.startIfSupported(state);
      expect(desktop, isNull);
      expect(plugins.preventClose, isNot(isTrue));
      expect(windowManager.hasListeners, isFalse);
      expect(trayManager.hasListeners, isFalse);
    });

    test('returns the services when the tray starts', () async {
      final desktop = await DesktopServices.startIfSupported(state);
      expect(desktop, isNotNull);
      expect(plugins.preventClose, isTrue);
      desktop!.detach();
    });
  });
}
