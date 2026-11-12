// C7 full mode inside the native service (docs/designs/C7-channel-history.md,
// decisions 2 to 5): records under C4 authority, per-channel chains,
// generation keys, the rekey at a removal merge, `history_sync` slots and
// duties, and the `keyless` and `unsure` states. Every state change is
// returned as settings for the same local transaction as the MLS step that
// causes it (decision 5, "One local transaction").
part of 'native_crypto_service.dart';

/// A newcomer asks for its `history_sync` when none arrived this long after
/// its Welcome (decision 5, `history_sync_request`).
const Duration c7RequestDelay = Duration(seconds: 60);

/// Members other than the committer wait [c7FallbackBase] plus up to
/// [c7FallbackPerMember] per member at random, at most [c7FallbackCap],
/// before sending a `history_sync` of their own (decision 5, "Duty").
const Duration c7FallbackBase = Duration(seconds: 20);
const Duration c7FallbackPerMember = Duration(seconds: 2);
const Duration c7FallbackCap = Duration(minutes: 10);

/// Posts sealed under a generation key. Targeted actions (edit, delete,
/// reaction, pin, poll vote and close) stay under random keys until each
/// local row records the period it was sealed in (decision 7, not built:
/// a gap for newcomers, never a leak). Control payloads never are.
const Set<AppPayloadType> c7HistoryPostTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.attachmentManifest,
  AppPayloadType.poll,
};

const Map<String, String?> _c7None = <String, String?>{};

extension _C7Engine on NativeCryptoService {
  bool _c7Active(String conversationId) =>
      c7SealedBodies &&
      c7CommunityKind(_authority?.conversationKind(conversationId));

  String? _c7CommunityOf(String conversationId) => switch (_authority) {
        final ConversationCommunitySource source =>
          source.conversationCommunity(conversationId),
        _ => null,
      };

  Future<C7GroupState> _c7LoadGroup(String conversationId) async =>
      C7GroupState.decode(
          await localStore.loadSetting(c7GroupSetting(conversationId)));

  Future<C7ChannelBook> _c7LoadBook(
          String conversationId, String channelId) async =>
      C7ChannelBook.decode(
          await localStore
              .loadSetting(c7ChannelSetting(conversationId, channelId)),
          channelId,
          conversationId);

  /// The channels a `history_sync` from this device names besides those it
  /// keeps a chain for: the server's list and a private group's own channel
  /// (decision 5, "Channels named, not assumed").
  Set<String> _c7KnownChannels(String conversationId, C7GroupState group) {
    final authority = _authority;
    return <String>{
      ...group.channels,
      if (authority is C7ChannelListSource)
        ...(authority as C7ChannelListSource).c7Channels(conversationId),
      if (_c7PrivateChannel(conversationId) case final String channel) channel,
    };
  }

  /// The settings that store [group] and [books] (each book's channel joins
  /// the group's channel list).
  Map<String, String?> _c7Put(String conversationId, C7GroupState group,
      Iterable<C7ChannelBook> books) {
    final out = <String, String?>{};
    final channels = <String>{...group.channels};
    for (final book in books) {
      out[c7ChannelSetting(conversationId, book.channelId)] = book.encode();
      channels.add(book.channelId);
    }
    out[c7GroupSetting(conversationId)] =
        group.copyWith(channels: channels).encode();
    return out;
  }

  Map<String, String?> _c7Wipe(String conversationId, C7GroupState group) =>
      <String, String?>{
        c7GroupSetting(conversationId): null,
        for (final channel in group.channels)
          c7ChannelSetting(conversationId, channel): null,
      };

  int _c7NowMs() => _clock().toUtc().millisecondsSinceEpoch;

  int _c7FallbackDelayMs(String conversationId) {
    int members;
    try {
      members = _requiredDevice().groupMembers(conversationId).length;
    } on Object {
      members = 2;
    }
    final spread = c7FallbackPerMember.inMilliseconds * members;
    final delay = c7FallbackBase.inMilliseconds +
        (spread <= 0 ? 0 : Random.secure().nextInt(spread + 1));
    return delay > c7FallbackCap.inMilliseconds
        ? c7FallbackCap.inMilliseconds
        : delay;
  }

  /// The account and signing key of [deviceId] in the group's current tree,
  /// or null when it holds no leaf there (decision 8: records and slots are
  /// checked only against keys in the tree).
  ({String accountId, Uint8List key})? _c7TreeKey(
      String conversationId, String deviceId) {
    try {
      for (final leaf in _requiredDevice().groupMembers(conversationId)) {
        if (utf8.decode(leaf.deviceId) == deviceId) {
          return (
            accountId: utf8.decode(leaf.accountId),
            key: Uint8List.fromList(leaf.signingKey),
          );
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// D80 and C4: a record's actor is an owner or admin in the verified role
  /// record the app holds (a private channel's group is judged by its
  /// shared group's, which the authority maps). No record, no authority.
  bool _c7MayRecord(String conversationId, String accountId) {
    final authority = _authority;
    if (authority is! VerifiedRoleSource) return false;
    final GovernanceState? record;
    try {
      record = (authority as VerifiedRoleSource).governanceOf(conversationId);
    } on Object {
      return false;
    }
    return record != null && record.rankOf(accountId) >= BuiltInRole.admin.rank;
  }

  /// A record applied after this device already merged a later removal
  /// opened a generation that removal closes: the removal's generation is
  /// derived from the kept root (decision 5, "Rekey").
  C7ChannelBook _c7CatchUp(
      C7ChannelBook book, C7GroupState group, String communityId) {
    final root = group.root;
    final rootEpoch = group.rootEpoch;
    if (root == null ||
        rootEpoch == null ||
        book.mode != c7ModeFull ||
        book.gens.isEmpty ||
        book.gens.last.epoch >= rootEpoch) {
      return book;
    }
    return book.rekey(
        rootEpoch,
        C7Keys(bindings).rekeyChk(
            root: root, communityId: communityId, channelId: book.channelId));
  }

  // ---- commits and Welcomes -------------------------------------------------

  /// The C7 change a merged commit makes, for the same MLS transition. Empty
  /// while C7 is off or outside community conversations. A commit that
  /// removed this device deletes the group's C7 state (the re-add wipe). A
  /// removal rekeys every `full` channel of the group from the exporter root
  /// MLS returned; every membership commit fixes the slot snapshot and the
  /// `history_sync` duty, due at once when this device committed ([own])
  /// and after a jittered delay otherwise.
  Future<Map<String, String?>> _c7Commit(
      String conversationId, C7CommitOutcome outcome,
      {required bool own}) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    final next = group.afterCommit(outcome);
    if (next == null) return _c7Wipe(conversationId, group);
    if (!outcome.membership) return _c7None;
    final epoch = outcome.newEpoch;
    final community = _c7CommunityOf(conversationId);
    final root = outcome.removedAny ? outcome.root : null;
    final books = <C7ChannelBook>[];
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      books.add(root != null && community != null
          ? book.rekey(
              epoch,
              C7Keys(bindings).rekeyChk(
                  root: root, communityId: community, channelId: channel))
          : book);
    }
    final due = _c7NowMs() + (own ? 0 : _c7FallbackDelayMs(conversationId));
    return _c7Put(
      conversationId,
      next.withSnapshot(
        epoch,
        <String, C7SlotSnapshot>{
          for (final book in books) book.channelId: book.snapshot(epoch),
        },
        due,
      ),
      books,
    );
  }

  /// A Welcome made this device a newcomer at [joinEpoch]: state left under
  /// the group id from an earlier membership is dropped (Trace 4, the re-add
  /// wipe) and the request timer starts.
  Future<Map<String, String?>> _c7Welcome(
      String conversationId, int joinEpoch) async {
    if (!c7SealedBodies) return _c7None;
    final old = await _c7LoadGroup(conversationId);
    return <String, String?>{
      ..._c7Wipe(conversationId, old),
      c7GroupSetting(conversationId): C7GroupState.joined(joinEpoch,
              requestDueAtMs: _c7NowMs() + c7RequestDelay.inMilliseconds)
          .encode(),
    };
  }

  // ---- unsure ---------------------------------------------------------------

  /// This device met a message in [conversationId] it could not fully apply
  /// (decision 5, "Unsure"): every `full` channel of the group keeps the
  /// group's current epoch as its miss epoch, and an `ok` one turns
  /// `unsure`. The current epoch, never the message's own: a server could
  /// label a message low, and nothing at or below the miss epoch clears it.
  Future<Map<String, String?>> _c7Miss(String conversationId) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (group.channels.isEmpty) return _c7None;
    final int epoch;
    try {
      epoch = _requiredDevice().groupEpoch(conversationId).epoch;
    } on Object {
      return _c7None;
    }
    final changed = <C7ChannelBook>[];
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      if (book.mode == c7ModeFull) changed.add(book.markUnsure(epoch));
    }
    return changed.isEmpty ? _c7None : _c7Put(conversationId, group, changed);
  }

  /// The `gen` trigger for a live post (decision 5, "Unsure"): an `ok` `full`
  /// channel whose post at [epoch] was not sealed under the generation this
  /// device holds as current there turns `unsure`, unless the signed `gen`
  /// is 0 or below the current period's start. A live member reads the
  /// signed `gen` only by checking the signature against those candidates:
  /// 0 and the past generations it remembers. A sender in an older period
  /// whose `gen` this device never held is so taken as out of step (a gap,
  /// never a leak).
  Future<Map<String, String?>> _c7GenCheck({
    required ReceivedMessageEnvelope envelope,
    required String channelId,
    required int epoch,
    required C7Opened opened,
  }) async {
    final conversationId = envelope.conversationId;
    final community = _c7CommunityOf(conversationId);
    if (community == null) return _c7None;
    final book = await _c7LoadBook(conversationId, channelId);
    if (book.mode != c7ModeFull || book.status != C7Status.ok) return _c7None;
    final gen = book.genAt(conversationId, epoch);
    final key = gen?.key;
    if (key != null && gen!.epoch != 0) {
      final expected = C7Keys(bindings).postBodyKey(
        chk: key,
        communityId: community,
        channelId: channelId,
        senderDeviceId: envelope.senderDeviceId,
        actionId: envelope.idempotencyKey,
      );
      final same = c7SameBytes(expected, opened.bodyKey);
      expected.fillRange(0, expected.length, 0);
      if (same) return _c7None;
    }
    final signer = _c7TreeKey(conversationId, envelope.senderDeviceId);
    if (signer != null) {
      final start = book.periodStart ?? 0;
      for (final candidate in <int>{
        0,
        for (final past in book.pastGens)
          if (past < start) past,
      }) {
        final bool valid;
        try {
          valid = bindings.c7Verify(
            domain: c7PostSignatureDomain,
            publicKey: signer.key,
            message: c7PostSignedFields(
              communityId: community,
              channelId: channelId,
              actionId: envelope.idempotencyKey,
              groupId: conversationId,
              epoch: epoch,
              senderDeviceId: envelope.senderDeviceId,
              generation: candidate,
              paddedVap1: opened.paddedVap1,
            ),
            signature: opened.signature,
          );
        } on Object {
          continue;
        }
        if (valid) return _c7None;
      }
    }
    final group = await _c7LoadGroup(conversationId);
    return _c7Put(conversationId, group, <C7ChannelBook>[
      book.markUnsure(_requiredDevice().groupEpoch(conversationId).epoch),
    ]);
  }

  // ---- records ----------------------------------------------------------------

  /// A `history_change` proposal that decrypted live (decision 4). Checked
  /// before the table: a sender its list has not removed (D119), freshness
  /// against the membership floor, the actor's authority in the verified
  /// role record, and the signature against the actor's key in the current
  /// tree. An invalid record leaves its hidden action row and changes
  /// nothing. Returns the settings for the message's transition.
  Future<Map<String, String?>> _c7ApplyProposal(
    ReceivedMessageEnvelope envelope,
    DecryptedAppPayload payload, {
    required String? routeChannel,
    required int? epoch,
    required LeafVerdict? verdict,
  }) async {
    final conversationId = envelope.conversationId;
    if (!_c7Active(conversationId) ||
        epoch == null ||
        verdict != LeafVerdict.approved) {
      return _c7None;
    }
    final community = _c7CommunityOf(conversationId);
    final channel = payload.channelId ?? routeChannel;
    if (community == null || channel == null) return _c7None;
    final C7CompactRecord compact;
    final C7Record record;
    try {
      compact =
          C7CompactRecord.decode(base64Decode(payload.body['r']! as String));
      record = compact.expand(C7RecordContext(
        communityId: utf8.encode(community),
        channelId: utf8.encode(channel),
        groupId: utf8.encode(conversationId),
        epoch: epoch,
        actorDeviceId: utf8.encode(envelope.senderDeviceId),
      ));
    } on Object {
      return _c7None;
    }
    // A move is C3's conversion, not built: it stays an invalid record.
    if (record.reason == c7ReasonMove) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (record.epoch < group.floor) return _c7None;
    if (!_c7MayRecord(conversationId, envelope.senderAccountId)) {
      return _c7None;
    }
    final signer = _c7TreeKey(conversationId, envelope.senderDeviceId);
    if (signer == null ||
        signer.accountId != envelope.senderAccountId ||
        !c7VerifyRecord(bindings, record, signer.key)) {
      return _c7None;
    }
    final book = await _c7LoadBook(conversationId, channel);
    final step = book.applyRecord(record, record.encode(),
        source: C7Source.proposalLive, key: compact.key);
    if (step.row == C7Row.invalid) return _c7None;
    return _c7Put(conversationId, group,
        <C7ChannelBook>[_c7CatchUp(step.book, group, community)]);
  }

  /// This device's own record came back in sync order ([actionId]): it is
  /// applied now, or reported stale (sequenced after a membership commit:
  /// the app proposes it again) or lost (decision 4, "Own proposals").
  Future<Map<String, String?>> _c7OwnEcho(
      String conversationId, String actionId) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    final community = _c7CommunityOf(conversationId);
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      final pending = book.pending;
      if (pending == null || pending.actionId != actionId) continue;
      final record = pending.full;
      if (record.epoch < group.floor) {
        // Kept, so the app can propose the same setting again.
        return _c7Put(conversationId, group,
            <C7ChannelBook>[book.copyWith(ownNotice: 'stale')]);
      }
      if (!_c7MayRecord(conversationId, _accountId!)) {
        return _c7Put(conversationId, group, <C7ChannelBook>[
          book.copyWith(clearPending: true, ownNotice: 'lost'),
        ]);
      }
      final step = book.applyRecord(record, pending.record,
          source: C7Source.proposalLive, key: pending.key, ownProposal: true);
      return _c7Put(conversationId, group, <C7ChannelBook>[
        community == null ? step.book : _c7CatchUp(step.book, group, community),
      ]);
    }
    return _c7None;
  }

  // ---- history_sync -----------------------------------------------------------

  /// A live `history_sync` (decision 5). A member checks each reported head
  /// against its chain (the actor's key in the tree, the actor's authority),
  /// takes a key it was missing, clears `unsure` for its own head and key,
  /// and settles its duty when the slots carry its own snapshot. A newcomer
  /// adopts heads and generations on the word of its MLS-authenticated
  /// sender when the head's actor has left (trust limits). A `history_sync`
  /// whose slots do not all open is a message this device could not fully
  /// apply.
  Future<Map<String, String?>> _c7ApplySync(
    ReceivedMessageEnvelope envelope,
    DecryptedAppPayload payload,
    Uint8List trailer, {
    required LeafVerdict? verdict,
  }) async {
    final conversationId = envelope.conversationId;
    if (!_c7Active(conversationId)) return _c7None;
    final community = _c7CommunityOf(conversationId);
    if (community == null) return _c7None;
    final slots = c7OpenSlots(
      bindings: bindings,
      body: payload.body,
      trailer: trailer,
      communityId: community,
      conversationId: conversationId,
      senderDeviceId: envelope.senderDeviceId,
      actionId: envelope.idempotencyKey,
    );
    if (slots == null) return _c7Miss(conversationId);
    // D119: a leaf its list removed hands nothing over.
    if (verdict != LeafVerdict.approved) return _c7None;
    final forEpoch = payload.body['for_epoch']! as int;
    var group = await _c7LoadGroup(conversationId);
    final known = _c7KnownChannels(conversationId, group);
    final mine = group.snapshots[forEpoch];
    var matches = mine != null;
    final listed = <String>{for (final slot in slots) slot.channelId};
    final changed = <C7ChannelBook>[];
    for (final slot in slots) {
      final own = mine?[slot.channelId];
      if (own != null &&
          own.key != null &&
          (!c7SameBytes(own.key, slot.key) ||
              !c7SameBytes(own.plain, slot.plain))) {
        matches = false;
      }
      if (!known.contains(slot.channelId) || slot.headIsZero) continue;
      final C7Record record;
      final C7GenerationEntry? entry;
      try {
        record = C7Record.decode(slot.head);
        entry = C7GenerationEntry.decode(slot.entry);
      } on Object {
        matches = false;
        continue;
      }
      if (utf8.decode(record.channelId) != slot.channelId ||
          utf8.decode(record.communityId) != community ||
          utf8.decode(record.groupId) != conversationId ||
          record.epoch > forEpoch ||
          record.reason == c7ReasonMove) {
        continue;
      }
      final book = await _c7LoadBook(conversationId, slot.channelId);
      final signer =
          _c7TreeKey(conversationId, utf8.decode(record.actorDeviceId));
      if (book.hasHead) {
        if (signer == null ||
            !c7VerifyRecord(bindings, record, signer.key) ||
            !_c7MayRecord(conversationId, signer.accountId)) {
          continue;
        }
      } else if (signer != null &&
          !c7VerifyRecord(bindings, record, signer.key)) {
        continue;
      }
      final step = book.applyRecord(record, Uint8List.fromList(slot.head),
          source: C7Source.report, key: slot.key, entry: entry);
      if (step.row == C7Row.invalid) continue;
      var next = _c7CatchUp(step.book, group, community);
      if (step.row == C7Row.noop && entry != null) {
        next = next.confirmedBySlot(forEpoch, slot.key, entry);
      }
      changed.add(next);
    }
    // Every channel this device hands a key over for must be in the slots.
    if (mine != null) {
      for (final entry in mine.entries) {
        if (entry.value.key != null && !listed.contains(entry.key)) {
          matches = false;
        }
      }
    }
    final duty = group.duties[forEpoch];
    if (matches && duty != null && !duty.settled) {
      group = group.withDuty(
          forEpoch, C7SyncDuty(dueAtMs: duty.dueAtMs, settled: true));
    }
    if (group.joinEpoch != null && forEpoch >= group.joinEpoch!) {
      group = group.copyWith(joinSynced: true, clearRequest: true);
    }
    return _c7Put(conversationId, group, changed);
  }

  /// A newcomer's `history_sync_request` (decision 5): a member holding the
  /// snapshot for that commit sends again after its jittered delay, unless a
  /// matching `history_sync` arrives first.
  Future<Map<String, String?>> _c7ApplyRequest(
      String conversationId, DecryptedAppPayload payload) async {
    if (!_c7Active(conversationId)) return _c7None;
    final forEpoch = payload.body['for_epoch'];
    if (forEpoch is! int) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (!group.snapshots.containsKey(forEpoch)) return _c7None;
    return _c7Put(
        conversationId,
        group.withDuty(
            forEpoch,
            C7SyncDuty(
                dueAtMs: _c7NowMs() + _c7FallbackDelayMs(conversationId))),
        const <C7ChannelBook>[]);
  }

  // ---- sending ------------------------------------------------------------------

  /// The generation a post of [type] in [channelId] seals under at [epoch],
  /// or null (a random key; I4).
  Future<C7Gen?> _c7SealGen(String conversationId, String? channelId,
      AppPayloadType type, int epoch) async {
    if (channelId == null ||
        !c7HistoryPostTypes.contains(type) ||
        !_c7Active(conversationId)) {
      return null;
    }
    final book = await _c7LoadBook(conversationId, channelId);
    return book.sealGenAt(epoch);
  }

  /// Queues one hidden C7 message (a record, a `history_sync` or its
  /// request). [channelId] is null for a group-level message. [build] makes
  /// the padded VAP1 and the trailer (a `history_sync`'s slots) from the
  /// action id; [settingsFor] the C7 settings that commit with the outbox
  /// row. C7 types carry no `frank` member and a random `frank_commit`
  /// (decision 3, "Franking"). Runs inside [_serial].
  Future<MessageEnvelope> _c7SendHidden(
    String conversationId, {
    required String? channelId,
    required int? layoutGeneration,
    required ({Uint8List vap1, Uint8List trailer}) Function(
            String actionId, int epoch)
        build,
    required Map<String, String?> Function(String actionId, int epoch)
        settingsFor,
    ({Uint8List chk, int generation})? seal,
  }) async {
    await _requireNotPaused(conversationId);
    await _requireApproved(conversationId);
    final community = _c7CommunityOf(conversationId);
    if (community == null || community.isEmpty) {
      throw StateError('C7 needs the community of this conversation');
    }
    final sharedGroup =
        _authority?.conversationKind(conversationId) == 'community_shared';
    if (sharedGroup && channelId != null && layoutGeneration == null) {
      throw StateError('a shared group channel needs its layout generation');
    }
    final previous = await _requiredState();
    final cursor = await localStore.loadSyncCursor();
    if (!await localStore.hasOutboxCapacity()) {
      throw const OutboxFullException();
    }
    try {
      final actionId = _randomIdempotencyKey();
      final deviceId = _deviceId!;
      final device = _requiredDevice();
      final epoch = device.groupEpoch(conversationId).epoch;
      final parts = build(actionId, epoch);
      final sealed = c7SealMessage(
        bindings: bindings,
        sign: (message) =>
            device.c7Sign(domain: c7PostSignatureDomain, message: message),
        communityId: community,
        conversationId: conversationId,
        channelId: channelId,
        senderDeviceId: deviceId,
        actionId: actionId,
        epoch: epoch,
        paddedVap1: parts.vap1,
        chk: seal?.chk,
        generation: seal?.generation ?? 0,
        trailer: parts.trailer,
      );
      final envelope = MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: actionId,
        ciphertext: device.encrypt(conversationId, sealed.reference),
        cryptoProtocol: 'mls10-openmls-v1',
        cryptoMetadata: <String, Object?>{
          'protocol_version': 1,
          'group_id': conversationId,
          'content_type': 'application',
          'payload_version': 1,
          if (channelId != null) 'channel_id': channelId,
          if (channelId != null && sharedGroup)
            'community_layout_generation': layoutGeneration,
          'mls_epoch': epoch,
        },
        frankCommit: _randomBytes(32),
        sealedBody: sealed.sealedBody,
      );
      await localStore.commitOutgoingApplicationTransition(
        OutgoingApplicationStateTransition(
          expectedCounter: previous.counter,
          expectedCursor: cursor,
          state: _sealNext(previous),
          envelope: envelope,
          messageEffects: <MessageEffect>[
            InsertMessageEffect(
              key: messageKey(deviceId, actionId),
              conversationId: conversationId,
              senderAccountId: _accountId!,
              senderDeviceId: deviceId,
              kind: LocalMessageKind.action,
              senderHidden: true,
              channelId: sharedGroup ? channelId : null,
              createdAt: _c7NowMs(),
              state: LocalMessageState.pending,
            ),
          ],
          c7Settings: settingsFor(actionId, epoch),
        ),
      );
      return envelope;
    } catch (_) {
      await _restorePrevious(previous);
      rethrow;
    }
  }

  Future<MessageEnvelope> _c7Propose(
    String conversationId,
    String channelId, {
    required bool full,
    required bool create,
    required int? layoutGeneration,
  }) async {
    if (!_c7Active(conversationId)) {
      throw StateError('C7 is off for this conversation');
    }
    final community = _c7CommunityOf(conversationId);
    if (community == null) throw StateError('C7 needs the community');
    final sharedGroup =
        _authority?.conversationKind(conversationId) == 'community_shared';
    if (!sharedGroup && channelId != _c7PrivateChannel(conversationId)) {
      throw StateError('a private group holds only its own channel');
    }
    if (!_c7MayRecord(conversationId, _accountId!)) {
      throw StateError('only owners and admins change the history setting');
    }
    final group = await _c7LoadGroup(conversationId);
    final book = await _c7LoadBook(conversationId, channelId);
    if (book.pending != null && book.ownNotice != 'stale') {
      throw StateError('a history change is already pending here');
    }
    final head = book.headRecord;
    if (create != (head == null && book.chain.highestSeq < 0)) {
      throw StateError(create
          ? 'this channel already has a history record'
          : 'a switch needs the record before it');
    }
    // A closed channel recovers with a switch above every seq seen,
    // chained from its own head (decision 4, row 3 or 5).
    final seq = create
        ? 0
        : (book.status == C7Status.closed
            ? book.chain.highestSeq + 1
            : head!.seq + 1);
    final key = Uint8List.fromList(_randomBytes(32));
    final device = _requiredDevice();
    C7Record? signed;
    return _c7SendHidden(
      conversationId,
      channelId: channelId,
      layoutGeneration: layoutGeneration,
      // A record that opens a key seals its own message under it, like a
      // post of the generation it opens (decision 3). Epoch 0 is `gen` 0.
      seal: full && device.groupEpoch(conversationId).epoch > 0
          ? (chk: key, generation: device.groupEpoch(conversationId).epoch)
          : null,
      build: (actionId, epoch) {
        final unsigned = C7Record(
          communityId: utf8.encode(community),
          channelId: utf8.encode(channelId),
          seq: seq,
          prev: head?.hash() ?? Uint8List(32),
          mode: full ? c7ModeFull : c7ModeMembersFromJoin,
          reason: create ? c7ReasonCreate : c7ReasonSwitch,
          groupId: utf8.encode(conversationId),
          epoch: epoch,
          closeGroupId: utf8.encode(conversationId),
          closeEpoch: epoch,
          chkCommit: full ? c7ChkCommitOf(key) : Uint8List(32),
          actorDeviceId: utf8.encode(_deviceId!),
          sig: Uint8List(64),
        );
        final sig = device.c7Sign(
            domain: c7HistorySignatureDomain, message: unsigned.signedFields());
        signed = C7Record(
          communityId: unsigned.communityId,
          channelId: unsigned.channelId,
          seq: seq,
          prev: unsigned.prev,
          mode: unsigned.mode,
          reason: unsigned.reason,
          groupId: unsigned.groupId,
          epoch: epoch,
          closeGroupId: unsigned.closeGroupId,
          closeEpoch: epoch,
          chkCommit: unsigned.chkCommit,
          actorDeviceId: unsigned.actorDeviceId,
          sig: sig,
        );
        final compact = C7CompactRecord(
          seq: seq,
          prev: unsigned.prev,
          mode: unsigned.mode,
          reason: unsigned.reason,
          closeEpoch: epoch,
          key: key,
          sig: sig,
        );
        return (
          vap1: AppPayloadCodec().encode(
            type: AppPayloadType.historyChange,
            conversationId: conversationId,
            senderDeviceId: _deviceId!,
            actionId: actionId,
            body: <String, Object?>{'r': base64Encode(compact.encode())},
            hidden: true,
            channelId: sharedGroup ? channelId : null,
          ),
          trailer: Uint8List(0),
        );
      },
      settingsFor: (actionId, _) =>
          _c7Put(conversationId, group, <C7ChannelBook>[
        book.copyWith(
          pending: C7Pending(
            actionId: actionId,
            sentAtMs: _c7NowMs(),
            record: signed!.encode(),
            key: key,
          ),
          clearNotice: true,
        ),
      ]),
    );
  }

  /// Sends the `history_sync` for the commit that produced [forEpoch] from
  /// the snapshot fixed at that merge, and settles the duty with it. Null
  /// when it is no longer owed.
  Future<MessageEnvelope?> _c7SendSync(
      String conversationId, int forEpoch) async {
    if (!_c7Active(conversationId)) return null;
    final group = await _c7LoadGroup(conversationId);
    final snapshot = group.snapshots[forEpoch];
    final duty = group.duties[forEpoch];
    final community = _c7CommunityOf(conversationId);
    if (snapshot == null || duty == null || duty.settled || community == null) {
      return null;
    }
    final settled = group.withDuty(
        forEpoch, C7SyncDuty(dueAtMs: duty.dueAtMs, settled: true));
    final extra = _c7KnownChannels(conversationId, group)
        .where((channel) => !snapshot.containsKey(channel))
        .toList();
    if (snapshot.isEmpty && extra.isEmpty) {
      // Nothing to name: the duty is settled with nothing sent.
      final previous = await _requiredState();
      await localStore.commitLocalMlsState(
        expectedCounter: previous.counter,
        expectedCursor: await localStore.loadSyncCursor(),
        state: _sealNext(previous),
        c7Settings: _c7Put(conversationId, settled, const <C7ChannelBook>[]),
      );
      return null;
    }
    return _c7SendHidden(
      conversationId,
      channelId: null,
      layoutGeneration: null,
      build: (actionId, _) {
        final parts = c7BuildHistorySync(
          bindings: bindings,
          communityId: community,
          conversationId: conversationId,
          senderDeviceId: _deviceId!,
          actionId: actionId,
          forEpoch: forEpoch,
          snapshot: snapshot,
          extraChannels: extra,
        );
        return (vap1: parts.body0, trailer: parts.slots);
      },
      settingsFor: (_, __) =>
          _c7Put(conversationId, settled, const <C7ChannelBook>[]),
    );
  }

  /// A newcomer's one request for the `history_sync` of its join.
  Future<MessageEnvelope?> _c7SendRequest(String conversationId) async {
    if (!_c7Active(conversationId)) return null;
    final group = await _c7LoadGroup(conversationId);
    final joinEpoch = group.joinEpoch;
    if (group.joinSynced || joinEpoch == null) return null;
    return _c7SendHidden(
      conversationId,
      channelId: null,
      layoutGeneration: null,
      build: (actionId, _) => (
        vap1: AppPayloadCodec().encode(
          type: AppPayloadType.historySyncRequest,
          conversationId: conversationId,
          senderDeviceId: _deviceId!,
          actionId: actionId,
          body: <String, Object?>{'for_epoch': joinEpoch},
          hidden: true,
        ),
        trailer: Uint8List(0),
      ),
      settingsFor: (_, __) => _c7Put(conversationId,
          group.copyWith(clearRequest: true), const <C7ChannelBook>[]),
    );
  }

  Future<List<C7Due>> _c7Due(Iterable<String> conversationIds) async {
    final now = _c7NowMs();
    final out = <C7Due>[];
    for (final conversationId in conversationIds) {
      if (!_c7Active(conversationId)) continue;
      final group = await _c7LoadGroup(conversationId);
      for (final entry in group.duties.entries) {
        if (!entry.value.settled && entry.value.dueAtMs <= now) {
          out.add(C7DueSync(conversationId, entry.key));
        }
      }
      final request = group.requestDueAtMs;
      if (request != null &&
          request <= now &&
          !group.joinSynced &&
          group.joinEpoch != null) {
        out.add(C7DueRequest(conversationId, group.joinEpoch!));
      }
      for (final channel in group.channels) {
        final book = await _c7LoadBook(conversationId, channel);
        final pending = book.pending;
        if (book.ownNotice == 'stale' && pending != null) {
          out.add(C7DueRepropose(conversationId, channel,
              full: pending.full.mode == c7ModeFull));
        }
      }
    }
    return out;
  }
}
