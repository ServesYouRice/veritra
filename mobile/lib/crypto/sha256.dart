import 'dart:typed_data';

/// SHA-256 (FIPS 180-4) in plain Dart, for one job: the token hashes of the
/// v3 device-link claim (`auth.HashToken`: SHA-256 over the exact canonical
/// token text, as 64 lowercase hex characters). The package this repository
/// does not depend on would be a new dependency; the native library has no
/// such entry point; the inputs are 43-byte tokens.
///
/// Not for secrets that must resist timing analysis; it is used on values
/// that are about to be sent to the server as hashes anyway.
Uint8List sha256(List<int> message) {
  final hash = Uint32List.fromList(_initial);
  final length = message.length;
  // The message, a 0x80 byte, zeros, and the 64-bit big-endian bit length,
  // padded to a multiple of 64 bytes.
  final padded = (length + 9 + 63) & ~63;
  final data = Uint8List(padded)
    ..setRange(0, length, message)
    ..[length] = 0x80;
  final view = ByteData.sublistView(data);
  final bits = length * 8;
  view.setUint32(padded - 8, bits ~/ 0x100000000);
  view.setUint32(padded - 4, bits & 0xffffffff);

  final w = Uint32List(64);
  for (var offset = 0; offset < padded; offset += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = view.getUint32(offset + t * 4);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xffffffff & g);
      final temp1 = (h + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    hash[0] = (hash[0] + a) & 0xffffffff;
    hash[1] = (hash[1] + b) & 0xffffffff;
    hash[2] = (hash[2] + c) & 0xffffffff;
    hash[3] = (hash[3] + d) & 0xffffffff;
    hash[4] = (hash[4] + e) & 0xffffffff;
    hash[5] = (hash[5] + f) & 0xffffffff;
    hash[6] = (hash[6] + g) & 0xffffffff;
    hash[7] = (hash[7] + h) & 0xffffffff;
  }
  final out = ByteData(32);
  for (var index = 0; index < 8; index++) {
    out.setUint32(index * 4, hash[index]);
  }
  return out.buffer.asUint8List();
}

/// [sha256] as 64 lowercase hexadecimal characters.
String sha256Hex(List<int> message) => hexOf(sha256(message));

/// Lowercase hexadecimal text of [bytes].
String hexOf(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

int _rotr(int value, int count) =>
    ((value >> count) | (value << (32 - count))) & 0xffffffff;

const List<int> _initial = <int>[
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
