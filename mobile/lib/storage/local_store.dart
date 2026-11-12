import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/server_origin.dart' show canonicalizeServerOrigin;
import '../crypto/message_format.dart' show pinLimitPerChat;
import '../sync/conversation_pause.dart';
import '../crypto/app_payload.dart' show effectiveExpiryMillis;
import '../crypto/poll.dart' show applyPollClose, applyPollVote;
import '../sync/sync_recovery.dart';
import 'backup_exclusion.dart';
import 'encrypted_database.dart';
import 'message_search.dart';
import 'history_snapshot.dart';
import 'notice_outbox.dart';
import 'invite_anchor.dart';
import 'governance_observation.dart';
export 'governance_observation.dart';
export 'invite_anchor.dart';

export 'notice_outbox.dart';
export 'encrypted_database.dart'
    show
        AcceptedCommunityInfo,
        CommunityInfoEvent,
        CommunityInfoEventKind,
        FrankReveal,
        ReportKeyPin,
        SealedKeyPin,
        SealedOwnPost,
        maxSealedTokensPerConversation,
        sealedOwnPostRetention,
        ProfileKeyEffect;
export 'profile_records.dart';
export 'device_list_records.dart';

final Map<String, Future<void>> _databaseOpenTails = <String, Future<void>>{};
final Map<String, Future<void>> _databaseWriteTails = <String, Future<void>>{};
final Map<String, RandomAccessFile> _instanceLocks =
    <String, RandomAccessFile>{};

const int maxPendingEnvelopes = 100;

class OutboxFullException implements Exception {
  const OutboxFullException();

  @override
  String toString() =>
      'The encrypted message queue is full. Send or discard a pending message first.';
}

/// Why the encrypted local database could not be opened (card I39).
enum LocalStoreFailureKind {
  /// Another window holds this profile.
  profileLocked,

  /// Secure storage could not be read (for example, the device is locked or
  /// the keystore refused). Retrying later may work.
  keyUnavailable,

  /// The database exists but its key is gone.
  keyMissing,

  /// The stored key is not a well-formed key.
  keyMalformed,

  /// The key did not open the database: it is the wrong key, or the file
  /// is damaged.
  keyRejected,

  /// Writing a new key could not be confirmed.
  keyWriteFailed,

  /// The key opened the database, but upgrading it to this app version
  /// failed because the device is full or could not write (SQLite reported
  /// `SQLITE_FULL` or `SQLITE_IOERR`). The upgrade rolled back; the database
  /// and its key are as they were, and a retry after freeing space runs it
  /// again.
  upgradeStorageFull,

  /// The key opened the database, but upgrading or opening it for this app
  /// version failed for another reason, for example a damaged page or a step
  /// that cannot complete, such as moving a corrupt legacy secure-storage
  /// record into the database or a move that did not check out. The upgrade
  /// rolled back and nothing was changed; a legacy record is kept. A reset
  /// discards that record along with the database.
  /// A retry runs it again; if that keeps failing, only the confirmed
  /// [LocalStore.quarantineUnreadableDatabase] moves the database aside.
  upgradeFailed,

  /// This build's SQLite lacks the encryption cipher or FTS5 (the search
  /// index). The database and key are fine and are not touched; neither a
  /// retry nor a reset can help, only a build with the feature.
  sqliteFeatureMissing,
}

/// The local database stays closed and untouched. Nothing is reset without
/// an explicit, confirmed [LocalStore.quarantineUnreadableDatabase].
class LocalStoreUnavailableException implements Exception {
  const LocalStoreUnavailableException(this.kind);

  final LocalStoreFailureKind kind;

  /// Only these may succeed on a plain retry.
  bool get retryable =>
      kind == LocalStoreFailureKind.profileLocked ||
      kind == LocalStoreFailureKind.keyUnavailable ||
      kind == LocalStoreFailureKind.keyWriteFailed ||
      kind == LocalStoreFailureKind.upgradeStorageFull ||
      kind == LocalStoreFailureKind.upgradeFailed;

  @override
  String toString() => 'LocalStoreUnavailableException(${kind.name})';
}

Future<T> _serializeDatabaseWrite<T>(
  String path,
  Future<T> Function() action,
) async {
  final previous = _databaseWriteTails[path] ?? Future<void>.value();
  final release = Completer<void>();
  final current = previous.then((_) => release.future);
  _databaseWriteTails[path] = current;
  await previous;
  try {
    return await action();
  } finally {
    release.complete();
    if (identical(_databaseWriteTails[path], current)) {
      _databaseWriteTails.remove(path);
    }
  }
}

class CachedSnapshot {
  const CachedSnapshot({
    required this.cursor,
    required this.conversations,
    required this.messagesByConversation,
  });

  final int cursor;
  final List<Conversation> conversations;
  final Map<String, List<ReceivedMessageEnvelope>> messagesByConversation;
}

class StoredCryptoState {
  StoredCryptoState({
    required this.counter,
    required this.stateKey,
    required this.sealedState,
    this.changes = const <CryptoRecordChange>[],
  });

  final int counter;
  final List<int> stateKey;

  /// The root (format 4) or, before migration, the whole format 2/3 state.
  final List<int> sealedState;

  /// The record writes and deletes that go with [sealedState] (D70). They
  /// are applied in the same transaction as the root, never on their own.
  /// A loaded state carries none: the records are read separately.
  final List<CryptoRecordChange> changes;
}

/// Record kinds of the sealed MLS state (D70): 1 the device record, 2 one
/// group, 3 one key package. Kind 0 is the root, kept in the singleton.
const int cryptoRecordKindDevice = 1;
const int cryptoRecordKindGroup = 2;
const int cryptoRecordKindKeyPackage = 3;

/// The largest sealed record the native library writes or reads: a 32 MiB
/// group plus the record overhead (D70 caps).
const int maxSealedCryptoRecordBytes = 32 * 1024 * 1024 + 4096;
const int _maxCryptoRecordIdBytes = 255;

/// One change to a sealed MLS record: an upsert of [sealed], or a delete
/// when [sealed] is null.
class CryptoRecordChange {
  const CryptoRecordChange({
    required this.kind,
    required this.recordId,
    required this.generation,
    required this.sealed,
  });

  final int kind;
  final List<int> recordId;
  final int generation;
  final List<int>? sealed;
}

/// One sealed MLS record of the per-record state (D70, format 4), as the
/// root in [StoredCryptoState.sealedState] lists it. Every path that drops
/// the crypto state drops them with it.
class StoredCryptoRecord {
  StoredCryptoRecord({
    required this.kind,
    required this.recordId,
    required this.generation,
    required this.sealed,
  });

  final int kind;
  final List<int> recordId;
  final int generation;
  final List<int> sealed;
}

/// A device enrollment that is not an active session yet (schema 17): a K0
/// account recovery claim, or a K2 v3 device link before promotion. It
/// holds bearer credentials ([payloadJson]) and the new identity's sealed
/// MLS state, so it stays in the encrypted local store and is never in a
/// backup or a history snapshot (D71, D73). A device holds at most one.
class PendingEnrollment {
  const PendingEnrollment({
    required this.kind,
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.payloadJson,
    this.state,
  });

  static const kindAccountRecovery = pendingEnrollmentKindAccountRecovery;
  static const kindDeviceLinkV3 = pendingEnrollmentKindDeviceLinkV3;

  final String kind;

  /// The canonical server origin the enrollment was made with.
  final String origin;
  final String accountId;
  final String deviceId;

  /// The kind's own fields, credentials included. Never log it.
  final String payloadJson;

  /// The new identity's sealed MLS state, with its records in
  /// [StoredCryptoState.changes]; null before the identity exists (a K2
  /// reservation). Frozen once stored.
  final StoredCryptoState? state;

  PendingEnrollmentRow _toRow() {
    final state = this.state;
    return PendingEnrollmentRow(
      kind: kind,
      origin: origin,
      accountId: accountId,
      deviceId: deviceId,
      payloadJson: payloadJson,
      state: state == null
          ? null
          : PendingEnrollmentState(
              counter: state.counter,
              stateKey: List<int>.from(state.stateKey),
              root: List<int>.from(state.sealedState),
              records: [
                for (final change in state.changes)
                  (
                    kind: change.kind,
                    recordId: List<int>.from(change.recordId),
                    generation: change.generation,
                    sealed: change.sealed == null
                        ? null
                        : List<int>.from(change.sealed!),
                  ),
              ],
            ),
    );
  }

  static PendingEnrollment? _fromRow(PendingEnrollmentRow? row) {
    if (row == null) return null;
    final state = row.state;
    return PendingEnrollment(
      kind: row.kind,
      origin: row.origin,
      accountId: row.accountId,
      deviceId: row.deviceId,
      payloadJson: row.payloadJson,
      state: state == null
          ? null
          : StoredCryptoState(
              counter: state.counter,
              stateKey: List<int>.from(state.stateKey),
              sealedState: List<int>.from(state.root),
              changes: [
                for (final record in state.records)
                  CryptoRecordChange(
                    kind: record.kind,
                    recordId: List<int>.from(record.recordId),
                    generation: record.generation,
                    sealed: record.sealed == null
                        ? null
                        : List<int>.from(record.sealed!),
                  ),
              ],
            ),
    );
  }

  @override
  String toString() => 'PendingEnrollment($kind)';
}

/// Makes a pending enrollment of [kind] the active identity [session]
/// (schema 18, [LocalStore.promotePendingEnrollment]). [expectedState] is the
/// frozen state the native service opened; [promotionId] names what made
/// the promotion (the K2 claim request digest, the K0 request ID) so a
/// retry is recognised.
class EnrollmentPromotion {
  const EnrollmentPromotion({
    required this.kind,
    required this.session,
    required this.promotionId,
    required this.expectedState,
    required this.promotedAt,
    this.transfer,
  });

  final String kind;
  final Session session;
  final String promotionId;
  final StoredCryptoState expectedState;
  final DateTime promotedAt;

  /// An incoming K2 transfer that starts with the identity.
  final HistoryTransferProgress? transfer;

  EnrollmentPromotionRequest _toRequest() {
    _validateCryptoState(expectedState);
    final String origin;
    try {
      origin = canonicalizeServerOrigin(session.baseUrl);
    } on FormatException {
      throw const EnrollmentPromotionRefused('invalid promotion');
    }
    final row = PendingEnrollment(
      kind: kind,
      origin: origin,
      accountId: session.accountId ?? '',
      deviceId: session.deviceId ?? '',
      payloadJson: '',
      state: expectedState,
    )._toRow();
    return EnrollmentPromotionRequest(
      kind: kind,
      origin: origin,
      accountId: row.accountId,
      deviceId: row.deviceId,
      promotionId: promotionId,
      session: _sessionJson(session),
      expectedState: row.state!,
      promotedAt: promotedAt.toUtc().millisecondsSinceEpoch,
      transfer: transfer,
    );
  }

  @override
  String toString() => 'EnrollmentPromotion($kind)';
}

/// Durable C3 removal watermark, written atomically with the MLS transition.
/// The sealed setting that holds one group's C7 state
/// (`mobile/lib/crypto/c7_group_state.dart`).
String c7GroupSetting(String conversationId) => 'c7.group.$conversationId';

String communityInfoRemovalSetting(String conversationId) =>
    'c3.removal_epoch.$conversationId';

/// C4 removal proof: [accountId]'s authenticated `member_leave` in the record
/// group [conversationId], holding the MLS epoch it was sent in. Written
/// atomically with the message's transition (through
/// [MlsStateTransition.c7Settings], the shared settings channel); cleared when the account is
/// added again or its removal merges (docs/crypto.md, "C4 app wiring").
String governanceLeaveSetting(String conversationId, String accountId) =>
    'c4.leave.$conversationId.${Uri.encodeComponent(accountId)}';

/// C4 leave proof in the commit (ABI 24): [accountId]'s signed leave
/// statement in the record group [conversationId] (`member_leave_signed`),
/// base64, from an approved leaf. A committer that removes the account puts
/// it in the commit's authenticated data, so a member that joined after the
/// leave can verify it. Written and cleared with [governanceLeaveSetting].
String governanceLeaveSignedSetting(String conversationId, String accountId) =>
    'c4.leave_signed.$conversationId.${Uri.encodeComponent(accountId)}';

/// C4 leave proof in the commit: set by this device before it sends its own
/// signed leave statement in [conversationId]. If the leave does not go
/// through, the statement must be voided by a self-update (it verifies until
/// this leaf changes); the setting is cleared when a self-update of this
/// device merges.
String governanceLeaveSignedOutSetting(String conversationId) =>
    'c4.leave_signed_out.$conversationId';

/// C4 server succession: the owner a won election (or claim) made in the
/// record group [conversationId], kept until this device has asked the
/// server to move its owner row too (docs/designs/C4-custom-roles.md,
/// "Server succession"). The value is [governanceSuccessionValue]; empty
/// when there is nothing to ask.
String governanceSuccessionSetting(String conversationId) =>
    'c4.succession.$conversationId';

/// `<rev>:<owner>`: the record revision that made [owner] owner, so an ask
/// saved before this device merged its own deciding commit is not taken for
/// a stale one.
String governanceSuccessionValue(int rev, String owner) => '$rev:$owner';

/// The parts of a [governanceSuccessionValue], or null when malformed.
({int rev, String owner})? parseGovernanceSuccessionValue(String? value) {
  if (value == null) return null;
  final split = value.indexOf(':');
  if (split <= 0 || split == value.length - 1) return null;
  final rev = int.tryParse(value.substring(0, split));
  if (rev == null || rev < 0) return null;
  return (rev: rev, owner: value.substring(split + 1));
}

class MlsStateTransition {
  const MlsStateTransition({
    required this.messageId,
    required this.conversationId,
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.cursor,
    this.upsertedEnvelopes = const <ReceivedMessageEnvelope>[],
    this.deletedEnvelopeIds = const <String>[],
    this.messageEffects = const <MessageEffect>[],
    this.noticeReferences = const <LocalNoticeReference>[],
    this.frankReveals = const <FrankReveal>[],
    this.communityInfo = const <CommunityInfoEvent>[],
    this.approvalLeaves,
    this.governanceObservation,
    this.infoRemovalEpoch,
    this.c7Settings = const <String, String?>{},
    this.resolvedMlsOutboxKey,
    this.checkCanCommit,
  });

  /// C7 group state (setting name to value, null deletes), written in the
  /// same transaction as the MLS state: a crash can never apply a removal
  /// commit and lose its rekey root (docs/designs/C7-channel-history.md,
  /// "One local transaction"). Sealed settings are never in K1 or K2.
  final Map<String, String?> c7Settings;

  /// The leaf verdicts of the commit or Welcome this transition applies
  /// (L1, D94), written in the same transaction.
  final ApprovalLeafChange? approvalLeaves;

  /// C4: clocks from the accepted transition, committed atomically with it.
  final GovernanceObservationChange? governanceObservation;

  /// Authenticated remote removal epoch (C3); null for adds and updates.
  final int? infoRemovalEpoch;

  /// An MLS outbox item that this transition settles, removed with it
  /// (card I51: this device's commit, merged when its echo arrives).
  final String? resolvedMlsOutboxKey;

  final String messageId;
  final String conversationId;
  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final int cursor;
  final List<ReceivedMessageEnvelope> upsertedEnvelopes;
  final List<String> deletedEnvelopeIds;

  /// Decrypted history changes, committed with [state] (D23).
  final List<MessageEffect> messageEffects;
  final List<LocalNoticeReference> noticeReferences;

  /// What to keep so a received franked message can be reported later (C6,
  /// schema 19). A reveal is stored only for a message row that this
  /// transition leaves live; any other is dropped without failing the commit.
  final List<FrankReveal> frankReveals;

  /// C3 (schema 31): community info keys, announcements and key requests
  /// that arrived in this MLS message, kept with the state that consumed it.
  final List<CommunityInfoEvent> communityInfo;
  final void Function()? checkCanCommit;
}

class PendingMlsMessage {
  const PendingMlsMessage({
    required this.idempotencyKey,
    required this.conversationId,
    required this.kind,
    required this.payload,
    this.recipientDeviceId,
    this.revocationDeviceId,
    this.attemptCount = 0,
    this.nextAttemptAt,
    this.failureClass,
    this.terminal = false,
  });

  final String idempotencyKey;
  final String conversationId;
  final String kind;
  final String? recipientDeviceId;
  final String? revocationDeviceId;
  final List<int> payload;

  /// Delivery state (I34). A terminal item stays queued: it blocks its
  /// conversation instead of letting later MLS messages overtake it.
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? failureClass;
  final bool terminal;

  PendingMlsMessage withFailure({
    required String failureClass,
    required bool terminal,
    required DateTime? nextAttemptAt,
  }) =>
      PendingMlsMessage(
        idempotencyKey: idempotencyKey,
        conversationId: conversationId,
        kind: kind,
        payload: payload,
        recipientDeviceId: recipientDeviceId,
        revocationDeviceId: revocationDeviceId,
        attemptCount: attemptCount + 1,
        nextAttemptAt: nextAttemptAt,
        failureClass: failureClass,
        terminal: terminal,
      );
}

class OutgoingMlsStateTransition {
  const OutgoingMlsStateTransition({
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.messages,
  });

  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final List<PendingMlsMessage> messages;
}

class OutgoingApplicationStateTransition {
  const OutgoingApplicationStateTransition({
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.envelope,
    this.draftText,
    this.governanceObservation,
    this.messageEffects = const <MessageEffect>[],
    this.communityInfo = const <CommunityInfoEvent>[],
    this.sealedOwnPost,
    this.replacesSealedEntry = false,
  });

  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final MessageEnvelope envelope;
  final String? draftText;
  final GovernanceObservationChange? governanceObservation;

  /// L2-3: the digest (and identified fallback) of a message chosen to go
  /// sealed, recorded with its outbox entry.
  final SealedOwnPost? sealedOwnPost;

  /// L2-3 (M2): [envelope] is the identified re-encryption of the queued
  /// sealed message with the same idempotency key and takes that entry's
  /// place (attempts reset). Its own copy is already stored.
  final bool replacesSealedEntry;

  /// This device's own copy of what it sent, committed with [state] (D23).
  final List<MessageEffect> messageEffects;

  /// C3: this device's own info key or announcement. MLS never decrypts a
  /// device's own application message, so without this copy the sender
  /// would not hold its own key or pass its own announcement check.
  final List<CommunityInfoEvent> communityInfo;
}

class PendingEnvelopeRecord {
  const PendingEnvelopeRecord({
    required this.envelope,
    required this.attemptCount,
    required this.terminal,
    this.draftText,
    this.nextAttemptAt,
    this.failureClass,
  });
  final MessageEnvelope envelope;
  final int attemptCount;
  final bool terminal;
  final DateTime? nextAttemptAt;
  final String? failureClass;
  final String? draftText;
}

class SyncEventCommit {
  const SyncEventCommit({
    required this.eventKey,
    required this.conversationId,
    required this.expectedCursor,
    required this.cursor,
    this.envelope,
    this.ownMessageKey,
    this.allowOwnPinEffect = false,
    this.checkCanCommit,
  });

  final String eventKey;
  final String conversationId;
  final int expectedCursor;
  final int cursor;
  final ReceivedMessageEnvelope? envelope;

  /// Set when [envelope] is the server echo of a message this device sent:
  /// the local history record with this key is linked to the envelope.
  final String? ownMessageKey;

  /// Current cached authority rechecked at echo processing time (W7).
  final bool allowOwnPinEffect;
  final void Function()? checkCanCommit;
}

class LocalSyncLease {
  const LocalSyncLease({
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.generation,
  });

  final String origin;
  final String accountId;
  final String deviceId;
  final int generation;

  String get key => '$origin\u0000$accountId\u0000$deviceId\u0000$generation';
}

/// An unsent composer draft read back from the local database (W6).
class StoredDraft {
  const StoredDraft({required this.text, this.replyTo});

  final String text;

  /// The local key of the message being replied to.
  final String? replyTo;
}

abstract class LocalStore {
  Future<void> saveSession(Session session);
  Future<Session?> loadSession();
  Future<void> saveSyncCursor(int eventId);
  Future<int> loadSyncCursor();
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  );
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  );
  Future<CachedSnapshot?> loadSnapshot();
  Future<void> enqueueEnvelope(MessageEnvelope envelope, {String? draftText});
  Future<bool> hasOutboxCapacity();
  Future<List<MessageEnvelope>> pendingEnvelopes();
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords();
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  });
  Future<void> removePendingEnvelope(String idempotencyKey);
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor);
  Future<void> commitMlsTransition(MlsStateTransition transition);

  /// Device-local C4 waits. Missing observations start both waits afresh.
  Future<GovernanceObservations?> loadGovernanceObservations(String groupId);
  Future<void> commitSyncEvent(SyncEventCommit commit);

  /// C6 (schema 19): the franking key and exact payload bytes kept with the
  /// received message [messageKey], or null when none were kept (an unfranked
  /// message, one received before schema 19, or one that was deleted, hidden
  /// or expired since). Only a reporting flow reads this.
  Future<FrankReveal?> loadFrankReveal(String messageKey);

  /// C3 (schema 31): what arrived over MLS for one community info subject,
  /// oldest first, bounded per subject.
  Future<List<CommunityInfoEvent>> loadCommunityInfoEvents(
      CommunityInfoEventKind kind, String subjectKind, String subjectId);

  /// Keeps events this device made itself (its own new keys), outside any
  /// MLS commit, under the same bounds as received ones.
  Future<void> recordOwnCommunityInfoEvents(List<CommunityInfoEvent> events);

  /// The record this device last accepted for a subject, or null.
  Future<AcceptedCommunityInfo?> loadAcceptedCommunityInfo(
      String subjectKind, String subjectId);

  /// Keeps an accepted record; a lower revision never replaces a higher one.
  Future<void> saveAcceptedCommunityInfo(AcceptedCommunityInfo info);

  /// The report keys of [origin]'s instance owners that this app pinned (D95).
  Future<List<ReportKeyPin>> loadReportKeyPins(String origin);
  Future<ReportKeyPin?> loadReportKeyPin(String origin, String ownerAccountId);

  /// Pins a key, replacing the owner's earlier pin for the origin. Only a
  /// person's confirmation calls this; a key the server changed is never
  /// pinned silently.
  Future<void> saveReportKeyPin(ReportKeyPin pin);
  Future<void> deleteReportKeyPin(String origin, String ownerAccountId);

  /// L2-3 (schema 43): unspent sealed sender tokens. Bearer credentials,
  /// kept only in the local store; see [SealedToken].
  Future<int> saveSealedTokens(List<SealedToken> tokens);

  /// Takes one token out of the store (the older day first), or null.
  Future<SealedToken?> takeSealedToken(String conversationId,
      {required String keyId, required int epoch});
  Future<int> countSealedTokens(String conversationId,
      {required String keyId, required int epoch});

  /// See [SealedSenderSql.dropSealedTokens].
  Future<void> dropSealedTokens(
      {int? minEpoch, String? keyId, String? conversationId});
  Future<SealedKeyPin?> loadSealedKeyPin(String origin);
  Future<void> saveSealedKeyPin(SealedKeyPin pin);

  /// Replaces the queued envelope with the same idempotency key (a sealed
  /// retry under a new token), keeping its attempts. Returns whether it was
  /// still queued.
  Future<bool> rewriteQueuedEnvelope(MessageEnvelope envelope);

  /// L2-3: the SHA-256 of the ciphertext this device encrypted to go sealed
  /// under ([conversationId], [idempotencyKey]), or null. How the device
  /// recognises the echo of its own sealed post.
  Future<List<int>?> loadSealedOwnPostDigest(
      String conversationId, String idempotencyKey);

  /// L2-3 (M2): the payload kept to encrypt a queued sealed message again
  /// identified, or null once it left the outbox.
  Future<String?> loadSealedOwnPostFallback(
      String conversationId, String idempotencyKey);

  /// C6 (schema 27): whether [accountId] already reported [messageKey] on
  /// [origin] from this device, and the note that it did. Ids only.
  Future<bool> isMessageReported(
      String origin, String accountId, String messageKey);
  Future<void> markMessageReported(
      String origin, String accountId, String messageKey);

  // L1 approved-device lists (schema 26, D94). Never in a backup.
  Future<DeviceListPin?> loadDeviceListPin(String accountId);

  /// Writes [pin] only while the stored pin is at [expectedVersion] (null:
  /// none) and not in conflict. Returns whether it was written.
  Future<bool> saveDeviceListPin(DeviceListPin pin,
      {required int? expectedVersion});
  Future<void> touchDeviceListPin(String accountId, int checkedAt);
  Future<void> saveDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  });
  Future<List<ApprovalLeaf>> loadApprovalLeaves(String conversationId);
  Future<void> saveApprovalLeaves(ApprovalLeafChange change);
  Future<List<String>> loadHeldConversations();

  // W11 profiles (schema 34). Keys and names never go into a log, a history
  // snapshot or a K2 transfer.
  Future<List<StoredProfileKey>> loadProfileKeys(String kind, String subjectId);

  /// Keeps [key] like a received one: at most [profileKeysPerSubject] per
  /// subject, the key that opens the cached record never evicted.
  Future<void> saveProfileKey(ProfileKeyEffect key);

  /// Every key held for subjects of [kind], at most four per subject.
  Future<List<StoredProfileKey>> loadAllProfileKeys(String kind);
  Future<void> deleteProfileKey(String kind, String subjectId, String keyId);
  Future<StoredProfile?> loadProfile(String kind, String subjectId);
  Future<List<StoredProfile>> loadProfiles(String kind);

  /// Writes an accepted record unless it is below the stored revision.
  Future<bool> saveProfile(StoredProfile profile);

  /// Deletes a subject's cached profile and all its keys.
  Future<void> deleteProfileSubject(String kind, String subjectId);
  Future<String?> loadProfileState(String name);

  /// Null deletes [name].
  Future<void> saveProfileState(String name, String? value);
  Future<Map<String, String>> loadProfileStatePrefix(String prefix);

  /// The durable recovery record (card I33), or null when sync may run.
  /// Pass null to clear it. It survives restarts so a failing event is not
  /// retried in a loop, and it is removed with the device identity.
  Future<void> saveSyncRecovery(SyncRecovery? recovery);
  Future<SyncRecovery?> loadSyncRecovery();

  /// The paused conversations (C1 prerequisite 1), by conversation id.
  /// A conversation's MLS failure pauses it alone: the global cursor moves
  /// past its later crypto events without applying them, and an explicit
  /// replay applies them in order. Removed with the device identity.
  Future<List<ConversationPause>> loadConversationPauses();
  Future<ConversationPause?> loadConversationPause(String conversationId);

  /// Records the failure of [conversationId] at [failedEventId]. A new pause
  /// resumes after the event just below it. Throws
  /// [ConversationPauseLimitReached] when [maxConversationPauses] are held.
  Future<ConversationPause> pauseConversation({
    required String conversationId,
    required int failedEventId,
    required SyncFailureKind kind,
    String? failedEventType,
    String? failedRef,
    void Function()? checkCanCommit,
  });

  /// Moves the global cursor past [eventId], an event of a paused
  /// conversation, without applying it. Throws unless the conversation is
  /// paused in the same step and the cursor is [expectedCursor].
  Future<void> skipPausedConversationEvent({
    required String conversationId,
    required int eventId,
    required int expectedCursor,
    void Function()? checkCanCommit,
  });

  /// Removes a conversation's pause (the replay finished, or the
  /// conversation was left). With [generation], only that failure's.
  Future<bool> clearConversationPause(String conversationId,
      {int? generation, void Function()? checkCanCommit});

  /// L2-3: after a sync pass that opened a sealed message, moves the
  /// write-ahead log into the database and truncates it, so the MLS state
  /// from before the message (which could open its ciphertext again) does
  /// not linger in old log frames (`secure_delete` clears freed pages of
  /// the database file, not the log). Best effort: a busy database keeps
  /// the log until the next pass. Returns whether the log was emptied.
  Future<bool> checkpointSealedResidue();

  /// When this device last made an encrypted backup (card I45).

  /// Group invite commitments, excluded from backups and identity changes.
  Future<void> saveInviteAnchor(InviteAnchor anchor);
  Future<InviteAnchor?> loadInviteAnchor(String conversationId);

  /// Small local settings (the encrypted `local_metadata` key-value table).
  Future<String?> loadSetting(String name);
  Future<void> saveSetting(String name, String value);
  Future<void> acquireSyncLease(LocalSyncLease lease);
  Future<void> releaseSyncLease(LocalSyncLease lease);
  Future<bool> hasProcessedMlsMessage(String messageId);

  /// Whether the MLS control message with server ID [mlsMessageId] has been
  /// applied, whatever sync event carried it.
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId);
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition);

  /// Pending MLS control messages in the order they must be delivered.
  Future<List<PendingMlsMessage>> pendingMlsMessages();
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  });
  Future<void> removePendingMlsMessage(String idempotencyKey);
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition);

  /// Stores a local MLS state change. [resolvedMlsOutboxKey] names an MLS
  /// outbox item settled by the same change (a commit bundle the server
  /// accepted or refused, card I51); it is removed atomically.
  /// [infoRemoval] records an authenticated own removal in that transaction,
  /// so revocation coordinators also owe C3 key rotation after a restart.
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
    GovernanceObservationChange? governanceObservation,
    ({String conversationId, int epoch})? infoRemoval,
    Map<String, String?> c7Settings = const <String, String?>{},
  });
  Future<StoredCryptoState?> loadCryptoState();

  /// The device's pending enrollment, or null. Kept by sign-out with a kept
  /// device, an identity change and a backup restore (as schema 16 kept the
  /// K0 claim's setting); dropped by [clear].
  Future<PendingEnrollment?> loadPendingEnrollment();

  /// Stores [enrollment]. Throws [PendingEnrollmentConflict] while another
  /// one (kind, origin, account or device) is pending, or when it would
  /// change a stored MLS state; one without a state keeps the stored state.
  Future<void> savePendingEnrollment(PendingEnrollment enrollment);

  /// Deletes the pending enrollment if it is of [kind] (and [deviceId],
  /// when given). Returns whether one was deleted.
  Future<bool> deletePendingEnrollment(
      {required String kind, String? deviceId});

  /// Makes the pending enrollment the active identity in one step (schema
  /// 18): session, its frozen MLS state at counter 1, cursor 0, a promotion
  /// ledger row and an optional incoming history transfer; the pending
  /// enrollment goes. A restored account's history stays.
  ///
  /// The ledger, not an empty MLS state, decides whether an identity was
  /// promoted (review finding 4): a retry of the same promotion answers
  /// [EnrollmentPromotionOutcome.alreadyPromoted] without touching the
  /// active state; any other promotion of a ledgered identity, a pending
  /// row that differs, another signed-in session, or a stored MLS state of
  /// the pending identity throws [EnrollmentPromotionRefused] and changes
  /// nothing. A signed-out identity of another device (a sign-out that kept
  /// the device) is replaced, its local state dropped as [saveSession] drops
  /// it on an identity change.
  ///
  /// The ledger is kept by sign-out, a cached clear, an identity change and
  /// a backup restore; only [clear] drops it (with the pending enrollment).
  /// While it names an identity, [loadPendingEnrollment] drops that
  /// identity's pending row and [savePendingEnrollment] refuses one.
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
      EnrollmentPromotion promotion);

  /// Whether this database ever promoted [accountId]/[deviceId] (on any
  /// server origin).
  Future<bool> isEnrollmentPromoted(
      {required String accountId, required String deviceId});

  /// K2 history transfer progress (schema 18), keyed by canonical origin and
  /// link. Rows exist only for the active identity and go wherever its MLS
  /// state goes (an identity change, a backup restore, [clear]); never in a
  /// backup or a history snapshot.
  Future<HistoryTransferProgress?> loadHistoryTransfer(
      String origin, String linkId);
  Future<List<HistoryTransferProgress>> loadHistoryTransfers();

  /// Stores [transfer] under [mergeHistoryTransfer]'s rules. Throws
  /// [HistoryTransferConflict] for another identity or a changed frozen
  /// field, [FormatException] for an invalid row.
  Future<void> saveHistoryTransfer(HistoryTransferProgress transfer);

  /// Stores a native transfer mutation ([state], under
  /// [commitLocalMlsState]'s expected-counter rules; the cursor stays) and
  /// [transfer] together: neither half is ever stored alone.
  Future<void> commitHistoryTransferState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    required HistoryTransferProgress transfer,
  });

  /// Deletes the transfer; returns whether one was deleted.
  Future<bool> deleteHistoryTransfer(String origin, String linkId);

  /// The sealed MLS records (D70), ordered by kind, then id. Cleared with
  /// the crypto state.
  Future<List<StoredCryptoRecord>> loadCryptoRecords();

  /// The crypto state and its records, read together so a restore never
  /// mixes two states (D70).
  Future<({StoredCryptoState? state, List<StoredCryptoRecord> records})>
      loadCryptoSnapshot();

  /// The one-way format 2/3 to format 4 migration (D70 section 5): replaces
  /// the stored state only if it is still [expectedSealedState] at
  /// [expectedCounter], drops any records left beside it, and writes
  /// [state] (one counter on, every record in [StoredCryptoState.changes])
  /// in one transaction. The sync cursor does not move.
  Future<void> commitCryptoMigration({
    required int expectedCounter,
    required List<int> expectedSealedState,
    required StoredCryptoState state,
    void Function()? checkCanCommit,
  });

  /// The K2 history snapshot. [omitDisappearing] (K1 backups) leaves out
  /// every message with an expiry, whether it has expired yet or not.
  Future<List<int>> exportHistorySnapshot({bool omitDisappearing = false});
  Future<void> importHistorySnapshot(
      List<int> encoded, HistoryImportContext context);
  Future<HistoryNamespace> loadHistoryNamespace();
  Future<List<LocalNoticeReference>> pendingNoticeReferences(
      LocalNoticeOwner owner,
      {int limit = localNoticeBatchLimit,
      int? now,
      void Function()? checkCanCommit});
  Future<LocalNoticeDecision?> pendingNoticeDecision(LocalNoticeOwner owner,
      {int? now, void Function()? checkCanCommit});
  Future<LocalNoticeDecision?> freezeNoticeDecision(
      LocalNoticeOwner owner, Iterable<String> referenceIds,
      {int? now, void Function()? checkCanCommit});
  Future<void> suppressNoticeReferences(
      LocalNoticeOwner owner, Iterable<String> referenceIds,
      {int? now, void Function()? checkCanCommit});
  Future<void> suppressNoticesThrough(LocalNoticeOwner owner, int eventId,
      {int? now, void Function()? checkCanCommit});
  Future<void> finishNoticeDecision(
      LocalNoticeOwner owner, String decisionId, LocalNoticeOutcome outcome,
      {int? now, void Function()? checkCanCommit});

  Future<void> savePeerVerification(
      String conversationId, String peerAccountId, List<int> transcriptHash);
  Future<List<int>?> loadPeerVerification(
      String conversationId, String peerAccountId);

  /// Decrypted history for one conversation, oldest first (D23).
  Future<List<LocalMessage>> loadMessages(String conversationId);
  Future<List<LocalMessageReaction>> loadReactions(String conversationId);
  Future<List<LocalPin>> loadPins(String conversationId);
  Future<Set<String>> loadStarred();
  Future<void> setStarred(String key, bool starred);
  Future<void> hideMessage(String conversationId, String key);
  Future<List<LocalConversationPref>> loadConversationPrefs();
  Future<void> saveConversationPref(LocalConversationPref pref);
  Future<void> discardPendingPin(String actionKey);

  /// Drops what the server can send again. [keepDrafts] is set only when the
  /// session expired (the person signs in again to the same drafts); sign-out
  /// and relinking leave it unset and delete them. The sync cursor stays with
  /// the MLS state it was committed with; only a new identity or [clear]
  /// resets it.
  Future<void> clearCachedState(
      {bool preserveOutbox = false, bool keepDrafts = false});
  Future<void> clear();

  /// Message text this device holds that contains every word of [query],
  /// newest first (W10). Answered from the encrypted local database; nothing
  /// about the query reaches the server.
  Future<List<MessageSearchHit>> searchMessages(String query, {int limit = 50});

  /// Unsent composer drafts by conversation. They are message text before
  /// encryption: kept only in the encrypted database, never in a backup, and
  /// wiped with the rest of the data (W6).
  Future<Map<String, StoredDraft>> loadDrafts();
  Future<void> saveDraft(String conversationId, String text, {String? replyTo});
  Future<void> deleteDraft(String conversationId);

  /// This device's copy of conversation mutes: the end of each mute, or null
  /// for one without an end. Mutes that have ended are not returned (W6).
  Future<Map<String, DateTime?>> loadConversationMutes();
  Future<void> saveConversationMute(String conversationId,
      {required bool muted, DateTime? until});

  /// Deletes every message, reaction and cached envelope whose server expiry
  /// has passed (W2) and returns the conversations that lost a row.
  Future<Set<String>> purgeExpiredMessages({DateTime? now});

  /// When the next stored message expires, if any does.
  Future<DateTime?> nextMessageExpiry();

  /// The confirmed destructive reset for a database that cannot be opened
  /// (I39). The unreadable database is moved aside with its key, never
  /// deleted, and the next open starts a new, empty identity.
  Future<void> quarantineUnreadableDatabase({required bool confirmed});
}

class MemoryLocalStore implements LocalStore {
  HistoryNamespace _historyNamespace = HistoryNamespace();
  Session? _session;
  int _syncCursor = 0;
  CachedSnapshot? _snapshot;
  final List<MessageEnvelope> _outbox = <MessageEnvelope>[];
  final Map<String, PendingEnvelopeRecord> _outboxRecords =
      <String, PendingEnvelopeRecord>{};
  StoredCryptoState? _cryptoState;

  /// Sealed MLS records (D70) by `kind:hex(recordId)`. Dropped wherever
  /// [_cryptoState] is.
  final Map<String, StoredCryptoRecord> _cryptoRecords =
      <String, StoredCryptoRecord>{};
  final Set<String> _processedMlsMessages = <String>{};
  final Map<String, PendingMlsMessage> _mlsOutbox =
      <String, PendingMlsMessage>{};
  final Map<String, List<int>> _peerVerifications = <String, List<int>>{};
  final Map<String, FrankReveal> _frankReveals = <String, FrankReveal>{};
  List<CommunityInfoEvent> _communityInfoEvents = const <CommunityInfoEvent>[];
  final Map<String, AcceptedCommunityInfo> _acceptedCommunityInfo =
      <String, AcceptedCommunityInfo>{};
  final Map<String, ReportKeyPin> _reportKeyPins = <String, ReportKeyPin>{};
  final Set<String> _filedReports = <String>{};
  _MemoryMessageHistory _history = _MemoryMessageHistory();
  final Map<String, LocalConversationPref> _conversationPrefs = {};
  String? _syncLeaseKey;
  SyncRecovery? _syncRecovery;
  final Map<String, ConversationPause> _pauses = <String, ConversationPause>{};
  final Map<String, StoredDraft> _drafts = <String, StoredDraft>{};
  final Map<String, DateTime?> _mutes = <String, DateTime?>{};

  LocalNoticeState _noticeState = LocalNoticeState();

  final Map<String, String> _settings = <String, String>{};

  final Map<String, GovernanceObservations> _governanceObservations = {};

  @override
  Future<GovernanceObservations?> loadGovernanceObservations(
          String groupId) async =>
      _governanceObservations[groupId];

  void _applyGovernanceObservation(GovernanceObservationChange? change) {
    if (change == null) return;
    _governanceObservations[change.groupId] =
        change.reduce(_governanceObservations[change.groupId]);
  }

  final Map<String, InviteAnchor> _inviteAnchors = {};
  @override
  Future<void> saveInviteAnchor(InviteAnchor anchor) async {
    _inviteAnchors[anchor.conversationId] = anchor;
  }

  @override
  Future<InviteAnchor?> loadInviteAnchor(String conversationId) async =>
      _inviteAnchors[conversationId];

  @override
  Future<String?> loadSetting(String name) async => _settings[name];

  @override
  Future<void> saveSetting(String name, String value) async =>
      _settings[name] = value;

  @override
  Future<void> saveSyncRecovery(SyncRecovery? recovery) async {
    _syncRecovery = recovery;
  }

  @override
  Future<SyncRecovery?> loadSyncRecovery() async => _syncRecovery;

  @override
  Future<List<ConversationPause>> loadConversationPauses() async {
    final ids = _pauses.keys.toList()..sort();
    return <ConversationPause>[for (final id in ids) _pauses[id]!];
  }

  @override
  Future<ConversationPause?> loadConversationPause(
          String conversationId) async =>
      _pauses[conversationId];

  @override
  Future<ConversationPause> pauseConversation({
    required String conversationId,
    required int failedEventId,
    required SyncFailureKind kind,
    String? failedEventType,
    String? failedRef,
    void Function()? checkCanCommit,
  }) async {
    checkCanCommit?.call();
    if (conversationId.isEmpty ||
        conversationId.length > maxPausedConversationIdLength ||
        (failedEventType?.length ?? 0) > maxPausedEventTypeLength ||
        failedEventId <= 0) {
      throw const FormatException('invalid conversation pause');
    }
    final existing = _pauses[conversationId];
    final now = DateTime.now().toUtc();
    final ConversationPause next;
    if (existing == null) {
      if (_pauses.length >= maxConversationPauses) {
        throw const ConversationPauseLimitReached();
      }
      next = ConversationPause(
        conversationId: conversationId,
        resumeAfter: failedEventId - 1,
        failedEventId: failedEventId,
        failedEventType: failedEventType,
        failedRef: failedRef,
        kind: kind,
        recordedAt: now,
      );
    } else {
      if (failedEventId <= existing.resumeAfter) {
        throw StateError('pause failure is behind the replayed events');
      }
      next = ConversationPause(
        conversationId: conversationId,
        resumeAfter: existing.resumeAfter,
        failedEventId: failedEventId,
        failedEventType: failedEventType,
        failedRef: failedRef,
        kind: kind,
        recordedAt: now,
        generation: existing.generation + 1,
      );
    }
    checkCanCommit?.call();
    _pauses[conversationId] = next;
    return next;
  }

  @override
  Future<void> skipPausedConversationEvent({
    required String conversationId,
    required int eventId,
    required int expectedCursor,
    void Function()? checkCanCommit,
  }) async {
    checkCanCommit?.call();
    final pause = _pauses[conversationId];
    if (pause == null) throw StateError('conversation is not paused');
    if (_syncCursor != expectedCursor ||
        eventId <= expectedCursor ||
        eventId <= pause.resumeAfter) {
      throw StateError('stale paused sync event skip');
    }
    checkCanCommit?.call();
    _syncCursor = eventId;
  }

  /// How often [checkpointSealedResidue] ran (tests).
  int sealedResidueCheckpoints = 0;

  @override
  Future<bool> checkpointSealedResidue() async {
    sealedResidueCheckpoints++;
    return true;
  }

  @override
  Future<bool> clearConversationPause(String conversationId,
      {int? generation, void Function()? checkCanCommit}) async {
    checkCanCommit?.call();
    final existing = _pauses[conversationId];
    if (existing == null ||
        (generation != null && existing.generation != generation)) {
      return false;
    }
    _pauses.remove(conversationId);
    return true;
  }

  @override
  Future<void> acquireSyncLease(LocalSyncLease lease) async {
    _syncLeaseKey = lease.key;
  }

  @override
  Future<void> releaseSyncLease(LocalSyncLease lease) async {
    if (_syncLeaseKey == lease.key) _syncLeaseKey = null;
  }

  @override
  Future<void> saveSession(Session session) async {
    if (_session != null && _identityChanged(_session!, session)) {
      await _clearIdentityState();
    }
    _session = session;
  }

  /// What an identity change drops (shared by [saveSession] and a promotion
  /// that replaces a signed-out identity). A pending enrollment and the
  /// promotion ledger stay.
  Future<void> _clearIdentityState() async {
    await clearCachedState();
    _syncCursor = 0;
    _cryptoState = null;
    _cryptoRecords.clear();
    _governanceObservations.clear();
    _pauses.clear();
    // Their native half goes with the MLS state; the ledger stays.
    _historyTransfers.clear();
    _processedMlsMessages.clear();
    _mlsOutbox.clear();
    _peerVerifications.clear();
    _history.clear();
    _historyNamespace = HistoryNamespace();
    _conversationPrefs.clear();
    _frankReveals.clear();
    _sealedTokens.clear();
    _sealedOwnPosts.clear();
    _communityInfoEvents = const <CommunityInfoEvent>[];
    _inviteAnchors.clear();
    _acceptedCommunityInfo.clear();
    _deviceListPins.clear();
    _profileKeys.clear();
    _profiles.clear();
    _profileState.clear();
    _deviceListConflicts.clear();
    _approvalLeaves.clear();
    _syncLeaseKey = null;
    _syncRecovery = null;
  }

  @override
  Future<Session?> loadSession() async => _session;

  @override
  Future<void> saveSyncCursor(int eventId) async {
    _syncCursor = eventId;
  }

  @override
  Future<int> loadSyncCursor() async => _syncCursor;

  @override
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  ) async {
    if (cursor < _syncCursor) return;
    final retainedCursor = cursor;
    _syncCursor = retainedCursor;
    _snapshot = CachedSnapshot(
      cursor: retainedCursor,
      conversations: List<Conversation>.from(conversations),
      messagesByConversation: messagesByConversation.map(
        (key, value) =>
            MapEntry(key, List<ReceivedMessageEnvelope>.from(value)),
      ),
    );
  }

  @override
  Future<CachedSnapshot?> loadSnapshot() async => _snapshot;

  @override
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  ) async {
    final cursor = _syncCursor;
    _snapshot = CachedSnapshot(
      cursor: cursor,
      conversations: List<Conversation>.from(conversations),
      messagesByConversation: messagesByConversation.map(
        (key, value) =>
            MapEntry(key, List<ReceivedMessageEnvelope>.from(value)),
      ),
    );
  }

  @override
  Future<void> enqueueEnvelope(MessageEnvelope envelope,
      {String? draftText}) async {
    final existing = _outboxRecords[envelope.idempotencyKey];
    if (existing != null) {
      if (existing.envelope.toJson().toString() !=
              envelope.toJson().toString() ||
          (existing.draftText != null && existing.draftText != draftText)) {
        throw StateError('outbox idempotency key conflict');
      }
      if (existing.draftText == null && draftText != null) {
        _outboxRecords[envelope.idempotencyKey] = PendingEnvelopeRecord(
          envelope: existing.envelope,
          attemptCount: existing.attemptCount,
          terminal: existing.terminal,
          nextAttemptAt: existing.nextAttemptAt,
          failureClass: existing.failureClass,
          draftText: draftText,
        );
      }
      return;
    }
    if (_outbox.length >= maxPendingEnvelopes) {
      throw const OutboxFullException();
    }
    _outbox.add(envelope);
    _outboxRecords[envelope.idempotencyKey] = PendingEnvelopeRecord(
      envelope: envelope,
      attemptCount: 0,
      terminal: false,
      draftText: draftText,
    );
  }

  @override
  Future<bool> hasOutboxCapacity() async =>
      _outbox.length < maxPendingEnvelopes;

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async =>
      List<MessageEnvelope>.from(_outbox);

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async => _outbox
      .map((item) =>
          _outboxRecords[item.idempotencyKey] ??
          PendingEnvelopeRecord(
              envelope: item, attemptCount: 0, terminal: false))
      .toList(growable: false);

  @override
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    final existing = _outboxRecords[idempotencyKey];
    if (existing == null) return;
    _outboxRecords[idempotencyKey] = PendingEnvelopeRecord(
        envelope: existing.envelope,
        attemptCount: existing.attemptCount + 1,
        terminal: terminal,
        nextAttemptAt: nextAttemptAt,
        failureClass: failureClass,
        draftText: existing.draftText);
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    _outbox.removeWhere((item) => item.idempotencyKey == idempotencyKey);
    _outboxRecords.remove(idempotencyKey);
    _clearSealedFallback(idempotencyKey);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    _validateCryptoState(state);
    if (_cryptoState != null && state.counter <= _cryptoState!.counter) {
      throw StateError('crypto state counter must increase');
    }
    _cryptoRecords.clear();
    _governanceObservations.clear();
    _pauses.clear();
    _setCryptoState(state);
    _syncCursor = syncCursor;
  }

  /// Stores [state] and applies its record changes, as one step.
  void _setCryptoState(StoredCryptoState state) {
    for (final change in state.changes) {
      final key = _cryptoRecordKey(change.kind, change.recordId);
      final sealed = change.sealed;
      if (sealed == null) {
        if (change.kind == cryptoRecordKindGroup) {
          _governanceObservations.removeWhere((groupId, _) =>
              listEquals(utf8.encode(groupId), change.recordId));
        }
        _cryptoRecords.remove(key);
      } else {
        _cryptoRecords[key] = StoredCryptoRecord(
          kind: change.kind,
          recordId: List<int>.from(change.recordId),
          generation: change.generation,
          sealed: List<int>.from(sealed),
        );
      }
    }
    _cryptoState = _copyCryptoState(state);
  }

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    transition.checkCanCommit?.call();
    if (_processedMlsMessages.contains(transition.messageId)) {
      throw StateError('MLS message was already processed');
    }
    // An event behind the global cursor is a replay of a paused
    // conversation's event (C1 P1): it leaves the cursor alone.
    final replay = transition.cursor <= _syncCursor;
    final replayed = _pauses[transition.conversationId];
    if (replay &&
        (replayed == null || transition.cursor <= replayed.resumeAfter)) {
      throw StateError('stale or incomplete MLS state transition');
    }
    if (!replay && replayed != null) {
      throw ConversationSyncPausedException(transition.conversationId);
    }
    _validateMlsTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
      allowBehindCursor: replay,
    );
    final nextMessages = <String, List<ReceivedMessageEnvelope>>{
      for (final entry in _snapshot?.messagesByConversation.entries ??
          const <MapEntry<String, List<ReceivedMessageEnvelope>>>[])
        entry.key: List<ReceivedMessageEnvelope>.from(entry.value),
    };
    final deletedIds = transition.deletedEnvelopeIds.toSet();
    for (final entry in nextMessages.entries) {
      entry.value.removeWhere((message) => deletedIds.contains(message.id));
    }
    final now = DateTime.now().toUtc();
    for (final envelope in transition.upsertedEnvelopes) {
      final messages =
          nextMessages[envelope.conversationId] ??= <ReceivedMessageEnvelope>[];
      messages.removeWhere((message) => message.id == envelope.id);
      // Arrived already expired (W2): consumed, never stored.
      if (_expired(envelope.expiresAt, now)) continue;
      messages.add(envelope);
    }
    final nextHistory = _history.copy();
    final nextNamespace = _historyNamespace.copy();
    nextHistory.apply(transition.messageEffects,
        namespace: nextNamespace, accountId: _session?.accountId);
    final nextNotices = _noticeState.copy();
    if (transition.noticeReferences.isNotEmpty) {
      final owner = transition.noticeReferences.first.owner;
      owner.requireSession(_session);
      nextNotices.prune(owner, now.millisecondsSinceEpoch);
      final refs = validLocalNoticeReferences(
          session: _session,
          references: transition.noticeReferences,
          previousKeys: _history.allMessages().map((m) => m.key).toSet(),
          rows: {for (final m in nextHistory.allMessages()) m.key: m},
          cursor: transition.cursor,
          now: now.millisecondsSinceEpoch);
      for (final ref in refs) {
        nextNotices.references.putIfAbsent(ref.id, () => ref);
      }
      nextNotices.checkCapacity(admission: true);
    }
    transition.checkCanCommit?.call();
    _noticeState = nextNotices;
    _history = nextHistory;
    _historyNamespace = nextNamespace;
    for (final effect
        in transition.messageEffects.whereType<ProfileKeyEffect>()) {
      _storeProfileKey(effect);
    }
    for (final reveal in transition.frankReveals) {
      if (reveal.isStorable && _liveMessage(reveal.messageKey) != null) {
        _frankReveals.putIfAbsent(reveal.messageKey, () => reveal);
      }
    }
    final protectedKeyIds = {
      for (final record in _acceptedCommunityInfo.values) record.keyId
    };
    for (final event in transition.communityInfo) {
      _communityInfoEvents = addCommunityInfoEvent(_communityInfoEvents, event,
          protectedKeyIds: protectedKeyIds);
    }
    if (transition.infoRemovalEpoch case final epoch?) {
      _settings[communityInfoRemovalSetting(transition.conversationId)] =
          epoch.toString();
    }
    _applyC7Settings(transition.c7Settings);
    _applyApprovalLeaves(transition.approvalLeaves);
    _applyGovernanceObservation(transition.governanceObservation);
    _setCryptoState(transition.state);
    _processedMlsMessages.add(transition.messageId);
    final resolved = transition.resolvedMlsOutboxKey;
    if (resolved != null) _mlsOutbox.remove(resolved);
    if (replay) {
      _pauses[transition.conversationId] =
          replayed!.copyWith(resumeAfter: transition.cursor);
    } else {
      _syncCursor = transition.cursor;
    }
    _snapshot = CachedSnapshot(
      cursor: _syncCursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messagesByConversation: nextMessages,
    );
  }

  /// The stored row of [key] while it is live (not deleted, hidden or
  /// expired): a reveal outlives neither.
  LocalMessage? _liveMessage(String key) {
    final row = _history._messages[key];
    if (row == null || row.deletedAt != null || row.hiddenAt != null) {
      return null;
    }
    final expiresAt = row.expiresAt;
    if (expiresAt != null &&
        expiresAt <= DateTime.now().toUtc().millisecondsSinceEpoch) {
      return null;
    }
    return row;
  }

  @override
  Future<void> recordOwnCommunityInfoEvents(
      List<CommunityInfoEvent> events) async {
    final protectedKeyIds = {
      for (final record in _acceptedCommunityInfo.values) record.keyId
    };
    for (final event in events) {
      _communityInfoEvents = addCommunityInfoEvent(_communityInfoEvents, event,
          protectedKeyIds: protectedKeyIds);
    }
  }

  @override
  Future<List<CommunityInfoEvent>> loadCommunityInfoEvents(
          CommunityInfoEventKind kind,
          String subjectKind,
          String subjectId) async =>
      _communityInfoEvents
          .where((e) =>
              e.kind == kind &&
              e.subjectKind == subjectKind &&
              e.subjectId == subjectId)
          .toList();

  @override
  Future<AcceptedCommunityInfo?> loadAcceptedCommunityInfo(
          String subjectKind, String subjectId) async =>
      _acceptedCommunityInfo['$subjectKind|$subjectId'];

  @override
  Future<void> saveAcceptedCommunityInfo(AcceptedCommunityInfo info) async {
    final key = '${info.subjectKind}|${info.subjectId}';
    final held = _acceptedCommunityInfo[key];
    if (held == null || info.revision >= held.revision) {
      _acceptedCommunityInfo[key] = info;
    }
  }

  @override
  Future<FrankReveal?> loadFrankReveal(String messageKey) async {
    final reveal = _frankReveals[messageKey];
    if (reveal == null) return null;
    if (_liveMessage(messageKey) == null) {
      _frankReveals.remove(messageKey);
      return null;
    }
    return reveal;
  }

  @override
  Future<List<ReportKeyPin>> loadReportKeyPins(String origin) async => [
        for (final pin in _reportKeyPins.values)
          if (pin.origin == origin) pin
      ]..sort((a, b) => a.ownerAccountId.compareTo(b.ownerAccountId));

  @override
  Future<ReportKeyPin?> loadReportKeyPin(
          String origin, String ownerAccountId) async =>
      _reportKeyPins['$origin\u0000$ownerAccountId'];

  @override
  Future<void> saveReportKeyPin(ReportKeyPin pin) async {
    if (pin.origin.isEmpty ||
        pin.ownerAccountId.isEmpty ||
        pin.publicKey.length != 32 ||
        pin.keyRev < 1) {
      throw const FormatException('invalid report key pin');
    }
    _reportKeyPins['${pin.origin}\u0000${pin.ownerAccountId}'] = pin;
  }

  final List<SealedToken> _sealedTokens = <SealedToken>[];
  final Map<String, SealedKeyPin> _sealedKeyPins = <String, SealedKeyPin>{};

  @override
  Future<int> saveSealedTokens(List<SealedToken> tokens) async {
    var written = 0;
    for (final token in tokens) {
      if (!token.isWellFormed) continue;
      if (_sealedTokens
              .where((t) => t.conversationId == token.conversationId)
              .length >=
          maxSealedTokensPerConversation) {
        continue;
      }
      if (_sealedTokens.any((t) => _sameNonce(t.nonce, token.nonce))) continue;
      _sealedTokens.add(token);
      written++;
    }
    return written;
  }

  static bool _sameNonce(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<SealedToken?> takeSealedToken(String conversationId,
      {required String keyId, required int epoch}) async {
    SealedToken? best;
    for (final token in _sealedTokens) {
      if (token.conversationId != conversationId ||
          token.keyId != keyId ||
          (token.epoch != epoch && token.epoch != epoch - 1)) {
        continue;
      }
      if (best == null || token.epoch < best.epoch) best = token;
    }
    if (best != null) _sealedTokens.remove(best);
    return best;
  }

  @override
  Future<int> countSealedTokens(String conversationId,
          {required String keyId, required int epoch}) async =>
      _sealedTokens
          .where((t) =>
              t.conversationId == conversationId &&
              t.keyId == keyId &&
              t.epoch == epoch)
          .length;

  @override
  Future<void> dropSealedTokens(
      {int? minEpoch, String? keyId, String? conversationId}) async {
    _sealedTokens.removeWhere((t) =>
        (minEpoch != null && t.epoch < minEpoch) ||
        (keyId != null && t.keyId != keyId) ||
        (conversationId != null && t.conversationId == conversationId));
  }

  @override
  Future<SealedKeyPin?> loadSealedKeyPin(String origin) async =>
      _sealedKeyPins[origin];

  @override
  Future<void> saveSealedKeyPin(SealedKeyPin pin) async {
    if (pin.origin.isEmpty ||
        pin.keyId.length != 32 ||
        pin.publicKey.length != 32 ||
        (pin.seenKeyId == null) != (pin.seenPublicKey == null)) {
      throw const FormatException('invalid sealed key pin');
    }
    _sealedKeyPins[pin.origin] = pin;
  }

  final Map<String, SealedOwnPost> _sealedOwnPosts = <String, SealedOwnPost>{};

  static String _ownPostKey(String conversationId, String idempotencyKey) =>
      '$conversationId\u0000$idempotencyKey';

  @override
  Future<List<int>?> loadSealedOwnPostDigest(
          String conversationId, String idempotencyKey) async =>
      _sealedOwnPosts[_ownPostKey(conversationId, idempotencyKey)]
          ?.ciphertextSha256;

  @override
  Future<String?> loadSealedOwnPostFallback(
          String conversationId, String idempotencyKey) async =>
      _sealedOwnPosts[_ownPostKey(conversationId, idempotencyKey)]
          ?.fallbackJson;

  void _clearSealedFallback(String idempotencyKey) {
    for (final entry in _sealedOwnPosts.entries.toList()) {
      if (entry.value.idempotencyKey == idempotencyKey &&
          entry.value.fallbackJson != null) {
        _sealedOwnPosts[entry.key] = SealedOwnPost(
            conversationId: entry.value.conversationId,
            idempotencyKey: idempotencyKey,
            ciphertextSha256: entry.value.ciphertextSha256);
      }
    }
  }

  @override
  Future<bool> rewriteQueuedEnvelope(MessageEnvelope envelope) async {
    final index = _outbox
        .indexWhere((item) => item.idempotencyKey == envelope.idempotencyKey);
    if (index < 0) return false;
    _outbox[index] = envelope;
    final record = _outboxRecords[envelope.idempotencyKey];
    if (record != null) {
      _outboxRecords[envelope.idempotencyKey] = PendingEnvelopeRecord(
        envelope: envelope,
        attemptCount: record.attemptCount,
        terminal: record.terminal,
        draftText: record.draftText,
        nextAttemptAt: record.nextAttemptAt,
        failureClass: record.failureClass,
      );
    }
    return true;
  }

  final Map<String, List<StoredProfileKey>> _profileKeys =
      <String, List<StoredProfileKey>>{};
  final Map<String, StoredProfile> _profiles = <String, StoredProfile>{};
  final Map<String, String> _profileState = <String, String>{};

  static String _profileId(String kind, String subjectId) =>
      '$kind\u0000$subjectId';

  void _storeProfileKey(ProfileKeyEffect effect) {
    final id = _profileId(effect.kind, effect.subjectId);
    final held = _profileKeys.putIfAbsent(id, () => <StoredProfileKey>[]);
    if (!held.any((k) => k.keyId == effect.keyId)) {
      held.add(StoredProfileKey(
          kind: effect.kind,
          subjectId: effect.subjectId,
          keyId: effect.keyId,
          key: Uint8List.fromList(effect.key),
          receivedAt: effect.receivedAt));
      final drop = profileKeysToEvict(held,
          protectedKeyId: _profiles[id]?.keyId, newestKeyId: effect.keyId);
      held.removeWhere((k) => drop.contains(k.keyId));
    }
    if (effect.raisesFloor) {
      final current = _profiles[id];
      if (current == null) {
        _profiles[id] = StoredProfile(
            kind: effect.kind,
            subjectId: effect.subjectId,
            serverVersion: 0,
            keyId: '',
            revision: 0,
            fetchedAt: 0,
            versionFloor: effect.version);
      } else if (effect.version > current.versionFloor) {
        _profiles[id] = current.copyWith(versionFloor: effect.version);
      }
    }
  }

  @override
  Future<List<StoredProfileKey>> loadProfileKeys(
          String kind, String subjectId) async =>
      List<StoredProfileKey>.of(
          _profileKeys[_profileId(kind, subjectId)] ?? const []);

  @override
  Future<void> saveProfileKey(ProfileKeyEffect key) async =>
      _storeProfileKey(key);

  @override
  Future<List<StoredProfileKey>> loadAllProfileKeys(String kind) async => [
        for (final keys in _profileKeys.values)
          for (final key in keys)
            if (key.kind == kind) key,
      ];

  @override
  Future<void> deleteProfileKey(
      String kind, String subjectId, String keyId) async {
    _profileKeys[_profileId(kind, subjectId)]
        ?.removeWhere((k) => k.keyId == keyId);
  }

  @override
  Future<StoredProfile?> loadProfile(String kind, String subjectId) async =>
      _profiles[_profileId(kind, subjectId)];

  @override
  Future<List<StoredProfile>> loadProfiles(String kind) async => [
        for (final p in _profiles.values)
          if (p.kind == kind && !p.isPlaceholder) p,
      ];

  @override
  Future<bool> saveProfile(StoredProfile profile) async {
    final id = _profileId(profile.kind, profile.subjectId);
    final current = _profiles[id];
    if (current != null && profile.revision < current.revision) return false;
    final floor = profile.versionFloor > (current?.versionFloor ?? 0)
        ? profile.versionFloor
        : (current?.versionFloor ?? 0);
    _profiles[id] = profile.copyWith(versionFloor: floor);
    return true;
  }

  @override
  Future<void> deleteProfileSubject(String kind, String subjectId) async {
    final id = _profileId(kind, subjectId);
    _profileKeys.remove(id);
    _profiles.remove(id);
  }

  @override
  Future<String?> loadProfileState(String name) async => _profileState[name];

  @override
  Future<void> saveProfileState(String name, String? value) async {
    if (value == null) {
      _profileState.remove(name);
    } else {
      _profileState[name] = value;
    }
  }

  @override
  Future<Map<String, String>> loadProfileStatePrefix(String prefix) async => {
        for (final e in _profileState.entries)
          if (e.key.startsWith(prefix)) e.key: e.value,
      };

  final Map<String, DeviceListPin> _deviceListPins = <String, DeviceListPin>{};
  final Map<String, List<int>> _deviceListConflicts = <String, List<int>>{};
  final Map<String, List<ApprovalLeaf>> _approvalLeaves =
      <String, List<ApprovalLeaf>>{};

  @override
  Future<DeviceListPin?> loadDeviceListPin(String accountId) async =>
      _deviceListPins[accountId];

  @override
  Future<bool> saveDeviceListPin(DeviceListPin pin,
      {required int? expectedVersion}) async {
    final current = _deviceListPins[pin.accountId];
    if (current?.version != expectedVersion) return false;
    if (current != null &&
        (current.conflict || pin.version < current.version)) {
      return false;
    }
    _deviceListPins[pin.accountId] = pin;
    return true;
  }

  @override
  Future<void> touchDeviceListPin(String accountId, int checkedAt) async {
    final pin = _deviceListPins[accountId];
    if (pin == null) return;
    _deviceListPins[accountId] = pin.copyWith(checkedAt: checkedAt);
  }

  @override
  Future<void> saveDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  }) async {
    final pin = _deviceListPins[accountId];
    if (pin != null) {
      _deviceListPins[accountId] = pin.copyWith(conflict: true);
    }
    _deviceListConflicts.putIfAbsent('$accountId\u0000$version',
        () => [...pinnedStatement, ...otherStatement]);
  }

  @override
  Future<List<ApprovalLeaf>> loadApprovalLeaves(String conversationId) async =>
      List<ApprovalLeaf>.unmodifiable(
          _approvalLeaves[conversationId] ?? const <ApprovalLeaf>[]);

  @override
  Future<void> saveApprovalLeaves(ApprovalLeafChange change) async =>
      _applyApprovalLeaves(change);

  void _applyC7Settings(Map<String, String?> settings) {
    for (final entry in settings.entries) {
      final value = entry.value;
      if (value == null) {
        _settings.remove(entry.key);
      } else {
        _settings[entry.key] = value;
      }
    }
  }

  void _applyApprovalLeaves(ApprovalLeafChange? change) {
    if (change == null) return;
    final rows = change.replaceAll
        ? <ApprovalLeaf>[]
        : [...?_approvalLeaves[change.conversationId]];
    for (final leaf in change.leaves) {
      if (!leaf.isStorable) continue;
      rows.removeWhere((row) => row.sameLeaf(leaf.accountId, leaf.deviceId));
      rows.add(leaf);
    }
    if (rows.isEmpty) {
      _approvalLeaves.remove(change.conversationId);
    } else {
      _approvalLeaves[change.conversationId] = rows;
    }
  }

  @override
  Future<List<String>> loadHeldConversations() async => [
        for (final entry in _approvalLeaves.entries)
          if (entry.value.any((leaf) => leaf.verdict != LeafVerdict.approved))
            entry.key,
      ]..sort();

  @override
  Future<void> deleteReportKeyPin(String origin, String ownerAccountId) async {
    _reportKeyPins.remove('$origin\u0000$ownerAccountId');
  }

  @override
  Future<bool> isMessageReported(
          String origin, String accountId, String messageKey) async =>
      _filedReports.contains('$origin\u0000$accountId\u0000$messageKey');

  @override
  Future<void> markMessageReported(
      String origin, String accountId, String messageKey) async {
    if (origin.isEmpty || accountId.isEmpty || messageKey.isEmpty) {
      throw const FormatException('invalid filed report');
    }
    _filedReports.add('$origin\u0000$accountId\u0000$messageKey');
  }

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    commit.checkCanCommit?.call();
    if (_processedMlsMessages.contains(commit.eventKey)) return;
    if (commit.expectedCursor != _syncCursor) {
      throw StateError('stale sync event commit');
    }
    // Behind the global cursor only as a replay of a paused conversation's
    // event (C1 P1).
    final replay = commit.cursor <= commit.expectedCursor;
    final replayed = _pauses[commit.conversationId];
    if (replay && (replayed == null || commit.cursor <= replayed.resumeAfter)) {
      throw StateError('stale sync event commit');
    }
    final nextMessages = <String, List<ReceivedMessageEnvelope>>{
      for (final entry in _snapshot?.messagesByConversation.entries ??
          const <MapEntry<String, List<ReceivedMessageEnvelope>>>[])
        entry.key: List<ReceivedMessageEnvelope>.from(entry.value),
    };
    final nextHistory = _history.copy();
    final nextNamespace = _historyNamespace.copy();
    final envelope = commit.envelope;
    String? settledOwnPost;
    if (envelope != null) {
      final messages =
          nextMessages[envelope.conversationId] ??= <ReceivedMessageEnvelope>[];
      messages.removeWhere((item) => item.id == envelope.id);
      if (!_expired(envelope.expiresAt, DateTime.now().toUtc())) {
        messages.add(envelope);
      }
      final ownKey = commit.ownMessageKey;
      if (ownKey != null) {
        final command = nextHistory.pendingPins[ownKey];
        final channel = envelope.cryptoMetadata is Map
            ? (envelope.cryptoMetadata as Map)['channel_id']
            : null;
        if (command != null &&
            command.conversationId == envelope.conversationId &&
            command.channelId == channel) {
          nextHistory.pendingPins.remove(ownKey);
          if (commit.allowOwnPinEffect)
            nextHistory.apply([
              PinMessageEffect(
                  conversationId: command.conversationId,
                  channelId: command.channelId,
                  targetKey: command.targetKey,
                  accountId: command.accountId,
                  at: envelope.createdAt.millisecondsSinceEpoch,
                  pinned: command.pinned,
                  durationSeconds: command.durationSeconds)
            ], namespace: nextNamespace, accountId: _session?.accountId);
        }
        nextHistory.markSent(ownKey, envelope.id,
            expiresAt: envelope.expiresAt?.toUtc().millisecondsSinceEpoch,
            conversationId: envelope.conversationId,
            channelId: channel as String?);
        if (envelope.sealed) {
          settledOwnPost =
              _ownPostKey(envelope.conversationId, envelope.idempotencyKey);
        }
      }
    }
    commit.checkCanCommit?.call();
    _history = nextHistory;
    _historyNamespace = nextNamespace;
    if (settledOwnPost != null) _sealedOwnPosts.remove(settledOwnPost);
    _processedMlsMessages.add(commit.eventKey);
    if (replay) {
      _pauses[commit.conversationId] =
          replayed!.copyWith(resumeAfter: commit.cursor);
    } else {
      _syncCursor = commit.cursor;
    }
    _snapshot = CachedSnapshot(
      cursor: _syncCursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messagesByConversation: nextMessages,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      _processedMlsMessages.contains(messageId);

  @override
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId) async =>
      _processedMlsMessages.any((marker) =>
          marker.startsWith('mls:') && marker.endsWith(':$mlsMessageId'));

  @override
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition) async {
    _validateOutgoingMlsTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
    );
    for (final message in transition.messages) {
      if (_pauses.containsKey(message.conversationId)) {
        throw ConversationSyncPausedException(message.conversationId);
      }
    }
    if (transition.messages
        .any((message) => _mlsOutbox.containsKey(message.idempotencyKey))) {
      throw StateError('duplicate MLS outbox idempotency key');
    }
    _setCryptoState(transition.state);
    for (final message in transition.messages) {
      _mlsOutbox[message.idempotencyKey] = message;
    }
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async =>
      _mlsOutbox.values.toList(growable: false);

  @override
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    final existing = _mlsOutbox[idempotencyKey];
    if (existing == null) return;
    _mlsOutbox[idempotencyKey] = existing.withFailure(
      failureClass: failureClass,
      terminal: terminal,
      nextAttemptAt: nextAttemptAt?.toUtc(),
    );
  }

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    _mlsOutbox.remove(idempotencyKey);
  }

  @override
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition) async {
    _validateOutgoingApplicationTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
    );
    if (_pauses.containsKey(transition.envelope.conversationId)) {
      throw ConversationSyncPausedException(transition.envelope.conversationId);
    }
    final key = transition.envelope.idempotencyKey;
    final existing = _outboxRecords[key];
    if (transition.replacesSealedEntry) {
      if (existing == null ||
          !existing.envelope.sealed ||
          existing.envelope.conversationId !=
              transition.envelope.conversationId) {
        throw StateError('no queued sealed entry to replace');
      }
    } else {
      if (existing != null) {
        throw StateError('outbox idempotency key conflict');
      }
      if (_outbox.length >= maxPendingEnvelopes) {
        throw const OutboxFullException();
      }
    }
    _applyHistoryEffects(transition.messageEffects);
    _applyGovernanceObservation(transition.governanceObservation);
    final protectedKeyIds = {
      for (final record in _acceptedCommunityInfo.values) record.keyId
    };
    for (final event in transition.communityInfo) {
      _communityInfoEvents = addCommunityInfoEvent(_communityInfoEvents, event,
          protectedKeyIds: protectedKeyIds);
    }
    _setCryptoState(transition.state);
    final sentText = transition.draftText;
    final draft = _drafts[transition.envelope.conversationId];
    if (sentText != null &&
        draft != null &&
        draft.text.trim() == sentText.trim()) {
      _drafts.remove(transition.envelope.conversationId);
    }
    if (transition.replacesSealedEntry) {
      final index = _outbox.indexWhere((item) => item.idempotencyKey == key);
      _outbox[index] = transition.envelope;
      _outboxRecords[key] = PendingEnvelopeRecord(
          envelope: transition.envelope,
          attemptCount: 0,
          terminal: false,
          draftText: existing!.draftText);
      // The plaintext goes. The digest stays: an earlier sealed attempt
      // still in flight could land late, and its echo is then this
      // device's own.
      _clearSealedFallback(key);
    } else {
      _outbox.add(transition.envelope);
      _outboxRecords[key] = PendingEnvelopeRecord(
          envelope: transition.envelope,
          attemptCount: 0,
          terminal: false,
          draftText: transition.draftText);
    }
    final ownPost = transition.sealedOwnPost;
    if (ownPost != null) {
      final cutoff = DateTime.now().toUtc().subtract(sealedOwnPostRetention);
      _sealedOwnPostTimes.removeWhere((name, at) {
        final stale = at.isBefore(cutoff) &&
            !_outboxRecords.containsKey(_sealedOwnPosts[name]?.idempotencyKey);
        if (stale) _sealedOwnPosts.remove(name);
        return stale;
      });
      final name = _ownPostKey(ownPost.conversationId, ownPost.idempotencyKey);
      _sealedOwnPosts[name] = ownPost;
      _sealedOwnPostTimes[name] = DateTime.now().toUtc();
    }
  }

  final Map<String, DateTime> _sealedOwnPostTimes = <String, DateTime>{};

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
    GovernanceObservationChange? governanceObservation,
    ({String conversationId, int epoch})? infoRemoval,
    Map<String, String?> c7Settings = const <String, String?>{},
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: _cryptoState?.counter ?? 0, currentCursor: _syncCursor);
    _applyGovernanceObservation(governanceObservation);
    _setCryptoState(state);
    if (infoRemoval != null) {
      _settings[communityInfoRemovalSetting(infoRemoval.conversationId)] =
          infoRemoval.epoch.toString();
    }
    _applyC7Settings(c7Settings);
    if (resolvedMlsOutboxKey != null) _mlsOutbox.remove(resolvedMlsOutboxKey);
  }

  @override
  Future<StoredCryptoState?> loadCryptoState() async =>
      _cryptoState == null ? null : _copyCryptoState(_cryptoState!);

  PendingEnrollmentRow? _pendingEnrollment;
  final List<EnrollmentPromotionRow> _promotions = <EnrollmentPromotionRow>[];
  final Map<String, HistoryTransferProgress> _historyTransfers =
      <String, HistoryTransferProgress>{};

  List<EnrollmentPromotionRow> _promotionsFor(
          String accountId, String deviceId) =>
      [
        for (final row in _promotions)
          if (row.accountId == accountId && row.deviceId == deviceId) row,
      ];

  @override
  Future<PendingEnrollment?> loadPendingEnrollment() async {
    final row = _pendingEnrollment;
    if (row != null && _promotionsFor(row.accountId, row.deviceId).isNotEmpty) {
      _pendingEnrollment = null;
      return null;
    }
    return PendingEnrollment._fromRow(row);
  }

  @override
  Future<void> savePendingEnrollment(PendingEnrollment enrollment) async {
    if (_promotionsFor(enrollment.accountId, enrollment.deviceId).isNotEmpty) {
      throw const PendingEnrollmentConflict();
    }
    _pendingEnrollment =
        mergePendingEnrollment(_pendingEnrollment, enrollment._toRow());
  }

  @override
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
      EnrollmentPromotion promotion) async {
    final request = promotion._toRequest();
    final pending = _pendingEnrollment;
    final outcome = decideEnrollmentPromotion(
      request: request,
      ledger: _promotionsFor(request.accountId, request.deviceId),
      pending: pending,
      cryptoStateStored: _cryptoState != null,
      existingSession: _session == null ? null : _sessionJson(_session!),
    );
    if (outcome == EnrollmentPromotionOutcome.alreadyPromoted) {
      if (pending != null &&
          pending.accountId == request.accountId &&
          pending.deviceId == request.deviceId) {
        _pendingEnrollment = null;
      }
      return outcome;
    }
    // Everything that can refuse runs before the first change.
    final transfer = request.transfer;
    final mergedTransfer = transfer == null
        ? null
        : mergeHistoryTransfer(
            _historyTransfers[_transferKey(transfer.origin, transfer.linkId)],
            transfer);
    final state = PendingEnrollment._fromRow(pending)!.state!;
    if (promotionReplacesSignedOutIdentity(
        request: request,
        existingSession: _session == null ? null : _sessionJson(_session!))) {
      await _clearIdentityState();
    }
    _session = promotion.session;
    _cryptoRecords.clear();
    _governanceObservations.clear();
    _pauses.clear();
    _setCryptoState(state);
    _syncCursor = 0;
    _promotions.add(EnrollmentPromotionRow(
      kind: request.kind,
      origin: request.origin,
      accountId: request.accountId,
      deviceId: request.deviceId,
      promotionId: request.promotionId,
      promotedAt: request.promotedAt,
    ));
    if (mergedTransfer != null) {
      _historyTransfers[
              _transferKey(mergedTransfer.origin, mergedTransfer.linkId)] =
          mergedTransfer;
    }
    _pendingEnrollment = null;
    return outcome;
  }

  @override
  Future<bool> isEnrollmentPromoted(
          {required String accountId, required String deviceId}) async =>
      _promotionsFor(accountId, deviceId).isNotEmpty;

  static String _transferKey(String origin, String linkId) =>
      '$origin\u0000$linkId';

  @override
  Future<HistoryTransferProgress?> loadHistoryTransfer(
          String origin, String linkId) async =>
      _historyTransfers[_transferKey(origin, linkId)];

  @override
  Future<List<HistoryTransferProgress>> loadHistoryTransfers() async {
    final values = _historyTransfers.values.toList()
      ..sort((a, b) {
        final byOrigin = a.origin.compareTo(b.origin);
        return byOrigin != 0 ? byOrigin : a.linkId.compareTo(b.linkId);
      });
    return values;
  }

  HistoryTransferProgress _mergedActiveTransfer(
      HistoryTransferProgress transfer) {
    validateHistoryTransfer(transfer);
    if (!historyTransferIsActive(
        transfer,
        _session == null ? null : _sessionJson(_session!),
        _cryptoState != null)) {
      throw const HistoryTransferConflict(
          'the transfer is not for the active identity');
    }
    return mergeHistoryTransfer(
        _historyTransfers[_transferKey(transfer.origin, transfer.linkId)],
        transfer);
  }

  @override
  Future<void> saveHistoryTransfer(HistoryTransferProgress transfer) async {
    final merged = _mergedActiveTransfer(transfer);
    _historyTransfers[_transferKey(merged.origin, merged.linkId)] = merged;
  }

  @override
  Future<void> commitHistoryTransferState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    required HistoryTransferProgress transfer,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: _cryptoState?.counter ?? 0, currentCursor: _syncCursor);
    final merged = _mergedActiveTransfer(transfer);
    _setCryptoState(state);
    _historyTransfers[_transferKey(merged.origin, merged.linkId)] = merged;
  }

  @override
  Future<bool> deleteHistoryTransfer(String origin, String linkId) async =>
      _historyTransfers.remove(_transferKey(origin, linkId)) != null;

  @override
  Future<bool> deletePendingEnrollment(
      {required String kind, String? deviceId}) async {
    final existing = _pendingEnrollment;
    if (existing == null ||
        existing.kind != kind ||
        (deviceId != null && existing.deviceId != deviceId)) {
      return false;
    }
    _pendingEnrollment = null;
    return true;
  }

  @override
  Future<List<StoredCryptoRecord>> loadCryptoRecords() async {
    final keys = _cryptoRecords.keys.toList()..sort();
    return [for (final k in keys) _copyCryptoRecord(_cryptoRecords[k]!)];
  }

  @override
  Future<({StoredCryptoState? state, List<StoredCryptoRecord> records})>
      loadCryptoSnapshot() async =>
          (state: await loadCryptoState(), records: await loadCryptoRecords());

  @override
  Future<void> commitCryptoMigration({
    required int expectedCounter,
    required List<int> expectedSealedState,
    required StoredCryptoState state,
    void Function()? checkCanCommit,
  }) async {
    checkCanCommit?.call();
    _validateCryptoMigration(state);
    final current = _cryptoState;
    if (current == null ||
        current.counter != expectedCounter ||
        state.counter != expectedCounter + 1 ||
        !_bytesEqual(current.sealedState, expectedSealedState) ||
        !_bytesEqual(current.stateKey, state.stateKey)) {
      throw StateError('stale or changed crypto state migration');
    }
    _cryptoRecords.clear();
    _governanceObservations.clear();
    _setCryptoState(state);
  }

  /// Puts records in place directly, so tests can check that every
  /// crypto-state clear drops them (D70 S2).
  @visibleForTesting
  void seedCryptoRecordsForTest(Iterable<StoredCryptoRecord> records) {
    for (final r in records) {
      _cryptoRecords[_cryptoRecordKey(r.kind, r.recordId)] =
          _copyCryptoRecord(r);
    }
  }

  void _applyHistoryEffects(List<MessageEffect> effects) {
    final next = _history.copy();
    final namespace = _historyNamespace.copy();
    next.apply(effects, namespace: namespace, accountId: _session?.accountId);
    _history = next;
    _historyNamespace = namespace;
    for (final effect in effects.whereType<ProfileKeyEffect>()) {
      _storeProfileKey(effect);
    }
  }

  Future<T> _noticeChange<T>(
      LocalNoticeOwner owner, T Function(LocalNoticeState) change,
      {int? now, void Function()? checkCanCommit}) async {
    checkCanCommit?.call();
    owner.requireSession(_session);
    final next = _noticeState.copy();
    next.prune(owner, now ?? DateTime.now().millisecondsSinceEpoch);
    final result = change(next);
    checkCanCommit?.call();
    _noticeState = next;
    return result;
  }

  @override
  Future<List<LocalNoticeReference>> pendingNoticeReferences(
          LocalNoticeOwner owner,
          {int limit = localNoticeBatchLimit,
          int? now,
          void Function()? checkCanCommit}) =>
      _noticeChange(owner, (n) => n.pending(owner, limit),
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<LocalNoticeDecision?> pendingNoticeDecision(LocalNoticeOwner owner,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeChange(owner, (n) => n.decision(owner),
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<LocalNoticeDecision?> freezeNoticeDecision(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeChange(
          owner,
          (n) => n.freeze(owner, referenceIds,
              now ?? DateTime.now().millisecondsSinceEpoch),
          now: now,
          checkCanCommit: checkCanCommit);
  @override
  Future<void> suppressNoticeReferences(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeChange(owner, (n) => n.suppress(owner, referenceIds),
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<void> suppressNoticesThrough(LocalNoticeOwner owner, int eventId,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeChange(owner, (n) {
        if (eventId < 0 || eventId > _syncCursor)
          throw StateError('notice watermark is not committed');
        n.suppressThrough(owner, eventId);
      }, now: now, checkCanCommit: checkCanCommit);
  @override
  Future<void> finishNoticeDecision(
          LocalNoticeOwner owner, String decisionId, LocalNoticeOutcome outcome,
          {int? now, void Function()? checkCanCommit}) =>
      _noticeChange(owner, (n) => n.finish(owner, decisionId, outcome),
          now: now, checkCanCommit: checkCanCommit);

  @override
  Future<HistoryNamespace> loadHistoryNamespace() async =>
      _historyNamespace.copy();

  @override
  Future<List<int>> exportHistorySnapshot(
      {bool omitDisappearing = false}) async {
    final session = _session;
    if (session == null) throw StateError('history export requires a session');
    final snapshot = captureHistory(
        session: session,
        namespace: _historyNamespace,
        conversations: _snapshot?.conversations ?? [],
        messages: _history.allMessages(),
        reactions: _history.allReactions(),
        pins: _history.pins.values.toList(),
        starred: _history.starred,
        preferences: _conversationPrefs.values.toList(),
        now: DateTime.now().millisecondsSinceEpoch,
        omitDisappearing: omitDisappearing);
    final bytes = snapshot.encode();
    _historyNamespace.counter = snapshot.counter;
    return bytes;
  }

  @override
  Future<void> importHistorySnapshot(
      List<int> encoded, HistoryImportContext context) async {
    final snapshot = HistorySnapshot.decode(encoded);
    context.checkSession(_session);
    final merge = mergeHistory(
        snapshot: snapshot,
        context: context,
        namespace: _historyNamespace,
        liveConversations: _snapshot?.conversations ?? [],
        existing: _history.allMessages(),
        existingPins: _history.pins.values.toList(),
        existingPreferences: _conversationPrefs.values.toList(),
        now: DateTime.now().millisecondsSinceEpoch);
    // The pure plan validates everything before touching this in-memory store.
    for (final m in merge.messages) {
      _history._messages[m.key] = m;
    }
    for (final r in merge.reactions) {
      _history._reactions['${r.targetKey}\u0000${r.reactorAccountId}'] = r;
    }
    for (final p in merge.pins) {
      _history.pins[p.targetKey] = p;
    }
    _history.starred.addAll(merge.starred);
    for (final p in merge.preferences) {
      _conversationPrefs[p.conversationId] = p;
    }
    _historyNamespace = merge.namespace;
  }

  @override
  Future<void> savePeerVerification(String conversationId, String peerAccountId,
      List<int> transcriptHash) async {
    _validatePeerVerification(conversationId, peerAccountId, transcriptHash);
    _peerVerifications['$conversationId\u0000$peerAccountId'] =
        List<int>.from(transcriptHash);
  }

  @override
  Future<List<int>?> loadPeerVerification(
      String conversationId, String peerAccountId) async {
    final value = _peerVerifications['$conversationId\u0000$peerAccountId'];
    return value == null ? null : List<int>.from(value);
  }

  @override
  Future<void> clearCachedState(
      {bool preserveOutbox = false, bool keepDrafts = false}) async {
    _noticeState = LocalNoticeState();
    // The cursor stays: it belongs to the MLS state, which stays too.
    _snapshot = null;
    if (!keepDrafts) _drafts.clear();
    _mutes.clear();
    if (!preserveOutbox) {
      _outbox.clear();
      _outboxRecords.clear();
    }
  }

  @override
  Future<void> clear() async {
    _noticeState = LocalNoticeState();
    _pendingEnrollment = null;
    _promotions.clear();
    _historyTransfers.clear();
    _session = null;
    _cryptoState = null;
    _cryptoRecords.clear();
    _governanceObservations.clear();
    _pauses.clear();
    _processedMlsMessages.clear();
    _mlsOutbox.clear();
    _peerVerifications.clear();
    _history.clear();
    _historyNamespace = HistoryNamespace();
    _conversationPrefs.clear();
    _frankReveals.clear();
    _sealedTokens.clear();
    _sealedOwnPosts.clear();
    _communityInfoEvents = const <CommunityInfoEvent>[];
    _inviteAnchors.clear();
    _acceptedCommunityInfo.clear();
    _deviceListPins.clear();
    _deviceListConflicts.clear();
    _approvalLeaves.clear();
    _reportKeyPins.clear();
    _filedReports.clear();
    _syncLeaseKey = null;
    _syncRecovery = null;
    await clearCachedState();
    _syncCursor = 0;
  }

  @override
  Future<void> quarantineUnreadableDatabase({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed');
    }
    await clear();
  }

  @override
  Future<List<MessageSearchHit>> searchMessages(String query,
          {int limit = 50}) async =>
      _history.search(query, limit);

  @override
  Future<Map<String, StoredDraft>> loadDrafts() async =>
      Map<String, StoredDraft>.of(_drafts);

  @override
  Future<void> saveDraft(String conversationId, String text,
      {String? replyTo}) async {
    _drafts[conversationId] = StoredDraft(text: text, replyTo: replyTo);
  }

  @override
  Future<void> deleteDraft(String conversationId) async {
    _drafts.remove(conversationId);
  }

  @override
  Future<Map<String, DateTime?>> loadConversationMutes() async {
    final now = DateTime.now().toUtc();
    _mutes.removeWhere((_, until) => until != null && !until.isAfter(now));
    return Map<String, DateTime?>.of(_mutes);
  }

  @override
  Future<void> saveConversationMute(String conversationId,
      {required bool muted, DateTime? until}) async {
    if (muted) {
      _mutes[conversationId] = until?.toUtc();
    } else {
      _mutes.remove(conversationId);
    }
  }

  static bool _expired(DateTime? expiresAt, DateTime now) =>
      expiresAt != null && !expiresAt.isAfter(now);

  @override
  Future<Set<String>> purgeExpiredMessages({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final touched = <String>{};
    final snapshot = _snapshot;
    if (snapshot != null) {
      final kept = <String, List<ReceivedMessageEnvelope>>{};
      for (final entry in snapshot.messagesByConversation.entries) {
        final live = <ReceivedMessageEnvelope>[];
        for (final envelope in entry.value) {
          if (_expired(envelope.expiresAt, at)) {
            touched.add(entry.key);
          } else {
            live.add(envelope);
          }
        }
        kept[entry.key] = live;
      }
      _snapshot = CachedSnapshot(
        cursor: snapshot.cursor,
        conversations: snapshot.conversations,
        messagesByConversation: kept,
      );
    }
    touched.addAll(_history.purgeExpired(at.millisecondsSinceEpoch));
    return touched;
  }

  @override
  Future<DateTime?> nextMessageExpiry() async {
    DateTime? next;
    for (final list in _snapshot?.messagesByConversation.values ??
        const <List<ReceivedMessageEnvelope>>[]) {
      for (final envelope in list) {
        final at = envelope.expiresAt;
        if (at != null && (next == null || at.isBefore(next))) next = at;
      }
    }
    final fromHistory = _history.nextExpiry();
    if (fromHistory != null && (next == null || fromHistory.isBefore(next))) {
      next = fromHistory;
    }
    return next;
  }

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async =>
      _history.messages(conversationId);

  @override
  Future<List<LocalPin>> loadPins(String conversationId) async {
    _history.pins.removeWhere(
        (_, p) => p.expiresAt <= DateTime.now().millisecondsSinceEpoch);
    return _history.pins.values
        .where((p) => p.conversationId == conversationId)
        .toList()
      ..sort((a, b) {
        final t = b.pinnedAt.compareTo(a.pinnedAt);
        return t != 0 ? t : b.appliedOrder.compareTo(a.appliedOrder);
      });
  }

  @override
  Future<Set<String>> loadStarred() async => _history.starred.keys.toSet();
  @override
  Future<void> setStarred(String key, bool starred) async {
    final target = _history._messages[key];
    if (target == null || target.hiddenAt != null || target.deletedAt != null)
      return;
    if (starred) {
      _history.starred[key] = DateTime.now().millisecondsSinceEpoch;
    } else {
      _history.starred.remove(key);
    }
  }

  @override
  Future<void> hideMessage(String conversationId, String key) async {
    final target = _history._messages[key];
    if (target == null || target.conversationId != conversationId) return;
    _history._messages[key] = target.copyWith(
        hiddenAt: Value(DateTime.now().millisecondsSinceEpoch),
        body: const Value(null),
        formatJson: const Value(null),
        replyTo: const Value(null));
    _history._reactions.removeWhere((_, r) => r.targetKey == key);
    _history.pins.remove(key);
    _history.starred.remove(key);
    _history.pendingPins.removeWhere((_, p) => p.targetKey == key);
  }

  @override
  Future<List<LocalConversationPref>> loadConversationPrefs() async =>
      _conversationPrefs.values.toList();
  @override
  Future<void> saveConversationPref(LocalConversationPref pref) async {
    if (pref.pinnedAt != null &&
        _conversationPrefs.values
                .where((p) =>
                    p.pinnedAt != null &&
                    p.conversationId != pref.conversationId)
                .length >=
            5)
      throw StateError('At most five chats can be pinned on this device');
    _conversationPrefs[pref.conversationId] = pref;
  }

  @override
  Future<void> discardPendingPin(String actionKey) async =>
      _history.pendingPins.remove(actionKey);

  @override
  Future<List<LocalMessageReaction>> loadReactions(
          String conversationId) async =>
      _history.reactions(conversationId);
}

/// In-memory twin of the database's decrypted history, with the same effect
/// rules as `EncryptedLocalDatabase._applyMessageEffects`.
class _MemoryMessageHistory {
  final Map<String, LocalPin> pins = {};
  final Map<String, LocalPendingPin> pendingPins = {};
  final Map<String, int> starred = {};
  final Map<String, LocalMessage> _messages = <String, LocalMessage>{};
  final Map<String, LocalMessageReaction> _reactions =
      <String, LocalMessageReaction>{};

  List<LocalMessage> allMessages() => _messages.values.toList(growable: false);

  List<LocalMessageReaction> allReactions() =>
      _reactions.values.toList(growable: false);

  void replace(
      List<LocalMessage> messages, List<LocalMessageReaction> reactions) {
    clear();
    for (final message in messages) {
      _messages[message.key] = message;
    }
    for (final reaction in reactions) {
      _reactions['${reaction.targetKey}\u0000${reaction.reactorAccountId}'] =
          reaction;
    }
  }

  void clear() {
    pins.clear();
    starred.clear();
    pendingPins.clear();
    _messages.clear();
    _reactions.clear();
  }

  _MemoryMessageHistory copy() {
    final next = _MemoryMessageHistory()
      ..replace(allMessages(), allReactions());
    next.pins.addAll(pins);
    next.pendingPins.addAll(pendingPins);
    next.starred.addAll(starred);
    return next;
  }

  void apply(List<MessageEffect> effects,
      {required HistoryNamespace namespace, String? accountId}) {
    for (final effect in effects) {
      switch (effect) {
        case InsertMessageEffect():
          if (effect.expiresAt != null &&
              effect.expiresAt! <= DateTime.now().millisecondsSinceEpoch)
            continue;
          final merged = reconcileDirectHistory(
              namespace,
              _messages.values.toList(),
              historyMessageFromInsert(effect),
              accountId);
          for (final key in merged.removed) {
            _messages.remove(key);
            _reactions.removeWhere((_, r) => r.targetKey == key);
            pins.remove(key);
            starred.remove(key);
            pendingPins.removeWhere((_, p) => p.targetKey == key);
          }
          if (merged.message == null) continue;
          _messages[effect.key] = merged.message!;
        case EditMessageEffect():
          final target = _messages[effect.targetKey];
          if (target == null) {
            deferHistoryEffect(namespace, effect, accountId);
            continue;
          }
          if (target.senderAccountId != effect.editorAccountId ||
              target.hiddenAt != null ||
              target.channelId != effect.channelId ||
              (target.expiresAt != null &&
                  target.expiresAt! <= DateTime.now().millisecondsSinceEpoch) ||
              (effect.conversationId != null &&
                  target.conversationId != effect.conversationId) ||
              target.kind != LocalMessageKind.text ||
              target.deletedAt != null) {
            continue;
          }
          _messages[effect.targetKey] = target.copyWith(
            body: Value(effect.body),
            editedAt: Value(effect.at),
            formatJson: Value(effect.formatJson),
            senderRemoved:
                effect.senderRemoved ? const Value(true) : const Value.absent(),
          );
          markLiveHistoryEffect(namespace, effect, effect.targetKey);
        case DeleteMessageEffect():
          final target = _messages[effect.targetKey];
          if (target == null) {
            deferHistoryEffect(namespace, effect, accountId);
            continue;
          }
          if (!effect.allows(target.senderAccountId) ||
              target.hiddenAt != null ||
              target.deletedAt != null ||
              target.channelId != effect.channelId ||
              (target.expiresAt != null &&
                  target.expiresAt! <= DateTime.now().millisecondsSinceEpoch) ||
              (effect.conversationId != null &&
                  target.conversationId != effect.conversationId) ||
              (target.kind != LocalMessageKind.text &&
                  target.kind != LocalMessageKind.attachment &&
                  target.kind != LocalMessageKind.unsupported &&
                  target.kind != LocalMessageKind.poll)) {
            continue;
          }
          _messages[effect.targetKey] = target.copyWith(
            body: Value(target.kind == LocalMessageKind.unsupported
                ? bodyAfterUnsupportedDelete(target.body)
                : null),
            deletedAt: Value(effect.at),
            formatJson: const Value(null),
          );
          markLiveHistoryEffect(namespace, effect, effect.targetKey);
          _reactions
              .removeWhere((_, item) => item.targetKey == effect.targetKey);
          pins.remove(effect.targetKey);
          starred.remove(effect.targetKey);
          pendingPins.removeWhere((_, p) => p.targetKey == effect.targetKey);
        case ReactionEffect():
          final id = '${effect.targetKey}\u0000${effect.reactorAccountId}';
          final reactionTarget = _messages[effect.targetKey];
          if (reactionTarget == null ||
              reactionTarget.hiddenAt != null ||
              reactionTarget.deletedAt != null ||
              reactionTarget.channelId != effect.channelId ||
              (reactionTarget.expiresAt != null &&
                  reactionTarget.expiresAt! <=
                      DateTime.now().millisecondsSinceEpoch) ||
              (effect.conversationId != null &&
                  reactionTarget.conversationId != effect.conversationId))
            continue;
          if (effect.reaction.isNotEmpty &&
              (reactionTarget.deletedAt != null ||
                  (reactionTarget.kind != LocalMessageKind.text &&
                      reactionTarget.kind != LocalMessageKind.attachment))) {
            continue;
          }
          if (effect.reaction.isEmpty) {
            _reactions.remove(id);
          } else {
            _reactions[id] = LocalMessageReaction(
                targetKey: effect.targetKey,
                reactorAccountId: effect.reactorAccountId,
                reaction: effect.reaction,
                updatedAt: effect.at);
          }
        case PollVoteEffect():
          final poll = _messages[effect.targetKey];
          if (poll == null ||
              poll.kind != LocalMessageKind.poll ||
              poll.conversationId != effect.conversationId ||
              poll.channelId != effect.channelId ||
              poll.hiddenAt != null ||
              poll.deletedAt != null ||
              (poll.expiresAt != null &&
                  poll.expiresAt! <= DateTime.now().millisecondsSinceEpoch)) {
            continue;
          }
          final updated =
              applyPollVote(poll.body, effect.voterAccountId, effect.choices);
          if (updated == null) continue;
          _messages[effect.targetKey] = poll.copyWith(body: Value(updated));
        case ProfileKeyEffect():
          // Profile keys are not message history; the store applies them
          // beside it (see MemoryLocalStore._applyHistoryEffects).
          break;
        case PollCloseEffect():
          final poll = _messages[effect.targetKey];
          if (poll == null ||
              poll.kind != LocalMessageKind.poll ||
              poll.senderAccountId != effect.closerAccountId ||
              poll.conversationId != effect.conversationId ||
              poll.channelId != effect.channelId ||
              poll.hiddenAt != null ||
              poll.deletedAt != null ||
              (poll.expiresAt != null &&
                  poll.expiresAt! <= DateTime.now().millisecondsSinceEpoch)) {
            continue;
          }
          final closed = applyPollClose(poll.body);
          if (closed == null) continue;
          _messages[effect.targetKey] = poll.copyWith(body: Value(closed));
        case PinMessageEffect():
          if (effect.pendingActionKey != null) {
            pendingPins[effect.pendingActionKey!] = LocalPendingPin(
                actionKey: effect.pendingActionKey!,
                conversationId: effect.conversationId,
                channelId: effect.channelId,
                targetKey: effect.targetKey,
                accountId: effect.accountId,
                pinned: effect.pinned,
                durationSeconds: effect.durationSeconds);
            continue;
          }
          final target = _messages[effect.targetKey];
          if (target == null ||
              target.conversationId != effect.conversationId ||
              target.channelId != effect.channelId ||
              target.hiddenAt != null ||
              target.deletedAt != null ||
              (target.expiresAt != null &&
                  target.expiresAt! <= DateTime.now().millisecondsSinceEpoch) ||
              !const [LocalMessageKind.text, LocalMessageKind.attachment]
                  .contains(target.kind)) continue;
          pins.remove(effect.targetKey);
          if (!effect.pinned) continue;
          var expiry = effect.at + effect.durationSeconds! * 1000;
          if (target.expiresAt != null && expiry > target.expiresAt!)
            expiry = target.expiresAt!;
          if (expiry <= DateTime.now().millisecondsSinceEpoch) continue;
          final order = pins.values.fold(0,
                  (int max, p) => p.appliedOrder > max ? p.appliedOrder : max) +
              1;
          pins[effect.targetKey] = LocalPin(
              conversationId: effect.conversationId,
              channelId: effect.channelId,
              targetKey: effect.targetKey,
              pinnedByAccountId: effect.accountId,
              pinnedAt: effect.at,
              appliedOrder: order,
              expiresAt: expiry);
          final scoped = pins.values
              .where((p) =>
                  p.conversationId == effect.conversationId &&
                  p.channelId == effect.channelId)
              .toList()
            ..sort((a, b) {
              final t = b.pinnedAt.compareTo(a.pinnedAt);
              return t != 0 ? t : b.appliedOrder.compareTo(a.appliedOrder);
            });
          while (scoped.length > pinLimitPerChat) {
            final oldest = scoped.removeLast();
            pins.remove(oldest.targetKey);
          }
      }
    }
  }

  void markSent(String key, String serverMessageId,
      {int? expiresAt, String? conversationId, String? channelId}) {
    final target = _messages[key];
    if (target == null ||
        (conversationId != null && target.conversationId != conversationId) ||
        target.channelId != channelId) return;
    // A row linked to another server id keeps it (L2-3 review H1).
    final linked = target.serverMessageId;
    if (linked != null && linked != serverMessageId) return;
    _messages[key] = target.copyWith(
      serverMessageId: Value(serverMessageId),
      state: LocalMessageState.sent,
      // Only the first echo sets the expiry (W2). The sender's own expiry,
      // already on the row, is only ever shortened by it, never lengthened
      // (TASK-106): the shorter of the two wins, as for a received message.
      expiresAt: Value(target.serverMessageId == null
          ? effectiveExpiryMillis(
              senderMs: target.expiresAt, serverMs: expiresAt)
          : target.expiresAt),
    );
  }

  /// Removes messages past their own expiry, with their reactions. Returns
  /// the conversations that lost a row.
  Set<String> purgeExpired(int nowMs) {
    final touched = <String>{};
    final removed = <String>{};
    _messages.removeWhere((key, item) {
      final at = item.expiresAt;
      final gone = at != null && at <= nowMs;
      if (gone) {
        touched.add(item.conversationId);
        removed.add(key);
      }
      return gone;
    });
    _reactions.removeWhere((_, item) => removed.contains(item.targetKey));
    pins.removeWhere((key, p) => removed.contains(key) || p.expiresAt <= nowMs);
    pendingPins.removeWhere((_, p) => removed.contains(p.targetKey));
    starred.removeWhere((key, _) => removed.contains(key));
    return touched;
  }

  List<MessageSearchHit> search(String query, int limit) {
    final terms = searchTerms(query);
    if (terms.isEmpty) return const <MessageSearchHit>[];
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final found = _messages.values.where((item) =>
        (item.expiresAt == null || item.expiresAt! > nowMs) &&
        item.kind == LocalMessageKind.text &&
        item.body != null &&
        item.deletedAt == null &&
        terms.every(item.body!.toLowerCase().contains));
    final sorted = found.toList()
      ..sort((a, b) {
        final byTime = b.createdAt.compareTo(a.createdAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return [
      for (final item in sorted.take(limit))
        MessageSearchHit(
          key: item.key,
          conversationId: item.conversationId,
          senderAccountId: item.senderAccountId,
          createdAt: item.createdAt,
          snippet: snippetFor(item.body!, terms),
        ),
    ];
  }

  DateTime? nextExpiry() {
    int? next;
    for (final item in _messages.values) {
      final at = item.expiresAt;
      if (at != null && (next == null || at < next)) next = at;
    }
    return next == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(next, isUtc: true);
  }

  List<LocalMessage> messages(String conversationId) {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final result = _messages.values
        .where((item) =>
            item.conversationId == conversationId &&
            (item.expiresAt == null || item.expiresAt! > nowMs))
        .toList();
    result.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return result;
  }

  List<LocalMessageReaction> reactions(String conversationId) => _reactions
      .values
      .where(
          (item) => _messages[item.targetKey]?.conversationId == conversationId)
      .toList(growable: false);
}

typedef LocalDatabaseFactory = EncryptedLocalDatabase Function(
  File file,
  String keyHex,
);

/// Stores growing local state in an encrypted transactional database. Secure
/// storage contains only the device-bound database key and a one-time legacy
/// record during migration.
class SecureLocalStore implements LocalStore {
  SecureLocalStore({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directoryProvider,
    LocalDatabaseFactory? databaseFactory,
    LocalDatabaseFactory? existingDatabaseFactory,
    MlsCommitFailureInjector? mlsCommitFailureInjector,
    BackupExclusion? backupExclusion,
    String namespace = '',
    bool existingOnly = false,
  })  : assert(RegExp(r'^[a-z0-9-]{0,40}$').hasMatch(namespace)),
        _namespace = namespace,
        _existingOnly = existingOnly,
        _storage = storage ??
            const FlutterSecureStorage(
              // Fail closed (I39): resetting on a keystore error would wipe
              // the database key and with it every message on the device.
              aOptions: AndroidOptions(
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              // The data protection keychain needs a keychain-access-groups
              // entitlement, which only a team-signed build can carry. macOS
              // builds are unsigned demos for now, so they use the login
              // keychain. Revisit when macOS builds are signed.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            ),
        _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _databaseFactory = databaseFactory ?? openEncryptedLocalDatabase,
        _existingDatabaseFactory =
            existingDatabaseFactory ?? openExistingEncryptedLocalDatabase,
        _mlsCommitFailureInjector = mlsCommitFailureInjector,
        _backupExclusion = backupExclusion ??
            (Platform.isIOS ? PlatformBackupExclusion.exclude : null);

  static const _legacyRecordKey = 'veritra.account_state.v2';
  static const _databaseKey = 'veritra.database_key.v1';
  static const _migrationMarker = 'legacy_secure_record_migrated';
  // Every conversation is cached so the full chat list opens offline
  // (Stage 4); the bound only stops a runaway server list. Envelopes stay
  // capped: decrypted history lives in local_messages, which has no cap.
  static const _maxCachedConversations = 1000;
  static const _maxMessagesPerConversation = 200;

  /// Separates independent local identities on one device: demo builds use
  /// `demo`, and desktop profiles extend it. The empty default keeps the
  /// release layout (database in the support directory, key
  /// `veritra.database_key.v1`) byte for byte.
  final String _namespace;

  /// The fixed account slot this store owns.
  String get namespace => _namespace;
  bool _existingOnly;

  /// Only the actual attached UI may enable initialization. An already-started
  /// strict open keeps its captured mode, even if the UI attaches meanwhile.
  void allowForegroundInitialization() => _existingOnly = false;
  String get _databaseKeyName =>
      _namespace.isEmpty ? _databaseKey : 'veritra.$_namespace.database_key.v1';
  String get _legacyRecordKeyName => _namespace.isEmpty
      ? _legacyRecordKey
      : 'veritra.$_namespace.account_state.v2';
  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _directoryProvider;
  final LocalDatabaseFactory _databaseFactory;
  final LocalDatabaseFactory _existingDatabaseFactory;
  final MlsCommitFailureInjector? _mlsCommitFailureInjector;
  final BackupExclusion? _backupExclusion;
  Future<EncryptedLocalDatabase>? _openingDatabase;

  /// Set by [close]; the store never opens its database again.
  bool _closed = false;
  String? _databasePath;
  String? _syncLeaseKey;

  @override
  Future<void> saveSyncRecovery(SyncRecovery? recovery) async {
    final database = await _database();
    if (recovery == null) {
      await database.deleteMetadata(EncryptedLocalDatabase.syncRecoveryName);
    } else {
      await database.writeMetadata(
          EncryptedLocalDatabase.syncRecoveryName, recovery.encode());
    }
  }

  @override
  Future<GovernanceObservations?> loadGovernanceObservations(
          String groupId) async =>
      (await _database()).readGovernanceObservations(groupId);

  @override
  Future<void> saveInviteAnchor(InviteAnchor anchor) async =>
      (await _database()).writeInviteAnchor(anchor);
  @override
  Future<InviteAnchor?> loadInviteAnchor(String conversationId) async =>
      (await _database()).readInviteAnchor(conversationId);

  @override
  Future<String?> loadSetting(String name) async =>
      (await _database()).readMetadata('setting:$name');

  @override
  Future<void> saveSetting(String name, String value) async =>
      (await _database()).writeMetadata('setting:$name', value);

  @override
  Future<List<ConversationPause>> loadConversationPauses() async =>
      (await _database()).readConversationPauses();

  @override
  Future<ConversationPause?> loadConversationPause(
          String conversationId) async =>
      (await _database()).readConversationPause(conversationId);

  @override
  Future<ConversationPause> pauseConversation({
    required String conversationId,
    required int failedEventId,
    required SyncFailureKind kind,
    String? failedEventType,
    String? failedRef,
    void Function()? checkCanCommit,
  }) async =>
      (await _database()).writeConversationPause(
        conversationId: conversationId,
        failedEventId: failedEventId,
        kind: kind,
        failedEventType: failedEventType,
        failedRef: failedRef,
        leaseKey: _syncLeaseKey,
        checkCanCommit: checkCanCommit,
      );

  @override
  Future<void> skipPausedConversationEvent({
    required String conversationId,
    required int eventId,
    required int expectedCursor,
    void Function()? checkCanCommit,
  }) async =>
      (await _database()).skipPausedConversationEvent(
        conversationId: conversationId,
        eventId: eventId,
        expectedCursor: expectedCursor,
        leaseKey: _syncLeaseKey,
        checkCanCommit: checkCanCommit,
      );

  @override
  Future<bool> checkpointSealedResidue() async {
    try {
      return await (await _database()).checkpointWalTruncate();
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> clearConversationPause(String conversationId,
          {int? generation, void Function()? checkCanCommit}) async =>
      (await _database()).clearConversationPause(
        conversationId,
        generation: generation,
        leaseKey: _syncLeaseKey,
        checkCanCommit: checkCanCommit,
      );

  @override
  Future<SyncRecovery?> loadSyncRecovery() async =>
      SyncRecovery.decode(await (await _database())
          .readMetadata(EncryptedLocalDatabase.syncRecoveryName));

  @override
  Future<void> acquireSyncLease(LocalSyncLease lease) async {
    final database = await _database();
    await database.acquireSyncLease(lease.key);
    _syncLeaseKey = lease.key;
  }

  @override
  Future<void> releaseSyncLease(LocalSyncLease lease) async {
    final key = _syncLeaseKey;
    if (key == null || key != lease.key) return;
    await (await _database()).releaseSyncLease(key);
    _syncLeaseKey = null;
  }

  @override
  Future<void> saveSession(Session session) async {
    final database = await _database();
    final previous = _sessionFromJson(await database.readSessionJson());
    final changed = previous != null && _identityChanged(previous, session);
    await database.writeSessionJson(
      jsonEncode(_sessionJson(session)),
      clearIdentityState: changed,
    );
    if (changed) _syncLeaseKey = null;
  }

  @override
  Future<Session?> loadSession() async {
    return _sessionFromJson(await (await _database()).readSessionJson());
  }

  @override
  Future<void> saveSyncCursor(int eventId) async {
    if (eventId < 0) throw const FormatException('invalid sync cursor');
    await (await _database()).writeCursor(eventId);
  }

  @override
  Future<int> loadSyncCursor() async => (await _database()).readCursor();

  @override
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  ) async {
    if (cursor < 0) throw const FormatException('invalid sync cursor');
    await _replaceProjection(conversations, messagesByConversation, cursor);
  }

  @override
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  ) =>
      _replaceProjection(conversations, messagesByConversation, null);

  Future<void> _replaceProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int? cursor,
  ) async {
    final boundedConversations =
        conversations.take(_maxCachedConversations).toList(growable: false);
    final conversationIds = boundedConversations.map((item) => item.id).toSet();
    await (await _database()).replaceSnapshot(
      conversations: boundedConversations.map(
        (item) => (id: item.id, payloadJson: jsonEncode(item.toJson())),
      ),
      envelopes: <({
        String id,
        String conversationId,
        int position,
        String payloadJson,
      })>[
        for (final entry in messagesByConversation.entries)
          if (conversationIds.contains(entry.key))
            for (final indexed in entry.value
                .take(_maxMessagesPerConversation)
                .toList(growable: false)
                .indexed)
              (
                id: indexed.$2.id,
                conversationId: entry.key,
                position: indexed.$1,
                payloadJson: jsonEncode(indexed.$2.toJson()),
              ),
      ],
      cursor: cursor,
    );
  }

  @override
  Future<CachedSnapshot?> loadSnapshot() async {
    final raw = await (await _database()).readSnapshotJson();
    if (raw.conversationJson.isEmpty) return null;
    try {
      final conversations = raw.conversationJson
          .map((item) => Conversation.fromJson(_decodeJsonMap(item)))
          .toList();
      final messages = <String, List<ReceivedMessageEnvelope>>{};
      for (final entry in raw.envelopeJson.entries) {
        messages[entry.key] = entry.value
            .map((item) =>
                ReceivedMessageEnvelope.fromJson(_decodeJsonMap(item)))
            .toList();
      }
      return CachedSnapshot(
        cursor: raw.cursor,
        conversations: conversations,
        messagesByConversation: messages,
      );
    } catch (_) {
      throw StateError('encrypted local snapshot is corrupt');
    }
  }

  @override
  Future<void> enqueueEnvelope(MessageEnvelope envelope,
      {String? draftText}) async {
    final database = await _database();
    final path = _databasePath;
    if (path == null) throw StateError('encrypted database path unavailable');
    await _serializeDatabaseWrite(path, () async {
      try {
        await database.upsertOutbox(
          idempotencyKey: envelope.idempotencyKey,
          conversationId: envelope.conversationId,
          payloadJson: jsonEncode(envelope.toJson()),
          draftText: draftText,
          queuedAt: DateTime.now().microsecondsSinceEpoch,
          maxEntries: maxPendingEnvelopes,
        );
      } on StateError catch (error) {
        if (error.message == 'outbox_full') {
          throw const OutboxFullException();
        }
        rethrow;
      }
    });
  }

  @override
  Future<bool> hasOutboxCapacity() async =>
      (await (await _database()).outboxCount()) < maxPendingEnvelopes;

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async =>
      (await (await _database()).readOutboxJson())
          .map((item) => MessageEnvelope.fromJson(_decodeJsonMap(item)))
          .toList();

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async =>
      (await (await _database()).readOutboxRecords())
          .map((item) => PendingEnvelopeRecord(
                envelope:
                    MessageEnvelope.fromJson(_decodeJsonMap(item.payloadJson)),
                attemptCount: item.attemptCount,
                terminal: item.terminal,
                nextAttemptAt: item.nextAttemptAt == null
                    ? null
                    : DateTime.fromMicrosecondsSinceEpoch(item.nextAttemptAt!,
                        isUtc: true),
                failureClass: item.failureClass,
                draftText: item.draftText,
              ))
          .toList(growable: false);

  @override
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    await (await _database()).markOutboxFailure(idempotencyKey,
        failureClass: failureClass,
        terminal: terminal,
        nextAttemptAt: nextAttemptAt?.toUtc().microsecondsSinceEpoch);
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    await (await _database()).deleteOutbox(idempotencyKey);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    _validateCryptoState(state);
    if (syncCursor < 0) throw const FormatException('invalid sync cursor');
    await (await _database()).writeCryptoState(
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      cursor: syncCursor,
      recordChanges: _recordWrites(state),
    );
  }

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    _validateCryptoState(transition.state);
    _validateMlsTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
      // The database transaction decides whether an event behind the
      // cursor is a replay of a paused conversation (C1 P1).
      allowBehindCursor: true,
    );
    await (await _database()).commitMlsTransition(
      messageId: transition.messageId,
      conversationId: transition.conversationId,
      expectedCounter: transition.expectedCounter,
      expectedCursor: transition.expectedCursor,
      counter: transition.state.counter,
      stateKey: transition.state.stateKey,
      sealedState: transition.state.sealedState,
      cursor: transition.cursor,
      upsertedEnvelopes: transition.upsertedEnvelopes
          .map((envelope) => (
                id: envelope.id,
                conversationId: envelope.conversationId,
                payloadJson: jsonEncode(envelope.toJson()),
              ))
          .toList(growable: false),
      deletedEnvelopeIds: transition.deletedEnvelopeIds,
      recordChanges: _recordWrites(transition.state),
      messageEffects: transition.messageEffects,
      failureInjector: _mlsCommitFailureInjector,
      leaseKey: _syncLeaseKey,
      resolvedMlsOutboxKey: transition.resolvedMlsOutboxKey,
      checkCanCommit: transition.checkCanCommit,
      noticeReferences: transition.noticeReferences,
      frankReveals: transition.frankReveals,
      communityInfo: transition.communityInfo,
      approvalLeaves: transition.approvalLeaves,
      governanceObservation: transition.governanceObservation,
      infoRemovalEpoch: transition.infoRemovalEpoch,
      c7Settings: transition.c7Settings,
    );
  }

  @override
  Future<FrankReveal?> loadFrankReveal(String messageKey) async =>
      (await _database()).readFrankReveal(messageKey);

  @override
  Future<int> saveSealedTokens(List<SealedToken> tokens) async =>
      (await _database()).writeSealedTokens(tokens);

  @override
  Future<SealedToken?> takeSealedToken(String conversationId,
          {required String keyId, required int epoch}) async =>
      (await _database())
          .takeSealedToken(conversationId, keyId: keyId, epoch: epoch);

  @override
  Future<int> countSealedTokens(String conversationId,
          {required String keyId, required int epoch}) async =>
      (await _database())
          .countSealedTokens(conversationId, keyId: keyId, epoch: epoch);

  @override
  Future<void> dropSealedTokens(
          {int? minEpoch, String? keyId, String? conversationId}) async =>
      (await _database()).dropSealedTokens(
          minEpoch: minEpoch, keyId: keyId, conversationId: conversationId);

  @override
  Future<SealedKeyPin?> loadSealedKeyPin(String origin) async =>
      (await _database()).readSealedKeyPin(origin);

  @override
  Future<void> saveSealedKeyPin(SealedKeyPin pin) async =>
      (await _database()).writeSealedKeyPin(pin);

  @override
  Future<List<int>?> loadSealedOwnPostDigest(
          String conversationId, String idempotencyKey) async =>
      (await _database())
          .readSealedOwnPostDigest(conversationId, idempotencyKey);

  @override
  Future<String?> loadSealedOwnPostFallback(
          String conversationId, String idempotencyKey) async =>
      (await _database())
          .readSealedOwnPostFallback(conversationId, idempotencyKey);

  @override
  Future<bool> rewriteQueuedEnvelope(MessageEnvelope envelope) async =>
      (await _database()).rewriteOutboxPayload(
          envelope.idempotencyKey, jsonEncode(envelope.toJson()));

  @override
  Future<List<CommunityInfoEvent>> loadCommunityInfoEvents(
          CommunityInfoEventKind kind,
          String subjectKind,
          String subjectId) async =>
      (await _database()).readCommunityInfoEvents(kind, subjectKind, subjectId);

  @override
  Future<void> recordOwnCommunityInfoEvents(
          List<CommunityInfoEvent> events) async =>
      (await _database()).writeCommunityInfoEvents(events);

  @override
  Future<AcceptedCommunityInfo?> loadAcceptedCommunityInfo(
          String subjectKind, String subjectId) async =>
      (await _database()).readAcceptedCommunityInfo(subjectKind, subjectId);

  @override
  Future<void> saveAcceptedCommunityInfo(AcceptedCommunityInfo info) async =>
      (await _database()).writeAcceptedCommunityInfo(info);

  @override
  Future<List<ReportKeyPin>> loadReportKeyPins(String origin) async =>
      (await _database()).readReportKeyPins(origin);

  @override
  Future<ReportKeyPin?> loadReportKeyPin(
          String origin, String ownerAccountId) async =>
      (await _database()).readReportKeyPin(origin, ownerAccountId);

  @override
  Future<void> saveReportKeyPin(ReportKeyPin pin) async =>
      (await _database()).writeReportKeyPin(pin);

  @override
  Future<void> deleteReportKeyPin(String origin, String ownerAccountId) async =>
      (await _database()).deleteReportKeyPin(origin, ownerAccountId);

  @override
  Future<bool> isMessageReported(
          String origin, String accountId, String messageKey) async =>
      (await _database()).readReportFiled(origin, accountId, messageKey);

  @override
  Future<void> markMessageReported(
          String origin, String accountId, String messageKey) async =>
      (await _database()).writeReportFiled(origin, accountId, messageKey,
          DateTime.now().toUtc().millisecondsSinceEpoch);

  @override
  Future<List<StoredProfileKey>> loadProfileKeys(
          String kind, String subjectId) async =>
      (await _database()).readProfileKeys(kind, subjectId);

  @override
  Future<List<StoredProfileKey>> loadAllProfileKeys(String kind) async =>
      (await _database()).readAllProfileKeys(kind);

  @override
  Future<void> saveProfileKey(ProfileKeyEffect key) async {
    final database = await _database();
    await database.transaction(() => database.storeProfileKey(key));
  }

  @override
  Future<void> deleteProfileKey(
          String kind, String subjectId, String keyId) async =>
      (await _database()).deleteProfileKey(kind, subjectId, keyId);

  @override
  Future<StoredProfile?> loadProfile(String kind, String subjectId) async =>
      (await _database()).readProfile(kind, subjectId);

  @override
  Future<List<StoredProfile>> loadProfiles(String kind) async =>
      (await _database()).readProfiles(kind);

  @override
  Future<bool> saveProfile(StoredProfile profile) async =>
      (await _database()).writeProfile(profile);

  @override
  Future<void> deleteProfileSubject(String kind, String subjectId) async =>
      (await _database()).deleteProfileSubject(kind, subjectId);

  @override
  Future<String?> loadProfileState(String name) async =>
      (await _database()).readProfileState(name);

  @override
  Future<void> saveProfileState(String name, String? value) async =>
      (await _database()).writeProfileState(name, value);

  @override
  Future<Map<String, String>> loadProfileStatePrefix(String prefix) async =>
      (await _database()).readProfileStatePrefix(prefix);

  @override
  Future<DeviceListPin?> loadDeviceListPin(String accountId) async =>
      (await _database()).readDeviceListPin(accountId);

  @override
  Future<bool> saveDeviceListPin(DeviceListPin pin,
          {required int? expectedVersion}) async =>
      (await _database())
          .writeDeviceListPin(pin, expectedVersion: expectedVersion);

  @override
  Future<void> touchDeviceListPin(String accountId, int checkedAt) async =>
      (await _database()).touchDeviceListPin(accountId, checkedAt);

  @override
  Future<void> saveDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  }) async =>
      (await _database()).writeDeviceListConflict(
          accountId: accountId,
          version: version,
          pinnedStatement: pinnedStatement,
          otherStatement: otherStatement,
          recordedAt: recordedAt);

  @override
  Future<List<ApprovalLeaf>> loadApprovalLeaves(String conversationId) async =>
      (await _database()).readApprovalLeaves(conversationId);

  @override
  Future<void> saveApprovalLeaves(ApprovalLeafChange change) async =>
      (await _database()).writeApprovalLeaves(change);

  @override
  Future<List<String>> loadHeldConversations() async =>
      (await _database()).readHeldConversations();

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    await (await _database()).commitSyncEvent(
      eventKey: commit.eventKey,
      conversationId: commit.conversationId,
      expectedCursor: commit.expectedCursor,
      cursor: commit.cursor,
      envelope: commit.envelope == null
          ? null
          : (
              id: commit.envelope!.id,
              conversationId: commit.envelope!.conversationId,
              payloadJson: jsonEncode(commit.envelope!.toJson()),
            ),
      ownMessageKey: commit.ownMessageKey,
      allowOwnPinEffect: commit.allowOwnPinEffect,
      checkCanCommit: commit.checkCanCommit,
      leaseKey: _syncLeaseKey,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      (await _database()).hasProcessedMlsMessage(messageId);

  @override
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId) async =>
      (await _database()).hasAppliedMlsControlMessage(mlsMessageId);

  @override
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition) async {
    _validateOutgoingMlsTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
    );
    await (await _database()).commitOutgoingMlsTransition(
      expectedCounter: transition.expectedCounter,
      expectedCursor: transition.expectedCursor,
      counter: transition.state.counter,
      stateKey: transition.state.stateKey,
      sealedState: transition.state.sealedState,
      messages: transition.messages
          .map((message) => (
                idempotencyKey: message.idempotencyKey,
                conversationId: message.conversationId,
                kind: message.kind,
                recipientDeviceId: message.recipientDeviceId,
                revocationDeviceId: message.revocationDeviceId,
                payload: message.payload,
              ))
          .toList(growable: false),
      recordChanges: _recordWrites(transition.state),
      leaseKey: _syncLeaseKey,
    );
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async =>
      (await (await _database()).readMlsOutbox())
          .map((message) => PendingMlsMessage(
                idempotencyKey: message.idempotencyKey,
                conversationId: message.conversationId,
                kind: message.kind,
                recipientDeviceId: message.recipientDeviceId,
                revocationDeviceId: message.revocationDeviceId,
                payload: message.payload,
                attemptCount: message.attemptCount,
                nextAttemptAt: message.nextAttemptAt == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                        message.nextAttemptAt!,
                        isUtc: true),
                failureClass: message.failureClass,
                terminal: message.terminal,
              ))
          .toList(growable: false);

  @override
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    await (await _database()).recordMlsOutboxFailure(
      idempotencyKey,
      failureClass: failureClass,
      terminal: terminal,
      nextAttemptAt: nextAttemptAt?.toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    await (await _database()).deleteMlsOutbox(idempotencyKey);
  }

  @override
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition) async {
    _validateOutgoingApplicationTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
    );
    try {
      await (await _database()).commitOutgoingApplicationTransition(
        expectedCounter: transition.expectedCounter,
        expectedCursor: transition.expectedCursor,
        counter: transition.state.counter,
        stateKey: transition.state.stateKey,
        sealedState: transition.state.sealedState,
        idempotencyKey: transition.envelope.idempotencyKey,
        conversationId: transition.envelope.conversationId,
        payloadJson: jsonEncode(transition.envelope.toJson()),
        maxEntries: maxPendingEnvelopes,
        draftText: transition.draftText,
        governanceObservation: transition.governanceObservation,
        messageEffects: transition.messageEffects,
        communityInfo: transition.communityInfo,
        recordChanges: _recordWrites(transition.state),
        sealedOwnPost: transition.sealedOwnPost,
        replacesSealedEntry: transition.replacesSealedEntry,
        leaseKey: _syncLeaseKey,
      );
    } on StateError catch (error) {
      if (error.message == 'outbox_full') {
        throw const OutboxFullException();
      }
      rethrow;
    }
  }

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
    GovernanceObservationChange? governanceObservation,
    ({String conversationId, int epoch})? infoRemoval,
    Map<String, String?> c7Settings = const <String, String?>{},
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: expectedCounter, currentCursor: expectedCursor);
    await (await _database()).commitLocalMlsState(
      expectedCounter: expectedCounter,
      expectedCursor: expectedCursor,
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      recordChanges: _recordWrites(state),
      leaseKey: _syncLeaseKey,
      resolvedMlsOutboxKey: resolvedMlsOutboxKey,
      governanceObservation: governanceObservation,
      infoRemoval: infoRemoval,
      c7Settings: c7Settings,
    );
  }

  @override
  Future<StoredCryptoState?> loadCryptoState() async {
    final row = await (await _database()).readCryptoState();
    if (row == null) return null;
    final state = StoredCryptoState(
      counter: row.counter,
      stateKey: row.stateKey,
      sealedState: row.sealedState,
    );
    _validateCryptoState(state);
    return state;
  }

  @override
  Future<PendingEnrollment?> loadPendingEnrollment() async =>
      PendingEnrollment._fromRow(
          await (await _database()).readPendingEnrollment());

  @override
  Future<void> savePendingEnrollment(PendingEnrollment enrollment) async =>
      (await _database()).writePendingEnrollment(enrollment._toRow());

  @override
  Future<bool> deletePendingEnrollment(
          {required String kind, String? deviceId}) async =>
      (await _database())
          .deletePendingEnrollment(kind: kind, deviceId: deviceId);

  @override
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
      EnrollmentPromotion promotion) async {
    final request = promotion._toRequest();
    final database = await _database();
    final previous = _sessionFromJson(await database.readSessionJson());
    final outcome = await database.promotePendingEnrollment(request);
    // As [saveSession]: replacing a signed-out identity dropped its stored
    // sync lease with the rest of its state.
    if (outcome == EnrollmentPromotionOutcome.promoted &&
        previous != null &&
        _identityChanged(previous, promotion.session)) {
      _syncLeaseKey = null;
    }
    return outcome;
  }

  @override
  Future<bool> isEnrollmentPromoted(
          {required String accountId, required String deviceId}) async =>
      (await (await _database()).readEnrollmentPromotions(
              accountId: accountId, deviceId: deviceId))
          .isNotEmpty;

  @override
  Future<HistoryTransferProgress?> loadHistoryTransfer(
          String origin, String linkId) async =>
      (await _database()).readHistoryTransfer(origin, linkId);

  @override
  Future<List<HistoryTransferProgress>> loadHistoryTransfers() async =>
      (await _database()).readHistoryTransfers();

  @override
  Future<void> saveHistoryTransfer(HistoryTransferProgress transfer) async =>
      (await _database()).writeHistoryTransfer(transfer);

  @override
  Future<void> commitHistoryTransferState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    required HistoryTransferProgress transfer,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: expectedCounter, currentCursor: expectedCursor);
    await (await _database()).commitHistoryTransferState(
      transfer: transfer,
      expectedCounter: expectedCounter,
      expectedCursor: expectedCursor,
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      recordChanges: _recordWrites(state),
      leaseKey: _syncLeaseKey,
    );
  }

  @override
  Future<bool> deleteHistoryTransfer(String origin, String linkId) async =>
      (await _database()).deleteHistoryTransfer(origin, linkId);

  @override
  Future<List<StoredCryptoRecord>> loadCryptoRecords() async => [
        for (final row in await (await _database()).readCryptoRecords())
          _storedRecord(row),
      ];

  @override
  Future<({StoredCryptoState? state, List<StoredCryptoRecord> records})>
      loadCryptoSnapshot() async {
    final snapshot = await (await _database()).readCryptoSnapshot();
    final row = snapshot.state;
    StoredCryptoState? state;
    if (row != null) {
      state = StoredCryptoState(
        counter: row.counter,
        stateKey: row.stateKey,
        sealedState: row.sealedState,
      );
      _validateCryptoState(state);
    }
    return (
      state: state,
      records: [for (final r in snapshot.records) _storedRecord(r)],
    );
  }

  @override
  Future<void> commitCryptoMigration({
    required int expectedCounter,
    required List<int> expectedSealedState,
    required StoredCryptoState state,
    void Function()? checkCanCommit,
  }) async {
    _validateCryptoMigration(state);
    await (await _database()).commitCryptoMigration(
      expectedCounter: expectedCounter,
      expectedSealedState: expectedSealedState,
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      recordChanges: _recordWrites(state),
      leaseKey: _syncLeaseKey,
      failureInjector: _mlsCommitFailureInjector,
      checkCanCommit: checkCanCommit,
    );
  }

  static StoredCryptoRecord _storedRecord(LocalCryptoRecord row) =>
      StoredCryptoRecord(
        kind: row.kind,
        recordId: List<int>.from(row.recordId),
        generation: row.generation,
        sealed: List<int>.from(row.sealed),
      );

  static List<CryptoRecordWrite> _recordWrites(StoredCryptoState state) => [
        for (final change in state.changes)
          (
            kind: change.kind,
            recordId: change.recordId,
            generation: change.generation,
            sealed: change.sealed,
          ),
      ];

  @override
  Future<List<LocalNoticeReference>> pendingNoticeReferences(
          LocalNoticeOwner owner,
          {int limit = localNoticeBatchLimit,
          int? now,
          void Function()? checkCanCommit}) async =>
      (await _database()).pendingNoticeReferences(owner,
          limit: limit, now: now, checkCanCommit: checkCanCommit);
  @override
  Future<LocalNoticeDecision?> pendingNoticeDecision(LocalNoticeOwner owner,
          {int? now, void Function()? checkCanCommit}) async =>
      (await _database()).pendingNoticeDecision(owner,
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<LocalNoticeDecision?> freezeNoticeDecision(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) async =>
      (await _database()).freezeNoticeDecision(owner, referenceIds,
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<void> suppressNoticeReferences(
          LocalNoticeOwner owner, Iterable<String> referenceIds,
          {int? now, void Function()? checkCanCommit}) async =>
      (await _database()).suppressNoticeReferences(owner, referenceIds,
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<void> suppressNoticesThrough(LocalNoticeOwner owner, int eventId,
          {int? now, void Function()? checkCanCommit}) async =>
      (await _database()).suppressNoticesThrough(owner, eventId,
          now: now, checkCanCommit: checkCanCommit);
  @override
  Future<void> finishNoticeDecision(
          LocalNoticeOwner owner, String decisionId, LocalNoticeOutcome outcome,
          {int? now, void Function()? checkCanCommit}) async =>
      (await _database()).finishNoticeDecision(owner, decisionId, outcome,
          now: now, checkCanCommit: checkCanCommit);

  @override
  Future<HistoryNamespace> loadHistoryNamespace() async =>
      (await _database()).readHistoryNamespace();

  @override
  Future<List<int>> exportHistorySnapshot(
          {bool omitDisappearing = false}) async =>
      (await _database()).exportHistorySnapshot(
          (json) => json == null ? null : _sessionFrom(jsonDecode(json)),
          omitDisappearing: omitDisappearing);

  @override
  Future<void> importHistorySnapshot(
      List<int> encoded, HistoryImportContext context) async {
    final snapshot = HistorySnapshot.decode(encoded);
    await (await _database()).importHistorySnapshot(snapshot, context,
        (json) => json == null ? null : _sessionFrom(jsonDecode(json)));
  }

  @override
  Future<void> savePeerVerification(String conversationId, String peerAccountId,
      List<int> transcriptHash) async {
    _validatePeerVerification(conversationId, peerAccountId, transcriptHash);
    await (await _database()).savePeerVerification(
        conversationId,
        peerAccountId,
        transcriptHash,
        DateTime.now().toUtc().microsecondsSinceEpoch);
  }

  @override
  Future<List<int>?> loadPeerVerification(
          String conversationId, String peerAccountId) =>
      _database().then((database) =>
          database.readPeerVerification(conversationId, peerAccountId));

  @override
  Future<List<MessageSearchHit>> searchMessages(String query,
          {int limit = 50}) async =>
      (await _database()).searchMessages(query, limit: limit);

  @override
  Future<Map<String, StoredDraft>> loadDrafts() async => {
        for (final row in await (await _database()).readDrafts())
          row.conversationId: StoredDraft(text: row.body, replyTo: row.replyTo),
      };

  @override
  Future<void> saveDraft(String conversationId, String text,
          {String? replyTo}) async =>
      (await _database()).saveDraft(
          conversationId: conversationId, body: text, replyTo: replyTo);

  @override
  Future<void> deleteDraft(String conversationId) async =>
      (await _database()).deleteDraft(conversationId);

  @override
  Future<Map<String, DateTime?>> loadConversationMutes() async => {
        for (final row in await (await _database())
            .readMutes(DateTime.now().toUtc().millisecondsSinceEpoch))
          row.conversationId: row.mutedUntil == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row.mutedUntil!,
                  isUtc: true),
      };

  @override
  Future<void> saveConversationMute(String conversationId,
          {required bool muted, DateTime? until}) async =>
      (await _database()).saveMute(conversationId,
          muted: muted, mutedUntil: until?.toUtc().millisecondsSinceEpoch);

  @override
  Future<Set<String>> purgeExpiredMessages({DateTime? now}) async =>
      (await _database()).purgeExpired(now: now);

  @override
  Future<DateTime?> nextMessageExpiry() async {
    final next = await (await _database()).nextExpiry();
    return next == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(next, isUtc: true);
  }

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async =>
      (await _database()).readMessages(conversationId);

  @override
  Future<List<LocalPin>> loadPins(String conversationId) async =>
      (await _database()).readPins(conversationId);
  @override
  Future<Set<String>> loadStarred() async => (await _database()).readStarred();
  @override
  Future<void> setStarred(String key, bool starred) async => (await _database())
      .setStarred(key, starred, DateTime.now().millisecondsSinceEpoch);
  @override
  Future<void> hideMessage(String conversationId, String key) async =>
      (await _database()).hideMessage(
          conversationId, key, DateTime.now().millisecondsSinceEpoch);
  @override
  Future<List<LocalConversationPref>> loadConversationPrefs() async =>
      (await _database()).readConversationPrefs();
  @override
  Future<void> saveConversationPref(LocalConversationPref pref) async =>
      (await _database()).saveConversationPref(pref);
  @override
  Future<void> discardPendingPin(String actionKey) async {
    final db = await _database();
    await (db.delete(db.localPendingPins)
          ..where((t) => t.actionKey.equals(actionKey)))
        .go();
  }

  @override
  Future<List<LocalMessageReaction>> loadReactions(
          String conversationId) async =>
      (await _database()).readReactions(conversationId);

  @override
  Future<void> clearCachedState(
      {bool preserveOutbox = false, bool keepDrafts = false}) async {
    await (await _database()).clearCachedState(
        preserveOutbox: preserveOutbox, keepDrafts: keepDrafts);
  }

  @override
  Future<void> clear() async {
    await (await _database()).clearAll();
    await _storage.delete(key: _legacyRecordKeyName);
    _syncLeaseKey = null;
  }

  @override
  Future<void> quarantineUnreadableDatabase({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed',
          'resetting the local database needs explicit confirmation');
    }
    // Synchronously, before any await: from here on no _database() call is
    // given the cached handle on the files this reset moves, and every new
    // open waits until the reset has finished.
    final opening = _openingDatabase;
    _resetGeneration++;
    final previousReset = _resetBarrier;
    final finished = Completer<void>();
    _resetBarrier = finished.future;
    EncryptedLocalDatabase? stale;
    var staleClosed = false;
    try {
      if (previousReset != null) await previousReset;
      // An open already requested finishes first. It may be queued on the
      // profile chain, so it is awaited before the reset joins that chain.
      if (opening != null) {
        try {
          stale = await opening;
        } catch (_) {
          // It never opened; there is nothing to close.
        }
      }
      final directory = await _profileDirectory();
      await _serializeProfile(_databaseFileIn(directory).absolute.path,
          () async {
        final releaseLocks = await _acquireProfileLocks(directory);
        try {
          // Closed before any file moves. The database object is closed
          // directly: _database() would wait for this reset.
          staleClosed = true;
          try {
            await stale?.close();
          } catch (_) {
            // It is not used again either way.
          }
          await _writeResetIntent(directory);
          await _completeReset(directory);
        } finally {
          await releaseLocks();
        }
      });
      _syncLeaseKey = null;
    } finally {
      if (!staleClosed) {
        // The reset stopped before its locked section and moved nothing;
        // the old handle is not handed out again, so it is closed here.
        try {
          await stale?.close();
        } catch (_) {}
      }
      // Only the open this reset replaced; a newer one is left alone.
      if (identical(_openingDatabase, opening)) _openingDatabase = null;
      if (identical(_resetBarrier, finished.future)) _resetBarrier = null;
      finished.complete();
    }
  }

  /// Raised by each requested reset. A cached open from an earlier
  /// generation belongs to files a reset moves, so it is never reused.
  int _resetGeneration = 0;
  int _openingGeneration = 0;

  /// Completes when the latest requested reset has finished (or failed).
  Future<void>? _resetBarrier;

  /// A failed open is not cached: the next call opens again, so a key that
  /// becomes readable later (after unlock, say) is picked up by a retry.
  Future<EncryptedLocalDatabase> _database() {
    final existing = _openingDatabase;
    if (existing != null && _openingGeneration == _resetGeneration) {
      return existing;
    }
    final barrier = _resetBarrier;
    final opening = barrier == null
        ? _openDatabase()
        : barrier.then((_) => _openDatabase());
    _openingDatabase = opening;
    _openingGeneration = _resetGeneration;
    unawaited(opening.then<void>((_) {}, onError: (Object error) {
      if (identical(_openingDatabase, opening)) _openingDatabase = null;
    }));
    return opening;
  }

  Future<Directory> _profileDirectory({bool existingOnly = false}) async {
    // Every open and every reset comes through here (see [close]).
    if (_closed) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.profileLocked);
    }
    final base = await _directoryProvider();
    final directory = _namespace.isEmpty
        ? base
        : Directory('${base.path}${Platform.pathSeparator}profiles'
            '${Platform.pathSeparator}$_namespace');
    if (existingOnly) {
      if (!await directory.exists()) throw const ExistingDatabaseUnavailable();
    } else {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static const _resetIntentName = 'veritra-local.reset-intent';
  static const _databaseFileNames = <String>[
    'veritra-local.db-wal',
    'veritra-local.db-shm',
    'veritra-local.db',
  ];

  String get _quarantinedKeyPrefix => '$_databaseKeyName.quarantined.';

  /// The reset is journaled so that a crash part-way leaves either the
  /// original database in place or a complete quarantined copy with its
  /// key, never a database separated from its WAL or its key.
  Future<void> _writeResetIntent(Directory directory) async {
    final intent = File('${directory.path}${Platform.pathSeparator}'
        '$_resetIntentName');
    if (await intent.exists()) return;
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final temporary = File('${intent.path}.tmp');
    await temporary.writeAsString(stamp, flush: true);
    await temporary.rename(intent.path);
  }

  Future<void> _completeReset(Directory directory) async {
    final intent = File('${directory.path}${Platform.pathSeparator}'
        '$_resetIntentName');
    if (!await intent.exists()) return;
    final stamp = (await intent.readAsString()).trim();
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(stamp)) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.keyRejected);
    }
    final quarantine = Directory('${directory.path}${Platform.pathSeparator}'
        'unreadable-$stamp');
    await quarantine.create(recursive: true);
    // Keep the key with the files so the copy stays readable if the key was
    // only temporarily unreadable. Copy before moving any file. A read that
    // failed is not an absent key, and the original entry is deleted only
    // once its copy was written and read back equal: otherwise it stays, so
    // the moved files always have a stored key that opens them.
    String? key;
    var keyReadFailed = false;
    try {
      key = await _storage.read(key: _databaseKeyName);
    } catch (_) {
      keyReadFailed = true;
    }
    var keyArchived = false;
    if (key != null) {
      final archiveName = '$_quarantinedKeyPrefix$stamp';
      try {
        await _storage.write(key: archiveName, value: key);
        keyArchived = await _storage.read(key: archiveName) == key;
      } catch (_) {
        keyArchived = false;
      }
    }
    for (final name in _databaseFileNames) {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      if (await file.exists()) {
        await file.rename('${quarantine.path}${Platform.pathSeparator}$name');
      }
    }
    if (!keyReadFailed && (key == null || keyArchived)) {
      await _storage.delete(key: _databaseKeyName);
    }
    await _storage.delete(key: _legacyRecordKeyName);
    await intent.delete();
  }

  static File _databaseFileIn(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}veritra-local.db');

  Future<EncryptedLocalDatabase> _openDatabase() async {
    final existingOnly = _existingOnly;
    final directory = await _profileDirectory(existingOnly: existingOnly);
    final databaseFile = _databaseFileIn(directory);
    final path = databaseFile.absolute.path;
    _databasePath = path;
    return _serializeProfile(
        path,
        () => _openDatabaseLocked(directory, databaseFile,
            existingOnly: existingOnly));
  }

  /// Runs [action] after every open or reset of the database at [path] that
  /// this isolate requested earlier, and before any requested later.
  static Future<T> _serializeProfile<T>(
      String path, Future<T> Function() action) async {
    final previous = _databaseOpenTails[path] ?? Future<void>.value();
    final release = Completer<void>();
    final current = previous.then((_) => release.future);
    _databaseOpenTails[path] = current;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_databaseOpenTails[path], current)) {
        _databaseOpenTails.remove(path);
      }
    }
  }

  /// Takes the profile's ownership locks, used by both open and reset: the
  /// instance lock this process keeps (a profile another process owns is
  /// refused as [LocalStoreFailureKind.profileLocked], before anything is
  /// touched) and the exclusive `veritra-local.lock` until the returned
  /// function releases it.
  static Future<Future<void> Function()> _acquireProfileLocks(
      Directory directory) async {
    try {
      await _holdInstanceLock(directory);
    } on StateError {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.profileLocked);
    }
    final lockFile =
        File('${directory.path}${Platform.pathSeparator}veritra-local.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      rethrow;
    }
    return () async {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    };
  }

  Future<EncryptedLocalDatabase> _openDatabaseLocked(
      Directory directory, File databaseFile,
      {required bool existingOnly}) async {
    if (existingOnly) {
      if (!await databaseFile.exists() ||
          await File(
                  '${directory.path}${Platform.pathSeparator}$_resetIntentName')
              .exists() ||
          await File(
                  '${directory.path}${Platform.pathSeparator}$_resetIntentName.tmp')
              .exists()) {
        throw const ExistingDatabaseUnavailable();
      }
      try {
        final key = await _storage.read(key: _databaseKeyName);
        final legacy = await _storage.read(key: _legacyRecordKeyName);
        if (key == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(key) ||
            legacy != null) {
          throw const ExistingDatabaseUnavailable();
        }
      } on ExistingDatabaseUnavailable {
        rethrow;
      } catch (_) {
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyUnavailable);
      }
    }
    final releaseLocks = await _acquireProfileLocks(directory);
    try {
      // Before anything can fail: a database from an older build that this
      // one cannot open is excluded too, and a new database file is created
      // in a directory that is already excluded.
      await _excludeFromBackup(directory);
      // A reset interrupted by a crash is finished before anything else.
      if (existingOnly) {
        if (await File(
                    '${directory.path}${Platform.pathSeparator}$_resetIntentName')
                .exists() ||
            await File(
                    '${directory.path}${Platform.pathSeparator}$_resetIntentName.tmp')
                .exists()) {
          throw const ExistingDatabaseUnavailable();
        }
      } else {
        await _completeReset(directory);
      }
      final String? keyHex;
      try {
        keyHex = await _storage.read(key: _databaseKeyName);
      } catch (_) {
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyUnavailable);
      }
      final databaseExists = await databaseFile.exists();
      if (existingOnly && (keyHex == null || !databaseExists)) {
        throw const ExistingDatabaseUnavailable();
      }
      if (keyHex == null && databaseExists) {
        // A database without its key is unreadable. Writing a fresh key
        // would hide that behind a new, empty identity (D26), so stop and
        // let the recovery screen explain it.
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyMissing);
      }
      if (keyHex != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(keyHex)) {
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyMalformed);
      }
      final key = keyHex ?? await _createKey();
      EncryptedLocalDatabase? database;
      try {
        database = existingOnly
            ? _existingDatabaseFactory(databaseFile, key)
            : _databaseFactory(databaseFile, key);
        await database.readCursor();
      } catch (error) {
        if (isSqliteFeatureUnavailable(error)) {
          // A fact about this build, not about the file or the key.
          try {
            await database?.close();
          } catch (_) {}
          throw const LocalStoreUnavailableException(
              LocalStoreFailureKind.sqliteFeatureMissing);
        }
        if (!databaseExists) {
          // A new database that failed to open: close the handle so nothing
          // holds the file (Windows refuses to move an open one).
          try {
            await database?.close();
          } catch (_) {}
          rethrow;
        }
        if (database != null &&
            (database.upgradeStarted || database.createStarted)) {
          // The key opened the file (or it was empty) and the create or
          // upgrade rolled back, as when a first create filled the disk and
          // left an empty version-0 file. Never a wrong key, so no reset is
          // offered that would delete the legacy record. Drift
          // refuses any further use of this handle, so close it; a retry
          // opens a new one. Nothing is deleted or reset.
          try {
            await database.close();
          } catch (_) {
            // It is unusable either way.
          }
          throw LocalStoreUnavailableException(isStorageFullError(error)
              ? LocalStoreFailureKind.upgradeStorageFull
              : LocalStoreFailureKind.upgradeFailed);
        }
        // SQLite cannot tell a wrong key from a damaged file. Either way the
        // file is left exactly as it is.
        try {
          await database?.close();
        } catch (_) {}
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyRejected);
      }
      if (existingOnly) {
        try {
          if (await database.readMetadata(_migrationMarker) != '1' ||
              await _storage.read(key: _legacyRecordKeyName) != null) {
            throw const ExistingDatabaseUnavailable();
          }
        } catch (_) {
          try {
            await database.close();
          } catch (_) {}
          rethrow;
        }
      } else {
        try {
          await _migrateLegacyRecord(database);
        } catch (error) {
          // The key opened the file, but this open still fails, so the handle
          // is closed as after a failed upgrade. Nothing was deleted: the
          // legacy record stays, and a retry runs the migration again.
          try {
            await database.close();
          } catch (_) {}
          if (error is LocalStoreUnavailableException) rethrow;
          throw LocalStoreUnavailableException(isStorageFullError(error)
              ? LocalStoreFailureKind.upgradeStorageFull
              : LocalStoreFailureKind.upgradeFailed);
        }
        await _repairEnvelopeExpiry(database);
      }
      // Again now that the database, WAL and SHM files exist.
      await _excludeFromBackup(directory);
      return database;
    } finally {
      await releaseLocks();
    }
  }

  /// Keeps the profile directory (and with it every later WAL, SHM, lock
  /// and quarantined copy) and the database files out of platform backups.
  /// Runs before and after each open; the platform skips paths that do not
  /// exist yet and tries every path even when one fails. Best effort: the
  /// database cannot be opened elsewhere without its device-only key, so a
  /// failure here does not stop the app.
  Future<void> _excludeFromBackup(Directory directory) async {
    final exclude = _backupExclusion;
    if (exclude == null) return;
    try {
      await exclude(<String>[
        directory.path,
        for (final name in _databaseFileNames)
          '${directory.path}${Platform.pathSeparator}$name',
      ]);
    } catch (_) {
      // Retried on the next open.
    }
  }

  /// Writes a new key for a profile that has no database yet and reads it
  /// back; the database is created only after the key is confirmed stored.
  Future<String> _createKey() async {
    final keyHex = _randomHexKey();
    try {
      await _storage.write(key: _databaseKeyName, value: keyHex);
      if (await _storage.read(key: _databaseKeyName) != keyHex) {
        throw StateError('key write not confirmed');
      }
    } catch (_) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.keyWriteFailed);
    }
    return keyHex;
  }

  /// Holds an OS lock on the profile directory for the life of the process,
  /// so a second window on the same profile fails at open instead of both
  /// advancing the same MLS state.
  /// Releases every profile lock this process holds. Tests call it before
  /// removing a profile directory, which Windows refuses while a lock file
  /// is open.
  @visibleForTesting
  static Future<void> releaseInstanceLocks() async {
    final handles = _instanceLocks.values.toList();
    _instanceLocks.clear();
    for (final handle in handles) {
      await handle.close();
    }
  }

  /// Closes this store's database and gives up its profile's instance lock,
  /// so the account switcher can open another slot (B7). The close is final:
  /// work of the torn-down account that outlives its drain gets
  /// [LocalStoreUnavailableException] and never reopens, or after a removal
  /// recreates, that slot's database. A slot opened again gets a new store.
  Future<void> close() async {
    _closed = true;
    final opening = _openingDatabase;
    _openingDatabase = null;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {
        // An open that failed holds nothing to close.
      }
    }
    final path = _databasePath;
    if (path != null) {
      final directory = File(path).parent.path;
      final handle = _instanceLocks
          .remove('$directory${Platform.pathSeparator}veritra-instance.lock');
      await handle?.close();
    }
  }

  static Future<void> _holdInstanceLock(Directory directory) async {
    final path =
        '${directory.path}${Platform.pathSeparator}veritra-instance.lock';
    if (_instanceLocks.containsKey(path)) return;
    final handle = await File(path).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      throw StateError('another Veritra window is using this profile');
    }
    _instanceLocks[path] = handle;
  }

  /// Moves the legacy secure-storage record into the database once. A
  /// record that cannot be read throws [LocalStoreFailureKind.keyUnavailable];
  /// a corrupt record or a failed check throws for the caller to classify.
  /// The record is deleted only after the check passed and the marker was
  /// written.
  Future<void> _migrateLegacyRecord(EncryptedLocalDatabase database) async {
    // The marker first: once the migration finished, a keystore that cannot
    // be read must not stop the database from opening. Removing a leftover
    // record is then best effort; a later open tries again.
    if (await database.readMetadata(_migrationMarker) == '1') {
      try {
        if (await _storage.read(key: _legacyRecordKeyName) != null) {
          await _storage.delete(key: _legacyRecordKeyName);
        }
      } catch (_) {}
      return;
    }
    final String? raw;
    try {
      raw = await _storage.read(key: _legacyRecordKeyName);
    } catch (_) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.keyUnavailable);
    }
    if (raw == null || raw.isEmpty) {
      await database.writeMetadata(_migrationMarker, '1');
      return;
    }

    final legacy = _parseLegacyRecord(raw);
    await database.importLegacy(
      sessionJson: legacy.sessionJson,
      conversations: legacy.conversations,
      envelopes: legacy.envelopes,
      outbox: legacy.outbox,
      cryptoState: legacy.cryptoState,
      cursor: legacy.cursor,
    );
    await _verifyLegacyMigration(database, legacy);
    await database.writeMetadata(_migrationMarker, '1');
    try {
      await _storage.delete(key: _legacyRecordKeyName);
    } catch (_) {
      // Migrated and marked: the next open removes the leftover record.
    }
  }

  /// Runs after the legacy migration has finished or found nothing to do,
  /// and before anything reads the next expiry. Best effort: a failure
  /// writes no marker, so the repair runs again on the next open, and the
  /// database still opens.
  static Future<void> _repairEnvelopeExpiry(
      EncryptedLocalDatabase database) async {
    try {
      await database.repairNullEnvelopeExpiry();
    } catch (_) {}
  }

  Future<void> _verifyLegacyMigration(
    EncryptedLocalDatabase database,
    _LegacyDatabasePayload legacy,
  ) async {
    if (await database.readSessionJson() != legacy.sessionJson ||
        await database.readCursor() != legacy.cursor) {
      throw StateError('legacy local-state migration verification failed');
    }
    final snapshot = await database.readSnapshotJson();
    if (!_stringListsEqual(
          snapshot.conversationJson,
          legacy.conversations.map((item) => item.payloadJson).toList(),
        ) ||
        !_stringMapListsEqual(
          snapshot.envelopeJson,
          _legacyEnvelopeMap(legacy.envelopes),
        ) ||
        !_stringListsEqual(
          await database.readOutboxJson(),
          legacy.outbox.map((item) => item.payloadJson).toList(),
        )) {
      throw StateError('legacy local-state migration verification failed');
    }
    final crypto = await database.readCryptoState();
    if (!_cryptoRecordsEqual(crypto, legacy.cryptoState)) {
      throw StateError('legacy local-state migration verification failed');
    }
  }
}

typedef _StoredConversation = ({String id, String payloadJson});
typedef _StoredEnvelope = ({
  String id,
  String conversationId,
  int position,
  String payloadJson,
});
typedef _StoredOutboxEntry = ({
  String idempotencyKey,
  String conversationId,
  int queuedAt,
  String payloadJson,
});
typedef _StoredCryptoRecord = ({
  int counter,
  List<int> stateKey,
  List<int> sealedState,
});

class _LegacyDatabasePayload {
  const _LegacyDatabasePayload({
    required this.sessionJson,
    required this.conversations,
    required this.envelopes,
    required this.outbox,
    required this.cryptoState,
    required this.cursor,
  });

  final String? sessionJson;
  final List<_StoredConversation> conversations;
  final List<_StoredEnvelope> envelopes;
  final List<_StoredOutboxEntry> outbox;
  final _StoredCryptoRecord? cryptoState;
  final int cursor;
}

_LegacyDatabasePayload _parseLegacyRecord(String raw) {
  try {
    final record = Map<String, Object?>.from(jsonDecode(raw) as Map);
    final cursor = (record['cursor'] as num?)?.toInt() ?? 0;
    if (cursor < 0) throw const FormatException('invalid cursor');

    String? sessionJson;
    final rawSession = record['session'];
    if (rawSession != null) {
      final sessionMap = Map<String, Object?>.from(rawSession as Map);
      if (_sessionFrom(sessionMap) == null) {
        throw const FormatException('invalid session');
      }
      sessionJson = jsonEncode(sessionMap);
    }

    final conversations = <_StoredConversation>[];
    final envelopes = <_StoredEnvelope>[];
    final rawSnapshot = record['snapshot'];
    if (rawSnapshot != null) {
      final snapshot = Map<String, Object?>.from(rawSnapshot as Map);
      for (final item in snapshot['conversations'] as List? ?? const []) {
        final payload = Map<String, Object?>.from(item as Map);
        final conversation = Conversation.fromJson(payload);
        conversations.add((
          id: conversation.id,
          payloadJson: jsonEncode(payload),
        ));
      }
      final rawMessages = snapshot['messages'];
      if (rawMessages != null) {
        final messages = Map<Object?, Object?>.from(rawMessages as Map);
        for (final entry in messages.entries) {
          final conversationId = entry.key.toString();
          var position = 0;
          for (final item in entry.value as List) {
            final payload = Map<String, Object?>.from(item as Map);
            final envelope = ReceivedMessageEnvelope.fromJson(payload);
            envelopes.add((
              id: envelope.id,
              conversationId: conversationId,
              position: position++,
              payloadJson: jsonEncode(payload),
            ));
          }
        }
      }
    }

    final outbox = <_StoredOutboxEntry>[];
    var queuedAt = 0;
    for (final item in record['outbox'] as List? ?? const []) {
      final payload = Map<String, Object?>.from(item as Map);
      final envelope = MessageEnvelope.fromJson(payload);
      outbox.add((
        idempotencyKey: envelope.idempotencyKey,
        conversationId: envelope.conversationId,
        queuedAt: queuedAt++,
        payloadJson: jsonEncode(payload),
      ));
    }

    _StoredCryptoRecord? cryptoState;
    if (record.containsKey('crypto_state')) {
      final parsed = _cryptoStateFrom(record['crypto_state']);
      if (parsed == null) throw const FormatException('invalid crypto state');
      cryptoState = (
        counter: parsed.counter,
        stateKey: parsed.stateKey,
        sealedState: parsed.sealedState,
      );
    }
    return _LegacyDatabasePayload(
      sessionJson: sessionJson,
      conversations: conversations,
      envelopes: envelopes,
      outbox: outbox,
      cryptoState: cryptoState,
      cursor: cursor,
    );
  } catch (_) {
    throw StateError('legacy local state is corrupt');
  }
}

Session? _sessionFromJson(String? raw) {
  if (raw == null) return null;
  return _sessionFrom(_decodeJsonMap(raw));
}

Map<String, Object?> _decodeJsonMap(String raw) =>
    Map<String, Object?>.from(jsonDecode(raw) as Map);

String _randomHexKey() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var index = 0; index < 32; index++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Map<String, List<String>> _legacyEnvelopeMap(
  Iterable<_StoredEnvelope> envelopes,
) {
  final result = <String, List<String>>{};
  for (final envelope in envelopes) {
    (result[envelope.conversationId] ??= <String>[]).add(envelope.payloadJson);
  }
  return result;
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _stringMapListsEqual(
  Map<String, List<String>> left,
  Map<String, List<String>> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    final expected = right[entry.key];
    if (expected == null || !_stringListsEqual(entry.value, expected)) {
      return false;
    }
  }
  return true;
}

bool _cryptoRecordsEqual(
  ({int counter, List<int> stateKey, List<int> sealedState})? left,
  _StoredCryptoRecord? right,
) {
  if (left == null || right == null) return left == null && right == null;
  return left.counter == right.counter &&
      _bytesEqual(left.stateKey, right.stateKey) &&
      _bytesEqual(left.sealedState, right.sealedState);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

String _identity(Session session) =>
    '${session.baseUrl}|${session.accountId ?? ''}|${session.deviceId ?? ''}';

/// Whether saving [next] over [previous] changes the identity, which drops
/// that identity's local state.
bool _identityChanged(Session previous, Session next) =>
    _identity(previous) != _identity(next);

Map<String, Object?> _sessionJson(Session session) => <String, Object?>{
      'base_url': session.baseUrl,
      'token': session.token,
      if (session.accountId != null) 'account_id': session.accountId,
      if (session.deviceId != null) 'device_id': session.deviceId,
      if (session.username != null) 'username': session.username,
      if (session.deviceSecret != null) 'device_secret': session.deviceSecret,
      if (session.role != null) 'role': session.role,
    };

Session? _sessionFrom(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final session = Map<String, Object?>.from(raw);
  final baseUrl = session['base_url'] as String?;
  final token = session['token'] as String?;
  if (baseUrl == null || token == null) {
    return null;
  }
  return Session(
    baseUrl: baseUrl,
    token: token,
    accountId: session['account_id'] as String?,
    deviceId: session['device_id'] as String?,
    username: session['username'] as String?,
    deviceSecret: session['device_secret'] as String?,
    role: session['role'] as String?,
  );
}

StoredCryptoState? _cryptoStateFrom(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  try {
    final json = Map<String, Object?>.from(raw);
    final state = StoredCryptoState(
      counter: (json['counter'] as num).toInt(),
      stateKey: base64Decode(json['state_key'] as String),
      sealedState: base64Decode(json['sealed_state'] as String),
    );
    _validateCryptoState(state);
    return state;
  } catch (_) {
    return null;
  }
}

StoredCryptoState _copyCryptoState(StoredCryptoState state) =>
    StoredCryptoState(
      counter: state.counter,
      stateKey: List<int>.from(state.stateKey),
      sealedState: List<int>.from(state.sealedState),
    );

StoredCryptoRecord _copyCryptoRecord(StoredCryptoRecord r) =>
    StoredCryptoRecord(
      kind: r.kind,
      recordId: List<int>.from(r.recordId),
      generation: r.generation,
      sealed: List<int>.from(r.sealed),
    );

/// Sorts like SQLite's (kind, record_id BLOB) order: hex keeps byte order.
String _cryptoRecordKey(int kind, List<int> recordId) =>
    '${kind.toString().padLeft(5, '0')}:'
    '${recordId.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

void _validateCryptoState(StoredCryptoState state) {
  if (state.counter <= 0 ||
      state.stateKey.length != 32 ||
      state.sealedState.isEmpty ||
      state.sealedState.length > 32 * 1024 * 1024) {
    throw const FormatException('invalid protected crypto state');
  }
  // Each change belongs to this state's generation, and names one record
  // once (D70).
  final seen = <String>{};
  for (final change in state.changes) {
    final sealed = change.sealed;
    if (change.kind < cryptoRecordKindDevice ||
        change.kind > cryptoRecordKindKeyPackage ||
        change.generation != state.counter ||
        change.recordId.length > _maxCryptoRecordIdBytes ||
        (change.kind == cryptoRecordKindDevice) != change.recordId.isEmpty ||
        (sealed != null &&
            (sealed.isEmpty || sealed.length > maxSealedCryptoRecordBytes)) ||
        !seen.add(_cryptoRecordKey(change.kind, change.recordId))) {
      throw const FormatException('invalid protected crypto record');
    }
  }
}

/// A migration writes a complete state: a device record, and no deletes.
void _validateCryptoMigration(StoredCryptoState state) {
  _validateCryptoState(state);
  if (state.changes.any((change) => change.sealed == null) ||
      !state.changes.any((change) => change.kind == cryptoRecordKindDevice)) {
    throw const FormatException('invalid crypto state migration');
  }
}

void _validatePeerVerification(
    String conversationId, String peerAccountId, List<int> transcriptHash) {
  if (conversationId.isEmpty ||
      peerAccountId.isEmpty ||
      conversationId.length > 128 ||
      peerAccountId.length > 128 ||
      // A safety-number version byte, then the SHA-256 transcript hash.
      transcriptHash.length != 33) {
    throw const FormatException('invalid peer verification state');
  }
}

void _validateMlsTransition(
  MlsStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
  bool allowBehindCursor = false,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      (transition.cursor <= currentCursor && !allowBehindCursor)) {
    throw StateError('stale or incomplete MLS state transition');
  }
  if (transition.messageId.isEmpty || transition.conversationId.isEmpty) {
    throw const FormatException('invalid MLS transition binding');
  }
  final deleted = transition.deletedEnvelopeIds.toSet();
  if (deleted.length != transition.deletedEnvelopeIds.length ||
      deleted.any((id) => id.isEmpty) ||
      transition.upsertedEnvelopes.any(
        (envelope) => envelope.id.isEmpty || deleted.contains(envelope.id),
      )) {
    throw const FormatException('invalid MLS ciphertext transition');
  }
}

void _validateOutgoingMlsTransition(
  OutgoingMlsStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      transition.messages.isEmpty) {
    throw StateError('stale or incomplete outgoing MLS transition');
  }
  final keys = <String>{};
  for (final message in transition.messages) {
    if (message.idempotencyKey.isEmpty ||
        !keys.add(message.idempotencyKey) ||
        message.conversationId.isEmpty ||
        (message.kind != 'welcome' &&
            message.kind != 'commit' &&
            message.kind != 'bundle') ||
        (message.kind == 'welcome' &&
            (message.recipientDeviceId?.isEmpty ?? true)) ||
        message.payload.isEmpty ||
        message.payload.length > 4 * 1024 * 1024) {
      throw const FormatException('invalid MLS outbox transition');
    }
  }
}

void _validateOutgoingApplicationTransition(
  OutgoingApplicationStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      transition.envelope.idempotencyKey.isEmpty ||
      transition.envelope.conversationId.isEmpty ||
      transition.envelope.ciphertext.isEmpty) {
    throw StateError('stale or incomplete outgoing application transition');
  }
}

void _validateLocalMlsState(
  int expectedCounter,
  int expectedCursor,
  StoredCryptoState state, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(state);
  if (expectedCounter != currentCounter ||
      expectedCursor != currentCursor ||
      state.counter != currentCounter + 1) {
    throw StateError('stale local MLS transition');
  }
}
