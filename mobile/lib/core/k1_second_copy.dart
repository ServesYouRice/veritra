import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// Writes to a folder on the file system (Windows, Linux, macOS).
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

/// The platform channel of the phone second copy: Android's picked
/// document tree (`MainActivity`, `K1SecondCopy.kt`) and iOS's manual export
/// (`AppDelegate.swift`). Registered with the shared engine on both.
const String k1SecondCopyChannelName =
    'org.veritra.private_messenger/k1_second_copy';

/// An Android document tree, which only the channel can write.
bool isK1DocumentTree(String folder) => folder.startsWith('content://');

/// How this platform keeps the second copy (D91): automatically in a picked
/// folder (desktop and Android), as a manual export (iOS), or not at all.
enum K1SecondCopyMode { folder, export, none }

K1SecondCopyMode k1SecondCopyModeFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.android =>
        K1SecondCopyMode.folder,
      TargetPlatform.iOS => K1SecondCopyMode.export,
      TargetPlatform.fuchsia => K1SecondCopyMode.none,
    };

/// This build's mode. [defaultTargetPlatform], so tests can pick one.
K1SecondCopyMode get k1SecondCopyMode =>
    kIsWeb ? K1SecondCopyMode.none : k1SecondCopyModeFor(defaultTargetPlatform);

/// A picked folder: where it is (a path, or an Android tree URI) and the
/// name Settings shows, never the URI.
typedef K1PickedFolder = ({String folder, String label});

/// The phone side of the channel. Every call throws [PlatformException] on
/// failure; the codes carry no names or paths.
class K1SecondCopyChannel {
  const K1SecondCopyChannel(
      [this.channel = const MethodChannel(k1SecondCopyChannelName)]);

  final MethodChannel channel;

  /// Android: the system folder picker. Null when the user cancels. The
  /// grant is persisted on the Kotlin side.
  Future<K1PickedFolder?> pickFolder() async {
    final picked = await channel.invokeMapMethod<String, Object?>('pickFolder');
    if (picked == null) return null;
    final tree = picked['tree'];
    if (tree is! String || !isK1DocumentTree(tree)) {
      throw PlatformException(code: 'invalid_answer');
    }
    final label = picked['label'];
    return (folder: tree, label: label is String ? label : '');
  }

  /// Android: gives up the grant of a folder no longer used (the number of
  /// persisted grants is capped).
  Future<void> release(String tree) =>
      channel.invokeMethod<void>('release', <String, Object?>{'tree': tree});

  /// Android: replaces the copy in [tree], through a temporary file.
  Future<void> write(String tree, String name, Uint8List bytes) =>
      channel.invokeMethod<void>('write',
          <String, Object?>{'tree': tree, 'name': name, 'bytes': bytes});

  /// iOS: the system document picker saves [bytes] as [name] where the user
  /// chooses. True when saved, false when cancelled.
  Future<bool> export(String name, Uint8List bytes) async =>
      await channel.invokeMethod<bool>(
          'export', <String, Object?>{'name': name, 'bytes': bytes}) ??
      false;
}

/// The writer the app uses: an Android tree goes through the channel, a
/// path to the file system.
class PlatformK1SecondCopyWriter implements K1SecondCopyWriter {
  const PlatformK1SecondCopyWriter(
      {this.channel = const K1SecondCopyChannel(),
      this.files = const FileK1SecondCopyWriter()});

  final K1SecondCopyChannel channel;
  final K1SecondCopyWriter files;

  @override
  Future<void> write(
      {required String folder,
      required String accountId,
      required String deviceId,
      required Uint8List ciphertext}) {
    if (!isK1DocumentTree(folder)) {
      return files.write(
          folder: folder,
          accountId: accountId,
          deviceId: deviceId,
          ciphertext: ciphertext);
    }
    return channel.write(
        folder, k1SecondCopyFileName(accountId, deviceId), ciphertext);
  }
}
