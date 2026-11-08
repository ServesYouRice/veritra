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
    notifyListeners();
    try {
      final error = await _k1BackupOnce(current, client, state);
      if (!identical(session, current)) return false;
      if (error == null) {
        state.recordSuccess(k1Clock());
      } else {
        state.recordFailure(error, k1Clock());
      }
      await _saveK1State(state);
      return error == null;
    } catch (_) {
      // Unreadable local settings or a store failure: try again later.
      return false;
    } finally {
      _k1Running = false;
      notifyListeners();
    }
  }

  /// True while a run is under way.
  bool get k1BackupRunning => _k1Running;

  // ------------------------------------------------------------ internal ---

  /// One run (design, "What one run does"). Returns the error kind, or null
  /// on success.
  Future<K1BackupError?> _k1BackupOnce(
      Session current, ApiClient client, K1BackupState state) async {
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
        !_constantTimeBytesEqual(accountRkId, state.rkId!)) {
      return K1BackupError.keyChanged;
    }
    // 2. Build the snapshot, without disappearing messages.
    final plaintext = Uint8List.fromList(
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
        rkPub: state.rkPub!,
        plaintext: plaintext,
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    // 4. Upload. A stale counter (this device's state was lost) jumps ahead
    // and tries once more.
    try {
      for (var attempt = 0;; attempt++) {
        final error = await _k1Upload(client, current, state, ciphertext!);
        if (error != _k1CounterStale) return error as K1BackupError?;
        if (attempt > 0) return K1BackupError.failed;
        // This device's counter fell behind the server's high-water mark
        // (its local state was lost or restored). Jump past it: the clock
        // in milliseconds is above any counter a device reaches by days.
        state.counter =
            max(state.counter + 1, k1Clock().millisecondsSinceEpoch);
        await _saveK1State(state);
        final plain = Uint8List.fromList(
            await localStore.exportHistorySnapshot(omitDisappearing: true));
        try {
          ciphertext = await seal.sealK1Backup(
            accountId: current.accountId!,
            sourceDeviceId: current.deviceId!,
            createdAtMs: k1Clock().millisecondsSinceEpoch,
            counter: state.counter,
            rkPub: state.rkPub!,
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
  Future<Object?> _k1Upload(ApiClient client, Session current,
      K1BackupState state, Uint8List ciphertext) async {
    try {
      await client.uploadK1Backup(current.token, ciphertext,
          rkId: state.rkId!, counter: state.counter);
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
      }
      if (err.statusCode == 507) return K1BackupError.spaceFull;
      if (err.statusCode >= 500 || err.statusCode == 429) {
        return K1BackupError.network;
      }
      return K1BackupError.failed;
    }
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
    final before = _k1State;
    K1BackupState? read;
    try {
      read = K1BackupState.decode(
          await localStore.loadSetting(k1BackupStateSetting));
    } catch (_) {
      read = null;
    }
    if (identical(_k1State, before)) _k1State = read;
  }

  Future<void> _saveK1State(K1BackupState state) async {
    if (!identical(_k1State, state)) return;
    await localStore.saveSetting(k1BackupStateSetting, state.encode());
  }

  /// Stores the key's public half after the user typed it on this device
  /// (setup, confirmation, or "turn on backups here").
  Future<void> _storeK1Key(Uint8List rkPub, Uint8List rkId) async {
    final state = _k1StateOrNew();
    if (state == null) return;
    state.setKey(rkPub, rkId);
    await _saveK1State(state);
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
