import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/profile_scope.dart';
import '../ui/about.dart';
import 'update_installer.dart';
import 'update_trust.dart';

/// Maximum size for update feed or signature file (64 KiB).
const int maxUpdateFeedBytes = 64 * 1024;

/// Network timeout for update checks.
const Duration updateCheckTimeout = Duration(seconds: 15);

/// Metadata for a published Veritra update (W12, docs/release-engineering.md).
/// Delivered via static update.json and detached update.json.sig.
class UpdateInfo implements UpdateInstallTarget {
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

  @override
  final String version;
  final int build;
  final String platform;
  final String arch;
  final DateTime issuedAt;
  final DateTime expiresAt;
  @override
  final String url;
  @override
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
        'Update URL must use https with a valid host',
      );
    }
    if (sha256 is! String || !_hex64.hasMatch(sha256)) {
      throw const FormatException(
        'Update sha256 must be 64 lowercase hex characters',
      );
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

  /// This build cannot check: no verified feed (no key, or no signature
  /// verification), or not a Windows build. No network request was made.
  unavailable,
  downloading,
  readyToInstall,
  downloadFailed,
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

  const UpdateStatus.unavailable()
      : kind = UpdateStatusKind.unavailable,
        update = null,
        errorMessage = null;

  const UpdateStatus.downloading(UpdateInfo info)
      : kind = UpdateStatusKind.downloading,
        update = info,
        errorMessage = null;

  const UpdateStatus.readyToInstall(UpdateInfo info)
      : kind = UpdateStatusKind.readyToInstall,
        update = info,
        errorMessage = null;

  const UpdateStatus.downloadFailed(UpdateInfo info, String message)
      : kind = UpdateStatusKind.downloadFailed,
        update = info,
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
abstract interface class UpdateSignatureVerifier {
  /// Whether this verifier can really check a signature. The service does not
  /// fetch a feed, and never reports an update, for one that cannot.
  bool get isConfigured;

  Future<bool> verify({required List<int> data, required List<int>? signature});
}

/// The verifier this build has: it accepts nothing. A feed is only trusted
/// after an Ed25519 check against [updateFeedPublicKeyHex], and the app has no
/// such check yet (it needs one function in the native library, because the
/// Dart side has no Ed25519 and must not hand-roll one: see
/// docs/release-engineering.md, "Update channel"). Until then the channel
/// stays off, whether or not the owner has already set a key; an earlier
/// placeholder that returned true for any non-empty signature was removed.
class FailClosedUpdateSignatureVerifier implements UpdateSignatureVerifier {
  const FailClosedUpdateSignatureVerifier();

  @override
  bool get isConfigured => false;

  @override
  Future<bool> verify({
    required List<int> data,
    required List<int>? signature,
  }) async =>
      false;
}

/// Client interface for downloading update feeds without cookies or tracking.
abstract interface class UpdateClient {
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
    Uri feedUri,
  );
}

/// Real HTTPS update client: one GET for the feed and one for its `.sig`,
/// without credentials or cookies, redirects followed by hand and only to
/// https ([openHttpsWithRedirects]), each body at most [maxBytes].
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
    Uri feedUri,
  ) async {
    if (feedUri.scheme != 'https' || feedUri.host.trim().isEmpty) {
      throw const FormatException(
        'Update feed must use https with a valid host',
      );
    }
    final http = client ?? HttpClient();
    http.connectionTimeout = timeout;
    try {
      final jsonBytes = await _get(http, feedUri, accept: 'application/json');
      if (jsonBytes == null) {
        throw HttpException('Update feed is not available', uri: feedUri);
      }
      // A missing or unreadable signature is null: the verifier rejects it.
      Uint8List? sigBytes;
      try {
        sigBytes = await _get(
          http,
          feedUri.replace(path: '${feedUri.path}.sig'),
        );
      } catch (_) {
        sigBytes = null;
      }
      return (jsonBytes: jsonBytes, signatureBytes: sigBytes);
    } finally {
      if (client == null) http.close(force: true);
    }
  }

  /// The body of [uri] when it answers 200, null for another status.
  Future<Uint8List?> _get(HttpClient http, Uri uri, {String? accept}) async {
    final response = await openHttpsWithRedirects(
      http,
      uri,
      timeout: timeout,
      accept: accept,
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const FormatException('Update feed response exceeds size limit');
      }
    }
    return builder.takeBytes();
  }
}

/// Mock client for tests.
class MemoryUpdateClient implements UpdateClient {
  MemoryUpdateClient({this.responseBytes, this.signatureBytes, this.error});

  Uint8List? responseBytes;
  Uint8List? signatureBytes;
  Object? error;

  @override
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
    Uri feedUri,
  ) async {
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
    UpdateInstaller? installer,
    void Function()? onQuitForUpdate,
    Uri? feedUri,
    String? platform,
    String? arch,
    int? currentBuild,
    DateTime Function()? now,
  })  : _client = client ?? const HttpUpdateClient(),
        _verifier = verifier ?? const FailClosedUpdateSignatureVerifier(),
        _installer = installer,
        _onQuitForUpdate = onQuitForUpdate,
        _feedUri = feedUri ?? Uri.parse(updateFeedUrl),
        _platform = platform ?? 'windows',
        _arch = arch ?? 'x64',
        _currentBuild = currentBuild ?? veritraBuildNumber,
        _now = now ?? DateTime.now {
    settings.addListener(_onSettingsChanged);
    if (!_canCheck) _status = const UpdateStatus.unavailable();
  }

  final UpdateSettings settings;
  final UpdateClient _client;
  final UpdateSignatureVerifier _verifier;
  final UpdateInstaller? _installer;
  final void Function()? _onQuitForUpdate;
  final Uri _feedUri;
  final String _platform;
  final String _arch;
  final int _currentBuild;
  final DateTime Function() _now;

  UpdateStatus _status = const UpdateStatus.idle();
  DateTime? _lastCheckTime;
  File? _readyInstaller;

  /// Only the Windows channel exists, and only with a verifier that can check
  /// the feed's signature.
  bool get _canCheck => _platform == 'windows' && _verifier.isConfigured;

  UpdateStatus get status => _status;

  /// Whether this install can download and start an update itself (a
  /// per-user Windows install: see [isPerUserWindowsInstall]). Otherwise an
  /// available update is only reported.
  bool get canInstall => _installer != null;
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
    if (!_canCheck) return _setUnavailable();
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
  Future<UpdateStatus> checkForUpdates({
    bool force = false,
    Uri? feedUri,
  }) async {
    // Nothing is requested, not even by a manual check, from a build that
    // cannot verify what comes back.
    if (!_canCheck) return _setUnavailable();
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

      // The signature is checked before the JSON is read at all.
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
        _status = const UpdateStatus.error(
          'Update architecture does not match',
        );
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

  UpdateStatus _setUnavailable() {
    _status = const UpdateStatus.unavailable();
    notifyListeners();
    return _status;
  }

  /// Downloads the installer of the update [status] offers and checks its
  /// SHA-256 against the signed feed. Only from `updateAvailable`, and only
  /// when the user asked (the settings tile); it never starts by itself.
  Future<UpdateStatus> downloadUpdate() async {
    final info = _status.update;
    final installer = _installer;
    if (_status.kind != UpdateStatusKind.updateAvailable ||
        info == null ||
        installer == null) {
      return _status;
    }
    _status = UpdateStatus.downloading(info);
    notifyListeners();
    try {
      _readyInstaller = await installer.download(info);
      _status = UpdateStatus.readyToInstall(info);
    } catch (e) {
      _readyInstaller = null;
      _status = UpdateStatus.downloadFailed(info, e.toString());
    }
    notifyListeners();
    return _status;
  }

  /// Starts the verified installer (checked again just before) and asks the
  /// app to quit so it can replace the files. Only from `readyToInstall`.
  Future<UpdateStatus> installUpdate() async {
    final info = _status.update;
    final file = _readyInstaller;
    final installer = _installer;
    if (_status.kind != UpdateStatusKind.readyToInstall ||
        info == null ||
        file == null ||
        installer == null) {
      return _status;
    }
    // One start per verified download: a second tap before the app quits
    // finds nothing to start.
    _readyInstaller = null;
    try {
      await installer.launch(file, info);
    } catch (e) {
      _readyInstaller = null;
      _status = UpdateStatus.downloadFailed(info, e.toString());
      notifyListeners();
      return _status;
    }
    _onQuitForUpdate?.call();
    return _status;
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
