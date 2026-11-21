// Owner decisions 2026-11-21 (C1/C5). When a join request arrives, its owners and
// admins see "New join request" and nothing else. The server's event carries
// no name, no group or community, and no request id.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/ui/widgets/join_request_notice_banner.dart';
import 'package:private_messenger/ui/widgets/notice_stack.dart';

import 'b7_passkey_fakes.dart';
import 'goldens/golden_harness.dart';

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition not reached');
}

SyncEvent _notice(int id) => SyncEvent(
      id: id,
      type: joinRequestNoticeEventType,
      createdAt: DateTime.utc(2026, 11, 21),
      payload: const <String, Object?>{},
    );

void main() {
  test('the content-free event raises the notice; dismiss hides it', () async {
    final h = PkHarness();
    addTearDown(h.dispose);
    await h.enrolled();
    expect(h.state.joinRequestNotice, isFalse);
    h.api.events.add(_notice(1));
    await h.state.signInWithPasskey(pkOrigin);
    await _waitFor(() => h.state.joinRequestNotice);
    // Not a sync failure: the session stays and nothing else changed.
    await _waitFor(() => h.state.error == null);
    expect(h.state.session, isNotNull);
    expect(ShellNotice.joinRequest.isActive(h.state), isTrue);

    h.state.dismissJoinRequestNotice();
    expect(h.state.joinRequestNotice, isFalse);
    expect(ShellNotice.joinRequest.isActive(h.state), isFalse);
  });

  testWidgets('the banner says only "New join request"', (tester) async {
    final h = PkHarness();
    addTearDown(h.dispose);
    final state = h.state..joinRequestNotice = true;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: JoinRequestNoticeBanner(state: state))),
    );
    expect(find.text('New join request'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('join-request-notice-dismiss')),
    );
    await tester.pump();
    expect(find.text('New join request'), findsNothing);
    expect(state.joinRequestNotice, isFalse);
  });

  testWidgets(
      'Blocked accounts offers the stranger-invite switch, off by default',
      (tester) async {
    setWindowSize(tester, const Size(360, 4000));
    final state = await connectedState();
    await tester.pumpWidget(veritraTestApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    // It sits with the blocks: Settings › Privacy and safety › Blocked
    // accounts (the Settings tab has no room for another row, U18).
    await tester.tap(find.text('Blocked accounts'));
    await tester.pumpAndSettle();
    final tile =
        find.byKey(const ValueKey<String>('settings-invites-shared-only'));
    expect(tile, findsOneWidget);
    expect(
      find.text(
        'Only accept community invites from people I share a group with',
      ),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(state.communityInvitesSharedOnly, isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });
}
