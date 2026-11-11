part of 'app_state.dart';

// K1 automatic backups on the client (docs/designs/K1-automatic-backups.md,
// K1-3, D91). After the recovery key is saved on this device the app seals
// the history snapshot to the key's public half and uploads it once a day,
// replacing the copy before. The key itself never stays on the device: only
// rk_pub and rk_id, which cannot open a backup. A backup never blocks
// sending or sync, and nothing here logs a key, a token or history.

extension K1BackupActions on AppState {
  /// Whether this build can make K1 backups: the native engine with the
  /// backup seal (ABI 19) and recovery keys.
  bool get k1BackupSupported =>
      recoveryAvailable && cryptoService is BackupSealCryptoService;

  /// What the settings tile shows.
  K1BackupView get k1BackupView {
    if (!k1BackupSupported) return K1BackupView.unknown;
    final status = recoveryKeyStatus;
    return computeK1BackupView(
      serverAvailable: status?.available,
      accountConfigured: status?.configured,
      accountRkId: status?.rkId,
      state: _k1StateForSession(),
    );
  }

  /// This device's backup state for the signed-in account, or null.
  K1BackupState? get k1BackupState => _k1StateForSession();

  /// No good copy for a week while backups are on (design: warn).
  bool get k1BackupStale =>
      k1BackupView == K1BackupView.on &&
      (_k1StateForSession()?.isStale(k1Clock()) ?? false);

  /// Whether to show "Save your recovery key" (D49): offered once the server
  /// has recovery on and the account has no key; "Not now" waits 3 days.
  bool get k1ShouldOfferRecoveryKey {
    if (!k1BackupSupported) return false;
    final status = recoveryKeyStatus;
    return k1ShouldPromptForKey(
      serverAvailable: status?.available,
      accountConfigured: status?.configured,
      state: _k1StateForSession(),
      now: k1Clock(),
    );
  }

  /// Settings badge: the user skipped the prompt, or this device needs the
  /// key typed, or backups have failed for a week.
  bool get k1BackupNeedsAttention {
    final view = k1BackupView;
    return view == K1BackupView.noKey ||
        view == K1BackupView.needsKeyHere ||
        k1ConfirmBadge ||
        k1BackupStale;
  }

  /// "Not now" on the onboarding prompt: ask again after three days.
  Future<void> snoozeRecoveryKeyPrompt() async {
    final state = _k1StateOrNew();
    if (state == null) return;
    state.keyPromptSnoozedUntil = k1Clock().add(k1KeyPromptSnooze);
    await _saveK1State(state);
    notifyListeners();
  }

  /// "Type your recovery key to turn on backups here": checks [typed]
  /// against the account's current key id (nothing leaves the device),
  /// then stores rk_pub and rk_id and starts the first backup. Returns
  /// false for a key that is not the account's (the screen never says
  /// which characters were wrong).
  Future<bool> enableK1BackupsWithKey(String typed) async {
    if (!k1BackupSupported) return false;
    final crypto = _recoveryCrypto;
    await refreshRecoveryKeyStatus();
    final status = recoveryKeyStatus;
    final accountRkId = status?.rkId;
    if (status == null || !status.available || accountRkId == null) {
      return false;
    }
    final Uint8List entropy;
    try {
      entropy =
          await crypto.decodeRecoveryKey(normalizeRecoveryKeyInput(typed));
    } catch (_) {
      return false;
    }
    try {
      final values = await crypto.deriveRecoveryKey(entropy);
      try {
        if (!_constantTimeBytesEqual(values.rkId, accountRkId)) return false;
        await _storeK1Key(values.rkPub, values.rkId);
      } finally {
        values.rkPub.fillRange(0, values.rkPub.length, 0);
      }
    } finally {
      entropy.fillRange(0, entropy.length, 0);
    }
    unawaited(runK1BackupIfDue());
    return true;
  }

  /// Whether the user is asked to type the recovery key again (K1-5).
  bool get k1ConfirmDue =>
      k1BackupView == K1BackupView.on &&
      (_k1StateForSession()?.confirmDue(k1Clock()) ?? false);

  /// The Settings badge: the confirmation was missed three times.
  bool get k1ConfirmBadge =>
      k1BackupView == K1BackupView.on &&
      (_k1StateForSession()?.confirmBadge ?? false);

  /// The user typed the key to confirm it. Local only: the key's public half
  /// is derived and compared with the stored one. A match schedules the next
  /// ask; anything else (also a key that is not even valid) returns false
  /// and never says which characters were wrong.
  Future<bool> confirmK1Key(String typed) async {
    final state = _k1StateForSession();
    if (state == null || !state.hasKey || !k1BackupSupported) return false;
    final crypto = _recoveryCrypto;
    Uint8List? entropy;
    try {
      entropy =
          await crypto.decodeRecoveryKey(normalizeRecoveryKeyInput(typed));
      final values = await crypto.deriveRecoveryKey(entropy);
      try {
        if (!identical(_k1StateForSession(), state) ||
            !state.hasKey ||
            !_constantTimeBytesEqual(values.rkPub, state.rkPub!)) {
          return false;
        }
      } finally {
        values.rkPub.fillRange(0, values.rkPub.length, 0);
      }
    } catch (_) {
      return false;
    } finally {
      entropy?.fillRange(0, entropy.length, 0);
    }
    state.recordConfirmed(k1Clock());
    await _saveK1State(state);
    notifyListeners();
    return true;
  }

  /// "Not now" on the confirmation: ask again in 7 days.
  Future<void> postponeK1Confirm() async {
    final state = _k1StateForSession();
    if (state == null) return;
    state.postponeConfirm(k1Clock());
    await _saveK1State(state);
    notifyListeners();
  }

  /// Sets (or with null clears) the folder of the second copy, and writes
  /// the first copy with the next run.
  Future<void> setK1SecondCopyFolder(String? folder) async {
    final state = _k1StateForSession();
    if (state == null) return;
    state.secondCopyPath = folder;
    state.secondCopyAt = null;
    state.secondCopyFailed = false;
    await _saveK1State(state);
    notifyListeners();
    if (folder != null) unawaited(runK1BackupIfDue(force: true));
  }

  /// Runs a backup when one is due (a day since the last good copy, no
  /// backoff pending), or at once with [force] ("Back up now"). Never
  /// throws; the outcome is in [k1BackupState]. Returns whether a copy was
  /// uploaded.
  Future<bool> runK1BackupIfDue({bool force = false}) async {
    if (_k1Running || !k1BackupSupported) return false;
    final current = session;
    final client = api;
    if (current == null ||
        client == null ||
        current.token.isEmpty ||
        current.accountId == null ||
        current.deviceId == null) {
      return false;
    }
    if (_k1State == null) await _loadK1State();
    final state = _k1StateForSession();
    if (state == null || !state.hasKey) return false;
    final now = k1Clock();
    if (!force && !state.isDue(now)) return false;
    _k1Running = true;
    _k1RerunRequested = false;
    notifyListeners();
    // The run works on copies of the key: a key typed or replaced while it
    // is under way never mixes into this run's seal or metadata.
    final key = _K1RunKey(
        Uint8List.fromList(state.rkPub!), Uint8List.fromList(state.rkId!));
    K1BackupError? error;
    try {
      error = await _k1BackupOnce(current, client, state, key);
    } catch (_) {
      // An export, seal or local store failure: recorded, with backoff.
      error = K1BackupError.failed;
    } finally {
      key.wipe();
    }
    try {
      // Record the outcome only for the key this run used, on the state of
      // the signed-in identity. A key changed meanwhile starts over below.
      if (identical(_k1StateForSession(), state) &&
          state.hasKey &&
          _constantTimeBytesEqual(state.rkId!, key.rkId)) {
        if (error == null) {
          state.recordSuccess(k1Clock());
        } else {
          state.recordFailure(error, k1Clock());
        }
        await _saveK1State(state);
      }
    } catch (_) {
      // The session ended or the store went away: nothing to record.
    } finally {
      _k1Running = false;
      notifyListeners();
      if (_k1RerunRequested) {
        _k1RerunRequested = false;
        unawaited(runK1BackupIfDue(force: true));
      }
    }
    return error == null;
  }

  /// True while a run is under way.
  bool get k1BackupRunning => _k1Running;

  // ------------------------------------------------------------ internal ---

  /// One run (design, "What one run does"). Returns the error kind, or null
  /// on success.
  Future<K1BackupError?> _k1BackupOnce(Session current, ApiClient client,
      K1BackupState state, _K1RunKey key) async {
    final seal = cryptoService as BackupSealCryptoService;
    // 1. Check the key: a changed key pauses until it is typed here.
    final RecoveryKeyStatus status;
    try {
      status = await client.recoveryKeyStatus(current.token);
    } on ApiException catch (err) {
      return err.statusCode == 401
          ? K1BackupError.failed
          : K1BackupError.network;
    } catch (_) {
      return K1BackupError.network;
    }
    if (!identical(session, current)) return K1BackupError.failed;
    recoveryKeyStatus = status;
    if (!status.available) return K1BackupError.unavailable;
    final accountRkId = status.rkId;
    if (!status.configured ||
        accountRkId == null ||
        !_constantTimeBytesEqual(accountRkId, key.rkId)) {
      return K1BackupError.keyChanged;
    }
    // 2. Build the snapshot, without disappearing messages.
    final plaintext = _k1Bytes(
        await localStore.exportHistorySnapshot(omitDisappearing: true));
    Uint8List? ciphertext;
    try {
      if (plaintext.length > seal.k1BackupMaxPlaintextBytes) {
        return K1BackupError.tooLarge;
      }
      // 3. Commit the counter before the upload: after a crash the next run
      // uses a higher one, so a counter is never used twice.
      state.counter++;
      await _saveK1State(state);
      ciphertext = await seal.sealK1Backup(
        accountId: current.accountId!,
        sourceDeviceId: current.deviceId!,
        createdAtMs: k1Clock().millisecondsSinceEpoch,
        counter: state.counter,
        rkPub: key.rkPub,
        plaintext: plaintext,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    // 4. Upload. A stale counter (this device's state was lost) jumps ahead
    // and tries once more.
    try {
      for (var attempt = 0;; attempt++) {
        final error =
            await _k1Upload(client, current, key, state.counter, ciphertext!);
        if (error == null) {
          await _k1WriteSecondCopy(state, current, ciphertext);
        }
        if (error != _k1CounterStale) return error as K1BackupError?;
        if (attempt > 0) return K1BackupError.failed;
        // This device's counter fell behind the server's high-water mark
        // (its local state was lost or restored). Jump past it: the clock
        // in milliseconds is above any counter a device reaches by days.
        state.counter =
            max(state.counter + 1, k1Clock().millisecondsSinceEpoch);
        await _saveK1State(state);
        final plain = _k1Bytes(
            await localStore.exportHistorySnapshot(omitDisappearing: true));
        try {
          ciphertext = await seal.sealK1Backup(
            accountId: current.accountId!,
            sourceDeviceId: current.deviceId!,
            createdAtMs: k1Clock().millisecondsSinceEpoch,
            counter: state.counter,
            rkPub: key.rkPub,
            plaintext: plain,
          );
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      }
    } catch (_) {
      return K1BackupError.network;
    } finally {
      ciphertext?.fillRange(0, ciphertext.length, 0);
    }
  }

  /// Uploads [ciphertext]; returns null on success, [_k1CounterStale] for a
  /// stale counter, or the error kind.
  Future<Object?> _k1Upload(ApiClient client, Session current, _K1RunKey key,
      int counter, Uint8List ciphertext) async {
    try {
      await client.uploadK1Backup(current.token, ciphertext,
          rkId: key.rkId, counter: counter);
      return null;
    } on ApiException catch (err) {
      switch (err.serverCode) {
        case 'backup_counter_stale':
          return _k1CounterStale;
        case 'recovery_key_changed':
          return K1BackupError.keyChanged;
        case 'recovery_not_configured':
          return K1BackupError.unavailable;
        case 'storage_quota_exceeded':
          return K1BackupError.spaceFull;
        case 'server_storage_low':
          // The server's disk, not this account's allowance: retried.
          return K1BackupError.network;
      }
      if (err.statusCode == 507) return K1BackupError.spaceFull;
      if (err.statusCode >= 500 || err.statusCode == 429) {
        return K1BackupError.network;
      }
      return K1BackupError.failed;
    }
  }

  /// Step 5 of a run: the same ciphertext into the folder the user picked.
  /// Never throws and never fails the backup.
  Future<void> _k1WriteSecondCopy(
      K1BackupState state, Session current, Uint8List ciphertext) async {
    final folder = state.secondCopyPath;
    if (folder == null) return;
    var failed = false;
    try {
      await k1SecondCopyWriter.write(
          folder: folder,
          accountId: current.accountId!,
          deviceId: current.deviceId!,
          ciphertext: ciphertext);
      state.secondCopyAt = k1Clock();
    } catch (_) {
      failed = true;
    }
    state.secondCopyFailed = failed;
  }

  K1BackupState? _k1StateForSession() {
    final current = session;
    final state = _k1State;
    if (current == null ||
        state == null ||
        current.accountId == null ||
        current.deviceId == null ||
        !state.belongsTo(
            current.baseUrl, current.accountId!, current.deviceId!)) {
      return null;
    }
    return state;
  }

  /// The session's state, or a fresh one for it (counter 0, no key).
  K1BackupState? _k1StateOrNew() {
    final current = session;
    if (current == null ||
        current.accountId == null ||
        current.deviceId == null) {
      return null;
    }
    final existing = _k1StateForSession();
    if (existing != null) return existing;
    return _k1State = K1BackupState(
      baseUrl: current.baseUrl,
      accountId: current.accountId!,
      deviceId: current.deviceId!,
    );
  }

  /// Reads the stored state. A state made or changed while the read was
  /// under way (a snooze, a key typed) wins over what was read.
  Future<void> _loadK1State() async {
    final current = session;
    final before = _k1State;
    if (current == null ||
        current.accountId == null ||
        current.deviceId == null) {
      return;
    }
    K1BackupState? read;
    try {
      read = K1BackupState.decode(await localStore.loadSetting(
          k1BackupSettingName(
              current.baseUrl, current.accountId!, current.deviceId!)));
      if (read != null &&
          !read.belongsTo(
              current.baseUrl, current.accountId!, current.deviceId!)) {
        read = null;
      }
    } catch (_) {
      read = null;
    }
    if (identical(_k1State, before) && identical(session, current)) {
      _k1State = read;
    }
  }

  /// Writes [state] under its identity's setting. A state that is no
  /// longer the signed-in identity's (signed out, wiped, switched) is never
  /// written back: that throws, so a counter that cannot be committed stops
  /// the run before its upload.
  Future<void> _saveK1State(K1BackupState state) async {
    if (!identical(_k1StateForSession(), state)) {
      throw StateError('K1 state no longer belongs to the session');
    }
    await localStore.saveSetting(
        k1BackupSettingName(state.baseUrl, state.accountId, state.deviceId),
        state.encode());
  }

  /// Stores the key's public half after the user typed it on this device
  /// (setup, confirmation, or "turn on backups here").
  Future<void> _storeK1Key(Uint8List rkPub, Uint8List rkId) async {
    final state = _k1StateOrNew();
    if (state == null) return;
    state.setKey(rkPub, rkId, k1Clock());
    await _saveK1State(state);
    // A run under way keeps its own key; a fresh run follows it.
    if (_k1Running) _k1RerunRequested = true;
    notifyListeners();
  }

  /// After sign-in or restore: read the state and run when due. The desktop
  /// app stays open in the tray (W4), so an hourly timer checks there too.
  Future<void> _startK1Backups() async {
    await _loadK1State();
    notifyListeners();
    _k1Timer?.cancel();
    _k1Timer = null;
    if (k1DesktopTimerEnabled) {
      _k1Timer = Timer.periodic(const Duration(hours: 1), (_) {
        unawaited(runK1BackupIfDue());
      });
    }
    unawaited(runK1BackupIfDue());
  }

  void _stopK1Backups() {
    _k1Timer?.cancel();
    _k1Timer = null;
  }
}

/// Marks a 409 `backup_counter_stale` inside a run.
const Object _k1CounterStale = Object();

/// The key one run seals to, copied from the state at its start.
class _K1RunKey {
  _K1RunKey(this.rkPub, this.rkId);
  final Uint8List rkPub;
  final Uint8List rkId;

  void wipe() => rkPub.fillRange(0, rkPub.length, 0);
}

/// The exported snapshot as one buffer, without a second copy when it
/// already is one.
Uint8List _k1Bytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
