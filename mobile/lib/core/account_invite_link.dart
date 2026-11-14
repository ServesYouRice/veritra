import 'server_origin.dart';
import 'transport_policy.dart';

/// An account invitation as one link (U21):
/// `<origin>/invite#v1.<invite code>`. See
/// `docs/designs/U21-account-invite-link.md`.
///
/// The code stays in the URL fragment, which is never sent in an HTTP
/// request, so a browser, a proxy or a link previewer that sees the link does
/// not see the code. The app still sends the code to the server in the
/// registration body, as before: the server minted it.
///
/// Unlike a C1 group link ([MembershipInviteLink], path `/join`), this link
/// names the server to use, because it is opened before there is an account.
class AccountInviteLink {
  AccountInviteLink._(this.origin, this.code);

  /// The canonical server origin (see [canonicalizeServerOrigin]).
  final String origin;

  /// The invite code exactly as the server issued it.
  final String code;

  static const String path = '/invite';
  static const String fragmentPrefix = 'v1.';

  /// Longest text [tryParse] looks at.
  static const int maxLinkLength = 512;

  /// URL-safe without percent-encoding, so the fragment is read as is.
  static final RegExp _codePattern = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

  /// Whether [code] can travel in a link (the server's codes always can).
  static bool canLink(String code) => _codePattern.hasMatch(code);

  /// The link for an invitation of the server at [origin], or null when the
  /// origin is not a server origin or [code] cannot travel in a link.
  static AccountInviteLink? forInvite({
    required String origin,
    required String code,
  }) {
    if (!canLink(code)) return null;
    try {
      return AccountInviteLink._(canonicalizeServerOrigin(origin), code);
    } on FormatException {
      return null;
    }
  }

  /// Reads a pasted or scanned link. Returns null for anything that is not a
  /// well-formed invitation link to a server [transport] allows: another
  /// path, a query, credentials, another fragment version or a malformed
  /// code. A failure carries no part of the input.
  static AccountInviteLink? tryParse(
    String input, {
    required TransportPolicy transport,
  }) {
    final text = input.trim();
    if (text.isEmpty || text.length > maxLinkLength) return null;
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    if (!uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.path != path ||
        !uri.hasFragment) {
      return null;
    }
    final String origin;
    try {
      origin = canonicalizeServerOrigin(
        Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ).toString(),
      );
    } on FormatException {
      return null;
    }
    if (!transport.allows(origin)) return null;
    // Read path and fragment from the text as written: Uri.parse decodes
    // percent-escapes of unreserved characters (`%41` becomes `A`), and a
    // link has one spelling.
    final hash = text.indexOf('#');
    if (!text.substring(0, hash).endsWith(path)) return null;
    final fragment = text.substring(hash + 1);
    if (!fragment.startsWith(fragmentPrefix)) return null;
    final code = fragment.substring(fragmentPrefix.length);
    if (!canLink(code)) return null;
    return AccountInviteLink._(origin, code);
  }

  /// The link to share. It holds the code: show it only to the inviter.
  String get url => '$origin$path#$fragmentPrefix$code';

  @override
  String toString() => 'AccountInviteLink(<redacted>)';
}
