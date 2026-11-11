part of 'app_state.dart';

// K2 device link v3 and the history transfer on the client
// (docs/designs/K2-new-device-history.md): the existing device creates a
// link, confirms the new device's safety code, approves, and then sends its
// history as one encrypted bundle; the new device claims the link, waits for
// the approval, becomes active through the promotion ledger and receives the
// bundle. There is no fallback to the v2 link: a v3 server answer never
// produces a response-generated credential.
//
// L1-3 commit-then-reveal (docs/designs/L1-3-link-commitment.md): the
// existing device commits to a fresh random when it creates the link and
// reveals it only after its native accept of the claim is committed; the new
// device shows the code only once that random opens the commitment it was
// given before it claimed. A relay that knows the QR secret still gets one
// guess at the 8 digits per run.
//
// Every secret here is held in memory only as long as a step needs it. The
// new device's three credentials (claim token, device secret, initial session
// token) are created on the device and stored, with the frozen signed claim,
// in its encrypted pending enrollment before the claim is sent. Nothing is
// logged.

/// How often a new device looks at its waiting link.
const Duration _linkPollInterval = Duration(seconds: 4);

/// How often an unfinished history transfer is looked at again, and how long
/// to wait after a failure that may be temporary.
const Duration _transferRetryInterval = Duration(seconds: 30);
const Duration _transferFailureInterval = Duration(minutes: 5);

/// What the existing device's link screen shows.
class DeviceLinkV3View {
  const DeviceLinkV3View({
    required this.id,
    required this.state,
    required this.expiresAt,
    this.claimedDeviceName,
    this.verificationCode = '',
  });

  final String id;

  /// `pending`, `claimed`, `approved` or `consumed` (the server's states).
  final String state;
  final DateTime expiresAt;
  final String? claimedDeviceName;

  /// The 8-digit safety code the new device shows, once the claim passed
  /// the native checks; empty before. The user types the code shown on the
  /// new device, so this value only gates the approve button.
  final String verificationCode;
}

/// What the new device's link form shows while it waits.
class DeviceLinkClaimView {
  const DeviceLinkClaimView({
    required this.state,
    required this.verificationCode,
    required this.expiresAt,
  });

  /// `claimed` once the server has the signed claim, `approved` once the
  /// existing device approved it.
  final String state;

  /// The 8-digit safety code to read out on the existing device. Empty
  /// until the existing device revealed its random and it opened the
  /// commitment (L1-3).
  final String verificationCode;
  final DateTime expiresAt;
}

/// [failed] is temporary (it is tried again); [ended] is final (the copy was
/// abandoned and the device must be linked again to copy history).
enum HistoryTransferPhase { working, waiting, failed, ended }

/// Where the history copy stands, for the one banner that shows it. Null in
/// [AppState.historyTransferStatus] when no copy is open.
class HistoryTransferStatus {
  const HistoryTransferStatus({required this.incoming, required this.phase});

  /// True on the new device, false on the device that sends.
  final bool incoming;
  final HistoryTransferPhase phase;
}

/// A new device's stored claim: everything needed to finish the link after a
/// restart, credentials included. Never printed.
class _PendingLinkV3 {
  const _PendingLinkV3({
    required this.origin,
    required this.linkId,
    required this.accountId,
    required this.deviceId,
    required this.locator,
    required this.requestId,
    required this.reservation,
    required this.claim,
    required this.claimRequestHash,
    required this.claimToken,
    required this.deviceSecret,
    required this.initialSessionToken,
    required this.verificationCode,
    required this.expiresAt,
    this.record,
  });

  final String origin;
  final String linkId;
  final String accountId;
  final String deviceId;
  final String locator;
  final String requestId;
  final Map<String, Object?> reservation;
  final Map<String, Object?> claim;
  final String claimRequestHash;
  final String claimToken;
  final String deviceSecret;
  final String initialSessionToken;
  final String verificationCode;

  /// The link's expiry, epoch milliseconds.
  final int expiresAt;

  /// The last public link record the server returned for this claim; null
  /// until the claim was accepted.
  final Map<String, Object?>? record;

  /// The code is never stored: after a restart it is derived again from
  /// the reveal (the read-only native step), so a stored row keeps ''.
  _PendingLinkV3 withCode(String code) => _PendingLinkV3(
        origin: origin,
        linkId: linkId,
        accountId: accountId,
        deviceId: deviceId,
        locator: locator,
        requestId: requestId,
        reservation: reservation,
        claim: claim,
        claimRequestHash: claimRequestHash,
        claimToken: claimToken,
        deviceSecret: deviceSecret,
        initialSessionToken: initialSessionToken,
        verificationCode: code,
        expiresAt: expiresAt,
        record: record,
      );

  _PendingLinkV3 withRecord(Map<String, Object?> next) => _PendingLinkV3(
        origin: origin,
        linkId: linkId,
        accountId: accountId,
        deviceId: deviceId,
        locator: locator,
        requestId: requestId,
        reservation: reservation,
        claim: claim,
        claimRequestHash: claimRequestHash,
        claimToken: claimToken,
        deviceSecret: deviceSecret,
        initialSessionToken: initialSessionToken,
        verificationCode: verificationCode,
        expiresAt: expiresAt,
        record: next,
      );

  /// The enrollment row. [state] is the sealed MLS state of the first save;
  /// later saves pass none and keep it (a stored state is frozen).
  PendingEnrollment toEnrollment({StoredCryptoState? state}) =>
      PendingEnrollment(
        kind: PendingEnrollment.kindDeviceLinkV3,
        origin: origin,
        accountId: accountId,
        deviceId: deviceId,
        payloadJson: jsonEncode(<String, Object?>{
          'v': 1,
          'link_id': linkId,
          'locator': locator,
          'request_id': requestId,
          'reservation': reservation,
          'claim': claim,
          'claim_request_hash': claimRequestHash,
          'claim_token': claimToken,
          'device_secret': deviceSecret,
          'initial_session_token': initialSessionToken,
          'sas': '',
          'expires_at': expiresAt,
          if (record != null) 'record': record,
        }),
        state: state,
      );

  /// Null for a row that cannot be read (a different shape, a damaged
  /// payload).
  static _PendingLinkV3? fromEnrollment(PendingEnrollment row) {
    if (row.kind != PendingEnrollment.kindDeviceLinkV3) return null;
    try {
      final json = jsonDecode(row.payloadJson);
      if (json is! Map || json['v'] != 1) return null;
      Map<String, Object?> map(Object? value) =>
          Map<String, Object?>.from(value as Map);
      String text(String key) => json[key] as String;
      final record = json['record'];
      return _PendingLinkV3(
        origin: row.origin,
        linkId: text('link_id'),
        accountId: row.accountId,
        deviceId: row.deviceId,
        locator: text('locator'),
        requestId: text('request_id'),
        reservation: map(json['reservation']),
        claim: map(json['claim']),
        claimRequestHash: text('claim_request_hash'),
        claimToken: text('claim_token'),
        deviceSecret: text('device_secret'),
        initialSessionToken: text('initial_session_token'),
        // Shown again only after a fresh reveal check (L1-3).
        verificationCode: '',
        expiresAt: json['expires_at'] as int,
        record: record == null ? null : map(record),
      );
    } on Object {
      return null;
    }
  }

  @override
  String toString() => '_PendingLinkV3';
}

int _linkTimeMs(Map<String, Object?> fields, String key) =>
    DateTime.parse(fields[key] as String).millisecondsSinceEpoch;

List<int> _linkRandom(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _linkToken() => base64Url.encode(_linkRandom(32)).replaceAll('=', '');

List<int> _linkUnhex(String text) => <int>[
      for (var index = 0; index < text.length; index += 2)
        int.parse(text.substring(index, index + 2), radix: 16),
    ];

Map<String, Object?> _linkRowPayload(HistoryTransferProgress row) {
  final decoded = jsonDecode(row.payloadJson);
  return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
}

List<int> _linkTokenHash(String token) => sha256(utf8.encode(token));

extension DeviceLinkV3Actions on AppState {
  /// Whether this build can link devices and move history: the native
  /// engine with its K2 operations. [UnavailableCryptoService] never
  /// qualifies (`PM_CRYPTO_UNAVAILABLE`).
  bool get deviceLinkV3Available =>
      cryptoService is K2TransferCryptoService &&
      cryptoService is RecoveryCryptoService &&
      cryptoService is EnrollmentPromotionCryptoService &&
      cryptoService is! UnavailableCryptoService &&
      _mlsCrypto != null;

  void _requireDeviceLinkV3() {
    if (!deviceLinkV3Available) {
      throw UserFacingException(l10n.deviceLinkUnavailableHere);
    }
  }

  K2TransferCryptoService get _k2 {
    if (cryptoService case final K2TransferCryptoService crypto
        when deviceLinkV3Available) {
      return crypto;
    }
    throw UserFacingException(l10n.deviceLinkUnavailableHere);
  }

  EnrollmentPromotionCryptoService get _linkPromotionCrypto {
    if (cryptoService case final EnrollmentPromotionCryptoService crypto
        when deviceLinkV3Available) {
      return crypto;
    }
    throw UserFacingException(l10n.deviceLinkUnavailableHere);
  }

  RecoveryCryptoService get _linkRecoveryCrypto {
    if (cryptoService case final RecoveryCryptoService crypto
        when deviceLinkV3Available) {
      return crypto;
    }
    throw UserFacingException(l10n.deviceLinkUnavailableHere);
  }

  /// The link code the new device scans or types, while the link is open.
  String? get activeDeviceLinkCode => _activeLinkSecret == null ||
          activeDeviceLink == null ||
          DateTime.now().isAfter(activeDeviceLink!.expiresAt)
      ? null
      : encodeDeviceLinkSecret(_activeLinkSecret!);

  // ------------------------------------------------ Existing device ---

  /// Makes a v3 link. The secret stays in memory; only its locator goes to
  /// the server. So does the random this device commits to (L1-3): only its
  /// commitment goes to the server now.
  Future<void> createDeviceLink() => _runScoped(Ops.deviceLink, () async {
        final current = session;
        final client = api;
        if (current == null || client == null) return;
        _requireDeviceLinkV3();
        final crypto = _k2;
        _requireLinkOrigin(current, client);
        activeDeviceLink = null;
        _activeLinkRecord = null;
        _clearLinkSecret();
        final secret = _linkRandom(16);
        final sourceRandom = _linkRandom(32);
        try {
          final locator = await cryptoService.deviceLinkLocator(secret);
          final commitment = await crypto.k2SourceCommitment(
              canonicalizeServerOrigin(current.baseUrl), sourceRandom);
          final created =
              await client.createDeviceLinkV3(current, locator, commitment);
          if (created.state != 'pending' ||
              created.accountId != current.accountId ||
              created.sourceDeviceId != current.deviceId) {
            throw StateError('Device-link context was substituted');
          }
          _activeLinkSecret = secret;
          _activeLinkSourceRandom = sourceRandom;
          _activeLinkRecord = created;
          activeDeviceLink = _linkView(created);
        } finally {
          if (!identical(secret, _activeLinkSecret)) {
            secret.fillRange(0, secret.length, 0);
          }
          if (!identical(sourceRandom, _activeLinkSourceRandom)) {
            sourceRandom.fillRange(0, sourceRandom.length, 0);
          }
        }
      });

  /// Reads the link again. A claimed link is checked natively (transcript
  /// and confirmation tag, keyed by the secret only the QR carried) before
  /// the safety code is shown; anything that does not check out fails
  /// closed.
  Future<void> refreshActiveDeviceLink() =>
      _runScoped(Ops.deviceLink, () async {
        final current = session;
        final client = api;
        final view = activeDeviceLink;
        if (current == null || client == null || view == null) return;
        final crypto = _k2;
        _requireLinkOrigin(current, client);
        try {
          final link = await client.deviceLinkV3(current, view.id);
          if (link.accountId != current.accountId ||
              link.sourceDeviceId != current.deviceId) {
            throw StateError('Device-link context was substituted');
          }
          _activeLinkRecord = link;
          if (link.state == 'claimed') {
            final code = await _acceptedVerification(crypto, current, link);
            // Only now, with this claim accepted and committed natively,
            // may the random leave the device (L1-3).
            final revealed = await _revealSourceRandom(client, current, link);
            _activeLinkRecord = revealed;
            activeDeviceLink = _linkView(revealed, verificationCode: code);
          } else {
            activeDeviceLink = _linkView(link);
          }
        } catch (_) {
          // Fail closed: nothing verified before stands, so approval is
          // impossible until a refresh passes every check.
          final previous = activeDeviceLink;
          if (previous != null) {
            activeDeviceLink = DeviceLinkV3View(
              id: previous.id,
              state: previous.state,
              expiresAt: previous.expiresAt,
              claimedDeviceName: previous.claimedDeviceName,
            );
          }
          rethrow;
        }
      });

  DeviceLinkV3View _linkView(DeviceLinkV3Record link,
          {String verificationCode = ''}) =>
      DeviceLinkV3View(
        id: link.id,
        state: link.state,
        expiresAt: DateTime.parse(link.fields['expires_at'] as String),
        claimedDeviceName: link.fields['claimed_device_name'] as String?,
        verificationCode: verificationCode,
      );

  /// The safety code of [link]'s claim. Native verifies the relayed
  /// transcript hash and confirmation tag against the link secret before it
  /// releases a code; a claim already accepted (and committed) before is read
  /// back instead of accepted twice.
  Future<String> _acceptedVerification(K2TransferCryptoService crypto,
      Session current, DeviceLinkV3Record link) async {
    final secret = _activeLinkSecret;
    if (secret == null || DateTime.now().isAfter(_linkExpiry(link))) {
      throw StateError('Device-link secret is unavailable');
    }
    final id = K2TransferId(canonicalizeServerOrigin(current.baseUrl), link.id);
    final transcript = link.bytes('transcript_hash');
    K2Verification? known;
    try {
      known = (await crypto.k2Inspect(id)).verification;
    } on Object {
      known = null;
    }
    if (known != null) {
      if (!_constantTimeBytesEqual(known.transcriptHash, transcript) ||
          !_constantTimeBytesEqual(known.claimTag, link.bytes('claim_tag'))) {
        throw StateError('Device-link transcript was substituted');
      }
      return known.sas;
    }
    final sourceRandom = _activeLinkSourceRandom;
    if (sourceRandom == null) {
      throw StateError('Device-link random is unavailable');
    }
    // Native refuses unless this device's random opens the commitment in
    // the context, so a substituted commitment cannot be accepted.
    final verification = await crypto.k2SourceAccept(
      K2LinkContext(
        id: id,
        accountId: link.accountId,
        nonce: link.bytes('link_nonce'),
        sourceDeviceId: current.deviceId!,
        sourceSigningKey: link.bytes('existing_signing_key'),
        recipientDeviceId: link.recipientDeviceId!,
        recipientSigningKey: link.bytes('claimed_signing_key'),
        transferPublicKey: link.bytes('transfer_public_key'),
        sourceCommitment: link.bytes('source_commitment'),
        recipientRandom: link.bytes('recipient_random'),
      ),
      secret,
      originalExpiresAt: _linkExpiry(link).millisecondsSinceEpoch,
      transcriptHash: transcript,
      claimTag: link.bytes('claim_tag'),
      sourceRandom: sourceRandom,
    );
    return verification.sas;
  }

  DateTime _linkExpiry(DeviceLinkV3Record link) =>
      DateTime.parse(link.fields['expires_at'] as String);

  /// Reveals this device's committed random for the claim it accepted, once
  /// (an exact repeat is accepted). A link that already holds another random
  /// was not revealed by this device: refused.
  Future<DeviceLinkV3Record> _revealSourceRandom(
      ApiClient client, Session current, DeviceLinkV3Record link) async {
    final random = _activeLinkSourceRandom;
    if (random == null) {
      throw StateError('Device-link random is unavailable');
    }
    if (link.fields.containsKey('source_random')) {
      if (!_constantTimeBytesEqual(link.bytes('source_random'), random)) {
        throw StateError('Device-link reveal was substituted');
      }
      return link;
    }
    return client.revealDeviceLinkV3(current, link, random);
  }

  /// Confirms the code typed from the new device and approves it. The
  /// native confirmation is committed with the transfer record before the
  /// approval tag leaves the device; the rest (approval POST, native apply,
  /// the history copy) resumes from that record after any failure.
  Future<void> approveActiveDeviceLink(String verificationCode) async {
    await _runScoped(Ops.deviceLink, () async {
      final current = session;
      final client = api;
      final view = activeDeviceLink;
      final link = _activeLinkRecord;
      if (current == null ||
          client == null ||
          view == null ||
          link == null ||
          link.id != view.id) {
        return;
      }
      final crypto = _k2;
      _requireLinkOrigin(current, client);
      if (_activeLinkSecret == null ||
          DateTime.now().isAfter(view.expiresAt) ||
          link.state != 'claimed' ||
          view.verificationCode.isEmpty ||
          link.recipientDeviceId == null) {
        throw UserFacingException(l10n.deviceLinkRefreshFirst);
      }
      final origin = canonicalizeServerOrigin(current.baseUrl);
      try {
        await crypto.k2SourceConfirm(
          K2TransferId(origin, link.id),
          verificationCode.trim(),
          recipientDeviceId: link.recipientDeviceId!,
          claimRequestHash: link.fields['claim_request_hash'] as String,
        );
      } on NativeCryptoException {
        throw UserFacingException(l10n.deviceLinkCodeMismatch);
      }
      _clearLinkSecret();
      try {
        final row = await localStore.loadHistoryTransfer(origin, link.id);
        if (row == null) throw StateError('The approval was not stored');
        final approved = await _finishSourceApproval(row, current);
        _activeLinkRecord = approved;
        activeDeviceLink = _linkView(approved);
      } finally {
        unawaited(resumeHistoryTransfers());
      }
    });
  }

  /// The approval half of the source, safe to repeat: the tag from the
  /// committed confirmation, the approval POST (an exact replay is accepted),
  /// and the native apply (a repeat with the same time is a no-op).
  Future<DeviceLinkV3Record> _finishSourceApproval(
      HistoryTransferProgress row, Session current) async {
    final crypto = _k2;
    final client = _linkClient(row.origin);
    final id = K2TransferId(row.origin, row.linkId);
    final request = await crypto.k2SourceApprovalRequest(id);
    final link = await client.deviceLinkV3(current, row.linkId);
    final stored = _linkRowPayload(row)['claim_request_hash'];
    if (stored is! String || link.fields['claim_request_hash'] != stored) {
      throw const K2TransferException('the claim changed');
    }
    final DeviceLinkV3Record approved;
    switch (link.state) {
      case 'claimed':
        // L1: the change-2 version names the new device with the signing
        // key of the transcript native verified (claim tag and typed code)
        // before it released the approval tag; a server record that no
        // longer matches that transcript is refused first.
        //
        // The record was fetched again just now, so its fields are the
        // server's word: comparing its `transcript_hash` field with native's
        // proves nothing about `claimed_device_id` or `claimed_signing_key`.
        // The transcript is recomputed from the very fields the version will
        // name and must equal the one native verified, and the recipient
        // must be the device the confirmation stored.
        final verified = (await crypto.k2Inspect(id)).verification;
        final recipient = link.recipientDeviceId;
        if (recipient == null ||
            recipient != row.peerDeviceId ||
            link.origin != row.origin ||
            link.accountId != current.accountId) {
          throw const K2TransferException('the claim changed');
        }
        final recipientKey = link.bytes('claimed_signing_key');
        final transcript = deviceLinkV3TranscriptHash(K2LinkContext(
          id: id,
          accountId: link.accountId,
          nonce: link.bytes('link_nonce'),
          sourceDeviceId: current.deviceId!,
          sourceSigningKey: link.bytes('existing_signing_key'),
          recipientDeviceId: recipient,
          recipientSigningKey: recipientKey,
          transferPublicKey: link.bytes('transfer_public_key'),
          sourceCommitment: link.bytes('source_commitment'),
          recipientRandom: link.bytes('recipient_random'),
        ));
        if (!_constantTimeBytesEqual(verified.transcriptHash, transcript) ||
            !_constantTimeBytesEqual(
                verified.transcriptHash, link.bytes('transcript_hash'))) {
          throw const K2TransferException('the claim changed');
        }
        approved = await _approveLinkWithDeviceList(
            client, current, link, request.approvalTag,
            recipientDeviceId: recipient, recipientSigningKey: recipientKey);
      case 'approved' || 'consumed':
        if (link.fields['approval_tag'] != base64Encode(request.approvalTag)) {
          throw const K2TransferException('another approval is stored');
        }
        approved = link;
      default:
        throw const K2TransferException(k2ServerClosedReason);
    }
    await crypto.k2ApplyApproval(id, request.approvalTag,
        approvedAt: _linkTimeMs(approved.fields, 'approved_at'));
    return approved;
  }

  ApiClient _linkClient(String origin) {
    final current = api;
    if (current != null && current.baseUrl == origin) return current;
    _replaceApi(origin);
    if (api!.baseUrl != origin) {
      throw StateError('Device-link server was substituted');
    }
    return api!;
  }

  // ----------------------------------------------------- New device ---

  /// Claims a v3 link from the code the existing device shows. Everything
  /// that must survive a restart (identity, credentials, the exact signed
  /// claim) is stored before the claim is sent; a failed send is retried
  /// byte for byte by [completeDeviceLinkClaim].
  Future<void> claimDeviceLink(String baseUrl, String code) =>
      _runDeviceLinkClaim(() async {
        if (session != null) {
          throw UserFacingException(l10n.recoverySignedInAlready);
        }
        final crypto = _k2;
        final recovery = _linkRecoveryCrypto;
        if (_pendingLink != null) {
          throw UserFacingException(l10n.deviceLinkAlreadyPending);
        }
        // A stored enrollment the app did not load would refuse the claim
        // only after the server took it, so it is settled first.
        final stored = await localStore.loadPendingEnrollment();
        if (stored != null) {
          if (stored.kind == PendingEnrollment.kindDeviceLinkV3 &&
              await _adoptStoredLink(stored)) {
            throw UserFacingException(l10n.deviceLinkAlreadyPending);
          }
          if (stored.kind != PendingEnrollment.kindDeviceLinkV3) {
            throw UserFacingException(l10n.deviceLinkRecoveryInProgress);
          }
        }
        final secret = decodeDeviceLinkSecret(code);
        var enrolling = false;
        try {
          final locator = await cryptoService.deviceLinkLocator(secret);
          _replaceApi(baseUrl);
          final client = api!;
          final origin = client.baseUrl;
          final requestId = hexOf(_linkRandom(32));
          final reservation =
              await client.reserveDeviceLinkV3(locator, requestId);
          final fields = reservation.fields;
          final linkId = fields['id'] as String;
          final accountId = fields['account_id'] as String;
          final deviceId = fields['device_id'] as String;
          final challenge = base64Decode(fields['challenge'] as String);
          enrolling = true;
          final credential = await cryptoService.createEnrollmentCredential(
              EnrollmentReservation(
                  id: linkId,
                  accountId: accountId,
                  deviceId: deviceId,
                  challenge: challenge));
          final id = K2TransferId(origin, linkId);
          final expiresAt = _linkTimeMs(fields, 'expires_at');
          final received = await crypto.k2ReceiveBegin(
            K2LinkContext(
              id: id,
              accountId: accountId,
              nonce: base64Decode(fields['link_nonce'] as String),
              sourceDeviceId: fields['existing_device_id'] as String,
              sourceSigningKey:
                  base64Decode(fields['existing_signing_key'] as String),
              recipientDeviceId: deviceId,
              recipientSigningKey: credential.signingKey,
              transferPublicKey: List<int>.filled(32, 0),
              // Fixed before this device chooses its random (L1-3).
              sourceCommitment:
                  base64Decode(fields['source_commitment'] as String),
              recipientRandom: List<int>.filled(32, 0),
            ),
            secret,
            originalExpiresAt: expiresAt,
          );
          final claimToken = _linkToken();
          final deviceSecret = _linkToken();
          final sessionToken = _linkToken();
          final deviceName = _linkDeviceName();
          final proof = await crypto.k2EnrollmentProof(
            id,
            locator: locator,
            reservationRequestId: _linkUnhex(requestId),
            deviceName: deviceName,
            challenge: challenge,
            keyPackage: credential.deviceKeyPackage,
            claimTokenHash: _linkTokenHash(claimToken),
            deviceSecretHash: _linkTokenHash(deviceSecret),
            initialSessionHash: _linkTokenHash(sessionToken),
          );
          final claim = <String, Object?>{
            'code': locator,
            'protocol_version': deviceLinkV3Protocol,
            'server_origin': origin,
            'reservation_request_id': requestId,
            'enrollment_reservation_id': linkId,
            'device_name': deviceName,
            'device_key_package': base64Encode(credential.deviceKeyPackage),
            'signing_key': base64Encode(credential.signingKey),
            'transfer_public_key': base64Encode(received.transferPublicKey),
            'recipient_random': base64Encode(received.recipientRandom),
            'transcript_hash': base64Encode(received.transcriptHash),
            'claim_tag': base64Encode(received.claimTag),
            'claim_token_hash': hexOf(_linkTokenHash(claimToken)),
            'device_secret_hash': hexOf(_linkTokenHash(deviceSecret)),
            'initial_session_token_hash': hexOf(_linkTokenHash(sessionToken)),
            'challenge_signature': base64Encode(proof.signature),
          };
          final requestHash = hexOf(proof.requestHash);
          // Validates every field's shape before anything is stored.
          FrozenDeviceLinkV3Claim.fromJson(claim,
              requestHash: requestHash, transport: config.transport);
          final sealed = await recovery.sealPendingEnrollment();
          final pending = _PendingLinkV3(
            origin: origin,
            linkId: linkId,
            accountId: accountId,
            deviceId: deviceId,
            locator: locator,
            requestId: requestId,
            reservation: Map<String, Object?>.from(fields),
            claim: claim,
            claimRequestHash: requestHash,
            claimToken: claimToken,
            deviceSecret: deviceSecret,
            initialSessionToken: sessionToken,
            // No code before the existing device reveals its random.
            verificationCode: '',
            expiresAt: expiresAt,
          );
          await localStore
              .savePendingEnrollment(pending.toEnrollment(state: sealed));
          enrolling = false;
          _setPendingLink(pending, 'reserved');
          await _submitPendingClaim();
        } finally {
          secret.fillRange(0, secret.length, 0);
          if (enrolling) {
            try {
              await recovery.abandonPendingEnrollment();
            } catch (_) {}
          }
        }
      });

  /// A short, valid device name: `Linked <name>`, at most 64 UTF-8 bytes,
  /// never padded.
  String _linkDeviceName() {
    var name = 'Linked ${config.deviceName.trim().toLowerCase()}';
    while (utf8.encode(name).length > 64) {
      name = name.substring(0, name.length - 1);
    }
    name = name.trim();
    return name.isEmpty ? 'Linked device' : name;
  }

  /// Looks at the waiting link now and finishes it when approved.
  Future<void> completeDeviceLinkClaim() =>
      _runDeviceLinkClaim(_pollDeviceLinkClaim);

  /// Drops the waiting claim on this device. The server's link expires by
  /// itself; only the existing device can cancel it there.
  Future<void> abandonDeviceLinkClaim() => _enqueueSessionTransition(() async {
        if (session != null) return;
        await _abandonDeviceLinkClaimNow();
      });

  Future<void> _abandonDeviceLinkClaimNow() async {
    _linkPollTimer?.cancel();
    _linkPollTimer = null;
    final pending = _pendingLink;
    _pendingLink = null;
    pendingDeviceLinkClaim = null;
    notifyListeners();
    try {
      await localStore.deletePendingEnrollment(
          kind: PendingEnrollment.kindDeviceLinkV3,
          deviceId: pending?.deviceId);
    } catch (_) {}
    if (cryptoService case final RecoveryCryptoService crypto) {
      try {
        await crypto.abandonPendingEnrollment();
      } catch (_) {}
    }
  }

  /// Like [_run] for a signed-out device: its own busy and error under
  /// [Ops.deviceLinkClaim], and a 401 clears nothing (there is no session).
  Future<void> _runDeviceLinkClaim(Future<void> Function() body) =>
      _enqueueSessionTransition(() async {
        const op = Ops.deviceLinkClaim;
        _busyOps.add(op);
        _opErrors.remove(op);
        busy = true;
        error = null;
        notifyListeners();
        try {
          await body();
        } catch (err) {
          final message = describeError(err, l10n);
          _opErrors[op] = message;
          error = message;
        } finally {
          _busyOps.remove(op);
          busy = false;
          notifyListeners();
        }
      });

  void _setPendingLink(_PendingLinkV3 pending, String state) {
    _pendingLink = pending;
    pendingDeviceLinkClaim = DeviceLinkClaimView(
      state: state,
      verificationCode: pending.verificationCode,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(pending.expiresAt),
    );
  }

  /// Sends the stored signed claim (byte for byte: it is never rebuilt).
  Future<void> _submitPendingClaim() async {
    final pending = _pendingLink;
    if (pending == null) return;
    final client = _linkClient(pending.origin);
    final record = await client.submitDeviceLinkV3Claim(
      FrozenDeviceLinkV3Claim.fromJson(pending.claim,
          requestHash: pending.claimRequestHash, transport: config.transport),
      DeviceLinkV3Reservation.fromJson(pending.reservation),
    );
    if (record.recipientDeviceId != pending.deviceId ||
        record.accountId != pending.accountId) {
      throw StateError('Device-link identity was substituted');
    }
    final next = pending.withRecord(record.fields);
    await localStore.savePendingEnrollment(next.toEnrollment());
    if (!identical(_pendingLink, pending)) return;
    _setPendingLink(next, 'claimed');
    _scheduleLinkPoll();
  }

  void _scheduleLinkPoll() {
    _linkPollTimer?.cancel();
    _linkPollTimer = null;
    final pending = _pendingLink;
    if (_disposed || pending == null) return;
    _linkPollTimer = Timer(_linkPollInterval, () {
      _linkPollTimer = null;
      unawaited(completeDeviceLinkClaim());
    });
  }

  Future<void> _pollDeviceLinkClaim() async {
    final pending = _pendingLink;
    if (pending == null || session != null) return;
    if (pending.record == null) {
      await _submitPendingClaim();
      return;
    }
    final client = _linkClient(pending.origin);
    final expected = DeviceLinkV3Record.fromJson(pending.record!,
        transport: config.transport);
    final DeviceLinkV3Record status;
    try {
      status =
          await client.deviceLinkV3ClaimStatus(expected, pending.claimToken);
    } on ApiException catch (err) {
      // The real server answers a revoked, expired or unknown link with 400
      // invalid_device_link (it never sends the state 'revoked'); 401, 404
      // and 410 mean the claim or its credentials are gone.
      if (err.statusCode == 401 ||
          err.statusCode == 404 ||
          err.statusCode == 410 ||
          (err.statusCode == 400 && err.serverCode == 'invalid_device_link') ||
          _claimWindowPassed(pending)) {
        // The claim can never be approved.
        await _abandonDeviceLinkClaimNow();
        throw UserFacingException(l10n.deviceLinkEnded);
      }
      _scheduleLinkPoll();
      rethrow;
    } catch (_) {
      if (_claimWindowPassed(pending)) {
        await _abandonDeviceLinkClaimNow();
        throw UserFacingException(l10n.deviceLinkEnded);
      }
      _scheduleLinkPoll();
      rethrow;
    }
    if (!identical(_pendingLink, pending)) return;
    switch (status.state) {
      case 'revoked':
        await _abandonDeviceLinkClaimNow();
        throw UserFacingException(l10n.deviceLinkEnded);
      case 'approved' || 'consumed':
        // The record model refuses an approved link without a reveal, and
        // the approval tag binds the commitment through the transcript. The
        // native opening is not repeated here: it needs the link window,
        // and a late approval must still finish (transfer window).
        await _finishDeviceLink(pending, status);
      default:
        if (DateTime.now().millisecondsSinceEpoch > pending.expiresAt) {
          await _abandonDeviceLinkClaimNow();
          throw UserFacingException(l10n.deviceLinkEnded);
        }
        if (status.fields.containsKey('source_random') &&
            pending.verificationCode.isEmpty) {
          final code = await _revealedLinkCode(pending, status);
          if (!identical(_pendingLink, pending)) return;
          _setPendingLink(pending.withCode(code), 'claimed');
        }
        _scheduleLinkPoll();
    }
  }

  /// The code to show, from the random the existing device revealed. Native
  /// opens the commitment pinned when this device claimed; a reveal that is
  /// missing or does not open it ends the claim with its own message.
  Future<String> _revealedLinkCode(
      _PendingLinkV3 pending, DeviceLinkV3Record status) async {
    try {
      return await _k2.k2RevealSas(K2TransferId(pending.origin, pending.linkId),
          status.bytes('source_random'));
    } on Object {
      await _abandonDeviceLinkClaimNow();
      // Past the link window native refuses any reveal: that is an ended
      // link, not a mismatch.
      throw UserFacingException(
          DateTime.now().millisecondsSinceEpoch > pending.expiresAt
              ? l10n.deviceLinkEnded
              : l10n.deviceLinkCommitmentMismatch);
    }
  }

  /// A claim still waiting for approval whose link has expired: the server
  /// refuses it from now on, so a status error cannot be waited out. A
  /// claim already approved or consumed is left to the transfer window.
  bool _claimWindowPassed(_PendingLinkV3 pending) =>
      pending.record?['state'] == 'claimed' &&
      DateTime.now().millisecondsSinceEpoch > pending.expiresAt;

  /// The approval is in: completes at the server, then makes this device the
  /// account's active one in one local step that also starts the history
  /// transfer. The approval tag is verified natively before the server is
  /// asked to complete (on a scratch copy of the frozen pending state), and
  /// applied again as the first active commit of the transfer.
  Future<void> _finishDeviceLink(
      _PendingLinkV3 pending, DeviceLinkV3Record status) async {
    if (status.id != pending.linkId ||
        status.accountId != pending.accountId ||
        status.recipientDeviceId != pending.deviceId) {
      throw StateError('Device-link identity was substituted');
    }
    final client = _linkClient(pending.origin);
    final promoter = _linkPromotionCrypto;
    // The approval is checked natively against the context pinned when this
    // device claimed, before anything is completed at the server: a server
    // that substituted the link cannot make this device join without the
    // source's real approval.
    final approved = await _k2.k2VerifyPendingApproval(
      K2TransferId(pending.origin, pending.linkId),
      status.bytes('approval_tag'),
      approvedAt: _linkTimeMs(status.fields, 'approved_at'),
    );
    if (!approved) {
      await _abandonDeviceLinkClaimNow();
      throw UserFacingException(l10n.deviceLinkApprovalInvalid);
    }
    final next = pending.withRecord(status.fields);
    await localStore.savePendingEnrollment(next.toEnrollment());
    await client.completeDeviceLinkV3(status, pending.claimToken,
        hexOf(_linkTokenHash(pending.initialSessionToken)));
    final linked = Session(
      baseUrl: pending.origin,
      token: pending.initialSessionToken,
      accountId: pending.accountId,
      deviceId: pending.deviceId,
      deviceSecret: pending.deviceSecret,
    );
    final transfer = HistoryTransferProgress(
      origin: pending.origin,
      linkId: pending.linkId,
      direction: historyTransferIncoming,
      accountId: pending.accountId,
      deviceId: pending.deviceId,
      peerDeviceId: status.sourceDeviceId,
      stage: HistoryTransferStage.awaitingHandoff,
      expiresAt: _linkTimeMs(status.fields, 'transfer_expires_at'),
      payloadJson: jsonEncode(<String, Object?>{
        'approval_tag': base64Encode(status.bytes('approval_tag')),
        'approved_at': _linkTimeMs(status.fields, 'approved_at'),
        'claim_request_hash': pending.claimRequestHash,
        'claim_token': pending.claimToken,
      }),
    );
    await _journalLinkedDeviceAnchor(client, linked,
        signingKey: base64Decode(pending.claim['signing_key'] as String),
        approverDeviceId: pending.reservation['existing_device_id'] as String,
        approverSigningKey: base64Decode(
            pending.reservation['existing_signing_key'] as String));
    await _oweInitialKeyPackages(linked);
    await promoter.promotePendingEnrollment(linked,
        kind: PendingEnrollment.kindDeviceLinkV3,
        promotionId: pending.claimRequestHash,
        transfer: transfer);
    await _resumeDeviceListAnchor(linked);
    await _clearDeviceListAnchorJournal(linked);
    session = linked;
    _linkPollTimer?.cancel();
    _linkPollTimer = null;
    _pendingLink = null;
    pendingDeviceLinkClaim = null;
    await localStore.deletePendingEnrollment(
        kind: PendingEnrollment.kindDeviceLinkV3, deviceId: pending.deviceId);
    await _finishSignIn(() async {
      await _publishInitialMlsKeyPackages();
      await _refreshConversations(notify: true);
      await _refreshDevices();
    });
  }

  /// At start with no signed-in session: the waiting v3 claim, if any, and a
  /// look at it.
  Future<void> _loadPendingDeviceLink() async {
    if (!deviceLinkV3Available) return;
    final PendingEnrollment? stored;
    try {
      stored = await localStore.loadPendingEnrollment();
    } catch (_) {
      return;
    }
    if (stored == null || stored.kind != PendingEnrollment.kindDeviceLinkV3) {
      return;
    }
    if (await _adoptStoredLink(stored)) {
      unawaited(completeDeviceLinkClaim());
    }
  }

  /// Opens a stored v3 claim as the pending identity and shows it. An
  /// unreadable row can never be resumed and would block every later link,
  /// so it is deleted (its identity is dropped too).
  Future<bool> _adoptStoredLink(PendingEnrollment stored) async {
    final pending = _PendingLinkV3.fromEnrollment(stored);
    final state = stored.state;
    if (pending == null || state == null) {
      try {
        await localStore.deletePendingEnrollment(
            kind: PendingEnrollment.kindDeviceLinkV3,
            deviceId: stored.deviceId);
      } catch (_) {}
      return false;
    }
    try {
      await _linkRecoveryCrypto.resumePendingEnrollment(
        accountId: pending.accountId,
        deviceId: pending.deviceId,
        state: state,
      );
    } catch (_) {
      return false;
    }
    _setPendingLink(pending, pending.record == null ? 'reserved' : 'claimed');
    notifyListeners();
    return true;
  }

  // ------------------------------------------------ History transfer ---

  /// Moves every open history transfer of this device one step on: the
  /// existing device approves, prepares, uploads and waits for the receipt;
  /// the new device fetches, verifies, imports and acknowledges. Safe to call
  /// at any time (start, resume, after an approval): each stage resumes from
  /// its stored row, and a call while one runs does nothing. A copy that
  /// cannot finish is abandoned locally; a temporary failure is tried again
  /// later.
  Future<void> resumeHistoryTransfers() async {
    final current = session;
    if (_transfersRunning || _disposed || current == null) return;
    if (!deviceLinkV3Available) return;
    _transfersRunning = true;
    final generation = _sessionGeneration;
    var again = false;
    var failed = false;
    var ended = false;
    try {
      final crypto = _k2;
      final origin = canonicalizeServerOrigin(current.baseUrl);
      try {
        await crypto.k2ExpireTransfers();
      } catch (_) {}
      final rows = <HistoryTransferProgress>[
        for (final row in await localStore.loadHistoryTransfers())
          if (row.origin == origin && row.deviceId == current.deviceId) row,
      ];
      if (rows.isEmpty) {
        _transferStatus(null);
        return;
      }
      final directory = await _transferDirectory();
      final transport = historyTransferTransportFactory?.call(origin) ??
          HistoryTransferClient(baseUrl: origin, transport: config.transport);
      try {
        final service = HistoryTransferService(
            crypto: crypto, localStore: localStore, transport: transport);
        for (final row in rows) {
          if (_disposed ||
              generation != _sessionGeneration ||
              !identical(session, current)) {
            return;
          }
          final auth = HistorySessionAuth(current.token);
          final id = K2TransferId(row.origin, row.linkId);
          try {
            if (row.direction == historyTransferIncoming) {
              await service.receive(id,
                  auth: auth, downloadDirectory: '$directory/incoming');
            } else {
              if (row.stage == HistoryTransferStage.approving) {
                await _finishSourceApproval(row, current);
                // The export names conversations from the stored list; make
                // it the server's current one first (it is otherwise only
                // saved at some refreshes).
                await _refreshConversations(notify: false);
              }
              final next = await service.send(id,
                  sessionToken: current.token,
                  cacheDirectory: '$directory/source');
              if (next.stage != HistoryTransferStage.acknowledged) {
                again = true;
              }
            }
          } on K2TransferException {
            // A refusal that waiting cannot cure: this copy is over. The
            // history already imported stays.
            ended = true;
            try {
              await service.abandon(id, auth);
            } catch (_) {}
          } on ApiException catch (err) {
            // 401: the session is the sync loop's to settle, not ours. A 404
            // before the source has uploaded is the wait for it.
            if (err.statusCode == 404) {
              again = true;
            } else if (err.statusCode != 401) {
              failed = true;
            }
          } catch (_) {
            failed = true;
          } finally {
            await _settleImportedHistory(row);
          }
        }
      } finally {
        if (transport is HistoryTransferClient) transport.close();
      }
      if (generation != _sessionGeneration || !identical(session, current)) {
        return;
      }
      final left = [
        for (final row in await localStore.loadHistoryTransfers())
          if (row.origin == origin && row.deviceId == current.deviceId) row,
      ];
      if (left.isEmpty) {
        _transferStatus(ended
            ? HistoryTransferStatus(
                incoming: rows.first.direction == historyTransferIncoming,
                phase: HistoryTransferPhase.ended)
            : null);
      } else {
        final first = left.first;
        _transferStatus(HistoryTransferStatus(
          incoming: first.direction == historyTransferIncoming,
          phase: failed
              ? HistoryTransferPhase.failed
              : first.stage == HistoryTransferStage.uploaded ||
                      first.stage == HistoryTransferStage.awaitingHandoff
                  ? HistoryTransferPhase.waiting
                  : HistoryTransferPhase.working,
        ));
        again = again || first.direction == historyTransferIncoming;
      }
    } catch (_) {
      failed = true;
    } finally {
      _transfersRunning = false;
    }
    if (again || failed) {
      _scheduleTransferResume(
          failed ? _transferFailureInterval : _transferRetryInterval);
    }
  }

  /// A recipient whose import committed shows the copied chats, even when the
  /// ACK after it failed.
  Future<void> _settleImportedHistory(HistoryTransferProgress row) async {
    if (row.direction != historyTransferIncoming) return;
    try {
      final after =
          await localStore.loadHistoryTransfer(row.origin, row.linkId);
      if (after == null ||
          after.stage == HistoryTransferStage.imported ||
          after.stage == HistoryTransferStage.acknowledged) {
        await refreshCopiedHistory();
      }
    } catch (_) {}
  }

  /// Hides the notice of a copy that ended.
  void dismissHistoryCopyNotice() {
    if (historyTransferStatus?.phase == HistoryTransferPhase.ended) {
      _transferStatus(null);
    }
  }

  void _transferStatus(HistoryTransferStatus? next) {
    final previous = historyTransferStatus;
    if (previous?.incoming == next?.incoming &&
        previous?.phase == next?.phase) {
      return;
    }
    historyTransferStatus = next;
    notifyListeners();
  }

  void _scheduleTransferResume(Duration delay) {
    _transferTimer?.cancel();
    _transferTimer = null;
    if (_disposed || session == null) return;
    _transferTimer = Timer(delay, () {
      _transferTimer = null;
      unawaited(resumeHistoryTransfers());
    });
  }

  Future<String> _transferDirectory() async {
    final provider = historyTransferDirectory;
    final base = provider != null
        ? await provider()
        : '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}k2';
    return base;
  }

  /// Clears every in-memory trace of a link and a transfer (sign-out,
  /// dispose). The stored rows stay: a kept device identity resumes them.
  void _resetDeviceLinkState() {
    activeDeviceLink = null;
    _activeLinkRecord = null;
    _clearLinkSecret();
    pendingDeviceLinkClaim = null;
    _pendingLink = null;
    _linkPollTimer?.cancel();
    _linkPollTimer = null;
    _transferTimer?.cancel();
    _transferTimer = null;
    historyTransferStatus = null;
  }
}
