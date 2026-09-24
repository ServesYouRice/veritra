import 'api_client.dart';

/// Which server origins this build may talk to.
///
/// Release builds accept HTTPS only. Demo builds (decision D12) additionally
/// accept plain HTTP to the same machine: `localhost`, `127.0.0.0/8` and
/// `::1`. Loopback traffic never leaves the device, so it adds no network
/// exposure; every other host still needs HTTPS. The Android emulator reaches
/// a host-side server through `adb reverse`, which keeps it on loopback.
class TransportPolicy {
  const TransportPolicy({this.allowLoopbackHttp = false});

  /// HTTPS only. Used by `main.dart` and every test that does not opt in.
  static const TransportPolicy production = TransportPolicy();

  /// HTTPS, plus plain HTTP to loopback hosts.
  static const TransportPolicy demo = TransportPolicy(allowLoopbackHttp: true);

  final bool allowLoopbackHttp;

  /// Whether [origin] may be used. [origin] need not be canonical; anything
  /// that is not a valid server origin is rejected.
  bool allows(String origin) {
    final Uri uri;
    try {
      uri = Uri.parse(canonicalizeServerOrigin(origin));
    } on FormatException {
      return false;
    }
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        allowLoopbackHttp &&
        isLoopbackHost(uri.host);
  }
}

/// True for `localhost`, any IPv4 address in `127.0.0.0/8`, and `::1`.
/// Names that merely start with "localhost" (`localhost.example.com`) are not
/// loopback.
bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost') return true;
  final bare = normalized.startsWith('[') && normalized.endsWith(']')
      ? normalized.substring(1, normalized.length - 1)
      : normalized;
  if (bare == '::1' || bare == '0:0:0:0:0:0:0:1') return true;
  final parts = bare.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  return octets.first == 127;
}
