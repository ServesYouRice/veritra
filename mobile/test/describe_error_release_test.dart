// In release builds describeError shows only user-facing text: developer
// StateError messages (device-link SAS, transcript checks, call ids) map to
// a generic sentence, while the app's own localized sentences still show.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/l10n/l10n.dart';

void main() {
  final en = englishL10n;

  test('release text hides developer StateError messages', () {
    String release(String message) =>
        describeError(StateError(message), en, false);

    expect(release('Production device-link SAS is not integrated'),
        en.errorActionUnavailable);
    expect(release('Device-link transcript was substituted'), en.errorGeneric);
    expect(release('Device-link verification did not match locally'),
        en.errorGeneric);
    expect(release('Call c_123 ended during setup'), en.errorGeneric);
    expect(release('Production MLS/OpenMLS encryption is not integrated'),
        en.errorEncryptionUnavailable);
  });

  test('debug text keeps the developer detail', () {
    const message = 'Production device-link SAS is not integrated';
    expect(describeError(StateError(message), en, true), message);
  });

  test('the app\'s own localized sentences show in release', () async {
    final sr = await AppLocalizations.delegate.load(const Locale('sr'));
    for (final strings in <AppLocalizations>[en, sr]) {
      for (final message in <String>[
        strings.errorPasswordLoginNeedsLink,
        strings.errorRelinkRequired,
        strings.errorServerNotAllowed('http://chat.example.org'),
      ]) {
        expect(describeError(StateError(message), strings, false), message);
      }
    }
  });
}
