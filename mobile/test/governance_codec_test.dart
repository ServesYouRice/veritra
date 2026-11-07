import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';

/// C4 record codec (format v2) against testing/vectors/c4-governance-record-v2.json.
/// Set C4_WRITE_VECTORS=1 to rewrite the vector from the cases below. A missing
/// vector fails; it never skips.
const _vectorPath = '../testing/vectors/c4-governance-record-v2.json';

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

GovernanceState _full() => GovernanceState(
      rev: 9,
      owner: 'acc_owner',
      ownerRev: 4,
      admins: {'acc_b': 3, 'acc_a': 4},
      moderators: {'acc_m2', 'acc_m1'},
      adminsOnlyPosting: true,
      announcementChannels: {'ch_news', 'ch_all'},
      electors: {'acc_a'},
      joined: {'acc_owner': 0, 'acc_a': 2, 'acc_b': 3, 'acc_m1': 5},
      election: Election(
        opened: 8,
        electorate: {'acc_a', 'acc_b'},
        votes: {'acc_b': 'acc_a'},
      ),
    );

final Map<String, GovernanceState> _valid = {
  'genesis': GovernanceState.genesis('acc_owner'),
  'no_owner': GovernanceState(rev: 1, owner: null, ownerRev: 0),
  'full_with_election': _full(),
  'non_bmp_ids': GovernanceState(
    rev: 2,
    owner: '\u{1F600}x',
    ownerRev: 1,
    moderators: {'～b', '\u{1F600}a'},
  ),
};

void main() {
  if (Platform.environment['C4_WRITE_VECTORS'] == '1') {
    final out = {
      'format': 'veritra-c4-governance-record-v2',
      'valid': {
        for (final e in _valid.entries) e.key: _hex(encodeGovernance(e.value))
      },
      'invalid': _invalid(),
    };
    File(_vectorPath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(out)}\n');
  }
  final vector =
      jsonDecode(File(_vectorPath).readAsStringSync()) as Map<String, dynamic>;
  final valid = vector['valid'] as Map<String, dynamic>;
  final invalid = vector['invalid'] as Map<String, dynamic>;

  test('vector valid cases encode to the fixed bytes and decode back', () {
    expect(valid.keys.toSet(), _valid.keys.toSet());
    for (final e in _valid.entries) {
      expect(_hex(encodeGovernance(e.value)), valid[e.key], reason: e.key);
      expect(decodeGovernance(_unhex(valid[e.key] as String)), e.value,
          reason: e.key);
    }
  });

  test('vector invalid cases are refused', () {
    expect(invalid, isNotEmpty);
    for (final e in invalid.entries) {
      expect(() => decodeGovernance(_unhex(e.value as String)),
          throwsA(isA<GovernanceCodecException>()),
          reason: e.key);
    }
  });

  test('every truncation of a valid record is refused', () {
    final bytes = encodeGovernance(_full());
    for (var n = 0; n < bytes.length; n++) {
      expect(() => decodeGovernance(Uint8List.sublistView(bytes, 0, n)),
          throwsA(isA<GovernanceCodecException>()),
          reason: 'cut at $n');
    }
  });

  test('a byte appended is refused', () {
    final bytes = Uint8List.fromList([...encodeGovernance(_full()), 0]);
    expect(() => decodeGovernance(bytes),
        throwsA(isA<GovernanceCodecException>()));
  });

  test('encoding is independent of insertion order', () {
    final a = GovernanceState(
        rev: 5,
        owner: 'o',
        ownerRev: 0,
        admins: {'x': 1, 'y': 2},
        moderators: {'m', 'n'});
    final b = GovernanceState(
        rev: 5,
        owner: 'o',
        ownerRev: 0,
        admins: {'y': 2, 'x': 1},
        moderators: {'n', 'm'});
    expect(_hex(encodeGovernance(a)), _hex(encodeGovernance(b)));
  });

  test('the encoder refuses states the format cannot hold', () {
    GovernanceState s({
      String? owner = 'o',
      int ownerRev = 0,
      Map<String, int> admins = const {},
      Set<String> moderators = const {},
      Set<String> electors = const {},
      Election? election,
    }) =>
        GovernanceState(
          rev: 3,
          owner: owner,
          ownerRev: ownerRev,
          admins: admins,
          moderators: moderators,
          electors: electors,
          election: election,
        );
    final bad = <String, GovernanceState>{
      'owner is admin': s(admins: {'o': 1}),
      'owner is moderator': s(moderators: {'o'}),
      'admin and moderator': s(admins: {'a': 1}, moderators: {'a'}),
      'ownerRev above rev': s(ownerRev: 4),
      'admin since above rev': s(admins: {'a': 4}),
      'elector not admin': s(electors: {'z'}),
      'empty electorate':
          s(election: Election(opened: 1, electorate: <String>{})),
      'vote outside electorate': s(
          election: Election(opened: 1, electorate: {'a'}, votes: {'b': 'a'})),
      'empty id': s(moderators: {''}),
      'long id': s(moderators: {'a' * 256}),
    };
    for (final e in bad.entries) {
      expect(() => encodeGovernance(e.value),
          throwsA(isA<GovernanceCodecException>()),
          reason: e.key);
    }
  });
}

/// Hand-built bad encodings. Built from a valid record so each differs in one
/// way. Offsets are into the `genesis` encoding.
Map<String, String> _invalid() {
  final g = encodeGovernance(GovernanceState.genesis('o')).toList();
  // genesis: ver(1) rev(8) ownerRev(8) flags(1) ownerLen(2) 'o'(1) then
  // admins(2) mods(2) channels(2) joined(2)+{len(2) 'o' since(8)}.
  String h(List<int> b) => _hex(b);
  List<int> with_(int at, int value) => [...g]..[at] = value;
  const flags = 17;
  final unsortedMods = [
    ...g.sublist(0, 22),
    0, 2, 0, 1, 0x62, 0, 1, 0x61, // two moderators b, a
    ...g.sublist(24),
  ];
  return {
    'version_1': h(with_(0, 1)),
    'version_3': h(with_(0, 3)),
    'unknown_flag_bit': h(with_(flags, 4)),
    'election_flag_without_body': h(with_(flags, 2)),
    'owner_rev_above_rev': h(with_(16, 1)),
    'empty_input': '',
    'moderators_unsorted': h(unsortedMods),
    'rev_high_bit_set': h(with_(1, 0x80)),
    'id_not_utf8': h([...g.sublist(0, 19), 0xff, ...g.sublist(20)]),
    'id_with_bom': h([
      ...g.sublist(0, 17),
      0, 0, 4, 0xef, 0xbb, 0xbf, 0x61, // owner = BOM + 'a'
      ...g.sublist(20),
    ]),
  };
}
