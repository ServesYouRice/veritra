import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/c7_move.dart';

/// Review L-7: the moves this device keeps (`c7.moves`) are bounded, but a
/// flood of noted moves never evicts one this device still owes a record
/// for or still has to import.
void main() {
  C7Move noted(int i) => C7Move(
      channelId: 'chan_$i',
      fromConversationId: 'conv_from_$i',
      toConversationId: 'conv_to_$i');

  test('only settled moves make room, oldest first', () {
    final owed = const C7Move(
        channelId: 'chan_owed',
        fromConversationId: 'conv_a',
        toConversationId: 'conv_b',
        owed: true,
        imported: true);
    final toImport = C7Move(
        channelId: 'chan_import',
        fromConversationId: 'conv_c',
        toConversationId: 'conv_d',
        wrapEpoch: 2,
        wrapKey: Uint8List(32),
        wrapClose: 4);
    expect(toImport.importDue, isTrue);
    final moves = <C7Move>[
      owed,
      toImport,
      for (var i = 0; i < c7MoveLimit + 10; i++) noted(i),
    ];
    final kept = C7Move.decodeAll(C7Move.encodeAll(moves));
    expect(kept, hasLength(c7MoveLimit));
    expect(kept.where((m) => m.same(owed)).single.owed, isTrue);
    expect(kept.where((m) => m.same(toImport)).single.importDue, isTrue);
    // The newest settled ones stay; the oldest went.
    expect(kept.any((m) => m.same(noted(c7MoveLimit + 9))), isTrue);
    expect(kept.any((m) => m.same(noted(0))), isFalse);
    // Under the limit nothing is dropped.
    expect(
        C7Move.decodeAll(C7Move.encodeAll(moves.sublist(0, 5))), hasLength(5));
  });
}
