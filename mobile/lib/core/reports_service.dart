import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../crypto/franking.dart';
import '../crypto/owner_proof_pins.dart';
import '../crypto/report_body.dart';
import '../crypto/report_key_announcement.dart';
import '../crypto/report_key_pins.dart';
import '../crypto/sha256.dart';
import '../storage/local_store.dart';
import 'api_client.dart';
import 'report_key_announcer.dart' show ReportKeyAnnouncer;
import 'report_models.dart';
import 'report_seed_store.dart';

/// C6 step 4: filing a report about a received message and, for an instance
/// owner, opening and verifying the reports sent to them
/// (`docs/designs/C6-reports-franking.md`, D95). Everything is sealed or
/// opened here; the server only carries ciphertext. Nothing in this file logs
/// or stores a message, a seed or a franking key.

/// Why a report cannot be filed.
enum ReportFailure {
  /// The conversation reports to a community's moderators, but this app
  /// holds no verified role record for the community (one made before C4),
  /// so it cannot tell who moderates and seals to nobody.
  communityUnavailable,

  /// No recipient has published a report key yet: no instance owner, or no
  /// moderator the verified record names.
  noRecipients,

  /// Moderators the verified record names have published keys, but none of
  /// those keys has been announced to this device over MLS yet, so nothing
  /// can be sealed. The app's foreground pass asks for them.
  moderatorKeysPending,

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
    this.unconfirmed = const <String>[],
  });

  final String conversationId;
  final ReportInbox inbox;

  /// How the inbox's keys compare with the app's pins (owners), or which
  /// keys MLS authenticated (moderators).
  final ReportKeyCheck check;

  /// Community only: verified moderators whose listed key no MLS
  /// announcement on this device matches. They get no copy.
  final List<String> unconfirmed;

  bool get isCommunity => inbox.kind == reportInboxCommunity;

  /// Whether sending is allowed right now (every key pinned).
  bool get canSend => check.allPinned;
}

/// Who moderates a community according to the verified role record (C4) of
/// its shared group: the owner, the admins and the moderators. The server's
/// roles never decide who receives a community report.
class ReportModerators {
  const ReportModerators(this.communityId, this.accounts,
      {required this.recordGroupId});

  final String communityId;
  final Set<String> accounts;

  /// The group whose MLS state holds the record (the community's shared
  /// group). Moderator keys are trusted only from announcements in it.
  final String recordGroupId;
}

/// Who a report is sealed to: the keys, how they were judged, and the
/// verified moderators left out for lack of an MLS announcement.
class _SealTargets {
  const _SealTargets(this.recipients, this.check,
      {this.unconfirmed = const <String>[], this.recordGroupId});

  final List<ReportRecipientKey> recipients;
  final ReportKeyCheck check;
  final List<String> unconfirmed;
  final String? recordGroupId;
}

/// The state of an instance owner's own report key as this device sees it:
/// the seed it holds (if any) against the key the server lists for the owner.
enum OwnerReportKeyState {
  /// No seed here and no key published: nobody can report yet.
  none,

  /// This device holds the seed and the server lists its key.
  active,

  /// The server lists a key but this device holds no seed for it: another
  /// device holds it. Reports to it open there, not here. Making a key here
  /// replaces it (after a warning).
  heldElsewhere,

  /// This device holds a seed but the server lists a different key: another
  /// device replaced the key. This device's seed still opens the reports
  /// sealed to its old key, but new reports are sealed to the listed one.
  replacedElsewhere,

  /// This device holds a seed but the server lists none (publishing failed):
  /// publishing makes it current.
  unpublished,
}

class OwnerReportKeyStatus {
  const OwnerReportKeyStatus(this.state, {this.localKey, this.listedKey});

  final OwnerReportKeyState state;

  /// The key this device's seed makes, when it has one.
  final List<int>? localKey;

  /// The key the server lists for this owner now, when there is one. This is
  /// the code reporters see, so it is the one to show.
  final List<int>? listedKey;
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

  /// L2-3: a sealed message whose commitment matches and that names this
  /// owner's key, but whose sender's franking key could not be read from the
  /// claimed account's signed device list (unavailable, in conflict, or
  /// naming none). Not proven; fails closed.
  senderUnverified,

  /// L2-3: a sealed message that was not designated to this owner's current
  /// report key: sent in the plain form (the sender's app had no owner key
  /// pinned), to other owners only, or to a key this owner has since
  /// replaced (old proofs lapse with the key). It can be proven to no one
  /// here.
  notDesignated,

  /// L2-3: a sealed message that names this owner's key, but whose tag does
  /// not verify for the claimed sender. Not proven.
  proofFailed,
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
    this.moderatorsOf,
    this.communityId,
    this.onSeedChanged,
    this.senderFrankKey,
    Random? random,
  })  : pins = ReportKeyPins(store, api.baseUrl),
        _random = random ?? Random.secure();

  final ApiClient api;
  final String token;
  final String accountId;
  final ReportCryptoService crypto;

  /// L2-3: the franking key [accountId]'s signed L1 device list gives
  /// [deviceId] (listed now or removed since), or null. Null callback: a
  /// sealed report cannot be attributed here, and checks
  /// [ReportVerdict.senderUnverified].
  final Future<Uint8List?> Function(String accountId, String deviceId)?
      senderFrankKey;
  final LocalStore store;
  final ReportSeedStore seeds;
  final ReportKeyPins pins;
  final Random _random;

  /// Called after this device's report seed was made or published: the
  /// app announces the key again where this account moderates.
  final void Function()? onSeedChanged;

  /// The verified moderators of a community conversation, or null when the
  /// conversation is not in a community or has no verified record.
  final ReportModerators? Function(String conversationId)? moderatorsOf;

  /// Set for a moderator's inbox in this community: the key, list and open
  /// calls then use this account's moderator inbox there instead of the
  /// instance owner's.
  final String? communityId;

  /// The same service for this account's moderator inbox in [id].
  ReportsService forCommunity(String id) => ReportsService(
        api: api,
        token: token,
        accountId: accountId,
        crypto: crypto,
        store: store,
        seeds: seeds,
        moderatorsOf: moderatorsOf,
        communityId: id,
        onSeedChanged: onSeedChanged,
        senderFrankKey: senderFrankKey,
        random: _random,
      );

  /// Who a report about [conversationId] is sealed to.
  ///
  /// - Instance owners: every listed owner, judged against the pins a person
  ///   made (D95).
  /// - A community: only accounts its verified record ranks moderator or
  ///   above (never the reporter), and only at a key the account itself
  ///   announced over MLS in the record group (`report_key`). No pin and no
  ///   tap: a reporter has no way to compare a moderator's code, and the
  ///   announcement is authenticated by the moderator's own MLS leaf. A
  ///   server that lists another account, or another key, gets no copy. A
  ///   moderator the record no longer names gets none either, whatever the
  ///   server still lists.
  ///
  /// Read-only: preparing or filing a report sends nothing to the group, so
  /// no member can tell that this account is about to report. Missing
  /// announcements are asked for by the app's foreground pass, whether or
  /// not anyone reports ([ReportKeyAnnouncer.askMissing]).
  Future<_SealTargets> _sealTo(String conversationId, ReportInbox inbox) async {
    final all = _recipients(inbox);
    if (inbox.kind != reportInboxCommunity) {
      return _SealTargets(all, await pins.check(all));
    }
    final moderators = moderatorsOf?.call(conversationId);
    if (moderators == null) {
      throw const ReportFailureException(ReportFailure.communityUnavailable);
    }
    final accountOf = <String, String>{
      for (final account in moderators.accounts)
        if (account != accountId)
          communityModeratorInboxId(moderators.communityId, account): account,
    };
    final trusted = <ReportRecipientKey>[];
    final unconfirmed = <String>[];
    for (final recipient in all) {
      final account = accountOf[recipient.inboxId];
      if (account == null) continue;
      final announced = await store.loadSetting(
          reportKeyAnnouncementSetting(moderators.recordGroupId, account));
      if (announced != null && announced == base64Encode(recipient.publicKey)) {
        trusted.add(recipient);
      } else {
        unconfirmed.add(account);
      }
    }
    return _SealTargets(
      trusted,
      ReportKeyCheck([
        for (final recipient in trusted)
          ReportKeyAssessment(recipient, ReportKeyStatus.authenticated, null)
      ], const <ReportKeyPin>[]),
      unconfirmed: unconfirmed,
      recordGroupId: moderators.recordGroupId,
    );
  }

  /// Refuses an empty seal.
  void _requireTargets(_SealTargets targets) {
    if (targets.recipients.isNotEmpty) return;
    throw ReportFailureException(targets.unconfirmed.isEmpty
        ? ReportFailure.noRecipients
        : ReportFailure.moderatorKeysPending);
  }

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
    final targets = await _sealTo(conversationId, inbox);
    _requireTargets(targets);
    return ReportPlan(
      conversationId: conversationId,
      inbox: inbox,
      check: targets.check,
      unconfirmed: targets.unconfirmed,
    );
  }

  /// Pins the keys of [plan] that are not pinned yet, or changed. Call only
  /// after the person compared the fingerprints. An instance owner's key
  /// compared here also becomes that owner's sealed-message proof
  /// recipient (L2-3, `OwnerProofPins.followReportPin`); this never works
  /// the other way round.
  Future<void> pinKeys(ReportPlan plan) async {
    final proofs = OwnerProofPins(store, api.baseUrl);
    for (final assessment in plan.check.recipients) {
      if (assessment.status == ReportKeyStatus.unpinned ||
          assessment.status == ReportKeyStatus.changed) {
        await pins.pin(assessment.recipient);
        final id = assessment.recipient.inboxId;
        if (plan.inbox.kind == reportInboxInstanceOwner && !id.contains(':')) {
          await proofs.followReportPin(id);
        }
      }
    }
  }

  /// Files the report about the message [messageKey] of [conversationId].
  /// Looks the recipients up again and seals only to keys that equal their
  /// pins (owners) or their MLS announcements (moderators), so a key
  /// swapped after the person confirmed is refused.
  Future<void> file({
    required String conversationId,
    required String messageKey,
  }) async {
    final reveal = await store.loadFrankReveal(messageKey);
    if (reveal == null || reveal.conversationId != conversationId) {
      throw const ReportFailureException(ReportFailure.notReportable);
    }
    // The server cannot dedupe by message (D95), so this device remembers
    // (local schema 27) which messages this account already reported.
    if (await store.isMessageReported(api.baseUrl, accountId, messageKey)) {
      throw const ReportFailureException(ReportFailure.alreadyReported);
    }
    final inbox = await api.getReportInbox(token, conversationId);
    final targets = await _sealTo(conversationId, inbox);
    _requireTargets(targets);
    final recipients = targets.recipients;
    if (!targets.check.allPinned) {
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
    try {
      await store.markMessageReported(api.baseUrl, accountId, messageKey);
    } catch (_) {
      // The report is filed; failing to note it must not read as a failure.
    }
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

  /// Compares this device's seed with the key the server lists for this
  /// owner (see [OwnerReportKeyState]).
  Future<OwnerReportKeyStatus> keyStatus() async {
    final community = communityId;
    final listed = community == null
        ? await api.getOwnReportKey(token)
        : await api.getOwnModeratorReportKey(token, community);
    final seed = await seeds.load(api.baseUrl, accountId);
    if (seed == null) {
      return OwnerReportKeyStatus(
        listed == null
            ? OwnerReportKeyState.none
            : OwnerReportKeyState.heldElsewhere,
        listedKey: listed?.publicKey,
      );
    }
    try {
      final own = await crypto.reportPublicKey(seed);
      final state = listed == null
          ? OwnerReportKeyState.unpublished
          : _sameBytes(own, listed.publicKey)
              ? OwnerReportKeyState.active
              : OwnerReportKeyState.replacedElsewhere;
      return OwnerReportKeyStatus(state,
          localKey: own, listedKey: listed?.publicKey);
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
        final rev = await _putKey(key);
        _seedChanged();
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
      final rev = await _putKey(key);
      _seedChanged();
      return (key, rev);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  void _seedChanged() {
    try {
      onSeedChanged?.call();
    } catch (_) {
      // Announcing is the app's background work; publishing succeeded.
    }
  }

  /// Publishes [key] to this service's inbox: the instance owner's, or this
  /// account's moderator inbox in [communityId]. The seed is the account's
  /// one report seed on this device, so every inbox lists the same key.
  Future<int> _putKey(List<int> key) {
    final community = communityId;
    return community == null
        ? api.putInstanceReportKey(token, key)
        : api.putModeratorReportKey(token, community, key);
  }

  /// This owner's report copies, oldest first.
  Future<List<ReportCopyRow>> list() async {
    final rows = <ReportCopyRow>[];
    String? after;
    // The server's retention and caps bound the inbox; stop at a page limit
    // so a misbehaving server cannot make this loop forever.
    for (var page = 0; page < 40; page++) {
      final community = communityId;
      final next = community == null
          ? await api.listOwnerReports(token, afterId: after)
          : await api.listModeratorReports(token, community, afterId: after);
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
      final community = communityId;
      final ownInbox = community == null
          ? row.inboxKind == reportInboxInstanceOwner &&
              row.inboxId == accountId
          : row.inboxKind == reportInboxCommunity &&
              row.inboxId == communityModeratorInboxId(community, accountId);
      if (!_sameBytes(own, row.recipientPublicKey) || !ownInbox) {
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
    if (record.sealed || body.sealed) return _verifySealed(report, record);
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

  /// L2-3: a report about a sealed message (`docs/crypto.md`, "Franking a
  /// sealed message"). The server row names no sender, so the body does,
  /// and this owner checks it: the commitment recomputes from the revealed
  /// message for the claimed device and equals the stored one; the
  /// designation names this owner's current report key (else nothing more
  /// is asked of anyone: [ReportVerdict.notDesignated]); the claimed
  /// device's franking key comes from the claimed account's signed device
  /// list (which the server cannot forge); and the tag for this owner
  /// verifies with this owner's report seed. The tag convinces only this
  /// owner: anyone holding the seed could have made it.
  Future<ReportVerification> _verifySealed(
      OpenedReport report, ReportEnvelopeRecord record) async {
    final body = report.body!;
    final account = body.senderAccountId;
    final designation = body.designation;
    if (!record.sealed ||
        !body.sealed ||
        account == null ||
        designation == null ||
        record.envelopeId != body.envelopeId ||
        // Review low (b): the envelope the message was first stored in,
        // not a copy under another key.
        record.idempotencyKey == null ||
        record.idempotencyKey != body.actionId ||
        record.conversationId != body.conversationId ||
        record.conversationId != report.row.conversationId ||
        account == report.row.reporterAccountId ||
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
    if (!frankCommitEquals(computed, commit)) {
      return const ReportVerification(ReportVerdict.mismatch);
    }
    final seed = await seeds.load(api.baseUrl, accountId);
    if (seed == null) {
      return const ReportVerification(ReportVerdict.notDesignated);
    }
    try {
      final own = await crypto.reportPublicKey(seed);
      if (!designationNames(designation, frankDesignationKid(own))) {
        return const ReportVerification(ReportVerdict.notDesignated);
      }
      Uint8List? senderKey;
      try {
        senderKey = await senderFrankKey?.call(account, body.senderDeviceId);
      } on Object {
        senderKey = null;
      }
      if (senderKey == null) {
        return const ReportVerification(ReportVerdict.senderUnverified);
      }
      final checker = crypto;
      final verdict = checker is SealedReportCryptoService
          ? await (checker as SealedReportCryptoService)
              .frankDesignationVerdict(
              seed: seed,
              senderFrankKey: senderKey,
              conversationId: body.conversationId,
              accountId: account,
              deviceId: body.senderDeviceId,
              commit: commit,
              designation: designation,
            )
          : 0;
      if (verdict == 2) {
        return const ReportVerification(ReportVerdict.notDesignated);
      }
      if (verdict != 1) {
        return const ReportVerification(ReportVerdict.proofFailed);
      }
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
    return ReportVerification(ReportVerdict.verified,
        record: ReportEnvelopeRecord(
          envelopeId: record.envelopeId,
          conversationId: record.conversationId,
          senderAccountId: account,
          senderDeviceId: body.senderDeviceId,
          frankCommit: commit,
          createdAt: record.createdAt,
          sealed: true,
          idempotencyKey: record.idempotencyKey,
        ));
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

/// L2-3: the 16-byte id a designation files an owner key under,
/// `SHA-256("veritra-frank-dv-kid-v1" | key)[0..16]` (vector
/// testing/vectors/l2-frank-dv-v1.json).
Uint8List frankDesignationKid(List<int> ownerKey) => Uint8List.sublistView(
    sha256(<int>[...utf8.encode('veritra-frank-dv-kid-v1'), ...ownerKey]),
    0,
    frankDesignationKidBytes);

/// Whether [designation] has an entry under [kid].
bool designationNames(List<int> designation, List<int> kid) {
  if (designation.isEmpty || !designationWellFormed(designation)) return false;
  for (var at = 0; at < designation.length; at += frankDesignationEntryBytes) {
    var same = true;
    for (var i = 0; i < frankDesignationKidBytes; i++) {
      if (designation[at + i] != kid[i]) same = false;
    }
    if (same) return true;
  }
  return false;
}
