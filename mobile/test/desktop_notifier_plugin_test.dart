// PluginDesktopNotifier asks whether a notification is still wanted after its
// asynchronous setup (which is a real platform call on Windows), so a sign-out
// during setup shows nothing (TASK-061). The real local_notifier plugin runs;
// only its method channel is replaced.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/desktop/desktop_shell.dart';

const _channel = MethodChannel('local_notifier');

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
}
