// RFC 4648 base32, no padding. Never include the input in errors: it is secret.
const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String encodeDeviceLinkSecret(List<int> secret) {
  if (secret.length != 16) throw const FormatException('Invalid link code');
  var bits = 0;
  var value = 0;
  final out = StringBuffer();
  for (final byte in secret) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_alphabet[(value >> bits) & 31]);
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
  return out.toString();
}

List<int> decodeDeviceLinkSecret(String code) {
  final normalized = code.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (normalized.length != 26) {
    throw const FormatException('Invalid link code');
  }
  var bits = 0;
  var value = 0;
  final out = <int>[];
  for (final char in normalized.split('')) {
    final digit = _alphabet.indexOf(char);
    if (digit < 0) throw const FormatException('Invalid link code');
    value = (value << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((value >> bits) & 255);
    }
    value &= (1 << bits) - 1;
  }
  if (out.length != 16 || value != 0) {
    throw const FormatException('Invalid link code');
  }
  return out;
}
