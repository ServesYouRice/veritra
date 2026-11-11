// B7 S5: the runtime switch (docs/designs/B7-passkeys.md). At most one live
// store and AppState at any time; a switch tears the old one down completely
// first; add, remove and crash recovery keep the registry and the files in
// step; a slot added under the release entry point holds the unavailable
// crypto service.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_host.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/main.dart' show buildReleaseRuntime;
import 'package:private_messenger/storage/account_slots.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/profile_scope.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _HostState extends AppState {
  _HostState(this.namespace, this.world)
      : super(
          apiClientFactory: (_) => throw StateError('no network in this test'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _Quiet(),
        );

  final String namespace;
  final _World world;
  bool pushGone = true;
  int prepared = 0;
  int resumed = 0;
  bool closed = false;
  int logouts = 0;

  void signInAs(String account, {String origin = 'https://a.example'}) {
    session = Session(
      baseUrl: origin,
      token: 't-$account',
      accountId: account,
      username: 'user-$account',
    );
    notifyListeners();
  }

  @override
  Future<bool> prepareToLeave() async {
    prepared++;
    world.events.add('prepare:$namespace');
    return pushGone;
  }

  @override
  void resumeAfterCancelledSwitch() => resumed++;

  @override
  Future<void> closeForSwitch() async {
    closed = true;
    world.events.add('close-state:$namespace');
    dispose();
  }

  @override
  Future<void> logout() async {
    logouts++;
    world.events.add('logout:$namespace');
  }
}

class _Quiet implements SyncService {
  final _c = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _c.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() => _c.close();
}

class _World {
  final List<String> events = <String>[];
  final Map<String, _HostState> states = <String, _HostState>{};
  int live = 0;
  int maxLive = 0;
  final Set<String> failBuild = <String>{};
  final Set<String> hasContent = <String>{};
  final List<String> revoked = <String>[];
  final Set<String> failErase = <String>{};
  late Directory support;
}

/// Fails for the namespaces in [_World.failErase], as a locked file or an
/// unreadable keystore entry would.
class _FlakyEraser implements SlotErasing {
  _FlakyEraser(this.inner, this.world);
  final SlotErasing inner;
  final _World world;

  @override
  Future<void> erase(String namespace) async {
    if (world.failErase.contains(namespace)) {
      throw const FileSystemException('locked');
    }
    await inner.erase(namespace);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _World world;
  late MemorySlotKeyValue kv;

  setUp(() async {
    world = _World()
      ..support = await Directory.systemTemp.createTemp('veritra-host-');
    kv = MemorySlotKeyValue();
  });

  tearDown(() async {
    if (await world.support.exists()) {
      await world.support.delete(recursive: true);
    }
  });

  AccountHost newHost({bool desktop = false}) {
    final scope = const ProfileScope();
    return AccountHost(
      registryStore: AccountRegistryStore(storage: kv),
      eraser: _FlakyEraser(
          SlotEraser(
              storage: kv,
              scope: scope,
              directoryProvider: () async => world.support),
          world),
      primaryNamespace: '',
      build: (ns) async {
        if (world.failBuild.contains(ns)) throw StateError('cannot open');
        // The design's rule: nothing else is alive while a slot is built.
        expect(world.live, 0, reason: 'a runtime was still alive for $ns');
        world.live++;
        if (world.live > world.maxLive) world.maxLive = world.live;
        world.events.add('build:$ns');
        final state = _HostState(ns, world);
        world.states[ns] = state;
        await scope
            .forNamespace(ns)
            .directoryIn(world.support)
            .create(recursive: true);
        return AccountRuntime(
          namespace: ns,
          state: state,
          closeStore: () async {
            world.live--;
            world.events.add('close-store:$ns');
          },
        );
      },
      inspect: (ns) async => world.hasContent.contains(ns),
      revoke: (ns) async => world.revoked.add(ns),
      beforeLeave: (r) async => world.events.add('leave:${r.namespace}'),
      afterClose: (ns) async => world.events.add('purge:$ns'),
    );
  }

  _HostState stateOf(AccountHost host) => host.runtime!.state as _HostState;

  test('start opens the primary slot and nothing else', () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    expect(host.runtime!.namespace, '');
    expect(host.registry.slots, hasLength(1));
    expect(world.live, 1);
  });

  test('adding an account tears the old one down before the new one builds',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    final first = stateOf(host)..signInAs('acct_1');
    await host.idle();

    expect(await host.beginAdd(), SwitchOutcome.done);

    expect(world.maxLive, 1);
    expect(first.closed, isTrue);
    final ns = host.runtime!.namespace;
    expect(ns, startsWith('a-'));
    expect(host.registry.active, ns);
    expect(host.registry.slot(ns)!.state, SlotState.pending);
    // The documented order: prepare, leave hook, close state, close store,
    // purge that slot's files, then build.
    expect(
        world.events,
        containsAllInOrder(<String>[
          'build:',
          'prepare:',
          'leave:',
          'close-state:',
          'close-store:',
          'purge:',
          'build:$ns',
        ]));
    // Nothing of the first account is in the second runtime.
    expect(stateOf(host).session, isNull);
    expect(identical(stateOf(host), first), isFalse);
  });

  test('a session in a pending slot makes it active and survives a restart',
      () async {
    var host = newHost();
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final ns = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();

    final slot = host.registry.slot(ns)!;
    expect(slot.state, SlotState.active);
    expect(slot.accountId, 'acct_2');
    expect(slot.username, 'user-acct_2');
    host.dispose();

    host = newHost();
    addTearDown(host.dispose);
    await host.start();
    expect(host.runtime!.namespace, ns, reason: 'opens the last active slot');
    expect(host.registry.slots, hasLength(2));
  });

  test('the same account in two slots is refused: signed out and wiped',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    final secondState = stateOf(host);

    secondState.signInAs('acct_1');
    await host.idle();

    expect(host.duplicateAccount, isTrue);
    expect(secondState.logouts, 1);
    expect(host.registry.slot(second), isNull);
    expect(Directory('${world.support.path}/profiles/$second').existsSync(),
        isFalse);
    expect(host.runtime!.namespace, '');
    expect(world.maxLive, 1);
  });

  test('another account on the same server is allowed', () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    stateOf(host).signInAs('acct_2');
    await host.idle();
    expect(host.duplicateAccount, isFalse);
    expect(host.registry.hasServer('https://a.example'), isTrue);
    expect(host.registry.liveCount, 2);
  });

  test('at most five accounts', () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    for (var i = 0; i < maxAccountSlots - 1; i++) {
      expect(await host.beginAdd(), SwitchOutcome.done);
      stateOf(host).signInAs('acct_$i');
      await host.idle();
    }
    expect(host.registry.liveCount, maxAccountSlots);
    final before = host.runtime;
    expect(await host.beginAdd(), SwitchOutcome.failed);
    expect(host.error, AccountHostError.full);
    expect(identical(host.runtime, before), isTrue);
  });

  test('push that cannot be taken down asks first and changes nothing',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();
    final secondState = stateOf(host)..pushGone = false;

    expect(await host.switchTo(''), SwitchOutcome.needsConfirmation);
    expect(identical(host.runtime!.state, secondState), isTrue);
    expect(secondState.closed, isFalse);
    expect(secondState.resumed, 1, reason: 'push registers again');
    expect(host.registry.active, second);

    expect(
        await host.switchTo('', acceptPushFailure: true), SwitchOutcome.done);
    expect(host.runtime!.namespace, '');
    expect(secondState.closed, isTrue);
  });

  test('a slot that cannot open leaves the previous one open again', () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();

    world.failBuild.add('');
    expect(await host.switchTo(''), SwitchOutcome.failed);
    expect(host.error, AccountHostError.openFailed);
    expect(host.runtime!.namespace, second);
    expect(host.registry.active, second);
    expect(world.live, 1);
  });

  test('removing an inactive account signs it out and deletes its files',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();
    await host.switchTo('');

    expect(await host.remove(second), SwitchOutcome.done);

    expect(world.revoked, <String>[second]);
    expect(host.registry.slot(second), isNull);
    expect(Directory('${world.support.path}/profiles/$second').existsSync(),
        isFalse);
    expect(host.runtime!.namespace, '');
  });

  test('removing the open account opens another, or a fresh connect screen',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    final first = stateOf(host)..signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();

    expect(await host.remove(second), SwitchOutcome.done);
    expect(host.runtime!.namespace, '');
    expect(identical(host.runtime!.state, first), isFalse,
        reason: 'a rebuilt runtime, not the old one');

    expect(await host.remove(''), SwitchOutcome.done);
    expect(host.registry.liveCount, 1);
    // The emptied primary namespace starts over on the connect screen.
    expect(host.activeSlot!.hasIdentity, isFalse);
    expect(host.runtime!.state.session, isNull);
    expect(world.maxLive, 1);
  });

  test('a crash leaves the registry in a state the next start finishes',
      () async {
    final store = AccountRegistryStore(storage: kv);
    var registry = await store.load();
    registry = registry.withPending('a-removing00001', DateTime.utc(2026));
    registry = registry.withPending('a-empty0000002', DateTime.utc(2026));
    registry = registry.withPending('a-claim0000003', DateTime.utc(2026));
    registry = registry.withRemoving('a-removing00001');
    await store.save(registry);
    for (final ns in <String>[
      'a-removing00001',
      'a-empty0000002',
      'a-claim0000003'
    ]) {
      Directory('${world.support.path}/profiles/$ns')
          .createSync(recursive: true);
    }
    // The waiting K0 claim keeps its slot (D78); the empty one goes.
    world.hasContent.add('a-claim0000003');

    final host = newHost();
    addTearDown(host.dispose);
    await host.start();

    expect(host.registry.slot('a-removing00001'), isNull);
    expect(host.registry.slot('a-empty0000002'), isNull);
    expect(host.registry.slot('a-claim0000003'), isNotNull);
    expect(
        Directory('${world.support.path}/profiles/a-removing00001')
            .existsSync(),
        isFalse);
    expect(
        Directory('${world.support.path}/profiles/a-claim0000003').existsSync(),
        isTrue);
    expect(host.runtime!.namespace, '');
  });

  test(
      'a removal that cannot finish at start keeps its journal and opens '
      'another account', () async {
    final store = AccountRegistryStore(storage: kv);
    var registry = await store.load();
    registry = registry.withPending('a-stuck0000001', DateTime.utc(2026));
    registry = registry.withRemoving('a-stuck0000001');
    // The crash came while the account being removed was the open one.
    registry = AccountRegistry(active: 'a-stuck0000001', slots: registry.slots);
    await store.save(registry);
    Directory('${world.support.path}/profiles/a-stuck0000001')
        .createSync(recursive: true);
    world.failErase.add('a-stuck0000001');

    var host = newHost();
    await host.start();
    expect(host.runtime!.namespace, '',
        reason: 'the half-removed slot is never opened');
    expect(host.registry.slot('a-stuck0000001')!.state, SlotState.removing);
    expect(
        (await store.load()).slot('a-stuck0000001')!.state, SlotState.removing);
    host.dispose();

    // The next start that can delete it finishes the removal.
    world.failErase.clear();
    host = newHost();
    addTearDown(host.dispose);
    await host.start();
    expect(host.registry.slot('a-stuck0000001'), isNull);
    expect(
        Directory('${world.support.path}/profiles/a-stuck0000001').existsSync(),
        isFalse);
  });

  test('a removal that fails never reopens the account being removed',
      () async {
    final host = newHost();
    addTearDown(host.dispose);
    await host.start();
    stateOf(host).signInAs('acct_1');
    await host.idle();
    await host.beginAdd();
    final second = host.runtime!.namespace;
    stateOf(host).signInAs('acct_2');
    await host.idle();
    world.failErase.add(second);

    expect(await host.remove(second), SwitchOutcome.failed);
    expect(host.error, AccountHostError.removeFailed);
    expect(host.runtime!.namespace, '');
    expect(host.registry.active, '');
    expect(host.registry.slot(second)!.state, SlotState.removing,
        reason: 'the journal finishes the removal at the next start');
    expect(world.maxLive, 1);

    // Removing the last live account next to the stuck one still saves a
    // registry the next start can read.
    expect(await host.remove(''), SwitchOutcome.done);
    final saved = await AccountRegistryStore(storage: kv).load();
    expect(saved.slot(second)!.state, SlotState.removing);
    expect(saved.slot(saved.active)!.state, isNot(SlotState.removing));
    expect(host.runtime!.namespace, saved.active);
  });

  test('a registry that names a missing active slot fails closed', () async {
    kv.values['veritra.accounts.v1'] =
        '{"version":1,"active":"a-gone00000001","slots":[{"slot":"","state":"active"}]}';
    final host = newHost();
    addTearDown(host.dispose);
    await expectLater(host.start(), throwsA(anything),
        reason: 'guessing could open the wrong account\'s data');
  });

  group('the release entry point', () {
    setUp(() {
      // The push plugin listens on its event channel when it is built.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        const EventChannel('org.veritra.private_messenger/push_events'),
        MockStreamHandler.inline(onListen: (_, __) {}),
      );
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    test('every slot holds the unavailable crypto service', () async {
      for (final ns in <String>['', 'a-aaaaaaaaaaaa']) {
        final runtime = await buildReleaseRuntime(ns);
        addTearDown(runtime.state.dispose);
        expect(runtime.state.cryptoService, isA<UnavailableCryptoService>(),
            reason: 'slot "$ns"');
        expect(runtime.state.config.demo, isFalse);
        await runtime.closeStore();
      }
    });
  });
}
