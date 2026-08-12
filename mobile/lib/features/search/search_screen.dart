import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/avatar.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/status_pill.dart';
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
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: BoneSpacing.sm,
        // The field sits in the same pill the composer uses, so the two
        // typing surfaces in the app are the same object.
        title: ListenableBuilder(
          listenable: query,
          builder: (context, _) => Container(
            padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(BoneRadii.pill),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: TextField(
              controller: query,
              autofocus: true,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                // The server searches accounts, communities, and channels
                // only. Promising chats and groups made search look broken.
                hintText: 'Search people, communities, channels…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                prefixIcon: const Icon(Icons.search, size: 20),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
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
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BoneSpacing.sm,
                    vertical: BoneSpacing.sm,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index];
                    final action = _actionFor(result);
                    final reason = _inertReason(result);
                    final colors = avatarColorsFor(context, result.id);
                    return MergeSemantics(
                      child: ListTile(
                        leading: ExcludeSemantics(
                          child: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: colors.fill,
                              shape: BoxShape.circle,
                              border: Border.all(color: colors.ring),
                            ),
                            child: Icon(
                              _iconForType(result.type),
                              size: 18,
                              color: colors.glyph,
                            ),
                          ),
                        ),
                        title: Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                result.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: BoneSpacing.sm),
                            StatusPill(label: _labelForType(result.type)),
                          ],
                        ),
                        // Explains inert rows instead of leaving a dead tap
                        // target unexplained; silent when the row works.
                        subtitle: reason == null
                            ? null
                            : Text(
                                reason,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
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
                      ),
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
    Navigator.of(context).push(sharedAxisRoute<void>(
      (_) => ChatScreen(
        state: widget.state,
        conversationId: conversationId,
      ),
    ));
  }

  /// Why a row cannot be opened, or null when it can.
  ///
  /// The result's kind used to be the first clause of this string; it is a
  /// pill on the title row now, which leaves this saying only the thing the
  /// user could not otherwise work out.
  String? _inertReason(MetadataSearchResult result) {
    if (_actionFor(result) != null) {
      return null;
    }
    switch (result.type) {
      case 'community':
        return 'No channel you can open yet';
      case 'channel':
        return 'Join the community to open it';
      default:
        return null;
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
