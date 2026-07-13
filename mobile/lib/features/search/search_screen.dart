import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/widgets/empty_state.dart';
import '../chat/chat_screen.dart';

/// Metadata-only search: conversation titles, communities, channels.
/// Message contents are ciphertext on the server and cannot be searched
/// there by design.
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
              hintText: 'Search chats, groups, communities…',
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
              message: 'Find conversations, communities, and channels by '
                  'name. Message contents are end-to-end encrypted and '
                  'never searchable on the server.',
            )
          : results.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'No results',
                  message: 'Nothing matched. Only names and titles are '
                      'searchable — not message contents.',
                )
              : ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, __) =>
                      const Divider(indent: 72, height: 1),
                  itemBuilder: (context, index) {
                    final result = results[index];
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
                      subtitle: Text(_labelForType(result.type)),
                      onTap: _actionFor(result),
                    );
                  },
                ),
    );
  }

  VoidCallback? _actionFor(MetadataSearchResult result) {
    if (result.type == 'account') {
      return () async {
        final conversation = await widget.state.startConversation(
          kind: 'dm',
          memberAccountIds: <String>[result.id],
        );
        if (!mounted || conversation == null) return;
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatScreen(state: widget.state),
        ));
      };
    }
    if (result.type == 'channel') {
      final matches = widget.state.conversations
          .where((conversation) => conversation.channelId == result.id);
      if (matches.isEmpty) return null;
      return () {
        widget.state.selectConversation(matches.first.id);
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatScreen(state: widget.state),
        ));
      };
    }
    return null;
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
