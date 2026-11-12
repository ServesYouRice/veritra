import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/c7_history.dart';

/// testing/vectors/c7-move-v1.json, made by testing/vectors/c7-move-v1.py:
/// the 128-byte wrap of a C7 move and the compact move record carrying it.
/// Rust and Go check the same file. A missing vector fails; it never skips.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/c7-move-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  List<Map<String, dynamic>> cases(String name) =>
      (vector[name] as List).cast<Map<String, dynamic>>();

  test('valid wraps decode to their fields and encode back', () {
    for (final c in cases('valid_wraps')) {
      final wrap = C7MoveWrap.decode(hex(c['wrap_hex']));
      expect(wrap.prevEpoch, c['prev_epoch'], reason: c['name'] as String);
      expect(toHex(wrap.prevKey), c['prev_key_hex']);
      expect(utf8.decode(wrap.prevGroupId), c['prev_group_id']);
      expect(wrap.prevCloseEpoch, c['prev_close_epoch']);
      expect(toHex(wrap.encode()), c['wrap_hex']);
    }
  });

  test('random bytes and malformed wraps are no wrap', () {
    for (final c in cases('invalid_wraps')) {
      expect(() => C7MoveWrap.decode(hex(c['wrap_hex'])), throwsFormatException,
          reason: c['name'] as String);
    }
  });

  test('a move record takes only a wrap naming its own old group and epoch',
      () {
    final record = vector['record'] as Map<String, dynamic>;
    final compact = hex(record['compact_hex']);
    expect(compact.length, record['compact_length']);
    final decoded = C7CompactRecord.decode(compact);
    expect(decoded.reason, c7ReasonMove);
    expect(toHex(decoded.encode()), record['compact_hex']);
    expect(utf8.decode(decoded.closeGroupId!), record['close_group_id']);
    final wrap = C7MoveWrap.decodeFor(decoded);
    expect(wrap, isNotNull);
    expect(toHex(wrap!.encode()), record['wrap_hex']);

    C7CompactRecord withWrap(List<int> bytes) => C7CompactRecord(
          seq: decoded.seq,
          prev: decoded.prev,
          mode: decoded.mode,
          reason: decoded.reason,
          closeEpoch: decoded.closeEpoch,
          key: decoded.key,
          sig: decoded.sig,
          closeGroupId: decoded.closeGroupId,
          wrap: bytes,
        );
    for (final c in [...cases('mismatched_wraps'), ...cases('invalid_wraps')]) {
      final bytes = hex(c['wrap_hex']);
      if (bytes.length != c7MoveWrapBytes) continue;
      expect(C7MoveWrap.decodeFor(withWrap(bytes)), isNull,
          reason: c['name'] as String);
    }
  });

  test('encoding refuses what decoding refuses', () {
    C7MoveWrap make({int prevEpoch = 10, List<int>? key, List<int>? group}) =>
        C7MoveWrap(
          prevEpoch: prevEpoch,
          prevKey: key ?? List<int>.filled(32, 7),
          prevGroupId: group ?? utf8.encode('g'),
          prevCloseEpoch: 20,
        );
    expect(make().encode(), hasLength(c7MoveWrapBytes));
    expect(() => make(key: List<int>.filled(32, 0)), throwsFormatException);
    expect(() => make(prevEpoch: 21), throwsFormatException);
    expect(() => make(group: <int>[]), throwsFormatException);
    expect(() => make(group: List<int>.filled(65, 1)), throwsFormatException);
  });
}
