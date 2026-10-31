import 'package:private_messenger/crypto/native_crypto_bindings.dart';

/// Seals a device that was never sealed (so every record is in the change
/// set) at [generation] and restores it from those records (D70, ABI 10).
NativeCryptoDevice reopenFreshDevice(NativeCryptoBindings bindings,
    NativeCryptoDevice device, String accountId, String deviceId,
    {required List<int> stateKey, int generation = 1}) {
  final sealed = device.sealChanges(stateKey, generation);
  device.close();
  final restored = bindings.restoreRecords(
      accountId, deviceId, stateKey, generation, sealed.root, [
    for (final change in sealed.changes)
      if (change.sealed != null) change.sealed!,
  ]);
  if (restored.generation != generation) {
    throw StateError('restored generation mismatch');
  }
  return restored.device;
}
