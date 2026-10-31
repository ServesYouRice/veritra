// A screen reader must be able to activate an emoji in the picker grid
// (TASK-072): the item's semantics node carries a tap action.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/emoji_data.dart';
import 'package:private_messenger/features/chat/emoji_picker.dart';
import 'package:private_messenger/l10n/l10n.dart';

void main() {
  testWidgets('each grid emoji exposes a tap action that picks it',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      String? result;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await showEmojiPicker(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final first = emojiCatalog[EmojiGroup.smileys]!.first;
      final item = find.semantics.byLabel(first.name);
      final node = item.evaluate().single;
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
          reason: 'an announced button must be activatable');
      // The glyph is not read a second time.
      expect(node.label, first.name);

      tester.semantics.performAction(item, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(result, first.emoji);
    } finally {
      semantics.dispose();
    }
  });
}
