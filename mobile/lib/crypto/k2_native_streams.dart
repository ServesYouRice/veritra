part of 'native_crypto_bindings.dart';

final class _PmHistoryStream extends Opaque {}

typedef _K2BeginNative = Int32 Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    Pointer<Pointer<_PmHistoryStream>>, Pointer<_PmOwnedBuffer>);
typedef _K2BeginDart = int Function(Pointer<_PmCryptoHandle>, _PmByteSlice,
    Pointer<Pointer<_PmHistoryStream>>, Pointer<_PmOwnedBuffer>);
typedef _K2StreamNative = Int32 Function(
    Pointer<_PmHistoryStream>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _K2StreamDart = int Function(
    Pointer<_PmHistoryStream>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _K2FinishNative = Int32 Function(Pointer<_PmCryptoHandle>,
    Pointer<_PmHistoryStream>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _K2FinishDart = int Function(Pointer<_PmCryptoHandle>,
    Pointer<_PmHistoryStream>, _PmByteSlice, Pointer<_PmOwnedBuffer>);
typedef _K2DestroyNative = Void Function(Pointer<_PmHistoryStream>);
typedef _K2DestroyDart = void Function(Pointer<_PmHistoryStream>);

class _K2StreamBindings {
  _K2StreamBindings(DynamicLibrary library)
      : sourceBegin = library.lookupFunction<_K2BeginNative, _K2BeginDart>(
            'pm_crypto_k2_source_begin'),
        receiveBegin = library.lookupFunction<_K2BeginNative, _K2BeginDart>(
            'pm_crypto_k2_receive_begin_bundle'),
        write = library.lookupFunction<_K2StreamNative, _K2StreamDart>(
            'pm_crypto_k2_stream_write'),
        read = library.lookupFunction<_K2StreamNative, _K2StreamDart>(
            'pm_crypto_k2_stream_read'),
        sourceFinish = library.lookupFunction<_K2FinishNative, _K2FinishDart>(
            'pm_crypto_k2_source_finish'),
        receiveFinish = library.lookupFunction<_K2FinishNative, _K2FinishDart>(
            'pm_crypto_k2_receive_finish'),
        destroy = library.lookupFunction<_K2DestroyNative, _K2DestroyDart>(
            'pm_crypto_k2_stream_destroy'),
        finalizer = NativeFinalizer(library
            .lookup<NativeFunction<_K2DestroyNative>>(
                'pm_crypto_k2_stream_destroy')
            .cast());
  final _K2BeginDart sourceBegin, receiveBegin;
  final _K2StreamDart write, read;
  final _K2FinishDart sourceFinish, receiveFinish;
  final _K2DestroyDart destroy;
  final NativeFinalizer finalizer;
}

String _k2TransferId(_K2Reader r) {
  final size = r.u16();
  if (size != 64) _K2Reader.invalid();
  final value = ascii.decode(r.fixed(size));
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) _K2Reader.invalid();
  return value;
}

class K2SourceBundleResult {
  K2SourceBundleResult._(_K2Reader r)
      : transferId = _k2TransferId(r),
        headerHash = r.fixed(32),
        ciphertextHash = r.fixed(32),
        ciphertextSize = r.u64() {
    final count = ByteData.sublistView(r.fixed(4)).getUint32(0);
    if (count == 0 || count > 8192) _K2Reader.invalid();
    handoff = r.fixed(count);
  }
  final String transferId;
  final Uint8List headerHash, ciphertextHash;
  final int ciphertextSize;
  late final Uint8List handoff;
}

class K2ReceiveBundleResult {
  K2ReceiveBundleResult._(this.stream, _K2Reader r)
      : transferId = _k2TransferId(r),
        ciphertextHash = r.fixed(32),
        ciphertextSize = r.u64(),
        headerHash = r.fixed(32),
        snapshotCounter = r.u64();
  final K2HistoryStream stream;
  final String transferId;
  final Uint8List ciphertextHash, headerHash;
  final int ciphertextSize, snapshotCounter;
}

class K2OpenedBundleResult {
  K2OpenedBundleResult._(_K2Reader r)
      : payloadLength = r.u64(),
        snapshotCounter = r.u64(),
        plaintextVersion = r.byte(),
        createdAt = r.u64();
  final int payloadLength, snapshotCounter, plaintextVersion, createdAt;
}

class K2StreamChunk {
  const K2StreamChunk(this.nextOffset, this.eof, this.bytes);

  /// Decodes an owned native read-result frame. Failure wipes the entire
  /// allocation, including when its outer header is malformed. A successful
  /// result owns a view into [frame]; consume and wipe [bytes] afterwards.
  factory K2StreamChunk.fromOwnedNativeFrame(Uint8List frame,
          {required int offset, int maximum = 1024 * 1024}) =>
      K2StreamChunk._fromReader(_ownedStreamReader(frame, 25), offset, maximum);

  static K2StreamChunk _fromReader(_K2Reader r, int offset, int maximum) {
    try {
      if (offset < 0 || maximum < 1 || maximum > 1024 * 1024) {
        _K2Reader.invalid();
      }
      final next = r.u64();
      final eof = r.boolean();
      final size = ByteData.sublistView(r.fixed(4)).getUint32(0);
      if (size > 1024 * 1024 ||
          size > maximum ||
          next != offset + size ||
          (size == 0 && !eof)) _K2Reader.invalid();
      if (r._at + size != r._bytes.length) _K2Reader.invalid();
      final bytes = Uint8List.sublistView(r._bytes, r._at);
      r._at += size;
      r.finish();
      return K2StreamChunk(next, eof, bytes);
    } catch (_) {
      r._bytes.fillRange(0, r._bytes.length, 0);
      rethrow;
    }
  }

  final int nextOffset;
  final bool eof;

  /// Incoming plaintext is caller-owned memory: process then overwrite it.
  final Uint8List bytes;
}

_K2Reader _ownedStreamReader(List<int> result, int operation) {
  final bytes = result is Uint8List ? result : Uint8List.fromList(result);
  try {
    return _K2Reader(bytes, operation, maximum: 1024 * 1024 + 32);
  } catch (_) {
    bytes.fillRange(0, bytes.length, 0);
    if (!identical(bytes, result)) result.fillRange(0, result.length, 0);
    rethrow;
  }
}

extension K2NativeBundleStreams on NativeCryptoDevice {
  K2HistoryStream k2SourceBegin(K2TransferId id,
      {required int now,
      required int createdAt,
      required int snapshotCounter,
      required int plaintextVersion,
      required int payloadLength}) {
    final w = _K2Writer(20);
    id._write(w);
    w.u64(now);
    w.u64(createdAt);
    w.u64(snapshotCounter);
    w.fixed([plaintextVersion], 1);
    w.u64(payloadLength);
    final opened = _k2BeginStream(w, false);
    try {
      opened.reader.finish();
      return opened.stream;
    } catch (_) {
      opened.stream.close();
      rethrow;
    }
  }

  /// Verify and persist native handoff state+exact handoff bytes before fetching
  /// ciphertext/importing. Returned transferId must match server metadata.
  K2ReceiveBundleResult k2ReceiveBeginBundle(K2TransferId id, List<int> handoff,
      {required int now, required int plaintextVersion}) {
    final w = _K2Writer(23);
    id._write(w);
    w.u64(now);
    w.blob32(handoff, 8192);
    w.fixed([plaintextVersion], 1);
    final opened = _k2BeginStream(w, true);
    try {
      final result = K2ReceiveBundleResult._(opened.stream, opened.reader);
      opened.reader.finish();
      return result;
    } catch (_) {
      opened.stream.close();
      rethrow;
    }
  }

  ({K2HistoryStream stream, _K2Reader reader}) _k2BeginStream(
      _K2Writer w, bool incoming) {
    final pointer = calloc<Pointer<_PmHistoryStream>>();
    final bytes = w.bytes();
    K2HistoryStream? stream;
    try {
      _bindings._bounded(bytes, 64 * 1024);
      final result = _bindings._withSlice(
          bytes,
          (slice) => _bindings._output((out) => (incoming
                  ? _bindings._k2Streams.receiveBegin
                  : _bindings._k2Streams.sourceBegin)(
              _liveHandle, slice, pointer, out)));
      if (pointer.value == nullptr) _K2Reader.invalid();
      stream = K2HistoryStream._(this, pointer.value);
      pointer.value = nullptr;
      final r = _K2Reader(
          result is Uint8List ? result : Uint8List.fromList(result),
          w.operation);
      return (stream: stream, reader: r);
    } catch (_) {
      stream?.close();
      rethrow;
    } finally {
      if (pointer.value != nullptr) _bindings._k2Streams.destroy(pointer.value);
      calloc.free(pointer);
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}

/// One process-local, bounded native stream. Always close explicitly. Device
/// close invalidates/wipes its native data even while this Dart object exists.
class K2HistoryStream implements Finalizable {
  K2HistoryStream._(this._owner, this._pointer) {
    _owner._bindings._k2Streams.finalizer
        .attach(this, _pointer.cast(), detach: this);
  }
  final NativeCryptoDevice _owner;
  Pointer<_PmHistoryStream> _pointer;
  Pointer<_PmHistoryStream> get _live {
    if (_pointer == nullptr) throw StateError('History stream is closed');
    return _pointer;
  }

  int write(int offset, List<int> bytes) {
    final w = _K2Writer(21);
    w.u64(offset);
    w.blob32(bytes, 1024 * 1024);
    final r = _call(w);
    final next = r.u64();
    r.finish();
    return next;
  }

  /// Returns opaque ciphertext metadata only. Drain ciphertext to a durable
  /// cache, then atomically persist manifest+handoff+sealed state before HTTP.
  K2SourceBundleResult sourceFinish({required int now}) {
    final w = _K2Writer(22);
    w.u64(now);
    final r = _call(w);
    final result = K2SourceBundleResult._(r);
    r.finish();
    return result;
  }

  /// No plaintext read succeeds until the whole file passes authentication.
  K2OpenedBundleResult receiveFinish({required int now}) {
    final w = _K2Writer(24);
    w.u64(now);
    final r = _call(w);
    final result = K2OpenedBundleResult._(r);
    r.finish();
    return result;
  }

  K2StreamChunk read(int offset, {int maximum = 1024 * 1024}) {
    final w = _K2Writer(25);
    w.u64(offset);
    w._uint(maximum, 4);
    return K2StreamChunk._fromReader(_call(w), offset, maximum);
  }

  _K2Reader _call(_K2Writer w) {
    final bytes = w.bytes();
    final binding = _owner._bindings;
    try {
      final result = binding._withSlice(
          bytes,
          (slice) => binding._output((out) => switch (w.operation) {
                21 => binding._k2Streams.write(_live, slice, out),
                22 => binding._k2Streams
                    .sourceFinish(_owner._liveHandle, _live, slice, out),
                24 => binding._k2Streams
                    .receiveFinish(_owner._liveHandle, _live, slice, out),
                25 => binding._k2Streams.read(_live, slice, out),
                _ => throw StateError('Unknown stream operation'),
              }));
      return _ownedStreamReader(result, w.operation);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void close() {
    if (_pointer == nullptr) return;
    _owner._bindings._k2Streams.finalizer.detach(this);
    final pointer = _pointer;
    _pointer = nullptr;
    _owner._bindings._k2Streams.destroy(pointer);
  }
}
