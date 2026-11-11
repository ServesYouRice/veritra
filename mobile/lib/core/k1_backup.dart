import 'dart:convert';
import 'dart:typed_data';

/// K1 automatic backups (docs/designs/K1-automatic-backups.md, D91): the
/// device's backup state and schedule. Pure, so the rules are unit tested
/// apart from [AppState].
///
/// Everything here lives in the encrypted local metadata under
/// [k1BackupStateSetting]. No `k1.*` setting is ever in a backup or a
/// history snapshot: `rk_pub` would let anyone forge a backup that restores.
const String k1BackupStateSetting = 'k1.state';

/// The setting of one identity (server, account, device), so signing in
/// to another account on this device never overwrites its key or counter.
String k1BackupSettingName(String baseUrl, String accountId, String deviceId) =>
    '$k1BackupStateSetting|$baseUrl|$accountId|$deviceId';

/// Every K1 local setting starts with this; the leak test scans for it.
const String k1SettingPrefix = 'k1.';

/// The plaintext of a K1 backup is the K2 history snapshot, version 1.
const int k1BackupPlaintextVersion = 1;

/// How old the last good copy may get before the next run is due.
const Duration k1BackupInterval = Duration(hours: 24);

/// After this long with no success the app warns (design: "a week").
const Duration k1BackupStaleAfter = Duration(days: 7);

/// Key confirmation (design): 3 days after setup, 14 days after that, then
/// every 90 days; "Not now" waits 7 days; three misses keep a badge.
const Duration k1ConfirmFirst = Duration(days: 3);
const Duration k1ConfirmSecond = Duration(days: 14);
const Duration k1ConfirmLater = Duration(days: 90);
const Duration k1ConfirmPostpone = Duration(days: 7);
const int k1ConfirmBadgeMisses = 3;

/// The onboarding prompt (D49) asks again this long after "Not now".
const Duration k1KeyPromptSnooze = Duration(days: 3);

/// Why the last run failed. Only the kind is kept, never a message.
enum K1BackupError {
  /// Offline, a timeout or a server error: retried with backoff.
  network,

  /// The account's backup allowance is full (507).
  spaceFull,

  /// The history is above the 64 MiB cap: the last good copy is kept and
  /// nothing smaller is sent silently.
  tooLarge,

  /// The account's recovery key changed: backups pause until the new key is
  /// typed on this device (K0 rotation step 4).
  keyChanged,

  /// The server has backups turned off (no public origin, D91).
  unavailable,

  /// Anything else.
  failed,
}

/// What the settings tile shows.
enum K1BackupView {
  /// Unknown yet (status not read), or this build cannot back up.
  unknown,

  /// The server has recovery and backups turned off.
  serverOff,

  /// The account has no recovery key: offer to create one.
  noKey,

  /// The account has a recovery key this device has not been given:
  /// "Type your recovery key to turn on backups here".
  needsKeyHere,

  /// Backups run on this device.
  on,
}

/// Retry delays after a failed run: 1 h, 4 h, then a day.
Duration k1BackupBackoff(int failures) {
  if (failures <= 1) return const Duration(hours: 1);
  if (failures == 2) return const Duration(hours: 4);
  return const Duration(hours: 24);
}

/// The device's K1 state, scoped to one account and device on one server,
/// so a later sign-in to another account never uses (or shows) it.
class K1BackupState {
  K1BackupState({
    required this.baseUrl,
    required this.accountId,
    required this.deviceId,
    this.rkPub,
    this.rkId,
    this.counter = 0,
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.lastError,
    this.failures = 0,
    this.nextAttemptAt,
    this.keyPromptSnoozedUntil,
    this.keySetAt,
    this.confirmDueAt,
    this.confirmedCount = 0,
    this.confirmMisses = 0,
    this.secondCopyPath,
    this.secondCopyAt,
    this.secondCopyFailed = false,
  });

  final String baseUrl;
  final String accountId;
  final String deviceId;

  /// The recovery key's HPKE public key and id, stored only after the user
  /// typed the key on this device. Null: this device backs up nothing.
  Uint8List? rkPub;
  Uint8List? rkId;

  /// The last counter this device used. Strictly increasing and kept across
  /// recovery-key changes; committed before each upload, so a crash leaves a
  /// gap, never a reuse.
  int counter;

  DateTime? lastSuccessAt;
  DateTime? lastAttemptAt;
  K1BackupError? lastError;
  int failures;
  DateTime? nextAttemptAt;
  DateTime? keyPromptSnoozedUntil;

  /// When this device was given the current key: the anchor for the
  /// week-without-a-backup warning before any copy succeeded.
  DateTime? keySetAt;

  /// Key confirmation schedule (typed locally, nothing leaves the device).
  DateTime? confirmDueAt;
  int confirmedCount;
  int confirmMisses;

  /// The second copy folder the user picked (desktop), when it was last
  /// written, and whether the last write failed (a warning of its own; it
  /// never fails the backup).
  String? secondCopyPath;
  DateTime? secondCopyAt;
  bool secondCopyFailed;

  bool get hasKey => rkPub != null && rkId != null;

  /// The user is asked to type the key again.
  bool confirmDue(DateTime now) {
    final due = confirmDueAt;
    return hasKey && due != null && !now.isBefore(due);
  }

  /// Three misses or postpones: a Settings badge stays until confirmed.
  bool get confirmBadge => hasKey && confirmMisses >= k1ConfirmBadgeMisses;

  /// The typed key matched: next ask 14 days on after the first, then 90.
  void recordConfirmed(DateTime now) {
    confirmedCount++;
    confirmMisses = 0;
    confirmDueAt =
        now.add(confirmedCount == 1 ? k1ConfirmSecond : k1ConfirmLater);
  }

  /// "Not now": ask again in 7 days.
  void postponeConfirm(DateTime now) {
    confirmMisses++;
    confirmDueAt = now.add(k1ConfirmPostpone);
  }

  bool belongsTo(String baseUrl, String accountId, String deviceId) =>
      this.baseUrl == baseUrl &&
      this.accountId == accountId &&
      this.deviceId == deviceId;

  /// Whether a run should start now: a key is set, the last good copy is a
  /// day old (or there is none), and no backoff is pending. A changed key
  /// waits for the user, not the clock; other errors retry with backoff.
  bool isDue(DateTime now) {
    if (!hasKey) return false;
    if (lastError == K1BackupError.keyChanged) return false;
    final next = nextAttemptAt;
    if (next != null && now.isBefore(next)) return false;
    final last = lastSuccessAt;
    return last == null || !now.isBefore(last.add(k1BackupInterval));
  }

  /// No good copy for a week while backups are on.
  bool isStale(DateTime now) {
    if (!hasKey) return false;
    final anchor = lastSuccessAt ?? keySetAt;
    return anchor != null && !now.isBefore(anchor.add(k1BackupStaleAfter));
  }

  void recordSuccess(DateTime now) {
    lastSuccessAt = now;
    lastAttemptAt = now;
    lastError = null;
    failures = 0;
    nextAttemptAt = null;
  }

  void recordFailure(K1BackupError error, DateTime now) {
    lastAttemptAt = now;
    lastError = error;
    failures++;
    nextAttemptAt = now.add(k1BackupBackoff(failures));
  }

  /// Stores a key typed on this device. A new key clears the error and the
  /// backoff, so the first copy under it runs at once.
  void setKey(Uint8List rkPub, Uint8List rkId, [DateTime? at]) {
    wipeKey();
    keySetAt = at;
    this.rkPub = Uint8List.fromList(rkPub);
    this.rkId = Uint8List.fromList(rkId);
    confirmedCount = 0;
    confirmMisses = 0;
    confirmDueAt = at?.add(k1ConfirmFirst);
    lastError = null;
    failures = 0;
    nextAttemptAt = null;
    lastSuccessAt = null;
  }

  void wipeKey() {
    rkPub?.fillRange(0, rkPub!.length, 0);
    rkPub = null;
    rkId = null;
  }

  String encode() => jsonEncode(<String, Object?>{
        'v': 1,
        'base_url': baseUrl,
        'account_id': accountId,
        'device_id': deviceId,
        if (rkPub != null) 'rk_pub': base64.encode(rkPub!),
        if (rkId != null) 'rk_id': base64.encode(rkId!),
        'counter': counter,
        if (lastSuccessAt != null)
          'last_success_at': lastSuccessAt!.millisecondsSinceEpoch,
        if (lastAttemptAt != null)
          'last_attempt_at': lastAttemptAt!.millisecondsSinceEpoch,
        if (lastError != null) 'last_error': lastError!.name,
        'failures': failures,
        if (nextAttemptAt != null)
          'next_attempt_at': nextAttemptAt!.millisecondsSinceEpoch,
        if (keySetAt != null) 'key_set_at': keySetAt!.millisecondsSinceEpoch,
        if (confirmDueAt != null)
          'confirm_due_at': confirmDueAt!.millisecondsSinceEpoch,
        'confirmed_count': confirmedCount,
        'confirm_misses': confirmMisses,
        if (secondCopyPath != null) 'second_copy_path': secondCopyPath,
        if (secondCopyAt != null)
          'second_copy_at': secondCopyAt!.millisecondsSinceEpoch,
        if (secondCopyFailed) 'second_copy_failed': true,
        if (keyPromptSnoozedUntil != null)
          'key_prompt_snoozed_until':
              keyPromptSnoozedUntil!.millisecondsSinceEpoch,
      });

  /// Reads a stored state. Anything malformed reads as null (backups off on
  /// this device until the key is typed again), never as a guess. A state
  /// whose key is malformed keeps its counter but drops the key.
  static K1BackupState? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != 1) return null;
      final baseUrl = json['base_url'], account = json['account_id'];
      final device = json['device_id'], counter = json['counter'];
      if (baseUrl is! String ||
          account is! String ||
          device is! String ||
          counter is! int ||
          counter < 0) {
        return null;
      }
      final state = K1BackupState(
        baseUrl: baseUrl,
        accountId: account,
        deviceId: device,
        counter: counter,
        lastSuccessAt: _time(json['last_success_at']),
        lastAttemptAt: _time(json['last_attempt_at']),
        lastError: _error(json['last_error']),
        failures: json['failures'] is int && (json['failures'] as int) >= 0
            ? json['failures'] as int
            : 0,
        nextAttemptAt: _time(json['next_attempt_at']),
        keyPromptSnoozedUntil: _time(json['key_prompt_snoozed_until']),
        keySetAt: _time(json['key_set_at']),
        confirmDueAt: _time(json['confirm_due_at']),
        confirmedCount:
            json['confirmed_count'] is int && json['confirmed_count'] >= 0
                ? json['confirmed_count'] as int
                : 0,
        confirmMisses:
            json['confirm_misses'] is int && json['confirm_misses'] >= 0
                ? json['confirm_misses'] as int
                : 0,
        secondCopyPath: json['second_copy_path'] is String
            ? json['second_copy_path'] as String
            : null,
        secondCopyAt: _time(json['second_copy_at']),
        secondCopyFailed: json['second_copy_failed'] == true,
      );
      final rkPub = _bytes(json['rk_pub'], 32),
          rkId = _bytes(json['rk_id'], 16);
      if (rkPub != null && rkId != null) {
        state.rkPub = rkPub;
        state.rkId = rkId;
      }
      return state;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _time(Object? value) => value is int && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
      : null;

  static K1BackupError? _error(Object? value) {
    for (final error in K1BackupError.values) {
      if (error.name == value) return error;
    }
    return null;
  }

  static Uint8List? _bytes(Object? value, int length) {
    if (value is! String) return null;
    try {
      final bytes = base64.decode(value);
      return bytes.length == length ? bytes : null;
    } catch (_) {
      return null;
    }
  }
}

/// The view for the settings tile, from the server's status (null: not
/// read yet) and this device's state.
K1BackupView computeK1BackupView({
  required bool? serverAvailable,
  required bool? accountConfigured,
  required List<int>? accountRkId,
  required K1BackupState? state,
}) {
  if (serverAvailable == null) {
    return state?.hasKey == true ? K1BackupView.on : K1BackupView.unknown;
  }
  if (!serverAvailable) return K1BackupView.serverOff;
  if (accountConfigured != true) return K1BackupView.noKey;
  if (state == null || !state.hasKey) return K1BackupView.needsKeyHere;
  if (accountRkId != null && !_sameBytes(accountRkId, state.rkId!)) {
    return K1BackupView.needsKeyHere;
  }
  return K1BackupView.on;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Whether the onboarding prompt "Save your recovery key" (D49) shows: the
/// server has recovery on, the account has no key yet, and the user has not
/// said "Not now" within the last three days.
bool k1ShouldPromptForKey({
  required bool? serverAvailable,
  required bool? accountConfigured,
  required K1BackupState? state,
  required DateTime now,
}) {
  if (serverAvailable != true || accountConfigured != false) return false;
  final snoozed = state?.keyPromptSnoozedUntil;
  return snoozed == null || !now.isBefore(snoozed);
}
