import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../features/settings/recovery_key_screen.dart';
import '../../l10n/l10n.dart';
import '../tokens.dart';
import 'listenable_selector.dart';

/// D49 onboarding prompt for K1: "Save a recovery key", which turns on
/// automatic backups. "Not now" hides it for three days; the settings tile
/// keeps a badge meanwhile. Draws nothing when the account has a key, the
/// server has recovery off, or the build cannot back up.
class RecoveryKeyPromptBanner extends StatelessWidget {
  const RecoveryKeyPromptBanner({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<bool>(
      listenable: state,
      select: () => state.k1ShouldOfferRecoveryKey,
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return Material(
          key: const ValueKey<String>('recovery-key-prompt'),
          color: scheme.secondaryContainer,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.gutter,
              vertical: BoneSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.key_outlined,
                        size: 18, color: scheme.onSecondaryContainer),
                    const SizedBox(width: BoneSpacing.md),
                    Expanded(
                      child: Text(
                        l10n.autoBackupPromptMessage,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: BoneSpacing.sm,
                  children: <Widget>[
                    TextButton(
                      key: const ValueKey<String>('recovery-key-prompt-save'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RecoveryKeyScreen(state: state),
                        ),
                      ),
                      child: Text(l10n.autoBackupPromptSave),
                    ),
                    TextButton(
                      key: const ValueKey<String>('recovery-key-prompt-later'),
                      onPressed: state.snoozeRecoveryKeyPrompt,
                      child: Text(l10n.autoBackupPromptLater),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
