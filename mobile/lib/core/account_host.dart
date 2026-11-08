import 'dart:async';

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../desktop/desktop_services.dart';
import '../storage/account_slots.dart';
import '../storage/encrypted_database.dart' show ExistingDatabaseUnavailable;
import '../storage/profile_scope.dart';
import '../storage/local_store.dart';
import 'api_client.dart';
import 'app_state.dart';

// B7 account switcher, the runtime host (docs/designs/B7-passkeys.md, S5).
//
// At most one live LocalStore and AppState exist at any time. A switch tears
// the old runtime down completely before it builds the next one, in one
// serialized queue. No slot code chooses a crypto service or a transport:
// the entry point (main.dart or main_demo.dart) passes its own
// [AccountRuntimeBuilder], so a slot added under the release entry point
// holds UnavailableCryptoService and the release transport.

/// One account's live runtime.
class AccountRuntime {
  AccountRuntime({
    required this.namespace,
    required this.state,
    required this.closeStore,
  });

  final String namespace;
  final AppState state;

  /// Closes the slot's store and gives up its profile lock.
  final Future<void> Function() closeStore;
  DesktopServices? desktop;
}

/// Builds the runtime for [namespace]: its store, AppState and services,
/// from the entry point's own factories.
typedef AccountRuntimeBuilder = Future<AccountRuntime> Function(
    String namespace);

/// Starts the desktop services for a fresh runtime; null off desktop.
typedef AccountDesktopFactory = Future<DesktopServices?> Function(
    AppState state);

/// What a slot holds that must survive a restart: a session or a pending
/// enrollment (a K0 claim can wait seven days, D78).
typedef SlotInspector = Future<bool> Function(String namespace);

/// Signs a slot out on its server without opening its runtime (best effort),
/// for removing an inactive account.
typedef SlotRevoker = Future<void> Function(String namespace);

enum SwitchOutcome {
  done,

  /// Push could not be taken down. Nothing changed; ask the user, then call
  /// again with `acceptPushFailure`.
  needsConfirmation,
  failed,
  busy,
  unchanged,
}

class AccountHost extends ChangeNotifier {
  AccountHost({
    required AccountRegistryStore registryStore,
    required SlotErasing eraser,
    required AccountRuntimeBuilder build,
    required this.primaryNamespace,
    this.desktopFactory,
    this.inspect,
    this.revoke,
    this.beforeLeave,
    this.afterClose,
  })  : _registryStore = registryStore,
        _eraser = eraser,
        _build = build;

  final AccountRegistryStore _registryStore;
  final SlotErasing _eraser;
  final AccountRuntimeBuilder _build;
  final String primaryNamespace;
  final AccountDesktopFactory? desktopFactory;
  final SlotInspector? inspect;
  final SlotRevoker? revoke;

  /// Runs while the old runtime is still live: cancels a wake worker and
  /// uninstalls the wake bridge (step 3).
  final Future<void> Function(AccountRuntime runtime)? beforeLeave;

  /// Runs after the old runtime is closed: purges that slot's opened files
  /// and pasted images (step 7).
  final Future<void> Function(String namespace)? afterClose;

  AccountRegistry registry = AccountRegistry.initial('');
  AccountRuntime? runtime;

  /// True from the start of a switch until the next runtime is mounted: the
  /// UI shows a blocking overlay.
  bool switching = false;

  /// The last failure, for the switcher to show; cleared by the next change.
  AccountHostError? error;

  /// A new account turned out to be one this device already has. The device
  /// the server just created stays in that account's device list.
  bool duplicateAccount = false;

  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  String? _boundIdentity;

  AccountSlot? get activeSlot => registry.slot(registry.active);
  bool get canAdd => registry.canAdd;

  /// Loads the registry, finishes what a crash left (a `removing` slot, a
  /// `pending` slot with nothing in it) and opens the active slot.
  Future<void> start() => _enqueue(() async {
        registry = await _registryStore.load();
        await _finishInterrupted();
        await _openActive();
      });

  Future<void> _finishInterrupted() async {
    for (final slot in List<AccountSlot>.of(registry.slots)) {
      if (slot.state == SlotState.removing) {
        await _eraseAndForget(slot.namespace);
      } else if (slot.state == SlotState.pending &&
          slot.namespace != registry.active) {
        // Wiped only when it holds neither a session nor a pending
        // enrollment: a K0 claim must survive restarts.
        final holds = inspect == null ? true : await inspect!(slot.namespace);
        if (!holds) await _eraseAndForget(slot.namespace);
      }
    }
    if (registry.slot(registry.active) == null) {
      final live =
          registry.slots.where((s) => s.state != SlotState.removing).toList();
      registry = AccountRegistry(
        active: live.isEmpty ? primaryNamespace : live.first.namespace,
        slots: live.isEmpty
            ? <AccountSlot>[
                AccountSlot(
                    namespace: primaryNamespace, state: SlotState.active),
              ]
            : registry.slots,
      );
      await _registryStore.save(registry);
    }
  }

  Future<void> _eraseAndForget(String namespace) async {
    await _eraser.erase(namespace);
    registry = registry.without(namespace, fallback: primaryNamespace);
    if (registry.slots.isEmpty) {
      registry = AccountRegistry.initial(primaryNamespace);
    }
    await _registryStore.save(registry);
  }

  Future<void> _openActive() async {
    final namespace = registry.active;
    await _mount(namespace);
    _bindIdentity();
  }

  Future<void> _mount(String namespace) async {
    final next = await _build(namespace);
    next.desktop = await desktopFactory?.call(next.state);
    next.desktop?.attach();
    next.state.addListener(_bindIdentity);
    runtime = next;
    _boundIdentity = null;
    notifyListeners();
    unawaited(next.state.tryRestoreSession());
  }

  /// Records the account in the registry once a session exists in the slot
  /// (the pending slot becomes active), and refuses a duplicate.
  void _bindIdentity() {
    final current = runtime;
    final session = current?.state.session;
    if (current == null ||
        session == null ||
        session.accountId == null ||
        _disposed) {
      return;
    }
    final identity = '${current.namespace}|${session.baseUrl}|'
        '${session.accountId}|${session.username}';
    if (identity == _boundIdentity) return;
    _boundIdentity = identity;
    unawaited(_enqueue(() async {
      if (runtime != current) return;
      final slot = registry.slot(current.namespace);
      if (slot == null) return;
      if (slot.state == SlotState.active &&
          slot.origin == session.baseUrl &&
          slot.accountId == session.accountId &&
          slot.username == session.username) {
        return;
      }
      try {
        registry = registry.withIdentity(current.namespace, session.baseUrl,
            session.accountId!, session.username);
        await _registryStore.save(registry);
        notifyListeners();
      } on SlotException catch (e) {
        if (e.refusal == SlotRefusal.duplicate) {
          await _dropDuplicate(current);
        }
      } on AccountRegistryException {
        error = AccountHostError.registry;
        notifyListeners();
      }
    }));
  }

  /// The slot just signed in as an account another slot already holds: sign
  /// out, wipe it and go back to the slot that has the account.
  Future<void> _dropDuplicate(AccountRuntime current) async {
    duplicateAccount = true;
    final other = registry.duplicateOf(
        current.state.session!.baseUrl, current.state.session!.accountId!,
        except: current.namespace);
    registry = registry.withRemoving(current.namespace);
    await _registryStore.save(registry);
    await current.state.logout();
    await _leaveAndClose(current, signedOutAlready: true);
    await _eraseAndForget(current.namespace);
    registry = registry.withActive(other?.namespace ?? _firstLive());
    await _registryStore.save(registry);
    await _mount(registry.active);
    notifyListeners();
  }

  String _firstLive() => registry.slots
      .firstWhere((s) => s.state != SlotState.removing,
          orElse: () =>
              AccountSlot(namespace: primaryNamespace, state: SlotState.active))
      .namespace;

  // ------------------------------------------------------------- switching ---

  /// Makes [namespace] the live account. The old runtime is torn down
  /// completely first. When push cannot be taken down, nothing changes and
  /// the result is [SwitchOutcome.needsConfirmation].
  Future<SwitchOutcome> switchTo(String namespace,
      {bool acceptPushFailure = false}) async {
    if (switching) return SwitchOutcome.busy;
    var outcome = SwitchOutcome.done;
    await _enqueue(() async {
      final current = runtime;
      if (current != null && current.namespace == namespace) {
        outcome = SwitchOutcome.unchanged;
        return;
      }
      final target = registry.slot(namespace);
      if (target == null || target.state == SlotState.removing) {
        outcome = SwitchOutcome.failed;
        return;
      }
      error = null;
      duplicateAccount = false;
      switching = true;
      notifyListeners();
      try {
        if (current != null) {
          final pushGone = await _prepare(current);
          if (!pushGone && !acceptPushFailure) {
            current.state.resumeAfterCancelledSwitch();
            outcome = SwitchOutcome.needsConfirmation;
            return;
          }
          await _leaveAndClose(current);
        }
        try {
          await _mount(namespace);
        } catch (_) {
          // Step 8 failed: reopen the previous slot and say so.
          error = AccountHostError.openFailed;
          outcome = SwitchOutcome.failed;
          if (current != null) await _mount(current.namespace);
          return;
        }
        try {
          registry = registry.withActive(namespace);
          await _registryStore.save(registry);
        } catch (_) {
          error = AccountHostError.registry;
        }
        _bindIdentity();
      } finally {
        switching = false;
        notifyListeners();
      }
    });
    return outcome;
  }

  /// Steps 2, 3 and 5: drafts, wake worker and bridge, push.
  Future<bool> _prepare(AccountRuntime current) async {
    final pushGone = await current.state.prepareToLeave();
    try {
      await beforeLeave?.call(current);
    } catch (_) {
      // The bridge is best effort; the native side refuses a stale profile.
    }
    return pushGone;
  }

  /// Steps 6 and 7: desktop services, state, store, then that slot's files.
  Future<void> _leaveAndClose(AccountRuntime current,
      {bool signedOutAlready = false}) async {
    current.state.removeListener(_bindIdentity);
    current.desktop?.detach();
    current.desktop = null;
    await current.state.closeForSwitch();
    try {
      await current.closeStore();
    } catch (_) {}
    runtime = null;
    try {
      await afterClose?.call(current.namespace);
    } catch (_) {}
  }

  // ------------------------------------------------------- add and remove ---

  /// Starts a new account: a pending slot, opened on the connect screen.
  /// The result tells whether the 5-account cap stopped it.
  Future<SwitchOutcome> beginAdd({bool acceptPushFailure = false}) async {
    if (switching) return SwitchOutcome.busy;
    if (!registry.canAdd) {
      error = AccountHostError.full;
      notifyListeners();
      return SwitchOutcome.failed;
    }
    String? namespace;
    await _enqueue(() async {
      try {
        registry = await _registryStore.addPending();
        namespace = _registryStore.newestPending(registry);
      } catch (_) {
        error = AccountHostError.registry;
        notifyListeners();
      }
    });
    if (namespace == null) return SwitchOutcome.failed;
    final outcome =
        await switchTo(namespace!, acceptPushFailure: acceptPushFailure);
    if (outcome != SwitchOutcome.done) {
      // Nothing was opened: do not leave an empty pending slot behind.
      await _enqueue(() async {
        if (registry.slot(namespace!)?.state == SlotState.pending &&
            runtime?.namespace != namespace) {
          await _eraseAndForget(namespace!);
          notifyListeners();
        }
      });
    }
    return outcome;
  }

  /// Removes an account from this device: the slot is journaled as
  /// `removing`, signed out on its server (best effort), deleted, and then
  /// forgotten. Removing the active slot opens another one, or a fresh
  /// connect screen when none is left.
  Future<SwitchOutcome> remove(String namespace,
      {bool acceptPushFailure = false}) async {
    if (switching) return SwitchOutcome.busy;
    var outcome = SwitchOutcome.done;
    await _enqueue(() async {
      if (registry.slot(namespace) == null) {
        outcome = SwitchOutcome.failed;
        return;
      }
      error = null;
      switching = true;
      notifyListeners();
      try {
        final current = runtime;
        final isActive = current != null && current.namespace == namespace;
        if (isActive) {
          final pushGone = await _prepare(current);
          if (!pushGone && !acceptPushFailure) {
            current.state.resumeAfterCancelledSwitch();
            outcome = SwitchOutcome.needsConfirmation;
            return;
          }
        }
        // Journaled first: a crash from here on finishes the removal at the
        // next start.
        registry = registry.withRemoving(namespace);
        await _registryStore.save(registry);
        if (isActive) {
          // The server session ends before the files do.
          await current.state.logout();
          await _leaveAndClose(current);
        } else {
          try {
            await revoke?.call(namespace);
          } catch (_) {
            // Best effort: the token expires on its own.
          }
        }
        await _eraseAndForget(namespace);
        if (runtime == null) {
          if (registry.slots.isEmpty) {
            registry = await _registryStore.addPending();
            registry =
                registry.withActive(_registryStore.newestPending(registry));
            await _registryStore.save(registry);
          } else {
            registry = registry.withActive(_firstLive());
            await _registryStore.save(registry);
          }
          await _mount(registry.active);
        }
      } catch (_) {
        error = AccountHostError.removeFailed;
        outcome = SwitchOutcome.failed;
        if (runtime == null) {
          try {
            await _openActive();
          } catch (_) {}
        }
      } finally {
        switching = false;
        notifyListeners();
      }
    });
    return outcome;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Waits for queued work, then disposes the live runtime (tests).
  @visibleForTesting
  Future<void> idle() => _tail;

  @override
  void dispose() {
    _disposed = true;
    final current = runtime;
    if (current != null) {
      current.state.removeListener(_bindIdentity);
      current.desktop?.detach();
      current.state.dispose();
      unawaited(current.closeStore());
      runtime = null;
    }
    super.dispose();
  }
}

enum AccountHostError { full, registry, openFailed, removeFailed }

/// Looks up the host from the widget tree; null when the app runs without
/// the account switcher (older tests, a fixed AppState).
class AccountHostScope extends InheritedNotifier<AccountHost> {
  const AccountHostScope({
    required AccountHost host,
    required super.child,
    super.key,
  }) : super(notifier: host);

  static AccountHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccountHostScope>()?.notifier;
}

/// Whether [store] holds anything worth keeping in a pending slot. A store
/// that has no database yet holds nothing.
Future<bool> storeHoldsAccount(LocalStore store) async {
  try {
    if (await store.loadSession() != null) return true;
    return await store.loadPendingEnrollment() != null;
  } on ExistingDatabaseUnavailable {
    return false;
  } catch (_) {
    // Unreadable is not empty: keep the slot.
    return true;
  }
}

/// The folder a slot keeps its working files in (attachment ciphertext,
/// backup and recovery files, K2 transfers): the shared support directory
/// for the primary slot, its own `profiles/<namespace>` folder otherwise.
Future<Directory> slotWorkingDirectory(ProfileScope scope) async {
  final directory =
      scope.workingDirectoryIn(await getApplicationSupportDirectory());
  await directory.create(recursive: true);
  return directory;
}

/// The K2 history-transfer folder of a slot; null for the primary slot,
/// which keeps the default `<support>/k2`.
Future<String> Function()? slotHistoryTransferDirectory(ProfileScope scope) {
  if (scope.isPrimary) return null;
  return () async =>
      '${(await slotWorkingDirectory(scope)).path}${Platform.pathSeparator}k2';
}

/// Inspects a pending slot at start: does its store hold a session or a
/// pending enrollment? Opens the store read-only (it never creates files).
SlotInspector slotInspectorFor(String primaryNamespace) => (namespace) async {
      final store = SecureLocalStore(namespace: namespace, existingOnly: true);
      try {
        return await storeHoldsAccount(store);
      } finally {
        await store.close();
      }
    };

/// Signs an inactive slot out on its server without opening its runtime:
/// reads its stored session and revokes the token, within a short timeout.
SlotRevoker slotRevokerFor(ApiClient Function(String baseUrl) clientFactory) =>
    (namespace) async {
      final store = SecureLocalStore(namespace: namespace, existingOnly: true);
      try {
        final session = await store.loadSession();
        if (session == null || session.token.isEmpty) return;
        final client = clientFactory(session.baseUrl);
        try {
          await client
              .logout(session.token)
              .timeout(const Duration(seconds: 5));
        } finally {
          client.close();
        }
      } finally {
        await store.close();
      }
    };
