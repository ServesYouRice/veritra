import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'server_origin.dart' show canonicalizeServerOrigin;

/// Custody of an instance owner's report-key seed (C6, D95). The seed opens
/// every report sealed to the owner's published report key, so it stays only
/// in protected platform storage on the device that made it: never in the
/// database, a backup, a log or the server. One seed per server and account.
///
/// There is deliberately no copy to another device. A second device sees
/// "this account's report key is held elsewhere" and may replace the key
/// (new seed here, new key published, reporters pin it again); reports sealed
/// to the old key stay readable only where the old seed is.
abstract interface class ReportSeedStore {
  /// The 32-byte seed, or null when this device holds none.
  Future<Uint8List?> load(String origin, String accountId);

  Future<void> save(String origin, String accountId, Uint8List seed);

  Future<void> delete(String origin, String accountId);
}

const int reportSeedBytes = 32;

String _name(String origin, String accountId) =>
    'veritra.report_seed.v1.${canonicalizeServerOrigin(origin)}.$accountId';

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Uint8List? _fromHex(String? text) {
  if (text == null || text.length != reportSeedBytes * 2) return null;
  final out = Uint8List(reportSeedBytes);
  for (var i = 0; i < out.length; i++) {
    final value = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (value == null) return null;
    out[i] = value;
  }
  return out;
}

/// The platform keystore, reached through `flutter_secure_storage`. Android's
/// and iOS's backup rules already exclude it from cloud backups of the app's
/// files; the value is also never written anywhere else.
class SecureReportSeedStore implements ReportSeedStore {
  SecureReportSeedStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> load(String origin, String accountId) async =>
      _fromHex(await _storage.read(key: _name(origin, accountId)));

  @override
  Future<void> save(String origin, String accountId, Uint8List seed) async {
    if (seed.length != reportSeedBytes) {
      throw ArgumentError.value(seed.length, 'seed');
    }
    final key = _name(origin, accountId);
    await _storage.write(key: key, value: _hex(seed));
    // A keystore that accepted nothing must not look like custody.
    if (await _storage.read(key: key) != _hex(seed)) {
      throw StateError('report key storage failed');
    }
  }

  @override
  Future<void> delete(String origin, String accountId) =>
      _storage.delete(key: _name(origin, accountId));
}

/// Memory only, for tests and builds with no protected storage. A seed here
/// is lost with the process, so a report key made with it cannot be opened
/// later.
class MemoryReportSeedStore implements ReportSeedStore {
  final Map<String, Uint8List> _seeds = <String, Uint8List>{};

  @override
  Future<Uint8List?> load(String origin, String accountId) async {
    final seed = _seeds[_name(origin, accountId)];
    return seed == null ? null : Uint8List.fromList(seed);
  }

  @override
  Future<void> save(String origin, String accountId, Uint8List seed) async {
    _seeds[_name(origin, accountId)] = Uint8List.fromList(seed);
  }

  @override
  Future<void> delete(String origin, String accountId) async {
    _seeds.remove(_name(origin, accountId));
  }
}
