import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/attachments.dart' show isAttachmentWorkingFile;
import 'profile_scope.dart';

// B7 account switcher, slot storage (docs/designs/B7-passkeys.md, S4).
//
// A slot is one account on one server with its own SecureLocalStore
// namespace. The existing install is the primary slot (the empty namespace in
// release builds, `demo` or `demo-<profile>` in demo builds) and nothing moves.
// Further slots get `a-<12 random base32 lowercase>` (demo builds:
// `<primary>-a-<12>`). A namespace never holds a username or a hostname.
//
// The registry lives in secure storage, not in any database, and every write
// is read back and compared. It holds hosts and usernames only; no token,
// secret or key.

/// At most this many accounts per device (D93, O8).
const int maxAccountSlots = 5;

enum SlotState {
  /// Added from the switcher and not signed in yet.
  pending,
  active,

  /// Being deleted from this device; finished at the next start.
  removing,
}

@immutable
class AccountSlot {
  const AccountSlot({
    required this.namespace,
    required this.state,
    this.origin,
    this.accountId,
    this.username,
    this.addedAt,
  });

  /// The SecureLocalStore namespace; unique, `^[a-z0-9-]{0,40}$`.
  final String namespace;
  final SlotState state;

  /// The server origin and account, known once a session was saved.
  final String? origin;
  final String? accountId;
  final String? username;
  final DateTime? addedAt;

  bool get hasIdentity => origin != null && accountId != null;

  AccountSlot copyWith({
    SlotState? state,
    String? origin,
    String? accountId,
    String? username,
  }) =>
      AccountSlot(
        namespace: namespace,
        state: state ?? this.state,
        origin: origin ?? this.origin,
        accountId: accountId ?? this.accountId,
        username: username ?? this.username,
        addedAt: addedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'slot': namespace,
        'state': state.name,
        if (origin != null) 'origin': origin,
        if (accountId != null) 'account_id': accountId,
        if (username != null) 'username': username,
        if (addedAt != null) 'added_at': addedAt!.toUtc().toIso8601String(),
      };

  static AccountSlot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final slot = raw['slot'];
    final state = raw['state'];
    if (slot is! String || !slotNamespacePattern.hasMatch(slot)) return null;
    final parsed = SlotState.values.where((s) => s.name == state);
    if (parsed.isEmpty) return null;
    String? text(String key, int max) {
      final value = raw[key];
      return value is String && value.length <= max ? value : null;
    }

    final added = raw['added_at'];
    return AccountSlot(
      namespace: slot,
      state: parsed.first,
      origin: text('origin', 300),
      accountId: text('account_id', 128),
      username: text('username', 128),
      addedAt: added is String ? DateTime.tryParse(added) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountSlot &&
      other.namespace == namespace &&
      other.state == state &&
      other.origin == origin &&
      other.accountId == accountId &&
      other.username == username &&
      other.addedAt == addedAt;

  @override
  int get hashCode =>
      Object.hash(namespace, state, origin, accountId, username, addedAt);
}

final RegExp slotNamespacePattern = RegExp(r'^[a-z0-9-]{0,40}$');

/// Why the registry refused a change.
enum SlotRefusal { full, duplicate, unknown }

class SlotException implements Exception {
  const SlotException(this.refusal);
  final SlotRefusal refusal;
  @override
  String toString() => 'SlotException(${refusal.name})';
}

/// The set of slots and which one is active. Immutable: each change returns a
/// new registry that the store writes and reads back.
@immutable
class AccountRegistry {
  const AccountRegistry({
    required this.active,
    required this.slots,
  });

  /// A device that never added a second account: one active primary slot.
  factory AccountRegistry.initial(String primaryNamespace) => AccountRegistry(
        active: primaryNamespace,
        slots: <AccountSlot>[
          AccountSlot(namespace: primaryNamespace, state: SlotState.active),
        ],
      );

  /// The namespace opened at start.
  final String active;
  final List<AccountSlot> slots;

  AccountSlot? slot(String namespace) {
    for (final slot in slots) {
      if (slot.namespace == namespace) return slot;
    }
    return null;
  }

  /// Slots still counted against the cap: all but those being removed.
  int get liveCount => slots.where((s) => s.state != SlotState.removing).length;

  bool get canAdd => liveCount < maxAccountSlots;

  /// Another slot with the same server and account (design: one account per
  /// slot). Slots that have no identity yet never match.
  AccountSlot? duplicateOf(String origin, String accountId, {String? except}) {
    for (final slot in slots) {
      if (slot.namespace != except &&
          slot.state != SlotState.removing &&
          slot.origin == origin &&
          slot.accountId == accountId) {
        return slot;
      }
    }
    return null;
  }

  /// Whether [origin] already holds a live slot: the add-account screen then
  /// warns that this server can tell the accounts are on one device (O10).
  bool hasServer(String origin) =>
      slots.any((s) => s.state != SlotState.removing && s.origin == origin);

  AccountRegistry withPending(String namespace, DateTime now) {
    if (!canAdd) throw const SlotException(SlotRefusal.full);
    if (slot(namespace) != null) {
      throw const SlotException(SlotRefusal.duplicate);
    }
    return AccountRegistry(
      active: active,
      slots: <AccountSlot>[
        ...slots,
        AccountSlot(
            namespace: namespace, state: SlotState.pending, addedAt: now),
      ],
    );
  }

  /// A session was saved in [namespace]: it becomes active with its identity.
  /// A second slot for the same server and account is refused.
  AccountRegistry withIdentity(
      String namespace, String origin, String accountId, String? username) {
    final current = slot(namespace);
    // A slot being removed never becomes active again.
    if (current == null || current.state == SlotState.removing) {
      throw const SlotException(SlotRefusal.unknown);
    }
    if (duplicateOf(origin, accountId, except: namespace) != null) {
      throw const SlotException(SlotRefusal.duplicate);
    }
    return _replace(
        namespace,
        current.copyWith(
          state: SlotState.active,
          origin: origin,
          accountId: accountId,
          username: username,
        ));
  }

  AccountRegistry withActive(String namespace) {
    final current = slot(namespace);
    if (current == null || current.state == SlotState.removing) {
      throw const SlotException(SlotRefusal.unknown);
    }
    return AccountRegistry(active: namespace, slots: slots);
  }

  AccountRegistry withRemoving(String namespace) {
    final current = slot(namespace);
    if (current == null) throw const SlotException(SlotRefusal.unknown);
    return _replace(namespace, current.copyWith(state: SlotState.removing));
  }

  /// The slot's data is gone. If it was active, the first live slot becomes
  /// active; with none left the registry is empty and the caller starts the
  /// connect flow in a fresh pending slot.
  AccountRegistry without(String namespace, {required String fallback}) {
    final rest = slots.where((s) => s.namespace != namespace).toList();
    final live = rest.where((s) => s.state != SlotState.removing).toList();
    final nextActive = namespace == active
        ? (live.isNotEmpty ? live.first.namespace : fallback)
        : active;
    return AccountRegistry(active: nextActive, slots: rest);
  }

  AccountRegistry _replace(String namespace, AccountSlot next) =>
      AccountRegistry(
        active: active,
        slots: <AccountSlot>[
          for (final slot in slots) slot.namespace == namespace ? next : slot,
        ],
      );

  String encode() => jsonEncode(<String, Object?>{
        'version': 1,
        'active': active,
        'slots': <Object?>[for (final slot in slots) slot.toJson()],
      });

  /// Null when [text] is not a registry this version understands; the caller
  /// then fails closed instead of guessing.
  static AccountRegistry? tryDecode(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map || raw['version'] != 1) return null;
      final active = raw['active'];
      final list = raw['slots'];
      if (active is! String ||
          list is! List ||
          list.length > maxAccountSlots + 2) {
        return null;
      }
      final slots = <AccountSlot>[];
      for (final row in list) {
        final slot = AccountSlot.tryParse(row);
        if (slot == null || slots.any((s) => s.namespace == slot.namespace)) {
          return null;
        }
        slots.add(slot);
      }
      final registry = AccountRegistry(active: active, slots: slots);
      if (slots.isEmpty || registry.slot(active) == null) return null;
      return registry;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AccountRegistry &&
      other.active == active &&
      listEquals(other.slots, slots);

  @override
  int get hashCode => Object.hash(active, Object.hashAll(slots));
}

/// The part of secure storage the registry needs.
abstract class SlotKeyValue {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Every stored key that starts with [prefix] (quarantined database keys).
  Future<List<String>> keysWithPrefix(String prefix);
}

class SecureSlotKeyValue implements SlotKeyValue {
  SecureSlotKeyValue({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: false),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
  @override
  Future<List<String>> keysWithPrefix(String prefix) async => <String>[
        for (final key in (await _storage.readAll()).keys)
          if (key.startsWith(prefix)) key,
      ];
}

class MemorySlotKeyValue implements SlotKeyValue {
  final Map<String, String> values = <String, String>{};

  /// Makes the next write store something else, to test the read-back.
  bool corruptNextWrite = false;

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = corruptNextWrite ? '$value ' : value;
    corruptNextWrite = false;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<List<String>> keysWithPrefix(String prefix) async =>
      values.keys.where((k) => k.startsWith(prefix)).toList();
}

class AccountRegistryException implements Exception {
  const AccountRegistryException(this.kind);
  final String kind;
  @override
  String toString() => 'AccountRegistryException($kind)';
}

class AccountRegistryStore {
  AccountRegistryStore({
    required SlotKeyValue storage,
    this.primaryNamespace = '',
    Random? random,
    DateTime Function()? clock,
  })  : _storage = storage,
        _random = random ?? Random.secure(),
        _clock = clock ?? DateTime.now;

  final SlotKeyValue _storage;
  final String primaryNamespace;
  final Random _random;
  final DateTime Function() _clock;

  /// `veritra.accounts.v1` in release builds; demo builds keep their own.
  String get key => primaryNamespace.isEmpty
      ? 'veritra.accounts.v1'
      : 'veritra.$primaryNamespace.accounts.v1';

  /// The saved registry; the implicit one-slot registry on a device that
  /// never added an account. A stored entry this version cannot read is an
  /// error: guessing could open the wrong account's data.
  Future<AccountRegistry> load() async {
    final text = await _storage.read(key);
    if (text == null) return AccountRegistry.initial(primaryNamespace);
    final registry = AccountRegistry.tryDecode(text);
    if (registry == null) {
      throw const AccountRegistryException('unreadable');
    }
    return registry;
  }

  /// Writes [registry] and reads it back; a mismatch is an error and the
  /// caller must not proceed as if the change was saved.
  Future<void> save(AccountRegistry registry) async {
    final text = registry.encode();
    // Never write what [load] would refuse: that would keep the app from
    // opening at the next start (for example, too many slots left
    // `removing` by deletes that keep failing).
    if (AccountRegistry.tryDecode(text) == null) {
      throw const AccountRegistryException('invalid');
    }
    await _storage.write(key, text);
    if (await _storage.read(key) != text) {
      throw const AccountRegistryException('readback');
    }
  }

  /// A fresh namespace that no slot of [registry] uses.
  String newNamespace(AccountRegistry registry) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    while (true) {
      final id = String.fromCharCodes(<int>[
        for (var i = 0; i < 12; i++)
          alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
      ]);
      final namespace =
          primaryNamespace.isEmpty ? 'a-$id' : '$primaryNamespace-a-$id';
      if (registry.slot(namespace) == null) return namespace;
    }
  }

  Future<AccountRegistry> addPending() async {
    final current = await load();
    final namespace = newNamespace(current);
    final next = current.withPending(namespace, _clock());
    // Snapshot the primary's preview choice before it can be removed. A new
    // account then owns this choice even if it has never been opened yet.
    final preview =
        await _storage.read('veritra.notifications.hide_preview.v1') ?? 'false';
    final key =
        ProfileScope(namespace: namespace, primaryNamespace: primaryNamespace)
            .secureKey('notifications.hide_preview.v1');
    await _storage.write(key, preview);
    if (await _storage.read(key) != preview) {
      throw const AccountRegistryException('readback');
    }
    await save(next);
    return next;
  }

  /// The namespace [addPending] created last.
  String newestPending(AccountRegistry registry) =>
      registry.slots.lastWhere((s) => s.state == SlotState.pending).namespace;
}

/// Deletes one slot's data; the host depends on this, tests fake it.
abstract class SlotErasing {
  Future<void> erase(String namespace);
}

/// Removes every file and key of one slot. A delete, not the quarantine
/// reset. Never deletes the support directory recursively: the primary slot
/// in release builds is the support directory itself, and the
/// `profiles/<namespace>` folders inside it belong to other slots.
class SlotEraser implements SlotErasing {
  SlotEraser({
    required SlotKeyValue storage,
    required this.scope,
    Future<Directory> Function()? directoryProvider,
  })  : _storage = storage,
        _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  final SlotKeyValue _storage;
  final Future<Directory> Function() _directoryProvider;

  /// Tells which names a namespace owns (see [ProfileScope]).
  final ProfileScope scope;

  static const databaseFileNames = <String>[
    'veritra-local.db-wal',
    'veritra-local.db-shm',
    'veritra-local.db',
    'veritra-local.reset-intent',
    'veritra-local.reset-intent.tmp',
  ];

  @override
  Future<void> erase(String namespace) async {
    final slot = scope.forNamespace(namespace);
    final base = await _directoryProvider();
    final directory = slot.directoryIn(base);
    if (await directory.exists()) {
      if (namespace.isEmpty) {
        // The support root also holds other slots: delete by name only.
        for (final name in databaseFileNames) {
          final file = File('${directory.path}${Platform.pathSeparator}$name');
          if (await file.exists()) await file.delete();
        }
        await for (final entry in directory.list(followLinks: false)) {
          final leaf = entry.path.split(Platform.pathSeparator).last;
          if (entry is Directory &&
              (leaf.startsWith('unreadable-') || leaf == 'k2')) {
            await entry.delete(recursive: true);
          } else if (entry is File &&
              (isAttachmentWorkingFile(leaf) ||
                  leaf.endsWith('.backup-ciphertext') ||
                  leaf == '.veritra-recovery.partial')) {
            await entry.delete();
          }
        }
      } else {
        await directory.delete(recursive: true);
      }
    }
    final databaseKey = slot.databaseKey;
    for (final name in <String>[
      databaseKey,
      slot.legacyRecordKey,
      slot.secureKey('read_receipts.v1'),
      slot.secureKey('notifications.hide_preview.v1'),
      ...await _storage.keysWithPrefix(slot.secureKey('report_seed.v1.')),
      ...await _storage.keysWithPrefix('$databaseKey.quarantined.'),
    ]) {
      await _storage.delete(name);
    }
  }
}

/// A cold wake may open only the active slot named by protected storage.
/// Missing or locked registry data never delegates profile choice to native.
Future<String?> activeAccountSlotForWake(AccountRegistryStore store) async {
  try {
    final registry = await store.load();
    final active = registry.slot(registry.active);
    return active != null && active.state != SlotState.removing
        ? active.namespace
        : null;
  } catch (_) {
    return null;
  }
}
