// B7 S5: nothing of account A reaches account B across a switch (the I30
// generation fences, docs/designs/B7-passkeys.md "Runtime"). Two real
// AppStates with separate stores stand in for two slots.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';

import 'b7_passkey_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PkHarness> signedIn() async {
    final h = PkHarness();
    await h.enrolled();
    await h.state.signInWithPasskey(pkOrigin);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return h;
  }

  test('a draft of A is written to A\'s store when A is left', () async {
    final a = await signedIn();
    final b = await signedIn();
    addTearDown(b.dispose);
    a.state.composerDrafts.setText('conv_1', 'unsent words');

    expect(await a.state.prepareToLeave(), isTrue);
    await a.state.closeForSwitch();

    expect((await a.store.loadDrafts())['conv_1']?.text, 'unsent words');
    expect(await b.store.loadDrafts(), isEmpty);
    expect(b.state.composerDrafts.textFor('conv_1'), isEmpty);
  });

  test('after the switch no socket, client or sync of A stays alive', () async {
    final a = await signedIn();
    await a.state.prepareToLeave();
    await a.state.closeForSwitch();
    expect(a.api.closedByHost, isTrue);
    expect(a.syncs, isNotEmpty);
    expect(a.syncs.every((s) => s.disposed), isTrue);
  });

  test('a sync page that arrives after the switch changes nothing', () async {
    final a = PkHarness();
    await a.enrolled();
    final gate = a.api.syncGate = Completer<void>();
    a.api.events.add(SyncEvent(
      id: 1,
      type: 'account.passkey_added',
      createdAt: DateTime.utc(2026, 11, 8),
      payload: <String, Object?>{'passkey_id': 'pk_late'},
    ));
    final b = await signedIn();
    addTearDown(b.dispose);
    // A signs in; its first sync page is requested and held.
    final signing = a.state.signInWithPasskey(pkOrigin);
    for (var i = 0; i < 200 && a.api.syncGate != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(a.api.syncGate, isNull, reason: 'the page is in flight');

    // Leave A while the page is in flight, then let the page arrive.
    final leaving = () async {
      await a.state.prepareToLeave();
      await a.state.closeForSwitch();
    }();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await leaving;
    await signing;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await a.store.loadSyncCursor(), 0,
        reason: 'the late page must not commit');
    expect(a.state.passkeyNotice, isNull);
    expect(b.state.passkeyNotice, isNull);
    expect(await b.store.loadSyncCursor(), 0);
  });

  test('push of A is taken down before A is closed, and B starts clean',
      () async {
    final a = await signedIn();
    final b = await signedIn();
    addTearDown(b.dispose);
    expect(await a.state.prepareToLeave(), isTrue,
        reason: 'nothing registered means nothing to fail');
    expect(a.state.pushConfigured, isFalse);
    await a.state.closeForSwitch();
    expect(b.state.session?.accountId, 'acct_owner');
    expect(b.state.pushConfigured, isFalse);
  });

  group('push on the way out', () {
    Future<PkHarness> withPush() async {
      final h = PkHarness();
      h.api.pushEnabled = true;
      await h.enrolled();
      await h.state.signInWithPasskey(pkOrigin);
      for (var i = 0; i < 200 && !h.state.pushConfigured; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(h.state.pushConfigured, isTrue, reason: 'push registered');
      return h;
    }

    test('is taken down once, and the account then closes', () async {
      final a = await withPush();
      expect(await a.state.prepareToLeave(), isTrue);
      expect(a.push.registered, isEmpty);
      expect(a.state.pushConfigured, isFalse);
      await a.state.closeForSwitch();
    });

    test('a refusal is retried twice, then reported', () async {
      final a = await withPush();
      a.push.failUnregister = true;
      expect(await a.state.prepareToLeave(), isFalse);
      expect(a.push.unregisterAttempts, 3);
      a.dispose();
    });
  });
}
