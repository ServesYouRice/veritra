import 'models.dart';

/// The most local community and channel hits one search shows.
const int maxLocalNameHits = 50;

/// Whether [query] could be an account the server's metadata search finds.
///
/// That search matches only an exact username (3 to 32 ASCII letters,
/// digits, `_` or `-`, as the server's sign-up rule) or an `acct_` ID. A
/// query that can be neither is never sent: it would find nothing and could
/// only carry words such as a community name to the server.
bool mayMatchAccount(String query) {
  final trimmed = query.trim();
  return _username.hasMatch(trimmed) || _accountId.hasMatch(trimmed);
}

/// What a submitted search sends for an account lookup: the trimmed query
/// with one leading `@` dropped (people write `@alice`), or null when that
/// could be neither a username nor an account ID, so nothing is sent.
String? accountLookupQuery(String query) {
  var trimmed = query.trim();
  if (trimmed.startsWith('@')) trimmed = trimmed.substring(1);
  return mayMatchAccount(trimmed) ? trimmed : null;
}

final RegExp _username = RegExp(r'^[A-Za-z0-9_-]{3,32}$');
final RegExp _accountId = RegExp(r'^acct_[0-9a-f]{32}$');

/// Communities and channels whose names, as this device decrypted them,
/// contain [query] (ignoring case).
///
/// C3 (migration 0082) removed community and channel names from the server,
/// so it has none to search: this runs on the device only, over the accepted
/// encrypted records ([communityName], [channelName]). A placeholder or the
/// empty server name never matches. A private channel is listed only while
/// this account is in its conversation ([conversations]): a record kept on
/// the device can outlive the membership.
///
/// Hits are communities first, then channels, in the order the app lists
/// them, at most [limit]. A channel hit's [MetadataSearchResult.detail] is
/// its community's name, when known, so two channels of the same name in
/// different communities can be told apart.
List<MetadataSearchResult> searchCommunityNames(
  String query, {
  required List<Community> communities,
  required Map<String, List<Channel>> channelsByCommunity,
  required List<Conversation> conversations,
  required String? Function(Community community) communityName,
  required String? Function(Channel channel) channelName,
  int limit = maxLocalNameHits,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || limit <= 0) return const <MetadataSearchResult>[];
  bool matches(String? name) =>
      name != null &&
      name.trim().isNotEmpty &&
      name.toLowerCase().contains(needle);

  final hits = <MetadataSearchResult>[];
  final names = <String, String?>{};
  for (final community in communities) {
    final name = names[community.id] = communityName(community);
    if (matches(name)) {
      hits.add(MetadataSearchResult(
          type: 'community', id: community.id, label: name!.trim()));
      if (hits.length >= limit) return hits;
    }
  }
  for (final community in communities) {
    for (final channel
        in channelsByCommunity[community.id] ?? const <Channel>[]) {
      if (channel.kind == 'private' &&
          channelConversationId(channel, conversations) == null) {
        continue;
      }
      final name = channelName(channel);
      if (!matches(name)) continue;
      final communityLabel = names[community.id]?.trim();
      hits.add(MetadataSearchResult(
        type: 'channel',
        id: channel.id,
        label: name!.trim(),
        detail: communityLabel == null || communityLabel.isEmpty
            ? null
            : communityLabel,
      ));
      if (hits.length >= limit) return hits;
    }
  }
  return hits;
}

/// The conversation backing [channel], if this account is a member of it. A
/// routed channel names its group; a legacy channel has a conversation of
/// its own that names the channel.
String? channelConversationId(
        Channel channel, List<Conversation> conversations) =>
    conversations
        .where((conversation) => channel.isRouted
            ? conversation.id == channel.conversationId
            : conversation.channelId == channel.id)
        .firstOrNull
        ?.id;
