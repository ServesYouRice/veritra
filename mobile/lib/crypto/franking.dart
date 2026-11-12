import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// C6 franking v1 wire form (`docs/crypto.md`, "Franking v1";
/// docs/designs/C6-reports-franking.md). Pure byte rules, no crypto: the
/// commitment itself is `ReportCryptoService.frankCommit` (ABI 12).
///
/// The canonical payload bytes `P` are the inner JSON exactly as the sender's
/// encoder wrote it without `frank`. The wire JSON is `P` without its final
/// `}`, then [_prefix], the standard padded base64 of the 32-byte key, and
/// [_tail]. Nothing is re-serialized, so `P` is the same bytes for the
/// sender, every receiver and a verifier, whatever JSON library each uses.

/// Franking key (`kf`) length.
const int frankKeyBytes = 32;

/// Commitment (`frank_commit`) length.
const int frankCommitBytes = 32;

/// L2-3: one entry of a sealed message's designation `d`: a 16-byte owner
/// key id and a 32-byte tag (`docs/crypto.md`, "Franking a sealed message").
const int frankDesignationEntryBytes = 48;
const int frankDesignationKidBytes = 16;

/// Most owner keys one designation names.
const int frankDesignationMaxEntries = 16;

const String _frankKey = 'frank';
final Uint8List _prefix = utf8.encode(',"frank":{"k":"');
final Uint8List _tail = utf8.encode('"}}');
// L2-3 designated form: `,"frank":{"k":"<44>","d":"<64 x n>"}}`, 1 <= n <= 16.
// 48 bytes are 64 base64 characters with no padding, so `d` is the standard
// base64 of the whole designation and contains no `=`, while the key's 44
// characters always end in one.
final Uint8List _designationInfix = utf8.encode('","d":"');
const int _keyBase64Length = 44;
const int _entryBase64Length = 64;
final int _suffixLength = _prefix.length + _keyBase64Length + _tail.length;

/// Whether [designation] is shaped as a designation: 1 to 16 entries of 48
/// bytes, key ids strictly ascending (sorted, no repeat). Says nothing about
/// whether any tag is right: only an owner can tell that.
bool designationWellFormed(List<int> designation) {
  if (designation.isEmpty ||
      designation.length % frankDesignationEntryBytes != 0 ||
      designation.length >
          frankDesignationMaxEntries * frankDesignationEntryBytes) {
    return false;
  }
  for (var at = frankDesignationEntryBytes;
      at < designation.length;
      at += frankDesignationEntryBytes) {
    var order = 0;
    for (var i = 0; i < frankDesignationKidBytes && order == 0; i++) {
      order = designation[at - frankDesignationEntryBytes + i] -
          designation[at + i];
    }
    if (order >= 0) return false;
  }
  return true;
}

/// A fresh franking key from the platform CSPRNG.
Uint8List generateFrankKey({Random? random}) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(frankKeyBytes, (_) => source.nextInt(256)),
  );
}

/// The wire JSON for [canonical] carrying [key]. Throws [FormatException]
/// unless [canonical] is a non-empty JSON object without a top-level `frank`
/// member and [key] is 32 bytes.
///
/// L2-3: a payload sent sealed may also carry the sender's [designation]
/// `d` (1 to 16 entries, [designationWellFormed]), only ever in the form
/// `,"frank":{"k":"<44 chars>","d":"<64 x n chars>"}}`. A sealed payload
/// with no owner key to designate is in the plain form (no `d`).
Uint8List frankWireJson(Uint8List canonical, List<int> key,
    {List<int>? designation}) {
  if (key.length != frankKeyBytes ||
      (designation != null && !designationWellFormed(designation)) ||
      canonical.length < 2 ||
      canonical.last != 0x7d /* } */ ||
      (_objectWithoutFrank(canonical)?.isEmpty ?? true)) {
    throw const FormatException('invalid franking input');
  }
  final encodedKey = ascii.encode(base64.encode(key));
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(canonical, 0, canonical.length - 1))
    ..add(_prefix)
    ..add(encodedKey);
  if (designation != null) {
    out
      ..add(_designationInfix)
      ..add(ascii.encode(base64.encode(designation)));
  }
  out.add(_tail);
  return out.takeBytes();
}

/// What the inner JSON of a decrypted payload says about franking.
sealed class FrankOutcome {
  const FrankOutcome();
}

/// No top-level `frank` member.
final class Unfranked extends FrankOutcome {
  const Unfranked();
}

/// A well-formed `frank` member: [canonical] is `P`, [key] is `kf`, and
/// [designation] the designated form's `d` (L2-3), or null for the plain
/// form. The receiver decides which form is allowed: `d` only on a message
/// that came sealed; a sealed message may be in either form.
final class Franked extends FrankOutcome {
  const Franked({required this.canonical, required this.key, this.designation});

  final Uint8List canonical;
  final Uint8List key;
  final Uint8List? designation;
}

/// A `frank` member that is not in the one fixed form, or JSON that does not
/// parse. Treat the payload as `invalid`, never as unfranked.
final class MalformedFrank extends FrankOutcome {
  const MalformedFrank();
}

/// Splits the inner JSON [json] (the bytes between the `VAP1` header and the
/// padding) into `P` and `kf`. Never throws.
FrankOutcome splitFrank(List<int> json) {
  try {
    final bytes = json is Uint8List ? json : Uint8List.fromList(json);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map) return const MalformedFrank();
    if (!decoded.containsKey(_frankKey)) return const Unfranked();
    if (!_equalAt(bytes, bytes.length - _tail.length, _tail)) {
      return const MalformedFrank();
    }
    // The designated form (L2-3): `d` is the run of base64 characters right
    // before the tail. The key ends in `=`, so in the plain form that run is
    // empty; in the designated form it is preceded by `","d":"`. An empty
    // `d` is no designated form and falls to the plain-form checks, which
    // refuse it.
    var run = 0;
    while (run < bytes.length - _tail.length &&
        _isBase64Char(bytes[bytes.length - _tail.length - 1 - run])) {
      run++;
    }
    Uint8List? designation;
    var start = bytes.length - _suffixLength;
    if (run > 0) {
      final runStart = bytes.length - _tail.length - run;
      final infixStart = runStart - _designationInfix.length;
      if (run % _entryBase64Length != 0 ||
          run > frankDesignationMaxEntries * _entryBase64Length ||
          !_equalAt(bytes, infixStart, _designationInfix)) {
        return const MalformedFrank();
      }
      final text = ascii.decode(
          Uint8List.sublistView(bytes, runStart, runStart + run),
          allowInvalid: false);
      final decodedDesignation = base64.decode(text);
      if (base64.encode(decodedDesignation) != text ||
          !designationWellFormed(decodedDesignation)) {
        return const MalformedFrank();
      }
      designation = Uint8List.fromList(decodedDesignation);
      start = infixStart - _keyBase64Length - _prefix.length;
    }
    if (start <= 1) return const MalformedFrank();
    final keyStart = start + _prefix.length;
    final keyEnd = keyStart + _keyBase64Length;
    if (!_equalAt(bytes, start, _prefix) ||
        (designation == null && !_equalAt(bytes, keyEnd, _tail))) {
      return const MalformedFrank();
    }
    final keyText = ascii.decode(
      Uint8List.sublistView(bytes, keyStart, keyEnd),
      allowInvalid: false,
    );
    final key = base64.decode(keyText);
    // One spelling only: standard alphabet, padded, canonical trailing bits.
    if (key.length != frankKeyBytes || base64.encode(key) != keyText) {
      return const MalformedFrank();
    }
    final canonical = Uint8List(start + 1)
      ..setRange(0, start, bytes)
      ..[start] = 0x7d; // }
    // P must stand alone as an object without `frank`. Then the suffix was
    // necessarily the last top-level member, and P's content is exactly the
    // wire content minus `frank`.
    if (_objectWithoutFrank(canonical) == null) return const MalformedFrank();
    return Franked(
        canonical: canonical,
        key: Uint8List.fromList(key),
        designation: designation);
  } catch (_) {
    return const MalformedFrank();
  }
}

/// Compares two commitments in time independent of where they differ.
bool frankCommitEquals(List<int> a, List<int> b) {
  if (a.length != frankCommitBytes || b.length != frankCommitBytes) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < frankCommitBytes; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

Map<Object?, Object?>? _objectWithoutFrank(Uint8List json) {
  try {
    final decoded = jsonDecode(utf8.decode(json, allowMalformed: false));
    if (decoded is! Map || decoded.containsKey(_frankKey)) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

bool _isBase64Char(int c) =>
    (c >= 0x41 && c <= 0x5a) || // A-Z
    (c >= 0x61 && c <= 0x7a) || // a-z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x2b || // +
    c == 0x2f; // /

bool _equalAt(Uint8List bytes, int offset, Uint8List expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}

/// Inbox kinds a sealed report is routed to.
const String reportInboxInstanceOwner = 'instance_owner';
const String reportInboxCommunity = 'community';

/// One moderator's own inbox in a community (C6, one sealed copy per
/// moderator): `<community id>:<account id>`, as the server names it
/// (`franking.CommunityModeratorInboxID`).
String communityModeratorInboxId(String communityId, String accountId) =>
    '$communityId:$accountId';

const String _reportAadLabel = 'veritra-c6-report-aad-v2';
const int _reportPublicKeyBytes = 32;
const int _maxReportIdBytes = 128;

/// The HPKE associated data of a sealed C6 report (`docs/crypto.md`, "Franking
/// v1", report aad; condition G4, D95): the label, then the inbox kind, the
/// inbox id (the owner's account id for the instance owners, one sealed copy
/// per owner; [communityModeratorInboxId] for a community, one per
/// moderator), the recipient's report public
/// key, the conversation id, the report id and the reporter's account id, each
/// with a big-endian u32 length in front. The report id is chosen by the
/// reporter's app and is the same in every copy of one report. The envelope id
/// is not here: it is sealed inside the report and never sent in clear. The
/// reporter seals with this aad; the recipient rebuilds it from the server's
/// report row, so a report sealed for other values does not open. Byte for
/// byte the same as `franking.ReportAAD` in the server (shared vector
/// `testing/vectors/c6-report-aad-v2.json`). Throws [FormatException] for an
/// unknown kind, a key that is not 32 bytes, or an id outside 1 to 128 bytes.
Uint8List reportAad({
  required String inboxKind,
  required String inboxId,
  required List<int> recipientKey,
  required String conversationId,
  required String reportId,
  required String reporterAccountId,
}) {
  if (inboxKind != reportInboxInstanceOwner &&
      inboxKind != reportInboxCommunity) {
    throw const FormatException('invalid report inbox kind');
  }
  if (recipientKey.length != _reportPublicKeyBytes) {
    throw const FormatException('invalid report public key');
  }
  final fields = <List<int>>[
    utf8.encode(inboxKind),
    utf8.encode(inboxId),
    recipientKey,
    utf8.encode(conversationId),
    utf8.encode(reportId),
    utf8.encode(reporterAccountId),
  ];
  for (final index in const [1, 3, 4, 5]) {
    if (fields[index].isEmpty || fields[index].length > _maxReportIdBytes) {
      throw const FormatException('invalid report id');
    }
  }
  final out = BytesBuilder(copy: false)..add(ascii.encode(_reportAadLabel));
  for (final field in fields) {
    final length = ByteData(4)..setUint32(0, field.length, Endian.big);
    out
      ..add(length.buffer.asUint8List())
      ..add(field);
  }
  return out.takeBytes();
}
