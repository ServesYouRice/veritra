String canonicalizeServerOrigin(String raw) {
  final uri = Uri.parse(raw.trim());
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('A full HTTP(S) server origin is required');
  }
  if (uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Server URL must not contain credentials, a path, query, or fragment',
    );
  }
  final defaultPort = scheme == 'https' ? 443 : 80;
  final origin = Uri(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != defaultPort ? uri.port : null,
  );
  return origin.toString().replaceFirst(RegExp(r'/$'), '');
}
