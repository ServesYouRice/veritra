import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';

import 'k0_recovery_fakes.dart';
import 'native_test_env.dart';

/// U37: "Check my key" for a recovery key saved earlier. The typed key is
/// decoded and its key id derived on the device, then compared with the id
/// of the account's current key from a status read made at that moment.
/// Nothing derived from the key leaves the device, and a status kept from
/// before (or the device's own K1 copy) never answers "this is your key".
void main() {
  late K0Server server;
  late MemoryLocalStore store;
  late K0Crypto crypto;

  setUp(() {
    server = K0Server()
      ..status = RecoveryKeyStatus(
        available: true,
        configured: true,
        setAt: DateTime.utc(2026, 11, 1),
        rkId: Uint8List.fromList(k0RkId),
      );
    store = MemoryLocalStore();
    crypto = K0Crypto();
  });

  AppState signedIn([K0Crypto? using]) => k0App(server, store, using ?? crypto)
    ..session = k0SignedIn
    ..api = K0Api(server);

  /// Nothing was sent or changed on the server, and every buffer holding
  /// key material was wiped.
  void expectLocalAndWiped(K0Crypto crypto) {
    expect(server.puts, isEmpty);
    expect(server.claims, isEmpty);
    expect(server.reserved, isEmpty);
    expect(server.logins, isEmpty);
    expect(server.cancels, isEmpty);
    for (final buffer in <Uint8List>[
      ...crypto.handedOut,
      ...crypto.derivedPubs,
    ]) {
      expect(buffer.every((byte) => byte == 0), isTrue);
    }
  }

  group('AppState.checkSavedRecoveryKey', () {
    test('the current key, typed in groups and lower case', () async {
      final state = signedIn();
      final reads = server.statusReads;
      final grouped = groupRecoveryKey(k0Display).toLowerCase();
      expect(
        await state.checkSavedRecoveryKey(grouped),
        SavedRecoveryKeyCheck.current,
      );
      // The status is read now, every time.
      expect(server.statusReads, reads + 1);
      expect(crypto.handedOut, hasLength(1));
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    test('a valid key that was replaced is not the current one', () async {
      final state = signedIn();
      expect(
        await state.checkSavedRecoveryKey(k0OtherDisplay),
        SavedRecoveryKeyCheck.notCurrent,
      );
      expect(crypto.handedOut, hasLength(1));
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    test('a typo is not a key', () async {
      final state = signedIn();
      expect(
        await state.checkSavedRecoveryKey('${k0Display.substring(1)}A'),
        SavedRecoveryKeyCheck.notAKey,
      );
      expect(
        await state.checkSavedRecoveryKey(''),
        SavedRecoveryKeyCheck.notAKey,
      );
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    test('offline: no answer, even with a status read before', () async {
      final state = signedIn();
      // A status read earlier, while online, says the typed key is the one.
      await state.refreshRecoveryKeyStatus();
      expect(state.recoveryKeyStatus?.rkId, k0RkId);
      server.statusFailure = k0Error(503, 'storage_unavailable');
      expect(
        await state.checkSavedRecoveryKey(k0Display),
        SavedRecoveryKeyCheck.unknown,
      );
      // The key was never even decoded.
      expect(crypto.decodedTexts, isEmpty);
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    test('replaced on another device since the last read', () async {
      final state = signedIn();
      await state.refreshRecoveryKeyStatus();
      // Another device set a new key; this one still remembers the old id.
      server.status = RecoveryKeyStatus(
        available: true,
        configured: true,
        setAt: DateTime.utc(2026, 11, 20),
        rkId: Uint8List.fromList(k0OtherRkId),
      );
      expect(
        await state.checkSavedRecoveryKey(k0Display),
        SavedRecoveryKeyCheck.notCurrent,
      );
      expect(
        await state.checkSavedRecoveryKey(k0OtherDisplay),
        SavedRecoveryKeyCheck.current,
      );
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    for (final (name, status) in <(String, RecoveryKeyStatus)>[
      (
        'no key set',
        const RecoveryKeyStatus(available: true, configured: false),
      ),
      (
        'a key set but no id sent',
        const RecoveryKeyStatus(available: true, configured: true),
      ),
      (
        'recovery off on the server',
        RecoveryKeyStatus(
          available: false,
          configured: true,
          rkId: Uint8List.fromList(k0RkId),
        ),
      ),
    ]) {
      test('$name: no answer', () async {
        server.status = status;
        final state = signedIn();
        expect(
          await state.checkSavedRecoveryKey(k0Display),
          SavedRecoveryKeyCheck.unknown,
        );
        expect(crypto.decodedTexts, isEmpty);
        expectLocalAndWiped(crypto);
        state.dispose();
      });
    }

    test('signed out: no answer and no request', () async {
      final state = k0App(server, store, crypto)..api = K0Api(server);
      expect(
        await state.checkSavedRecoveryKey(k0Display),
        SavedRecoveryKeyCheck.unknown,
      );
      expect(server.statusReads, 0);
      state.dispose();
    });
  });

  group('Settings: Check my key', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Widget app(Widget home) =>
        MaterialApp(theme: veritraLightTheme(), home: home);

    final checkSaved = find.byKey(
      const ValueKey<String>('recovery-key-check-saved'),
    );
    final field = find.byKey(
      const ValueKey<String>('recovery-key-check-saved-field'),
    );
    final checkButton = find.byKey(
      const ValueKey<String>('recovery-key-check-saved-button'),
    );
    final result = find.byKey(
      const ValueKey<String>('recovery-key-check-saved-result'),
    );

    String? resultText(WidgetTester tester) =>
        result.evaluate().isEmpty ? null : tester.widget<Text>(result).data;

    Future<void> check(WidgetTester tester, String typed) async {
      await tester.enterText(field, typed);
      await tester.tap(checkButton);
      await tester.pumpAndSettle();
    }

    testWidgets('each answer, and Back forgets the typed key', (tester) async {
      phone(tester);
      final state = signedIn();
      await tester.pumpWidget(app(RecoveryKeyScreen(state: state)));
      await tester.pumpAndSettle();
      await tester.tap(checkSaved);
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.recoveryKeyCheckSavedTitle), findsOneWidget);

      await check(tester, k0Display);
      expect(resultText(tester), englishL10n.recoveryKeyCheckSavedCurrent);

      await check(tester, k0OtherDisplay);
      expect(resultText(tester), englishL10n.recoveryKeyCheckSavedNotCurrent);

      await check(tester, 'ABCD-EFGH');
      expect(resultText(tester), englishL10n.recoveryKeyUnreadable);

      server.statusFailure = k0Error(503, 'storage_unavailable');
      await check(tester, k0Display);
      expect(resultText(tester), englishL10n.recoveryKeyCheckSavedUnknown);
      server.statusFailure = null;

      // Editing the text clears the answer.
      await tester.enterText(field, '${k0Display}X');
      await tester.pump();
      expect(result, findsNothing);

      // Back clears the field: opening the check again shows it empty.
      await tester.tap(
        find.byKey(const ValueKey<String>('recovery-key-check-saved-back')),
      );
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      await tester.tap(checkSaved);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(result, findsNothing);
      expectLocalAndWiped(crypto);
      state.dispose();
    });

    for (final (name, status) in <(String, RecoveryKeyStatus)>[
      (
        'no key set',
        const RecoveryKeyStatus(available: true, configured: false),
      ),
      (
        'recovery off',
        RecoveryKeyStatus(
          available: false,
          configured: true,
          rkId: Uint8List.fromList(k0RkId),
        ),
      ),
    ]) {
      testWidgets('not offered: $name', (tester) async {
        phone(tester);
        server.status = status;
        final state = signedIn();
        await tester.pumpWidget(app(RecoveryKeyScreen(state: state)));
        await tester.pumpAndSettle();
        expect(checkSaved, findsNothing);
        state.dispose();
      });
    }

    testWidgets('not offered in the forced follow-up', (tester) async {
      phone(tester);
      final state = signedIn();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: RecoveryKeySetup(
              state: state,
              intro: 'Replace the key',
              onSaved: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Replace the key'), findsOneWidget);
      expect(checkSaved, findsNothing);
      state.dispose();
    });
  });

  group('native key codec and derive', () {
    late NativeCryptoBindings bindings;

    setUp(() {
      if (nativeCryptoSkip() != false) return;
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    });

    test('the real checksum and key id decide the answer', () async {
      final native = _NativeRecoveryCrypto(bindings);
      final saved = bindings.generateRecoveryKey();
      final savedDisplay = bindings.encodeRecoveryKey(saved);
      final replaced = bindings.generateRecoveryKey();
      final replacedDisplay = bindings.encodeRecoveryKey(replaced);
      server.status = RecoveryKeyStatus(
        available: true,
        configured: true,
        rkId: bindings.deriveRecoveryKey(saved).rkId,
      );
      saved.fillRange(0, saved.length, 0);
      replaced.fillRange(0, replaced.length, 0);
      final state = signedIn(native);
      expect(
        await state.checkSavedRecoveryKey(groupRecoveryKey(savedDisplay)),
        SavedRecoveryKeyCheck.current,
      );
      expect(
        await state.checkSavedRecoveryKey(replacedDisplay),
        SavedRecoveryKeyCheck.notCurrent,
      );
      // One character changed: the checksum catches it.
      final typo = savedDisplay.replaceRange(
        20,
        21,
        savedDisplay[20] == 'A' ? 'B' : 'A',
      );
      expect(
        await state.checkSavedRecoveryKey(typo),
        SavedRecoveryKeyCheck.notAKey,
      );
      expectLocalAndWiped(native);
      state.dispose();
    }, skip: nativeCryptoSkip());
  });
}

/// The fake recovery service with the real native codec and derivation, so
/// the check runs over the real checksum and key id.
class _NativeRecoveryCrypto extends K0Crypto {
  _NativeRecoveryCrypto(this.bindings);

  final NativeCryptoBindings bindings;

  @override
  Future<Uint8List> decodeRecoveryKey(String text) async {
    decodedTexts.add(text);
    final entropy = bindings.decodeRecoveryKey(text);
    handedOut.add(entropy);
    return entropy;
  }

  @override
  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List value) async {
    final derived = bindings.deriveRecoveryKey(value);
    derivedPubs.add(derived.rkPub);
    return RecoveryKeyValues(
      rkPub: derived.rkPub,
      rkId: derived.rkId,
      rkAuthPub: derived.rkAuthPub,
    );
  }
}
