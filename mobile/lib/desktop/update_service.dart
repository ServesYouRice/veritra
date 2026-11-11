import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/profile_scope.dart';
import '../ui/about.dart';

/// Maximum size for update feed or signature file (64 KiB).
const int maxUpdateFeedBytes = 64 * 1024;

/// Network timeout for update checks.
const Duration updateCheckTimeout = Duration(seconds: 15);

/// Metadata for a published Veritra update (W12, docs/release-engineering.md).
/// Delivered via static update.json and detached update.json.sig.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.platform,
    required this.arch,
    required this.issuedAt,
    required this.expiresAt,
    required this.url,
    required this.sha256,
    required this.notes,
  });

  final String version;
  final int build;
  final String platform;
  final String arch;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String url;
  final String sha256;
  final String notes;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  factory UpdateInfo.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final build = json['build'];
    final platform = json['platform'];
    final arch = json['arch'];
    final issuedAtRaw = json['issued_at'];
    final expiresAtRaw = json['expires_at'];
    final url = json['url'];
    final sha256 = json['sha256'];
    final notes = json['notes'];

    if (version is! String || version.trim().isEmpty) {
      throw const FormatException('Missing or invalid update version');
    }
    if (build is! int || build < 1) {
      throw const FormatException('Missing or invalid update build number');
    }
    if (platform is! String || platform.trim().isEmpty) {
      throw const FormatException('Missing or invalid update platform');
    }
    if (arch is! String || arch.trim().isEmpty) {
      throw const FormatException('Missing or invalid update arch');
    }
    if (issuedAtRaw is! String) {
      throw const FormatException('Missing or invalid update issued_at');
    }
    final issuedAt = DateTime.tryParse(issuedAtRaw);
    if (issuedAt == null) {
      throw const FormatException('Invalid ISO-8601 update issued_at');
    }
    if (expiresAtRaw is! String) {
      throw const FormatException('Missing or invalid update expires_at');
    }
    final expiresAt = DateTime.tryParse(expiresAtRaw);
    if (expiresAt == null) {
      throw const FormatException('Invalid ISO-8601 update expires_at');
    }
    if (expiresAt.isBefore(issuedAt)) {
      throw const FormatException('Update expires_at cannot precede issued_at');
    }
    if (url is! String || url.trim().isEmpty) {
      throw const FormatException('Missing or invalid update url');
    }
    final parsedUri = Uri.tryParse(url);
    if (parsedUri == null ||
        parsedUri.scheme != 'https' ||
        parsedUri.host.trim().isEmpty) {
      throw const FormatException(
          'Update URL must use https with a valid host');
    }
    if (sha256 is! String || !_hex64.hasMatch(sha256)) {
      throw const FormatException(
          'Update sha256 must be 64 lowercase hex characters');
    }
    final notesStr = notes is String ? notes : '';

    return UpdateInfo(
      version: version,
      build: build,
      platform: platform.toLowerCase(),
      arch: arch.toLowerCase(),
      issuedAt: issuedAt.toUtc(),
      expiresAt: expiresAt.toUtc(),
      url: url,
      sha256: sha256.toLowerCase(),
      notes: notesStr,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'build': build,
        'platform': platform,
        'arch': arch,
        'issued_at': issuedAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'url': url,
        'sha256': sha256,
        'notes': notes,
      };

  bool isExpired({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    return current.isAfter(expiresAt);
  }

  bool matchesPlatform(String targetPlatform) =>
      platform == targetPlatform.toLowerCase();

  bool matchesArch(String targetArch) => arch == targetArch.toLowerCase();

  bool isNewer(int currentBuild) => build > currentBuild;
}

enum UpdateStatusKind {
  idle,
  checking,
  updateAvailable,
  upToDate,
  disabled,
  error,
}

class UpdateStatus {
  const UpdateStatus.idle()
      : kind = UpdateStatusKind.idle,
        update = null,
        errorMessage = null;

  const UpdateStatus.checking()
      : kind = UpdateStatusKind.checking,
        update = null,
        errorMessage = null;

  const UpdateStatus.updateAvailable(UpdateInfo info)
      : kind = UpdateStatusKind.updateAvailable,
        update = info,
        errorMessage = null;

  const UpdateStatus.upToDate()
      : kind = UpdateStatusKind.upToDate,
        update = null,
        errorMessage = null;

  const UpdateStatus.disabled()
      : kind = UpdateStatusKind.disabled,
        update = null,
        errorMessage = null;

  const UpdateStatus.error(String message)
      : kind = UpdateStatusKind.error,
        update = null,
        errorMessage = message;

  final UpdateStatusKind kind;
  final UpdateInfo? update;
  final String? errorMessage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateStatus &&
          other.kind == kind &&
          other.update?.version == update?.version &&
          other.update?.build == update?.build &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(kind, update?.build, errorMessage);
}

/// Verification interface for detached update signatures.
/// Signing stays a placeholder that waits for the owner's certificate and key.
abstract interface class UpdateSignatureVerifier {
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  });
}

/// Placeholder signature verifier: records that signing waits for the owner's
/// certificate and update signing key (docs/release-engineering.md).
class PlaceholderUpdateSignatureVerifier implements UpdateSignatureVerifier {
  const PlaceholderUpdateSignatureVerifier({this.expectedPublicKey});

  final Uint8List? expectedPublicKey;

  @override
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  }) async {
    // If no owner public key is compiled in, signing stays a placeholder.
    if (expectedPublicKey == null) {
      return true;
    }
    if (signature == null || signature.isEmpty) {
      return false;
    }
    // Reserved for when the owner configures the compiled-in update public key.
    return true;
  }
}

/// Client interface for downloading update feeds without cookies or tracking.
abstract interface class UpdateClient {
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
      Uri feedUri);
}

/// Real HTTPS update client. Sends one clean HTTPS GET without credentials or cookies.
class HttpUpdateClient implements UpdateClient {
  const HttpUpdateClient({
    this.client,
    this.timeout = updateCheckTimeout,
    this.maxBytes = maxUpdateFeedBytes,
  });

  final HttpClient? client;
  final Duration timeout;
  final int maxBytes;

  @override
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
      Uri feedUri) async {
    if (feedUri.scheme != 'https' || feedUri.host.trim().isEmpty) {
      throw const FormatException(
          'Update feed must use https with a valid host');
    }
    final http = client ?? HttpClient();
    http.connectionTimeout = timeout;
    try {
      final request = await http.getUrl(feedUri).timeout(timeout);
      request.cookies.clear();
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Update feed answered HTTP ${response.statusCode}',
            uri: feedUri);
      }
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytesBuilder.add(chunk);
        if (bytesBuilder.length > maxBytes) {
          throw const FormatException(
              'Update feed response exceeds size limit');
        }
      }
      final jsonBytes = bytesBuilder.takeBytes();

      Uint8List? sigBytes;
      try {
        final sigUri = feedUri.replace(path: '${feedUri.path}.sig');
        final sigReq = await http.getUrl(sigUri).timeout(timeout);
        sigReq.cookies.clear();
        final sigResp = await sigReq.close().timeout(timeout);
        if (sigResp.statusCode == HttpStatus.ok) {
          final sigBuilder = BytesBuilder(copy: false);
          await for (final chunk in sigResp.timeout(timeout)) {
            sigBuilder.add(chunk);
            if (sigBuilder.length > maxBytes) {
              throw const FormatException(
                  'Update signature exceeds size limit');
            }
          }
          sigBytes = sigBuilder.takeBytes();
        }
      } catch (_) {
        // Detached signature file may not be present in placeholder mode.
      }

      return (jsonBytes: jsonBytes, signatureBytes: sigBytes);
    } finally {
      if (client == null) http.close();
    }
  }
}

/// Mock client for tests.
class MemoryUpdateClient implements UpdateClient {
  MemoryUpdateClient({
    this.responseBytes,
    this.signatureBytes,
    this.error,
  });

  Uint8List? responseBytes;
  Uint8List? signatureBytes;
  Object? error;

  @override
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
      Uri feedUri) async {
    if (error != null) throw error!;
    if (responseBytes == null) {
      throw const HttpException('Not found');
    }
    return (jsonBytes: responseBytes!, signatureBytes: signatureBytes);
  }
}

/// Storage for update settings (on by default, can be turned off in settings).
abstract interface class UpdateSettingsStore {
  Future<bool?> loadAutoCheck();
  Future<void> saveAutoCheck(bool value);
}

class SecureUpdateSettingsStore implements UpdateSettingsStore {
  SecureUpdateSettingsStore({
    FlutterSecureStorage? storage,
    ProfileScope scope = const ProfileScope(),
  })  : _key = scope.secureKey('updates.auto_check.v1'),
        _isPrimary = scope.isPrimary,
        _storage = storage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  static const key = 'veritra.updates.auto_check.v1';

  final String _key;
  final bool _isPrimary;
  final FlutterSecureStorage _storage;

  @override
  Future<bool?> loadAutoCheck() async {
    var value = await _storage.read(key: _key);
    if (value == null && !_isPrimary) {
      value = await _storage.read(key: key) ?? 'true';
      await _storage.write(key: _key, value: value);
    }
    return value == null ? null : value == 'true';
  }

  @override
  Future<void> saveAutoCheck(bool value) async {
    try {
      await _storage.write(key: _key, value: value.toString());
    } catch (_) {}
  }
}

class MemoryUpdateSettingsStore implements UpdateSettingsStore {
  MemoryUpdateSettingsStore([this.autoCheck = true]);

  bool? autoCheck;

  @override
  Future<bool?> loadAutoCheck() async => autoCheck;

  @override
  Future<void> saveAutoCheck(bool value) async => autoCheck = value;
}

/// Settings model: on by default, can be turned off in settings.
class UpdateSettings extends ChangeNotifier {
  UpdateSettings(this._store);

  final UpdateSettingsStore _store;
  bool _autoCheck = true;
  bool _loaded = false;
  bool _disposed = false;
  Future<void>? _loadFuture;

  /// Whether automatic update check is enabled (on by default).
  bool get autoCheckEnabled => _autoCheck;

  /// Whether stored settings have finished loading.
  bool get isLoaded => _loaded;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    final bool? saved;
    try {
      saved = await _store.loadAutoCheck();
    } catch (_) {
      _loaded = true;
      return;
    }
    if (_disposed) return;
    _loaded = true;
    if (saved == null || saved == _autoCheck) return;
    _autoCheck = saved;
    notifyListeners();
  }

  Future<void> setAutoCheckEnabled(bool value) async {
    if (value != _autoCheck) {
      _autoCheck = value;
      notifyListeners();
    }
    await _store.saveAutoCheck(value);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Service that coordinates update checks according to docs/release-engineering.md.
class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.settings,
    UpdateClient? client,
    UpdateSignatureVerifier? verifier,
    Uri? feedUri,
    String? platform,
    String? arch,
    int? currentBuild,
    DateTime Function()? now,
  })  : _client = client ?? const HttpUpdateClient(),
        _verifier = verifier ?? const PlaceholderUpdateSignatureVerifier(),
        _feedUri = feedUri ??
            Uri.parse(
                'https://raw.githubusercontent.com/ServesYouRice/veritra/main/release/windows/update.json'),
        _platform = platform ?? 'windows',
        _arch = arch ?? 'x64',
        _currentBuild = currentBuild ?? veritraBuildNumber,
        _now = now ?? DateTime.now {
    settings.addListener(_onSettingsChanged);
  }

  final UpdateSettings settings;
  final UpdateClient _client;
  final UpdateSignatureVerifier _verifier;
  final Uri _feedUri;
  final String _platform;
  final String _arch;
  final int _currentBuild;
  final DateTime Function() _now;

  UpdateStatus _status = const UpdateStatus.idle();
  DateTime? _lastCheckTime;

  UpdateStatus get status => _status;
  DateTime? get lastCheckTime => _lastCheckTime;
  bool get isChecking => _status.kind == UpdateStatusKind.checking;

  void _onSettingsChanged() {
    if (!settings.autoCheckEnabled && _status.kind == UpdateStatusKind.idle) {
      _status = const UpdateStatus.disabled();
      notifyListeners();
    } else if (settings.autoCheckEnabled &&
        _status.kind == UpdateStatusKind.disabled) {
      _status = const UpdateStatus.idle();
      notifyListeners();
    }
  }

  /// Checks for updates if automatic checking is enabled.
  Future<UpdateStatus> checkForUpdatesIfEnabled() async {
    if (!settings.isLoaded) {
      await settings.load();
    }
    if (!settings.autoCheckEnabled) {
      _status = const UpdateStatus.disabled();
      notifyListeners();
      return _status;
    }
    return checkForUpdates(force: false);
  }

  /// Runs an update check. [force] ignores the disabled setting (used by manual button).
  Future<UpdateStatus> checkForUpdates(
      {bool force = false, Uri? feedUri}) async {
    if (!settings.isLoaded) {
      await settings.load();
    }
    if (!settings.autoCheckEnabled && !force) {
      _status = const UpdateStatus.disabled();
      notifyListeners();
      return _status;
    }

    _status = const UpdateStatus.checking();
    notifyListeners();

    final targetUri = feedUri ?? _feedUri;
    try {
      final fetched = await _client.fetchUpdate(targetUri);
      _lastCheckTime = _now();

      // Signature verification (placeholder waits for owner's certificate)
      final validSig = await _verifier.verify(
        data: fetched.jsonBytes,
        signature: fetched.signatureBytes,
      );
      if (!validSig) {
        _status = const UpdateStatus.error('Update signature is invalid');
        notifyListeners();
        return _status;
      }

      final dynamic decoded = jsonDecode(utf8.decode(fetched.jsonBytes));
      if (decoded is! Map<String, Object?>) {
        _status = const UpdateStatus.error('Malformed update metadata');
        notifyListeners();
        return _status;
      }

      final info = UpdateInfo.fromJson(decoded);

      if (!info.matchesPlatform(_platform)) {
        _status = const UpdateStatus.error('Update platform does not match');
        notifyListeners();
        return _status;
      }
      if (!info.matchesArch(_arch)) {
        _status =
            const UpdateStatus.error('Update architecture does not match');
        notifyListeners();
        return _status;
      }
      if (info.isExpired(now: _now())) {
        _status = const UpdateStatus.error('Update metadata has expired');
        notifyListeners();
        return _status;
      }
      if (!info.isNewer(_currentBuild)) {
        _status = const UpdateStatus.upToDate();
        notifyListeners();
        return _status;
      }

      _status = UpdateStatus.updateAvailable(info);
      notifyListeners();
      return _status;
    } catch (e) {
      _lastCheckTime = _now();
      _status = UpdateStatus.error(e.toString());
      notifyListeners();
      return _status;
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}

/// Inherited scope providing update settings and service down the widget tree.
class UpdateSettingsScope extends InheritedNotifier<UpdateSettings> {
  const UpdateSettingsScope({
    required UpdateSettings settings,
    required this.service,
    required super.child,
    super.key,
  }) : super(notifier: settings);

  final UpdateService service;

  static UpdateSettingsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateSettingsScope>();

  UpdateSettings get settings => notifier!;
}
