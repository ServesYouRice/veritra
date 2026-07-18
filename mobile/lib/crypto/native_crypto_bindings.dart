import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/models.dart';

final class _PmByteSlice extends Struct {
  external Pointer<Uint8> data;

  @IntPtr()
  external int len;
}

final class _PmOwnedBuffer extends Struct {
  external Pointer<Uint8> data;

  @IntPtr()
  external int len;
}

final class _PmCryptoHandle extends Opaque {}

typedef _AbiVersionNative = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _DeviceCreateNative = Int32 Function(
  _PmByteSlice,
  _PmByteSlice,
  Pointer<Pointer<_PmCryptoHandle>>,
);
typedef _DeviceCreateDart = int Function(
  _PmByteSlice,
  _PmByteSlice,
  Pointer<Pointer<_PmCryptoHandle>>,
);
typedef _DeviceDestroyNative = Void Function(Pointer<_PmCryptoHandle>);
typedef _DeviceDestroyDart = void Function(Pointer<_PmCryptoHandle>);
typedef _BufferFreeNative = Void Function(_PmOwnedBuffer);
typedef _BufferFreeDart = void Function(_PmOwnedBuffer);
typedef _EnrollmentNative = Int32 Function(
  Pointer<_PmCryptoHandle>,
  _PmByteSlice,
  Pointer<_PmOwnedBuffer>,
  Pointer<_PmOwnedBuffer>,
  Pointer<_PmOwnedBuffer>,
);
typedef _EnrollmentDart = int Function(
  Pointer<_PmCryptoHandle>,
  _PmByteSlice,
  Pointer<_PmOwnedBuffer>,
  Pointer<_PmOwnedBuffer>,
  Pointer<_PmOwnedBuffer>,
);

class NativeCryptoBindings {
  NativeCryptoBindings._(DynamicLibrary library)
      : _abiVersion =
            library.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
                'pm_crypto_abi_version'),
        _deviceCreate =
            library.lookupFunction<_DeviceCreateNative, _DeviceCreateDart>(
                'pm_crypto_device_create'),
        _deviceDestroy =
            library.lookupFunction<_DeviceDestroyNative, _DeviceDestroyDart>(
                'pm_crypto_device_destroy'),
        _bufferFree =
            library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
                'pm_crypto_buffer_free'),
        _createEnrollment =
            library.lookupFunction<_EnrollmentNative, _EnrollmentDart>(
                'pm_crypto_device_create_enrollment_credential') {
    if (_abiVersion() != 2) {
      throw StateError('Unsupported native crypto ABI');
    }
  }

  static const _ok = 0;
  final _AbiVersionDart _abiVersion;
  final _DeviceCreateDart _deviceCreate;
  final _DeviceDestroyDart _deviceDestroy;
  final _BufferFreeDart _bufferFree;
  final _EnrollmentDart _createEnrollment;

  static NativeCryptoBindings load() {
    final library = Platform.isAndroid
        ? DynamicLibrary.open('libprivate_messenger_crypto.so')
        : DynamicLibrary.process();
    return NativeCryptoBindings._(library);
  }

  NativeCryptoDevice createDevice(String accountId, String deviceId) {
    return _withSlices(
      Uint8List.fromList(accountId.codeUnits),
      Uint8List.fromList(deviceId.codeUnits),
      (account, device) {
        final output = calloc<Pointer<_PmCryptoHandle>>();
        try {
          _check(_deviceCreate(account, device, output));
          if (output.value == nullptr) {
            throw StateError('Native crypto returned an empty device handle');
          }
          return NativeCryptoDevice._(this, output.value);
        } finally {
          calloc.free(output);
        }
      },
    );
  }

  EnrollmentCredential createEnrollmentCredential(
    Pointer<_PmCryptoHandle> handle,
    List<int> challenge,
  ) {
    return _withSlice(Uint8List.fromList(challenge), (challengeSlice) {
      final keyPackage = calloc<_PmOwnedBuffer>();
      final signingKey = calloc<_PmOwnedBuffer>();
      final signature = calloc<_PmOwnedBuffer>();
      try {
        _check(_createEnrollment(
          handle,
          challengeSlice,
          keyPackage,
          signingKey,
          signature,
        ));
        return EnrollmentCredential(
          deviceKeyPackage: _take(keyPackage.ref),
          signingKey: _take(signingKey.ref),
          challengeSignature: _take(signature.ref),
        );
      } finally {
        calloc.free(keyPackage);
        calloc.free(signingKey);
        calloc.free(signature);
      }
    });
  }

  List<int> _take(_PmOwnedBuffer buffer) {
    if (buffer.data == nullptr || buffer.len == 0) {
      throw StateError('Native crypto returned an empty output');
    }
    try {
      return Uint8List.fromList(buffer.data.asTypedList(buffer.len));
    } finally {
      _bufferFree(buffer);
    }
  }

  void _check(int code) {
    if (code != _ok) {
      throw StateError('Native crypto operation failed ($code)');
    }
  }

  T _withSlice<T>(Uint8List bytes, T Function(_PmByteSlice) operation) {
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes');
    final data = calloc<Uint8>(bytes.length);
    final slice = calloc<_PmByteSlice>();
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      slice.ref
        ..data = data
        ..len = bytes.length;
      return operation(slice.ref);
    } finally {
      data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(slice);
      calloc.free(data);
    }
  }

  T _withSlices<T>(
    Uint8List first,
    Uint8List second,
    T Function(_PmByteSlice, _PmByteSlice) operation,
  ) {
    return _withSlice(first, (firstSlice) {
      return _withSlice(second, (secondSlice) {
        return operation(firstSlice, secondSlice);
      });
    });
  }
}

class NativeCryptoDevice {
  NativeCryptoDevice._(this._bindings, this._handle);

  final NativeCryptoBindings _bindings;
  Pointer<_PmCryptoHandle> _handle;

  EnrollmentCredential createEnrollmentCredential(List<int> challenge) {
    if (_handle == nullptr) throw StateError('Native crypto device is closed');
    return _bindings.createEnrollmentCredential(_handle, challenge);
  }

  void close() {
    if (_handle == nullptr) return;
    _bindings._deviceDestroy(_handle);
    _handle = nullptr;
  }
}
