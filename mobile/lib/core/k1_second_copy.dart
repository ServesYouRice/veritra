import 'dart:io';
import 'dart:typed_data';

/// The second copy of a K1 backup, saved where the user picks (design,
/// "Second copy"). It is the same ciphertext the server holds: it opens with
/// the recovery key alone and needs no password or account. A failure here
/// never fails the backup; it shows its own warning.
abstract interface class K1SecondCopyWriter {
  /// Replaces the copy in [folder] with [ciphertext]: a temporary file is
  /// written and renamed over the old one, so a crash leaves the old copy or
  /// the new, never half of one. Throws on any failure.
  Future<void> write(
      {required String folder,
      required String accountId,
      required String deviceId,
      required Uint8List ciphertext});
}

/// The file name of one device's copy. Ids are reduced to safe characters.
String k1SecondCopyFileName(String accountId, String deviceId) {
  String safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return 'veritra-backup-${safe(accountId)}-${safe(deviceId)}.vhc';
}

/// Writes to a folder on the file system (Windows, Linux, macOS). Android
/// (a picked document tree) and iOS (manual export) need platform code that
/// is not built yet; see docs/designs/K1-automatic-backups.md.
class FileK1SecondCopyWriter implements K1SecondCopyWriter {
  const FileK1SecondCopyWriter();

  @override
  Future<void> write(
      {required String folder,
      required String accountId,
      required String deviceId,
      required Uint8List ciphertext}) async {
    final dir = Directory(folder);
    if (!await dir.exists()) throw FileSystemException('no folder', folder);
    final name = k1SecondCopyFileName(accountId, deviceId);
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    final temp = File('${target.path}.part');
    try {
      await temp.writeAsBytes(ciphertext, flush: true);
      await temp.rename(target.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

/// Whether this platform can keep a second copy automatically in a folder.
bool get k1SecondCopySupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
