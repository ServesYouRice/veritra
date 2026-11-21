import 'package:private_messenger/core/roles/private_channel_membership.dart';
import 'package:private_messenger/storage/local_store.dart';

/// C3 private channel membership (docs/crypto.md): a device adds a new
/// account to a private channel's group only when its user picked it. Tests
/// that are not about who picks have every adder pick every account up
/// front, as the admin's app does before it asks the server to add them.
Future<void> pickForPrivateChannel(
  LocalStore store,
  String conversationId,
  Iterable<String> accounts,
) async {
  final key = privateChannelPicksSetting(conversationId);
  final now = DateTime.now();
  final picks = decodePrivateChannelPicks(await store.loadSetting(key), now);
  for (final account in accounts) {
    picks[account] = now.add(privateChannelPickLifetime).millisecondsSinceEpoch;
  }
  await store.saveSetting(key, encodePrivateChannelPicks(picks));
}
