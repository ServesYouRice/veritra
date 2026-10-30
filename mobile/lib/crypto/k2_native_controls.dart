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

class K2LinkContext {
  const K2LinkContext(
      {required this.id,
      required this.accountId,
      required this.nonce,
      required this.sourceDeviceId,
      required this.sourceSigningKey,
      required this.recipientDeviceId,
      required this.recipientSigningKey,
      required this.transferPublicKey});
  final K2TransferId id;
  final String accountId, sourceDeviceId, recipientDeviceId;
  final List<int> nonce,
      sourceSigningKey,
      recipientSigningKey,
      transferPublicKey;
  void _write(_K2Writer w) {
    id._write(w);
    w.text(accountId, 128);
    w.fixed(nonce, 32);
    w.text(sourceDeviceId, 128);
    w.fixed(sourceSigningKey, 32);
    w.text(recipientDeviceId, 128);
    w.fixed(recipientSigningKey, 32);
    w.fixed(transferPublicKey, 32);
  }
}

class K2Verification {
  K2Verification._(_K2Reader r)
      : transcriptHash = r.fixed(32),
        claimTag = r.fixed(32),
        sas = ascii.decode(r.fixed(8)) {
    if (!RegExp(r'^\d{8}$').hasMatch(sas)) _K2Reader.invalid();
  }
  final Uint8List transcriptHash, claimTag;
  final String sas;
}

class K2ReceiveResult {
  K2ReceiveResult._(_K2Reader r)
      : transferPublicKey = r.fixed(32),
        verification = K2Verification._(r);
  final Uint8List transferPublicKey;
  final K2Verification verification;
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
    verification = K2Verification._(r);
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

  K2Verification k2SourceAccept(K2LinkContext context, List<int> secret,
      {required int originalExpiresAt,
      required int now,
      required List<int> transcriptHash,
      required List<int> claimTag}) {
    final w = _K2Writer(2);
    context._write(w);
    w.fixed(secret, 16);
    w.u64(originalExpiresAt);
    w.u64(now);
    w.fixed(transcriptHash, 32);
    w.fixed(claimTag, 32);
    final r = _k2Control(w);
    final result = K2Verification._(r);
    r.finish();
    return result;
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
