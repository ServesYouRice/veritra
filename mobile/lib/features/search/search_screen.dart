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

  Future<void> _search(String value) async {
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
      if (!mounted) {
        return;
      }
      setState(() {
        results = found;
        searched = true;
      });
    } catch (err) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: query,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: const InputDecoration(
            hintText: 'Search chats, groups, communities…',
            border: InputBorder.none,
            filled: false,
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
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        child: Icon(
                          _iconForType(result.type),
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      title: Text(result.label),
                      subtitle: Text(_labelForType(result.type)),
                      onTap: result.type == 'conversation'
                          ? () {
                              widget.state.selectConversation(result.id);
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ChatScreen(state: widget.state),
                                ),
                              );
                            }
                          : null,
                    );
                  },
                ),
    );
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
