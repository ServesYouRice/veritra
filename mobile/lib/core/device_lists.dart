import 'dart:convert';
import 'dart:typed_data';

import '../crypto/native_crypto_bindings.dart'
    show
        DeviceListChainResult,
        DeviceListListedPair,
        DeviceListPair,
        DeviceListSummary,
        NativeCryptoException;
import '../storage/local_store.dart';

// L1-3: the client side of the approved-device list (D94,
// docs/designs/L1-approved-device-list.md, "Pins, rollback and forks").
//
// Every format and chain rule is checked in Rust ([DeviceListVerifier]); this
// file keeps the pins, decides what a fetch means and judges leaves. The
// server only stores and relays lists: anything it serves that does not
// verify changes nothing ("unavailable"), and only a validly signed
// disagreement with a pin is a conflict.

/// The Rust checks, behind an interface so the pin logic is testable.
abstract interface class DeviceListVerifier {
  DeviceListChainResult checkChain(
      String accountId, List<List<int>> statements);

  DeviceListSummary checkStep({
    required String accountId,
    required List<int>? prev,
    required List<int> statement,
    required List<DeviceListPair> history,
  });
}

/// One page of `GET /api/v1/accounts/{id}/device-list?after=N`.
class DeviceListPage {
  const DeviceListPage({
    required this.headVersion,
    required this.statements,
    required this.more,
  });

  final int headVersion;
  final List<({int version, Uint8List statement})> statements;
  final bool more;

  factory DeviceListPage.fromJson(Map<String, Object?> json) {
    final head = json['head_version'];
    final more = json['more'];
    final raw = json['statements'];
    if (head is! int || head < 0 || more is! bool || raw is! List) {
      throw const FormatException('invalid device list page');
    }
    return DeviceListPage(
      headVersion: head,
      more: more,
      statements: [
        for (final item in raw)
          if (item is Map &&
              item['version'] is int &&
              item['statement'] is String)
            (
              version: item['version'] as int,
              statement: base64Decode(item['statement'] as String),
            )
          else
            throw const FormatException('invalid device list statement'),
      ],
    );
  }
}

/// Where lists come from (the server). Null means the account is unknown
/// or not readable by this account (the server's 404).
abstract interface class DeviceListSource {
  Future<DeviceListPage?> fetchDeviceList(String accountId,
      {required int after});
}

/// What this device knows about an account's list after a refresh.
enum DeviceListState {
  /// A verified pin.
  ok,

  /// No list yet (an account from before L1): its devices are not added.
  empty,

  /// The list could not be fetched or did not verify. Nothing changed.
  unavailable,

  /// A validly signed statement disagreed with the pin (sticky).
  conflict,
}

class DeviceListStatus {
  const DeviceListStatus(this.state, this.pin);
  final DeviceListState state;
  final DeviceListPin? pin;
}

/// The longest chain fetched in one refresh (the Rust chain check's cap).
const int deviceListMaxChain = 256;

class DeviceListPins {
  DeviceListPins({
    required this.store,
    required this.source,
    required this.verifier,
    DateTime Function()? clock,
    this.minRefresh = const Duration(minutes: 1),
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final LocalStore store;
  final DeviceListSource source;
  final DeviceListVerifier verifier;
  final Duration minRefresh;
  final DateTime Function() _clock;
  final Map<String, DateTime> _lastFetch = <String, DateTime>{};
  final Map<String, DeviceListState> _lastState = <String, DeviceListState>{};

  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// Forgets the rate limit for [accountId] (a `device_list.updated` event,
  /// or this device just published a version).
  void invalidate(String accountId) => _lastFetch.remove(accountId);

  /// Refreshes [accountId]'s pin from the server, at most once per
  /// [minRefresh] unless [force]. Never throws for anything the server
  /// sends: an answer that does not verify is [DeviceListState.unavailable].
  Future<DeviceListStatus> refresh(String accountId,
      {bool force = false}) async {
    final pin = await store.loadDeviceListPin(accountId);
    if (pin != null && pin.conflict) {
      return DeviceListStatus(DeviceListState.conflict, pin);
    }
    final now = _clock();
    final last = _lastFetch[accountId];
    if (!force && last != null && now.difference(last) < minRefresh) {
      return DeviceListStatus(
          pin == null
              ? (_lastState[accountId] ?? DeviceListState.unavailable)
              : DeviceListState.ok,
          pin);
    }
    _lastFetch[accountId] = now;
    final DeviceListStatus status;
    try {
      status = pin == null
          ? await _firstSight(accountId)
          : await _advance(accountId, pin);
    } on Object {
      // The network, a bad page or a verify failure: the server can always
      // deny service, so this is not treated as an attack.
      final state =
          pin == null ? DeviceListState.unavailable : DeviceListState.ok;
      _lastState[accountId] = state;
      return DeviceListStatus(state, pin);
    }
    _lastState[accountId] = status.state;
    return status;
  }

  Future<List<({int version, Uint8List statement})>?> _fetchFrom(
      String accountId, int after) async {
    final out = <({int version, Uint8List statement})>[];
    var cursor = after;
    while (true) {
      final page = await source.fetchDeviceList(accountId, after: cursor);
      if (page == null) return null;
      for (final item in page.statements) {
        if (item.version != cursor + 1) {
          throw const FormatException('device list page out of order');
        }
        out.add(item);
        cursor = item.version;
      }
      if (out.length > deviceListMaxChain) {
        throw const FormatException('device list chain too long');
      }
      if (!page.more) {
        if (page.headVersion != cursor) {
          throw const FormatException('device list head mismatch');
        }
        return out;
      }
      if (page.statements.isEmpty) {
        throw const FormatException('device list page made no progress');
      }
    }
  }

  DeviceListPin _pinFrom(String accountId, DeviceListChainResult chain,
          List<int> headStatement) =>
      DeviceListPin(
        accountId: accountId,
        version: chain.head.version,
        listHash: chain.head.listHash,
        listId: chain.listId,
        headStatement: headStatement,
        conflict: false,
        checkedAt: _nowMs,
        recoveryKey: chain.head.recoveryKey,
        keys: [
          for (final DeviceListListedPair listed in chain.pairs)
            DeviceListKeyRow(
              deviceId: listed.pair.deviceId,
              signingKey: listed.pair.signingKey,
              addedVersion: listed.addedVersion,
              removedVersion: listed.removedVersion,
            ),
        ],
      );

  /// Trust on first use: the whole chain from version 1, verified in Rust.
  Future<DeviceListStatus> _firstSight(String accountId) async {
    final statements = await _fetchFrom(accountId, 0);
    if (statements == null) {
      return const DeviceListStatus(DeviceListState.unavailable, null);
    }
    if (statements.isEmpty) {
      return const DeviceListStatus(DeviceListState.empty, null);
    }
    final chain = verifier
        .checkChain(accountId, [for (final item in statements) item.statement]);
    final pin = _pinFrom(accountId, chain, statements.last.statement);
    if (!await store.saveDeviceListPin(pin, expectedVersion: null)) {
      // Another refresh pinned it meanwhile: take what is stored.
      final stored = await store.loadDeviceListPin(accountId);
      return DeviceListStatus(
          stored == null
              ? DeviceListState.unavailable
              : stored.conflict
                  ? DeviceListState.conflict
                  : DeviceListState.ok,
          stored);
    }
    return DeviceListStatus(DeviceListState.ok, pin);
  }

  /// Pins the head [statement] of a chain this device just verified some
  /// other way (its own new version accepted by the server, or a linked
  /// device's anchor): checked as the step after the current pin, or as a
  /// whole chain when there is none. Returns whether the pin moved.
  Future<bool> pinOwnStep(String accountId, List<int> statement) async {
    final pin = await store.loadDeviceListPin(accountId);
    if (pin == null || pin.conflict) return false;
    final next = _step(accountId, pin, statement);
    final moved =
        await store.saveDeviceListPin(next, expectedVersion: pin.version);
    invalidate(accountId);
    return moved;
  }

  /// Pins a whole verified chain as this device's own anchor (a newly
  /// linked device, whose head arrived authenticated with the link).
  /// [expectedHead] must be the chain's last statement.
  Future<DeviceListPin> pinChain(String accountId, List<List<int>> statements,
      {required List<int> expectedHead}) async {
    if (statements.isEmpty || !_same(statements.last, expectedHead)) {
      throw const FormatException('the chain does not end in the head');
    }
    final chain = verifier.checkChain(accountId, statements);
    final pin = _pinFrom(accountId, chain, statements.last);
    final stored = await store.loadDeviceListPin(accountId);
    if (!await store.saveDeviceListPin(pin, expectedVersion: stored?.version)) {
      throw StateError('device list pin changed meanwhile');
    }
    invalidate(accountId);
    return pin;
  }

  DeviceListPin _step(String accountId, DeviceListPin pin, List<int> statement,
      {DeviceListSummary? checked}) {
    final summary = checked ??
        verifier.checkStep(
          accountId: accountId,
          prev: pin.headStatement,
          statement: statement,
          history: [
            for (final key in pin.keys)
              DeviceListPair(key.deviceId, key.signingKey),
          ],
        );
    final keys = <DeviceListKeyRow>[];
    for (final key in pin.keys) {
      final still = summary.entries.any((entry) =>
          _same(entry.deviceId, key.deviceId) &&
          _same(entry.signingKey, key.signingKey));
      keys.add(key.listed && !still
          ? DeviceListKeyRow(
              deviceId: key.deviceId,
              signingKey: key.signingKey,
              addedVersion: key.addedVersion,
              removedVersion: summary.version,
            )
          : key);
    }
    for (final entry in summary.entries) {
      final known = pin.keys.any((key) =>
          _same(key.deviceId, entry.deviceId) &&
          _same(key.signingKey, entry.signingKey));
      if (!known) {
        keys.add(DeviceListKeyRow(
          deviceId: entry.deviceId,
          signingKey: entry.signingKey,
          addedVersion: summary.version,
          removedVersion: 0,
        ));
      }
    }
    return DeviceListPin(
      accountId: accountId,
      version: summary.version,
      listHash: summary.listHash,
      listId: pin.listId,
      headStatement: statement,
      conflict: false,
      checkedAt: _nowMs,
      keys: keys,
      recoveryKey: summary.recoveryKey,
    );
  }

  Future<DeviceListStatus> _advance(String accountId, DeviceListPin pin) async {
    // Ask from the version below the pin, so the server must show the
    // pinned head itself again: a different statement there is a fork.
    final after = pin.version - 1;
    final statements = await _fetchFrom(accountId, after);
    if (statements == null || statements.isEmpty) {
      // A lower head, or the account vanished: nothing changes.
      return DeviceListStatus(DeviceListState.ok, pin);
    }
    if (!_same(statements.first.statement, pin.headStatement)) {
      return _maybeConflict(accountId, pin, statements.first.statement);
    }
    var next = pin;
    for (final item in statements.skip(1)) {
      final DeviceListSummary summary;
      try {
        summary = verifier.checkStep(
          accountId: accountId,
          prev: next.headStatement,
          statement: item.statement,
          history: [
            for (final key in next.keys)
              DeviceListPair(key.deviceId, key.signingKey),
          ],
        );
      } on NativeCryptoException {
        // A bad step after the pin: keep what verified so far.
        break;
      }
      next = _step(accountId, next, item.statement, checked: summary);
    }
    if (next.version == pin.version) {
      await store.touchDeviceListPin(accountId, _nowMs);
      return DeviceListStatus(DeviceListState.ok, pin);
    }
    if (!await store.saveDeviceListPin(next, expectedVersion: pin.version)) {
      final stored = await store.loadDeviceListPin(accountId);
      return DeviceListStatus(
          stored?.conflict ?? false
              ? DeviceListState.conflict
              : DeviceListState.ok,
          stored ?? pin);
    }
    return DeviceListStatus(DeviceListState.ok, next);
  }

  /// The server showed another statement at the pinned version. It is a
  /// conflict only if the whole chain it serves verifies (so the other
  /// statement is validly signed, which needs a key the pinned list holds
  /// or a fabricated genesis); otherwise it is just unavailable.
  Future<DeviceListStatus> _maybeConflict(
      String accountId, DeviceListPin pin, List<int> other) async {
    final whole = await _fetchFrom(accountId, 0);
    if (whole == null || whole.length < pin.version) {
      return DeviceListStatus(DeviceListState.ok, pin);
    }
    try {
      verifier
          .checkChain(accountId, [for (final item in whole) item.statement]);
    } on NativeCryptoException {
      return DeviceListStatus(DeviceListState.ok, pin);
    }
    if (!_same(whole[pin.version - 1].statement, other)) {
      return DeviceListStatus(DeviceListState.ok, pin);
    }
    await store.saveDeviceListConflict(
      accountId: accountId,
      version: pin.version,
      pinnedStatement: pin.headStatement,
      otherStatement: other,
      recordedAt: _nowMs,
    );
    final stored = await store.loadDeviceListPin(accountId);
    return DeviceListStatus(DeviceListState.conflict, stored ?? pin);
  }

  Future<DeviceListStatus> _stored(String accountId) async {
    final pin = await store.loadDeviceListPin(accountId);
    if (pin == null) {
      return DeviceListStatus(
          _lastState[accountId] ?? DeviceListState.unavailable, null);
    }
    return DeviceListStatus(
        pin.conflict ? DeviceListState.conflict : DeviceListState.ok, pin);
  }

  /// The key the pin lists now for [deviceId] of [accountId], after a
  /// refresh, or null (not approved, no list, unavailable or in conflict).
  /// The add gate stages only with this key, never one the server sent.
  Future<Uint8List?> approvedKey(String accountId, String deviceId) async {
    final device = utf8.encode(deviceId);
    final status = await refresh(accountId);
    final pin = status.pin;
    if (status.state != DeviceListState.ok || pin == null) return null;
    return pin.listedKey(device);
  }

  /// Judges one leaf against its account's pin, refreshing it first when
  /// the pin alone does not approve the pair.
  ///
  /// With [refreshFirst] false only the stored pin is read (no network), for
  /// a caller that is out of time.
  Future<LeafVerdict> judge(
      List<int> accountId, List<int> deviceId, List<int> signingKey,
      {bool refreshFirst = true}) async {
    final String account;
    try {
      account = utf8.decode(accountId);
    } on FormatException {
      // No account anyone can spell: never on a list.
      return LeafVerdict.unapproved;
    }
    final DeviceListPin pin;
    final status =
        refreshFirst ? await refresh(account) : await _stored(account);
    switch (status.state) {
      case DeviceListState.empty:
      case DeviceListState.unavailable:
        return LeafVerdict.checking;
      case DeviceListState.conflict:
        return LeafVerdict.unapproved;
      case DeviceListState.ok:
        pin = status.pin!;
    }
    return switch (pin.standing(deviceId, signingKey)) {
      PinStanding.approved => LeafVerdict.approved,
      PinStanding.removed => LeafVerdict.removed,
      PinStanding.mismatch || PinStanding.unknown => LeafVerdict.unapproved,
    };
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
