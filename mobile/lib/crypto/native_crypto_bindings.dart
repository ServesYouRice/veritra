import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/models.dart';

part 'c4_roles.dart';
part 'k2_native_controls.dart';
part 'k2_native_streams.dart';
part 'l1_device_list.dart';

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
typedef _C7CommitNative = Int32 Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>);
typedef _C7CommitDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>);
typedef _C7MergeNative = Int32 Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>);
typedef _C7MergeDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>);
typedef _C7DecryptNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _C7DecryptDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _C7MemberKeyNative = Int32 Function(Pointer<_PmCryptoHandle>,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _C7MemberKeyDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _B6MediaKeyNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Uint8,
    Pointer<_PmOwnedBuffer>);
typedef _B6MediaKeyDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, int, Pointer<_PmOwnedBuffer>);
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
typedef _RecoveryDeriveNative = Int32 Function(
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _RecoveryDeriveDart = int Function(
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _HandleByteOutputNative = Int32 Function(
    Pointer<_PmCryptoHandle>, Pointer<Uint8>);
typedef _HandleByteOutputDart = int Function(
    Pointer<_PmCryptoHandle>, Pointer<Uint8>);
typedef _L1SignRecoveryNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>);
typedef _L1SignRecoveryDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>);
typedef _L1ProcessNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<Uint8>,
    Pointer<Uint64>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _L1ProcessDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<Uint8>,
    Pointer<Uint64>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _L1MergeNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    Pointer<Uint8>,
    Pointer<Uint64>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _L1MergeDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    Pointer<Uint8>,
    Pointer<Uint64>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _StageWithRolesNative = Int32 Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _StageWithRolesDart = int Function(
    Pointer<_PmCryptoHandle>,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<Uint64>);
typedef _RecoveryProofNative = Int32 Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _RecoveryProofDart = int Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _BackupSealNative = Int32 Function(_PmByteSlice, _PmByteSlice, Uint64,
    Uint64, Uint32, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _BackupSealDart = int Function(_PmByteSlice, _PmByteSlice, int, int,
    int, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _BackupPeekNative = Int32 Function(_PmByteSlice,
    Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _BackupPeekDart = int Function(_PmByteSlice, Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>);
typedef _BackupOpenNative = Int32 Function(
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _BackupOpenDart = int Function(
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    _PmByteSlice,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>,
    Pointer<_PmOwnedBuffer>);
typedef _ThreeSlicesOutputNative = Int32 Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _ThreeSlicesOutputDart = int Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _TwoSlicesOutputNative = Int32 Function(
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _TwoSlicesOutputDart = int Function(
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _FourSlicesOutputNative = Int32 Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _FourSlicesOutputDart = int Function(_PmByteSlice, _PmByteSlice,
    _PmByteSlice, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _VerifyNative = Int32 Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<Uint8>);
typedef _VerifyDart = int Function(
    _PmByteSlice, _PmByteSlice, _PmByteSlice, _PmByteSlice, Pointer<Uint8>);

/// The public values derived from a K0 recovery key (ABI 11). None is
/// secret against the device. `rkPub` is integrity-critical and never goes
/// to the server; `rkAuthPub` and `rkId` are what
/// `PUT /api/v1/account/recovery-key` takes. `rkListPub` (ABI 14, L1) is the
/// public key of the device-list recovery signer, the key a `recoveryKey`
/// version of the approved-device list names.
class RecoveryKeyPublic {
  const RecoveryKeyPublic({
    required this.rkPub,
    required this.rkId,
    required this.rkAuthPub,
    required this.rkListPub,
  });

  final Uint8List rkPub;
  final Uint8List rkId;
  final Uint8List rkAuthPub;
  final Uint8List rkListPub;
}

/// What a K1 backup container's header says (ABI 19). From [peekBackup] it is
/// unauthenticated; from [openBackup] it is authenticated.
class BackupHeaderInfo {
  const BackupHeaderInfo({
    required this.accountId,
    required this.sourceDeviceId,
    required this.createdAtMs,
    required this.counter,
    required this.rkId,
    required this.plaintextVersion,
    required this.paddedSize,
  });

  final String accountId;
  final String sourceDeviceId;
  final int createdAtMs;
  final int counter;
  final Uint8List rkId;
  final int plaintextVersion;
  final int paddedSize;
}

/// An opened K1 backup: the header and the plaintext. The caller wipes
/// [plaintext].
class OpenedBackup {
  const OpenedBackup({required this.header, required this.plaintext});

  final BackupHeaderInfo header;
  final Uint8List plaintext;
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
        _backupSeal =
            library.lookupFunction<_BackupSealNative, _BackupSealDart>(
                'pm_crypto_backup_seal'),
        _backupPeek =
            library.lookupFunction<_BackupPeekNative, _BackupPeekDart>(
                'pm_crypto_backup_peek'),
        _backupOpen =
            library.lookupFunction<_BackupOpenNative, _BackupOpenDart>(
                'pm_crypto_backup_open'),
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
        _c7Derive = library.lookupFunction<_ThreeSlicesOutputNative,
            _ThreeSlicesOutputDart>('pm_crypto_c7_derive'),
        _c7ChkCommit = library.lookupFunction<_LocatorNative, _LocatorDart>(
            'pm_crypto_c7_chk_commit'),
        _c7Seal = library.lookupFunction<_ThreeSlicesOutputNative,
            _ThreeSlicesOutputDart>('pm_crypto_c7_seal'),
        _c7Open = library.lookupFunction<_ThreeSlicesOutputNative,
            _ThreeSlicesOutputDart>('pm_crypto_c7_open'),
        _c7Verify = library
            .lookupFunction<_VerifyNative, _VerifyDart>('pm_crypto_c7_verify'),
        _c7Sign = library.lookupFunction<_HandleTwoSlicesOutputNative,
            _HandleTwoSlicesOutputDart>('pm_crypto_c7_sign'),
        _l1CheckStep = library.lookupFunction<_FourSlicesOutputNative,
            _FourSlicesOutputDart>('pm_crypto_l1_check_step'),
        _l1CheckChain = library.lookupFunction<_TwoSlicesOutputNative,
            _TwoSlicesOutputDart>('pm_crypto_l1_check_chain'),
        _l1Hold = library.lookupFunction<_HandleSliceNative, _HandleSliceDart>(
            'pm_crypto_l1_recovery_hold'),
        _l1HoldPublic =
            library.lookupFunction<_HandleOutputNative, _HandleOutputDart>(
                'pm_crypto_l1_recovery_hold_public'),
        _l1HoldDrop = library.lookupFunction<_HandleByteOutputNative,
            _HandleByteOutputDart>('pm_crypto_l1_recovery_hold_drop'),
        _l1SignRecovery =
            library.lookupFunction<_L1SignRecoveryNative, _L1SignRecoveryDart>(
                'pm_crypto_l1_sign_recovery'),
        _groupMembers = library.lookupFunction<_HandleSliceOutputNative,
            _HandleSliceOutputDart>('pm_crypto_group_members'),
        _groupL1Process =
            library.lookupFunction<_L1ProcessNative, _L1ProcessDart>(
                'pm_crypto_group_l1_process_commit'),
        _groupL1Merge = library.lookupFunction<_L1MergeNative, _L1MergeDart>(
            'pm_crypto_group_l1_merge_pending_commit'),
        _groupCreateWithRoles = library.lookupFunction<_HandleTwoSlicesNative,
            _HandleTwoSlicesDart>('pm_crypto_group_create_with_roles'),
        _groupStageWithRoles =
            library.lookupFunction<_StageWithRolesNative, _StageWithRolesDart>(
                'pm_crypto_group_stage_commit_with_roles'),
        _groupStageIncoming = library.lookupFunction<
                _HandleTwoSlicesOutputNative, _HandleTwoSlicesOutputDart>(
            'pm_crypto_group_stage_incoming_commit'),
        _groupMergeIncoming =
            library.lookupFunction<_L1ProcessNative, _L1ProcessDart>(
                'pm_crypto_group_merge_incoming_commit'),
        _groupDiscardIncoming =
            library.lookupFunction<_GroupDeleteNative, _GroupDeleteDart>(
                'pm_crypto_group_discard_incoming_commit'),
        _groupRoleState = library.lookupFunction<_HandleSliceOutputNative,
            _HandleSliceOutputDart>('pm_crypto_group_role_state'),
        _memberSignatureKey =
            library.lookupFunction<_RemoveMemberNative, _RemoveMemberDart>(
                'pm_crypto_group_member_signature_key'),
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
        _c7ProcessCommit =
            library.lookupFunction<_C7CommitNative, _C7CommitDart>(
                'pm_crypto_group_c7_process_commit'),
        _c7MergePending = library.lookupFunction<_C7MergeNative, _C7MergeDart>(
            'pm_crypto_group_c7_merge_pending_commit'),
        _c7GroupDecrypt =
            library.lookupFunction<_C7DecryptNative, _C7DecryptDart>(
                'pm_crypto_group_c7_decrypt'),
        _c7MemberKey =
            library.lookupFunction<_C7MemberKeyNative, _C7MemberKeyDart>(
                'pm_crypto_group_member_signature_key'),
        _b6MediaKey =
            library.lookupFunction<_B6MediaKeyNative, _B6MediaKeyDart>(
                'pm_crypto_group_b6_media_key'),
        _attachmentEncrypt = library.lookupFunction<_AttachmentChunkNative,
            _AttachmentChunkDart>('pm_crypto_attachment_encrypt_chunk'),
        _attachmentDecrypt = library.lookupFunction<_AttachmentChunkNative,
            _AttachmentChunkDart>('pm_crypto_attachment_decrypt_chunk') {
    if (_abiVersion() != 22) {
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
        12: 'reveal_sas',
        13: 'source_commitment',
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
  final _LocatorDart _deviceLinkLocator;
  final _OutputDart _recoveryGenerate;
  final _LocatorDart _recoveryEncode;
  final _LocatorDart _recoveryDecode;
  final _RecoveryDeriveDart _recoveryDerive;
  final _RecoveryProofDart _recoveryProof;
  final _BackupSealDart _backupSeal;
  final _BackupPeekDart _backupPeek;
  final _BackupOpenDart _backupOpen;
  final _OutputDart _reportKeyGenerate;
  final _LocatorDart _reportKeyPublic;
  final _ThreeSlicesOutputDart _reportSeal;
  final _ThreeSlicesOutputDart _reportOpen;
  final _RecoveryProofDart _frankCommit;
  final _ThreeSlicesOutputDart _c7Derive;
  final _LocatorDart _c7ChkCommit;
  final _ThreeSlicesOutputDart _c7Seal;
  final _ThreeSlicesOutputDart _c7Open;
  final _VerifyDart _c7Verify;
  final _HandleTwoSlicesOutputDart _c7Sign;
  final _FourSlicesOutputDart _l1CheckStep;
  final _TwoSlicesOutputDart _l1CheckChain;
  final _HandleSliceDart _l1Hold;
  final _HandleOutputDart _l1HoldPublic;
  final _HandleByteOutputDart _l1HoldDrop;
  final _L1SignRecoveryDart _l1SignRecovery;
  final _HandleSliceOutputDart _groupMembers;
  final _L1ProcessDart _groupL1Process;
  final _L1MergeDart _groupL1Merge;
  final _HandleTwoSlicesDart _groupCreateWithRoles;
  final _StageWithRolesDart _groupStageWithRoles;
  final _HandleTwoSlicesOutputDart _groupStageIncoming;
  final _L1ProcessDart _groupMergeIncoming;
  final _GroupDeleteDart _groupDiscardIncoming;
  final _HandleSliceOutputDart _groupRoleState;
  final _RemoveMemberDart _memberSignatureKey;

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

  /// Derives `rk_pub`, `rk_id`, `rk_auth_pub` (ABI 11) and `rk_list_pub`
  /// (ABI 14) from [entropy].
  RecoveryKeyPublic deriveRecoveryKey(Uint8List entropy) {
    _bounded(entropy, recoveryKeyEntropyBytes, exact: true);
    return _withSlice(entropy, (slice) {
      final rkPub = calloc<_PmOwnedBuffer>();
      final rkId = calloc<_PmOwnedBuffer>();
      final rkAuthPub = calloc<_PmOwnedBuffer>();
      final rkListPub = calloc<_PmOwnedBuffer>();
      try {
        _check(_recoveryDerive(slice, rkPub, rkId, rkAuthPub, rkListPub));
        final pub = Uint8List.fromList(_take(rkPub.ref, maximum: 32));
        final id = Uint8List.fromList(_take(rkId.ref, maximum: 16));
        final auth = Uint8List.fromList(_take(rkAuthPub.ref, maximum: 32));
        final list = Uint8List.fromList(_take(rkListPub.ref, maximum: 32));
        if (pub.length != 32 ||
            id.length != 16 ||
            auth.length != 32 ||
            list.length != 32) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        return RecoveryKeyPublic(
            rkPub: pub, rkId: id, rkAuthPub: auth, rkListPub: list);
      } finally {
        if (rkPub.ref.data != nullptr) _free(rkPub.ref);
        if (rkId.ref.data != nullptr) _free(rkId.ref);
        if (rkAuthPub.ref.data != nullptr) _free(rkAuthPub.ref);
        if (rkListPub.ref.data != nullptr) _free(rkListPub.ref);
        calloc.free(rkPub);
        calloc.free(rkId);
        calloc.free(rkAuthPub);
        calloc.free(rkListPub);
      }
    });
  }

  /// The most a K1 backup plaintext may hold (`MAX_PADDED_HISTORY` less the
  /// 8-byte length frame).
  static const backupMaxPlaintextBytes = 64 * 1024 * 1024 - 8;

  /// The most of a backup container the header peek needs.
  static const backupPeekBytes = 416;

  /// Seals [plaintext] into a K1 backup container for [rkPub] (ABI 19). The
  /// container binds [accountId], [sourceDeviceId], [createdAtMs], [counter]
  /// and the key id derived from [rkPub]. Padding is applied in Rust. The
  /// file key is fresh, sealed to [rkPub] and never returned. [plaintext]
  /// must not be empty.
  Uint8List sealBackup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required int plaintextVersion,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) {
    final account = utf8.encode(accountId);
    final device = utf8.encode(sourceDeviceId);
    _bounded(account, 128);
    _bounded(device, 128);
    _bounded(rkPub, 32, exact: true);
    _bounded(plaintext, backupMaxPlaintextBytes);
    if (createdAtMs <= 0 ||
        counter <= 0 ||
        plaintextVersion <= 0 ||
        plaintextVersion > 255) {
      throw ArgumentError('Invalid backup header value');
    }
    // The plaintext goes through _withSlice, which wipes its native copy; a
    // Dart-side copy of the whole snapshot is never made.
    return Uint8List.fromList(_withSlice(
        plaintext,
        (plainSlice) => _withByteLists(
            <List<int>>[account, device, rkPub],
            (slices) => _output(
                (out) => _backupSeal(slices[0], slices[1], createdAtMs, counter,
                    plaintextVersion, slices[2], plainSlice, out),
                maximum: backupMaxPlaintextBytes + 64 * 1024 * 2 + 4096))));
  }

  /// Reads the header of a backup from its first [backupPeekBytes] bytes,
  /// before the body is downloaded. Nothing is authenticated: use it to
  /// refuse a wrong account, device or key early. [openBackup] is the check.
  BackupHeaderInfo peekBackup(Uint8List prefix) {
    _bounded(prefix, backupPeekBytes);
    return _withSlice(prefix, (slice) {
      final account = calloc<_PmOwnedBuffer>();
      final device = calloc<_PmOwnedBuffer>();
      final meta = calloc<_PmOwnedBuffer>();
      try {
        _check(_backupPeek(slice, account, device, meta));
        return _backupHeader(_take(account.ref, maximum: 128),
            _take(device.ref, maximum: 128), _take(meta.ref, maximum: 41));
      } finally {
        if (account.ref.data != nullptr) _free(account.ref);
        if (device.ref.data != nullptr) _free(device.ref);
        if (meta.ref.data != nullptr) _free(meta.ref);
        calloc.free(account);
        calloc.free(device);
        calloc.free(meta);
      }
    });
  }

  /// Opens a backup with the typed recovery-key [entropy] (ABI 19). Throws
  /// if the container is for another account or key, if [sourceDeviceId] is
  /// given and differs, or if any byte was changed. Pass no
  /// [sourceDeviceId] only for a restore from a file. The caller wipes
  /// [OpenedBackup.plaintext] and [entropy].
  OpenedBackup openBackup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) {
    final account = utf8.encode(accountId);
    final device = sourceDeviceId == null ? null : utf8.encode(sourceDeviceId);
    _bounded(ciphertext, backupMaxPlaintextBytes + 64 * 1024 * 2 + 4096);
    _bounded(entropy, recoveryKeyEntropyBytes, exact: true);
    _bounded(account, 128);
    if (device != null) _bounded(device, 128);
    return _withSlice(ciphertext, (cipherSlice) {
      return _withSlice(entropy, (entropySlice) {
        return _withByteLists(<List<int>>[account], (accountSlices) {
          return _withOptionalSlice(device, (deviceSlice) {
            final payload = calloc<_PmOwnedBuffer>();
            final sourceDevice = calloc<_PmOwnedBuffer>();
            final meta = calloc<_PmOwnedBuffer>();
            try {
              // An empty device slice is how Rust reads "do not pin".
              _check(_backupOpen(cipherSlice, entropySlice, accountSlices[0],
                  deviceSlice, payload, sourceDevice, meta));
              // Header first, plaintext last and returned as taken, so no
              // unwiped second copy of the history exists and a header
              // failure cannot leave one behind.
              final header = _backupHeader(
                  account,
                  _take(sourceDevice.ref, maximum: 128),
                  _take(meta.ref, maximum: 41));
              final taken =
                  _take(payload.ref, maximum: backupMaxPlaintextBytes);
              return OpenedBackup(
                header: header,
                plaintext:
                    taken is Uint8List ? taken : Uint8List.fromList(taken),
              );
            } finally {
              if (payload.ref.data != nullptr) _free(payload.ref);
              if (sourceDevice.ref.data != nullptr) _free(sourceDevice.ref);
              if (meta.ref.data != nullptr) _free(meta.ref);
              calloc.free(payload);
              calloc.free(sourceDevice);
              calloc.free(meta);
            }
          });
        });
      });
    });
  }

  /// Like [_withSlice], but null reads as the empty slice (null pointer,
  /// length 0) for the one argument Rust treats as optional.
  T _withOptionalSlice<T>(
      List<int>? bytes, T Function(_PmByteSlice) operation) {
    if (bytes == null) {
      final slice = calloc<_PmByteSlice>();
      try {
        slice.ref
          ..data = nullptr
          ..len = 0;
        return operation(slice.ref);
      } finally {
        calloc.free(slice);
      }
    }
    return _withSlice(Uint8List.fromList(bytes), operation);
  }

  BackupHeaderInfo _backupHeader(
      List<int> account, List<int> device, List<int> meta) {
    if (meta.length != 41) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    final data = ByteData.sublistView(Uint8List.fromList(meta));
    final createdAtMs = data.getUint64(0);
    final counter = data.getUint64(8);
    // Values at or above 2^63 read back negative; no honest header has one.
    if (createdAtMs < 0 || counter < 0) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    try {
      return BackupHeaderInfo(
        accountId: utf8.decode(account),
        sourceDeviceId: utf8.decode(device),
        createdAtMs: createdAtMs,
        counter: counter,
        rkId: Uint8List.fromList(meta.sublist(16, 32)),
        plaintextVersion: data.getUint8(32),
        paddedSize: data.getUint64(33),
      );
    } on FormatException {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
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

  /// C7 channel history keys (ABI 13, `docs/designs/C7-channel-history.md`
  /// revision 7). Every key is 32 bytes.
  static const c7KeyBytes = 32;

  /// Largest C7 associated data and derive info (ABI 13).
  static const c7MaxAadBytes = 1024;
  static const c7MaxInfoBytes = 1024;

  /// Largest plaintext a C7 body seals: the 64 KiB VAP1 cap and the 64-byte
  /// signature in front of it.
  static const c7MaxPlaintextBytes = 64 * 1024 + 64;

  /// What sealing adds: key commitment (32), nonce (12) and tag (16).
  static const c7SealOverhead = 32 + 12 + 16;

  /// `c7_derive` (ABI 13): HKDF-SHA256, salt [label], 32 bytes out. [label]
  /// is `veritra-c7-post-v1`, `veritra-c7-rekey-chk-v1` or
  /// `veritra-c7-slot-v1`; any other is [NativeCryptoError.invalidArgument].
  /// [info] is `lp(...)` fields with u16 big-endian lengths. The caller
  /// wipes the result.
  Uint8List c7Derive({
    required Uint8List key,
    required String label,
    required List<int> info,
  }) {
    _bounded(key, c7KeyBytes, exact: true);
    _bounded(info, c7MaxInfoBytes);
    final derived = _withSlice(
        key,
        (keySlice) => _withByteLists(
            <List<int>>[utf8.encode(label), info],
            (slices) => _output(
                (out) => _c7Derive(keySlice, slices[0], slices[1], out),
                maximum: c7KeyBytes)));
    return _secretOutput(derived, c7KeyBytes);
  }

  /// `sha256("veritra-c7-chk-v1" | key)` (ABI 13): a record's `chk_commit`.
  Uint8List c7ChkCommit(Uint8List key) {
    _bounded(key, c7KeyBytes, exact: true);
    final commit = _withSlice(key,
        (slice) => _output((out) => _c7ChkCommit(slice, out), maximum: 32));
    if (commit.length != 32) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(commit);
  }

  /// Seals [plaintext] under [key] (ABI 13): `kc | nonce | ciphertext |
  /// tag`, with a random nonce chosen in Rust. A key seals one message only
  /// (post and slot keys bind `action_id`). [aad] is required.
  Uint8List c7Seal({
    required Uint8List key,
    required List<int> aad,
    required Uint8List plaintext,
  }) {
    _bounded(key, c7KeyBytes, exact: true);
    _bounded(aad, c7MaxAadBytes);
    _bounded(plaintext, c7MaxPlaintextBytes);
    final sealed = _withSlice(
        key,
        (keySlice) => _withSlice(
            plaintext,
            (plain) => _withByteLists(
                <List<int>>[aad],
                (slices) => _output(
                    (out) => _c7Seal(keySlice, slices[0], plain, out),
                    maximum: c7MaxPlaintextBytes + c7SealOverhead))));
    if (sealed.length != plaintext.length + c7SealOverhead) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(sealed);
  }

  /// Opens a value sealed by [c7Seal] (ABI 13). Returns `null` when [key] is
  /// not the key it was sealed under (its commitment differs): try the next
  /// candidate. Altered bytes or another [aad] under the right key throw
  /// [NativeCryptoError.operationFailed]. The caller wipes the result.
  Uint8List? c7Open({
    required Uint8List key,
    required List<int> aad,
    required List<int> sealed,
  }) {
    _bounded(key, c7KeyBytes, exact: true);
    _bounded(aad, c7MaxAadBytes);
    _bounded(sealed, c7MaxPlaintextBytes + c7SealOverhead);
    if (sealed.length < c7SealOverhead) {
      throw ArgumentError('Native crypto input has an invalid size');
    }
    try {
      final opened = _withSlice(
          key,
          (keySlice) => _withByteLists(
              <List<int>>[aad, sealed],
              (slices) => _output(
                  (out) => _c7Open(keySlice, slices[0], slices[1], out),
                  maximum: c7MaxPlaintextBytes)));
      return _secretOutput(opened, sealed.length - c7SealOverhead);
    } on NativeCryptoException catch (error) {
      if (error.kind == NativeCryptoError.c7KeyMismatch) return null;
      rethrow;
    }
  }

  /// Strict Ed25519 verification of `domain | message` (ABI 13). [domain] is
  /// `veritra-c7-post-sig-v1`, `veritra-c7-history-v1` or
  /// `veritra-invite-binding-v2`; any other is
  /// [NativeCryptoError.invalidArgument]. `false` for an invalid signature,
  /// a malformed key included.
  bool c7Verify({
    required String domain,
    required List<int> publicKey,
    required List<int> message,
    required List<int> signature,
  }) {
    _bounded(publicKey, 32, exact: true);
    _bounded(message, 4096);
    _bounded(signature, 64, exact: true);
    final ok = calloc<Uint8>();
    try {
      final status = _withSlice(
          Uint8List.fromList(utf8.encode(domain)),
          (d) => _withByteLists(<List<int>>[publicKey, message, signature],
              (s) => _c7Verify(d, s[0], s[1], s[2], ok)));
      _check(status);
      return ok.value == 1;
    } finally {
      calloc.free(ok);
    }
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
  final _C7CommitDart _c7ProcessCommit;
  final _C7MergeDart _c7MergePending;
  final _C7DecryptDart _c7GroupDecrypt;
  final _C7MemberKeyDart _c7MemberKey;
  final _B6MediaKeyDart _b6MediaKey;
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
      -10 => NativeCryptoError.c7KeyMismatch,
      -11 => NativeCryptoError.deviceListMalformed,
      -12 => NativeCryptoError.deviceListSignature,
      -13 => NativeCryptoError.deviceListChain,
      -14 => NativeCryptoError.deviceListRule,
      -15 => NativeCryptoError.deviceListNoSeed,
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

  /// [NativeCryptoBindings.c7Open] only (ABI 13): the key does not match the
  /// sealed value's commitment. Not a data failure: try the next candidate
  /// key. [NativeCryptoBindings.c7Open] turns it into a `null` result.
  c7KeyMismatch,

  /// ABI 14 (L1), the device-list calls: the bytes are not a canonical
  /// statement. Checks run in the order malformed, chain, rule, signature,
  /// so a statement with one fault reports it.
  deviceListMalformed,

  /// ABI 14 (L1): the statement's signature does not verify under the key
  /// the rules name.
  deviceListSignature,

  /// ABI 14 (L1): wrong account, version or `prev_hash`, or no genesis.
  deviceListChain,

  /// ABI 14 (L1): the signer may not make this change, or the entries are
  /// not what the change allows (also: a body this device may not sign).
  deviceListRule,

  /// ABI 14 (L1): recovery signing from the held seed, and none is held.
  deviceListNoSeed,

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
  /// Every leaf of the group as `(account, device, signature key)` (L1,
  /// ABI 14); see `l1_device_list.dart`.
  List<LeafPair> groupMembers(String groupId) => _groupMembersImpl(groupId);

  /// Stages a commit with change list version 2 (L1, ABI 14): each add
  /// names the signing key its key package must hold.
  ({List<int> commit, List<int> welcome, int epoch}) stageCommitKeyed(
    String groupId, {
    List<
            ({
              List<int> keyPackage,
              List<int> accountId,
              List<int> deviceId,
              List<int> signingKey
            })>
        adds = const [],
    List<({List<int> accountId, List<int> deviceId})> removes = const [],
  }) =>
      _stageCommitKeyedImpl(groupId, adds: adds, removes: removes);

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

  /// The 32-byte signature key of the member device [accountId]/[deviceId]
  /// in the current tree of [groupId] (ABI 13,
  /// `pm_crypto_group_member_signature_key`). Fails when this device has no
  /// such group or the group has no such member.
  List<int> memberSignatureKey(
      String groupId, String accountId, String deviceId) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(accountId.codeUnits, 128);
    _bindings._bounded(deviceId.codeUnits, 128);
    return _bindings._withByteLists(
        [groupId.codeUnits, accountId.codeUnits, deviceId.codeUnits],
        (slices) => _bindings._output(
            (out) => _bindings._memberSignatureKey(
                _liveHandle, slices[0], slices[1], slices[2], out),
            maximum: 32));
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

  /// [processCommit] that also reports what the commit did, from MLS itself
  /// (ABI 13, C7). Never trust a server label for this. The commit is staged
  /// and merged as before; for a removal that keeps this device the result
  /// carries the 32-byte exporter `root` of the epoch it produces. The caller
  /// derives its channel keys from it in the same local transaction as the
  /// merged MLS state and then wipes it ([C7CommitOutcome.wipeRoot]). A commit
  /// that removes this device returns [C7CommitOutcome.removedSelf] and no
  /// root.
  C7CommitOutcome c7ProcessCommit(String groupId, List<int> commit) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(commit, 4 * 1024 * 1024);
    return _c7Outcome(
      (flags, epoch, root) => _bindings._withByteLists(
        [groupId.codeUnits, commit],
        (slices) => _bindings._c7ProcessCommit(
            _liveHandle, slices[0], slices[1], flags, epoch, root),
      ),
    );
  }

  /// [mergePendingCommit] that reports like [c7ProcessCommit], for this
  /// device's own staged commit. Refuses a group with nothing staged.
  C7CommitOutcome c7MergePendingCommit(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _c7Outcome(
      (flags, epoch, root) => _bindings._withByteLists(
        [groupId.codeUnits],
        (slices) => _bindings._c7MergePending(
            _liveHandle, slices[0], flags, epoch, root),
      ),
    );
  }

  C7CommitOutcome _c7Outcome(
    int Function(Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>)
        operation,
  ) {
    final flags = calloc<Uint8>();
    final epoch = calloc<Uint64>();
    final root = calloc<_PmOwnedBuffer>();
    try {
      _bindings._check(operation(flags, epoch, root));
      final bits = flags.value;
      if (bits & ~7 != 0) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      final removed = bits & 1 != 0;
      final removedSelf = bits & 4 != 0;
      if (removedSelf && !removed) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      Uint8List? rootBytes;
      if (root.ref.data != nullptr) {
        // Only a removal that keeps this device carries a root.
        if (!removed || removedSelf) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        final taken = _bindings._take(root.ref, maximum: 32);
        root.ref
          ..data = nullptr
          ..len = 0;
        if (taken.length != 32) {
          throw const NativeCryptoException(NativeCryptoError.invalidOutput);
        }
        rootBytes = Uint8List.fromList(taken);
        if (taken is Uint8List) taken.fillRange(0, taken.length, 0);
      } else if (removed && !removedSelf) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      if (epoch.value == 0 && !removedSelf) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      return C7CommitOutcome._(
        removedAny: removed,
        addedAny: bits & 2 != 0,
        removedSelf: removedSelf,
        newEpoch: epoch.value,
        root: rootBytes,
      );
    } finally {
      if (root.ref.data != nullptr) _bindings._free(root.ref);
      calloc.free(flags);
      calloc.free(epoch);
      calloc.free(root);
    }
  }

  /// [decrypt] that also returns the epoch the message was encrypted in
  /// (ABI 13). Errors are [decrypt]'s.
  ({List<int> plaintext, int epoch}) c7Decrypt(
    String groupId,
    List<int> ciphertext, {
    required String senderAccountId,
    required String senderDeviceId,
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(ciphertext, 1024 * 1024 + 4096);
    _bindings._bounded(senderAccountId.codeUnits, 128);
    _bindings._bounded(senderDeviceId.codeUnits, 128);
    final epoch = calloc<Uint64>();
    try {
      final plaintext = _bindings._withByteLists(
        [
          groupId.codeUnits,
          ciphertext,
          senderAccountId.codeUnits,
          senderDeviceId.codeUnits,
        ],
        (slices) => _bindings._output((out) => _bindings._c7GroupDecrypt(
            _liveHandle,
            slices[0],
            slices[1],
            slices[2],
            slices[3],
            out,
            epoch)),
      );
      if (epoch.value == 0) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      return (plaintext: plaintext, epoch: epoch.value);
    } finally {
      calloc.free(epoch);
    }
  }

  /// The 32-byte signature public key of a member device, read from the
  /// group's current tree (ABI 13). An unknown device is an error.
  Uint8List c7MemberSignatureKey(
    String groupId,
    String accountId,
    String deviceId,
  ) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(accountId.codeUnits, 128);
    _bindings._bounded(deviceId.codeUnits, 128);
    final key = _bindings._withByteLists(
      [groupId.codeUnits, accountId.codeUnits, deviceId.codeUnits],
      (slices) => _bindings._output(
          (out) => _bindings._c7MemberKey(
              _liveHandle, slices[0], slices[1], slices[2], out),
          maximum: 32),
    );
    if (key.length != 32) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(key);
  }

  /// B6 (ABI 22): the 32-byte media key `K(s,t)` of the call group
  /// [groupId] at its current epoch, for the sender device and stream
  /// slot [stream] (0 voice, 1 camera, 2 screen, 3 screen audio). The
  /// exporter secret stays in the core. Hand the key to the frame cryptor
  /// and drop it; never store or log it.
  Uint8List b6MediaKey({
    required String groupId,
    required String callId,
    required String senderAccountId,
    required String senderDeviceId,
    required int stream,
  }) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(callId.codeUnits, 128);
    _bindings._bounded(senderAccountId.codeUnits, 128);
    _bindings._bounded(senderDeviceId.codeUnits, 128);
    if (stream < 0 || stream > 3) {
      throw ArgumentError('stream out of range');
    }
    final key = _bindings._withByteLists(
      [
        groupId.codeUnits,
        callId.codeUnits,
        senderAccountId.codeUnits,
        senderDeviceId.codeUnits
      ],
      (slices) => _bindings._output(
          (out) => _bindings._b6MediaKey(_liveHandle, slices[0], slices[1],
              slices[2], slices[3], stream, out),
          maximum: 32),
    );
    if (key.length != 32) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(key);
  }

  /// Signs `domain | message` with this device's credential key (ABI 13).
  /// [domain] must be on the native allowlist, such as
  /// `veritra-c7-post-sig-v1`, `veritra-c7-history-v1` or
  /// `veritra-invite-binding-v2`.
  Uint8List c7Sign({required String domain, required List<int> message}) {
    _bindings._bounded(message, 4096);
    final signature = _bindings._withSlice(
      Uint8List.fromList(utf8.encode(domain)),
      (d) => _bindings._withByteLists(
        [message],
        (slices) => _bindings._output(
            (out) => _bindings._c7Sign(_liveHandle, d, slices[0], out),
            maximum: 64),
      ),
    );
    if (signature.length != 64) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return Uint8List.fromList(signature);
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

/// What a C7 commit call did (ABI 13), from MLS itself. [root] is the
/// exporter secret of [newEpoch] for a removal that keeps this device, else
/// null; call [wipeRoot] once the channel keys are derived.
final class C7CommitOutcome {
  C7CommitOutcome._({
    required this.removedAny,
    required this.addedAny,
    required this.removedSelf,
    required this.newEpoch,
    required Uint8List? root,
  }) : root = root;

  /// At least one Remove proposal (a device replacement included).
  final bool removedAny;

  /// At least one Add proposal.
  final bool addedAny;

  /// This device was removed: no root, and the group store is dropped.
  final bool removedSelf;

  /// The epoch the commit produces (also set when [removedSelf]).
  final int newEpoch;
  final Uint8List? root;

  /// A membership commit has an Add or a Remove (a `history_sync` is owed).
  bool get membership => removedAny || addedAny;

  void wipeRoot() => root?.fillRange(0, root!.length, 0);
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
