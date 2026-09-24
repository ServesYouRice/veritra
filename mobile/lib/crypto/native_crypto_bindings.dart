import 'dart:convert';
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
typedef _RestoreNative = Int32 Function(
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Uint64,
    _PmByteSlice,
    Pointer<Pointer<_PmCryptoHandle>>,
    Pointer<Uint64>);
typedef _RestoreDart = int Function(_PmByteSlice, _PmByteSlice, _PmByteSlice,
    int, _PmByteSlice, Pointer<Pointer<_PmCryptoHandle>>, Pointer<Uint64>);
typedef _HandleOutputNative = Int32 Function(
    Pointer<_PmCryptoHandle>, Pointer<_PmOwnedBuffer>);
typedef _HandleOutputDart = int Function(
    Pointer<_PmCryptoHandle>, Pointer<_PmOwnedBuffer>);
typedef _HandleSliceNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice);
typedef _HandleSliceDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice);
typedef _HandleSliceOutputNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _HandleSliceOutputDart = int Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _HandleSliceTwoOutputsNative = Int32 Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _HandleSliceTwoOutputsDart = int Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _DeviceLinkTranscriptNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Uint8,
    Pointer<_PmOwnedBuffer>);
typedef _DeviceLinkTranscriptDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    int,
    Pointer<_PmOwnedBuffer>);
typedef _HandleTwoSlicesNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, _PmByteSlice);
typedef _HandleTwoSlicesDart = int Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, _PmByteSlice);
typedef _HandleTwoSlicesOutputNative = Int32 Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _HandleTwoSlicesOutputDart = int Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _AddMemberNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _AddMemberDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _RemoveMemberNative = Int32 Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _RemoveMemberDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _StageCommitNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _StageCommitDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _GroupEpochNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<Uint64>, Pointer<Uint8>);
typedef _GroupEpochDart = int Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<Uint64>, Pointer<Uint8>);
typedef _DecryptNative = Int32 Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _DecryptDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _SealNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Uint64, Pointer<_PmOwnedBuffer>);
typedef _SealDart = int Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, int, Pointer<_PmOwnedBuffer>);
typedef _AttachmentChunkNative = Int32 Function(_PmByteSlice, _PmByteSlice,
    Uint32, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _AttachmentChunkDart = int Function(_PmByteSlice, _PmByteSlice, int,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);

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
                'pm_crypto_device_create_enrollment_credential'),
        _restore = library.lookupFunction<_RestoreNative, _RestoreDart>(
            'pm_crypto_device_restore'),
        _signingKey =
            library.lookupFunction<_HandleOutputNative, _HandleOutputDart>(
                'pm_crypto_device_signing_public_key'),
        _deviceLinkTranscript = library.lookupFunction<
            _DeviceLinkTranscriptNative,
            _DeviceLinkTranscriptDart>('pm_crypto_device_link_transcript_hash'),
        _signChallenge = library
            .lookupFunction<_HandleSliceOutputNative, _HandleSliceOutputDart>(
                'pm_crypto_device_sign_enrollment_challenge'),
        _createKeyPackage =
            library.lookupFunction<_HandleOutputNative, _HandleOutputDart>(
                'pm_crypto_device_create_key_package'),
        _seal = library.lookupFunction<_SealNative, _SealDart>(
            'pm_crypto_device_seal_state'),
        _groupCreate =
            library.lookupFunction<_HandleSliceNative, _HandleSliceDart>(
                'pm_crypto_group_create'),
        _groupJoin = library.lookupFunction<_HandleTwoSlicesNative,
            _HandleTwoSlicesDart>('pm_crypto_group_join'),
        _groupAdd = library.lookupFunction<_AddMemberNative, _AddMemberDart>(
            'pm_crypto_group_add_member'),
        _groupCommit = library.lookupFunction<_HandleTwoSlicesNative,
            _HandleTwoSlicesDart>('pm_crypto_group_process_commit'),
        _groupUpdate = library.lookupFunction<_HandleSliceOutputNative,
            _HandleSliceOutputDart>('pm_crypto_group_self_update'),
        _groupSafety = library.lookupFunction<_HandleSliceTwoOutputsNative,
            _HandleSliceTwoOutputsDart>('pm_crypto_group_safety_number'),
        _groupRemove =
            library.lookupFunction<_RemoveMemberNative, _RemoveMemberDart>(
                'pm_crypto_group_remove_member'),
        _groupStageCommit =
            library.lookupFunction<_StageCommitNative, _StageCommitDart>(
                'pm_crypto_group_stage_commit'),
        _groupMergePending =
            library.lookupFunction<_HandleSliceNative, _HandleSliceDart>(
                'pm_crypto_group_merge_pending_commit'),
        _groupClearPending =
            library.lookupFunction<_HandleSliceNative, _HandleSliceDart>(
                'pm_crypto_group_clear_pending_commit'),
        _groupEpoch =
            library.lookupFunction<_GroupEpochNative, _GroupEpochDart>(
                'pm_crypto_group_epoch'),
        _groupEncrypt = library.lookupFunction<_HandleTwoSlicesOutputNative,
            _HandleTwoSlicesOutputDart>('pm_crypto_group_encrypt'),
        _groupDecrypt = library.lookupFunction<_DecryptNative, _DecryptDart>(
            'pm_crypto_group_decrypt'),
        _attachmentEncrypt = library.lookupFunction<_AttachmentChunkNative,
            _AttachmentChunkDart>('pm_crypto_attachment_encrypt_chunk'),
        _attachmentDecrypt = library.lookupFunction<_AttachmentChunkNative,
            _AttachmentChunkDart>('pm_crypto_attachment_decrypt_chunk') {
    if (_abiVersion() != 6) {
      throw const NativeCryptoException(NativeCryptoError.abiMismatch);
    }
    _deviceFinalizer = NativeFinalizer(library
        .lookup<NativeFunction<_DeviceDestroyNative>>(
            'pm_crypto_device_destroy')
        .cast());
  }

  static const _ok = 0;
  final _AbiVersionDart _abiVersion;
  final _DeviceCreateDart _deviceCreate;
  final _DeviceDestroyDart _deviceDestroy;
  final _BufferFreeDart _bufferFree;
  final _EnrollmentDart _createEnrollment;
  final _RestoreDart _restore;
  final _HandleOutputDart _signingKey;
  final _DeviceLinkTranscriptDart _deviceLinkTranscript;
  final _HandleSliceOutputDart _signChallenge;
  final _HandleOutputDart _createKeyPackage;
  final _SealDart _seal;
  final _HandleSliceDart _groupCreate;
  final _HandleTwoSlicesDart _groupJoin;
  final _AddMemberDart _groupAdd;
  final _HandleTwoSlicesDart _groupCommit;
  final _HandleSliceOutputDart _groupUpdate;
  final _HandleSliceTwoOutputsDart _groupSafety;
  final _RemoveMemberDart _groupRemove;
  final _StageCommitDart _groupStageCommit;
  final _HandleSliceDart _groupMergePending;
  final _HandleSliceDart _groupClearPending;
  final _GroupEpochDart _groupEpoch;
  final _HandleTwoSlicesOutputDart _groupEncrypt;
  final _DecryptDart _groupDecrypt;
  final _AttachmentChunkDart _attachmentEncrypt;
  final _AttachmentChunkDart _attachmentDecrypt;
  late final NativeFinalizer _deviceFinalizer;

  /// Loads the library bundled with the app.
  ///
  /// Android loads the JNI `.so` by name. iOS and macOS link the static library
  /// into the executable. Windows and Linux load the library from the app's
  /// own directory by absolute path, never through the system search path.
  static NativeCryptoBindings load() {
    return NativeCryptoBindings._(_openBundledLibrary());
  }

  static DynamicLibrary _openBundledLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libprivate_messenger_crypto.so');
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    final appDirectory = File(Platform.resolvedExecutable).parent.path;
    final separator = Platform.pathSeparator;
    if (Platform.isWindows) {
      return DynamicLibrary.open(
          '$appDirectory${separator}private_messenger_crypto.dll');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open(
          '$appDirectory${separator}lib${separator}libprivate_messenger_crypto.so');
    }
    throw UnsupportedError(
        'No bundled Veritra crypto library for this platform');
  }

  static NativeCryptoBindings open(String path) =>
      NativeCryptoBindings._(DynamicLibrary.open(path));

  List<int> encryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> plaintext,
  }) =>
      _attachmentChunk(
          _attachmentEncrypt, key, noncePrefix, chunkIndex, context, plaintext);

  List<int> decryptAttachmentChunk({
    required List<int> key,
    required List<int> noncePrefix,
    required int chunkIndex,
    required List<int> context,
    required List<int> ciphertext,
  }) =>
      _attachmentChunk(_attachmentDecrypt, key, noncePrefix, chunkIndex,
          context, ciphertext);

  List<int> _attachmentChunk(
    _AttachmentChunkDart operation,
    List<int> key,
    List<int> noncePrefix,
    int chunkIndex,
    List<int> context,
    List<int> input,
  ) {
    _bounded(key, 32, exact: true);
    _bounded(noncePrefix, 8, exact: true);
    _bounded(context, 512);
    _bounded(input, 1024 * 1024 + 16);
    if (chunkIndex < 0 || chunkIndex > 0xffffffff) {
      throw ArgumentError.value(chunkIndex, 'chunkIndex');
    }
    return _withByteLists(
        <List<int>>[key, noncePrefix, context, input],
        (slices) => _output((out) => operation(
            slices[0], slices[1], chunkIndex, slices[2], slices[3], out)));
  }

  NativeCryptoDevice createDevice(String accountId, String deviceId) {
    _bounded(accountId.codeUnits, 128);
    _bounded(deviceId.codeUnits, 128);
    return _withSlices(
      Uint8List.fromList(accountId.codeUnits),
      Uint8List.fromList(deviceId.codeUnits),
      (account, device) {
        final output = calloc<Pointer<_PmCryptoHandle>>();
        try {
          _check(_deviceCreate(account, device, output));
          if (output.value == nullptr) {
            throw const NativeCryptoException(
                NativeCryptoError.operationFailed);
          }
          return NativeCryptoDevice._(this, output.value);
        } finally {
          calloc.free(output);
        }
      },
    );
  }

  ({NativeCryptoDevice device, int counter}) restoreDevice(
      String accountId,
      String deviceId,
      List<int> stateKey,
      int minimumCounter,
      List<int> sealedState) {
    _bounded(accountId.codeUnits, 128);
    _bounded(deviceId.codeUnits, 128);
    _bounded(stateKey, 32, exact: true);
    _bounded(sealedState, 32 * 1024 * 1024);
    if (minimumCounter < 0) {
      throw ArgumentError.value(minimumCounter, 'minimumCounter');
    }
    return _withByteLists(
        [accountId.codeUnits, deviceId.codeUnits, stateKey, sealedState],
        (slices) {
      final handle = calloc<Pointer<_PmCryptoHandle>>();
      final counter = calloc<Uint64>();
      try {
        _check(_restore(slices[0], slices[1], slices[2], minimumCounter,
            slices[3], handle, counter));
        if (handle.value == nullptr) {
          throw const NativeCryptoException(NativeCryptoError.operationFailed);
        }
        return (
          device: NativeCryptoDevice._(this, handle.value),
          counter: counter.value
        );
      } finally {
        calloc.free(counter);
        calloc.free(handle);
      }
    });
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
        final packageBytes = _take(keyPackage.ref);
        keyPackage.ref.data = nullptr;
        final signingBytes = _take(signingKey.ref);
        signingKey.ref.data = nullptr;
        final signatureBytes = _take(signature.ref);
        signature.ref.data = nullptr;
        return EnrollmentCredential(
          deviceKeyPackage: packageBytes,
          signingKey: signingBytes,
          challengeSignature: signatureBytes,
        );
      } finally {
        if (keyPackage.ref.data != nullptr) _bufferFree(keyPackage.ref);
        if (signingKey.ref.data != nullptr) _bufferFree(signingKey.ref);
        if (signature.ref.data != nullptr) _bufferFree(signature.ref);
        calloc.free(keyPackage);
        calloc.free(signingKey);
        calloc.free(signature);
      }
    });
  }

  List<int> _take(_PmOwnedBuffer buffer) {
    if (buffer.data == nullptr ||
        buffer.len == 0 ||
        buffer.len > 32 * 1024 * 1024) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    try {
      return Uint8List.fromList(buffer.data.asTypedList(buffer.len));
    } finally {
      _bufferFree(buffer);
    }
  }

  List<int> _output(int Function(Pointer<_PmOwnedBuffer>) operation) {
    final output = calloc<_PmOwnedBuffer>();
    try {
      _check(operation(output));
      final bytes = _take(output.ref);
      output.ref
        ..data = nullptr
        ..len = 0;
      return bytes;
    } finally {
      if (output.ref.data != nullptr) _bufferFree(output.ref);
      calloc.free(output);
    }
  }

  ({List<int> first, List<int> second}) _twoOutputs(
      int Function(Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>)
          operation) {
    final first = calloc<_PmOwnedBuffer>();
    final second = calloc<_PmOwnedBuffer>();
    try {
      _check(operation(first, second));
      final firstBytes = _take(first.ref);
      first.ref
        ..data = nullptr
        ..len = 0;
      final secondBytes = _take(second.ref);
      second.ref
        ..data = nullptr
        ..len = 0;
      return (first: firstBytes, second: secondBytes);
    } finally {
      if (first.ref.data != nullptr) _bufferFree(first.ref);
      if (second.ref.data != nullptr) _bufferFree(second.ref);
      calloc.free(first);
      calloc.free(second);
    }
  }

  void _check(int code) {
    if (code == _ok) return;
    throw NativeCryptoException(switch (code) {
      -2 => NativeCryptoError.invalidArgument,
      -3 => NativeCryptoError.operationFailed,
      -4 => NativeCryptoError.nativePanic,
      -5 => NativeCryptoError.senderMismatch,
      _ => NativeCryptoError.unknown,
    });
  }

  void _bounded(List<int> bytes, int maximum, {bool exact = false}) {
    if (bytes.isEmpty ||
        bytes.length > maximum ||
        (exact && bytes.length != maximum) ||
        bytes.any((value) => value < 0 || value > 255)) {
      throw ArgumentError('Native crypto input has an invalid size');
    }
  }

  T _withByteLists<T>(
      List<List<int>> values, T Function(List<_PmByteSlice>) operation) {
    T visit(int index, List<_PmByteSlice> slices) {
      if (index == values.length) return operation(slices);
      return _withSlice(Uint8List.fromList(values[index]),
          (slice) => visit(index + 1, [...slices, slice]));
    }

    return visit(0, const []);
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

enum NativeCryptoError {
  abiMismatch,
  invalidArgument,
  operationFailed,
  nativePanic,

  /// The message decrypted, but its MLS sender is not the account/device the
  /// server claimed (ABI 5). The group ratchet has already advanced.
  senderMismatch,
  invalidOutput,
  unknown
}

class NativeCryptoException implements Exception {
  const NativeCryptoException(this.kind);
  final NativeCryptoError kind;

  @override
  String toString() => 'NativeCryptoException(${kind.name})';
}

class NativeCryptoDevice implements Finalizable {
  NativeCryptoDevice._(this._bindings, this._handle) {
    _bindings._deviceFinalizer.attach(this, _handle.cast(), detach: this);
  }

  final NativeCryptoBindings _bindings;
  Pointer<_PmCryptoHandle> _handle;

  Pointer<_PmCryptoHandle> get _liveHandle {
    if (_handle == nullptr) throw StateError('Native crypto device is closed');
    return _handle;
  }

  EnrollmentCredential createEnrollmentCredential(List<int> challenge) {
    _bindings._bounded(challenge, 4096);
    return _bindings.createEnrollmentCredential(_liveHandle, challenge);
  }

  List<int> signingPublicKey() =>
      _bindings._output((out) => _bindings._signingKey(_liveHandle, out));

  DeviceLinkVerification deriveDeviceLinkVerification({
    required String protocolVersion,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required List<int> linkNonce,
    required bool localIsExistingDevice,
  }) {
    _bindings._bounded(protocolVersion.codeUnits, 64);
    _bindings._bounded(peerDeviceId.codeUnits, 128);
    _bindings._bounded(peerSigningKey, 32, exact: true);
    _bindings._bounded(linkNonce, 32, exact: true);
    final transcriptHash = _bindings._withByteLists(
      [
        protocolVersion.codeUnits,
        peerDeviceId.codeUnits,
        peerSigningKey,
        linkNonce
      ],
      (slices) => _bindings._output((out) => _bindings._deviceLinkTranscript(
          _liveHandle,
          slices[0],
          slices[1],
          slices[2],
          slices[3],
          localIsExistingDevice ? 1 : 0,
          out)),
    );
    if (transcriptHash.length != 32) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    final sasValue = ByteData.sublistView(Uint8List.fromList(transcriptHash))
            .getUint32(0, Endian.big) %
        100000000;
    return DeviceLinkVerification(
      transcriptHash: transcriptHash,
      sas: sasValue.toString().padLeft(8, '0'),
    );
  }

  List<int> signEnrollmentChallenge(List<int> challenge) {
    _bindings._bounded(challenge, 4096);
    return _bindings._withSlice(
        Uint8List.fromList(challenge),
        (slice) => _bindings._output(
            (out) => _bindings._signChallenge(_liveHandle, slice, out)));
  }

  List<int> createKeyPackage() =>
      _bindings._output((out) => _bindings._createKeyPackage(_liveHandle, out));

  List<int> sealState(List<int> stateKey, int counter) {
    _bindings._bounded(stateKey, 32, exact: true);
    if (counter <= 0) throw ArgumentError.value(counter, 'counter');
    return _bindings._withSlice(
        Uint8List.fromList(stateKey),
        (key) => _bindings
            ._output((out) => _bindings._seal(_liveHandle, key, counter, out)));
  }

  void createGroup(String groupId) => _withOne(groupId.codeUnits,
      (group) => _bindings._groupCreate(_liveHandle, group), 128);

  void joinGroup(String expectedGroupId, List<int> welcome) {
    _bindings._bounded(expectedGroupId.codeUnits, 128);
    _bindings._bounded(welcome, 4 * 1024 * 1024);
    _withTwo(expectedGroupId.codeUnits, welcome,
        (group, value) => _bindings._groupJoin(_liveHandle, group, value));
  }

  ({List<int> commit, List<int> welcome}) addMember(
    String groupId,
    List<int> keyPackage,
    String expectedAccountId,
    String expectedDeviceId,
  ) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(keyPackage, 48 * 1024);
    _bindings._bounded(expectedAccountId.codeUnits, 128);
    _bindings._bounded(expectedDeviceId.codeUnits, 128);
    return _bindings._withByteLists([
      groupId.codeUnits,
      keyPackage,
      expectedAccountId.codeUnits,
      expectedDeviceId.codeUnits,
    ], (slices) {
      final result = _bindings._twoOutputs((commit, welcome) =>
          _bindings._groupAdd(_liveHandle, slices[0], slices[1], slices[2],
              slices[3], commit, welcome));
      return (commit: result.first, welcome: result.second);
    });
  }

  /// Stages one unmerged commit adding [adds] and removing [removes]
  /// (ABI 6). [welcome] is empty when nothing is added; [epoch] is the epoch
  /// the commit was built on.
  ({List<int> commit, List<int> welcome, int epoch}) stageCommit(
    String groupId, {
    List<({List<int> keyPackage, String accountId, String deviceId})> adds =
        const [],
    List<({String accountId, String deviceId})> removes = const [],
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    final changes = encodeMembershipChanges(adds: adds, removes: removes);
    return _bindings._withByteLists([groupId.codeUnits, changes], (slices) {
      final commit = calloc<_PmOwnedBuffer>();
      final welcome = calloc<_PmOwnedBuffer>();
      final epoch = calloc<Uint64>();
      try {
        _bindings._check(_bindings._groupStageCommit(
            _liveHandle, slices[0], slices[1], commit, welcome, epoch));
        final commitBytes = _bindings._take(commit.ref);
        commit.ref
          ..data = nullptr
          ..len = 0;
        final List<int> welcomeBytes;
        if (welcome.ref.data == nullptr) {
          welcomeBytes = const <int>[];
        } else {
          welcomeBytes = _bindings._take(welcome.ref);
          welcome.ref
            ..data = nullptr
            ..len = 0;
        }
        if (adds.isEmpty != welcomeBytes.isEmpty) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        return (commit: commitBytes, welcome: welcomeBytes, epoch: epoch.value);
      } finally {
        if (commit.ref.data != nullptr) _bindings._bufferFree(commit.ref);
        if (welcome.ref.data != nullptr) _bindings._bufferFree(welcome.ref);
        calloc.free(commit);
        calloc.free(welcome);
        calloc.free(epoch);
      }
    });
  }

  void mergePendingCommit(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) =>
            _bindings._check(_bindings._groupMergePending(_liveHandle, group)));
  }

  void clearPendingCommit(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) =>
            _bindings._check(_bindings._groupClearPending(_liveHandle, group)));
  }

  ({int epoch, bool pending}) groupEpoch(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(Uint8List.fromList(groupId.codeUnits), (group) {
      final epoch = calloc<Uint64>();
      final pending = calloc<Uint8>();
      try {
        _bindings
            ._check(_bindings._groupEpoch(_liveHandle, group, epoch, pending));
        return (epoch: epoch.value, pending: pending.value != 0);
      } finally {
        calloc.free(epoch);
        calloc.free(pending);
      }
    });
  }

  void processCommit(String groupId, List<int> commit) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(commit, 4 * 1024 * 1024);
    _withTwo(groupId.codeUnits, commit,
        (group, value) => _bindings._groupCommit(_liveHandle, group, value));
  }

  List<int> selfUpdate(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) => _bindings
            ._output((out) => _bindings._groupUpdate(_liveHandle, group, out)));
  }

  ({List<int> transcriptHash, String digits}) conversationSafetyNumber(
      String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(Uint8List.fromList(groupId.codeUnits), (group) {
      final values = _bindings._twoOutputs((hash, digits) =>
          _bindings._groupSafety(_liveHandle, group, hash, digits));
      return (
        transcriptHash: values.first,
        digits: utf8.decode(values.second, allowMalformed: false),
      );
    });
  }

  List<int> removeMember(String groupId, String accountId, String deviceId) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(accountId.codeUnits, 128);
    _bindings._bounded(deviceId.codeUnits, 128);
    return _bindings._withByteLists(
        [groupId.codeUnits, accountId.codeUnits, deviceId.codeUnits],
        (slices) => _bindings._output((out) => _bindings._groupRemove(
            _liveHandle, slices[0], slices[1], slices[2], out)));
  }

  List<int> encrypt(String groupId, List<int> plaintext) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(plaintext, 1024 * 1024);
    return _withTwoOutput(
        groupId.codeUnits, plaintext, _bindings._groupEncrypt);
  }

  /// Decrypts [ciphertext] and checks that its MLS sender is
  /// [senderAccountId]/[senderDeviceId]. Throws
  /// [NativeCryptoError.senderMismatch] when it is not.
  List<int> decrypt(
    String groupId,
    List<int> ciphertext, {
    required String senderAccountId,
    required String senderDeviceId,
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(ciphertext, 1024 * 1024);
    _bindings._bounded(senderAccountId.codeUnits, 128);
    _bindings._bounded(senderDeviceId.codeUnits, 128);
    return _bindings._withByteLists(
        [
          groupId.codeUnits,
          ciphertext,
          senderAccountId.codeUnits,
          senderDeviceId.codeUnits,
        ],
        (slices) => _bindings._output((out) => _bindings._groupDecrypt(
            _liveHandle, slices[0], slices[1], slices[2], slices[3], out)));
  }

  void _withOne(
      List<int> value, int Function(_PmByteSlice) operation, int max) {
    _bindings._bounded(value, max);
    _bindings._withSlice(Uint8List.fromList(value),
        (slice) => _bindings._check(operation(slice)));
  }

  void _withTwo(List<int> first, List<int> second,
      int Function(_PmByteSlice, _PmByteSlice) operation) {
    _bindings._withByteLists([first, second],
        (slices) => _bindings._check(operation(slices[0], slices[1])));
  }

  List<int> _withTwoOutput(List<int> first, List<int> second,
          _HandleTwoSlicesOutputDart operation) =>
      _bindings._withByteLists(
          [first, second],
          (slices) => _bindings._output(
              (out) => operation(_liveHandle, slices[0], slices[1], out)));

  void close() {
    if (_handle == nullptr) return;
    _bindings._deviceFinalizer.detach(this);
    _bindings._deviceDestroy(_handle);
    _handle = nullptr;
  }
}

/// Encodes the change list of `pm_crypto_group_stage_commit` (ABI 6).
List<int> encodeMembershipChanges({
  required List<({List<int> keyPackage, String accountId, String deviceId})>
      adds,
  required List<({String accountId, String deviceId})> removes,
}) {
  if (adds.isEmpty && removes.isEmpty) {
    throw ArgumentError('a commit needs at least one change');
  }
  if (adds.length > 256 || removes.length > 256) {
    throw ArgumentError('too many membership changes');
  }
  final out = BytesBuilder(copy: false)..addByte(1);
  void u16(int value) => out.add(<int>[(value >> 8) & 0xff, value & 0xff]);
  void id(String value) {
    final bytes = utf8.encode(value);
    if (bytes.isEmpty || bytes.length > 128) {
      throw ArgumentError('invalid identity in membership change');
    }
    u16(bytes.length);
    out.add(bytes);
  }

  u16(adds.length);
  for (final add in adds) {
    final length = add.keyPackage.length;
    if (length == 0 || length > 48 * 1024) {
      throw ArgumentError('invalid key package in membership change');
    }
    out.add(<int>[
      (length >> 24) & 0xff,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
    out.add(add.keyPackage);
    id(add.accountId);
    id(add.deviceId);
  }
  u16(removes.length);
  for (final remove in removes) {
    id(remove.accountId);
    id(remove.deviceId);
  }
  return out.takeBytes();
}
