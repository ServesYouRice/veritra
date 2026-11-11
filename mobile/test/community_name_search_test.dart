// Community and channel names are searched on the device (C3: the server
// keeps none since migration 0082).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/community_name_search.dart';
import 'package:private_messenger/core/models.dart';

final _communities = <Community>[
  Community(id: 'comm_club', name: '', sharedConversationId: 'conv_shared'),
  Community(id: 'comm_other', name: ''),
  Community(id: 'comm_unnamed', name: 'Server Plaintext'),
];

final _channels = <String, List<Channel>>{
  'comm_club': <Channel>[
    Channel(
        id: 'chan_general',
        communityId: 'comm_club',
        name: '',
        kind: 'open',
        conversationId: 'conv_shared',
        layoutGeneration: 1),
    Channel(
        id: 'chan_secret',
        communityId: 'comm_club',
        name: '',
        kind: 'private',
        conversationId: 'conv_secret',
        layoutGeneration: 1),
    Channel(
        id: 'chan_board',
        communityId: 'comm_club',
        name: '',
        kind: 'private',
        conversationId: 'conv_board',
        layoutGeneration: 1),
  ],
  'comm_other': <Channel>[
    Channel(
        id: 'chan_legacy',
        communityId: 'comm_other',
        name: '',
        kind: 'private'),
  ],
};

const _names = <String, String>{
  'comm_club': 'Chess Club',
  'comm_other': 'Book club',
  'chan_general': 'General Club Talk',
  'chan_secret': 'Club Secrets',
  'chan_board': 'Club Board',
  'chan_legacy': 'Club archive',
};

/// This account is in the shared group and the secret channel, not the
/// board, and in the legacy channel's own conversation.
final _conversations = <Conversation>[
  Conversation(id: 'conv_shared', kind: 'community_shared'),
  Conversation(id: 'conv_secret', kind: 'community_channel'),
  Conversation(
      id: 'conv_legacy', kind: 'community_channel', channelId: 'chan_legacy'),
];

List<MetadataSearchResult> _search(String query,
        {List<Conversation>? conversations, int limit = maxLocalNameHits}) =>
    searchCommunityNames(
      query,
      communities: _communities,
      channelsByCommunity: _channels,
      conversations: conversations ?? _conversations,
      communityName: (community) => _names[community.id],
      channelName: (channel) => _names[channel.id],
      limit: limit,
    );

void main() {
  test('matches decrypted names, ignoring case, communities first', () {
    final hits = _search('cLuB');
    expect(
      hits.map((hit) => '${hit.type}:${hit.id}:${hit.label}:${hit.detail}'),
      <String>[
        'community:comm_club:Chess Club:null',
        'community:comm_other:Book club:null',
        'channel:chan_general:General Club Talk:Chess Club',
        'channel:chan_secret:Club Secrets:Chess Club',
        'channel:chan_legacy:Club archive:Book club',
      ],
    );
  });

  test('a private channel shows only while this account is in it', () {
    expect(_search('board'), isEmpty, reason: 'not in the board conversation');
    expect(
        _search('board', conversations: <Conversation>[
          ..._conversations,
          Conversation(id: 'conv_board', kind: 'community_channel'),
        ]).map((hit) => hit.id),
        <String>['chan_board']);
    expect(_search('secrets', conversations: const <Conversation>[]), isEmpty,
        reason: 'a record kept on the device outlives the membership');
  });

  test('the server name and placeholders never match', () {
    expect(_search('plaintext'), isEmpty);
    expect(_search('server'), isEmpty);
    expect(_search('   '), isEmpty);
  });

  test('stops at the limit', () {
    expect(_search('club', limit: 2).length, 2);
    expect(_search('club', limit: 0), isEmpty);
  });

  test('only a possible username or account ID may go to the server', () {
    expect(mayMatchAccount('alice'), isTrue);
    expect(mayMatchAccount(' Alice_99 '), isTrue);
    expect(mayMatchAccount('acct_${'a' * 32}'), isTrue);
    expect(mayMatchAccount('Chess Club'), isFalse);
    expect(mayMatchAccount('ab'), isFalse);
    expect(mayMatchAccount('a' * 33), isFalse);
    expect(mayMatchAccount('клуб'), isFalse);
    expect(mayMatchAccount('club!'), isFalse);
  });
}
