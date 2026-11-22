import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../ui/about.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/veritra_mark.dart';

/// U20: the first screen of a signed-out app. Two choices, and the big logo,
/// which shows here and nowhere else in the flow (`docs/design.md` §5).
class WelcomeChoices extends StatelessWidget {
  const WelcomeChoices({
    required this.onInvite,
    required this.onAccount,
    required this.onSetUpServer,
    super.key,
  });

  final VoidCallback onInvite;
  final VoidCallback onAccount;
  final VoidCallback onSetUpServer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const WelcomeBrandHeader(),
        const SizedBox(height: BoneSpacing.xl * 2),
        FilledButton.icon(
          key: const ValueKey<String>('welcome-invite'),
          onPressed: onInvite,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.lg,
              vertical: 14,
            ),
          ),
          icon: const Icon(Icons.card_giftcard_outlined),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(l10n.welcomeHaveInvite, maxLines: 1),
          ),
        ),
        const SizedBox(height: BoneSpacing.md),
        OutlinedButton.icon(
          key: const ValueKey<String>('welcome-account'),
          onPressed: onAccount,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.lg,
              vertical: 14,
            ),
          ),
          icon: const Icon(Icons.login),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(l10n.welcomeHaveAccount, maxLines: 1),
          ),
        ),
        const SizedBox(height: BoneSpacing.lg),
        Center(
          child: TextButton(
            key: const ValueKey<String>('welcome-set-up-server'),
            onPressed: onSetUpServer,
            child: Text(l10n.welcomeSetUpServer),
          ),
        ),
      ],
    );
  }
}

/// U20: the second screen, after "I already have an account". Three answers,
/// each a whole tappable row. [onLostDevices] is null where this build cannot
/// recover an account (no native engine), and the row is then left out.
class AccountChoices extends StatelessWidget {
  const AccountChoices({
    required this.onNewDevice,
    required this.onSignedInBefore,
    required this.onLostDevices,
    super.key,
  });

  final VoidCallback onNewDevice;
  final VoidCallback onSignedInBefore;
  final VoidCallback? onLostDevices;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          l10n.welcomeAccountTitle,
          padding: const EdgeInsets.only(bottom: BoneSpacing.md),
        ),
        _ChoiceTile(
          key: const ValueKey<String>('welcome-new-device'),
          icon: Icons.qr_code_2,
          title: l10n.welcomeNewDeviceTitle,
          detail: l10n.welcomeNewDeviceDetail,
          onTap: onNewDevice,
        ),
        const SizedBox(height: BoneSpacing.md),
        _ChoiceTile(
          key: const ValueKey<String>('welcome-signed-in-before'),
          icon: Icons.login,
          title: l10n.welcomeSignedInBeforeTitle,
          detail: l10n.welcomeSignedInBeforeDetail,
          onTap: onSignedInBefore,
        ),
        if (onLostDevices case final onLost?) ...<Widget>[
          const SizedBox(height: BoneSpacing.md),
          _ChoiceTile(
            key: const ValueKey<String>('connect-lost-devices'),
            icon: Icons.key_outlined,
            title: l10n.welcomeLostDevicesTitle,
            detail: l10n.welcomeLostDevicesDetail,
            onTap: onLost,
          ),
        ],
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(BoneRadii.lg);
    // One button to a screen reader, named by its title and detail.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(BoneSpacing.lg),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(icon, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: BoneSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(title, style: theme.textTheme.titleMedium),
                        const SizedBox(height: BoneSpacing.xs),
                        Text(
                          detail,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: BoneSpacing.sm),
                  ExcludeSemantics(
                    child: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brand moment. One of the few places a direction this restrained shows the
/// mark at all, so it gets the wordmark and a line of positioning rather than
/// a tinted circle with a stock shield in it. Shown on the welcome step only.
class WelcomeBrandHeader extends StatelessWidget {
  const WelcomeBrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        VeritraMark(size: 72, color: theme.colorScheme.onSurface),
        const SizedBox(height: BoneSpacing.lg),
        Text(
          veritraProductName,
          style: theme.textTheme.displayMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: BoneSpacing.xs),
        Text(
          context.l10n.connectTagline,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
