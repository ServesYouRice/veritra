import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/models.dart';

part 'k2_native_controls.dart';
part 'k2_native_streams.dart';

/// Largest MLS application plaintext the app encrypts, so its ciphertext
/// always fits the server's message routes (docs/crypto.md, "Message size").
///
/// The routes read at most 1 MiB of JSON (`readLimitedJSON`) with the
/// ciphertext base64-encoded. Reserving 64 KiB for the other JSON fields
/// leaves (1 MiB - 64 KiB) * 3 / 4 = 737,280 ciphertext bytes; MLS framing
/// (312 bytes measured) gets a 4 KiB margin. The FFI ceiling (1 MiB) is
/// larger and only bounds the native call.
const int maxSendablePlaintextBytes = (1024 * 1024 - 64 * 1024) * 3 ~/ 4 - 4096;

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
typedef _RestoreBeginNative = Int32 Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, Uint64, _PmByteSlice, Pointer<Uint64>, Pointer<Uint64>);
typedef _RestoreBeginDart = int Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, int, _PmByteSlice, Pointer<Uint64>, Pointer<Uint64>);
typedef _RestoreAddNative = Int32 Function(Uint64, _PmByteSlice);
typedef _RestoreAddDart = int Function(int, _PmByteSlice);
typedef _RestoreFinishNative = Int32 Function(
    Uint64, Pointer<Pointer<_PmCryptoHandle>>, Pointer<Uint64>);
typedef _RestoreFinishDart = int Function(
    int, Pointer<Pointer<_PmCryptoHandle>>, Pointer<Uint64>);
typedef _RestoreAbortNative = Int32 Function(Uint64);
typedef _RestoreAbortDart = int Function(int);
typedef _GroupDeleteNative = Int32 Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<Uint8>);
typedef _GroupDeleteDart = int Function(
    Pointer<_PmCryptoHandle>, _PmByteSlice, Pointer<Uint8>);
typedef _PruneNative = Int32 Function(
    Pointer<_PmCryptoHandle>, Uint64, Pointer<Uint64>);
typedef _PruneDart = int Function(
    Pointer<_PmCryptoHandle>, int, Pointer<Uint64>);
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

typedef _LocatorNative = Int32 Function(_PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _LocatorDart = int Function(_PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _OutputNative = Int32 Function(Pointer<_PmOwnedBuffer>);
typedef _OutputDart = int Function(Pointer<_PmOwnedBuffer>);
typedef _RecoveryDeriveNative = Int32 Function(_PmByteSlice,
    Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _RecoveryDeriveDart = int Function(_PmByteSlice,
    Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _RecoveryProofNative = Int32 Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _RecoveryProofDart = int Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _ThreeSlicesOutputNative = Int32 Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _ThreeSlicesOutputDart = int Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);

/// The public values derived from a K0 recovery key (ABI 11). None is
/// secret against the device. `rkPub` is integrity-critical and never goes
/// to the server; `rkAuthPub` and `rkId` are what
/// `PUT /api/v1/account/recovery-key` takes.
class RecoveryKeyPublic {
  const RecoveryKeyPublic({
    required this.rkPub,
    required this.rkId,
    required this.rkAuthPub,
  });

  final Uint8List rkPub;
  final Uint8List rkId;
  final Uint8List rkAuthPub;
}

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
        _migrate = library.lookupFunction<_RestoreNative, _RestoreDart>(
            'pm_crypto_device_migrate_v3'),
        _restoreBegin =
            library.lookupFunction<_RestoreBeginNative, _RestoreBeginDart>(
                'pm_crypto_restore_begin'),
        _restoreAdd =
            library.lookupFunction<_RestoreAddNative, _RestoreAddDart>(
                'pm_crypto_restore_add'),
        _restoreFinish =
            library.lookupFunction<_RestoreFinishNative, _RestoreFinishDart>(
                'pm_crypto_restore_finish'),
        _restoreAbort =
            library.lookupFunction<_RestoreAbortNative, _RestoreAbortDart>(
                'pm_crypto_restore_abort'),
        _groupDelete =
            library.lookupFunction<_GroupDeleteNative, _GroupDeleteDart>(
                'pm_crypto_group_delete'),
        _pruneKeyPackages = library.lookupFunction<_PruneNative, _PruneDart>(
            'pm_crypto_device_prune_key_packages'),
        _signingKey =
            library.lookupFunction<_HandleOutputNative, _HandleOutputDart>(
                'pm_crypto_device_signing_public_key'),
        _deviceLinkLocator =
            library.lookupFunction<_LocatorNative, _LocatorDart>(
                'pm_crypto_device_link_locator'),
        _recoveryGenerate = library.lookupFunction<_OutputNative, _OutputDart>(
            'pm_crypto_recovery_key_generate'),
        _recoveryEncode = library.lookupFunction<_LocatorNative, _LocatorDart>(
            'pm_crypto_recovery_key_encode'),
        _recoveryDecode = library.lookupFunction<_LocatorNative, _LocatorDart>(
            'pm_crypto_recovery_key_decode'),
        _recoveryDerive =
            library.lookupFunction<_RecoveryDeriveNative, _RecoveryDeriveDart>(
                'pm_crypto_recovery_key_derive'),
        _recoveryProof =
            library.lookupFunction<_RecoveryProofNative, _RecoveryProofDart>(
                'pm_crypto_recovery_proof_sign'),
        _reportKeyGenerate = library.lookupFunction<_OutputNative, _OutputDart>(
            'pm_crypto_report_key_generate'),
        _reportKeyPublic = library.lookupFunction<_LocatorNative, _LocatorDart>(
            'pm_crypto_report_key_public'),
        _reportSeal = library.lookupFunction<_ThreeSlicesOutputNative,
            _ThreeSlicesOutputDart>('pm_crypto_report_seal'),
        _reportOpen = library.lookupFunction<_ThreeSlicesOutputNative,
            _ThreeSlicesOutputDart>('pm_crypto_report_open'),
        _frankCommit =
            library.lookupFunction<_RecoveryProofNative, _RecoveryProofDart>(
                'pm_crypto_frank_commit'),
        _deviceLinkTranscript = library.lookupFunction<
            _DeviceLinkTranscriptNative,
            _DeviceLinkTranscriptDart>('pm_crypto_device_link_transcript_hash'),
        _createKeyPackage =
            library.lookupFunction<_HandleOutputNative, _HandleOutputDart>(
                'pm_crypto_device_create_key_package'),
        _seal = library.lookupFunction<_SealNative, _SealDart>(
            'pm_crypto_device_seal_changes'),
        _groupCreate =
            library.lookupFunction<_HandleSliceNative, _HandleSliceDart>(
                'pm_crypto_group_create'),
        _groupJoin = library.lookupFunction<_HandleTwoSlicesNative,
            _HandleTwoSlicesDart>('pm_crypto_group_join'),
        _groupAdd = library.lookupFunction<_AddMemberNative, _AddMemberDart>(
            'pm_crypto_group_add_member'),
        _groupCommit = library.lookupFunction<_HandleTwoSlicesNative,
            _HandleTwoSlicesDart>('pm_crypto_group_process_commit'),
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
    if (_abiVersion() != 12) {
      throw const NativeCryptoException(NativeCryptoError.abiMismatch);
    }
    _k2Controls = {
      for (final entry in const {
        1: 'receive_begin',
        2: 'source_accept',
        3: 'inspect',
        4: 'enrollment_proof',
        5: 'source_confirm',
        6: 'source_approval_request',
        7: 'apply_approval',
        8: 'source_posted',
        9: 'importing',
        10: 'forget',
        11: 'expire',
      }.entries)
        entry.key: library.lookupFunction<_HandleSliceOutputNative,
            _HandleSliceOutputDart>('pm_crypto_k2_${entry.value}'),
    };
    _k2Streams = _K2StreamBindings(library);
    _deviceFinalizer = NativeFinalizer(library
        .lookup<NativeFunction<_DeviceDestroyNative>>(
            'pm_crypto_device_destroy')
        .cast());
  }

  static const _ok = 0;
  final _AbiVersionDart _abiVersion;
  late final Map<int, _HandleSliceOutputDart> _k2Controls;
  late final _K2StreamBindings _k2Streams;
  final _DeviceCreateDart _deviceCreate;
  final _DeviceDestroyDart _deviceDestroy;
  final _BufferFreeDart _bufferFree;
  final _EnrollmentDart _createEnrollment;
  final _RestoreDart _migrate;
  final _RestoreBeginDart _restoreBegin;
  final _RestoreAddDart _restoreAdd;
  final _RestoreFinishDart _restoreFinish;
  final _RestoreAbortDart _restoreAbort;
  final _GroupDeleteDart _groupDelete;
  final _PruneDart _pruneKeyPackages;
  final _HandleOutputDart _signingKey;
  final _DeviceLinkTranscriptDart _deviceLinkTranscript;
  final _LocatorDart _deviceLinkLocator;
  final _OutputDart _recoveryGenerate;
  final _LocatorDart _recoveryEncode;
  final _LocatorDart _recoveryDecode;
  final _RecoveryDeriveDart _recoveryDerive;
  final _RecoveryProofDart _recoveryProof;
  final _OutputDart _reportKeyGenerate;
  final _LocatorDart _reportKeyPublic;
  final _ThreeSlicesOutputDart _reportSeal;
  final _ThreeSlicesOutputDart _reportOpen;
  final _RecoveryProofDart _frankCommit;

  /// K0 recovery key entropy length (ABI 11).
  static const recoveryKeyEntropyBytes = 30;

  /// Length of the canonical recovery key display (no separators).
  static const recoveryKeyDisplayChars = 52;

  /// Fresh recovery key entropy (30 bytes) from the OS RNG (ABI 11). The
  /// caller owns it: wipe it (`fillRange(0, length, 0)`) once it has been
  /// shown, confirmed and used. Never store or log it.
  Uint8List generateRecoveryKey() =>
      _recoveryEntropy(_output((out) => _recoveryGenerate(out),
          maximum: recoveryKeyEntropyBytes));

  /// The canonical 52-character display (upper case, no separators) of
  /// [entropy]. The UI groups it into 13 groups of 4. A Dart string cannot
  /// be wiped, so keep it only while it is shown.
  String encodeRecoveryKey(Uint8List entropy) {
    _bounded(entropy, recoveryKeyEntropyBytes, exact: true);
    final bytes = _withSlice(
        entropy,
        (slice) => _output((out) => _recoveryEncode(slice, out),
            maximum: recoveryKeyDisplayChars));
    try {
      if (bytes.length != recoveryKeyDisplayChars) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      return ascii.decode(bytes);
    } on FormatException {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    } finally {
      _wipe(bytes);
    }
  }

  /// Decodes typed recovery key text to its 30-byte entropy, before any
  /// network call. Case-insensitive; O reads as 0 and I/L as 1; `-` and
  /// spaces are ignored. A typo, a wrong length or any other symbol throws
  /// [NativeCryptoError.invalidArgument]. The caller wipes the result.
  Uint8List decodeRecoveryKey(String text) {
    final bytes = utf8.encode(text);
    try {
      if (bytes.isEmpty || bytes.length > 256) {
        throw const NativeCryptoException(NativeCryptoError.invalidArgument);
      }
      return _recoveryEntropy(_withSlice(
          bytes,
          (slice) => _output((out) => _recoveryDecode(slice, out),
              maximum: recoveryKeyEntropyBytes)));
    } finally {
      _wipe(bytes);
    }
  }

  /// Derives `rk_pub`, `rk_id` and `rk_auth_pub` from [entropy] (ABI 11).
  RecoveryKeyPublic deriveRecoveryKey(Uint8List entropy) {
    _bounded(entropy, recoveryKeyEntropyBytes, exact: true);
    return _withSlice(entropy, (slice) {
      final rkPub = calloc<_PmOwnedBuffer>();
      final rkId = calloc<_PmOwnedBuffer>();
      final rkAuthPub = calloc<_PmOwnedBuffer>();
      try {
        _check(_recoveryDerive(slice, rkPub, rkId, rkAuthPub));
        final pub = Uint8List.fromList(_take(rkPub.ref, maximum: 32));
        final id = Uint8List.fromList(_take(rkId.ref, maximum: 16));
        final auth = Uint8List.fromList(_take(rkAuthPub.ref, maximum: 32));
        if (pub.length != 32 || id.length != 16 || auth.length != 32) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        return RecoveryKeyPublic(rkPub: pub, rkId: id, rkAuthPub: auth);
      } finally {
        if (rkPub.ref.data != nullptr) _free(rkPub.ref);
        if (rkId.ref.data != nullptr) _free(rkId.ref);
        if (rkAuthPub.ref.data != nullptr) _free(rkAuthPub.ref);
        calloc.free(rkPub);
        calloc.free(rkId);
        calloc.free(rkAuthPub);
      }
    });
  }

  /// Signs the recovery-enrollment proof for a claim (ABI 11):
  /// `"veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key |
  /// SHA-256(key_package) | lp(origin)`. [origin] must be the canonical
  /// origin the app uses for this server (`https://host[:port]`); the server
  /// rebuilds the message with its configured origin. Returns the 64-byte
  /// Ed25519 signature. The label is fixed in Rust, so the recovery key
  /// signs nothing else.
  Uint8List signRecoveryProof({
    required Uint8List entropy,
    required List<int> challenge,
    required List<int> signingKey,
    required List<int> keyPackage,
    required String origin,
  }) {
    _bounded(entropy, recoveryKeyEntropyBytes, exact: true);
    _bounded(challenge, 4096);
    _bounded(signingKey, 32, exact: true);
    _bounded(keyPackage, 48 * 1024);
    final originBytes = utf8.encode(origin);
    _bounded(originBytes, 2048);
    final signature = _withSlice(
        entropy,
        (entropySlice) => _withByteLists(
            <List<int>>[challenge, signingKey, keyPackage, originBytes],
            (slices) => _output(
                (out) => _recoveryProof(entropySlice, slices[0], slices[1],
                    slices[2], slices[3], out),
                maximum: 64)));
    if (signature.length != 64) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(signature);
  }

  /// C6 report key seed length (ABI 12).
  static const reportKeySeedBytes = 32;

  /// X25519 report public key length (ABI 12).
  static const reportPublicKeyBytes = 32;

  /// Largest report plaintext the native seal accepts (ABI 12).
  static const maxReportPlaintextBytes = 256 * 1024;

  /// Largest report associated data (ABI 12). It is required.
  static const maxReportAadBytes = 1024;

  /// Largest sealed report: `VRP1`, enc, plaintext and tag.
  static const maxSealedReportBytes = 4 + 32 + maxReportPlaintextBytes + 16;

  /// Largest canonical payload a franking commitment covers (ABI 12).
  static const maxFrankPayloadBytes = 64 * 1024;

  /// A fresh report key seed from the OS RNG (ABI 12). The caller owns it:
  /// keep it only in protected storage and wipe every Dart copy once used.
  /// Never log or send it.
  Uint8List generateReportKeySeed() => _secretOutput(
      _output((out) => _reportKeyGenerate(out), maximum: reportKeySeedBytes),
      reportKeySeedBytes);

  /// The 32-byte report public key for [seed] (ABI 12).
  Uint8List reportPublicKey(Uint8List seed) {
    _bounded(seed, reportKeySeedBytes, exact: true);
    final public = _withSlice(
        seed,
        (slice) => _output((out) => _reportKeyPublic(slice, out),
            maximum: reportPublicKeyBytes));
    if (public.length != reportPublicKeyBytes) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(public);
  }

  /// Seals [plaintext] to [recipientPublicKey] (ABI 12): RFC 9180 base
  /// mode, X25519 / HKDF-SHA256 / AES-256-GCM, with the info label fixed in
  /// Rust. [aad] is required and must be rebuilt identically by the
  /// recipient. A bad or low-order key is [NativeCryptoError.invalidArgument].
  Uint8List sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  }) {
    _bounded(recipientPublicKey, reportPublicKeyBytes, exact: true);
    _bounded(aad, maxReportAadBytes);
    _bounded(plaintext, maxReportPlaintextBytes);
    final sealed = _withSlice(
        plaintext,
        (plain) => _withByteLists(
            <List<int>>[recipientPublicKey, aad],
            (slices) => _output(
                (out) => _reportSeal(slices[0], slices[1], plain, out),
                maximum: maxSealedReportBytes)));
    if (sealed.length != plaintext.length + 4 + 32 + 16) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(sealed);
  }

  /// Opens a sealed report with the recipient's [seed] (ABI 12). Altered
  /// bytes, another [aad] or another key throw
  /// [NativeCryptoError.operationFailed]. The caller wipes the result.
  Uint8List openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  }) {
    _bounded(seed, reportKeySeedBytes, exact: true);
    _bounded(aad, maxReportAadBytes);
    _bounded(sealed, maxSealedReportBytes);
    final opened = _withSlice(
        seed,
        (seedSlice) => _withByteLists(
            <List<int>>[aad, sealed],
            (slices) => _output(
                (out) => _reportOpen(seedSlice, slices[0], slices[1], out),
                maximum: maxReportPlaintextBytes)));
    return _secretOutput(opened, sealed.length - 4 - 32 - 16);
  }

  /// The C6 franking commitment over the canonical payload bytes [payload]
  /// (ABI 12, `docs/crypto.md` "Franking v1"). [key] is the 32-byte `kf`.
  Uint8List frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  }) {
    _bounded(key, 32, exact: true);
    final ids = <List<int>>[
      utf8.encode(conversationId),
      utf8.encode(senderDeviceId),
      utf8.encode(actionId),
    ];
    for (final id in ids) {
      _bounded(id, 128);
    }
    _bounded(payload, maxFrankPayloadBytes);
    final commit = _withSlice(
        key,
        (keySlice) => _withSlice(
            payload,
            (payloadSlice) => _withByteLists(
                ids,
                (slices) => _output(
                    (out) => _frankCommit(keySlice, slices[0], slices[1],
                        slices[2], payloadSlice, out),
                    maximum: 32))));
    if (commit.length != 32) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(commit);
  }

  /// Hands a secret owned-buffer copy over without another Dart copy.
  Uint8List _secretOutput(List<int> bytes, int length) {
    if (bytes.length != length) {
      _wipe(bytes);
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    if (bytes is Uint8List) return bytes;
    final copy = Uint8List.fromList(bytes);
    _wipe(bytes);
    return copy;
  }

  Uint8List _recoveryEntropy(List<int> bytes) {
    if (bytes.length != recoveryKeyEntropyBytes) {
      _wipe(bytes);
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    // The owned-buffer copy is already a Uint8List: hand it over as is, so
    // the caller holds the only Dart copy and can wipe it.
    if (bytes is Uint8List) return bytes;
    final copy = Uint8List.fromList(bytes);
    _wipe(bytes);
    return copy;
  }

  static void _wipe(List<int> bytes) => bytes.fillRange(0, bytes.length, 0);

  String deviceLinkLocator(List<int> secret) {
    _bounded(secret, 16, exact: true);
    final bytes = _withSlice(Uint8List.fromList(secret),
        (slice) => _output((out) => _deviceLinkLocator(slice, out)));
    if (bytes.length != 32)
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
  }

  final _HandleOutputDart _createKeyPackage;
  final _SealDart _seal;
  final _HandleSliceDart _groupCreate;
  final _HandleTwoSlicesDart _groupJoin;
  final _AddMemberDart _groupAdd;
  final _HandleTwoSlicesDart _groupCommit;
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

  /// Restores a format-4 state (D70): the [root] and every stored record,
  /// read together. The root's generation must be at least
  /// [minimumGeneration]; the caller requires it to equal its counter. Any
  /// missing, extra, stale or altered record fails the restore.
  ({NativeCryptoDevice device, int generation}) restoreRecords(
      String accountId,
      String deviceId,
      List<int> stateKey,
      int minimumGeneration,
      List<int> root,
      Iterable<List<int>> records) {
    _bounded(accountId.codeUnits, 128);
    _bounded(deviceId.codeUnits, 128);
    _bounded(stateKey, 32, exact: true);
    _bounded(root, _maxSealedRootBytes);
    if (minimumGeneration < 0) {
      throw ArgumentError.value(minimumGeneration, 'minimumGeneration');
    }
    final loader = _withByteLists(
        [accountId.codeUnits, deviceId.codeUnits, stateKey, root], (slices) {
      final token = calloc<Uint64>();
      final generation = calloc<Uint64>();
      try {
        _check(_restoreBegin(slices[0], slices[1], slices[2], minimumGeneration,
            slices[3], token, generation));
        return token.value;
      } finally {
        calloc.free(generation);
        calloc.free(token);
      }
    });
    var open = true;
    try {
      for (final record in records) {
        _bounded(record, _maxSealedRecordBytes);
        _withSlice(Uint8List.fromList(record),
            (slice) => _check(_restoreAdd(loader, slice)));
      }
      final handle = calloc<Pointer<_PmCryptoHandle>>();
      final generation = calloc<Uint64>();
      try {
        open = false;
        _check(_restoreFinish(loader, handle, generation));
        if (handle.value == nullptr) {
          throw const NativeCryptoException(NativeCryptoError.operationFailed);
        }
        return (
          device: NativeCryptoDevice._(this, handle.value),
          generation: generation.value
        );
      } finally {
        calloc.free(generation);
        calloc.free(handle);
      }
    } finally {
      if (open) _restoreAbort(loader);
    }
  }

  /// Opens a format 2/3 blob stored at [counter] for the one-way migration
  /// (D70 section 5). The returned device seals every record at
  /// `counter + 1`; [dropped] counts inactive groups and unowned key pairs
  /// left behind.
  ({NativeCryptoDevice device, int dropped}) migrateLegacyState(
      String accountId,
      String deviceId,
      List<int> stateKey,
      int counter,
      List<int> sealedState) {
    _bounded(accountId.codeUnits, 128);
    _bounded(deviceId.codeUnits, 128);
    _bounded(stateKey, 32, exact: true);
    _bounded(sealedState, 32 * 1024 * 1024);
    if (counter <= 0) throw ArgumentError.value(counter, 'counter');
    return _withByteLists(
        [accountId.codeUnits, deviceId.codeUnits, stateKey, sealedState],
        (slices) {
      final handle = calloc<Pointer<_PmCryptoHandle>>();
      final dropped = calloc<Uint64>();
      try {
        _check(_migrate(slices[0], slices[1], slices[2], counter, slices[3],
            handle, dropped));
        if (handle.value == nullptr) {
          throw const NativeCryptoException(NativeCryptoError.operationFailed);
        }
        return (
          device: NativeCryptoDevice._(this, handle.value),
          dropped: dropped.value
        );
      } finally {
        calloc.free(dropped);
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
        if (keyPackage.ref.data != nullptr) _free(keyPackage.ref);
        if (signingKey.ref.data != nullptr) _free(signingKey.ref);
        if (signature.ref.data != nullptr) _free(signature.ref);
        calloc.free(keyPackage);
        calloc.free(signingKey);
        calloc.free(signature);
      }
    });
  }

  /// Test seams (TASK-047): stand in for the copy out of an owned buffer and
  /// for the native free, so a test can make the copy fail and count frees
  /// without a real double free. Never set outside tests.
  @visibleForTesting
  static List<int> Function(Pointer<Uint8> data, int len) debugCopyOwnedBytes =
      _copyOwnedBytes;
  @visibleForTesting
  static void Function(Pointer<Uint8> data, int len)? debugFreeOwnedBuffer;

  static List<int> _copyOwnedBytes(Pointer<Uint8> data, int len) =>
      Uint8List.fromList(data.asTypedList(len));

  void _free(_PmOwnedBuffer buffer) {
    final override = debugFreeOwnedBuffer;
    if (override != null) {
      override(buffer.data, buffer.len);
    } else {
      _bufferFree(buffer);
    }
  }

  List<int> _take(_PmOwnedBuffer buffer, {int maximum = 32 * 1024 * 1024}) {
    if (buffer.data == nullptr || buffer.len == 0 || buffer.len > maximum) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    // Once validated, _take is the single owner: it frees the buffer and
    // nulls it, so the caller's cleanup cannot free it a second time when
    // the copy throws.
    try {
      return debugCopyOwnedBytes(buffer.data, buffer.len);
    } finally {
      _free(buffer);
      buffer
        ..data = nullptr
        ..len = 0;
    }
  }

  List<int> _output(int Function(Pointer<_PmOwnedBuffer>) operation,
      {int maximum = 32 * 1024 * 1024}) {
    final output = calloc<_PmOwnedBuffer>();
    try {
      _check(operation(output));
      final bytes = _take(output.ref, maximum: maximum);
      output.ref
        ..data = nullptr
        ..len = 0;
      return bytes;
    } finally {
      if (output.ref.data != nullptr) _free(output.ref);
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
      if (first.ref.data != nullptr) _free(first.ref);
      if (second.ref.data != nullptr) _free(second.ref);
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
      -6 => NativeCryptoError.stateFormatUnsupported,
      -7 => NativeCryptoError.senderRemoved,
      -8 => NativeCryptoError.recordLimit,
      -9 => NativeCryptoError.welcomeKeyPackageUnavailable,
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

  /// The message decrypted from a retained past epoch, but its sender has
  /// left the group (ABI 9). The ratchet has already advanced: handle it as
  /// [senderMismatch].
  senderRemoved,

  /// [NativeCryptoBindings.restoreRecords] and
  /// [NativeCryptoBindings.migrateLegacyState] only: the sealed state is in
  /// a format that call does not read (ABI 9). Unauthenticated: it may lead
  /// to re-linking the device or to the migration, never to a weaker check.
  stateFormatUnsupported,

  /// [NativeCryptoDevice.sealChanges] only: a record would be over its cap
  /// (ABI 10, D70). Thrown as [NativeRecordLimitException], which names it.
  recordLimit,

  /// [NativeCryptoDevice.joinGroup] only: the Welcome names no key package
  /// this device holds, or it expired (ABI 10, D74). Nothing was consumed.
  welcomeKeyPackageUnavailable,

  /// [NativeCryptoDevice.encrypt] only: the plaintext is larger than
  /// [maxSendablePlaintextBytes], so its ciphertext could not be sent.
  /// Refused before encrypting; the group state is unchanged.
  plaintextTooLarge,
  invalidOutput,
  unknown
}

extension NativeCryptoErrorRatchet on NativeCryptoError {
  /// Decryption used its ratchet step, so the message can never be decrypted
  /// again, but its content must not be shown: commit and keep a warning.
  bool get ratchetAdvanced =>
      this == NativeCryptoError.senderMismatch ||
      this == NativeCryptoError.senderRemoved;
}

class NativeCryptoException implements Exception {
  const NativeCryptoException(this.kind);
  final NativeCryptoError kind;

  @override
  String toString() => 'NativeCryptoException(${kind.name})';
}

/// A sealed record would be over its cap (D70): [recordKind] is 1 for the
/// device, 2 for a group (then [recordId] is its conversation id), 3 for a
/// key package. Nothing was sealed.
class NativeRecordLimitException extends NativeCryptoException {
  const NativeRecordLimitException(this.recordKind, this.recordId)
      : super(NativeCryptoError.recordLimit);
  final int recordKind;
  final List<int> recordId;

  @override
  String toString() => 'NativeRecordLimitException(kind $recordKind)';
}

/// Largest sealed root and record (D70 caps plus the record overhead).
const int _maxSealedRootBytes = 16 * 1024 * 1024 + 4096;
const int _maxSealedRecordBytes = 32 * 1024 * 1024 + 4096;

/// Largest change set [NativeCryptoDevice.sealChanges] accepts.
const int _maxChangeSetBytes = 128 * 1024 * 1024;

/// One record change of a [NativeChangeSet]; [sealed] null deletes it.
typedef NativeRecordChange = ({
  int kind,
  List<int> id,
  int generation,
  List<int>? sealed,
});

/// The root at a new generation and every record that changed with it.
typedef NativeChangeSet = ({List<int> root, List<NativeRecordChange> changes});

NativeChangeSet _parseChangeSet(List<int> bytes, int generation) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  var offset = 0;
  int need(int n) {
    if (n < 0 || offset + n > data.lengthInBytes) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    final start = offset;
    offset += n;
    return start;
  }

  List<int> take(int n) {
    final start = need(n);
    return Uint8List.sublistView(data, start, start + n);
  }

  int u32() => data.getUint32(need(4), Endian.big);
  final rootLength = u32();
  if (rootLength == 0 || rootLength > _maxSealedRootBytes) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final root = take(rootLength);
  final count = u32();
  final changes = <NativeRecordChange>[];
  for (var index = 0; index < count; index++) {
    final kind = data.getUint8(need(1));
    final id = take(data.getUint16(need(2), Endian.big));
    final changeGeneration = data.getUint64(need(8), Endian.big);
    final present = data.getUint8(need(1));
    List<int>? sealed;
    if (present == 1) {
      final length = u32();
      if (length == 0 || length > _maxSealedRecordBytes) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      sealed = take(length);
    } else if (present != 0) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    if (kind < 1 || kind > 3 || changeGeneration != generation) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    changes.add(
        (kind: kind, id: id, generation: changeGeneration, sealed: sealed));
  }
  if (offset != data.lengthInBytes) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  return (root: root, changes: changes);
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

  _K2Reader _k2Control(_K2Writer request) {
    final bytes = request.bytes();
    try {
      _bindings._bounded(bytes, 64 * 1024);
      final result = _bindings._withSlice(
          bytes,
          (slice) => _bindings._output((out) => _bindings
              ._k2Controls[request.operation]!(_liveHandle, slice, out)));
      return _K2Reader(Uint8List.fromList(result), request.operation);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  EnrollmentCredential createEnrollmentCredential(List<int> challenge) {
    _bindings._bounded(challenge, 4096);
    return _bindings.createEnrollmentCredential(_liveHandle, challenge);
  }

  List<int> signingPublicKey() =>
      _bindings._output((out) => _bindings._signingKey(_liveHandle, out));

  DeviceLinkVerification deriveDeviceLinkVerification({
    required String protocolVersion,
    required String serverOrigin,
    required String linkId,
    required List<int> linkSecret,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required List<int> linkNonce,
    required bool localIsExistingDevice,
  }) {
    _bindings._bounded(protocolVersion.codeUnits, 64);
    _bindings._bounded(serverOrigin.codeUnits, 2048);
    _bindings._bounded(linkId.codeUnits, 128);
    _bindings._bounded(linkSecret, 16, exact: true);
    _bindings._bounded(peerDeviceId.codeUnits, 128);
    _bindings._bounded(peerSigningKey, 32, exact: true);
    _bindings._bounded(linkNonce, 32, exact: true);
    final transcriptHash = _bindings._withByteLists(
      [
        protocolVersion.codeUnits,
        serverOrigin.codeUnits,
        linkId.codeUnits,
        linkSecret,
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
          slices[4],
          slices[5],
          slices[6],
          localIsExistingDevice ? 1 : 0,
          out)),
    );
    if (transcriptHash.length != 100) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    final sasValue = ByteData.sublistView(Uint8List.fromList(transcriptHash))
            .getUint32(96, Endian.big) %
        100000000;
    return DeviceLinkVerification(
      transcriptHash: transcriptHash.sublist(0, 32),
      claimTag: transcriptHash.sublist(32, 64),
      approvalTag: transcriptHash.sublist(64, 96),
      sas: sasValue.toString().padLeft(8, '0'),
    );
  }

  List<int> createKeyPackage() =>
      _bindings._output((out) => _bindings._createKeyPackage(_liveHandle, out));

  /// Seals what changed since the last seal or restore at [generation],
  /// the stored counter plus one (D70). Store the root and every change in
  /// one transaction; after any failure, restore the committed state.
  /// Throws [NativeRecordLimitException] naming a record over its cap.
  NativeChangeSet sealChanges(List<int> stateKey, int generation) {
    _bindings._bounded(stateKey, 32, exact: true);
    if (generation <= 0) throw ArgumentError.value(generation, 'generation');
    final bytes = _bindings._withSlice(Uint8List.fromList(stateKey), (key) {
      final output = calloc<_PmOwnedBuffer>();
      try {
        final code = _bindings._seal(_liveHandle, key, generation, output);
        if (code == -8) {
          final named = _bindings._take(output.ref);
          output.ref
            ..data = nullptr
            ..len = 0;
          throw NativeRecordLimitException(named.first, named.sublist(1));
        }
        _bindings._check(code);
        final bytes = _bindings._take(output.ref, maximum: _maxChangeSetBytes);
        output.ref
          ..data = nullptr
          ..len = 0;
        return bytes;
      } finally {
        if (output.ref.data != nullptr) _bindings._free(output.ref);
        calloc.free(output);
      }
    });
    return _parseChangeSet(bytes, generation);
  }

  /// Drops this device's state for a chat the user deleted. Returns whether
  /// one was stored. Never for a removal: that group is already gone.
  bool deleteGroup(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(Uint8List.fromList(groupId.codeUnits), (group) {
      final deleted = calloc<Uint8>();
      try {
        _bindings._check(_bindings._groupDelete(_liveHandle, group, deleted));
        return deleted.value == 1;
      } finally {
        calloc.free(deleted);
      }
    });
  }

  /// Drops key packages that expired more than 24 hours before [now].
  int pruneKeyPackages(DateTime now) {
    final seconds = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0) throw ArgumentError.value(now, 'now');
    final removed = calloc<Uint64>();
    try {
      _bindings
          ._check(_bindings._pruneKeyPackages(_liveHandle, seconds, removed));
      return removed.value;
    } finally {
      calloc.free(removed);
    }
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
    final changes = encodeMembershipChanges(adds: adds, removes: removes);
    return _stage(groupId, changes, expectWelcome: adds.isNotEmpty);
  }

  /// Stages one unmerged self-update: a commit with an update path that
  /// adds and removes no one and gives this device's leaf a fresh key
  /// (periodic self-update). The native side reads an empty change list
  /// this way. Merge it only after the server accepts it, like [stageCommit].
  ({List<int> commit, List<int> welcome, int epoch}) stageSelfUpdate(
          String groupId) =>
      _stage(groupId, emptyMembershipChanges, expectWelcome: false);

  ({List<int> commit, List<int> welcome, int epoch}) _stage(
      String groupId, List<int> changes,
      {required bool expectWelcome}) {
    _bindings._bounded(groupId.codeUnits, 128);
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
        if (expectWelcome == welcomeBytes.isEmpty) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        return (commit: commitBytes, welcome: welcomeBytes, epoch: epoch.value);
      } finally {
        if (commit.ref.data != nullptr) _bindings._free(commit.ref);
        if (welcome.ref.data != nullptr) _bindings._free(welcome.ref);
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

  /// Throws [NativeCryptoError.plaintextTooLarge] above
  /// [maxSendablePlaintextBytes], before any ratchet step.
  List<int> encrypt(String groupId, List<int> plaintext) {
    _bindings._bounded(groupId.codeUnits, 128);
    if (plaintext.length > maxSendablePlaintextBytes) {
      throw const NativeCryptoException(NativeCryptoError.plaintextTooLarge);
    }
    _bindings._bounded(plaintext, maxSendablePlaintextBytes);
    return _withTwoOutput(
        groupId.codeUnits, plaintext, _bindings._groupEncrypt);
  }

  /// Decrypts [ciphertext] and checks that its MLS sender is
  /// [senderAccountId]/[senderDeviceId]. Throws
  /// [NativeCryptoError.senderMismatch] when it is not, and
  /// [NativeCryptoError.senderRemoved] for a past-epoch message from a
  /// sender who has left the group; the ratchet has advanced in both.
  List<int> decrypt(
    String groupId,
    List<int> ciphertext, {
    required String senderAccountId,
    required String senderDeviceId,
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    // The native ciphertext ceiling: 1 MiB of plaintext plus MLS overhead.
    _bindings._bounded(ciphertext, 1024 * 1024 + 4096);
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
/// The change list that asks `pm_crypto_group_stage_commit` for a
/// self-update: version 1, no adds, no removes.
const List<int> emptyMembershipChanges = <int>[1, 0, 0, 0, 0];

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
