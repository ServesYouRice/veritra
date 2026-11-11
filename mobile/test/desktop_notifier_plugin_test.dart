// PluginDesktopNotifier asks whether a notification is still wanted after its
// asynchronous setup (which is a real platform call on Windows), so a sign-out
// during setup shows nothing (TASK-061). The real local_notifier plugin runs;
// only its method channel is replaced.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/desktop/desktop_shell.dart';
import 'package:private_messenger/desktop/message_notifications.dart';

const _channel = MethodChannel('local_notifier');

class _DelayedPreferences implements NotificationSettingsStore {
  final result = Completer<bool?>();
  @override
  Future<bool?> loadHidePreview() => result.future;
  @override
  Future<void> saveHidePreview(bool value) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return call.method == 'setup' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('a preference read finishing after teardown stays silent', () async {
    final store = _DelayedPreferences();
    final settings = NotificationSettings(store);
    var changes = 0;
    settings.addListener(() => changes++);
    final loading = settings.load();
    settings.dispose();
    store.result.complete(true);
    await loading;
    expect(changes, 0);
  });

  test('a notification that is no longer wanted is not shown', () async {
    final notifier = PluginDesktopNotifier(appName: 'Veritra');
    await notifier.show(
      title: 'Veritra',
      body: 'secret words',
      stillWanted: () => false,
    );
    expect(calls, isNot(contains('notify')));
  });

  test('the check runs after setup, before the notification goes out',
      () async {
    final notifier = PluginDesktopNotifier(appName: 'Veritra');
    var asked = 0;
    await notifier.show(
      title: 'Veritra',
      body: 'secret words',
      stillWanted: () {
        asked++;
        return true;
      },
    );
    expect(asked, 1);
    expect(calls, contains('notify'));
  });

  test('a notification with no check is shown', () async {
    final notifier = PluginDesktopNotifier(appName: 'Veritra');
    await notifier.show(title: 'Veritra', body: 'two');
    expect(calls, contains('notify'));
  });

  test('leaving an account closes its notices and refuses new ones', () async {
    final notifier = PluginDesktopNotifier(appName: 'Veritra');
    await notifier.show(title: 'Veritra', body: 'old account');
    await notifier.clear();
    expect(calls, contains('close'));
    calls.clear();
    await notifier.show(title: 'Veritra', body: 'late notice');
    expect(calls, isNot(contains('notify')));
  });

  test('leaving during notification setup drops the pending notice', () async {
    final setup = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return call.method == 'setup' ? setup.future : null;
    });
    final notifier = PluginDesktopNotifier(appName: 'Veritra');
    // show() is now suspended in its setup. On Windows that is the 'setup'
    // channel call, held open by [setup]; elsewhere local_notifier sets up
    // without a channel call, so no extra turn may run before clear() or the
    // notice would already be out.
    final pending = notifier.show(title: 'Veritra', body: 'old account');
    await notifier.clear();
    setup.complete(true);
    await pending;
    expect(calls, isNot(contains('notify')));
  });
}
