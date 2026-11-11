import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/account_host.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/k1_restore.dart';
import 'package:private_messenger/core/k1_second_copy.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/account_slots.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Real clients, real OpenMLS, real server: the demo's message flow end to
/// end, including offline use. Run through `scripts/test-demo-e2e.sh`, which
/// builds the server this test starts, stops and restarts.
void main() {
  final serverPath = Platform.environment['VERITRA_DEMO_E2E_SERVER'];
  final dataDir = Platform.environment['VERITRA_DEMO_E2E_DATA'];
  final port = Platform.environment['VERITRA_DEMO_E2E_PORT'] ?? '18082';
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = serverPath == null || dataDir == null || libraryPath == null
      ? 'run scripts/test-demo-e2e.sh'
      : false;

  test('B7 switches two accounts with real MLS in one process', () async {
    final server = _Server(serverPath!, '$dataDir/b7', port);
    addTearDown(server.stop);
    await server.start();
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final stores = <String, MemoryLocalStore>{};
    final clients = <String, _DemoClient>{};
    final host = AccountHost(
      registryStore: AccountRegistryStore(
          storage: MemorySlotKeyValue(), primaryNamespace: 'demo'),
      eraser: _E2eEraser(),
      primaryNamespace: 'demo',
      build: (slot) async {
        final client = _DemoClient(bindings, server.baseUrl,
            store: stores.putIfAbsent(slot, MemoryLocalStore.new));
        clients[slot] = client;
        return AccountRuntime(
            namespace: slot, state: client.state, closeStore: () async {});
      },
    );
    addTearDown(host.dispose);
    await host.start();
    final owner = clients['demo']!;
    await owner.state.createOwner(server.baseUrl, 'switchowner',
        'owner-password-123', 'demo-e2e-setup-token');
    owner.expectOk();
    final ownerId = owner.accountId;
    final invitation = await owner.state.createInvite();
    owner.expectOk();
    await host.idle();
    expect(await host.beginAdd(), SwitchOutcome.done);
    final secondSlot = host.runtime!.namespace;
    final alice = clients[secondSlot]!;
    await alice.state.registerWithInvite(
        server.baseUrl, invitation!.code, 'switchalice', 'alice-password-123');
    alice.expectOk();
    final aliceId = alice.accountId;
    await host.idle();
    expect(host.registry.slots.where((s) => s.hasIdentity).length, 2);
    final dm = await alice.state
        .startConversation(kind: 'dm', memberAccountIds: [ownerId]);
    alice.expectOk();
    expect(await alice.state.sendMessageTo(dm!.id, 'for paused owner'), isTrue);
    await alice.waitUntil(() async => (await alice.store.loadMessages(dm.id))
        .any((m) =>
            m.body == 'for paused owner' && m.state == LocalMessageState.sent));
    alice.state.composerDrafts.setText(dm.id, 'alice draft');

    expect(await host.switchTo('demo'), SwitchOutcome.done);
    final reopenedOwner = clients['demo']!;
    await reopenedOwner.waitFor(dm.id, (m) => m.body == 'for paused owner');
    expect(reopenedOwner.accountId, ownerId);
    expect(reopenedOwner.state.composerDrafts.textFor(dm.id), isEmpty);
    expect(await reopenedOwner.state.sendMessageTo(dm.id, 'for paused alice'),
        isTrue);
    await reopenedOwner.waitUntil(() async =>
        (await reopenedOwner.store.loadMessages(dm.id)).any((m) =>
            m.body == 'for paused alice' && m.state == LocalMessageState.sent));

    expect(await host.switchTo(secondSlot), SwitchOutcome.done);
    final reopenedAlice = clients[secondSlot]!;
    await reopenedAlice.waitFor(dm.id, (m) => m.body == 'for paused alice');
    expect(reopenedAlice.accountId, aliceId);
    expect(reopenedAlice.state.composerDrafts.textFor(dm.id), 'alice draft');
    expect(await stores['demo']!.loadCryptoState(), isNotNull);
    expect(await stores[secondSlot]!.loadCryptoState(), isNotNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));

  test('demo clients exchange every message type and work offline', () async {
    final server = _Server(serverPath!, dataDir!, port);
    addTearDown(server.stop);
    await server.start();
    final baseUrl = server.baseUrl;
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final owner = _DemoClient(bindings, baseUrl);
    addTearDown(owner.dispose);
    await owner.state.createOwner(
        baseUrl, 'owner', 'owner-password-123', 'demo-e2e-setup-token');
    owner.expectOk();

    final alice = await owner.invite('alice');
    addTearDown(alice.dispose);

    // Direct message.
    final dm = await owner.state.startConversation(
      kind: 'dm',
      memberAccountIds: <String>[alice.accountId],
    );
    owner.expectOk();
    final conv = dm!.id;
    expect(await owner.state.sendMessageTo(conv, 'hello alice'), isTrue);
    final hello = await alice.waitFor(conv, (m) => m.body == 'hello alice');
    expect(hello.senderAccountId, owner.accountId);

    // A DM from the owner waits as a request until alice accepts it.
    expect(alice.state.isMessageRequestId(conv), isTrue);
    expect(await alice.state.acceptMessageRequest(conv), isTrue);

    expect(await alice.state.replyTo(conv, hello.key, 'hi owner'), isTrue);
    final reply = await owner.waitFor(conv, (m) => m.body == 'hi owner');
    expect(reply.replyTo, hello.key);

    expect(
        await owner.state.editMessage(conv, hello.key, 'hello, alice'), isTrue);
    await alice.waitFor(
        conv, (m) => m.key == hello.key && m.body == 'hello, alice');

    expect(await alice.state.react(conv, hello.key, '👍'), isTrue);
    await owner.waitUntil(() async =>
        (await owner.store.loadReactions(conv)).any((r) => r.reaction == '👍'));

    expect(await owner.state.deleteMessage(conv, hello.key), isTrue);
    await alice.waitFor(conv, (m) => m.key == hello.key && m.deletedAt != null);

    // Attachment: encrypted on the device, only ciphertext uploaded; the
    // key reaches alice inside the MLS message. Three chunks and a tail.
    final photo =
        File('${Directory.systemTemp.createTempSync('veritra-e2e-photo-').path}'
            '/photo.png')
          ..writeAsBytesSync(
              List<int>.generate(3 * 1024 * 1024 + 17, (index) => index % 251));
    expect(
        await owner.state.sendAttachment(conv,
            path: photo.path, fileName: 'photo.png', mediaType: 'image/png'),
        isTrue,
        reason: owner.state.errorFor(Ops.attachment));
    final attachment =
        await alice.waitFor(conv, (m) => m.kind == LocalMessageKind.attachment);
    final entry =
        AttachmentEntry.listFromBody(attachment.body, conversationId: conv)
            .single;
    expect(entry.fileName, 'photo.png');
    expect(await alice.state.loadAttachment(entry, conversationId: conv),
        photo.readAsBytesSync());

    // A group of three.
    final bob = await owner.invite('bob');
    addTearDown(bob.dispose);
    final group = await owner.state.startConversation(
      kind: 'group',
      title: 'Demo group',
      memberAccountIds: <String>[alice.accountId, bob.accountId],
    );
    owner.expectOk();
    expect(await owner.state.sendMessageTo(group!.id, 'hello group'), isTrue);
    await alice.waitFor(group.id, (m) => m.body == 'hello group');
    await bob.waitFor(group.id, (m) => m.body == 'hello group');
    // A group from an accepted peer (alice took the owner's DM) is a chat; to
    // bob, a stranger's group is a request, and replying accepts it.
    expect(alice.state.isMessageRequestId(group.id), isFalse);
    expect(bob.state.isMessageRequestId(group.id), isTrue);
    expect(await bob.state.acceptMessageRequest(group.id), isTrue);
    expect(await bob.state.sendMessageTo(group.id, 'bob here'), isTrue);
    await owner.waitFor(group.id, (m) => m.body == 'bob here');
    await alice.waitFor(group.id, (m) => m.body == 'bob here');

    // Membership after creation (card I51): Carol joins the group later and
    // reads what is sent from then on; Bob leaves and stops receiving.
    final carol = await owner.invite('carol');
    addTearDown(carol.dispose);
    await owner.state.addConversationMember(group.id, carol.accountId);
    owner.expectOk();
    await alice.waitUntil(() async => (await alice.epoch(group.id)) == 2,
        timeout: const Duration(seconds: 60));
    await carol.waitUntil(() async => (await carol.epoch(group.id)) == 2,
        timeout: const Duration(seconds: 60));
    expect(await alice.state.sendMessageTo(group.id, 'welcome carol'), isTrue);
    await carol.waitFor(group.id, (m) => m.body == 'welcome carol');
    await bob.waitFor(group.id, (m) => m.body == 'welcome carol');
    expect(await carol.state.sendMessageTo(group.id, 'thanks'), isTrue);
    await owner.waitFor(group.id, (m) => m.body == 'thanks');
    // Carol sees nothing from before she joined.
    expect((await carol.store.loadMessages(group.id)).map((m) => m.body),
        isNot(contains('hello group')));

    // Bob's list holds the group before his removal, so its absence later
    // means something.
    await bob.waitUntil(
        () async => bob.state.conversations.any((c) => c.id == group.id));
    expect(await owner.state.removeConversationMember(group.id, bob.accountId),
        isTrue);
    await alice.waitUntil(() async => (await alice.epoch(group.id)) == 3,
        timeout: const Duration(seconds: 60));
    await carol.waitUntil(() async => (await carol.epoch(group.id)) == 3,
        timeout: const Duration(seconds: 60));
    expect(await alice.state.sendMessageTo(group.id, 'without bob'), isTrue);
    await carol.waitFor(group.id, (m) => m.body == 'without bob');
    await owner.waitFor(group.id, (m) => m.body == 'without bob');
    // Catch-up barrier: the server lists an account's sync events in id
    // order and the app commits them one by one, refusing a page out of
    // order. A marker sent after 'without bob', in a chat Bob is still in,
    // proves Bob's sync has passed every earlier event before his store is
    // read, so a slow or rate-limited catch-up cannot pass the check.
    final bobDm = await owner.state.startConversation(
      kind: 'dm',
      memberAccountIds: <String>[bob.accountId],
    );
    owner.expectOk();
    expect(await owner.state.sendMessageTo(bobDm!.id, 'after removal'), isTrue);
    await bob.waitFor(bobDm.id, (m) => m.body == 'after removal',
        timeout: const Duration(seconds: 120));
    // Bob's own view reflects the removal: the group leaves his list.
    await bob.waitUntil(
        () async => !bob.state.conversations.any((c) => c.id == group.id));
    expect((await bob.store.loadMessages(group.id)).map((m) => m.body),
        isNot(contains('without bob')));

    // Restart: a new app instance on the same local data keeps history and
    // keeps decrypting.
    final restarted = await alice.restart();
    addTearDown(restarted.dispose);
    expect(
      (await restarted.store.loadMessages(conv)).map((m) => m.body),
      contains('hi owner'),
    );
    expect(await owner.state.sendMessageTo(conv, 'after restart'), isTrue);
    await restarted.waitFor(conv, (m) => m.body == 'after restart');

    // Offline (Stage 4): with the server down, an app that starts from
    // scratch still opens its chats and history, and queues what it sends.
    await server.stop();
    final offline = await restarted.restart();
    addTearDown(offline.dispose);
    expect(offline.state.session, isNotNull);
    expect(offline.state.conversations.map((c) => c.id), contains(conv));
    await offline.state.loadMessages(conv);
    final shown = offline.state
        .timelineFor(conv)
        .map((envelope) =>
            offline.state.historyFor(conv).forEnvelope(envelope)?.body)
        .toList();
    expect(shown, containsAll(<String>['hi owner', 'after restart']));
    expect(await offline.state.sendMessageTo(conv, 'sent offline'), isTrue);
    expect(offline.state.pendingFor(conv), hasLength(1));

    // Back online: the queued message goes out and arrives.
    await server.start();
    await owner.waitFor(conv, (m) => m.body == 'sent offline',
        timeout: const Duration(seconds: 90));
    await offline.waitUntil(() async => offline.state.pendingFor(conv).isEmpty,
        timeout: const Duration(seconds: 90));

    // VBK2 backups are retired (K1-6). A fresh device joins by a link from
    // the original, and K2 sends it the history. The K1 back up, lose every
    // device, recover and restore path is exercised by K1-7.
    final ownerAccountId = owner.accountId;
    final replacement = _DemoClient(bindings, baseUrl);
    addTearDown(replacement.dispose);
    // A password alone does not sign in a device the server does not know.
    await replacement.state.login(baseUrl, 'owner', 'owner-password-123');
    expect(replacement.state.session, isNull);
    expect(await replacement.store.loadCryptoState(), isNull);
    // The original device links the new one.
    expect(await owner.state.reauthenticate('owner-password-123'), isTrue,
        reason: owner.state.error);
    await owner.state.createDeviceLink();
    expect(owner.state.errorFor(Ops.deviceLink), isNull,
        reason: owner.state.errorFor(Ops.deviceLink));
    final linkCode = owner.state.activeDeviceLinkCode;
    expect(linkCode, isNotNull);
    await replacement.state.claimDeviceLink(baseUrl, linkCode!);
    replacement.expectOk();
    // L1-3: the code appears only after the owner accepted the claim and
    // revealed its committed random, and the replacement looked again.
    expect(replacement.state.pendingDeviceLinkClaim!.verificationCode, isEmpty);
    await owner.state.refreshActiveDeviceLink();
    expect(owner.state.errorFor(Ops.deviceLink), isNull,
        reason: owner.state.errorFor(Ops.deviceLink));
    await replacement.state.completeDeviceLinkClaim();
    replacement.expectOk();
    final verification =
        replacement.state.pendingDeviceLinkClaim!.verificationCode;
    expect(verification, matches(RegExp(r'^\d{8}$')));
    await owner.state.approveActiveDeviceLink(verification);
    expect(owner.state.errorFor(Ops.deviceLink), isNull,
        reason: owner.state.errorFor(Ops.deviceLink));
    await replacement.state.completeDeviceLinkClaim();
    replacement.expectOk();
    expect(replacement.state.session?.accountId, ownerAccountId);
    expect(replacement.state.session?.deviceId,
        isNot(owner.state.session?.deviceId));
    // K2: the owner device sends its history as one encrypted bundle through
    // the real server; both ends settle (rows and files gone).
    await replacement.waitUntil(() async {
      // Spaced out: every client here shares one address and the server's
      // per-address rate limit.
      await Future<void>.delayed(const Duration(seconds: 2));
      await owner.state.resumeHistoryTransfers();
      await replacement.state.resumeHistoryTransfers();
      return (await owner.store.loadHistoryTransfers()).isEmpty &&
          (await replacement.store.loadHistoryTransfers()).isEmpty;
    });
    expect(replacement.state.historyTransferStatus, isNull);
    expect(owner.state.historyTransferStatus, isNull);
    // The history arrived by the K2 transfer, and new messages arrive once
    // the groups add the new device.
    expect((await replacement.store.loadMessages(conv)).map((m) => m.body),
        contains('hi owner'));
    // A member device adds it to the group (I51). The server names the
    // group device with the lowest id the coordinator. Linking sends the
    // owner's devices an event but sends alice's none, so when alice's device
    // is the coordinator it never runs a pass; the owner's device then steps
    // in after the three-minute fallback, which is why the wait is long on
    // that half of the runs. Device ids hold no content, so the CI log names
    // the path this run took.
    final ownerDeviceId = owner.state.session!.deviceId!;
    final aliceDeviceId = offline.state.session!.deviceId!;
    final coordinatorIsOwner = ownerDeviceId.compareTo(aliceDeviceId) < 0;
    final linkWait = Stopwatch()..start();
    final replacementMls =
        replacement.state.cryptoService as MlsConversationCryptoService;
    await replacement.waitUntil(
        () async => await replacementMls.groupEpoch(conv) != null,
        timeout: const Duration(minutes: 4));
    // ignore: avoid_print
    print('demo e2e: linked device joined after '
        '${linkWait.elapsed.inSeconds} s '
        '(coordinator: ${coordinatorIsOwner ? 'owner' : 'alice'})');
    expect(await offline.state.sendMessageTo(conv, 'after restore'), isTrue);
    await replacement.waitFor(conv, (m) => m.body == 'after restore',
        timeout: const Duration(seconds: 90));
    expect(replacement.state.syncRecovery, isNull);
    expect(replacement.state.deviceRecoveryRequired, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 12)));

  // K1-7: every device of the owner is lost (signed out, so no live
  // session and no recovery wait). The account is recovered with the
  // recovery key (K0-R), its history comes back from the K1 backup the lost
  // device uploaded, the forced follow-up sets a new key and password, and
  // alice's device adds the recovered device to the chat (L1 change 4).
  test('K1-7 recovers an account, restores its backup and chats again',
      () async {
    final server = _Server(serverPath!, '$dataDir/k1', port, environment: {
      // K1 and K0-R stay off without it; the recovery proof names it.
      'PRIVATE_MESSENGER_PUBLIC_ORIGIN': 'http://127.0.0.1:$port',
    });
    addTearDown(server.stop);
    await server.start();
    final baseUrl = server.baseUrl;
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final owner = _DemoClient(bindings, baseUrl);
    addTearDown(owner.dispose);
    await owner.state.createOwner(
        baseUrl, 'k1owner', 'owner-password-123', 'demo-e2e-setup-token');
    owner.expectOk();
    final alice = await owner.invite('k1alice');
    addTearDown(alice.dispose);
    // K0-R completion sends peers no coordinator notice (D96 covers link
    // approval only), so alice's device finds the recovered device only
    // through the L1 complete-adds audit: at a catch-up once the group's
    // 15-minute audit is due, then another at least the 3-minute fallback
    // later. Nothing wakes the app for it. The interval is set from the
    // start, as an audit already done would keep its due time.
    alice.state.l1JoinAuditInterval = Duration.zero;

    final dm = await owner.state.startConversation(
        kind: 'dm', memberAccountIds: <String>[alice.accountId]);
    owner.expectOk();
    final conv = dm!.id;
    expect(await owner.state.sendMessageTo(conv, 'before recovery'), isTrue);
    await alice.waitFor(conv, (m) => m.body == 'before recovery');
    expect(await alice.state.acceptMessageRequest(conv), isTrue);
    expect(await alice.state.sendMessageTo(conv, 'alice before'), isTrue);
    await owner.waitFor(conv, (m) => m.body == 'alice before');

    // The recovery key, saved on the owner's only device, turns backups on
    // and starts the first upload.
    await owner.state.refreshRecoveryKeyStatus();
    expect(owner.state.recoveryKeyStatus?.available, isTrue);
    final key = await owner.state.createRecoveryKeyDraft();
    final typed = key.display;
    expect(await owner.state.saveRecoveryKey(key), RecoveryActionResult.done,
        reason: owner.state.errorFor(Ops.recoveryKey));
    key.dispose();
    expect(owner.state.k1BackupState?.hasKey, isTrue,
        reason: 'view ${owner.state.k1BackupView}');
    // The upload saveRecoveryKey started; no second run is forced, so a
    // failed first run (its error is in the state) fails here.
    await owner.waitUntil(
        () async =>
            owner.state.k1BackupState?.lastSuccessAt != null ||
            owner.state.k1BackupState?.lastError != null,
        timeout: const Duration(minutes: 2));
    expect(owner.state.k1BackupState?.lastError, isNull);
    expect(owner.state.k1BackupState?.lastSuccessAt, isNotNull);
    // The iOS "Save a copy" path against the real server and native peek:
    // this device's own row is listed, downloads and matches its header.
    final exported = _RecordingExport();
    owner.state.k1SecondCopyChannel = exported;
    expect(await owner.state.exportK1SecondCopy(), K1SecondCopyExport.saved);
    expect(exported.name,
        k1SecondCopyFileName(owner.accountId, owner.state.session!.deviceId!));
    expect(exported.bytes!.length, greaterThanOrEqualTo(k1BackupPeekBytes));
    expect(owner.state.k1BackupState?.secondCopyAt, isNotNull);
    final ownerId = owner.accountId;
    final lostDevice = owner.state.session!.deviceId!;
    await owner.state.logout();
    owner.dispose();

    final recovered = _DemoClient(bindings, baseUrl);
    addTearDown(recovered.dispose);
    expect(
        await recovered.state.startAccountRecovery(
            baseUrl: baseUrl,
            username: 'k1owner',
            password: 'owner-password-123',
            recoveryKey: typed),
        isTrue,
        reason: recovered.state.errorFor(Ops.accountRecovery));
    await recovered.waitUntil(() async {
      if (recovered.state.session == null) {
        await recovered.state.checkAccountRecovery();
      }
      return recovered.state.session != null;
    }, timeout: const Duration(minutes: 2));
    expect(recovered.accountId, ownerId);
    expect(recovered.state.session!.deviceId, isNot(lostDevice));
    expect(recovered.state.recoveryFollowUp, RecoveryFollowUpStep.restore);

    final copies = await recovered.state.loadK1RestoreList();
    final copy = copies!.singleWhere((entry) => entry.deviceId == lostDevice);
    expect(await recovered.state.restoreFromK1Backup(copy, typed),
        K1RestoreResult.done);
    final restored = {
      for (final m in await recovered.store.loadMessages(conv)) m.body
    };
    expect(restored, containsAll(<String>['before recovery', 'alice before']));
    await recovered.state.finishRecoveryRestoreStep();
    expect(recovered.state.recoveryFollowUp, RecoveryFollowUpStep.recoveryKey);
    final fresh = await recovered.state.createRecoveryKeyDraft();
    var saved = await recovered.state.saveRecoveryKey(fresh);
    if (saved == RecoveryActionResult.needsRecentAuth) {
      // As the screen does: the password again, then the same key.
      expect(await recovered.state.reauthenticate('owner-password-123'), isTrue,
          reason: recovered.state.error);
      saved = await recovered.state.saveRecoveryKey(fresh);
    }
    expect(saved, RecoveryActionResult.done,
        reason: recovered.state.errorFor(Ops.recoveryKey));
    fresh.dispose();
    expect(recovered.state.recoveryFollowUp, RecoveryFollowUpStep.password);
    await recovered.state.changePassword('owner-password-456');
    recovered.expectOk();
    expect(recovered.state.recoveryFollowUp, isNull);

    // Alice's device adds the recovered one through its audit (above). The
    // audit first gives the server's coordinator its turn, so the fallback
    // is shortened, and a foreground resume stands in for the user opening
    // the app (each one catches up and audits).
    alice.state.reconcileFallback = Duration.zero;
    final recoveredMls =
        recovered.state.cryptoService as MlsConversationCryptoService;
    var nudges = 0;
    await recovered.waitUntil(() async {
      if (nudges++ % 50 == 0) {
        alice.state.handleAppLifecycleState(AppLifecycleState.resumed);
      }
      return await recoveredMls.groupEpoch(conv) != null;
    }, timeout: const Duration(minutes: 4));
    expect(await recovered.state.sendMessageTo(conv, 'after recovery'), isTrue);
    await alice.waitFor(conv, (m) => m.body == 'after recovery',
        timeout: const Duration(minutes: 2));
    expect(await alice.state.sendMessageTo(conv, 'welcome back'), isTrue);
    await recovered.waitFor(conv, (m) => m.body == 'welcome back',
        timeout: const Duration(minutes: 2));
    expect(recovered.state.deviceRecoveryRequired, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 14)));
}

/// Records an iOS export instead of showing the document picker.
class _RecordingExport extends K1SecondCopyChannel {
  String? name;
  Uint8List? bytes;

  @override
  Future<bool> export(String name, Uint8List bytes) async {
    this.name = name;
    this.bytes = bytes;
    return true;
  }
}

class _E2eEraser implements SlotErasing {
  @override
  Future<void> erase(String namespace) async {}
}

class _Server {
  _Server(this.path, this.dataDir, this.port,
      {this.environment = const <String, String>{}});

  final String path;
  final String dataDir;
  final String port;

  /// Added to the base environment (K1-7 sets the public origin).
  final Map<String, String> environment;
  Process? _process;

  String get baseUrl => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _process = await Process.start(
      path,
      <String>['serve', '--addr', '127.0.0.1:$port', '--data-dir', dataDir],
      environment: <String, String>{
        // An unset environment means production, which refuses this
        // short local setup token.
        'PRIVATE_MESSENGER_ENV': 'development',
        'PRIVATE_MESSENGER_SETUP_TOKEN': 'demo-e2e-setup-token',
        'PRIVATE_MESSENGER_LOG_LEVEL': 'error',
        ...environment,
      },
    );
    // Drain output so the server never blocks on a full pipe.
    _process!.stdout.drain<void>();
    _process!.stderr.drain<void>();
    final client = HttpClient();
    try {
      for (var attempt = 0; attempt < 120; attempt++) {
        try {
          final request = await client.getUrl(Uri.parse('$baseUrl/healthz'));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) return;
        } on SocketException {
          // Not listening yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      fail('demo server did not become ready');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    await process.exitCode;
  }
}

class _DemoClient {
  _DemoClient(this.bindings, this.baseUrl, {MemoryLocalStore? store})
      : store = store ?? MemoryLocalStore() {
    final attachments =
        Directory.systemTemp.createTempSync('veritra-e2e-attachments-');
    state = AppState(
      apiClientFactory: (url) =>
          ApiClient(baseUrl: url, transport: TransportPolicy.demo),
      cryptoService:
          NativeCryptoService(bindings: bindings, localStore: this.store),
      localStore: this.store,
      attachmentService: AttachmentCryptoService(
        bindings,
        directoryProvider: () async => attachments,
      ),
      syncServiceFactory: (url, token) =>
          WebSocketSyncService(baseUrl: url, token: token),
      config: const ClientConfig(
        demo: true,
        transport: TransportPolicy.demo,
        deviceName: 'E2E test device',
      ),
    );
    final transfers = Directory.systemTemp.createTempSync('veritra-e2e-k2-');
    state.historyTransferDirectory = () async => transfers.path;
  }

  final NativeCryptoBindings bindings;
  final String baseUrl;
  final MemoryLocalStore store;
  late final AppState state;

  String get accountId => state.session!.accountId!;

  void expectOk() => expect(state.error, isNull, reason: state.error);

  Future<_DemoClient> invite(String username) async {
    final invite = await state.createInvite();
    expectOk();
    final client = _DemoClient(bindings, baseUrl);
    await client.state.registerWithInvite(
        baseUrl, invite!.code, username, '$username-password-123');
    client.expectOk();
    return client;
  }

  Future<_DemoClient> restart() async {
    dispose();
    final client = _DemoClient(bindings, baseUrl, store: store);
    await client.state.tryRestoreSession();
    client.expectOk();
    return client;
  }

  /// Every client in this test shares one address, so the server's
  /// per-address rate limit (240 requests a minute) can refuse a catch-up;
  /// the app retries after the window resets, which can take up to a minute.
  Future<void> waitUntil(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    // Captured before the first await, so it names the step that waited.
    final caller =
        StackTrace.current.toString().split('\n').take(3).join(' <- ');
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (state.deviceRecoveryRequired) {
        fail('sync stopped: ${state.error}');
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for sync after ${timeout.inSeconds} s '
            '(connection ${state.connectionStatus.name}, error '
            '${state.error ?? 'none'}) at $caller');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<LocalMessage> waitFor(
    String conversationId,
    bool Function(LocalMessage message) matches, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    LocalMessage? found;
    await waitUntil(() async {
      found =
          (await store.loadMessages(conversationId)).where(matches).firstOrNull;
      return found != null;
    }, timeout: timeout);
    return found!;
  }

  Future<int?> epoch(String conversationId) async =>
      (await (state.cryptoService as NativeCryptoService)
              .groupEpoch(conversationId))
          ?.epoch;

  void dispose() {
    state.sync?.dispose();
    state.sync = null;
  }
}
