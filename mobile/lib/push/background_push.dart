import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../storage/local_store.dart';

const _completionChannel = MethodChannel(
  'org.veritra.private_messenger/push_background',
);

Future<void> performBackgroundPushCatchUp() async {
  final store = SecureLocalStore();
  ApiClient? client;
  var succeeded = false;
  try {
    final session = await store.loadSession();
    if (session == null || session.token.isEmpty) {
      succeeded = true;
      return;
    }
    client = ApiClient(baseUrl: session.baseUrl);
    final snapshot = await store.loadSnapshot();
    var cursor = snapshot?.cursor ?? await store.loadSyncCursor();
    var conversations = snapshot?.conversations ?? <Conversation>[];
    var refreshConversations = false;

    // Keep background execution bounded. A later foreground catch-up resumes
    // from the last transactionally persisted cursor.
    for (var page = 0; page < 5; page++) {
      final events = await client.syncEvents(
        session.token,
        after: cursor,
        limit: 200,
      );
      if (events.isEmpty) break;
      for (final event in events) {
        if (event.id > cursor) cursor = event.id;
        if (event.conversationId != null ||
            event.type.startsWith('conversation.')) {
          refreshConversations = true;
        }
      }
      if (events.length < 200) break;
    }
    if (refreshConversations) {
      conversations = await client.conversations(session.token);
    }
    await store.saveSnapshot(
      conversations,
      snapshot?.messagesByConversation ??
          <String, List<ReceivedMessageEnvelope>>{},
      cursor,
    );
    succeeded = true;
  } on ApiException catch (error) {
    if (error.serverCode == 'full_resync_required') {
      final session = await store.loadSession();
      if (session != null && session.token.isNotEmpty && client != null) {
        final snapshot = await store.loadSnapshot();
        final conversations = await client.conversations(session.token);
        await store.saveSnapshot(
          conversations,
          snapshot?.messagesByConversation ??
              <String, List<ReceivedMessageEnvelope>>{},
          error.intField('latest_event_id') ?? 0,
        );
        succeeded = true;
      }
    }
  } catch (_) {
    // The wake marker remains safe to retry on the next app launch.
  } finally {
    client?.close();
    await _completionChannel.invokeMethod<void>(
      'complete',
      <String, bool>{'succeeded': succeeded},
    );
  }
}
