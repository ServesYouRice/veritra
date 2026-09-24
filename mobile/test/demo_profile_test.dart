import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/main_demo.dart';

void main() {
  test('demo profiles come from --profile and are safe file names', () {
    expect(demoProfileFromArgs(const <String>[]), isNull);
    expect(demoProfileFromArgs(const <String>['--profile', 'bob']), 'bob');
    expect(demoProfileFromArgs(const <String>['--profile=alice2']), 'alice2');
    for (final bad in <List<String>>[
      <String>['--profile'],
      <String>['--profile=../x'],
      <String>['--profile=Bob'],
      <String>['--profile='],
      <String>['--profile=${'a' * 21}'],
    ]) {
      expect(() => demoProfileFromArgs(bad), throwsFormatException,
          reason: bad.join(' '));
    }
  });
}
