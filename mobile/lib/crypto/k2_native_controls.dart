part of 'native_crypto_bindings.dart';

/// Low-level ABI8 controls. The service must persist every native mutation
/// before publishing its result or issuing HTTP. These do not perform storage.
class K2TransferId {
  const K2TransferId(this.serverOrigin, this.linkId);
  final String serverOrigin;
  final String linkId;
  void _write(_K2Writer w) {
    w.text(serverOrigin, 2048);
    w.text(linkId, 128);
  }
}

/// The link context (protocol `veritra-device-link-v4`, ABI 18, L1-3).
/// [sourceCommitment] is the existing device's commitment to its random,
/// made when it created the link; [recipientRandom] is the new device's
/// random, a native output of [K2NativeControls.k2ReceiveBegin] (pass zeros
/// there, the returned value afterwards).
class K2LinkContext {
  const K2LinkContext(
      {required this.id,
      required this.accountId,
      required this.nonce,
      required this.sourceDeviceId,
      required this.sourceSigningKey,
      required this.recipientDeviceId,
      required this.recipientSigningKey,
      required this.transferPublicKey,
      required this.sourceCommitment,
      required this.recipientRandom});
  final K2TransferId id;
  final String accountId, sourceDeviceId, recipientDeviceId;
  final List<int> nonce,
      sourceSigningKey,
      recipientSigningKey,
      transferPublicKey,
      sourceCommitment,
      recipientRandom;
  void _write(_K2Writer w) {
    id._write(w);
    w.text(accountId, 128);
    w.fixed(nonce, 32);
    w.text(sourceDeviceId, 128);
    w.fixed(sourceSigningKey, 32);
    w.text(recipientDeviceId, 128);
    w.fixed(recipientSigningKey, 32);
    w.fixed(transferPublicKey, 32);
    w.fixed(sourceCommitment, 32);
    w.fixed(recipientRandom, 32);
  }
}

/// [sas] is the 8-digit code. It is empty only in a [K2Status] of the new
/// device: its SAS needs the source's revealed random, see
/// [K2NativeControls.k2RevealSas].
class K2Verification {
  K2Verification._(_K2Reader r)
      : transcriptHash = r.fixed(32),
        claimTag = r.fixed(32),
        sas = ascii.decode(r.fixed(8)) {
    if (!RegExp(r'^\d{8}$').hasMatch(sas)) _K2Reader.invalid();
  }
  K2Verification._status(_K2Reader r)
      : transcriptHash = r.fixed(32),
        claimTag = r.fixed(32),
        sas = _optionalSas(r);
  final Uint8List transcriptHash, claimTag;
  final String sas;

  static String _optionalSas(_K2Reader r) {
    final present = r.boolean();
    final bytes = r.fixed(8);
    if (!present) {
      if (bytes.any((b) => b != 0)) _K2Reader.invalid();
      return '';
    }
    final sas = ascii.decode(bytes, allowInvalid: true);
    if (!RegExp(r'^\d{8}$').hasMatch(sas)) _K2Reader.invalid();
    return sas;
  }
}

/// The new device's begin: its transfer key, its fresh random (sent in the
/// claim) and the claim transcript hash and tag. No SAS yet.
class K2ReceiveResult {
  K2ReceiveResult._(_K2Reader r)
      : transferPublicKey = r.fixed(32),
        recipientRandom = r.fixed(32),
        transcriptHash = r.fixed(32),
        claimTag = r.fixed(32);
  final Uint8List transferPublicKey, recipientRandom, transcriptHash, claimTag;
}

enum K2Direction { outgoing, incoming }

/// Native stage4 means posted for source and importing for recipient.
enum K2Stage { waitingApproval, approved, ready, posted, importing }

class K2Status {
  K2Status._(_K2Reader r) {
    final directionByte = r.byte();
    final stageByte = r.byte();
    if (directionByte < 1 ||
        directionByte > 2 ||
        stageByte < 1 ||
        stageByte > 4) {
      _K2Reader.invalid();
    }
    direction = K2Direction.values[directionByte - 1];
    stage = stageByte == 4
        ? (direction == K2Direction.incoming
            ? K2Stage.importing
            : K2Stage.posted)
        : K2Stage.values[stageByte - 1];
    intentPresent = r.boolean();
    originalExpiresAt = r.u64();
    approvedAt = r.u64();
    transferExpiresAt = r.u64();
    verification = K2Verification._status(r);
    if ((verification.sas.isEmpty) != (direction == K2Direction.incoming)) {
      _K2Reader.invalid();
    }
  }
  late final K2Direction direction;
  late final K2Stage stage;
  late final bool intentPresent;
  late final int originalExpiresAt, approvedAt, transferExpiresAt;
  late final K2Verification verification;
}

class K2ProofResult {
  K2ProofResult._(_K2Reader r)
      : signature = r.fixed(64),
        requestHash = r.fixed(32);
  final Uint8List signature, requestHash;
}

class K2ApprovalRequest {
  K2ApprovalRequest._(_K2Reader r)
      : transcriptHash = r.fixed(32),
        approvalTag = r.fixed(32);
  final Uint8List transcriptHash, approvalTag;
}

extension K2NativeControls on NativeCryptoDevice {
  K2ReceiveResult k2ReceiveBegin(K2LinkContext context, List<int> secret,
      {required int originalExpiresAt, required int now}) {
    final w = _K2Writer(1);
    context._write(w);
    w.fixed(secret, 16);
    w.u64(originalExpiresAt);
    w.u64(now);
    final r = _k2Control(w);
    final result = K2ReceiveResult._(r);
    r.finish();
    return result;
  }

  /// The source accepts the claim. [sourceRandom] must open
  /// [K2LinkContext.sourceCommitment]; reveal it to the server only after
  /// this record is committed (L1-3).
  K2Verification k2SourceAccept(K2LinkContext context, List<int> secret,
      {required int originalExpiresAt,
      required int now,
      required List<int> transcriptHash,
      required List<int> claimTag,
      required List<int> sourceRandom}) {
    final w = _K2Writer(2);
    context._write(w);
    w.fixed(secret, 16);
    w.u64(originalExpiresAt);
    w.u64(now);
    w.fixed(transcriptHash, 32);
    w.fixed(claimTag, 32);
    w.fixed(sourceRandom, 32);
    final r = _k2Control(w);
    final result = K2Verification._(r);
    r.finish();
    return result;
  }

  /// The new device's SAS from the source's revealed random (ABI 18). Read
  /// only; refused when the random does not open the pinned commitment.
  String k2RevealSas(K2TransferId id, List<int> sourceRandom,
      {required int now}) {
    final w = _K2Writer(12);
    id._write(w);
    w.fixed(sourceRandom, 32);
    w.u64(now);
    final r = _k2Control(w);
    final sas = ascii.decode(r.fixed(8), allowInvalid: true);
    r.finish();
    if (!RegExp(r'^\d{8}$').hasMatch(sas)) _K2Reader.invalid();
    return sas;
  }

  /// This device's commitment to [sourceRandom] for a link it is about to
  /// create on [serverOrigin] (ABI 18). Pure; changes no state.
  Uint8List k2SourceCommitment(String serverOrigin, List<int> sourceRandom) {
    final w = _K2Writer(13);
    w.text(serverOrigin, 2048);
    w.fixed(sourceRandom, 32);
    final r = _k2Control(w);
    final commitment = r.fixed(32);
    r.finish();
    return commitment;
  }

  K2Status k2Inspect(K2TransferId id, {required int now}) {
    final w = _K2Writer(3);
    id._write(w);
    w.u64(now);
    final r = _k2Control(w);
    final result = K2Status._(r);
    r.finish();
    return result;
  }

  K2ProofResult k2EnrollmentProof(K2TransferId id,
      {required int now,
      required String locator,
      required List<int> reservationRequestId,
      required String deviceName,
      required List<int> challenge,
      required List<int> keyPackage,
      required List<int> claimTokenHash,
      required List<int> deviceSecretHash,
      required List<int> initialSessionHash}) {
    final w = _K2Writer(4);
    id._write(w);
    w.u64(now);
    w.text(locator, 64);
    w.fixed(reservationRequestId, 32);
    w.text(deviceName, 64);
    w.blob16(challenge, 4096);
    w.blob32(keyPackage, 48 * 1024);
    w.fixed(claimTokenHash, 32);
    w.fixed(deviceSecretHash, 32);
    w.fixed(initialSessionHash, 32);
    final r = _k2Control(w);
    final result = K2ProofResult._(r);
    r.finish();
    return result;
  }

  /// Returns only the first frozen intent timestamp. Commit sealed state
  /// before calling k2SourceApprovalRequest or issuing any approval HTTP.
  int k2SourceConfirm(K2TransferId id, String typedSas, {required int now}) {
    final w = _K2Writer(5);
    id._write(w);
    w.fixed(ascii.encode(typedSas), 8);
    w.u64(now);
    final r = _k2Control(w);
    if (!r.boolean()) _K2Reader.invalid();
    final timestamp = r.u64();
    r.finish();
    return timestamp;
  }

  K2ApprovalRequest k2SourceApprovalRequest(K2TransferId id,
      {required int now}) {
    final w = _K2Writer(6);
    id._write(w);
    w.u64(now);
    final r = _k2Control(w);
    final result = K2ApprovalRequest._(r);
    r.finish();
    return result;
  }

  int k2ApplyApproval(K2TransferId id, List<int> approvalTag,
      {required int approvedAt, required int now}) {
    final w = _K2Writer(7);
    id._write(w);
    w.fixed(approvalTag, 32);
    w.u64(approvedAt);
    w.u64(now);
    final r = _k2Control(w);
    final deadline = r.u64();
    r.finish();
    return deadline;
  }

  void k2SourcePosted(K2TransferId id, {required int now}) =>
      _k2StageMutation(8, id, now);
  void k2Importing(K2TransferId id, {required int now}) =>
      _k2StageMutation(9, id, now);
  void _k2StageMutation(int op, K2TransferId id, int now) {
    final w = _K2Writer(op);
    id._write(w);
    w.u64(now);
    final r = _k2Control(w);
    if (r.byte() != 4) _K2Reader.invalid();
    r.finish();
  }

  bool k2Forget(K2TransferId id) {
    final w = _K2Writer(10);
    id._write(w);
    final r = _k2Control(w);
    final removed = r.boolean();
    r.finish();
    return removed;
  }

  int k2Expire({required int now}) {
    final w = _K2Writer(11);
    w.u64(now);
    final r = _k2Control(w);
    final count = r.u16();
    r.finish();
    return count;
  }
}

class _K2Writer {
  _K2Writer(this.operation) {
    _out.add(const [80, 75, 50, 81, 1]);
    _uint(operation, 2);
  }
  final int operation;
  final _out = BytesBuilder(copy: false);
  void _uint(int value, int width) {
    if (value < 0 ||
        (width == 2 && value > 65535) ||
        (width == 4 && value > 0xffffffff)) {
      throw ArgumentError('K2 integer out of range');
    }
    final b = ByteData(width);
    if (width == 2) {
      b.setUint16(0, value);
    } else if (width == 4) {
      b.setUint32(0, value);
    } else {
      b.setUint64(0, value);
    }
    _out.add(b.buffer.asUint8List());
  }

  void u64(int value) => _uint(value, 8);
  void fixed(List<int> value, int size) {
    if (value.length != size || value.any((b) => b < 0 || b > 255))
      throw ArgumentError('K2 fixed field');
    _out.add(value);
  }

  void text(String value, int max) => blob16(utf8.encode(value), max);
  void blob16(List<int> value, int max) => _blob(value, max, 2);
  void blob32(List<int> value, int max) => _blob(value, max, 4);
  void _blob(List<int> value, int max, int width) {
    if (value.isEmpty ||
        value.length > max ||
        value.any((b) => b < 0 || b > 255))
      throw ArgumentError('K2 field size');
    _uint(value.length, width);
    _out.add(value);
  }

  Uint8List bytes() => _out.takeBytes();
}

class _K2Reader {
  _K2Reader(this._bytes, int operation, {int maximum = 64 * 1024}) {
    if (_bytes.length > maximum ||
        !_same(fixed(5), const [80, 75, 50, 82, 1]) ||
        u16() != operation) invalid();
  }
  final Uint8List _bytes;
  int _at = 0;
  static Never invalid() =>
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  static bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);
  Uint8List fixed(int count) {
    if (count < 0 || _at + count > _bytes.length) invalid();
    final value = Uint8List.fromList(_bytes.sublist(_at, _at + count));
    _at += count;
    return value;
  }

  int byte() => fixed(1)[0];
  bool boolean() {
    final b = byte();
    if (b > 1) invalid();
    return b == 1;
  }

  int u16() => ByteData.sublistView(fixed(2)).getUint16(0);
  int u64() {
    final v = ByteData.sublistView(fixed(8)).getUint64(0);
    if (v < 0) invalid();
    return v;
  }

  void finish() {
    if (_at != _bytes.length) invalid();
  }
}
