part of 'app_state.dart';

// B7 passkeys (docs/designs/B7-passkeys.md, S3). A passkey replaces the
// password at sign-in only. It never adds a device and never counts as recent
// authentication: adding or removing a passkey still needs the password
// check the settings screen makes first. Options, challenges and credentials
// are never logged or stored.

/// A passkey change made somewhere else, shown until dismissed.
enum PasskeyNotice { added, removed }

extension PasskeyActions on AppState {
  /// Whether the passkey button may show for a probed server, given the
  /// platform, the server's say and the compiled-in Apple domains. Always
  /// false on Linux and where the plugin cannot run.
  bool passkeysOfferedFor(SetupProbeResult probe) {
    final origin = probe.origin;
    if (origin == null || !passkeyClient.platformSupported) return false;
    final host = Uri.tryParse(origin)?.host ?? '';
    if (host.isEmpty) return false;
    return passkeysOffered(
      platform: passkeyPlatform,
      info: probe.passkeys,
      serverHost: host,
      appleDomains: passkeyAppleDomains,
    );
  }

  /// Signs in with a passkey on an enrolled device. The device ID and secret
  /// stored for [baseUrl] are checked at both server steps; no username is
  /// typed. A cancelled platform sheet is silent.
  Future<void> signInWithPasskey(String baseUrl) async {
    await _run(() async {
      _replaceApi(baseUrl);
      final client = api!;
      final localSession = await localStore.loadSession();
      final deviceId = localSession?.baseUrl == client.baseUrl
          ? localSession?.deviceId
          : null;
      final deviceSecret = localSession?.baseUrl == client.baseUrl
          ? localSession?.deviceSecret
          : null;
      if (localSession == null ||
          deviceId == null ||
          deviceId.isEmpty ||
          deviceSecret == null ||
          deviceSecret.isEmpty) {
        throw UserFacingException(l10n.errorPasswordLoginNeedsLink);
      }
      final info = PasskeyServerInfo.fromStatus(await client.setupStatus());
      final host = Uri.parse(client.baseUrl).host;
      if (info == null ||
          !passkeysOffered(
            platform: passkeyPlatform,
            info: info,
            serverHost: host,
            appleDomains: passkeyAppleDomains,
          ) ||
          !passkeyClient.platformSupported) {
        throw UserFacingException(l10n.passkeyUnavailable);
      }
      final credential = await _runCeremony(
        host: host,
        info: info,
        registration: false,
        options: () => client.passkeyLoginOptions(
            deviceId: deviceId, deviceSecret: deviceSecret),
        ceremony: passkeyClient.get,
        finish: (ceremony, credential) async {
          // Read before saving the new session: a different identity wipes
          // the MLS state with it.
          final hadMlsState = await localStore.loadCryptoState() != null;
          try {
            session = await client.passkeyLogin(
              ceremonyId: ceremony.id,
              deviceId: deviceId,
              deviceSecret: deviceSecret,
              credential: credential,
              fallbackUsername: localSession.username,
            );
          } on ApiException catch (err) {
            if (err.serverCode == 'invalid_credentials') {
              throw UserFacingException(l10n.passkeySignInFailed);
            }
            rethrow;
          }
          await _finishDeviceSignIn(localSession, hadMlsState);
        },
      );
      // A cancelled sheet returns null and leaves the screen as it was.
      if (credential == null) return;
    });
  }

  /// Runs one ceremony: options, the RP ID pin, the platform call, [finish].
  /// Returns null when the user cancelled. The pin runs before the platform
  /// is called, so a hostile server cannot ask for another server's
  /// assertion (design, "The app pins the RP ID").
  Future<Map<String, Object?>?> _runCeremony({
    required String host,
    required PasskeyServerInfo info,
    required bool registration,
    required Future<PasskeyCeremony> Function() options,
    required Future<Map<String, Object?>> Function(Map<String, Object?>)
        ceremony,
    required Future<void> Function(
            PasskeyCeremony, Map<String, Object?> credential)
        finish,
  }) async {
    final started = await options();
    try {
      pinPasskeyRp(
        publicKey: started.publicKey,
        registration: registration,
        serverHost: host,
        info: info,
      );
    } on PasskeyPinException {
      throw UserFacingException(l10n.passkeyPinRefused);
    }
    final Map<String, Object?> credential;
    try {
      credential = await ceremony(started.publicKey);
    } on PasskeyCancelled {
      return null;
    } on PasskeyUnavailable {
      throw UserFacingException(l10n.passkeyUnavailable);
    }
    await finish(started, credential);
    return credential;
  }

  /// Reads the account's passkeys. Failures keep the last list.
  Future<void> refreshPasskeys() async {
    final current = session;
    final client = api;
    if (current == null || client == null || current.token.isEmpty) return;
    final generation = _sessionGeneration;
    try {
      final list = await client.passkeys(current.token);
      if (!_refreshOwned(current, generation)) return;
      passkeyList = list;
      passkeysLoaded = true;
      notifyListeners();
    } catch (_) {
      // Offline or an older server: the screen shows what it has.
    }
  }

  /// What the server says about passkeys, for the signed-in server; null
  /// when it offers none to this build on this platform.
  Future<PasskeyServerInfo?> signedInPasskeyInfo() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return null;
    try {
      final info = PasskeyServerInfo.fromStatus(await client.setupStatus());
      final host = Uri.parse(client.baseUrl).host;
      if (!passkeyClient.platformSupported ||
          !passkeysOffered(
            platform: passkeyPlatform,
            info: info,
            serverHost: host,
            appleDomains: passkeyAppleDomains,
          )) {
        return null;
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Adds a passkey named [name]. The caller has just made the password
  /// check (`reauthenticate`): the server refuses without recent
  /// authentication. Returns whether a passkey was added.
  Future<bool> addPasskey(String name) async {
    var added = false;
    await _runScoped(Ops.passkeys, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      final info = await signedInPasskeyInfo();
      if (info == null) throw UserFacingException(l10n.passkeyUnavailable);
      final host = Uri.parse(client.baseUrl).host;
      final credential = await _runCeremony(
        host: host,
        info: info,
        registration: true,
        options: () => client.passkeyRegisterOptions(current.token),
        ceremony: passkeyClient.create,
        finish: (ceremony, credential) async {
          final id = await client.passkeyRegister(
            current.token,
            ceremonyId: ceremony.id,
            name: name,
            credential: credential,
          );
          _ownPasskeyChanges.add(id);
        },
      );
      if (credential == null) return;
      if (!_sameSession(current)) return;
      added = true;
      await refreshPasskeys();
    });
    return added;
  }

  Future<bool> renamePasskey(String id, String name) async {
    final ok = await _runScoped(Ops.passkeys, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      await client.renamePasskey(current.token, id, name);
      await refreshPasskeys();
    });
    return ok;
  }

  /// Removes a passkey. The caller has just made the password check.
  Future<bool> removePasskey(String id) async {
    final ok = await _runScoped(Ops.passkeys, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      _ownPasskeyChanges.add(id);
      try {
        await client.deletePasskey(current.token, id);
      } catch (_) {
        _ownPasskeyChanges.remove(id);
        rethrow;
      }
      await refreshPasskeys();
    });
    return ok;
  }

  void dismissPasskeyNotice() {
    if (passkeyNotice == null) return;
    passkeyNotice = null;
    notifyListeners();
  }

  /// `account.passkey_added` and `account.passkey_removed` from sync. Events
  /// for a change this device made itself raise no notice. The payload holds
  /// the passkey's row ID only.
  void _notePasskeyEvent(SyncEvent event) {
    final payload = event.payload;
    final id = payload is Map ? payload['passkey_id'] : null;
    if (id is String && _ownPasskeyChanges.remove(id)) {
      passkeysLoaded = false;
      return;
    }
    passkeysLoaded = false;
    passkeyNotice = event.type == 'account.passkey_added'
        ? PasskeyNotice.added
        : PasskeyNotice.removed;
    notifyListeners();
  }
}
