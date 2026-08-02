import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/widgets/empty_state.dart';
import '../chat/chat_screen.dart';

/// Metadata-only search over what the server actually indexes: accounts by
/// exact username, plus communities and channels by name. Message contents
/// are ciphertext on the server and cannot be searched there by design, and
/// account lookup stays exact-match so the user directory cannot be
/// enumerated.
class SearchScreen extends StatefulWidget {
  const SearchScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final query = TextEditingController();
  Timer? _debounce;
  List<MetadataSearchResult> results = <MetadataSearchResult>[];
  bool searching = false;
  bool searched = false;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  void _clear() {
    _generation++;
    _debounce?.cancel();
    query.clear();
    setState(() {
      results = <MetadataSearchResult>[];
      searching = false;
      searched = false;
    });
  }

  Future<void> _search(String value) async {
    final generation = ++_generation;
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        results = <MetadataSearchResult>[];
        searched = false;
      });
      return;
    }
    setState(() => searching = true);
    try {
      final found = await widget.state.searchMetadata(trimmed);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        results = found;
        searched = true;
      });
    } catch (err) {
      if (!mounted || generation != _generation) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err.toString())),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: query,
          builder: (context, _) => TextField(
            controller: query,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            decoration: InputDecoration(
              // The server searches accounts, communities, and channels only.
              // Promising chats and groups made search look broken.
              hintText: 'Search people, communities, channels…',
              border: InputBorder.none,
              filled: false,
              suffixIcon: query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: _clear,
                    ),
            ),
          ),
        ),
        bottom: searching
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: !searched
          ? const EmptyState(
              icon: Icons.search,
              title: 'Search metadata',
              message: 'Find people by exact username, plus communities and '
                  'channels by name. Message contents are end-to-end '
                  'encrypted and never searchable on the server.',
            )
          : results.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'No results',
                  message: 'Nothing matched. Usernames must match exactly, '
                      'and message contents are never searchable.',
                )
              : ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, __) =>
                      const Divider(indent: 72, height: 1),
                  itemBuilder: (context, index) {
                    final result = results[index];
                    final action = _actionFor(result);
                    return ListTile(
                      leading: ExcludeSemantics(
                        child: CircleAvatar(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          child: Icon(
                            _iconForType(result.type),
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      title: Text(result.label),
                      subtitle: Text(_subtitleFor(result)),
                      // Blocking from search is the quickest path away from
                      // unwanted contact, so it lives beside the result.
                      trailing: result.type == 'account'
                          ? _AccountResultActions(
                              state: widget.state,
                              accountId: result.id,
                              label: result.label,
                            )
                          : null,
                      enabled: action != null,
                      onTap: action,
                    );
                  },
                ),
    );
  }

  VoidCallback? _actionFor(MetadataSearchResult result) {
    if (result.type == 'account') {
      return () async {
        // startConversation reuses the existing DM with this account rather
        // than creating a second, indistinguishable thread.
        final conversation = await widget.state.startConversation(
          kind: 'dm',
          memberAccountIds: <String>[result.id],
        );
        if (!mounted) return;
        if (conversation == null) {
          final error = widget.state.error;
          if (error != null) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(error)));
          }
          return;
        }
        _open(conversation.id);
      };
    }
    if (result.type == 'channel') {
      final matches = widget.state.conversations
          .where((conversation) => conversation.channelId == result.id);
      if (matches.isEmpty) return null;
      return () => _open(matches.first.id);
    }
    if (result.type == 'community') {
      final channels =
          widget.state.channelsByCommunity[result.id] ?? const <Channel>[];
      // A community is not a conversation. Navigate to a channel of it when
      // one is known; otherwise the row stays explicitly inert instead of
      // looking tappable and doing nothing.
      for (final channel in channels) {
        final matches = widget.state.conversations
            .where((conversation) => conversation.channelId == channel.id);
        if (matches.isNotEmpty) {
          return () => _open(matches.first.id);
        }
      }
      return null;
    }
    if (result.type == 'conversation') {
      final matches = widget.state.conversations
          .where((conversation) => conversation.id == result.id);
      if (matches.isEmpty) return null;
      return () => _open(matches.first.id);
    }
    return null;
  }

  void _open(String conversationId) {
    widget.state.selectAndPrepare(conversationId);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        state: widget.state,
        conversationId: conversationId,
      ),
    ));
  }

  /// Explains inert rows instead of leaving a dead tap target unexplained.
  String _subtitleFor(MetadataSearchResult result) {
    final type = _labelForType(result.type);
    if (_actionFor(result) != null) {
      return type;
    }
    switch (result.type) {
      case 'community':
        return '$type · No channel you can open yet';
      case 'channel':
        return '$type · Join the community to open it';
      default:
        return type;
    }
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'conversation':
        return Icons.chat_bubble_outline;
      case 'community':
        return Icons.groups_outlined;
      case 'channel':
        return Icons.tag;
      case 'account':
        return Icons.person_outline;
      default:
        return Icons.search;
    }
  }

  String _labelForType(String type) {
    switch (type) {
      case 'conversation':
        return 'Conversation';
      case 'community':
        return 'Community';
      case 'channel':
        return 'Channel';
      case 'account':
        return 'Account';
      default:
        return type;
    }
  }
}

/// Block/unblock straight from an account result.
class _AccountResultActions extends StatelessWidget {
  const _AccountResultActions({
    required this.state,
    required this.accountId,
    required this.label,
  });

  final AppState state;
  final String accountId;
  final String label;

  @override
  Widget build(BuildContext context) {
    final blocked = state.isBlocked(accountId);
    return IconButton(
      tooltip: blocked ? 'Unblock $label' : 'Block $label',
      icon: Icon(blocked ? Icons.person_off : Icons.block),
      onPressed: state.isBusy(Ops.blocks)
          ? null
          : () async {
              final ok = blocked
                  ? await state.unblockAccount(accountId)
                  : await state.blockAccount(accountId);
              if (!context.mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(ok
                      ? (blocked ? '$label unblocked.' : '$label blocked.')
                      : state.errorFor(Ops.blocks) ??
                          'Could not update the block.'),
                ),
              );
            },
    );
  }
}
