import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/push/background_wake_runner.dart';
import 'package:private_messenger/push/wake_worker_bridge.dart';

class _Bridge extends PlatformWakeWorkerBridge {
  bool valid = true;
  int remaining = 20000;
  int notices = 0;
  @override
  Future<WakePermitStatus> validatePermit(WakePermit permit) async =>
      WakePermitStatus(valid, valid ? remaining : 0);
  @override
  Future<WakeNoticeResult> presentGenericNotice(
      WakePermit permit, String id) async {
    notices++;
    return WakeNoticeResult.shown;
  }
}

class _LostReplyBridge extends _Bridge {
  @override
  Future<WakePermitStatus> validatePermit(WakePermit permit) =>
      Completer<WakePermitStatus>().future;
}

WakePermit permit({String profile = 'demo', int budget = 1000}) => WakePermit(
    permit: 'e6b2dccb-5cf9-45a0-9aad-231256f55c07',
    profile: profile,
    wakeGeneration: 8,
    budgetMs: budget,
    deadlineEpochMs: DateTime.now().millisecondsSinceEpoch + budget);
const done =
    WakeCatchUpResult(caughtUp: true, decisionsDurable: true, changed: true);

void main() {
  test('only an existing bound owner with durable decisions can ACK success',
      () async {
    final bridge = _Bridge();
    var calls = 0;
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: bridge,
        mayStart: () => true,
        restoreExisting: (ctx) async {
          ctx.bindOwner(() => true);
          return true;
        },
        catchUp: (ctx) async {
          calls++;
          return done;
        });
    expect(await runner.run(permit(profile: 'other')), WakeOutcome.unavailable);
    expect(calls, 0);
    expect(await runner.run(permit()), WakeOutcome.committed);
    await runner.dispose();
    expect(await runner.run(permit()), WakeOutcome.unavailable);
  });

  test('missing protected state never invokes catch-up or a notice', () async {
    final bridge = _Bridge();
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: bridge,
        mayStart: () => true,
        restoreExisting: (_) async => false,
        catchUp: (_) async {
          fail('created work without protected state');
        });
    expect(await runner.run(permit()), WakeOutcome.unavailable);
    expect(bridge.notices, 0);
    await runner.dispose();
  });

  test('a lost read-only native validation reply cannot strand the runner',
      () async {
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: _LostReplyBridge(),
        mayStart: () => true,
        restoreExisting: (_) async {
          fail('unvalidated permit');
        },
        catchUp: (_) async {
          fail('unvalidated permit');
        });
    expect(
        await runner
            .run(permit(budget: 20))
            .timeout(const Duration(seconds: 1)),
        WakeOutcome.retry);
    await runner.dispose();
  });

  test('partial catch-up and non-durable notice decisions leave wake pending',
      () async {
    for (final result in [
      const WakeCatchUpResult(
          caughtUp: false, decisionsDurable: true, changed: true),
      const WakeCatchUpResult(
          caughtUp: true, decisionsDurable: false, changed: true),
    ]) {
      final runner = BackgroundWakeRunner(
          profile: 'demo',
          bridge: _Bridge(),
          mayStart: () => true,
          restoreExisting: (ctx) async {
            ctx.bindOwner(() => true);
            return true;
          },
          catchUp: (_) async => result);
      expect(await runner.run(permit()), WakeOutcome.retry);
      await runner.dispose();
    }
  });

  test('native revocation and account switching refuse later notices',
      () async {
    for (final switchAccount in [false, true]) {
      final bridge = _Bridge();
      var owner = true;
      final runner = BackgroundWakeRunner(
          profile: 'demo',
          bridge: bridge,
          mayStart: () => true,
          restoreExisting: (ctx) async {
            ctx.bindOwner(() => owner);
            return true;
          },
          catchUp: (ctx) async {
            if (switchAccount) {
              owner = false;
            } else {
              bridge.valid = false;
            }
            await ctx.presentDecision(List.filled(32, 'a').join());
            return done;
          });
      expect(await runner.run(permit()), WakeOutcome.retry);
      expect(bridge.notices, 0);
      await runner.dispose();
    }
  });

  test('deadline is monotonic and native validation cannot extend it',
      () async {
    final bridge = _Bridge();
    var aborted = 0;
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: bridge,
        mayStart: () => true,
        restoreExisting: (ctx) async {
          ctx.bindOwner(() => true);
          return true;
        },
        catchUp: (ctx) async {
          ctx.onCancel(() => aborted++);
          await Future<void>.delayed(const Duration(milliseconds: 45));
          await ctx.check();
          return done;
        });
    expect(await runner.run(permit(budget: 20)), WakeOutcome.retry);
    expect(aborted, 1);
    await runner.dispose();
  });

  test(
      'overlapping runs are refused and stale cancellation cannot cancel owner',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var aborted = 0;
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: _Bridge(),
        mayStart: () => true,
        restoreExisting: (ctx) async {
          ctx.bindOwner(() => true);
          return true;
        },
        catchUp: (ctx) async {
          ctx.onCancel(() => aborted++);
          entered.complete();
          await release.future;
          return done;
        });
    final first = runner.run(permit());
    await entered.future;
    expect(await runner.run(permit()), WakeOutcome.unavailable);
    await runner.cancel(const WakeCancellation('stale', 'demo', 'os_stop'));
    expect(aborted, 0);
    await runner.cancel(WakeCancellation(permit().permit, 'demo', 'os_stop'));
    expect(aborted, 1);
    release.complete();
    expect(await first, WakeOutcome.retry);
    await runner.dispose();
  });

  test('permit cancellation aborts the actual dedicated HTTP connection',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    server.listen((r) {
      arrived.complete();
    }); // Deliberately never responds.
    final client = HttpClient();
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: _Bridge(),
        mayStart: () => true,
        restoreExisting: (ctx) async {
          ctx.bindOwner(() => true);
          return true;
        },
        catchUp: (ctx) async {
          ctx.onCancel(() => client.close(force: true));
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:${server.port}/wait'));
          await request.close();
          return done;
        });
    try {
      final work = runner.run(permit());
      await arrived.future;
      await runner.cancel(WakeCancellation(permit().permit, 'demo', 'os_stop'));
      expect(await work.timeout(const Duration(seconds: 1)), WakeOutcome.retry);
      await runner.drain();
    } finally {
      client.close(force: true);
      await server.close(force: true);
      await runner.dispose();
    }
  });
}
