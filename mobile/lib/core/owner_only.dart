import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Owner read, write and search: 0700.
const int _ownerOnlyMode = 0x1c0;

typedef _ChmodLinuxNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodMacNative = Int32 Function(Pointer<Utf8>, Uint16);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);

_ChmodDart? _chmod;

_ChmodDart _lookupChmod() {
  final libc = DynamicLibrary.process();
  // mode_t is 32 bits on Linux and 16 bits on macOS.
  return Platform.isMacOS
      ? libc.lookupFunction<_ChmodMacNative, _ChmodDart>('chmod')
      : libc.lookupFunction<_ChmodLinuxNative, _ChmodDart>('chmod');
}

/// Makes [directory] readable only by its owner (0700) on Linux and macOS,
/// where a new folder takes the process umask and is often readable by
/// every local user. Elsewhere it does nothing: the app's folders are
/// already private (Android, iOS) or protected by the profile's ACL
/// (Windows). Throws a [FileSystemException] when the mode cannot be set,
/// so a caller about to write private data there can refuse.
void restrictDirectoryToOwner(Directory directory) {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  final chmod = _chmod ??= _lookupChmod();
  final path = directory.path.toNativeUtf8();
  try {
    if (chmod(path, _ownerOnlyMode) != 0) {
      throw FileSystemException(
          'Cannot make the folder private to its owner', directory.path);
    }
  } finally {
    malloc.free(path);
  }
}
