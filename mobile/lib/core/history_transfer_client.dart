import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'api_errors.dart';
import 'server_origin.dart' show canonicalizeServerOrigin;

/// K2 history transfer transport (`docs/designs/K2-transfer-resource.md`).
///
/// Moves one opaque encrypted history container between two devices of the
/// same account through `/api/v1/device-links/v3/{id}/history`. The server
/// and this class only ever see ciphertext, its digest and size, and the
/// opaque native handoff; neither parses the container. Authenticity of the
/// whole ciphertext is checked by the native receive stream, which knows the
/// digest from the verified handoff; this class checks the size and the
/// server's `ETag` so a resumed download never mixes two bodies.
///
/// Every request refuses redirects, so neither a session token nor a claim
/// token can be forwarded to another origin.
const historyTransferProtocol = 'veritra-device-link-v3';

/// Largest ciphertext the server accepts for one transfer.
const maxHistoryCiphertextBytes = 100 * 1024 * 1024;
const maxHistoryHandoffBytes = 8192;

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// The metadata part of the upload. All fields come from the native source
/// stream and the approved v3 link; none is derived from plaintext.
class HistoryTransferMetadata {
  HistoryTransferMetadata({
    required this.transferId,
    required this.claimRequestHash,
    required List<int> transcriptHash,
    required this.ciphertextSha256,
    required this.sizeBytes,
    required List<int> handoff,
  })  : transcriptHash = Uint8List.fromList(transcriptHash),
        handoff = Uint8List.fromList(handoff) {
    if (!_hex64.hasMatch(transferId) ||
        !_hex64.hasMatch(claimRequestHash) ||
        !_hex64.hasMatch(ciphertextSha256) ||
        this.transcriptHash.length != 32 ||
        sizeBytes <= 0 ||
        sizeBytes > maxHistoryCiphertextBytes ||
        this.handoff.isEmpty ||
        this.handoff.length > maxHistoryHandoffBytes) {
      throw ArgumentError('invalid history transfer metadata');
    }
  }

  final String transferId, claimRequestHash, ciphertextSha256;
  final Uint8List transcriptHash, handoff;
  final int sizeBytes;

  Map<String, Object?> toJson() => {
        'protocol_version': historyTransferProtocol,
        'transfer_id': transferId,
        'claim_request_hash': claimRequestHash,
        'transcript_hash': base64Encode(transcriptHash),
        'ciphertext_sha256': ciphertextSha256,
        'size_bytes': sizeBytes,
        'handoff': base64Encode(handoff),
      };
}

/// The server's receipt. Only the exact recipient ever receives [handoff].
class HistoryTransferReceipt {
  const HistoryTransferReceipt({
    required this.transferId,
    required this.linkId,
    required this.accountId,
    required this.sourceDeviceId,
    required this.recipientDeviceId,
    required this.claimRequestHash,
    required this.transcriptHash,
    required this.ciphertextSha256,
    required this.sizeBytes,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
    this.handoff,
    this.terminalAt,
  });

  final String transferId, linkId, accountId, sourceDeviceId;
  final String recipientDeviceId, claimRequestHash, ciphertextSha256, state;
  final Uint8List transcriptHash;
  final Uint8List? handoff;
  final int sizeBytes;
  final DateTime createdAt, expiresAt;
  final DateTime? terminalAt;

  bool get active => state == 'active';

  /// Strict decoding: a malformed receipt is one typed failure and never a
  /// partially trusted object.
  factory HistoryTransferReceipt.fromJson(Object? body) {
    try {
      final outer = body as Map;
      final j = outer['transfer'] as Map;
      String hex(String k) {
        final v = j[k] as String;
        if (!_hex64.hasMatch(v)) throw const FormatException();
        return v;
      }

      String text(String k) {
        final v = j[k] as String;
        if (v.isEmpty || v.length > 256) throw const FormatException();
        return v;
      }

      final transcript = base64Decode(j['transcript_hash'] as String);
      final size = (j['size_bytes'] as num).toInt();
      final handoff =
          j['handoff'] == null ? null : base64Decode(j['handoff'] as String);
      if (transcript.length != 32 ||
          size <= 0 ||
          size > maxHistoryCiphertextBytes ||
          (handoff != null &&
              (handoff.isEmpty || handoff.length > maxHistoryHandoffBytes))) {
        throw const FormatException();
      }
      return HistoryTransferReceipt(
        transferId: hex('transfer_id'),
        linkId: text('link_id'),
        accountId: text('account_id'),
        sourceDeviceId: text('source_device_id'),
        recipientDeviceId: text('recipient_device_id'),
        claimRequestHash: hex('claim_request_hash'),
        transcriptHash: transcript,
        ciphertextSha256: hex('ciphertext_sha256'),
        sizeBytes: size,
        state: text('state'),
        handoff: handoff,
        createdAt: DateTime.parse(j['created_at'] as String),
        expiresAt: DateTime.parse(j['expires_at'] as String),
        terminalAt: j['terminal_at'] == null
            ? null
            : DateTime.parse(j['terminal_at'] as String),
      );
    } on ApiResponseException {
      rethrow;
    } catch (_) {
      throw const ApiResponseException();
    }
  }

  /// Whether this receipt describes exactly [metadata].
  bool matches(HistoryTransferMetadata metadata) =>
      transferId == metadata.transferId &&
      claimRequestHash == metadata.claimRequestHash &&
      ciphertextSha256 == metadata.ciphertextSha256 &&
      sizeBytes == metadata.sizeBytes &&
      _equal(transcriptHash, metadata.transcriptHash);
}

/// How a request proves who it is. The recipient may use either its new
/// ordinary session or the link's claim token; the source always uses its
/// session.
sealed class HistoryTransferAuth {
  const HistoryTransferAuth();
  void _apply(HttpClientRequest request);
}

class HistorySessionAuth extends HistoryTransferAuth {
  const HistorySessionAuth(this.token);
  final String token;
  @override
  void _apply(HttpClientRequest request) =>
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
}

class HistoryClaimAuth extends HistoryTransferAuth {
  HistoryClaimAuth(List<int> claimToken)
      : _token = base64Url.encode(claimToken).replaceAll('=', '') {
    if (claimToken.length != 32) {
      // Never echo the token.
      throw ArgumentError('invalid claim token');
    }
  }
  final String _token;
  @override
  void _apply(HttpClientRequest request) =>
      request.headers.set('X-Veritra-Claim-Token', _token);
}

/// Thrown when downloaded bytes cannot belong to the expected transfer: the
/// server's ETag or the byte count does not match. The partial file is
/// removed so the next attempt starts clean.
class HistoryTransferMismatch implements Exception {
  const HistoryTransferMismatch();
  @override
  String toString() => 'HistoryTransferMismatch';
}

class HistoryTransferClient {
  HistoryTransferClient({required String baseUrl, HttpClient? httpClient})
      : baseUrl = canonicalizeServerOrigin(baseUrl),
        _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 15);
  }

  final String baseUrl;
  final HttpClient _http;
  static const _timeout = Duration(seconds: 30);

  /// Upload budget, matching the server's five-minute body budget.
  static const _uploadTimeout = Duration(minutes: 5);

  Uri _uri(String linkId, [String suffix = '']) {
    if (linkId.isEmpty || linkId.length > 128) {
      throw ArgumentError('invalid link id');
    }
    return Uri.parse(baseUrl).resolve(
        '/api/v1/device-links/v3/${Uri.encodeComponent(linkId)}/history$suffix');
  }

  Future<HttpClientRequest> _open(String method, Uri uri,
      [HistoryTransferAuth? auth]) async {
    final request = await _http.openUrl(method, uri).timeout(_timeout);
    request.followRedirects = false;
    auth?._apply(request);
    return request;
  }

  /// Source only: posts metadata then exactly [HistoryTransferMetadata.sizeBytes]
  /// ciphertext bytes read from [ciphertext] (the durable source cache). An
  /// exact retry after a lost response returns the original receipt; a
  /// receipt for different metadata is refused.
  Future<HistoryTransferReceipt> upload({
    required String token,
    required String linkId,
    required HistoryTransferMetadata metadata,
    required Stream<List<int>> Function() ciphertext,
  }) async {
    final boundary = 'veritra-${_randomHex(16)}';
    final head = utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="metadata"\r\n'
        'Content-Type: application/json\r\n\r\n'
        '${jsonEncode(metadata.toJson())}\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="ciphertext"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final request =
        await _open('POST', _uri(linkId), HistorySessionAuth(token));
    request.headers.set(HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary');
    request.contentLength = head.length + metadata.sizeBytes + tail.length;
    request.add(head);
    var sent = 0;
    await request
        .addStream(ciphertext().map((chunk) {
          sent += chunk.length;
          if (sent > metadata.sizeBytes) throw const HistoryTransferMismatch();
          return chunk;
        }))
        .timeout(_uploadTimeout);
    if (sent != metadata.sizeBytes) {
      request.abort(const HistoryTransferMismatch());
      throw const HistoryTransferMismatch();
    }
    request.add(tail);
    final response = await request.close().timeout(_uploadTimeout);
    final receipt = HistoryTransferReceipt.fromJson(await _json(response));
    if (!receipt.matches(metadata)) throw const ApiResponseException();
    return receipt;
  }

  /// Receipt and, for the exact recipient while active, the opaque handoff.
  Future<HistoryTransferReceipt> status(
          String linkId, HistoryTransferAuth auth) async =>
      HistoryTransferReceipt.fromJson(await _json(
          await (await _open('GET', _uri(linkId), auth))
              .close()
              .timeout(_timeout)));

  /// Recipient only: downloads the ciphertext into [target], resuming from
  /// its current length when the server still serves the same body
  /// (`If-Range` with the expected ETag). Returns the final length, always
  /// [expectedSize]. The caller passes the file to the native receive stream,
  /// which authenticates the whole container before any plaintext exists.
  Future<int> download({
    required String linkId,
    required HistoryTransferAuth auth,
    required String expectedSha256,
    required int expectedSize,
    required File target,
  }) async {
    if (!_hex64.hasMatch(expectedSha256) ||
        expectedSize <= 0 ||
        expectedSize > maxHistoryCiphertextBytes) {
      throw ArgumentError('invalid expected ciphertext');
    }
    final etag = '"sha256-$expectedSha256"';
    var offset = await target.exists() ? await target.length() : 0;
    if (offset > expectedSize) {
      await _discard(target);
      offset = 0;
    }
    if (offset == expectedSize) return offset;
    final request = await _open('GET', _uri(linkId, '/content'), auth);
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      request.headers.set(HttpHeaders.ifRangeHeader, etag);
    }
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw await _error(response);
    }
    if (response.headers.value(HttpHeaders.etagHeader) != etag) {
      await response.listen(null).cancel();
      await _discard(target);
      throw const HistoryTransferMismatch();
    }
    if (response.statusCode == 200) {
      // The server sent the whole body (no range, or If-Range failed).
      offset = 0;
    } else {
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      if (offset == 0 ||
          range != 'bytes $offset-${expectedSize - 1}/$expectedSize') {
        await response.listen(null).cancel();
        await _discard(target);
        throw const HistoryTransferMismatch();
      }
    }
    if (response.contentLength >= 0 &&
        response.contentLength != expectedSize - offset) {
      await response.listen(null).cancel();
      await _discard(target);
      throw const HistoryTransferMismatch();
    }
    final file =
        await target.open(mode: offset == 0 ? FileMode.write : FileMode.append);
    var written = offset;
    try {
      await for (final chunk in response.timeout(_timeout)) {
        written += chunk.length;
        if (written > expectedSize) {
          throw const HistoryTransferMismatch();
        }
        await file.writeFrom(chunk);
      }
      await file.flush();
    } on HistoryTransferMismatch {
      await file.close();
      await _discard(target);
      rethrow;
    } finally {
      try {
        await file.close();
      } catch (_) {}
    }
    // A short body keeps its prefix for the next resume.
    if (written != expectedSize) throw const ApiResponseException();
    return written;
  }

  /// Recipient only, and only after the import transaction and its import
  /// ledger have committed. An exact replay returns the same receipt.
  Future<HistoryTransferReceipt> acknowledge({
    required String linkId,
    required HistoryTransferAuth auth,
    required String transferId,
    required String ciphertextSha256,
  }) async {
    if (!_hex64.hasMatch(transferId) || !_hex64.hasMatch(ciphertextSha256)) {
      throw ArgumentError('invalid acknowledgement');
    }
    final request = await _open('POST', _uri(linkId, '/ack'), auth);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'protocol_version': historyTransferProtocol,
      'transfer_id': transferId,
      'ciphertext_sha256': ciphertextSha256,
    }));
    final receipt = HistoryTransferReceipt.fromJson(
        await _json(await request.close().timeout(_timeout)));
    if (receipt.transferId != transferId ||
        receipt.ciphertextSha256 != ciphertextSha256 ||
        receipt.state != 'acknowledged') {
      throw const ApiResponseException();
    }
    return receipt;
  }

  /// Cancels the copy for the source or the recipient. Idempotent. Never
  /// unlinks or revokes a device.
  Future<void> cancel(String linkId, HistoryTransferAuth auth) async {
    await _json(await (await _open('DELETE', _uri(linkId), auth))
        .close()
        .timeout(_timeout));
  }

  void close() => _http.close(force: true);

  static Future<Object?> _json(HttpClientResponse response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _error(response);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > 64 * 1024) {
        throw const ApiResponseTooLargeException();
      }
      bytes.add(chunk);
    }
    try {
      return jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw const ApiResponseException();
    }
  }

  static Future<ApiException> _error(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_timeout)) {
      final room = ApiException.maxErrorBodyBytes - bytes.length;
      if (chunk.length >= room) {
        bytes.add(chunk.sublist(0, room));
        break;
      }
      bytes.add(chunk);
    }
    return ApiException(
        response.statusCode,
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
        ApiException.parseRetryAfter(
            response.headers.value(HttpHeaders.retryAfterHeader)));
  }

  static Future<void> _discard(File target) async {
    try {
      if (await target.exists()) await target.delete();
    } on FileSystemException {
      // Ciphertext only; a leftover is overwritten from offset zero.
    }
  }
}

String _randomHex(int bytes) {
  final random = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0')
  ].join();
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
