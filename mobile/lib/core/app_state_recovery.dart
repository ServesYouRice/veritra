part of 'app_state.dart';

// K0 recovery enrollment on the client (docs/designs/K0-recovery-enrollment.md):
// R3, setting the account's recovery key, and R4, recovering the account on
// a new device after every device was lost, plus the notices an existing
// device shows. Recovery key entropy is wiped as soon as it is used; no key,
// password, token or device secret is ever logged.

/// Settings in the encrypted local metadata. None is in a backup (D71).
const String _pendingRecoverySetting = 'k0.pending_recovery';
const String _recoveryFollowUpSetting = 'k0.recovery_follow_up';
const String _passwordLeakSetting = 'k0.password_leak_day';
const String _passwordLeakDismissedSetting = 'k0.password_leak_dismissed';

/// A leak warning from a day further back than this is history (a sync from
/// cursor 0 replays old events), not news.
const Duration _passwordLeakNoticeWindow = Duration(days: 7);

/// Polls of a waiting claim: hourly, and once soon after `ready_at`.
const Duration _recoveryPollInterval = Duration(hours: 1);

/// The steps a recovered device takes before its chats open (design,
/// client flow step 6). The device has been through recovery because the
/// password and recovery key may both be known to someone else, so both are
/// replaced. [recoveryKey] includes proving the password again (completion
/// never grants recent authentication).
enum RecoveryFollowUpStep { recoveryKey, password }

/// What saving or cancelling a recovery setting found, when it did not
/// simply fail (the error is then under [Ops.recoveryKey] or
/// [Ops.accountRecovery]).
enum RecoveryActionResult { done, needsRecentAuth, failed }

/// A newly generated recovery key while it is shown and confirmed. [dispose]
/// wipes the entropy; the display string cannot be wiped and is dropped
/// with the screen.
class RecoveryKeyDraft {
  RecoveryKeyDraft._(this._entropy, this.display);

  final Uint8List _entropy;

  /// The canonical 52-character display.
  final String display;

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _entropy.fillRange(0, _entropy.length, 0);
  }
}

extension AccountRecoveryActions on AppState {
  /// Whether this build can set a recovery key or recover an account: only
  /// with the native engine. [UnavailableCryptoService] never qualifies
  /// (`PM_CRYPTO_UNAVAILABLE`).
  bool get recoveryAvailable =>
      cryptoService is RecoveryCryptoService &&
      cryptoService is! UnavailableCryptoService &&
      _mlsCrypto != null;

  RecoveryCryptoService get _recoveryCrypto {
    if (cryptoService case final RecoveryCryptoService crypto
        when recoveryAvailable) {
      return crypto;
    }
    throw UserFacingException(l10n.recoveryUnavailableHere);
  }

  /// The leak warning to show (D79), or null.
  String? get passwordLeakWarningDay => _passwordLeakDay;

  // ---------------------------------------------------------------- R3 ---

  /// Reads the account's recovery key status. It never throws: a failure
  /// keeps the last status.
  Future<void> refreshRecoveryKeyStatus() async {
    final current = session;
    final client = api;
    if (current == null || client == null || current.token.isEmpty) return;
    final generation = _sessionGeneration;
    try {
      final status = await client.recoveryKeyStatus(current.token);
      if (!_refreshOwned(current, generation)) return;
      recoveryKeyStatus = status;
      notifyListeners();
      // A server with recovery off cannot take a new key; the password
      // change is still required.
      if (!status.available &&
          recoveryFollowUp == RecoveryFollowUpStep.recoveryKey) {
        await _saveRecoveryFollowUp(RecoveryFollowUpStep.password);
      }
    } catch (_) {
      // Offline or an older server: the settings tile says it is unknown.
    }
  }

  /// A fresh recovery key to show. The caller disposes it.
  Future<RecoveryKeyDraft> createRecoveryKeyDraft() async {
    final crypto = _recoveryCrypto;
    final entropy = await crypto.generateRecoveryKey();
    try {
      return RecoveryKeyDraft._(
          entropy, await crypto.encodeRecoveryKey(entropy));
    } catch (_) {
      entropy.fillRange(0, entropy.length, 0);
      rethrow;
    }
  }

  /// Whether [typed] is the key of [draft]. The typed text is decoded and
  /// compared as bytes, in constant time, and the decoded copy is wiped.
  Future<bool> recoveryKeyMatches(RecoveryKeyDraft draft, String typed) async {
    if (draft._disposed) return false;
    final Uint8List decoded;
    try {
      decoded = await _recoveryCrypto
          .decodeRecoveryKey(normalizeRecoveryKeyInput(typed));
    } catch (_) {
      return false;
    }
    try {
      return _constantTimeBytesEqual(decoded, draft._entropy);
    } finally {
      decoded.fillRange(0, decoded.length, 0);
    }
  }

  /// Sets [draft] as the account's recovery key, replacing any earlier one
  /// (which also cancels a waiting recovery). Returns
  /// [RecoveryActionResult.needsRecentAuth] when the server asks for the
  /// password again first.
  Future<RecoveryActionResult> saveRecoveryKey(RecoveryKeyDraft draft) async {
    var needsRecentAuth = false;
    final ok = await _runScoped(Ops.recoveryKey, () async {
      final current = session;
      final client = api;
      if (current == null || client == null || draft._disposed) {
        throw UserFacingException(l10n.errorRelinkRequired);
      }
      final values = await _recoveryCrypto.deriveRecoveryKey(draft._entropy);
      // rk_pub is K1's; nothing stores it yet.
      values.rkPub.fillRange(0, values.rkPub.length, 0);
      try {
        final status = await client.putRecoveryKey(current.token,
            rkAuthPub: values.rkAuthPub, rkId: values.rkId);
        if (!identical(session, current)) return;
        recoveryKeyStatus = status;
      } on ApiException catch (err) {
        if (err.serverCode == 'recent_auth_required') {
          needsRecentAuth = true;
          return;
        }
        rethrow;
      }
      if (recoveryFollowUp == RecoveryFollowUpStep.recoveryKey) {
        await _saveRecoveryFollowUp(RecoveryFollowUpStep.password);
      }
    });
    if (needsRecentAuth) return RecoveryActionResult.needsRecentAuth;
    return ok ? RecoveryActionResult.done : RecoveryActionResult.failed;
  }

  // -------------------------------------------- Notices on other devices ---

  /// Cancels a waiting recovery of this account from this signed-in device
  /// (needs recent auth).
  Future<RecoveryActionResult> cancelAccountRecoveryRequest(
      String requestId) async {
    var needsRecentAuth = false;
    final ok = await _runScoped(Ops.accountRecovery, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        throw UserFacingException(l10n.errorRelinkRequired);
      }
      try {
        await client.cancelAccountRecovery(current.token, requestId);
      } on ApiException catch (err) {
        if (err.serverCode == 'recent_auth_required') {
          needsRecentAuth = true;
          return;
        }
        // Already gone (completed, cancelled or expired): show what is.
        if (err.statusCode != 404 && err.statusCode != 410) rethrow;
      }
      final status = recoveryKeyStatus;
      if (status != null && status.pending?.id == requestId) {
        recoveryKeyStatus = RecoveryKeyStatus(
            available: status.available,
            configured: status.configured,
            setAt: status.setAt);
      }
      unawaited(refreshRecoveryKeyStatus());
    });
    if (needsRecentAuth) return RecoveryActionResult.needsRecentAuth;
    return ok ? RecoveryActionResult.done : RecoveryActionResult.failed;
  }

  /// Hides the leak warning until the next one.
  Future<void> dismissPasswordLeakWarning() async {
    final day = _passwordLeakDay;
    if (day == null) return;
    _passwordLeakDay = null;
    notifyListeners();
    try {
      await localStore.saveSetting(_passwordLeakDismissedSetting, day);
    } catch (_) {
      // Shown again after a restart; harmless.
    }
  }

  // --------------------------------------------------------------- R4 ---

  /// Starts recovering the account of [username] on this device: decodes
  /// the recovery key (before any network call), reserves, claims with the
  /// password and the recovery proof, and keeps the claim for the wait.
  /// Returns false with the error under [Ops.accountRecovery].
  Future<bool> startAccountRecovery({
    required String baseUrl,
    required String username,
    required String password,
    required String recoveryKey,
  }) =>
      _runRecovery(() async {
        final crypto = _recoveryCrypto;
        if (session != null) {
          throw UserFacingException(l10n.recoverySignedInAlready);
        }
        if (pendingAccountRecovery != null) {
          throw UserFacingException(l10n.recoveryAlreadyPending);
        }
        final Uint8List entropy;
        try {
          entropy = await crypto
              .decodeRecoveryKey(normalizeRecoveryKeyInput(recoveryKey));
        } catch (_) {
          throw UserFacingException(l10n.recoveryKeyUnreadable);
        }
        var enrolling = false;
        try {
          _replaceApi(baseUrl);
          final client = api!;
          // The origin the proof names, byte for byte: the canonical
          // https://host[:port] this app talks to, which is what the server's
          // PRIVATE_MESSENGER_PUBLIC_ORIGIN must be.
          final origin = client.baseUrl;
          final restored = await localStore.loadSession();
          final reservation =
              await client.reserveAccountRecovery(username.trim());
          if (restored != null &&
              isRestoredAccountSession(restored) &&
              (canonicalizeServerOrigin(restored.baseUrl) != origin ||
                  restored.accountId != reservation.accountId)) {
            // Going on would silently drop the restored history.
            throw UserFacingException(l10n.recoveryBackupOtherAccount);
          }
          enrolling = true;
          final credential =
              await cryptoService.createEnrollmentCredential(reservation);
          final signature = await crypto.signRecoveryProof(
            entropy: entropy,
            challenge: reservation.challenge,
            signingKey: credential.signingKey,
            keyPackage: credential.deviceKeyPackage,
            origin: origin,
          );
          final sealed = await crypto.sealPendingEnrollment();
          final AccountRecoveryClaim claim;
          try {
            claim = await client.claimAccountRecovery(
              enrollment: reservation,
              password: password,
              deviceName: config.deviceName,
              credential: credential,
              recoverySignature: signature,
            );
          } on ApiException catch (err) {
            if (err.statusCode == 401) {
              throw UserFacingException(l10n.recoveryClaimRefused);
            }
            rethrow;
          }
          final pending = PendingAccountRecovery(
            origin: origin,
            username: username.trim(),
            accountId: reservation.accountId,
            deviceId: reservation.deviceId,
            deviceName: config.deviceName,
            requestId: claim.requestId,
            claimToken: claim.claimToken,
            deviceSecret: claim.deviceSecret,
            readyAt: claim.readyAt,
            mlsState: sealed,
          );
          await localStore.saveSetting(
              _pendingRecoverySetting, pending.encode());
          enrolling = false;
          pendingAccountRecovery = pending;
          _scheduleRecoveryPoll();
        } finally {
          entropy.fillRange(0, entropy.length, 0);
          if (enrolling) {
            try {
              await crypto.abandonPendingEnrollment();
            } catch (_) {}
          }
        }
      });

  /// The account a backup restore left on this device, to prefill the
  /// recovery form; null when there is none.
  Future<Session?> restoredAccountForRecovery() async {
    if (session != null) return null;
    try {
      final stored = await localStore.loadSession();
      return stored != null && isRestoredAccountSession(stored) ? stored : null;
    } catch (_) {
      return null;
    }
  }

  /// Asks the server about the waiting claim now. Completes it when ready.
  Future<bool> checkAccountRecovery() => _runRecovery(_pollAccountRecovery);

  /// Finishes a claim whose session answer was lost: the server already
  /// enrolled this device, so it signs in with the password and the
  /// claim's device secret.
  Future<bool> finishAccountRecoveryWithPassword(String password) =>
      _runRecovery(() async {
        final pending = pendingAccountRecovery;
        if (pending == null || !pending.needsLogin) return;
        final client = _recoveryClient(pending);
        final Session signedIn;
        try {
          signedIn = await client.login(
            username: pending.username,
            password: password,
            deviceId: pending.deviceId,
            deviceSecret: pending.deviceSecret,
          );
        } on ApiException catch (err) {
          if (err.statusCode == 401) {
            throw UserFacingException(l10n.apiErrorInvalidCredentials);
          }
          rethrow;
        }
        await _finishRecoveredSession(pending, signedIn);
      });

  /// Drops the waiting claim on this device. The server's request expires
  /// on its own; only a signed-in device can cancel it there.
  Future<void> abandonAccountRecovery() async {
    _recoveryPollTimer?.cancel();
    _recoveryPollTimer = null;
    pendingAccountRecovery = null;
    notifyListeners();
    try {
      await localStore.saveSetting(_pendingRecoverySetting, '');
    } catch (_) {}
    if (cryptoService case final RecoveryCryptoService crypto) {
      try {
        await crypto.abandonPendingEnrollment();
      } catch (_) {}
    }
  }

  /// Recovery steps without a session: like [_runScoped], but a 401 never
  /// clears a session (there is none; a restored account's history stays).
  Future<bool> _runRecovery(Future<void> Function() body) async {
    var succeeded = false;
    await _enqueueSessionTransition(() async {
      const op = Ops.accountRecovery;
      _busyOps.add(op);
      _opErrors.remove(op);
      notifyListeners();
      try {
        await body();
        succeeded = true;
      } catch (err) {
        _opErrors[op] = describeError(err, l10n);
      } finally {
        _busyOps.remove(op);
        notifyListeners();
      }
    });
    return succeeded;
  }

  ApiClient _recoveryClient(PendingAccountRecovery pending) {
    final current = api;
    if (current != null && current.baseUrl == pending.origin) return current;
    _replaceApi(pending.origin);
    if (api!.baseUrl != pending.origin) {
      throw StateError('Recovery server was substituted');
    }
    return api!;
  }

  Future<void> _pollAccountRecovery() async {
    final pending = pendingAccountRecovery;
    if (pending == null || pending.needsLogin || session != null) return;
    final client = _recoveryClient(pending);
    final AccountRecoveryStatus status;
    try {
      status = await client.accountRecoveryStatus(
          pending.requestId, pending.claimToken);
    } on ApiException catch (err) {
      if (err.statusCode == 410 || err.statusCode == 404) {
        // Cancelled by the account's owner, by a password or recovery key
        // change, replaced by a newer claim, or expired.
        await abandonAccountRecovery();
        throw UserFacingException(l10n.recoveryRequestEnded);
      }
      if (err.statusCode == 401) {
        throw UserFacingException(l10n.recoveryRequestEnded);
      }
      rethrow;
    } finally {
      _scheduleRecoveryPoll();
    }
    if (!identical(pendingAccountRecovery, pending)) return;
    switch (status.phase) {
      case AccountRecoveryPhase.waiting:
        final readyAt = status.readyAt;
        if (readyAt != null && readyAt != pending.readyAt) {
          final next = pending.copyWith(readyAt: readyAt);
          await localStore.saveSetting(_pendingRecoverySetting, next.encode());
          pendingAccountRecovery = next;
          _scheduleRecoveryPoll();
        }
      case AccountRecoveryPhase.completedWithoutToken:
        if (status.accountId != pending.accountId ||
            status.deviceId != pending.deviceId) {
          throw StateError('Recovery identity was substituted');
        }
        final next = pending.copyWith(needsLogin: true);
        await localStore.saveSetting(_pendingRecoverySetting, next.encode());
        pendingAccountRecovery = next;
        _recoveryPollTimer?.cancel();
        _recoveryPollTimer = null;
      case AccountRecoveryPhase.completed:
        if (status.accountId != pending.accountId ||
            status.deviceId != pending.deviceId) {
          throw StateError('Recovery identity was substituted');
        }
        await _finishRecoveredSession(
          pending,
          Session(
            baseUrl: pending.origin,
            token: status.token!,
            accountId: status.accountId,
            deviceId: status.deviceId,
            username: status.username ?? pending.username,
            deviceSecret: pending.deviceSecret,
            role: status.role,
          ),
        );
    }
  }

  /// Saves the recovered device's session, as [completeDeviceLinkClaim]
  /// does for a linked one. The restored history of the same account stays.
  /// The forced follow-up is stored first, so no restart opens the chats
  /// before it is done.
  Future<void> _finishRecoveredSession(
      PendingAccountRecovery pending, Session recovered) async {
    if (canonicalizeServerOrigin(recovered.baseUrl) != pending.origin ||
        recovered.accountId != pending.accountId ||
        recovered.deviceId != pending.deviceId ||
        recovered.token.isEmpty) {
      throw StateError('Recovery identity was substituted');
    }
    await _saveRecoveryFollowUp(RecoveryFollowUpStep.recoveryKey,
        owner: recovered);
    await _recoveryCrypto.resumePendingEnrollment(
      accountId: pending.accountId,
      deviceId: pending.deviceId,
      state: pending.mlsState,
    );
    session = recovered;
    await _oweInitialKeyPackages(recovered);
    await localStore.saveSession(recovered);
    await _mlsCrypto?.activateSession(recovered);
    await localStore.saveSyncCursor(0);
    _recoveryPollTimer?.cancel();
    _recoveryPollTimer = null;
    pendingAccountRecovery = null;
    await localStore.saveSetting(_pendingRecoverySetting, '');
    await _finishSignIn(() async {
      await _publishInitialMlsKeyPackages();
      await _refreshConversations(notify: true);
      await _refreshDevices();
    });
  }

  void _scheduleRecoveryPoll() {
    _recoveryPollTimer?.cancel();
    _recoveryPollTimer = null;
    final pending = pendingAccountRecovery;
    if (_disposed || pending == null || pending.needsLogin) return;
    var delay = pending.readyAt.difference(DateTime.now().toUtc());
    // A little after ready_at, so the server's clock has passed it too.
    delay += const Duration(seconds: 5);
    if (delay.isNegative || delay > _recoveryPollInterval) {
      delay = _recoveryPollInterval;
    }
    _recoveryPollTimer = Timer(delay, () {
      _recoveryPollTimer = null;
      unawaited(checkAccountRecovery());
    });
  }

  // ------------------------------------------------------ Load and hooks ---

  /// At start with no signed-in session: the waiting claim, if any, and a
  /// poll (design: poll at start, on resume and hourly).
  Future<void> _loadPendingAccountRecovery() async {
    if (!recoveryAvailable) return;
    PendingAccountRecovery? pending;
    try {
      pending = PendingAccountRecovery.decode(
          await localStore.loadSetting(_pendingRecoverySetting));
    } catch (_) {
      return;
    }
    pendingAccountRecovery = pending;
    if (pending != null && !pending.needsLogin) {
      unawaited(checkAccountRecovery());
    }
  }

  /// A recovered session whose MLS state did not reach the store before the
  /// app stopped: the pending identity is opened again, so activation
  /// stores it.
  Future<void> _resumeRecoveredIdentity(Session restored) async {
    if (!recoveryAvailable) return;
    final PendingAccountRecovery? pending;
    try {
      pending = PendingAccountRecovery.decode(
          await localStore.loadSetting(_pendingRecoverySetting));
    } catch (_) {
      return;
    }
    if (pending == null) return;
    if (pending.accountId != restored.accountId ||
        pending.deviceId != restored.deviceId ||
        pending.origin != canonicalizeServerOrigin(restored.baseUrl)) {
      return;
    }
    if (await localStore.loadCryptoState() == null) {
      await _recoveryCrypto.resumePendingEnrollment(
        accountId: pending.accountId,
        deviceId: pending.deviceId,
        state: pending.mlsState,
      );
      await _mlsCrypto?.activateSession(restored);
      await localStore.saveSyncCursor(0);
    }
    await localStore.saveSetting(_pendingRecoverySetting, '');
  }

  /// Reads the follow-up step, the leak warning and the server's recovery
  /// status again.
  Future<void> refreshRecoveryNotices() => _loadSignedInRecoveryState();

  /// After any sign-in or restore: the follow-up, the leak warning and the
  /// server's recovery status.
  Future<void> _loadSignedInRecoveryState() async {
    final current = session;
    if (current == null) return;
    try {
      recoveryFollowUp = _decodeFollowUp(
          await localStore.loadSetting(_recoveryFollowUpSetting), current);
      final day = await localStore.loadSetting(_passwordLeakSetting);
      final dismissed =
          await localStore.loadSetting(_passwordLeakDismissedSetting);
      _passwordLeakDay = _currentLeakDay(day, dismissed);
    } catch (_) {
      // Unreadable settings: nothing to show.
    }
    if (!identical(session, current)) return;
    notifyListeners();
    if (recoveryAvailable) await refreshRecoveryKeyStatus();
  }

  RecoveryFollowUpStep? _decodeFollowUp(String? raw, Session current) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('\u0000');
    if (parts.length != 3 ||
        parts[0] != current.accountId ||
        parts[1] != current.deviceId) {
      return null;
    }
    for (final step in RecoveryFollowUpStep.values) {
      if (step.name == parts[2]) return step;
    }
    return null;
  }

  Future<void> _saveRecoveryFollowUp(RecoveryFollowUpStep? step,
      {Session? owner}) async {
    final current = owner ?? session;
    if (step == null || current == null) {
      await localStore.saveSetting(_recoveryFollowUpSetting, '');
    } else {
      await localStore.saveSetting(_recoveryFollowUpSetting,
          '${current.accountId}\u0000${current.deviceId}\u0000${step.name}');
    }
    recoveryFollowUp = step;
    notifyListeners();
  }

  String? _currentLeakDay(String? day, String? dismissed) {
    if (day == null || day.isEmpty || day == dismissed) return null;
    final parsed = DateTime.tryParse('${day}T00:00:00Z');
    if (parsed == null) return null;
    final age = DateTime.now().toUtc().difference(parsed);
    return age > _passwordLeakNoticeWindow ? null : day;
  }

  /// `account.password_leak_suspected` (D79): local only, so a background
  /// pass may record it too.
  Future<void> _notePasswordLeak(SyncEvent event) async {
    final payload = event.payload;
    var day = payload is Map ? payload['day'] : null;
    if (day is! String || DateTime.tryParse('${day}T00:00:00Z') == null) {
      day = event.createdAt.toUtc().toIso8601String().substring(0, 10);
    }
    try {
      final dismissed =
          await localStore.loadSetting(_passwordLeakDismissedSetting);
      final current = _currentLeakDay(day, dismissed);
      if (current == null) return;
      await localStore.saveSetting(_passwordLeakSetting, current);
      _passwordLeakDay = current;
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  /// A password change ends the leak warning and the last follow-up step.
  Future<void> _afterPasswordChanged() async {
    final day = _passwordLeakDay;
    if (day != null) await dismissPasswordLeakWarning();
    if (recoveryFollowUp == RecoveryFollowUpStep.password) {
      await _saveRecoveryFollowUp(null);
    }
  }

  /// Account events from sync. Returns whether the status should be read
  /// again.
  bool _noteAccountSyncEvent(SyncEvent event) {
    final type = event.type;
    if (type == 'account.password_leak_suspected') {
      unawaited(_notePasswordLeak(event));
      return false;
    }
    return type.startsWith('account.recovery');
  }

  void _resumeAccountRecovery() {
    if (session != null) {
      final now = DateTime.now();
      final last = _recoveryStatusReadAt;
      if (recoveryAvailable &&
          (last == null || now.difference(last) > const Duration(minutes: 1))) {
        _recoveryStatusReadAt = now;
        unawaited(refreshRecoveryKeyStatus());
      }
      return;
    }
    if (pendingAccountRecovery != null && !pendingAccountRecovery!.needsLogin) {
      unawaited(checkAccountRecovery());
    }
  }
}
