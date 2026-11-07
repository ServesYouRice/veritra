import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'membership_models.dart';
import 'server_origin.dart';
import 'sha256.dart';

/// A group or community invitation link (C1): `<origin>/join#v1.<secret>`.
///
/// The secret stays in the URL fragment. Browsers and this app never send a
/// fragment to a server, and this class never lets the secret into a path, a
/// query, a body or an error text. What the server gets is [locator], a
/// one-way value derived from the secret; the server stores a hash of that
/// and can neither rebuild the link nor read the secret from it.
///
/// A link is only accepted for the server the user is signed in to, so a link
/// from another origin cannot make the app send anything there.
class MembershipInviteLink {
  MembershipInviteLink._(this.origin, Uint8List secret) : _secret = secret;

  /// The server origin the link names, canonical (see
  /// [canonicalizeServerOrigin]).
  final String origin;
  final Uint8List _secret;

  static const int secretLength = 32;
  static const String path = '/join';
  static const String fragmentPrefix = 'v1.';

  /// Domain separation for [locator]; the NUL ends the label.
  static const String _locatorLabel =
      'veritra/membership-invite/v1/locator\x00';

  /// Domain separation for the binding key and for the bound message (D90).
  static const String _bindingKeyLabel =
      'veritra/membership-invite/v1/binding-key\x00';
  static const String _bindingLabel =
      'veritra/membership-invite/v1/binding\x00';

  /// Longest text [tryParse] looks at.
  static const int maxLinkLength = 512;

  static final RegExp _fragmentPattern = RegExp(r'^v1\.([A-Za-z0-9_-]{43})$');

  /// A new link with a random secret for the server at [origin]. [random]
  /// defaults to a cryptographically secure source.
  factory MembershipInviteLink.generate(
      {required String origin, Random? random}) {
    final source = random ?? Random.secure();
    final secret = Uint8List(secretLength);
    for (var i = 0; i < secretLength; i++) {
      secret[i] = source.nextInt(256);
    }
    return MembershipInviteLink._(canonicalizeServerOrigin(origin), secret);
  }

  /// Reads a pasted or scanned link. Returns null for anything that is not a
  /// well-formed link of the server at [expectedOrigin]: wrong shape, another
  /// origin, a path or query beyond `/join`, credentials, or a malformed
  /// secret. A failure carries no part of the input.
  static MembershipInviteLink? tryParse(
    String input, {
    required String expectedOrigin,
  }) {
    final text = input.trim();
    if (text.isEmpty || text.length > maxLinkLength) return null;
    final String expected;
    try {
      expected = canonicalizeServerOrigin(expectedOrigin);
    } on FormatException {
      return null;
    }
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
        uri.path != path) {
      return null;
    }
    final String linkOrigin;
    try {
      linkOrigin = canonicalizeServerOrigin(Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ).toString());
    } on FormatException {
      return null;
    }
    if (linkOrigin != expected) return null;
    final match = _fragmentPattern.firstMatch(uri.fragment);
    if (match == null) return null;
    final encoded = match.group(1)!;
    final Uint8List secret;
    try {
      secret =
          Uint8List.fromList(base64Url.decode(base64Url.normalize(encoded)));
    } on FormatException {
      return null;
    }
    // Only the canonical spelling, so one secret has one link.
    if (secret.length != secretLength || _encode(secret) != encoded) {
      return null;
    }
    return MembershipInviteLink._(linkOrigin, secret);
  }

  static String _encode(Uint8List secret) =>
      base64Url.encode(secret).replaceAll('=', '');

  /// The link to share. It holds the secret: show it only to the person
  /// creating the invitation.
  String get url => '$origin$path#$fragmentPrefix${_encode(_secret)}';

  /// The value the app sends in place of the secret: SHA-256 of a fixed label
  /// and the secret, as 64 lowercase hex characters.
  String get locator =>
      sha256Hex(<int>[...utf8.encode(_locatorLabel), ..._secret]);

  /// The tag that binds an invitation to its target, the inviting account and
  /// device, and that device's signing key (D90): HMAC-SHA256, keyed by
  /// SHA-256 of a fixed label and the secret, over a fixed label, [origin] and
  /// those fields, each with a 16-bit big-endian length in front. The key is
  /// not the locator, so a server that holds the locator cannot make a tag.
  String bindingTag({
    required InviteTargetKind kind,
    required String targetId,
    required String inviterAccountId,
    required String inviterDeviceId,
    required List<int> inviterSigningKey,
  }) {
    final message = BytesBuilder(copy: false)..add(utf8.encode(_bindingLabel));
    for (final field in <List<int>>[
      utf8.encode(origin),
      utf8.encode(kind.wire),
      utf8.encode(targetId),
      utf8.encode(inviterAccountId),
      utf8.encode(inviterDeviceId),
      inviterSigningKey,
    ]) {
      if (field.length > 0xffff) throw ArgumentError('field too long');
      message
        ..add(<int>[field.length >> 8, field.length & 0xff])
        ..add(field);
    }
    final key = sha256(<int>[...utf8.encode(_bindingKeyLabel), ..._secret]);
    return hexOf(hmacSha256(key, message.takeBytes()));
  }

  /// Whether [binding] is what the device that made this link bound it to. A
  /// server without the secret cannot make a binding that passes, so a
  /// swapped target, inviter account, device or key fails here.
  bool verifies(InviteBinding binding) {
    if (binding.inviterSigningKey.length != 32) return false;
    final String expected;
    try {
      expected = bindingTag(
        kind: binding.kind,
        targetId: binding.targetId,
        inviterAccountId: binding.inviterAccountId,
        inviterDeviceId: binding.inviterDeviceId,
        inviterSigningKey: binding.inviterSigningKey,
      );
    } on ArgumentError {
      return false;
    }
    final actual = binding.tag;
    if (actual.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
    }
    return difference == 0;
  }

  @override
  String toString() => 'MembershipInviteLink(<redacted>)';
}
