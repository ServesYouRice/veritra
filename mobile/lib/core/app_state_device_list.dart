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

extension AppStateDeviceList on AppState {
  DeviceListCryptoService? get _listCrypto => switch (cryptoService) {
        final DeviceListCryptoService lists => lists,
        _ => null,
      };

  /// A change-1 genesis that lists only this (pending) device, signed by it,
  /// for setup and registration. Null with an engine without L1: the account
  /// then starts with no list, and peers add none of its devices until one
  /// of them signs a migration genesis (fail closed for peers).
  Future<Uint8List?> _signGenesis(EnrollmentReservation enrollment) async {
    final crypto = _listCrypto;
    if (crypto == null) return null;
    final key = await crypto.currentSigningKey();
    return crypto.signDeviceList(DeviceListBody(
      accountId: idBytes(enrollment.accountId),
      version: 1,
      prevHash: DeviceListBody.zeroHash,
      createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      change: DeviceListChange.genesis,
      entries: [DeviceListPair(idBytes(enrollment.deviceId), key)],
    ));
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

  DeviceListBody _nextBody(
    DeviceListPin head,
    DeviceListChange change,
    List<DeviceListPair> entries, {
    Uint8List? recoveryKey,
    bool keepRecoveryKey = true,
  }) =>
      DeviceListBody(
        accountId: idBytes(head.accountId),
        version: head.version + 1,
        prevHash: head.listHash,
        createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        change: change,
        entries: entries,
        recoveryKey: keepRecoveryKey ? head.recoveryKey : recoveryKey,
      );

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

  /// Anchors a newly linked device on its own account's list: the chain
  /// must verify and its head must list this device with its own key, added
  /// by the device that approved the link with the key the authenticated
  /// transcript names. Best effort: a failure leaves no pin, and the next
  /// refresh pins by trust on first use.
  Future<void> _anchorLinkedDevice(Session current,
      {required String approverDeviceId,
      required List<int> approverSigningKey}) async {
    final pins = _deviceListPins;
    final crypto = _listCrypto;
    if (pins == null || crypto == null) return;
    try {
      final status = await pins.refresh(current.accountId ?? '', force: true);
      final pin = status.pin;
      if (status.state != DeviceListState.ok || pin == null) return;
      final own = await crypto.currentSigningKey();
      final mine = pin.standing(idBytes(current.deviceId ?? ''), own);
      final approver =
          pin.standing(idBytes(approverDeviceId), approverSigningKey);
      if (mine != PinStanding.approved ||
          (approver != PinStanding.approved &&
              approver != PinStanding.removed)) {
        developer.log('L1: this device is not on its own approved list',
            name: 'veritra.l1');
      }
    } on Object {
      // Pinned later by trust on first use.
    }
  }

  /// K0-R completion (design, "Recovery when every device is lost"): signs
  /// change 4, listing only this device, with the held recovery seed and
  /// posts it. It chains from the head at completion; Rust refuses to sign
  /// unless that head's recovery key is the held seed's. Without a held seed
  /// nothing is posted and peers keep this device out (K0-R's no-peer state)
  /// until the recovery key is typed again. Never throws.
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
      final status = await pins.refresh(account, force: true);
      final head = status.pin;
      if (status.state != DeviceListState.ok || head == null) return;
      final own = await crypto.currentSigningKey();
      if (head.standing(idBytes(device), own) == PinStanding.approved) return;
      final statement = await crypto.signRecoveryDeviceList(
        prev: head.headStatement,
        body: _nextBody(head, DeviceListChange.recovery,
            [DeviceListPair(idBytes(device), own)]),
        history: [
          for (final key in head.keys)
            DeviceListPair(key.deviceId, key.signingKey),
        ],
      );
      await client.publishDeviceList(recovered.token, statement);
      await pins.pinOwnStep(account, statement);
    } on Object catch (err) {
      developer.log('L1 recovery version not posted: ${err.runtimeType}',
          name: 'veritra.l1');
    }
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
    if (missing != ownDeviceListMissing) {
      ownDeviceListMissing = missing;
      notifyListeners();
    }
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
