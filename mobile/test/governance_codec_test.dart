import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';

/// C4 record codec (formats 2 and 3) against
/// testing/vectors/c4-governance-record-v3.json. Every format 2 case keeps the
/// bytes it had in the format 2 vector (`c4-governance-record-v2.json` at
/// `e156462`): a state that uses no format 3 field is still written as format
/// 2, so builds that read only format 2 keep reading it. Set
/// C4_WRITE_VECTORS=1 to rewrite the vector from the cases below. A missing
/// vector fails; it never skips.
const _vectorPath = '../testing/vectors/c4-governance-record-v3.json';

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
  // C5: two timeouts, sorted by account bytes after the other lists.
  'with_timeouts': GovernanceState(
    rev: 3,
    owner: 'acc_owner',
    ownerRev: 1,
    moderators: {'acc_m'},
    joined: {'acc_owner': 0, 'acc_m': 1, 'acc_x': 2, 'acc_y': 2},
    timeouts: {
      'acc_y': const MemberTimeout(
        epoch: 7,
        fromMs: 1700000000000,
        untilMs: 1700000600000,
      ),
      'acc_x': const MemberTimeout(
        epoch: 6,
        fromMs: 1699999000000,
        untilMs: 1700002600000,
      ),
    },
  ),
  // Format 3: the C3 and W8 switches alone (no bans).
  'v3_switches': GovernanceState(
    rev: 4,
    owner: 'acc_owner',
    ownerRev: 1,
    admins: {'acc_a': 1},
    joined: {'acc_owner': 0, 'acc_a': 1},
    channelInfoRestricted: true,
    adminsOnlyPins: true,
  ),
  // Format 3: bans alone, sorted by bytes, beside a format 2 election and
  // timeouts (the format 3 tail follows every format 2 section).
  'v3_bans_after_everything': _full().copyWith(
    rev: 10,
    timeouts: {
      'acc_m1': const MemberTimeout(
        epoch: 3,
        fromMs: 1700000000000,
        untilMs: 1700000600000,
      ),
    },
    bans: {'acc_z', 'acc_x', '\u{1F600}'},
  ),
};

/// The format 2 bytes each format 2 state had before format 3 existed
/// (`testing/vectors/c4-governance-record-v2.json` at `e156462`), pinned
/// here so the encoder can never start writing them differently.
const _formatTwoBytes = <String, String>{
  'genesis':
      '02000000000000000000000000000000000000096163635f6f776e6572000000000000000100096163635f6f776e65720000000000000000',
  'no_owner': '02000000000000000100000000000000000000000000000000000000',
  'with_timeouts':
      '02000000000000000300000000000000010400096163635f6f776e65720000000100056163635f6d0000000400056163635f6d000000000000000100096163635f6f776e6572000000000000000000056163635f78000000000000000200056163635f790000000000000002000200056163635f7800000000000000060000018bcfd625c00000018bd00d144000056163635f7900000000000000070000018bcfe568000000018bcfee8fc0',
};

void main() {
  if (Platform.environment['C4_WRITE_VECTORS'] == '1') {
    final out = {
      'format': 'veritra-c4-governance-record-v3',
      'valid': {
        for (final e in _valid.entries) e.key: _hex(encodeGovernance(e.value)),
      },
      'invalid': _invalid(),
    };
    File(
      _vectorPath,
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(out)}\n');
  }
  final vector =
      jsonDecode(File(_vectorPath).readAsStringSync()) as Map<String, dynamic>;
  final valid = vector['valid'] as Map<String, dynamic>;
  final invalid = vector['invalid'] as Map<String, dynamic>;

  test('vector valid cases encode to the fixed bytes and decode back', () {
    expect(valid.keys.toSet(), _valid.keys.toSet());
    for (final e in _valid.entries) {
      expect(_hex(encodeGovernance(e.value)), valid[e.key], reason: e.key);
      expect(
        decodeGovernance(_unhex(valid[e.key] as String)),
        e.value,
        reason: e.key,
      );
    }
  });

  test('vector invalid cases are refused', () {
    expect(invalid, isNotEmpty);
    for (final e in invalid.entries) {
      final item = e.value as Map<String, dynamic>;
      expect(
        () => decodeGovernance(_unhex(item['hex'] as String)),
        throwsA(
          isA<GovernanceCodecException>().having(
            (x) => x.message,
            'message',
            contains(item['reason'] as String),
          ),
        ),
        reason: e.key,
      );
    }
  });

  test('format 2 states keep their format 2 bytes', () {
    for (final e in _formatTwoBytes.entries) {
      expect(_hex(encodeGovernance(_valid[e.key]!)), e.value, reason: e.key);
      expect(valid[e.key], e.value, reason: e.key);
    }
    for (final e in _valid.entries) {
      final version = encodeGovernance(e.value).first;
      expect(version, e.value.usesFormat3 ? 3 : 2, reason: e.key);
    }
  });

  test('format 3 round-trips each field and drops back to 2 without them', () {
    final base = GovernanceState.genesis('acc_owner');
    for (final state in [
      base.copyWith(channelInfoRestricted: true),
      base.copyWith(adminsOnlyPins: true),
      base.copyWith(bans: {'acc_gone'}),
    ]) {
      final bytes = encodeGovernance(state);
      expect(bytes.first, 3);
      expect(decodeGovernance(bytes), state);
      // Lifting the field writes the format 2 bytes again.
      final lifted = state.copyWith(
        channelInfoRestricted: false,
        adminsOnlyPins: false,
        bans: const <String>{},
      );
      expect(_hex(encodeGovernance(lifted)), _formatTwoBytes['genesis']);
    }
  });

  test('every truncation of a format 3 record is refused', () {
    final bytes = encodeGovernance(_valid['v3_bans_after_everything']!);
    for (var n = 0; n < bytes.length; n++) {
      expect(
        () => decodeGovernance(Uint8List.sublistView(bytes, 0, n)),
        throwsA(isA<GovernanceCodecException>()),
        reason: 'cut at $n',
      );
    }
  });

  test('every truncation of a valid record is refused', () {
    final bytes = encodeGovernance(_full());
    for (var n = 0; n < bytes.length; n++) {
      expect(
        () => decodeGovernance(Uint8List.sublistView(bytes, 0, n)),
        throwsA(isA<GovernanceCodecException>()),
        reason: 'cut at $n',
      );
    }
  });

  test('a byte appended is refused', () {
    final bytes = Uint8List.fromList([...encodeGovernance(_full()), 0]);
    expect(
      () => decodeGovernance(bytes),
      throwsA(isA<GovernanceCodecException>()),
    );
  });

  test('encoding is independent of insertion order', () {
    final a = GovernanceState(
      rev: 5,
      owner: 'o',
      ownerRev: 0,
      admins: {'x': 1, 'y': 2},
      moderators: {'m', 'n'},
    );
    final b = GovernanceState(
      rev: 5,
      owner: 'o',
      ownerRev: 0,
      admins: {'y': 2, 'x': 1},
      moderators: {'n', 'm'},
    );
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
      'lone surrogate id': s(moderators: {'\uD800'}),
      'owner is admin': s(admins: {'o': 1}),
      'owner is moderator': s(moderators: {'o'}),
      'admin and moderator': s(admins: {'a': 1}, moderators: {'a'}),
      'ownerRev above rev': s(ownerRev: 4),
      'admin since above rev': s(admins: {'a': 4}),
      'elector not admin': s(electors: {'z'}),
      'empty electorate': s(
        election: Election(opened: 1, electorate: <String>{}),
      ),
      'vote outside electorate': s(
        election: Election(opened: 1, electorate: {'a'}, votes: {'b': 'a'}),
      ),
      'empty id': s(moderators: {''}),
      'long id': s(moderators: {'a' * 256}),
      'owner banned': s().copyWith(bans: {'o'}),
      'banned admin': s(admins: {'a': 1}).copyWith(bans: {'a'}),
      'banned moderator': s(moderators: {'m'}).copyWith(bans: {'m'}),
      'banned and joined': GovernanceState(
        rev: 3,
        owner: 'o',
        ownerRev: 0,
        joined: {'j': 1},
        bans: {'j'},
      ),
      'empty banned id': s().copyWith(bans: {''}),
      'too many bans': s().copyWith(
        bans: {for (var i = 0; i <= maxBans; i++) 'b$i'},
      ),
    };
    for (final e in bad.entries) {
      expect(
        () => encodeGovernance(e.value),
        throwsA(isA<GovernanceCodecException>()),
        reason: e.key,
      );
    }
  });
}

/// Hand-built bad encodings. Built from a valid record so each differs in one
/// way. Offsets are into the `genesis` encoding.
Map<String, Map<String, String>> _invalid() {
  final g = encodeGovernance(GovernanceState.genesis('o')).toList();
  // genesis: ver(1) rev(8) ownerRev(8) flags(1) ownerLen(2) 'o'(1) then
  // admins(2) mods(2) channels(2) joined(2)+{len(2) 'o' since(8)}.
  String h(List<int> b) => _hex(b);
  List<int> with_(int at, int value) => [...g]..[at] = value;
  const flags = 17;
  // genesis: version(0) rev(1-8) owner_rev(9-16) flags(17) owner_len(18-19)
  // owner 'o'(20) admin_count(21-22) moderator_count(23-24) channel_count
  // (25-26) joined_count(27-28) joined entry.
  final unsortedMods = [
    ...g.sublist(0, 23),
    0, 2, 0, 1, 0x62, 0, 1, 0x61, // two moderators: b, then a
    ...g.sublist(25),
  ];
  final dupMods = [
    ...g.sublist(0, 23),
    0, 2, 0, 1, 0x61, 0, 1, 0x61, // a twice
    ...g.sublist(25),
  ];
  Map<String, String> bad(String hex, String reason) => {
        'hex': hex,
        'reason': reason,
      };
  // Format 3: the genesis body, then the settings byte and the ban list.
  List<int> v3(List<int> tail) => [...with_(0, 3), ...tail];
  return {
    'version_1': bad(h(with_(0, 1)), 'unknown version'),
    'version_4': bad(h(with_(0, 4)), 'unknown version'),
    // A format 2 body marked 3 lacks the settings byte and ban list.
    'version_3_without_tail': bad(h(with_(0, 3)), 'truncated'),
    'version_3_settings_without_bans': bad(h(v3([1])), 'truncated'),
    // One state, one encoding: format 3 must carry something.
    'version_3_without_fields': bad(h(v3([0, 0, 0])), 'format 3 without'),
    'version_3_unknown_setting_bit': bad(h(v3([4, 0, 0])), 'unknown setting'),
    'version_3_bans_unsorted': bad(
      h(v3([0, 0, 2, 0, 1, 0x62, 0, 1, 0x61])),
      'not sorted',
    ),
    'version_3_bans_duplicate': bad(
      h(v3([0, 0, 2, 0, 1, 0x61, 0, 1, 0x61])),
      'not sorted',
    ),
    'version_3_owner_banned': bad(h(v3([0, 0, 1, 0, 1, 0x6f])), 'owner is'),
    'version_3_trailing_byte': bad(h(v3([1, 0, 0, 0])), 'trailing'),
    'version_3_too_many_bans': bad(h(v3([0, 0x03, 0xe9])), 'too many bans'),
    'unknown_flag_bit': bad(h(with_(flags, 8)), 'unknown flag'),
    'election_flag_without_body': bad(h(with_(flags, 2)), 'truncated'),
    // C5: bit 2 announces a timeout list, which must hold at least one.
    'timeouts_flag_without_body': bad(h(with_(flags, 4)), 'truncated'),
    'timeouts_flag_with_empty_list': bad(
      h([...with_(flags, 4), 0, 0]),
      'empty timeouts',
    ),
    'owner_rev_above_rev': bad(h(with_(16, 1)), 'owner_rev'),
    'empty_input': bad('', 'truncated'),
    'moderators_unsorted': bad(h(unsortedMods), 'not sorted'),
    'moderators_duplicate': bad(h(dupMods), 'not sorted'),
    'rev_high_bit_set': bad(h(with_(1, 0x80)), 'number too large'),
    'id_not_utf8': bad(
      h([...g.sublist(0, 20), 0xff, ...g.sublist(21)]),
      'UTF-8',
    ),
    'id_with_bom': bad(
      h([
        ...g.sublist(0, 18),
        0, 4, 0xef, 0xbb, 0xbf, 0x61, // owner = BOM + 'a'
        ...g.sublist(21),
      ]),
      'canonical',
    ),
    'owner_is_also_admin': bad(
      h([
        ...g.sublist(0, 21),
        0, 1, 0, 1, 0x6f, 0, 0, 0, 0, 0, 0, 0, 0, 0, // admin 'o' since 0
        ...g.sublist(23),
      ]),
      'owner also',
    ),
  };
}
