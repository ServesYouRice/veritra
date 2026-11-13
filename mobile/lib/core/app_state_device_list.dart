part of 'app_state.dart';

// L1-3: the approved-device list on this device (D94,
// docs/designs/L1-approved-device-list.md, "Lifecycles"). This file signs the
// versions this device makes (genesis at setup and registration, an add at
// link approval, a removal at revoke and repair, the recovery key, recovery
// and the migration genesis) and keeps the pins fresh. The add gate, the leaf
// judgments and the approval hold live in the native crypto service.

/// The server, as [DeviceListPins] reads it, for whichever session is
/// active. No session or no API: unavailable (an exception).
class _AppDeviceListSource implements DeviceListSource {
  _AppDeviceListSource(this._app);
  final AppState _app;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
      {required int after}) {
    final current = _app.session;
    final client = _app.api;
    if (current == null || client == null) {
      throw StateError('no session to read device lists with');
    }
    return client.fetchDeviceList(current.token, accountId, after: after);
  }
}

/// How many times a version is re-signed after the head moved meanwhile
/// (409 `device_list_conflict`) before the action is reported as failed.
const int _deviceListSignAttempts = 3;

/// The change-4 statement a K0-R completion signed and has not yet seen the
/// server take (JSON: account, device, base64 statement). Public bytes.
const String _recoveryStatementSetting = 'l1.recovery_list_statement';

/// Explicit session credentials are needed before a linked session is active.
class _EnrollmentListSource implements DeviceListSource {
  _EnrollmentListSource(this.client, this.current);
  final ApiClient client;
  final Session current;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
          {required int after}) =>
      client.fetchDeviceList(current.token, accountId, after: after);
}

extension AppStateDeviceList on AppState {
  DeviceListCryptoService? get _listCrypto => switch (cryptoService) {
        final DeviceListCryptoService lists => lists,
        _ => null,
      };

  /// L2-5 (D94): sends the own-device alerts the last judgments found due,
  /// one hidden `device_list_alert` per conversation and own list head,
  /// identified (it is about this account). Looked at on every sync pass; a
  /// failed send is tried again on the next pass.
  Future<void> _sendOwnDeviceAlerts(Session owner, int generation) async {
    final crypto = cryptoService;
    if (crypto is! OwnDeviceAlertCryptoService) return;
    final alerts = crypto as OwnDeviceAlertCryptoService;
    for (final due in await alerts.ownDeviceAlertsDue()) {
      if (!_syncOwnerActive(owner, generation)) return;
      if (!conversations.any((item) => item.id == due.conversationId)) {
        continue;
      }
      final sent = await _sendPayload(
          due.conversationId, AppPayloadType.deviceListAlert, due.body);
      if (sent) {
        await alerts.markOwnDeviceAlertSent(
            due.conversationId, due.body['head_version'] as int);
      }
    }
  }

  /// A change-1 genesis that lists only this (pending) device, signed by it,
  /// for setup and registration. Null with an engine without L1: the account
  /// then starts with no list, and peers add none of its devices until one
  /// of them signs a migration genesis (fail closed for peers).
  Future<Uint8List?> _signGenesis(EnrollmentReservation enrollment) async {
    final crypto = _listCrypto;
    if (crypto == null) return null;
    final key = await crypto.currentSigningKey();
    final device = idBytes(enrollment.deviceId);
    return crypto.signDeviceList(DeviceListBody(
      accountId: idBytes(enrollment.accountId),
      version: 1,
      prevHash: DeviceListBody.zeroHash,
      createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      change: DeviceListChange.genesis,
      entries: [DeviceListPair(device, key)],
      // L2-3: the device's franking key is listed from the start, but only
      // while the server's sealed switch is on (condition A).
      frankKeys: await _ownFrankKeys(crypto, api, device),
    ));
  }

  /// Condition A (`docs/crypto.md`, "Franking a sealed message"): this
  /// device's own franking key, for a list version it signs now (genesis,
  /// recovery, migration genesis), only while [client]'s server reports
  /// `sealed_sender` on. A key makes the version L1 format 2, which servers
  /// and apps without L2-3 refuse; with the switch off, or when the setup
  /// status cannot be read, the version stays format 1, byte for byte the
  /// earlier format, and the key is added later with change 7 by the first
  /// sealed token pass ([_sealedFrankContext]).
  Future<List<DeviceListFrankKey>> _ownFrankKeys(DeviceListCryptoService crypto,
      ApiClient? client, Uint8List device) async {
    if (client == null) return const <DeviceListFrankKey>[];
    try {
      final status = await client.setupStatus();
      if (status['sealed_sender'] != true) {
        return const <DeviceListFrankKey>[];
      }
    } catch (_) {
      return const <DeviceListFrankKey>[];
    }
    return [DeviceListFrankKey(device, await crypto.currentFrankKey())];
  }

  String _anchorJournalKey(Session current) =>
      'l1.activation.${base64UrlEncode(utf8.encode(jsonEncode([
            canonicalizeServerOrigin(current.baseUrl),
            current.accountId,
            current.deviceId,
          ])))}';

  /// Write ahead of session persistence/promotion. Only public signed bytes.
  Future<void> _journalDeviceListAnchor(
          Session current, List<List<int>> statements) =>
      localStore.saveSetting(
          _anchorJournalKey(current),
          jsonEncode(
              [for (final statement in statements) base64Encode(statement)]));

  /// Must finish before any active-session path can read server lists.
  /// Errors deliberately propagate: missing durable trust is not TOFU.
  Future<void> _resumeDeviceListAnchor(Session current) async {
    final raw = await localStore.loadSetting(_anchorJournalKey(current));
    if (raw == null || raw.isEmpty) return;
    final pins = _deviceListPins;
    if (pins == null) throw StateError('device-list verifier unavailable');
    final statements = [
      for (final value in jsonDecode(raw) as List)
        base64Decode(value as String),
    ];
    if (statements.isEmpty) throw StateError('empty activation anchor');
    await pins.pinChain(current.accountId!, statements,
        expectedHead: statements.last);
  }

  Future<void> _clearDeviceListAnchorJournal(Session current) async {
    final key = _anchorJournalKey(current);
    final raw = await localStore.loadSetting(key);
    if (raw != null && raw.isNotEmpty) await localStore.saveSetting(key, '');
  }

  /// Refreshes this account's own pin (forced). Null when the account has no
  /// list (an account from before L1) or it is unavailable.
  Future<DeviceListPin?> _ownPin(Session current) async {
    final pins = _deviceListPins;
    if (pins == null) return null;
    final status = await pins.refresh(current.accountId ?? '', force: true);
    if (status.state == DeviceListState.conflict) {
      throw UserFacingException(l10n.errorDeviceListConflict);
    }
    return status.state == DeviceListState.ok ? status.pin : null;
  }

  /// The version after [head]. Every franking key the head lists for a
  /// device that stays is carried unchanged (L2-3: a listed key is fixed,
  /// and Rust refuses a version that drops or changes one); [ownFrankKey]
  /// adds this device's own, for change 7 and a recovery version.
  DeviceListBody _nextBody(
    DeviceListPin head,
    DeviceListChange change,
    List<DeviceListPair> entries, {
    Uint8List? recoveryKey,
    bool keepRecoveryKey = true,
    DeviceListFrankKey? ownFrankKey,
  }) =>
      DeviceListBody(
        accountId: idBytes(head.accountId),
        version: head.version + 1,
        prevHash: head.listHash,
        createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        change: change,
        entries: entries,
        recoveryKey: keepRecoveryKey ? head.recoveryKey : recoveryKey,
        frankKeys: [
          for (final key in head.listed)
            if (key.frankKey != null &&
                entries
                    .any((pair) => _sameIdBytes(pair.deviceId, key.deviceId)))
              DeviceListFrankKey(key.deviceId, key.frankKey!),
          if (ownFrankKey != null) ownFrankKey,
        ],
      );

  /// L2-3 (`docs/crypto.md`, "Franking a sealed message"): what a sealed
  /// send designates with, read on the sealed token pass and never on a
  /// send. Null (so every message goes identified, fail safe) unless this
  /// device is on its own verified list with its signing key and the list
  /// names exactly this device's franking key. A listed device whose list
  /// names no franking key for it yet publishes change 7 first. The owner
  /// keys are the proof recipients this app pinned ([_pinnedOwnerKeys]),
  /// never a key fetched for the send.
  Future<SealedFrankContext?> _sealedFrankContext(String origin) async {
    // The owner listing is read here only to pin on first use and to show
    // differences; a failure keeps the pins as they are.
    try {
      await _observeOwnerKeys(origin);
    } catch (_) {
      // Quiet: the pins, and so the tags, stay as they were.
    }
    final current = session;
    final crypto = _listCrypto;
    final pins = _deviceListPins;
    final account = current?.accountId;
    final device = current?.deviceId;
    if (current == null ||
        crypto == null ||
        pins == null ||
        account == null ||
        device == null) {
      return null;
    }
    final own = await crypto.currentFrankKey();
    final ownSigning = await crypto.currentSigningKey();
    var status = await pins.refresh(account);
    var head = status.state == DeviceListState.ok ? status.pin : null;
    if (head == null ||
        head.conflict ||
        head.standing(idBytes(device), ownSigning) != PinStanding.approved) {
      return null;
    }
    if (head.listedFrankKey(idBytes(device)) == null) {
      await _publishOwnFrankKey(current, own);
      status = await pins.refresh(account);
      head = status.state == DeviceListState.ok ? status.pin : null;
      if (head == null || head.conflict) return null;
    }
    final listed = head.listedFrankKey(idBytes(device));
    if (listed == null || !_sameIdBytes(listed, own)) return null;
    return SealedFrankContext(
        listedKey: listed, ownerKeys: await _pinnedOwnerKeys(origin));
  }

  /// L2-3 (owner decision 2026-11-12, auto-pin on first use): reads the
  /// instance owners' report keys the server lists now, through a `dm` or
  /// `group` conversation outside a community (members only), and hands
  /// them to [OwnerKeyWatch]: pinned as proof recipients (never as report
  /// pins) if this is the first sight, otherwise only recorded, so a change
  /// waits for the person. Only
  /// `report_inbox_unavailable` reads as "no owner has a key"; any other
  /// error records nothing.
  Future<void> _observeOwnerKeys(String origin) async {
    final current = session;
    final client = api;
    if (current == null ||
        client == null ||
        canonicalizeServerOrigin(client.baseUrl) !=
            canonicalizeServerOrigin(origin)) {
      return;
    }
    final watch = OwnerKeyWatch(localStore, origin);
    String? conversationId;
    for (final conversation in conversations) {
      if ((conversation.kind == 'dm' || conversation.kind == 'group') &&
          conversation.communityId == null &&
          conversation.channelId == null) {
        conversationId = conversation.id;
        break;
      }
    }
    if (conversationId != null) {
      ReportInbox? inbox;
      try {
        inbox = await client.getReportInbox(current.token, conversationId);
      } on ApiException catch (error) {
        if (error.serverCode == 'report_inbox_unavailable') {
          inbox =
              ReportInbox(kind: reportInboxInstanceOwner, recipients: const []);
        }
      }
      if (inbox != null && _sameSession(current)) await watch.observe(inbox);
    }
    await _setOwnerKeyReview(watch);
  }

  /// The proof recipients for [origin] (`OwnerProofPins.effective`: the
  /// owner keys pinned for proofs on first use or on the sealed key screen,
  /// and otherwise the D95 report pins a person made), owner scope (no `:`
  /// in the id), at most [SealedFrankContext.maxOwnerKeys], in account
  /// order. Reports never read these; they read only the D95 pins.
  Future<List<List<int>>> _pinnedOwnerKeys(String origin) async {
    final owners = await OwnerProofPins(localStore, origin).effective();
    return [
      for (final pin in owners.take(SealedFrankContext.maxOwnerKeys))
        pin.publicKey,
    ];
  }

  /// Change 7: this device sets its own franking key on its list, once.
  /// Errors are left to the caller's pass (it tries again on the next one).
  Future<void> _publishOwnFrankKey(Session current, Uint8List frank) async {
    final client = api;
    final device = current.deviceId;
    if (client == null || device == null) return;
    await _signAndSend(
      current,
      (head) {
        final id = idBytes(device);
        if (head.listedKey(id) == null || head.listedFrankKey(id) != null) {
          return null;
        }
        return _nextBody(head, DeviceListChange.frankKey, _listedPairs(head),
            ownFrankKey: DeviceListFrankKey(id, frank));
      },
      (statement) async {
        if (statement == null) return;
        await client.publishDeviceList(current.token, statement);
      },
    );
  }

  List<DeviceListPair> _listedPairs(DeviceListPin head) => [
        for (final key in head.listed)
          DeviceListPair(key.deviceId, key.signingKey),
      ];

  /// Signs the version [build] makes from this account's head and hands it
  /// to [send]. When the head moved meanwhile (409 `device_list_conflict`)
  /// it refreshes, re-signs and retries without asking the user again.
  /// Returns the statement the server stored, or null when the account has
  /// no list yet (nothing is signed; [send] gets null).
  Future<Uint8List?> _signAndSend(
    Session current,
    DeviceListBody? Function(DeviceListPin head) build,
    Future<void> Function(Uint8List? statement) send,
  ) async {
    final crypto = _listCrypto;
    if (crypto == null) {
      await send(null);
      return null;
    }
    for (var attempt = 1;; attempt++) {
      final head = await _ownPin(current);
      final body = head == null ? null : build(head);
      final statement = body == null ? null : await crypto.signDeviceList(body);
      try {
        await send(statement);
      } on ApiException catch (err) {
        if (err.serverCode == 'device_list_conflict' &&
            attempt < _deviceListSignAttempts) {
          continue;
        }
        rethrow;
      }
      if (statement != null) {
        await _deviceListPins?.pinOwnStep(current.accountId ?? '', statement);
      }
      return statement;
    }
  }

  /// The change-2 version a K2 link approval carries: this account's head
  /// plus the new device with the signing key the link's authenticated
  /// transcript names. Called only after the claim tag and the typed code
  /// verified (the approval request exists only then). [recipientDeviceId]
  /// and [recipientSigningKey] must be the pair whose recomputed transcript
  /// hash equals the one native verified; the caller checks that.
  Future<DeviceLinkV3Record> _approveLinkWithDeviceList(
    ApiClient client,
    Session current,
    DeviceLinkV3Record link,
    List<int> approvalTag, {
    required String recipientDeviceId,
    required List<int> recipientSigningKey,
  }) async {
    late DeviceLinkV3Record approved;
    final recipient = recipientDeviceId;
    final newKey = Uint8List.fromList(recipientSigningKey);
    await _signAndSend(
      current,
      (head) {
        if (head.listedKey(idBytes(recipient)) != null) return null;
        return _nextBody(head, DeviceListChange.add, [
          ..._listedPairs(head),
          DeviceListPair(idBytes(recipient), newKey),
        ]);
      },
      (statement) async {
        approved = await client.approveDeviceLinkV3(current, link, approvalTag,
            deviceList: statement);
      },
    );
    return approved;
  }

  /// Revokes [deviceId] with the change-3 version that leaves it out. A
  /// device not on the list, or the last one, is revoked with no version.
  Future<void> _revokeWithDeviceList(
      ApiClient client, Session current, String deviceId) async {
    await _signAndSend(
      current,
      (head) {
        final listed = _listedPairs(head);
        final rest = [
          for (final pair in listed)
            if (!_sameIdBytes(pair.deviceId, idBytes(deviceId))) pair,
        ];
        if (rest.length == listed.length || rest.isEmpty) return null;
        return _nextBody(head, DeviceListChange.remove, rest);
      },
      (statement) =>
          client.revokeDevice(current.token, deviceId, deviceList: statement),
    );
  }

  /// `PUT /account/recovery-key` with the change-5 version that sets
  /// [rkListPub] as the list's recovery key.
  Future<RecoveryKeyStatus> _putRecoveryKeyWithDeviceList(
    ApiClient client,
    Session current,
    RecoveryKeyValues values,
  ) async {
    late RecoveryKeyStatus status;
    final listKey = values.rkListPub;
    await _signAndSend(
      current,
      (head) {
        if (listKey == null) return null;
        final same = head.recoveryKey != null &&
            _sameIdBytes(head.recoveryKey!, listKey);
        if (same) return null;
        return _nextBody(head, DeviceListChange.recoveryKey, _listedPairs(head),
            keepRecoveryKey: false, recoveryKey: listKey);
      },
      (statement) async {
        status = await client.putRecoveryKey(current.token,
            rkAuthPub: values.rkAuthPub,
            rkId: values.rkId,
            deviceList: statement);
      },
    );
    return status;
  }

  /// Repair (design, "Removing a device"): a listed sibling the server shows
  /// as revoked is taken off the list by this device. The server takes such
  /// a removal without recent auth only when every removed device is
  /// already revoked.
  Future<void> _repairDeviceList(List<Device> serverDevices) async {
    final current = session;
    final client = api;
    final crypto = _listCrypto;
    if (current == null || client == null || crypto == null) return;
    final revoked = {
      for (final device in serverDevices)
        if (device.revokedAt != null) device.id,
    };
    if (revoked.isEmpty) return;
    final head = await _ownPin(current);
    if (head == null) return;
    final listed = _listedPairs(head);
    final rest = [
      for (final pair in listed)
        if (!revoked.contains(_textId(pair.deviceId))) pair,
    ];
    if (rest.length == listed.length || rest.isEmpty) return;
    if (!rest.any((pair) =>
        _sameIdBytes(pair.deviceId, idBytes(current.deviceId ?? '')))) {
      return; // This device is not on the list: it cannot sign.
    }
    final statement = await crypto
        .signDeviceList(_nextBody(head, DeviceListChange.remove, rest));
    await client.publishDeviceList(current.token, statement);
    await _deviceListPins?.pinOwnStep(current.accountId ?? '', statement);
  }

  /// Validate before promotion; never let a server-selected chain become TOFU.
  Future<void> _journalLinkedDeviceAnchor(ApiClient client, Session current,
      {required List<int> signingKey,
      required String approverDeviceId,
      required List<int> approverSigningKey}) async {
    final crypto = _listCrypto;
    if (crypto == null) throw StateError('device-list verifier unavailable');
    final pins = DeviceListPins(
        store: localStore,
        source: _EnrollmentListSource(client, current),
        verifier: crypto);
    final statements = await pins.linkedAnchor(current.accountId!,
        deviceId: idBytes(current.deviceId!),
        signingKey: signingKey,
        approverDeviceId: idBytes(approverDeviceId),
        approverSigningKey: approverSigningKey);
    await _journalDeviceListAnchor(current, statements);
  }

  /// K0-R completion (design, "Recovery when every device is lost"): signs
  /// change 4, listing only this device, with the held recovery seed and
  /// posts it. It chains from the head at completion; Rust refuses to sign
  /// unless that head's recovery key is the held seed's. Without a held seed
  /// nothing is posted and peers keep this device out (K0-R's no-peer state)
  /// until the recovery key is typed again. Never throws.
  ///
  /// Signing drops the held seed for good, so the signed statement is stored
  /// (it is public) before it is posted, and posted again from
  /// [_retryRecoveryDeviceList] until the server takes it or the head names
  /// this device: one failed request must not cost the only signature.
  Future<void> _postRecoveryDeviceList(Session recovered) async {
    final crypto = _listCrypto;
    final client = api;
    final pins = _deviceListPins;
    final account = recovered.accountId;
    final device = recovered.deviceId;
    if (crypto == null ||
        client == null ||
        pins == null ||
        account == null ||
        device == null) {
      return;
    }
    try {
      var statement = await _storedRecoveryStatement(account, device);
      if (statement == null) {
        final status = await pins.refresh(account, force: true);
        final head = status.pin;
        if (status.state != DeviceListState.ok || head == null) return;
        final own = await crypto.currentSigningKey();
        if (head.standing(idBytes(device), own) == PinStanding.approved) {
          return;
        }
        statement = await crypto.signRecoveryDeviceList(
          prev: head.headStatement,
          body: _nextBody(head, DeviceListChange.recovery,
              [DeviceListPair(idBytes(device), own)],
              ownFrankKey:
                  (await _ownFrankKeys(crypto, client, idBytes(device)))
                      .firstOrNull),
          history: [
            for (final key in head.keys)
              DeviceListPair(key.deviceId, key.signingKey),
          ],
        );
        await localStore.saveSetting(
            _recoveryStatementSetting,
            jsonEncode(<String, Object?>{
              'account_id': account,
              'device_id': device,
              'statement': base64Encode(statement),
            }));
      }
      await _sendRecoveryStatement(recovered, statement);
    } on Object catch (err) {
      developer.log('L1 recovery version not posted: ${err.runtimeType}',
          name: 'veritra.l1');
      // No held seed, or one the head does not name: Settings asks for the
      // recovery key again (retype).
      unawaited(_refreshOwnListState().catchError((Object _) {}));
    }
  }

  /// Posts a stored change-4 statement again (start, device refresh).
  Future<void> _retryRecoveryDeviceList() async {
    final current = session;
    final account = current?.accountId;
    final device = current?.deviceId;
    if (current == null || account == null || device == null) return;
    final statement = await _storedRecoveryStatement(account, device);
    if (statement == null) return;
    try {
      await _sendRecoveryStatement(current, statement);
    } on Object catch (err) {
      developer.log('L1 recovery version not posted: ${err.runtimeType}',
          name: 'veritra.l1');
    }
  }

  Future<void> _sendRecoveryStatement(
      Session current, Uint8List statement) async {
    final client = api;
    final pins = _deviceListPins;
    final account = current.accountId;
    if (client == null || pins == null || account == null) return;
    try {
      await client.publishDeviceList(current.token, statement);
    } on ApiException catch (err) {
      if (err.serverCode != 'device_list_conflict') rethrow;
      // Taken already (a lost answer), or the head moved: done only if the
      // head now names this device with its key.
      final status = await pins.refresh(account, force: true);
      final own = await _listCrypto?.currentSigningKey();
      final head = status.pin;
      if (own != null &&
          head != null &&
          head.standing(idBytes(current.deviceId ?? ''), own) ==
              PinStanding.approved) {
        await localStore.saveSetting(_recoveryStatementSetting, '');
      } else if (head != null &&
          status.state == DeviceListState.ok &&
          !_chainsOnHead(statement, head)) {
        // The head moved past it and does not name this device: the stored
        // version can never be taken (review fix). It is dropped, so the
        // recovery key is asked for again and a fresh version is signed on
        // the current head.
        await localStore.saveSetting(_recoveryStatementSetting, '');
        unawaited(_refreshOwnListState().catchError((Object _) {}));
      }
      return;
    }
    await localStore.saveSetting(_recoveryStatementSetting, '');
    await pins.pinOwnStep(account, statement);
  }

  /// Whether [statement]'s `prev_hash` is [head]'s list hash, read from the
  /// VDL1 body (`"VDL1" | 1 | lp(account) | u64 version | prev_hash`). An
  /// unreadable statement does not chain.
  static bool _chainsOnHead(Uint8List statement, DeviceListPin head) {
    if (statement.length < 7) return false;
    final accountLength = (statement[5] << 8) | statement[6];
    final start = 7 + accountLength + 8;
    if (statement.length < start + 32) return false;
    final prev = statement.sublist(start, start + 32);
    if (head.listHash.length != 32) return false;
    var same = 0;
    for (var i = 0; i < 32; i++) {
      same |= prev[i] ^ head.listHash[i];
    }
    return same == 0;
  }

  Future<Uint8List?> _storedRecoveryStatement(
      String account, String device) async {
    final raw = await localStore.loadSetting(_recoveryStatementSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map &&
          value['account_id'] == account &&
          value['device_id'] == device &&
          value['statement'] is String) {
        return base64Decode(value['statement'] as String);
      }
    } on FormatException {
      // Unreadable: nothing to retry.
    }
    return null;
  }

  /// Whether this account has no approved-device list yet (an account from
  /// before L1). Read again with the devices; shown in Settings.
  Future<void> _refreshOwnListState() async {
    final current = session;
    final pins = _deviceListPins;
    final account = current?.accountId;
    if (current == null || pins == null || account == null) return;
    final status = await pins.refresh(account);
    if (!identical(session, current)) return;
    final missing = status.state == DeviceListState.empty;
    final head = status.state == DeviceListState.ok ? status.pin : null;
    final noRecoveryKey = head != null && head.recoveryKey == null;
    var retype = false;
    final device = current.deviceId;
    if (head != null && device != null) {
      await _loadRecoveredMark();
      final own =
          _recoveredDevice ? await _listCrypto?.currentSigningKey() : null;
      retype = own != null &&
          head.standing(idBytes(device), own) != PinStanding.approved &&
          await _storedRecoveryStatement(account, device) == null;
    }
    if (!identical(session, current)) return;
    if (missing != ownDeviceListMissing ||
        noRecoveryKey != _ownHeadWithoutRecoveryKey ||
        retype != recoveryListNeedsRetype) {
      ownDeviceListMissing = missing;
      _ownHeadWithoutRecoveryKey = noRecoveryKey;
      recoveryListNeedsRetype = retype;
      notifyListeners();
    }
  }

  /// A recovery key set before L1 (design, "Existing accounts"): the server
  /// has one, but the verified head names none, so recovery is refused for
  /// this account until the key is typed once on a device.
  bool get recoveryKeyNeedsConfirmation =>
      _ownHeadWithoutRecoveryKey &&
      !ownDeviceListMissing &&
      (recoveryKeyStatus?.configured ?? false);

  /// Confirms a pre-L1 recovery key: [typed] must be the key the server
  /// knows (same `rk_id`, compared in constant time); then the same key is
  /// set again with the change-5 version that names its list key. Needs
  /// recent auth. A wrong key sends nothing and fails under
  /// [Ops.recoveryKey].
  Future<RecoveryActionResult> confirmPreL1RecoveryKey(String typed) async {
    var needsRecentAuth = false;
    final ok = await _runScoped(Ops.recoveryKey, () async {
      final current = session;
      final client = api;
      final serverId = recoveryKeyStatus?.rkId;
      if (current == null || client == null) {
        throw UserFacingException(l10n.errorRelinkRequired);
      }
      final crypto = _recoveryCrypto;
      final Uint8List entropy;
      try {
        entropy =
            await crypto.decodeRecoveryKey(normalizeRecoveryKeyInput(typed));
      } catch (_) {
        throw UserFacingException(l10n.recoveryKeyUnreadable);
      }
      final RecoveryKeyValues values;
      try {
        values = await crypto.deriveRecoveryKey(entropy);
      } finally {
        entropy.fillRange(0, entropy.length, 0);
      }
      try {
        if (serverId == null ||
            !_constantTimeBytesEqual(values.rkId, serverId)) {
          throw UserFacingException(l10n.recoveryKeyNotThisAccount);
        }
        final status =
            await _putRecoveryKeyWithDeviceList(client, current, values);
        if (!identical(session, current)) return;
        recoveryKeyStatus = status;
        _ownHeadWithoutRecoveryKey = false;
      } on ApiException catch (err) {
        if (err.serverCode == 'recent_auth_required') {
          needsRecentAuth = true;
          return;
        }
        rethrow;
      } finally {
        values.rkPub.fillRange(0, values.rkPub.length, 0);
      }
    });
    if (needsRecentAuth) return RecoveryActionResult.needsRecentAuth;
    if (ok) unawaited(_refreshOwnListState().catchError((Object _) {}));
    return ok ? RecoveryActionResult.done : RecoveryActionResult.failed;
  }

  /// Recovery step 4 (retype): signs this device's change 4 from the typed
  /// recovery key, when the held seed is gone or does not match the head.
  /// Rust refuses a key whose list key is not the head's recovery key, so a
  /// wrong key signs nothing. Nothing derived from it is kept; the signed
  /// (public) statement is stored and posted as after a held-seed signing.
  Future<bool> finishRecoveryWithTypedKey(String typed) async {
    final ok = await _runScoped(Ops.recoveryKey, () async {
      final current = session;
      final crypto = _listCrypto;
      final pins = _deviceListPins;
      final account = current?.accountId;
      final device = current?.deviceId;
      if (current == null ||
          crypto == null ||
          pins == null ||
          account == null ||
          device == null) {
        throw UserFacingException(l10n.errorRelinkRequired);
      }
      final Uint8List entropy;
      try {
        entropy = await _recoveryCrypto
            .decodeRecoveryKey(normalizeRecoveryKeyInput(typed));
      } catch (_) {
        throw UserFacingException(l10n.recoveryKeyUnreadable);
      }
      try {
        final status = await pins.refresh(account, force: true);
        final head = status.pin;
        if (status.state == DeviceListState.conflict) {
          throw UserFacingException(l10n.errorDeviceListConflict);
        }
        if (status.state != DeviceListState.ok || head == null) {
          throw UserFacingException(l10n.errorRelinkRequired);
        }
        final own = await crypto.currentSigningKey();
        if (head.standing(idBytes(device), own) == PinStanding.approved) {
          return; // Done already (another attempt landed).
        }
        final frankKeys = await _ownFrankKeys(crypto, api, idBytes(device));
        final Uint8List statement;
        try {
          statement = await crypto.signRecoveryDeviceList(
            prev: head.headStatement,
            body: _nextBody(head, DeviceListChange.recovery,
                [DeviceListPair(idBytes(device), own)],
                ownFrankKey: frankKeys.firstOrNull),
            history: [
              for (final key in head.keys)
                DeviceListPair(key.deviceId, key.signingKey),
            ],
            entropy: entropy,
          );
        } on NativeCryptoException {
          // The head's recovery key is not this key's (or the body was
          // refused): nothing was signed.
          throw UserFacingException(l10n.recoveryKeyNotThisAccount);
        }
        await localStore.saveSetting(
            _recoveryStatementSetting,
            jsonEncode(<String, Object?>{
              'account_id': account,
              'device_id': device,
              'statement': base64Encode(statement),
            }));
        await _sendRecoveryStatement(current, statement);
      } finally {
        entropy.fillRange(0, entropy.length, 0);
      }
    });
    if (ok) await _refreshOwnListState().catchError((Object _) {});
    return ok;
  }

  /// The migration genesis (design, "Existing accounts"): the user ticked
  /// [keepDeviceIds] among the account's devices; they become version 1 of
  /// its approved-device list, signed by this device, which must be one of
  /// them. The unticked devices are then revoked. Needs recent auth.
  Future<RecoveryActionResult> createApprovedDeviceList(
      Set<String> keepDeviceIds) async {
    var needsRecentAuth = false;
    final ok = await _runScoped(Ops.devices, () async {
      final current = session;
      final client = api;
      final crypto = _listCrypto;
      final account = current?.accountId;
      final own = current?.deviceId;
      if (current == null ||
          client == null ||
          crypto == null ||
          account == null ||
          own == null ||
          !keepDeviceIds.contains(own)) {
        throw UserFacingException(l10n.errorRelinkRequired);
      }
      final ownKey = await crypto.currentSigningKey();
      final entries = <DeviceListPair>[
        for (final device in devices)
          if (device.revokedAt == null &&
              keepDeviceIds.contains(device.id) &&
              device.id != own &&
              device.signingKey != null)
            DeviceListPair(idBytes(device.id), device.signingKey!),
        DeviceListPair(idBytes(own), ownKey),
      ];
      final statement = await crypto.signDeviceList(DeviceListBody(
        accountId: idBytes(account),
        version: 1,
        prevHash: DeviceListBody.zeroHash,
        createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        change: DeviceListChange.migrationGenesis,
        entries: entries,
        // L2-3: only this device's own franking key, and only while the
        // sealed switch is on (condition A); the others set theirs with
        // change 7.
        frankKeys: await _ownFrankKeys(crypto, client, idBytes(own)),
      ));
      try {
        await client.publishDeviceList(current.token, statement);
      } on ApiException catch (err) {
        if (err.serverCode == 'recent_auth_required') {
          needsRecentAuth = true;
          return;
        }
        rethrow;
      }
      await _deviceListPins?.pinChain(account, [statement],
          expectedHead: statement);
      ownDeviceListMissing = false;
      for (final device in devices) {
        if (device.revokedAt == null && !keepDeviceIds.contains(device.id)) {
          await _revokeWithDeviceList(client, current, device.id);
        }
      }
      await _refreshDevices();
    });
    if (needsRecentAuth) return RecoveryActionResult.needsRecentAuth;
    return ok ? RecoveryActionResult.done : RecoveryActionResult.failed;
  }

  /// Handles `device_list.updated` (own devices only): the own pin is
  /// refreshed and groups are judged again at their next use.
  void _noteDeviceListUpdated() {
    final current = session;
    if (current == null) return;
    _deviceListPins?.invalidate(current.accountId ?? '');
    _mlsReconcileRequested = true;
  }
}

String? _textId(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

bool _sameIdBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
