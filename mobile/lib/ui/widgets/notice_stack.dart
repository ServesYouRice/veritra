import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../tokens.dart';
import 'account_recovery_banner.dart';
import 'connection_banner.dart';
import 'history_copy_banner.dart';
import 'listenable_selector.dart';
import 'recovery_key_prompt_banner.dart';

/// The notices the stack can fold, most urgent first.
enum ShellNotice {
  passwordLeak,
  connection,
  passkey,
  historyCopy,
  recoveryKeyPrompt;

  bool isActive(AppState state) => switch (this) {
        passwordLeak => PasswordLeakBanner.active(state),
        connection => ConnectionBanner.active(state),
        passkey => PasskeyNoticeBanner.active(state),
        historyCopy => HistoryCopyBanner.active(state),
        recoveryKeyPrompt => RecoveryKeyPromptBanner.active(state),
      };

  Widget build(AppState state) => switch (this) {
        passwordLeak => PasswordLeakBanner(state: state),
        connection => ConnectionBanner(state: state),
        passkey => PasskeyNoticeBanner(state: state),
        historyCopy => HistoryCopyBanner(state: state),
        recoveryKeyPrompt => RecoveryKeyPromptBanner(state: state),
      };

  /// The notices about the account itself, which an open chat repeats (U37).
  static const List<ShellNotice> account = <ShellNotice>[passwordLeak, passkey];
}

/// Everything the app wants to say at the top of the screen (U17).
///
/// An account-recovery attempt is always its own card above the rest and is
/// never folded: it may be an attack. Every other notice that is showing
/// folds into one, the most urgent, with a "2 more" button that opens the
/// rest and a "Show fewer" button that closes them again.
class NoticeStack extends StatefulWidget {
  const NoticeStack({
    required this.state,
    this.notices = ShellNotice.values,
    super.key,
  });

  final AppState state;

  /// The notices this stack may show, most urgent first.
  final List<ShellNotice> notices;

  @override
  State<NoticeStack> createState() => _NoticeStackState();
}

class _NoticeStackState extends State<NoticeStack> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notices = widget.notices;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        RecoveryAttemptCard(state: state),
        // Rebuilds only when the set of notices showing changes (T49C-1);
        // each notice watches its own details.
        ListenableSelector<List<ShellNotice>>(
          listenable: state,
          select: () => <ShellNotice>[
            for (final notice in notices)
              if (notice.isActive(state)) notice,
          ],
          equals: _sameNotices,
          builder: (context, active, _) => _folded(context, active),
        ),
      ],
    );
  }

  Widget _folded(BuildContext context, List<ShellNotice> active) {
    if (active.isEmpty) return const SizedBox.shrink();
    final expanded = _expanded && active.length > 1;
    final shown = expanded ? active : active.take(1).toList();
    final hidden = active.length - 1;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final notice in shown)
          KeyedSubtree(
            key: ValueKey<ShellNotice>(notice),
            child: notice.build(widget.state),
          ),
        if (hidden > 0)
          Material(
            color: scheme.surfaceContainerHigh,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.sm),
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey<String>('notice-stack-toggle'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(
                      BoneSpacing.minTapTarget, BoneSpacing.minTapTarget),
                ),
                onPressed: () => setState(() => _expanded = !expanded),
                child: Text(
                  expanded ? l10n.noticesShowFewer : l10n.noticesMore(hidden),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

bool _sameNotices(List<ShellNotice> a, List<ShellNotice> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
