import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../storage/message_search.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/status_pill.dart';
import '../chat/chat_list_screen.dart'
    show conversationAvatar, conversationTitle;
import '../chat/chat_screen.dart';
import '../../l10n/l10n.dart';

/// Two searches, kept apart so a message search can never reach the server.
///
/// Messages (the default) searches the text this device holds, in the
/// encrypted local database (W10): the query is never sent anywhere.
///
/// People and communities is the metadata search over what the server
/// actually indexes: accounts by exact username, plus communities and
/// channels by name. Message contents are ciphertext on the server and cannot
/// be searched there by design, and account lookup stays exact-match so the
/// user directory cannot be enumerated. Only this mode sends the query.
class SearchScreen extends StatefulWidget {
  const SearchScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

enum _SearchMode { messages, people }

class _SearchScreenState extends State<SearchScreen> {
  /// The account whose conversation is being started, if any.
  String? _startingAccountId;

  final query = TextEditingController();
  Timer? _debounce;
  _SearchMode mode = _SearchMode.messages;
  List<MessageSearchHit> messageHits = <MessageSearchHit>[];
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
    _debounce = Timer(
      Duration(milliseconds: mode == _SearchMode.messages ? 150 : 350),
      () => _search(value),
    );
  }

  void _setMode(_SearchMode next) {
    if (next == mode) return;
    _generation++;
    _debounce?.cancel();
    setState(() {
      mode = next;
      searching = false;
      searched = false;
      results = <MetadataSearchResult>[];
      messageHits = <MessageSearchHit>[];
    });
    // What was typed for one search is never carried into the other: words
    // typed to find a message must not be sent as a server query. Leaving
    // Messages for People clears the field; the user types a new query.
    query.clear();
  }

  void _clear() {
    _generation++;
    _debounce?.cancel();
    query.clear();
    setState(() {
      results = <MetadataSearchResult>[];
      messageHits = <MessageSearchHit>[];
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
        messageHits = <MessageSearchHit>[];
        searched = false;
      });
      return;
    }
    if (mode == _SearchMode.messages) {
      try {
        final hits = await widget.state.searchMessages(trimmed);
        if (!mounted || generation != _generation) return;
        setState(() {
          messageHits = hits;
          searched = true;
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.searchMessagesFailed)),
        );
      }
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
    // A pushed route: the results' actions and block state follow the app
    // state, which the root no longer rebuilds routes for (T49C-1).
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
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
                // only; messages are searched here. Each hint says which.
                hintText: mode == _SearchMode.messages
                    ? context.l10n.searchMessagesHint
                    : context.l10n.searchHint,
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
                        tooltip: context.l10n.searchClear,
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
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xs,
            ),
            child: SegmentedButton<_SearchMode>(
              showSelectedIcon: false,
              segments: <ButtonSegment<_SearchMode>>[
                ButtonSegment<_SearchMode>(
                  value: _SearchMode.messages,
                  label: Text(context.l10n.searchModeMessages),
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                ButtonSegment<_SearchMode>(
                  value: _SearchMode.people,
                  label: Text(context.l10n.searchModePeople),
                  icon: const Icon(Icons.groups_outlined),
                ),
              ],
              selected: <_SearchMode>{mode},
              onSelectionChanged: (selection) => _setMode(selection.single),
            ),
          ),
          Expanded(
            child: mode == _SearchMode.messages
                ? _messageResults(context)
                : _peopleResults(context),
          ),
        ],
      ),
    );
  }

  Widget _messageResults(BuildContext context) {
    final theme = Theme.of(context);
    if (!searched) {
      return EmptyState(
        icon: Icons.search,
        title: context.l10n.searchMessagesIntroTitle,
        message: context.l10n.searchMessagesIntroMessage,
      );
    }
    if (messageHits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: context.l10n.searchMessagesNoResultsTitle,
        message: context.l10n.searchMessagesNoResultsMessage,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: BoneSpacing.sm,
        vertical: BoneSpacing.sm,
      ),
      itemCount: messageHits.length,
      itemBuilder: (context, index) {
        final hit = messageHits[index];
        final conversation = widget.state.conversations
            .where((item) => item.id == hit.conversationId)
            .firstOrNull;
        final title = conversation == null
            ? context.l10n.searchTypeConversation
            : conversationTitle(context.l10n, conversation);
        return MergeSemantics(
          child: ListTile(
            leading: conversation == null
                ? const Icon(Icons.chat_bubble_outline)
                : conversationAvatar(context, conversation, radius: 20),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text.rich(
              _snippetSpan(hit.snippet, theme.textTheme.bodyMedium),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              formatDateTime(
                context,
                DateTime.fromMillisecondsSinceEpoch(hit.createdAt, isUtc: true)
                    .toLocal(),
              ),
              style: theme.textTheme.bodySmall,
            ),
            onTap: () => _openMessage(hit),
          ),
        );
      },
    );
  }

  /// The snippet with each match in bold.
  static TextSpan _snippetSpan(String snippet, TextStyle? style) {
    final spans = <InlineSpan>[];
    var marked = false;
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(
        text: buffer.toString(),
        style: marked ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ));
      buffer.clear();
    }

    for (final unit in snippet.runes) {
      final char = String.fromCharCode(unit);
      if (char == snippetMatchStart || char == snippetMatchEnd) {
        flush();
        marked = char == snippetMatchStart;
      } else {
        buffer.write(char);
      }
    }
    flush();
    return TextSpan(style: style, children: spans);
  }

  void _openMessage(MessageSearchHit hit) {
    widget.state.selectAndPrepare(hit.conversationId);
    Navigator.of(context).push(sharedAxisRoute<void>(
      (_) => ChatScreen(
        state: widget.state,
        conversationId: hit.conversationId,
        initialMessageKey: hit.key,
      ),
    ));
  }

  Widget _peopleResults(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return !searched
        ? EmptyState(
            icon: Icons.search,
            title: context.l10n.searchIntroTitle,
            message: context.l10n.searchIntroMessage,
          )
        : results.isEmpty
            ? EmptyState(
                icon: Icons.search_off,
                title: context.l10n.searchNoResultsTitle,
                message: context.l10n.searchNoResultsMessage,
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
                  // While a conversation is being started, account rows wait.
                  final startingThis =
                      _startingAccountId != null && result.type == 'account';
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
                      enabled: action != null && !startingThis,
                      onTap: startingThis ? null : action,
                    ),
                  );
                },
              );
  }

  VoidCallback? _actionFor(MetadataSearchResult result) {
    if (result.type == 'account') {
      return () async {
        // One start at a time: two taps would run two startConversation
        // calls that can both miss the existing DM, and each would open a
        // chat of its own.
        if (_startingAccountId != null) return;
        setState(() => _startingAccountId = result.id);
        try {
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
        } finally {
          if (mounted) setState(() => _startingAccountId = null);
        }
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
        return context.l10n.searchNoOpenChannel;
      case 'channel':
        return context.l10n.searchJoinCommunity;
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
        return context.l10n.searchTypeConversation;
      case 'community':
        return context.l10n.searchTypeCommunity;
      case 'channel':
        return context.l10n.searchTypeChannel;
      case 'account':
        return context.l10n.searchTypeAccount;
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
    final l10n = context.l10n;
    return IconButton(
      tooltip: blocked
          ? l10n.searchUnblockAccount(label)
          : l10n.searchBlockAccount(label),
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
                      ? (blocked
                          ? l10n.blockedUnblocked(label)
                          : l10n.searchBlocked(label))
                      : state.errorFor(Ops.blocks) ?? l10n.searchBlockFailed),
                ),
              );
            },
    );
  }
}
