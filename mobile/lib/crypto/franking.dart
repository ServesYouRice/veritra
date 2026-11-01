import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// C6 franking v1 wire form (`docs/crypto.md`, "Franking v1";
/// docs/designs/C6-reports-franking.md). Pure byte rules, no crypto: the
/// commitment itself is `ReportCryptoService.frankCommit` (ABI 12).
///
/// The canonical payload bytes `P` are the inner JSON exactly as the sender's
/// encoder wrote it without `frank`. The wire JSON is `P` without its final
/// `}`, then [_prefix], the standard padded base64 of the 32-byte key, and
/// [_tail]. Nothing is re-serialized, so `P` is the same bytes for the
/// sender, every receiver and a verifier, whatever JSON library each uses.

/// Franking key (`kf`) length.
const int frankKeyBytes = 32;

/// Commitment (`frank_commit`) length.
const int frankCommitBytes = 32;

const String _frankKey = 'frank';
final Uint8List _prefix = utf8.encode(',"frank":{"k":"');
final Uint8List _tail = utf8.encode('"}}');
const int _keyBase64Length = 44;
final int _suffixLength = _prefix.length + _keyBase64Length + _tail.length;

/// A fresh franking key from the platform CSPRNG.
Uint8List generateFrankKey({Random? random}) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(frankKeyBytes, (_) => source.nextInt(256)),
  );
}

/// The wire JSON for [canonical] carrying [key]. Throws [FormatException]
/// unless [canonical] is a JSON object without a top-level `frank` member
/// and [key] is 32 bytes.
Uint8List frankWireJson(Uint8List canonical, List<int> key) {
  if (key.length != frankKeyBytes ||
      canonical.length < 2 ||
      canonical.last != 0x7d /* } */ ||
      _objectWithoutFrank(canonical) == null) {
    throw const FormatException('invalid franking input');
  }
  final encodedKey = ascii.encode(base64.encode(key));
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(canonical, 0, canonical.length - 1))
    ..add(_prefix)
    ..add(encodedKey)
    ..add(_tail);
  return out.takeBytes();
}

/// What the inner JSON of a decrypted payload says about franking.
sealed class FrankOutcome {
  const FrankOutcome();
}

/// No top-level `frank` member.
final class Unfranked extends FrankOutcome {
  const Unfranked();
}

/// A well-formed `frank` member: [canonical] is `P`, [key] is `kf`.
final class Franked extends FrankOutcome {
  const Franked({required this.canonical, required this.key});

  final Uint8List canonical;
  final Uint8List key;
}

/// A `frank` member that is not in the one fixed form, or JSON that does not
/// parse. Treat the payload as `invalid`, never as unfranked.
final class MalformedFrank extends FrankOutcome {
  const MalformedFrank();
}

/// Splits the inner JSON [json] (the bytes between the `VAP1` header and the
/// padding) into `P` and `kf`. Never throws.
FrankOutcome splitFrank(List<int> json) {
  try {
    final bytes = json is Uint8List ? json : Uint8List.fromList(json);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map) return const MalformedFrank();
    if (!decoded.containsKey(_frankKey)) return const Unfranked();
    if (bytes.length <= _suffixLength + 1) return const MalformedFrank();
    final start = bytes.length - _suffixLength;
    final keyStart = start + _prefix.length;
    final keyEnd = keyStart + _keyBase64Length;
    if (!_equalAt(bytes, start, _prefix) || !_equalAt(bytes, keyEnd, _tail)) {
      return const MalformedFrank();
    }
    final keyText = ascii.decode(
      Uint8List.sublistView(bytes, keyStart, keyEnd),
      allowInvalid: false,
    );
    final key = base64.decode(keyText);
    // One spelling only: standard alphabet, padded, canonical trailing bits.
    if (key.length != frankKeyBytes || base64.encode(key) != keyText) {
      return const MalformedFrank();
    }
    final canonical = Uint8List(start + 1)
      ..setRange(0, start, bytes)
      ..[start] = 0x7d; // }
    // P must stand alone as an object without `frank`. Then the suffix was
    // necessarily the last top-level member, and P's content is exactly the
    // wire content minus `frank`.
    if (_objectWithoutFrank(canonical) == null) return const MalformedFrank();
    return Franked(canonical: canonical, key: Uint8List.fromList(key));
  } catch (_) {
    return const MalformedFrank();
  }
}

/// Compares two commitments in time independent of where they differ.
bool frankCommitEquals(List<int> a, List<int> b) {
  if (a.length != frankCommitBytes || b.length != frankCommitBytes) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < frankCommitBytes; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

Map<Object?, Object?>? _objectWithoutFrank(Uint8List json) {
  try {
    final decoded = jsonDecode(utf8.decode(json, allowMalformed: false));
    if (decoded is! Map || decoded.containsKey(_frankKey)) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

bool _equalAt(Uint8List bytes, int offset, Uint8List expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}
