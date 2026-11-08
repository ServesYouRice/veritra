import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

// B7 passkeys on the phone (docs/designs/B7-passkeys.md, S3).
//
// A passkey replaces the password at sign-in and nowhere else. The platform
// plugin sits behind [PasskeyClient]; tests use a fake. Nothing here is ever
// logged: options, credentials and challenges are not diagnostics.

/// What the server says about passkeys in `GET /api/v1/setup/status`
/// (`passkeys: {rp_id, android, apple}`). Null while passkeys are off.
@immutable
class PasskeyServerInfo {
  const PasskeyServerInfo({
    required this.rpId,
    required this.android,
    required this.apple,
  });

  final String rpId;

  /// The operator listed Android apps (`assetlinks.json` is served).
  final bool android;

  /// The operator listed Apple app IDs (the AASA file is served).
  final bool apple;

  /// Reads the `passkeys` object of the setup status. Anything else, or a
  /// malformed object, is "no passkeys": the button stays hidden.
  static PasskeyServerInfo? fromStatus(Map<String, Object?> status) {
    final raw = status['passkeys'];
    if (raw is! Map) return null;
    final rpId = raw['rp_id'];
    final android = raw['android'];
    final apple = raw['apple'];
    if (rpId is! String ||
        rpId.isEmpty ||
        rpId.length > 253 ||
        android is! bool ||
        apple is! bool) {
      return null;
    }
    return PasskeyServerInfo(rpId: rpId, android: android, apple: apple);
  }
}

/// The platforms the design distinguishes.
enum PasskeyPlatform { android, ios, macos, windows, linux, other }

PasskeyPlatform passkeyPlatformOf(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
      return PasskeyPlatform.android;
    case TargetPlatform.iOS:
      return PasskeyPlatform.ios;
    case TargetPlatform.macOS:
      return PasskeyPlatform.macos;
    case TargetPlatform.windows:
      return PasskeyPlatform.windows;
    case TargetPlatform.linux:
      return PasskeyPlatform.linux;
    case TargetPlatform.fuchsia:
      return PasskeyPlatform.other;
  }
}

/// Hostnames compiled into the build's associated-domains entitlement
/// (`--dart-define=VERITRA_PASSKEY_DOMAINS=a.example,b.example`). Only used
/// on iOS and macOS (design, "Where the button shows").
const String passkeyAppleDomainsDefine =
    String.fromEnvironment('VERITRA_PASSKEY_DOMAINS');

List<String> parsePasskeyDomains(String raw) => <String>[
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim().toLowerCase(),
    ];

/// Whether the passkey button may show for [serverHost] on [platform].
///
/// - Linux and unknown platforms: never (the plugin has no support, O2).
/// - The server must advertise passkeys, and its `rp_id` must be the host of
///   the server URL this slot uses.
/// - Android needs the operator's Android list; Apple platforms need the
///   operator's Apple list **and** a host in the compiled-in domain list (O1);
///   Windows needs nothing more.
bool passkeysOffered({
  required PasskeyPlatform platform,
  required PasskeyServerInfo? info,
  required String serverHost,
  List<String> appleDomains = const <String>[],
}) {
  if (info == null) return false;
  if (!_sameHost(info.rpId, serverHost)) return false;
  switch (platform) {
    case PasskeyPlatform.android:
      return info.android;
    case PasskeyPlatform.ios:
    case PasskeyPlatform.macos:
      return info.apple &&
          appleDomains.contains(serverHost.trim().toLowerCase());
    case PasskeyPlatform.windows:
      return true;
    case PasskeyPlatform.linux:
    case PasskeyPlatform.other:
      return false;
  }
}

bool _sameHost(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// The error raised before the platform is called, when the options name an
/// RP ID other than the server's. On Windows this check is the only thing
/// that stops a hostile server from asking for an assertion meant for
/// another server (design, "The app pins the RP ID").
class PasskeyPinException implements Exception {
  const PasskeyPinException();
  @override
  String toString() => 'passkey options name another relying party';
}

/// The server's answer to a ceremony request.
@immutable
class PasskeyCeremony {
  const PasskeyCeremony({required this.id, required this.publicKey});

  final String id;
  final Map<String, Object?> publicKey;
}

/// Checks the options before any platform call. [rpField] is where the RP ID
/// sits: `rp.id` for registration, `rpId` for sign-in. Both the server URL's
/// host and the advertised `rp_id` must equal it.
void pinPasskeyRp({
  required Map<String, Object?> publicKey,
  required bool registration,
  required String serverHost,
  required PasskeyServerInfo info,
}) {
  final Object? rp;
  if (registration) {
    final rpMap = publicKey['rp'];
    rp = rpMap is Map ? rpMap['id'] : null;
  } else {
    rp = publicKey['rpId'];
  }
  if (rp is! String ||
      !_sameHost(rp, serverHost) ||
      !_sameHost(rp, info.rpId)) {
    throw const PasskeyPinException();
  }
}

/// One passkey of the account, as `GET /api/v1/account/passkeys` lists it.
@immutable
class PasskeyRecord {
  const PasskeyRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastUsedAt,
    this.synced = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  /// The authenticator says the passkey is backed up (BS flag).
  final bool synced;

  static PasskeyRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final created = raw['created_at'];
    if (id is! String || id.isEmpty || id.length > 128) return null;
    if (name is! String || name.length > 256) return null;
    if (created is! String) return null;
    final createdAt = DateTime.tryParse(created);
    if (createdAt == null) return null;
    final used = raw['last_used_at'];
    final usedAt = used is String ? DateTime.tryParse(used) : null;
    return PasskeyRecord(
      id: id,
      name: name,
      createdAt: createdAt,
      lastUsedAt: usedAt,
      synced: raw['synced'] == true,
    );
  }
}

/// The user dismissed the platform sheet. Never shown as an error.
class PasskeyCancelled implements Exception {
  const PasskeyCancelled();
}

/// The platform cannot do this here: no passkey provider, no matching
/// association with the domain, or an unsupported device.
class PasskeyUnavailable implements Exception {
  const PasskeyUnavailable();
}

/// The platform side of passkeys. [create] runs a registration ceremony from
/// the server's `public_key` options and returns the WebAuthn credential JSON
/// the server verifies; [get] does the same for sign-in.
abstract class PasskeyClient {
  /// Whether this platform build can run a ceremony at all. Linux is false.
  bool get platformSupported;

  Future<Map<String, Object?>> create(Map<String, Object?> publicKey);

  Future<Map<String, Object?>> get(Map<String, Object?> publicKey);
}

/// Used where passkeys do not exist (Linux, tests that do not need them).
class UnsupportedPasskeyClient implements PasskeyClient {
  const UnsupportedPasskeyClient();

  @override
  bool get platformSupported => false;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> publicKey) =>
      Future<Map<String, Object?>>.error(const PasskeyUnavailable());

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> publicKey) =>
      Future<Map<String, Object?>>.error(const PasskeyUnavailable());
}

/// The Corbado `passkeys` plugin (BSD-3-Clause). Never built in debug mode:
/// that would make the plugin's doctor fetch the server's `.well-known` files.
class PlatformPasskeyClient implements PasskeyClient {
  PlatformPasskeyClient({PasskeyPlatform? platform})
      : _platform = platform ?? passkeyPlatformOf(defaultTargetPlatform);

  final PasskeyPlatform _platform;
  PasskeyAuthenticator? _authenticator;

  PasskeyAuthenticator get _plugin =>
      _authenticator ??= PasskeyAuthenticator(debugMode: false);

  @override
  bool get platformSupported =>
      _platform == PasskeyPlatform.android ||
      _platform == PasskeyPlatform.ios ||
      _platform == PasskeyPlatform.macos ||
      _platform == PasskeyPlatform.windows;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> publicKey) async {
    if (!platformSupported) throw const PasskeyUnavailable();
    try {
      final request =
          RegisterRequestType.fromJson(Map<String, dynamic>.from(publicKey));
      final response = await _plugin.register(request);
      return Map<String, Object?>.from(response.toJson());
    } on PasskeyAuthCancelledException {
      throw const PasskeyCancelled();
    } on AuthenticatorException {
      throw const PasskeyUnavailable();
    } on FormatException {
      throw const PasskeyUnavailable();
    }
  }

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> publicKey) async {
    if (!platformSupported) throw const PasskeyUnavailable();
    try {
      final request = AuthenticateRequestType.fromJson(
        Map<String, dynamic>.from(publicKey),
        mediation: MediationType.Optional,
        preferImmediatelyAvailableCredentials: false,
        canBeSecurityKey: false,
      );
      final response = await _plugin.authenticate(request);
      return Map<String, Object?>.from(response.toJson());
    } on PasskeyAuthCancelledException {
      throw const PasskeyCancelled();
    } on AuthenticatorException {
      throw const PasskeyUnavailable();
    } on FormatException {
      throw const PasskeyUnavailable();
    }
  }
}

/// A suggested name for the next passkey: "Passkey 1", "Passkey 2", ...
/// never a device model (design, "Registration").
String suggestPasskeyName(String prefix, Iterable<PasskeyRecord> existing) {
  final taken = existing.map((p) => p.name).toSet();
  for (var n = 1; n < 1000; n++) {
    final candidate = '$prefix $n';
    if (!taken.contains(candidate)) return candidate;
  }
  return prefix;
}

/// Encodes a ceremony body the way the server's handlers read it.
String passkeyCredentialJson(Map<String, Object?> credential) =>
    jsonEncode(credential);
