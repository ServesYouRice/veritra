// safeAttachmentName: the name shown in the chat and offered as the save name
// comes from the sender, so it must not spoof an extension or be invalid on
// Windows (TASK-049).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';

void main() {
  test('a right-to-left override cannot make an .exe look like a .pdf', () {
    // Rendered with the override, this reads "invoiceexe.pdf".
    final name = safeAttachmentName('invoice\u202Efdp.exe');
    expect(name, 'invoicefdp.exe');
    expect(name, isNot(contains('\u202E')));
  });

  group('removes', () {
    final removed = <String, List<int>>{
      'C0 controls': <int>[0x00, 0x01, 0x09, 0x0a, 0x0d, 0x1f],
      'DEL': <int>[0x7f],
      'C1 controls': <int>[0x80, 0x85, 0x9f],
      'soft hyphen': <int>[0xad],
      'LRM and RLM': <int>[0x200e, 0x200f],
      'embeddings and overrides': <int>[0x202a, 0x202b, 0x202c, 0x202d, 0x202e],
      'isolates': <int>[0x2066, 0x2067, 0x2068, 0x2069],
      'zero-width characters': <int>[0x200b, 0x200c, 0x200d, 0x2060, 0xfeff],
      'line and paragraph separators': <int>[0x2028, 0x2029],
      'language tag characters': <int>[0xe0001, 0xe0020, 0xe007f],
    };
    for (final entry in removed.entries) {
      test(entry.key, () {
        for (final code in entry.value) {
          final raw = 'ab${String.fromCharCode(code)}cd.txt';
          expect(safeAttachmentName(raw), 'abcd.txt',
              reason: 'U+${code.toRadixString(16)}');
        }
      });
    }

    test('a name made only of such characters falls back', () {
      expect(safeAttachmentName('\u202e\u200b\u0085'), 'attachment');
    });
  });

  group('Windows', () {
    test('invalid characters become underscores', () {
      expect(safeAttachmentName('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
    });

    test('directory parts are still dropped', () {
      expect(safeAttachmentName(r'C:\Users\me\secret.txt'), 'secret.txt');
      expect(safeAttachmentName('../../etc/passwd'), 'passwd');
    });

    test('trailing dots and spaces are removed', () {
      expect(safeAttachmentName('report.pdf.'), 'report.pdf');
      expect(safeAttachmentName('report.pdf. . '), 'report.pdf');
      expect(safeAttachmentName('report '), 'report');
      expect(safeAttachmentName('. . '), 'attachment');
    });

    test('a long name does not end in a dot or space after truncation', () {
      final name = safeAttachmentName('${'x' * 118} .${'y' * 20}');
      expect(name.length, lessThanOrEqualTo(120));
      expect(name, isNot(endsWith(' ')));
      expect(name, isNot(endsWith('.')));
    });

    test('reserved device names are prefixed', () {
      for (final reserved in <String>[
        'CON',
        'prn',
        'Aux',
        'NUL',
        'COM1',
        'com9',
        'LPT1',
        'lpt9',
      ]) {
        expect(safeAttachmentName(reserved), '_$reserved');
        expect(safeAttachmentName('$reserved.txt'), '_$reserved.txt');
        expect(safeAttachmentName('$reserved.tar.gz'), '_$reserved.tar.gz');
      }
      // Windows ignores trailing spaces before the extension.
      expect(safeAttachmentName('nul .txt'), '_nul .txt');
    });

    test('names that only start like a device name are kept', () {
      for (final fine in <String>[
        'CONSOLE.txt',
        'COM10',
        'COM0.txt',
        'LPT.txt',
        'null.txt',
        'xcon.txt',
        'a.con',
      ]) {
        expect(safeAttachmentName(fine), fine);
      }
    });
  });

  test('ordinary names, including non-Latin ones, are unchanged', () {
    for (final name in <String>[
      'photo.jpg',
      'Годишњи извештај.pdf',
      '日本語のファイル.docx',
      'my file (1).tar.gz',
      'naïve café.txt',
    ]) {
      expect(safeAttachmentName(name), name);
    }
  });

  test('the existing limits still hold', () {
    expect(safeAttachmentName(''), 'attachment');
    expect(safeAttachmentName('...'), 'attachment');
    expect(safeAttachmentName('.hidden'), 'hidden');
    expect(safeAttachmentName('${'x' * 200}.pdf').length, 120);
    expect(safeAttachmentName('${'x' * 200}.pdf'), endsWith('.pdf'));
    expect(safeAttachmentName('x' * 200).length, 120);
    // An extension longer than 10 characters is not kept.
    expect(safeAttachmentName('${'x' * 200}.abcdefghijkl'), hasLength(120));
  });
}
