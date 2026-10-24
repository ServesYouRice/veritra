import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';
import '../../l10n/l10n.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({required this.state, super.key});

  final AppState state;

  /// A pushed route: it listens to the state itself, since the app root no
  /// longer rebuilds every route on each notification (T49C-1).
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final session = state.session;
    final currentDevice = state.devices
        .where((device) => device.id == session?.deviceId)
        .firstOrNull;
    final accountId = session?.accountId;
    final host = session == null
        ? l10n.profileThisInstance
        : (Uri.tryParse(session.baseUrl)?.host ?? session.baseUrl);
    final colors = avatarColorsFor(context, accountId ?? 'unknown');
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.profileTitle),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.gutter,
          BoneSpacing.sm,
          BoneSpacing.gutter,
          BoneSpacing.xl,
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: BoneSpacing.md),
            child: Column(
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.fill,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.ring),
                    ),
                    child: Text(
                      accountInitials(accountId ?? '', session?.username),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: colors.glyph,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: BoneSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    session?.username == null
                        ? l10n.profileYourAccount
                        : '@${session!.username}',
                    style: theme.textTheme.displaySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: BoneSpacing.xs),
                Text(
                  host,
                  style: BoneType.mono.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          SectionHeader(l10n.profileSectionIdentity),
          TileGroup(
            children: <Widget>[
              _IdentityRow(
                icon: Icons.alternate_email,
                label: l10n.connectUsername,
                value: session?.username == null
                    ? l10n.profileNotAvailable
                    : '@${session!.username}',
              ),
              _IdentityRow(
                icon: Icons.badge_outlined,
                label: l10n.settingsAccountId,
                value: accountId == null
                    ? l10n.profileNotAvailable
                    : shortId(accountId),
                mono: true,
                copyValue: accountId,
              ),
              _IdentityRow(
                icon: Icons.devices_outlined,
                label: l10n.profileCurrentDevice,
                value: currentDevice?.name ??
                    (session?.deviceId == null
                        ? l10n.profileNotAvailable
                        : shortId(session!.deviceId!)),
                copyValue: session?.deviceId,
              ),
              _IdentityRow(
                icon: Icons.admin_panel_settings_outlined,
                label: l10n.profileInstanceRole,
                // Left exactly as the server reports it. Title-casing a role
                // makes it look like a display name rather than the literal
                // value, and `profile_screen_test.dart` pins the lowercase.
                value: session?.role ?? 'member',
              ),
            ],
          ),
          SectionHeader(l10n.profileSectionEncryption),
          TileGroup(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.lock_clock_outlined),
                title: Text(l10n.profileEncryptionPending),
                subtitle: Text(
                  l10n.profileEncryptionPendingDetail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One identity fact: a `micro` label above the value it names, which is the
/// same shape as the connect screen's fields (`docs/design.md` §5–6).
///
/// The label doubles as the copy button's tooltip, so it stays in its natural
/// casing — `Copy Account ID`, not `Copy ACCOUNT ID`.
class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    required this.icon,
    required this.label,
    required this.value,
    this.copyValue,
    this.mono = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? copyValue;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = mono
        ? BoneType.mono.copyWith(color: theme.colorScheme.onSurface)
        : theme.textTheme.bodyMedium;
    return ListTile(
      leading: ExcludeSemantics(child: Icon(icon)),
      title: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall,
      ),
      subtitle: Text(value, style: valueStyle),
      trailing: copyValue == null
          ? null
          : IconButton(
              tooltip: context.l10n.profileCopyLabel(label),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyValue!));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.settingsCopied(label))),
                  );
                }
              },
              icon: const Icon(Icons.copy_outlined),
            ),
    );
  }
}
