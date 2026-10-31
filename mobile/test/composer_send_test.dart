// Sending the composer's attachments while the tray can still change
// (TASK-070): removed files are not sent, a file being sent keeps its
// temporary copy, and one batch runs at a time.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart'
    show AttachmentCancellationToken;
import 'package:private_messenger/features/chat/composer_attachments.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// Records each send and finishes it when the test says so.
class _SendingState extends AppState {
  _SendingState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final List<String> sends = <String>[];
  final Map<String, Completer<bool>> pending = <String, Completer<bool>>{};
  final Set<String> throwing = <String>{};

  /// Finishes the send of [name] with [result].
  void finish(String name, {bool result = true}) =>
      pending[name]!.complete(result);

  @override
  Future<bool> sendAttachment(
    String conversationId, {
    required String path,
    required String fileName,
    String? mediaType,
    AttachmentCancellationToken? cancellation,
    int? forwardedHops,
  }) {
    sends.add(fileName);
    if (throwing.contains(fileName)) {
      return Future<bool>.error(StateError('send failed'));
    }
    return (pending[fileName] = Completer<bool>()).future;
  }
}

/// A temporary file whose deletion waits for the test.
class _SlowDiscard extends PendingAttachment {
  _SlowDiscard({required super.path, required super.name})
      : super(size: 1, temporary: true);

  final Completer<void> release = Completer<void>();
  bool discardStarted = false;

  @override
  Future<void> discard() async {
    discardStarted = true;
    await release.future;
    await super.discard();
  }
}

/// Waits (in real time) until [done] holds.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'timed out waiting');
}

/// Lets queued microtasks and file operations run.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Directory dir;
  late _SendingState state;
  late ComposerAttachments tray;
  late BuildContext context;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('composer_send_test_');
    state = _SendingState();
    tray = ComposerAttachments();
  });

  tearDown(() {
    state.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (built) {
          context = built;
          return const SizedBox();
        }),
      ),
    ));
  }

  PendingAttachment file(String name, {bool temporary = false}) {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync(name);
    return PendingAttachment(
      path: path,
      name: name,
      size: name.length,
      temporary: temporary,
    );
  }

  Future<bool> send() => sendPendingAttachments(context, state, 'conv', tray);

  testWidgets(
      'a file removed from the tray while an earlier one sends is '
      'not sent', (tester) async {
    await pumpHost(tester);
    final a = file('a.txt');
    final b = file('b.txt');
    tray
      ..add(a)
      ..add(b);
    final done = send();
    await tester.pump();
    expect(state.sends, <String>['a.txt']);

    await tray.remove(b);
    state.finish('a.txt');
    await tester.pump();
    expect(state.sends, <String>['a.txt'], reason: 'b was removed');
    expect(await done, isTrue);
    expect(tray.isEmpty, isTrue);
  });

  testWidgets('clearing the tray during a send stops the rest', (tester) async {
    await pumpHost(tester);
    tray
      ..add(file('a.txt'))
      ..add(file('b.txt'))
      ..add(file('c.txt'));
    final done = send();
    await tester.pump();
    await tray.clear();
    state.finish('a.txt');
    await tester.pump();
    expect(state.sends, <String>['a.txt']);
    await done;
  });

  testWidgets('the temporary copy of a file being sent outlives its removal',
      (tester) async {
    await pumpHost(tester);
    final pasted = file('pasted.png', temporary: true);
    tray.add(pasted);
    await tester.runAsync(() async {
      final done = send();
      await _settle();

      await tray.remove(pasted);
      expect(File(pasted.path).existsSync(), isTrue,
          reason: 'the send is still reading it');
      state.finish('pasted.png');
      await done;
      expect(File(pasted.path).existsSync(), isFalse,
          reason: 'deleted once the send ended');
    });
  });

  testWidgets('clearing keeps the in-flight temporary copy until it ends',
      (tester) async {
    await pumpHost(tester);
    final first = file('first.png', temporary: true);
    final second = file('second.png', temporary: true);
    tray
      ..add(first)
      ..add(second);
    await tester.runAsync(() async {
      final done = send();
      await _settle();

      await tray.clear();
      expect(File(first.path).existsSync(), isTrue);
      expect(File(second.path).existsSync(), isFalse,
          reason: 'a file that is not being sent goes at once');
      state.finish('first.png');
      await done;
      expect(File(first.path).existsSync(), isFalse);
    });
  });

  testWidgets('a second call while one runs sends nothing', (tester) async {
    await pumpHost(tester);
    tray
      ..add(file('a.txt'))
      ..add(file('b.txt'));
    final first = send();
    await tester.pump();
    final second = send();
    await tester.pump();
    expect(state.sends, <String>['a.txt'],
        reason: 'the second call sends none');
    expect(await second, isFalse);
    expect(tray.isSending, isTrue);

    state.finish('a.txt');
    await tester.pump();
    state.finish('b.txt');
    expect(await first, isTrue);
    expect(state.sends, <String>['a.txt', 'b.txt']);
    expect(tray.isSending, isFalse);
  });

  testWidgets('a second call during the clean-up of a file sends nothing',
      (tester) async {
    await pumpHost(tester);
    final b = file('b.txt');
    await tester.runAsync(() async {
      // Built here, in the real-time zone, so its Completer runs in it too.
      final a = _SlowDiscard(
        path: (File('${dir.path}/a.png')..writeAsStringSync('a')).path,
        name: 'a.png',
      );
      tray
        ..add(a)
        ..add(b);
      final first = send();
      await _settle();
      state.finish('a.png');
      // The first call is now inside the tray's removal of a, waiting for its
      // temporary copy to be deleted.
      await _until(() => a.discardStarted);

      final second = send();
      await _settle();
      expect(state.sends, <String>['a.png'],
          reason: 'b must not be sent by a second call');
      expect(await second, isFalse);

      a.release.complete();
      await _until(() => state.pending.containsKey('b.txt'));
      state.finish('b.txt');
      expect(await first, isTrue);
      expect(state.sends, <String>['a.png', 'b.txt']);
      expect(tray.isSending, isFalse);
    });
  });

  testWidgets('the guard is released after a failure', (tester) async {
    await pumpHost(tester);
    tray
      ..add(file('a.txt'))
      ..add(file('b.txt'));
    final first = send();
    await tester.pump();
    state.finish('a.txt', result: false);
    expect(await first, isFalse);
    expect(tray.isSending, isFalse);
    expect(tray.length, 2, reason: 'a failed file stays on the tray');

    final second = send();
    await tester.pump();
    expect(state.sends, <String>['a.txt', 'a.txt']);
    state.finish('a.txt');
    await tester.pump();
    state.finish('b.txt');
    expect(await second, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('the guard is released when a send throws', (tester) async {
    await pumpHost(tester);
    tray.add(file('a.txt'));
    state.throwing.add('a.txt');
    await expectLater(send(), throwsStateError);
    expect(tray.isSending, isFalse);

    state.throwing.clear();
    final again = send();
    await tester.pump();
    state.finish('a.txt');
    expect(await again, isTrue);
  });

  testWidgets('disposing the tray during a send leaves no listener error',
      (tester) async {
    await pumpHost(tester);
    final pasted = file('pasted.png', temporary: true);
    tray.add(pasted);
    await tester.runAsync(() async {
      final done = send();
      await _settle();

      // ChatScreen.dispose does exactly this.
      unawaited(tray.clear());
      tray.dispose();
      state.finish('pasted.png');
      await done;
      expect(File(pasted.path).existsSync(), isFalse);
    });
    expect(tester.takeException(), isNull);
  });
}
