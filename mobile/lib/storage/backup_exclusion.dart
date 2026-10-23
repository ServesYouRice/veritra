import 'package:flutter/services.dart';

/// Marks local paths as excluded from platform backups and device
/// transfers. Defence in depth only: a copied database cannot be opened
/// without its device-only key.
typedef BackupExclusion = Future<void> Function(List<String> paths);

/// iOS: the Runner sets `NSURLIsExcludedFromBackupKey` on each existing path
/// (see `ios/Runner/AppDelegate.swift`); a directory covers files created in
/// it later. Android needs no call: its manifest's backup and data
/// extraction rules exclude all app data.
abstract final class PlatformBackupExclusion {
  static const channel = MethodChannel('org.veritra.private_messenger/storage');

  static Future<void> exclude(List<String> paths) => channel.invokeMethod<void>(
      'excludeFromBackup', <String, Object?>{'paths': paths});
}
