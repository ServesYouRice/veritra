import 'dart:async';
import 'dart:io';

/// What the installer step needs to know about an update. [UpdateInfo]
/// (update_service.dart) implements it; the split keeps the files independent.
abstract interface class UpdateInstallTarget {
  String get version;
  String get url;
  String get sha256;
}

/// Largest installer the app will download (the real one is far smaller).
const int maxInstallerBytes = 512 * 1024 * 1024;

/// A downloaded installer did not match the digest the signed feed names.
class UpdateDigestMismatch implements Exception {
  const UpdateDigestMismatch();

  @override
  String toString() => 'The downloaded update does not match its signed digest';
}

abstract interface class UpdateDownloader {
  /// Writes the response body of [url] to [destination]. At most [maxBytes];
  /// https only, including every redirect; no cookies or credentials.
  Future<void> download(Uri url, File destination, {required int maxBytes});
}

abstract interface class FileDigester {
  /// Lowercase hex SHA-256 of [file].
  Future<String> sha256Hex(File file);
}

abstract interface class InstallerLauncher {
  /// Starts [installer] so that it outlives this process.
  Future<void> launch(File installer);
}

/// Downloads an update's installer, proves it is the file the signed feed
/// described, and starts it. It is only reachable from [UpdateService] after a
/// feed signature was verified and the user pressed the download tile, and the
/// installer is checked a second time just before it runs, so a file swapped
/// in the temporary folder in between never runs.
class UpdateInstaller {
  UpdateInstaller({
    required this.downloader,
    required this.digester,
    required this.launcher,
    Directory? tempRoot,
    this.maxBytes = maxInstallerBytes,
  }) : _tempRoot = tempRoot;

  final UpdateDownloader downloader;
  final FileDigester digester;
  final InstallerLauncher launcher;
  final int maxBytes;
  final Directory? _tempRoot;

  static final RegExp _safeVersion =
      RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$');

  Future<File> download(UpdateInstallTarget info) async {
    final url = Uri.tryParse(info.url);
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const FormatException('Update URL must use https');
    }
    if (!_safeVersion.hasMatch(info.version)) {
      throw const FormatException('Update version is not a plain version');
    }
    final dir = await (_tempRoot ?? Directory.systemTemp).createTemp(
      'veritra-update-',
    );
    try {
      // A name this code chooses, never one taken from the URL or the server.
      final file = File(
        '${dir.path}${Platform.pathSeparator}Veritra-Setup-${info.version}-x64.exe',
      );
      await downloader.download(url, file, maxBytes: maxBytes);
      if (await digester.sha256Hex(file) != info.sha256) {
        throw const UpdateDigestMismatch();
      }
      return file;
    } catch (_) {
      await _discard(dir);
      rethrow;
    }
  }

  /// Checks [installer] against [info] again and starts it.
  Future<void> launch(File installer, UpdateInstallTarget info) async {
    if (await digester.sha256Hex(installer) != info.sha256) {
      await _discard(installer.parent);
      throw const UpdateDigestMismatch();
    }
    await launcher.launch(installer);
  }

  static Future<void> _discard(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// HTTPS download with a size cap. Redirects (GitHub serves release assets
/// from another host) are followed by hand, at most five, each only to https.
class HttpUpdateDownloader implements UpdateDownloader {
  const HttpUpdateDownloader({
    this.timeout = const Duration(seconds: 30),
    this.client,
  });

  final Duration timeout;
  final HttpClient? client;

  @override
  Future<void> download(
    Uri url,
    File destination, {
    required int maxBytes,
  }) async {
    final http = client ?? HttpClient();
    http.connectionTimeout = timeout;
    try {
      var target = url;
      for (var hop = 0; hop <= 5; hop++) {
        if (target.scheme != 'https' || target.host.isEmpty) {
          throw const FormatException('Update download must use https');
        }
        final request = await http.getUrl(target).timeout(timeout);
        request.followRedirects = false;
        request.cookies.clear();
        final response = await request.close().timeout(timeout);
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) {
            throw const HttpException('Update download redirect has no target');
          }
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException(
            'Update download answered HTTP ${response.statusCode}',
          );
        }
        if (response.contentLength > maxBytes) {
          await response.drain<void>();
          throw const FormatException('Update download exceeds size limit');
        }
        final sink = destination.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.timeout(timeout)) {
            received += chunk.length;
            if (received > maxBytes) {
              throw const FormatException('Update download exceeds size limit');
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        return;
      }
      throw const HttpException('Update download redirected too often');
    } finally {
      if (client == null) http.close(force: true);
    }
  }
}

/// SHA-256 through Windows' own `certutil`, which streams the file (the plain
/// Dart hash in lib/crypto/sha256.dart is for 43-byte tokens, not installers).
class CertutilFileDigester implements FileDigester {
  const CertutilFileDigester();

  @override
  Future<String> sha256Hex(File file) async {
    final result = await Process.run('certutil', <String>[
      '-hashfile',
      file.path,
      'SHA256',
    ]);
    if (result.exitCode != 0) {
      throw const ProcessException('certutil', <String>[], 'hash failed');
    }
    // Line 2 is the digest (older versions print it with spaces).
    final lines = (result.stdout as String).split(RegExp(r'\r?\n'));
    final digest = lines.length > 1
        ? lines[1].replaceAll(RegExp(r'\s'), '').toLowerCase()
        : '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('certutil printed no SHA-256');
    }
    return digest;
  }
}

/// Runs the Inno Setup installer: silent (no questions, progress only), no
/// reboot, applications closed by Restart Manager. Detached, so it survives
/// this app quitting to let the installer replace its files.
class InnoInstallerLauncher implements InstallerLauncher {
  const InnoInstallerLauncher();

  @override
  Future<void> launch(File installer) async {
    await Process.start(
        installer.path,
        const <String>[
          '/SILENT',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached);
  }
}
