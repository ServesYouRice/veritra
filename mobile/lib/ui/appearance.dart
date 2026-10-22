import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the System/Light/Dark choice is kept. It is a device preference, not
/// account data: it survives sign-out and holds no message content.
abstract class AppearanceStore {
  Future<ThemeMode?> load();
  Future<void> save(ThemeMode mode);
}

/// Keeps the choice in the platform keystore the app already uses for its
/// database key. Any keystore failure falls back to following the system;
/// a theme preference must never block startup.
class SecureAppearanceStore implements AppearanceStore {
  SecureAppearanceStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: false),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              // Same reason as SecureLocalStore: unsigned macOS demo builds
              // cannot use the data protection keychain.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  static const key = 'veritra.appearance.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<ThemeMode?> load() async {
    try {
      return themeModeFromName(await _storage.read(key: key));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(ThemeMode mode) async {
    try {
      await _storage.write(key: key, value: mode.name);
    } catch (_) {
      // The choice still applies for this run.
    }
  }
}

class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.value]);

  ThemeMode? value;

  @override
  Future<ThemeMode?> load() async => value;

  @override
  Future<void> save(ThemeMode mode) async => value = mode;
}

ThemeMode? themeModeFromName(String? name) {
  for (final mode in ThemeMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}

class AppearanceController extends ChangeNotifier {
  AppearanceController(this._store);

  final AppearanceStore _store;
  ThemeMode _mode = ThemeMode.system;
  bool _changed = false;

  ThemeMode get mode => _mode;

  /// Reads the saved choice. A choice made before the read finishes wins.
  Future<void> load() async {
    final saved = await _store.load();
    if (saved == null || _changed || saved == _mode) return;
    _mode = saved;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _changed = true;
    if (mode != _mode) {
      _mode = mode;
      notifyListeners();
    }
    await _store.save(mode);
  }
}

/// Makes the appearance controller reachable from settings without threading
/// it through every screen.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    required AppearanceController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
