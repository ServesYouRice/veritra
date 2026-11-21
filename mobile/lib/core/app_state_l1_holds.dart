part of 'app_state.dart';

// L1 approval hold, shown (D94; docs/designs/L1-approved-device-list.md,
// "Results when a list is missing, stale or in conflict", and
// docs/designs/L1-approved-devices.md, "Hold states and the conflict
// reset"). The native service holds a conversation while any leaf is not
// approved now; this file tells the person which account holds it and why,
// lets them check again, and resets a contact's sticky list conflict once
// they choose to. Nothing here approves a leaf: only a verified pin or an
// MLS removal does, in the native service.

/// Why a conversation is held for one account's devices, most serious last.
enum ApprovalHoldReason {
  /// The account's list could not be read or verified yet.
  checking,

  /// The account has no list yet (from before L1): its devices wait until
  /// it reviews them once.
  waiting,

  /// A device the list approved once and removed since is still a leaf.
  removed,

  /// A device the list never approved is a leaf.
  unapproved,

  /// A validly signed statement forked the pinned list (sticky).
  conflict,
}

/// One account that holds a conversation, with the most serious reason
/// among its held leaves. [own] is this device's own account.
class ApprovalHoldAccount {
  const ApprovalHoldAccount({
    required this.accountId,
    required this.reason,
    required this.own,
  });

  final String accountId;
  final ApprovalHoldReason reason;
  final bool own;

  @override
  bool operator ==(Object other) =>
      other is ApprovalHoldAccount &&
      other.accountId == accountId &&
      other.reason == reason &&
      other.own == own;

  @override
  int get hashCode => Object.hash(accountId, reason, own);
}

/// How long "Check again" waits before it fetches the same lists again.
const Duration _l1RecheckSpacing = Duration(seconds: 5);

/// The longest one forced list read may take during "Check again".
const Duration _l1RecheckTimeout = Duration(seconds: 10);

/// The shown hold state of one session. Cleared with the session.
class _L1HoldState {
  final Map<String, List<ApprovalHoldAccount>> shown =
      <String, List<ApprovalHoldAccount>>{};
  final Map<String, DateTime> lastRecheck = <String, DateTime>{};
  final Set<String> rechecking = <String>{};

  void clear() {
    shown.clear();
    lastRecheck.clear();
    rechecking.clear();
  }
}

extension AppStateL1Holds on AppState {
  /// Runs [body]; when the approval hold refuses it, reads the chat's hold
  /// state at once so the banner shows why, then rethrows.
  Future<void> _noticeApprovalHold(
    String conversationId,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } on ConversationApprovalHeldException {
      unawaited(refreshApprovalHoldSummary(conversationId));
      rethrow;
    }
  }

  /// The accounts holding [conversationId], as last read (most serious
  /// first). Empty when it is not held or has not been read yet.
  List<ApprovalHoldAccount> approvalHoldAccounts(String conversationId) =>
      _l1Holds.shown[conversationId] ?? const <ApprovalHoldAccount>[];

  /// Whether "Check again" is running for [conversationId].
  bool approvalHoldRechecking(String conversationId) =>
      _l1Holds.rechecking.contains(conversationId);

  /// Reads which accounts hold [conversationId] from the stored leaf
  /// verdicts and pins (no network), and announces a change.
  Future<void> refreshApprovalHoldSummary(String conversationId) async {
    final pins = _deviceListPins;
    final current = session;
    if (pins == null || current == null) return;
    final generation = _sessionGeneration;
    final List<ApprovalHoldAccount> next;
    try {
      next = await _readApprovalHolds(pins, current, conversationId);
    } on Object {
      // Unreadable now: the banner keeps what it showed; read again later.
      return;
    }
    if (generation != _sessionGeneration) return;
    final before = _l1Holds.shown[conversationId] ?? const [];
    if (listEquals(before, next)) return;
    if (next.isEmpty) {
      _l1Holds.shown.remove(conversationId);
    } else {
      _l1Holds.shown[conversationId] = next;
    }
    notifyListeners();
  }

  Future<List<ApprovalHoldAccount>> _readApprovalHolds(
    DeviceListPins pins,
    Session current,
    String conversationId,
  ) async {
    final verdicts = <String, Set<LeafVerdict>>{};
    for (final leaf in await localStore.loadApprovalLeaves(conversationId)) {
      if (leaf.verdict == LeafVerdict.approved) continue;
      final account = utf8.decode(leaf.accountId, allowMalformed: true);
      verdicts.putIfAbsent(account, () => <LeafVerdict>{}).add(leaf.verdict);
    }
    final out = <ApprovalHoldAccount>[];
    for (final entry in verdicts.entries) {
      final account = entry.key;
      final pin = await localStore.loadDeviceListPin(account);
      final ApprovalHoldReason reason;
      if (pin != null && pin.conflict) {
        reason = ApprovalHoldReason.conflict;
      } else if (entry.value.contains(LeafVerdict.unapproved)) {
        reason = ApprovalHoldReason.unapproved;
      } else if (entry.value.contains(LeafVerdict.removed)) {
        reason = ApprovalHoldReason.removed;
      } else if (pin == null &&
          pins.lastState(account) == DeviceListState.empty) {
        reason = ApprovalHoldReason.waiting;
      } else {
        reason = ApprovalHoldReason.checking;
      }
      out.add(ApprovalHoldAccount(
        accountId: account,
        reason: reason,
        own: account == current.accountId,
      ));
    }
    out.sort((a, b) {
      final byReason = b.reason.index.compareTo(a.reason.index);
      return byReason != 0 ? byReason : a.accountId.compareTo(b.accountId);
    });
    return out;
  }

  /// Refreshes the shown holds of every held conversation and of every one
  /// shown before (a hold that cleared). Called at the end of a sync pass.
  Future<void> _refreshApprovalHoldSummaries() async {
    if (_deviceListPins == null) return;
    final ids = <String>{
      ...await localStore.loadHeldConversations(),
      ..._l1Holds.shown.keys,
    };
    for (final id in ids) {
      await refreshApprovalHoldSummary(id);
    }
  }

  /// "Check again": fetches the lists of the accounts holding
  /// [conversationId] past the usual one-minute limit (at most every few
  /// seconds) and judges the group again. A list that now approves or
  /// removes a leaf, or an MLS removal already applied, releases the hold;
  /// nothing else does.
  Future<void> recheckApprovalHold(String conversationId) async {
    final pins = _deviceListPins;
    final crypto = _listCrypto;
    if (pins == null || crypto == null || session == null) return;
    if (!_l1Holds.rechecking.add(conversationId)) return;
    notifyListeners();
    try {
      final now = DateTime.now().toUtc();
      final last = _l1Holds.lastRecheck[conversationId];
      if (last == null || now.difference(last) >= _l1RecheckSpacing) {
        _l1Holds.lastRecheck[conversationId] = now;
        final accounts = <String>{
          for (final leaf in await localStore.loadApprovalLeaves(
            conversationId,
          ))
            if (leaf.verdict != LeafVerdict.approved)
              utf8.decode(leaf.accountId, allowMalformed: true),
        };
        for (final account in accounts) {
          try {
            await pins.refresh(account, force: true).timeout(_l1RecheckTimeout);
          } on Object {
            // Unreadable: the judgment below keeps it "checking".
          }
        }
        try {
          await crypto.refreshApprovalHold(conversationId);
        } on Object {
          // Judged again before the next send.
        }
      }
      await refreshApprovalHoldSummary(conversationId);
    } finally {
      _l1Holds.rechecking.remove(conversationId);
      notifyListeners();
    }
  }

  /// Step one of resetting [accountId]'s sticky list conflict: reads and
  /// verifies the branch the server shows now and says how many devices it
  /// would newly approve, writing nothing
  /// ([DeviceListPins.prepareServedBranch] has the rules). Null when the
  /// reset is refused, and always for this device's own account: its own
  /// list is its authority, so a fork there keeps the existing error.
  Future<DeviceListResetPlan?> prepareContactDeviceListTrust(
    String accountId,
  ) async {
    final pins = _deviceListPins;
    final current = session;
    if (pins == null || current == null || accountId == current.accountId) {
      return null;
    }
    try {
      return await pins.prepareServedBranch(accountId);
    } on DeviceListResetRefused {
      return null;
    }
  }

  /// Step two, after the person confirmed: pins exactly [plan]'s branch
  /// while the conflict is still the one it was made from
  /// ([DeviceListPins.commitServedBranch]), then judges every held
  /// conversation again. Returns false when refused; the conflict then
  /// stays as it was.
  Future<bool> trustContactDeviceList(DeviceListResetPlan plan) async {
    final pins = _deviceListPins;
    final current = session;
    if (pins == null ||
        current == null ||
        plan.accountId == current.accountId) {
      return false;
    }
    final generation = _sessionGeneration;
    try {
      await pins.commitServedBranch(plan);
    } on DeviceListResetRefused {
      return false;
    }
    if (generation != _sessionGeneration) return true;
    for (final id in await localStore.loadHeldConversations()) {
      try {
        await _listCrypto?.refreshApprovalHold(id);
      } on Object {
        // Judged again before the next send.
      }
    }
    await _refreshApprovalHoldSummaries();
    return true;
  }
}
