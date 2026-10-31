// quotedPreview cuts long bodies at 80 user-perceived characters, never in the
// middle of a surrogate pair or an emoji sequence (TASK-068).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/chat_screen.dart'
    show quotedPreview;
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

LocalMessage _row(String body) => LocalMessage(
      key: 'k',
      conversationId: 'conv',
      senderAccountId: 'acct',
      senderDeviceId: 'dev',
      kind: LocalMessageKind.text,
      body: body,
      createdAt: 0,
      state: LocalMessageState.received,
    );

/// Whether [text] is well-formed UTF-16: every surrogate has its partner.
bool _wellFormed(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final high = unit >= 0xd800 && unit <= 0xdbff;
    final low = unit >= 0xdc00 && unit <= 0xdfff;
    if (high) {
      if (i + 1 >= units.length) return false;
      final next = units[i + 1];
      if (next < 0xdc00 || next > 0xdfff) return false;
      i++;
    } else if (low) {
      return false;
    }
  }
  return true;
}

void main() {
  final l10n = englishL10n;
  const smile = '\u{1F600}'; // two UTF-16 units
  // One grapheme: four people joined by zero-width joiners.
  final family = String.fromCharCodes(
      <int>[0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466]);

  test('a short body is quoted as is', () {
    expect(quotedPreview(l10n, _row('hello   there\n friend')),
        'hello there friend');
    expect(quotedPreview(l10n, _row('x' * 80)), 'x' * 80);
  });

  test('a long body is cut at 80 characters with an ellipsis', () {
    expect(quotedPreview(l10n, _row('x' * 81)), '${'x' * 80}…');
  });

  test('a cut inside a surrogate pair does not leave half of it', () {
    // 79 letters, then emoji of two units each: unit 80 is the high
    // surrogate of the first.
    final preview = quotedPreview(l10n, _row('${'x' * 79}${smile * 5}'));
    expect(_wellFormed(preview), isTrue, reason: 'lone surrogate in $preview');
    expect(preview, '${'x' * 79}$smile…');
  });

  test('a body of 100 astral characters keeps 80 whole ones', () {
    final preview = quotedPreview(l10n, _row(smile * 100));
    expect(_wellFormed(preview), isTrue);
    expect(preview, '${smile * 80}…');
  });

  test('an emoji sequence is not split', () {
    final preview = quotedPreview(l10n, _row('${'x' * 79}$family${'y' * 20}'));
    expect(_wellFormed(preview), isTrue);
    expect(preview, '${'x' * 79}$family…');
  });

  test('combining marks stay with their letter', () {
    const accented = 'é'; // e + combining acute: one character
    final preview = quotedPreview(l10n, _row('${'x' * 79}${accented * 5}'));
    expect(preview, '${'x' * 79}$accented…');
  });
}
