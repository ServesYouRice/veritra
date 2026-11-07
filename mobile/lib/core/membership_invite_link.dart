import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'membership_models.dart';
import 'server_origin.dart';
import 'sha256.dart';

/// A group or community invitation link (C1, format v2):
/// `<origin>/join#v2.<secret>.<key commitment>`.
///
/// The fragment also holds a 128-bit commitment to the inviting device's
/// signing key, so a joiner can tell that the key the server names is the one
/// the link was made with (see [matches] and `docs/designs/C1-invite-format.md`).
/// v1 links (`#v1.<secret>`, secret-keyed MAC only) are not read: nothing was
/// released with them, and a v1 link has no commitment to check.
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
  MembershipInviteLink._(this.origin, Uint8List secret, Uint8List commitment)
      : _secret = secret,
        _keyCommitment = commitment;

  /// The server origin the link names, canonical (see
  /// [canonicalizeServerOrigin]).
  final String origin;
  final Uint8List _secret;
  final Uint8List _keyCommitment;

  static const int secretLength = 32;

  /// Bytes of SHA-256 kept as the key commitment (128 bits).
  static const int keyCommitmentLength = 16;
  static const int signingKeyLength = 32;
  static const int signatureLength = 64;
  static const String path = '/join';
  static const String fragmentPrefix = 'v2.';

  /// Domain separation for [locator]; the NUL ends the label.
  static const String _locatorLabel =
      'veritra/membership-invite/v1/locator\x00';

  /// Domain separation for the key commitment (v2); the NUL ends the label.
  static const String _keyCommitLabel =
      'veritra/membership-invite/v2/key-commit\x00';

  /// Domain separation for the binding key and for the bound message (D90).
  static const String _bindingKeyLabel =
      'veritra/membership-invite/v1/binding-key\x00';
  static const String _bindingLabel =
      'veritra/membership-invite/v1/binding\x00';

  /// Longest text [tryParse] looks at.
  static const int maxLinkLength = 512;

  static final RegExp _fragmentPattern =
      RegExp(r'^v2\.([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{22})$');

  /// A new link with a random secret for the server at [origin], committed
  /// to the creating device's [inviterSigningKey] (32 bytes). [random]
  /// defaults to a cryptographically secure source.
  factory MembershipInviteLink.generate({
    required String origin,
    required List<int> inviterSigningKey,
    Random? random,
  }) {
    if (inviterSigningKey.length != signingKeyLength) {
      throw ArgumentError('the signing key is 32 bytes');
    }
    final source = random ?? Random.secure();
    final secret = Uint8List(secretLength);
    for (var i = 0; i < secretLength; i++) {
      secret[i] = source.nextInt(256);
    }
    return MembershipInviteLink._(
      canonicalizeServerOrigin(origin),
      secret,
      _commit(inviterSigningKey),
    );
  }

  /// The first [keyCommitmentLength] bytes of SHA-256 of a fixed label and
  /// the inviting device's signing key.
  static Uint8List _commit(List<int> signingKey) => Uint8List.fromList(
          sha256(<int>[...utf8.encode(_keyCommitLabel), ...signingKey]).sublist(
        0,
        keyCommitmentLength,
      ));

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
    final encodedCommitment = match.group(2)!;
    final Uint8List secret;
    final Uint8List commitment;
    try {
      secret =
          Uint8List.fromList(base64Url.decode(base64Url.normalize(encoded)));
      commitment = Uint8List.fromList(
          base64Url.decode(base64Url.normalize(encodedCommitment)));
    } on FormatException {
      return null;
    }
    // Only the canonical spelling, so one secret has one link.
    if (secret.length != secretLength ||
        _encode(secret) != encoded ||
        commitment.length != keyCommitmentLength ||
        _encode(commitment) != encodedCommitment) {
      return null;
    }
    return MembershipInviteLink._(linkOrigin, secret, commitment);
  }

  static String _encode(Uint8List secret) =>
      base64Url.encode(secret).replaceAll('=', '');

  /// The link to share. It holds the secret: show it only to the person
  /// creating the invitation.
  String get url =>
      '$origin$path#$fragmentPrefix${_encode(_secret)}.${_encode(_keyCommitment)}';

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
    _addFields(message,
        kind: kind,
        targetId: targetId,
        inviterAccountId: inviterAccountId,
        inviterDeviceId: inviterDeviceId,
        inviterSigningKey: inviterSigningKey);
    final key = sha256(<int>[...utf8.encode(_bindingKeyLabel), ..._secret]);
    return hexOf(hmacSha256(key, message.takeBytes()));
  }

  /// The fields both the tag and the signed message cover, each with a
  /// 16-bit big-endian length in front.
  void _addFields(
    BytesBuilder out, {
    required InviteTargetKind kind,
    required String targetId,
    required String inviterAccountId,
    required String inviterDeviceId,
    required List<int> inviterSigningKey,
  }) {
    for (final field in <List<int>>[
      utf8.encode(origin),
      utf8.encode(kind.wire),
      utf8.encode(targetId),
      utf8.encode(inviterAccountId),
      utf8.encode(inviterDeviceId),
      inviterSigningKey,
    ]) {
      _addField(out, field);
    }
  }

  static void _addField(BytesBuilder out, List<int> field) {
    if (field.length > 0xffff) throw ArgumentError('field too long');
    out
      ..add(<int>[field.length >> 8, field.length & 0xff])
      ..add(field);
  }

  /// The bytes the creating device signs (v2), under the native domain
  /// `veritra-invite-binding-v2` (which the engine prepends): the fields of
  /// [bindingTag] and this link's [locator], so a signature made for one link
  /// is no answer for another link of the same inviter.
  Uint8List bindingMessage({
    required InviteTargetKind kind,
    required String targetId,
    required String inviterAccountId,
    required String inviterDeviceId,
    required List<int> inviterSigningKey,
  }) {
    final message = BytesBuilder(copy: false);
    _addFields(message,
        kind: kind,
        targetId: targetId,
        inviterAccountId: inviterAccountId,
        inviterDeviceId: inviterDeviceId,
        inviterSigningKey: inviterSigningKey);
    _addField(message, utf8.encode(locator));
    return message.takeBytes();
  }

  /// The signed message for [binding], as the joiner rebuilds it.
  Uint8List bindingMessageOf(InviteBinding binding) => bindingMessage(
        kind: binding.kind,
        targetId: binding.targetId,
        inviterAccountId: binding.inviterAccountId,
        inviterDeviceId: binding.inviterDeviceId,
        inviterSigningKey: binding.inviterSigningKey,
      );

  /// Whether [binding] agrees with this link on everything the link itself
  /// can tell, without the native engine: the key is 32 bytes and hashes to
  /// the commitment in the link, the signature has its length, and the tag is
  /// the one the secret makes (a swapped target, account, device or key
  /// fails). It does NOT check the signature: the joiner does that through
  /// `InviteBindingCryptoService.verifyInviteBinding` over [bindingMessageOf]
  /// and the key, and a binding is accepted only when both pass.
  bool matches(InviteBinding binding) {
    if (binding.inviterSigningKey.length != signingKeyLength ||
        binding.signature.length != signatureLength) {
      return false;
    }
    // The key must be the one the link was made with. A server that holds the
    // link but not the inviter's key cannot name another key that fits.
    final commitment = _commit(binding.inviterSigningKey);
    var same = 0;
    for (var i = 0; i < keyCommitmentLength; i++) {
      same |= commitment[i] ^ _keyCommitment[i];
    }
    if (same != 0) return false;
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
