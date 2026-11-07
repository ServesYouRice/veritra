import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../crypto/crypto_service.dart';
import '../crypto/franking.dart';
import '../crypto/report_body.dart';
import '../crypto/report_key_pins.dart';
import '../storage/local_store.dart';
import 'api_client.dart';
import 'report_models.dart';
import 'report_seed_store.dart';

/// C6 step 4: filing a report about a received message and, for an instance
/// owner, opening and verifying the reports sent to them
/// (`docs/designs/C6-reports-franking.md`, D95). Everything is sealed or
/// opened here; the server only carries ciphertext. Nothing in this file logs
/// or stores a message, a seed or a franking key.

/// Why a report cannot be filed.
enum ReportFailure {
  /// The conversation reports to a community's moderators. Their inbox key
  /// waits for community roles (C4), so this build cannot file it.
  communityUnavailable,

  /// No instance owner has published a report key yet.
  noRecipients,

  /// This device kept no franking proof for the message: it is unfranked,
  /// older than the proof, deleted, hidden or expired.
  notReportable,

  /// The owners' keys differ from what this app pinned, or are not pinned.
  keysNotPinned,

  /// A report with this id was already filed from this device in this run.
  alreadyReported,
}

class ReportFailureException implements Exception {
  const ReportFailureException(this.kind);

  final ReportFailure kind;

  @override
  String toString() => 'report refused: ${kind.name}';
}

/// What the reporter's screen shows before anything is sent.
class ReportPlan {
  const ReportPlan({
    required this.conversationId,
    required this.inbox,
    required this.check,
  });

  final String conversationId;
  final ReportInbox inbox;

  /// How the inbox's keys compare with the app's pins.
  final ReportKeyCheck check;

  bool get isCommunity => inbox.kind == reportInboxCommunity;

  /// Whether sending is allowed right now (every key pinned).
  bool get canSend => !isCommunity && check.allPinned;
}

/// The state of an instance owner's own report key on this device. The
/// server has no route that tells an owner their own key, so this knows only
/// what this device holds: a seed makes the key, and publishing the same key
/// again changes nothing on the server.
enum OwnerReportKeyState {
  /// This device holds no seed. Either no key was ever made, or another
  /// device holds it; making a key here replaces whatever the server lists
  /// (reporters pin the new one, reports sealed to the old key open only
  /// where its seed is).
  none,

  /// This device holds the seed; [OwnerReportKeyStatus.publicKey] is its key.
  active,
}

class OwnerReportKeyStatus {
  const OwnerReportKeyStatus(this.state, {this.publicKey});

  final OwnerReportKeyState state;
  final List<int>? publicKey;
}

enum ReportOpenFailure {
  /// This device holds no seed.
  noSeed,

  /// Sealed to a key this device's seed does not make (an older key).
  otherKey,

  /// Did not open: altered, or sealed for other values.
  cannotOpen,

  /// Opened but the body is malformed or disagrees with the report row.
  invalidBody,
}

/// One report copy, opened if possible. [body] holds the revealed message; it
/// is kept in memory only while a screen shows it.
class OpenedReport {
  OpenedReport(this.row, {this.body, this.failure, this.text});

  final ReportCopyRow row;
  final ReportBody? body;
  final ReportOpenFailure? failure;

  /// The reported text when the payload is a text message, else null.
  final String? text;

  bool get isOpen => body != null;
}

/// What checking a report against the server's record found.
enum ReportVerdict {
  /// The commitment recomputed from the revealed message equals the one the
  /// server recorded for that envelope, from that sender, in that
  /// conversation. Only as honest as the server's row (G1).
  verified,

  /// The recorded commitment, sender or conversation differs from the report.
  mismatch,

  /// The server no longer has the envelope (message expired or deleted), so
  /// nothing can be checked.
  recordGone,

  /// The message was sent without franking: it cannot be proven.
  unfranked,
}

class ReportVerification {
  const ReportVerification(this.verdict, {this.record});

  final ReportVerdict verdict;
  final ReportEnvelopeRecord? record;
}

class ReportsService {
  ReportsService({
    required this.api,
    required this.token,
    required this.accountId,
    required this.crypto,
    required this.store,
    required this.seeds,
    Random? random,
  })  : pins = ReportKeyPins(store, api.baseUrl),
        _random = random ?? Random.secure();

  final ApiClient api;
  final String token;
  final String accountId;
  final ReportCryptoService crypto;
  final LocalStore store;
  final ReportSeedStore seeds;
  final ReportKeyPins pins;
  final Random _random;

  /// Report ids filed from this device in this run, so a double tap or a
  /// retried screen cannot file one message twice. The server dedupes by
  /// report id only; it cannot see messages (D95).
  static final Set<String> _filedMessages = <String>{};

  @visibleForTesting
  static void forgetFiledReports() => _filedMessages.clear();

  // ---- Reporter ----------------------------------------------------------

  /// The text of exactly what a report of [messageKey] would reveal: the
  /// canonical payload `P` kept at receive time, not the message as shown now
  /// (an edit rewrites what is shown, never what was committed). Null when
  /// the message has no text or no proof was kept.
  Future<String?> previewText(String messageKey) async {
    final reveal = await store.loadFrankReveal(messageKey);
    return reveal == null ? null : _textOf(reveal.payload);
  }

  /// Looks up where a report about [conversationId] goes and compares the
  /// recipients' keys with the pins.
  Future<ReportPlan> prepare(String conversationId) async {
    final inbox = await api.getReportInbox(token, conversationId);
    if (inbox.kind == reportInboxCommunity) {
      return ReportPlan(
        conversationId: conversationId,
        inbox: inbox,
        check: const ReportKeyCheck([], []),
      );
    }
    if (inbox.recipients.isEmpty) {
      throw const ReportFailureException(ReportFailure.noRecipients);
    }
    return ReportPlan(
      conversationId: conversationId,
      inbox: inbox,
      check: await pins.check(_recipients(inbox)),
    );
  }

  /// Pins the keys of [plan] that are not pinned yet, or changed. Call only
  /// after the person compared the fingerprints.
  Future<void> pinKeys(ReportPlan plan) async {
    for (final assessment in plan.check.recipients) {
      if (assessment.status != ReportKeyStatus.pinned) {
        await pins.pin(assessment.recipient);
      }
    }
  }

  /// Files the report about the message [messageKey] of [conversationId].
  /// Looks the recipients up again and seals only to keys that equal their
  /// pins, so a key swapped after the person confirmed is refused.
  Future<void> file({
    required String conversationId,
    required String messageKey,
  }) async {
    final reveal = await store.loadFrankReveal(messageKey);
    if (reveal == null || reveal.conversationId != conversationId) {
      throw const ReportFailureException(ReportFailure.notReportable);
    }
    final filedKey = '${api.baseUrl}\u0000$accountId\u0000$messageKey';
    if (_filedMessages.contains(filedKey)) {
      throw const ReportFailureException(ReportFailure.alreadyReported);
    }
    final inbox = await api.getReportInbox(token, conversationId);
    if (inbox.kind == reportInboxCommunity) {
      throw const ReportFailureException(ReportFailure.communityUnavailable);
    }
    if (inbox.recipients.isEmpty) {
      throw const ReportFailureException(ReportFailure.noRecipients);
    }
    final recipients = _recipients(inbox);
    try {
      await pins.requirePinned(recipients);
    } on ReportKeyNotPinned {
      throw const ReportFailureException(ReportFailure.keysNotPinned);
    }
    final reportId = _newReportId();
    final copies = await sealReportCopies(
      crypto: crypto,
      inboxKind: inbox.kind,
      recipients: recipients,
      conversationId: conversationId,
      reportId: reportId,
      reporterAccountId: accountId,
      body: ReportBody.fromReveal(reveal),
    );
    await api.createReport(
      token,
      conversationId: conversationId,
      reportId: reportId,
      copies: [for (final copy in copies) copy.toJson()],
    );
    _filedMessages.add(filedKey);
  }

  String _newReportId() => base64Url
      .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  List<ReportRecipientKey> _recipients(ReportInbox inbox) => [
        for (final r in inbox.recipients)
          ReportRecipientKey(
              inboxId: r.inboxId, publicKey: r.publicKey, keyRev: r.keyRev)
      ];

  // ---- Instance owner ----------------------------------------------------

  /// What this device holds (see [OwnerReportKeyState]).
  Future<OwnerReportKeyStatus> keyStatus() async {
    final seed = await seeds.load(api.baseUrl, accountId);
    if (seed == null) {
      return const OwnerReportKeyStatus(OwnerReportKeyState.none);
    }
    try {
      return OwnerReportKeyStatus(
        OwnerReportKeyState.active,
        publicKey: await crypto.reportPublicKey(seed),
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// Makes a new report key on this device and publishes it. The seed is
  /// stored first, so a failed publish leaves a seed that [publishKey] can
  /// publish again; the call never replaces a seed this device already holds
  /// unless [replace] is true (the second-device and rotation case, after a
  /// person confirmed). Returns the public key and revision.
  Future<(List<int>, int)> createKey({bool replace = false}) async {
    if (!replace && await seeds.load(api.baseUrl, accountId) != null) {
      throw StateError('a report key already exists on this device');
    }
    final previous = await seeds.load(api.baseUrl, accountId);
    final seed = await crypto.generateReportKeySeed();
    try {
      final key = await crypto.reportPublicKey(seed);
      await seeds.save(api.baseUrl, accountId, seed);
      try {
        final rev = await api.putInstanceReportKey(token, key);
        return (key, rev);
      } catch (_) {
        // Nothing was published: put the old seed back so the reports it
        // opens stay readable.
        if (previous != null) {
          await seeds.save(api.baseUrl, accountId, previous);
        } else {
          await seeds.delete(api.baseUrl, accountId);
        }
        rethrow;
      }
    } finally {
      seed.fillRange(0, seed.length, 0);
      previous?.fillRange(0, previous.length, 0);
    }
  }

  /// Publishes the key of the seed this device already holds.
  Future<(List<int>, int)> publishKey() async {
    final seed = await seeds.load(api.baseUrl, accountId);
    if (seed == null) throw StateError('no report key on this device');
    try {
      final key = await crypto.reportPublicKey(seed);
      return (key, await api.putInstanceReportKey(token, key));
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// This owner's report copies, oldest first.
  Future<List<ReportCopyRow>> list() async {
    final rows = <ReportCopyRow>[];
    String? after;
    // The server's retention and caps bound the inbox; stop at a page limit
    // so a misbehaving server cannot make this loop forever.
    for (var page = 0; page < 40; page++) {
      final next = await api.listOwnerReports(token, afterId: after);
      rows.addAll(next);
      if (next.length < 50) break;
      after = next.last.id;
    }
    return rows;
  }

  /// Opens [row] with this device's seed. Never throws for a report that
  /// cannot be opened: the failure says why.
  Future<OpenedReport> open(ReportCopyRow row) async {
    final seed = await seeds.load(api.baseUrl, accountId);
    if (seed == null) {
      return OpenedReport(row, failure: ReportOpenFailure.noSeed);
    }
    Uint8List? plaintext;
    try {
      final own = await crypto.reportPublicKey(seed);
      if (!_sameBytes(own, row.recipientPublicKey) ||
          row.inboxKind != reportInboxInstanceOwner ||
          row.inboxId != accountId) {
        return OpenedReport(row, failure: ReportOpenFailure.otherKey);
      }
      try {
        plaintext = await crypto.openReport(
          seed: seed,
          aad: reportAad(
            inboxKind: row.inboxKind,
            inboxId: row.inboxId,
            recipientKey: row.recipientPublicKey,
            conversationId: row.conversationId,
            reportId: row.reportId,
            reporterAccountId: row.reporterAccountId,
          ),
          sealed: row.sealed,
        );
      } on Object {
        return OpenedReport(row, failure: ReportOpenFailure.cannotOpen);
      }
      final ReportBody body;
      try {
        body = ReportBody.decode(plaintext);
      } on FormatException {
        return OpenedReport(row, failure: ReportOpenFailure.invalidBody);
      }
      // The body must be about the conversation the row was filed under.
      if (body.conversationId != row.conversationId) {
        return OpenedReport(row, failure: ReportOpenFailure.invalidBody);
      }
      return OpenedReport(row, body: body, text: _textOf(body.payload));
    } finally {
      seed.fillRange(0, seed.length, 0);
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  }

  /// Checks an opened report against what the server recorded for its
  /// envelope (condition G1): recomputes the commitment from the revealed
  /// message and compares it with the recorded one, from the recorded sender
  /// and conversation. This is the one request that tells the server an
  /// envelope id, and only because the owner asked to verify this report.
  Future<ReportVerification> verify(OpenedReport report) async {
    final body = report.body;
    if (body == null) throw StateError('report is not open');
    final ReportEnvelopeRecord record;
    try {
      record =
          await api.getReportEnvelope(token, report.row.id, body.envelopeId);
    } on ApiException catch (err) {
      if (err.statusCode == 404) {
        return const ReportVerification(ReportVerdict.recordGone);
      }
      rethrow;
    }
    // Context first: a record that does not describe this report proves
    // nothing, whatever else it says.
    if (record.envelopeId != body.envelopeId ||
        record.conversationId != body.conversationId ||
        record.conversationId != report.row.conversationId ||
        record.senderDeviceId != body.senderDeviceId ||
        record.senderAccountId == report.row.reporterAccountId ||
        !_payloadContextMatches(body)) {
      return const ReportVerification(ReportVerdict.mismatch);
    }
    final commit = record.frankCommit;
    if (commit == null) {
      return const ReportVerification(ReportVerdict.unfranked);
    }
    final computed = await crypto.frankCommit(
      key: Uint8List.fromList(body.frankKey),
      conversationId: body.conversationId,
      senderDeviceId: body.senderDeviceId,
      actionId: body.actionId,
      payload: Uint8List.fromList(body.payload),
    );
    return ReportVerification(
      frankCommitEquals(computed, commit)
          ? ReportVerdict.verified
          : ReportVerdict.mismatch,
      // The sender is shown only for a match.
      record: frankCommitEquals(computed, commit) ? record : null,
    );
  }

  /// Dismisses this owner's copy of a report.
  Future<void> dismiss(ReportCopyRow row) => api.deleteReport(token, row.id);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

Map<Object?, Object?>? _payloadMap(List<int> payload) {
  try {
    final decoded = jsonDecode(utf8.decode(payload, allowMalformed: false));
    return decoded is Map ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// The revealed payload names its own routing fields; they must be the ones
/// the report body claims (and the commitment covers).
bool _payloadContextMatches(ReportBody body) {
  final map = _payloadMap(body.payload);
  return map != null &&
      map['conversation_id'] == body.conversationId &&
      map['sender_device_id'] == body.senderDeviceId &&
      map['action_id'] == body.actionId;
}

String? _textOf(List<int> payload) {
  final map = _payloadMap(payload);
  if (map == null || (map['type'] != 'text' && map['type'] != 'reply')) {
    return null;
  }
  final body = map['body'];
  if (body is! Map) return null;
  final text = body['text'];
  return text is String ? text : null;
}
