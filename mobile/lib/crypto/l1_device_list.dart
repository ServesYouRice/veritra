part of 'native_crypto_bindings.dart';

// L1 approved-device list, crypto layer (ABI 14, step L1-1). Nothing here is
// wired into the app: the pins, the keys table, the add gate and the holds
// are L1-3. Design: docs/designs/L1-approved-device-list.md. Format and
// vector: testing/vectors/l1-device-list-v1.json.
//
// Every rule lives in Rust (`crypto/rust/src/l1.rs`). This file only encodes
// a body for the device to sign, joins it to its signature, and reads the
// summaries Rust hands back, so the app never parses a statement itself.
//
// Account and device ids are BYTES here, never Strings. Rust reads an id out
// of an MLS credential as 1 to 128 arbitrary bytes, so a member (or a server
// colluding with one) can commit an Add whose ids are not UTF-8. Decoding
// them as text would throw after the commit was already merged and break D94
// (apply the commit, then hold; never stall sync). [idBytes] spells an
// ordinary text id; nothing in this file ever decodes one.

/// The bytes of a text id (UTF-8), for the callers that have a String.
Uint8List idBytes(String text) => Uint8List.fromList(utf8.encode(text));

String _hexOf(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// What a device-list version does (the `change` byte).
enum DeviceListChange {
  genesis(1),
  add(2),
  remove(3),
  recovery(4),
  recoveryKey(5),
  migrationGenesis(6),

  /// L2-3: a listed device sets its own franking key, from none to some.
  frankKey(7);

  const DeviceListChange(this.code);
  final int code;

  static DeviceListChange fromCode(int code) => values.firstWhere(
        (change) => change.code == code,
        orElse: () =>
            throw const NativeCryptoException(NativeCryptoError.invalidOutput),
      );
}

/// Who signed a statement: a device on the version before (1), or the
/// recovery-derived key (2).
const int deviceListSignerDevice = 1;
const int deviceListSignerRecovery = 2;

/// The label `pm_crypto_c7_sign` takes for a device-list body (ABI 14).
const String deviceListSignLabel = 'veritra-l1-device-list-sig-v1';

/// A listed device: its id and its MLS credential signing key.
class DeviceListPair {
  DeviceListPair(List<int> deviceId, List<int> signingKey)
      : deviceId = Uint8List.fromList(deviceId),
        signingKey = Uint8List.fromList(signingKey) {
    if (this.signingKey.length != 32) {
      throw ArgumentError('A device-list signing key is 32 bytes');
    }
  }

  /// The id's bytes (see the note at the top of this file).
  final Uint8List deviceId;
  final Uint8List signingKey;

  @override
  bool operator ==(Object other) =>
      other is DeviceListPair &&
      _sameBytes(other.deviceId, deviceId) &&
      _sameBytes(other.signingKey, signingKey);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(deviceId), Object.hashAll(signingKey));

  @override
  String toString() => 'DeviceListPair(${_hexOf(deviceId)})';
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A listed device's X25519 franking key (format 2, L2-3). Once a version
/// lists it, no later version changes or drops it while the device stays
/// listed.
class DeviceListFrankKey {
  DeviceListFrankKey(List<int> deviceId, List<int> key)
      : deviceId = Uint8List.fromList(deviceId),
        key = Uint8List.fromList(key) {
    if (this.key.length != 32) {
      throw ArgumentError('A franking key is 32 bytes');
    }
  }

  final Uint8List deviceId;
  final Uint8List key;
}

/// The signed part of a device-list statement. [encode] writes the one
/// canonical spelling (entries sorted by id bytes); Rust refuses anything
/// else, so a mistake here fails closed.
class DeviceListBody {
  DeviceListBody({
    required List<int> accountId,
    required this.version,
    required List<int> prevHash,
    required this.createdAtMs,
    required this.change,
    required this.entries,
    List<int>? recoveryKey,
    this.frankKeys = const [],
  })  : accountId = Uint8List.fromList(accountId),
        prevHash = Uint8List.fromList(prevHash),
        recoveryKey =
            recoveryKey == null ? null : Uint8List.fromList(recoveryKey) {
    if (this.prevHash.length != 32) {
      throw ArgumentError('prev_hash is 32 bytes');
    }
    if (this.recoveryKey != null && this.recoveryKey!.length != 32) {
      throw ArgumentError('A recovery key is 32 bytes');
    }
  }

  final Uint8List accountId;
  final int version;
  final Uint8List prevHash;
  final int createdAtMs;
  final DeviceListChange change;
  final List<DeviceListPair> entries;
  final Uint8List? recoveryKey;

  /// The devices' franking keys. Empty writes format 1, byte for byte the
  /// earlier format; any key writes format 2 with the keys appended.
  final List<DeviceListFrankKey> frankKeys;

  /// `prev_hash` of a genesis.
  static final Uint8List zeroHash = Uint8List(32);

  Uint8List encode() {
    if (version < 1 || createdAtMs < 0) {
      throw ArgumentError('A device-list version starts at 1');
    }
    if (entries.isEmpty || entries.length > 16) {
      throw ArgumentError('A device list holds 1 to 16 devices');
    }
    final sorted = [...entries]
      ..sort((a, b) => _compareBytes(a.deviceId, b.deviceId));
    final out = BytesBuilder(copy: false);
    final data = ByteData(8);
    void u64(int value) {
      data.setUint64(0, value, Endian.big);
      out.add(data.buffer.asUint8List(0, 8).toList());
    }

    void lp(List<int> value) {
      if (value.length > 0xffff) throw ArgumentError('field too long');
      out.add(<int>[(value.length >> 8) & 0xff, value.length & 0xff]);
      out.add(value);
    }

    out
      ..add(utf8.encode('VDL1'))
      ..addByte(frankKeys.isEmpty ? 1 : 2);
    lp(accountId);
    u64(version);
    out.add(prevHash);
    u64(createdAtMs);
    out
      ..addByte(change.code)
      ..addByte(sorted.length);
    for (final pair in sorted) {
      lp(pair.deviceId);
      out.add(pair.signingKey);
    }
    final key = recoveryKey;
    if (key == null) {
      out.addByte(0);
    } else {
      out
        ..addByte(1)
        ..add(key);
    }
    if (frankKeys.isNotEmpty) {
      final franks = [...frankKeys]
        ..sort((a, b) => _compareBytes(a.deviceId, b.deviceId));
      out.addByte(franks.length);
      for (final frank in franks) {
        lp(frank.deviceId);
        out.add(frank.key);
      }
    }
    return out.toBytes();
  }
}

int _compareBytes(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// `body | signer_kind | lp(signer device id) | signature`. A device signer
/// names its own id; the recovery signer (kind 2) names none. Rust parses the
/// result again when it checks the statement.
Uint8List assembleDeviceListStatement({
  required List<int> body,
  required int signerKind,
  List<int>? signerDeviceId,
  required List<int> signature,
}) {
  if (signature.length != 64) throw ArgumentError('A signature is 64 bytes');
  final id = signerKind == deviceListSignerDevice
      ? (signerDeviceId ?? const <int>[])
      : const <int>[];
  if (signerKind != deviceListSignerDevice &&
      signerKind != deviceListSignerRecovery) {
    throw ArgumentError('Unknown signer kind');
  }
  final out = BytesBuilder(copy: false)
    ..add(body)
    ..addByte(signerKind)
    ..add(<int>[(id.length >> 8) & 0xff, id.length & 0xff])
    ..add(id)
    ..add(signature);
  return out.toBytes();
}

/// What a checked statement says, as Rust summarises it.
class DeviceListSummary {
  const DeviceListSummary({
    required this.change,
    required this.signerKind,
    required this.signerDeviceId,
    required this.version,
    required this.listHash,
    required this.prevHash,
    required this.createdAtMs,
    required this.accountId,
    required this.entries,
    required this.recoveryKey,
    this.frankKeys = const [],
  });

  final DeviceListChange change;
  final int signerKind;

  /// Empty for the recovery signer. Bytes, not text.
  final Uint8List signerDeviceId;
  final int version;
  final Uint8List listHash;
  final Uint8List prevHash;
  final int createdAtMs;
  final Uint8List accountId;
  final List<DeviceListPair> entries;
  final Uint8List? recoveryKey;

  /// The franking keys this version lists (L2-3), sorted by id.
  final List<DeviceListFrankKey> frankKeys;

  /// The franking key this version lists for [deviceId], if any.
  Uint8List? frankKeyOf(List<int> deviceId) {
    for (final frank in frankKeys) {
      if (_sameBytes(frank.deviceId, deviceId)) return frank.key;
    }
    return null;
  }
}

class _SummaryReader {
  _SummaryReader(List<int> bytes) : _data = Uint8List.fromList(bytes);

  final Uint8List _data;
  int offset = 0;

  Uint8List take(int count) {
    if (count < 0 || offset + count > _data.length) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    final value = Uint8List.sublistView(_data, offset, offset + count);
    offset += count;
    return Uint8List.fromList(value);
  }

  int byte() => take(1)[0];

  int u16() {
    final bytes = take(2);
    return (bytes[0] << 8) | bytes[1];
  }

  int u64() => ByteData.sublistView(take(8)).getUint64(0, Endian.big);

  /// A length-prefixed id, as the bytes Rust holds. Never decoded as text.
  Uint8List lpBytes() => take(u16());

  bool get finished => offset == _data.length;
}

DeviceListSummary _readSummary(_SummaryReader reader) {
  if (reader.byte() != 1) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  final change = DeviceListChange.fromCode(reader.byte());
  final signerKind = reader.byte();
  final signer = reader.lpBytes();
  final version = reader.u64();
  final listHash = reader.take(32);
  final prevHash = reader.take(32);
  final createdAtMs = reader.u64();
  final account = reader.lpBytes();
  final count = reader.byte();
  final entries = <DeviceListPair>[
    for (var i = 0; i < count; i++)
      DeviceListPair(reader.lpBytes(), reader.take(32)),
  ];
  final recoveryKey = switch (reader.byte()) {
    0 => null,
    1 => reader.take(32),
    _ => throw const NativeCryptoException(NativeCryptoError.invalidOutput),
  };
  final frankCount = reader.byte();
  final frankKeys = <DeviceListFrankKey>[
    for (var i = 0; i < frankCount; i++)
      DeviceListFrankKey(reader.lpBytes(), reader.take(32)),
  ];
  return DeviceListSummary(
    change: change,
    signerKind: signerKind,
    signerDeviceId: signer,
    version: version,
    listHash: listHash,
    prevHash: prevHash,
    createdAtMs: createdAtMs,
    accountId: account,
    entries: entries,
    recoveryKey: recoveryKey,
    frankKeys: frankKeys,
  );
}

/// A pair a chain listed, with the versions that added it and removed it
/// ([removedVersion] is 0 while it is listed), and the franking key the
/// chain gave the device, if any (L2-3; fixed once set).
class DeviceListListedPair {
  const DeviceListListedPair(this.pair, this.addedVersion, this.removedVersion,
      [this.frankKey]);
  final DeviceListPair pair;
  final int addedVersion;
  final int removedVersion;
  final Uint8List? frankKey;
}

/// A verified chain: its head, its list identity (`list_hash` of version 1)
/// and every pair it ever listed (the app's `local_device_list_keys`).
class DeviceListChainResult {
  const DeviceListChainResult(this.head, this.listId, this.pairs);
  final DeviceListSummary head;
  final Uint8List listId;
  final List<DeviceListListedPair> pairs;
}

/// A leaf of a group as `(account, device, signature key)`. The ids are the
/// raw bytes of the leaf's credential, which need not be UTF-8: a leaf with
/// an id nobody can spell is still a leaf, and the app holds it as
/// unapproved instead of failing.
class LeafPair {
  LeafPair(List<int> accountId, List<int> deviceId, List<int> signingKey)
      : accountId = Uint8List.fromList(accountId),
        deviceId = Uint8List.fromList(deviceId),
        signingKey = Uint8List.fromList(signingKey);
  final Uint8List accountId;
  final Uint8List deviceId;
  final Uint8List signingKey;

  @override
  bool operator ==(Object other) =>
      other is LeafPair &&
      _sameBytes(other.accountId, accountId) &&
      _sameBytes(other.deviceId, deviceId) &&
      _sameBytes(other.signingKey, signingKey);

  @override
  int get hashCode => Object.hash(Object.hashAll(accountId),
      Object.hashAll(deviceId), Object.hashAll(signingKey));

  @override
  String toString() => 'LeafPair(${_hexOf(accountId)}, ${_hexOf(deviceId)})';
}

List<LeafPair> _readLeafPairs(List<int> bytes) {
  final reader = _SummaryReader(bytes);
  final count = reader.u16();
  final pairs = <LeafPair>[
    for (var i = 0; i < count; i++)
      LeafPair(reader.lpBytes(), reader.lpBytes(), reader.take(32)),
  ];
  if (!reader.finished) {
    throw const NativeCryptoException(NativeCryptoError.invalidOutput);
  }
  return pairs;
}

/// [_readLeafPairs] for a buffer a native call handed back after it had
/// already changed state: a failure is a value (null), never an exception.
List<LeafPair>? _tryReadLeafPairs(List<int>? bytes) {
  if (bytes == null) return null;
  try {
    return _readLeafPairs(bytes);
  } on NativeCryptoException {
    return null;
  }
}

/// What a commit did, read from MLS itself (ABI 13 flags, ABI 14 pairs).
///
/// The native call has already merged the commit when this is built (D94:
/// apply the commit, then hold; never stall sync), so building it never
/// throws. Rust encodes the pair buffers before the merge, so [unreadable]
/// is not expected; if it is ever true (a damaged buffer), judge nothing and
/// hold the conversation. The flags and [epoch] are still true.
class CommitPairs {
  const CommitPairs({
    required this.removed,
    required this.added,
    required this.removedSelf,
    required this.epoch,
    required this.root,
    required this.addedLeaves,
    required this.committer,
    this.unreadable = false,
  });

  /// A pair buffer or the root could not be read after the merge: judge
  /// nothing from this commit and hold the conversation.
  final bool unreadable;

  /// At least one Remove proposal.
  final bool removed;

  /// At least one Add proposal.
  final bool added;

  /// This device was removed.
  final bool removedSelf;
  final int epoch;

  /// The 32-byte C7 exporter root of a removal that keeps this device, else
  /// null. The caller wipes it once it has derived from it.
  final Uint8List? root;

  /// The leaves the commit's Add proposals brought in (empty when
  /// [unreadable]).
  final List<LeafPair> addedLeaves;

  /// The committer; null only when [unreadable].
  final LeafPair? committer;
}

List<int> _historyBytes(List<DeviceListPair> history) {
  if (history.length > 1024)
    throw ArgumentError('too much device-list history');
  final out = BytesBuilder(copy: false)
    ..add(<int>[(history.length >> 8) & 0xff, history.length & 0xff]);
  for (final pair in history) {
    final id = pair.deviceId;
    if (id.isEmpty || id.length > 128) throw ArgumentError('invalid device id');
    out
      ..add(<int>[(id.length >> 8) & 0xff, id.length & 0xff])
      ..add(id)
      ..add(pair.signingKey);
  }
  return out.toBytes();
}

/// Membership change list version 2 (ABI 14): every add also names the
/// signature key its key package must hold.
List<int> encodeKeyedMembershipChanges({
  required List<
          ({
            List<int> keyPackage,
            List<int> accountId,
            List<int> deviceId,
            List<int> signingKey
          })>
      adds,
  required List<({List<int> accountId, List<int> deviceId})> removes,
  bool allowEmpty = false,
}) {
  // Only a commit that carries a role record (C4, ABI 20) may change no
  // membership; an empty list on its own asks for a self-update.
  if (adds.isEmpty && removes.isEmpty && !allowEmpty) {
    throw ArgumentError('a commit needs at least one change');
  }
  if (adds.length > 256 || removes.length > 256) {
    throw ArgumentError('too many membership changes');
  }
  final out = BytesBuilder(copy: false)..addByte(2);
  void u16(int value) => out.add(<int>[(value >> 8) & 0xff, value & 0xff]);
  void id(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 128) {
      throw ArgumentError('invalid identity in membership change');
    }
    u16(bytes.length);
    out.add(bytes);
  }

  u16(adds.length);
  for (final add in adds) {
    final length = add.keyPackage.length;
    if (length == 0 || length > 48 * 1024) {
      throw ArgumentError('invalid key package in membership change');
    }
    if (add.signingKey.length != 32) {
      throw ArgumentError('an expected signing key is 32 bytes');
    }
    out.add(<int>[
      (length >> 24) & 0xff,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
    out.add(add.keyPackage);
    id(add.accountId);
    id(add.deviceId);
    out.add(add.signingKey);
  }
  u16(removes.length);
  for (final remove in removes) {
    id(remove.accountId);
    id(remove.deviceId);
  }
  return out.toBytes();
}

extension DeviceListBindings on NativeCryptoBindings {
  /// Checks [statement] as the version after [prev] (null for a genesis) and
  /// returns its summary. [expectedAccountId] is the account the caller asked
  /// about: Rust refuses a statement of any other account, a genesis
  /// included, as [NativeCryptoError.deviceListChain], so a valid chain of
  /// another account (a server's substitute answer) never passes and the
  /// caller needs no comparison of its own. [history] is every pair the chain
  /// listed before;
  /// pass the app's keys table, since [prev] alone cannot know a device that
  /// was removed earlier (the no-return rule). Throws
  /// [NativeCryptoError.deviceListMalformed], `deviceListChain`,
  /// `deviceListRule` or `deviceListSignature` (checked in that order).
  DeviceListSummary checkDeviceListStep({
    required List<int> expectedAccountId,
    List<int>? prev,
    required List<int> statement,
    List<DeviceListPair> history = const [],
  }) {
    _bounded(expectedAccountId, 128);
    _bounded(statement, 4096);
    if (prev != null) _bounded(prev, 4096);
    final summary = _withDeviceListSlices(
      [
        expectedAccountId,
        prev ?? const <int>[],
        statement,
        history.isEmpty ? const <int>[] : _historyBytes(history)
      ],
      (slices) => _output(
          (out) =>
              _l1CheckStep(slices[0], slices[1], slices[2], slices[3], out),
          maximum: 8192),
    );
    final reader = _SummaryReader(summary);
    final parsed = _readSummary(reader);
    if (!reader.finished) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return parsed;
  }

  /// Checks a whole chain from its genesis (at most 256 statements) and
  /// returns the head, the list identity and every pair it listed.
  /// [expectedAccountId] is the account the caller asked about; a chain of
  /// any other account is refused as [NativeCryptoError.deviceListChain].
  DeviceListChainResult checkDeviceListChain(
    List<int> expectedAccountId,
    List<List<int>> statements,
  ) {
    _bounded(expectedAccountId, 128);
    if (statements.isEmpty || statements.length > 256) {
      throw ArgumentError('A chain holds 1 to 256 statements');
    }
    final out = BytesBuilder(copy: false)
      ..add(<int>[(statements.length >> 8) & 0xff, statements.length & 0xff]);
    for (final statement in statements) {
      _bounded(statement, 4096);
      out
        ..add(<int>[(statement.length >> 8) & 0xff, statement.length & 0xff])
        ..add(statement);
    }
    final result = _withByteLists(
        <List<int>>[expectedAccountId, out.toBytes()],
        (slices) => _output(
            (buffer) => _l1CheckChain(slices[0], slices[1], buffer),
            maximum: 4 * 1024 * 1024));
    final reader = _SummaryReader(result);
    final head = _readSummary(reader);
    final listId = reader.take(32);
    final count = reader.u16();
    final pairs = <DeviceListListedPair>[
      for (var i = 0; i < count; i++)
        DeviceListListedPair(
          DeviceListPair(reader.lpBytes(), reader.take(32)),
          reader.u64(),
          reader.u64(),
          switch (reader.byte()) {
            0 => null,
            1 => reader.take(32),
            _ => throw const NativeCryptoException(
                NativeCryptoError.invalidOutput),
          },
        ),
    ];
    if (!reader.finished) {
      throw const NativeCryptoException(NativeCryptoError.invalidOutput);
    }
    return DeviceListChainResult(head, listId, pairs);
  }

  /// [NativeCryptoBindings._withByteLists] that lets a slice be empty (an
  /// absent optional input is a zero-length slice).
  T _withDeviceListSlices<T>(
      List<List<int>> values, T Function(List<_PmByteSlice>) operation) {
    T visit(int index, List<_PmByteSlice> slices) {
      if (index == values.length) return operation(slices);
      final value = values[index];
      if (value.isEmpty) {
        final empty = calloc<_PmByteSlice>();
        try {
          empty.ref
            ..data = nullptr
            ..len = 0;
          return visit(index + 1, [...slices, empty.ref]);
        } finally {
          calloc.free(empty);
        }
      }
      return _withSlice(Uint8List.fromList(value),
          (slice) => visit(index + 1, [...slices, slice]));
    }

    return visit(0, const []);
  }
}

extension DeviceListDevice on NativeCryptoDevice {
  /// Signs a device-list body as this device through `pm_crypto_c7_sign`
  /// with the L1 label and returns the whole statement. Rust parses the body
  /// strictly and signs only its own account's list, a genesis that names
  /// exactly this device, or a migration genesis that includes it
  /// ([NativeCryptoError.deviceListRule] otherwise; a malformed body is
  /// [NativeCryptoError.deviceListMalformed]).
  Uint8List signDeviceList(DeviceListBody body, List<int> ownDeviceId) {
    final bytes = body.encode();
    final signature = _bindings._withByteLists(
        <List<int>>[utf8.encode(deviceListSignLabel), bytes],
        (slices) => _bindings._output(
            (out) => _bindings._c7Sign(_liveHandle, slices[0], slices[1], out),
            maximum: 64));
    return assembleDeviceListStatement(
      body: bytes,
      signerKind: deviceListSignerDevice,
      signerDeviceId: ownDeviceId,
      signature: signature,
    );
  }

  /// Keeps the device-list recovery seed derived from the typed 30-byte RK
  /// [entropy] in the sealed device record (a recovered phone waiting out the
  /// recovery delay, D94). Only the seed is kept; it never leaves Rust. Seal
  /// afterwards. An older library refuses a record that holds one.
  void holdRecoveryListSeed(List<int> entropy) {
    _bindings._bounded(entropy, NativeCryptoBindings.recoveryKeyEntropyBytes,
        exact: true);
    _bindings._withSlice(Uint8List.fromList(entropy),
        (slice) => _bindings._check(_bindings._l1Hold(_liveHandle, slice)));
  }

  /// The public key of the held seed, or null when none is held.
  Uint8List? heldRecoveryListPublic() {
    final out = calloc<_PmOwnedBuffer>();
    try {
      _bindings._check(_bindings._l1HoldPublic(_liveHandle, out));
      if (out.ref.data == nullptr) return null;
      final bytes = Uint8List.fromList(_bindings._take(out.ref, maximum: 32));
      out.ref
        ..data = nullptr
        ..len = 0;
      if (bytes.length != 32) {
        throw const NativeCryptoException(NativeCryptoError.invalidOutput);
      }
      return bytes;
    } finally {
      if (out.ref.data != nullptr) _bindings._free(out.ref);
      calloc.free(out);
    }
  }

  /// Forgets the held seed (a cancelled or expired claim). Returns whether
  /// one was held. Seal afterwards.
  bool dropRecoveryListHold() {
    final held = calloc<Uint8>();
    try {
      _bindings._check(_bindings._l1HoldDrop(_liveHandle, held));
      return held.value == 1;
    } finally {
      calloc.free(held);
    }
  }

  /// Signs change 4 with the recovery-derived key and returns the whole
  /// statement. Without [entropy] it uses the held seed (and drops it);
  /// with it, the seed derived from the typed entropy (nothing kept).
  /// [prev] is the account's head at completion. Rust refuses, signing
  /// nothing, a body that is not this device's change 4 (a single listed
  /// device, this one with its own key) and a statement the chain would
  /// refuse, one whose head recovery key is not this seed's included.
  /// Throws [NativeCryptoError.deviceListNoSeed] when there is no entropy
  /// and no held seed.
  Uint8List signRecoveryDeviceList({
    required List<int> prev,
    required DeviceListBody body,
    List<DeviceListPair> history = const [],
    List<int>? entropy,
  }) {
    _bindings._bounded(prev, 4096);
    if (entropy != null) {
      _bindings._bounded(entropy, NativeCryptoBindings.recoveryKeyEntropyBytes,
          exact: true);
    }
    final statement = _bindings._withDeviceListSlices(
        <List<int>>[
          prev,
          history.isEmpty ? const <int>[] : _historyBytes(history),
          body.encode(),
          entropy ?? const <int>[],
        ],
        (slices) => _bindings._output(
            (out) => _bindings._l1SignRecovery(
                _liveHandle, slices[0], slices[1], slices[2], slices[3], out),
            maximum: 4096));
    return Uint8List.fromList(statement);
  }

  /// Every leaf of the group as `(account, device, signature key)`, in leaf
  /// order, from the current tree. After a Welcome the app judges each pair
  /// against its account's list.
  List<LeafPair> _groupMembersImpl(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    final bytes = _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) => _bindings._output(
            (out) => _bindings._groupMembers(_liveHandle, group, out),
            maximum: 4 * 1024 * 1024));
    return _readLeafPairs(bytes);
  }

  /// [processCommit] that also reports what the commit did and the pairs it
  /// brought in, read from MLS itself (ABI 14). The commit is never refused
  /// for an L1 reason: the caller judges [CommitPairs.addedLeaves] and
  /// holds the conversation.
  CommitPairs processCommitWithPairs(String groupId, List<int> commit) {
    _bindings._bounded(groupId.codeUnits, 128);
    _bindings._bounded(commit, 4 * 1024 * 1024);
    return _bindings._withByteLists(
        <List<int>>[groupId.codeUnits, commit],
        (slices) => _commitPairs((flags, epoch, root, added, committer) =>
            _bindings._groupL1Process(_liveHandle, slices[0], slices[1], flags,
                epoch, root, added, committer)));
  }

  /// [mergePendingCommit] that also reports what this device's own commit
  /// did and the pairs it added (ABI 14).
  CommitPairs mergePendingCommitWithPairs(String groupId) {
    _bindings._bounded(groupId.codeUnits, 128);
    return _bindings._withSlice(
        Uint8List.fromList(groupId.codeUnits),
        (group) => _commitPairs((flags, epoch, root, added, committer) =>
            _bindings._groupL1Merge(
                _liveHandle, group, flags, epoch, root, added, committer)));
  }

  CommitPairs _commitPairs(
      int Function(Pointer<Uint8>, Pointer<Uint64>, Pointer<_PmOwnedBuffer>,
              Pointer<_PmOwnedBuffer>, Pointer<_PmOwnedBuffer>)
          call) {
    final flags = calloc<Uint8>();
    final epoch = calloc<Uint64>();
    final root = calloc<_PmOwnedBuffer>();
    final added = calloc<_PmOwnedBuffer>();
    final committer = calloc<_PmOwnedBuffer>();
    try {
      _bindings._check(call(flags, epoch, root, added, committer));
      // From here the commit is merged (D94): nothing below may throw. A
      // buffer that cannot be read becomes `unreadable`, never an exception.
      var unreadable = false;
      List<int>? read(_PmOwnedBuffer buffer, int maximum,
          {bool optional = false}) {
        if (optional && buffer.data == nullptr) return null;
        try {
          final bytes = _bindings._take(buffer, maximum: maximum);
          buffer
            ..data = nullptr
            ..len = 0;
          return bytes;
        } on Object {
          unreadable = true;
          return null;
        }
      }

      final rootBytes = read(root.ref, 32, optional: true);
      final addedLeaves = _tryReadLeafPairs(read(added.ref, 4 * 1024 * 1024));
      final committers = _tryReadLeafPairs(read(committer.ref, 4096));
      final onlyCommitter =
          committers != null && committers.length == 1 ? committers[0] : null;
      if (addedLeaves == null || onlyCommitter == null) unreadable = true;
      return CommitPairs(
        removed: flags.value & 1 != 0,
        added: flags.value & 2 != 0,
        removedSelf: flags.value & 4 != 0,
        epoch: epoch.value,
        root: rootBytes == null ? null : Uint8List.fromList(rootBytes),
        addedLeaves: unreadable ? const <LeafPair>[] : addedLeaves!,
        committer: unreadable ? null : onlyCommitter,
        unreadable: unreadable,
      );
    } finally {
      if (root.ref.data != nullptr) _bindings._free(root.ref);
      if (added.ref.data != nullptr) _bindings._free(added.ref);
      if (committer.ref.data != nullptr) _bindings._free(committer.ref);
      calloc.free(flags);
      calloc.free(epoch);
      calloc.free(root);
      calloc.free(added);
      calloc.free(committer);
    }
  }

  /// [stageCommit] with change-list version 2 (ABI 14): each add names the
  /// signature key its key package must hold, and a key package with another
  /// leaf key is refused (nothing is staged).
  ({List<int> commit, List<int> welcome, int epoch}) _stageCommitKeyedImpl(
    String groupId, {
    List<
            ({
              List<int> keyPackage,
              List<int> accountId,
              List<int> deviceId,
              List<int> signingKey
            })>
        adds = const [],
    List<({List<int> accountId, List<int> deviceId})> removes = const [],
  }) {
    final changes = encodeKeyedMembershipChanges(adds: adds, removes: removes);
    return _stage(groupId, changes, expectWelcome: adds.isNotEmpty);
  }
}
