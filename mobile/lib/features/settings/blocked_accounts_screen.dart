import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';

/// Review and undo blocks. Blocking is enforced by the server for delivery;
/// it is not a claim about the other person's device, and the copy here says
/// so rather than implying messages are deleted for them.
class BlockedAccountsScreen extends StatefulWidget {
  const BlockedAccountsScreen({required this.state, super.key});

  final AppState state;

  @override
  State<BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<BlockedAccountsScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred: refreshBlocks notifies listeners synchronously, which would
    // rebuild ancestors mid-build if started directly from initState.
    scheduleMicrotask(() {
      if (mounted) {
        widget.state.refreshBlocks();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final blocks = state.blockedAccounts;
        final error = state.errorFor(Ops.blocks);
        return Scaffold(
          appBar: const LargeTitleBar(title: 'Blocked accounts'),
          body: RefreshIndicator(
            onRefresh: state.refreshBlocks,
            child: blocks.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      const SizedBox(height: 120),
                      if (!state.blocksLoaded && state.isBusy(Ops.blocks))
                        const Center(child: CircularProgressIndicator())
                      else if (error != null)
                        _ErrorState(
                          message: error,
                          onRetry: state.refreshBlocks,
                        )
                      else
                        const EmptyState(
                          icon: Icons.block_outlined,
                          title: 'No blocked accounts',
                          message: 'Block someone from a direct message to '
                              'stop the server delivering their messages to '
                              'you.',
                        ),
                    ],
                  )
                // Dividers dropped for the same reason as the chat list:
                // rows separate by spacing, not by a rule between them.
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: BoneSpacing.sm,
                      vertical: BoneSpacing.sm,
                    ),
                    itemCount: blocks.length,
                    itemBuilder: (context, index) {
                      final block = blocks[index];
                      final label =
                          accountLabel(block.accountId, block.username);
                      final colors = avatarColorsFor(context, block.accountId);
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
                                Icons.person_off_outlined,
                                size: 18,
                                color: colors.glyph,
                              ),
                            ),
                          ),
                          title: Text(label),
                          subtitle: Text(block.createdAt == null
                              ? 'Blocked'
                              : 'Blocked '
                                  '${formatDate(context, block.createdAt!)}'),
                          trailing: TextButton(
                            onPressed: state.isBusy(Ops.blocks)
                                ? null
                                : () => _unblock(
                                      context,
                                      block.accountId,
                                      label,
                                    ),
                            child: const Text('Unblock'),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Future<void> _unblock(
    BuildContext context,
    String accountId,
    String label,
  ) async {
    final ok = await widget.state.unblockAccount(accountId);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '$label unblocked.'
            : widget.state.errorFor(Ops.blocks) ?? 'Could not unblock $label.'),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Couldn’t load blocked accounts',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
