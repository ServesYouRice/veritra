import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = state.session;
    final currentDevice = state.devices
        .where((device) => device.id == session?.deviceId)
        .firstOrNull;
    final accountId = session?.accountId;
    final host = session == null
        ? 'this instance'
        : (Uri.tryParse(session.baseUrl)?.host ?? session.baseUrl);
    final colors = avatarColorsFor(context, accountId ?? 'unknown');
    return Scaffold(
      appBar: const LargeTitleBar(title: 'Profile'),
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
                        ? 'Your account'
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
          const SectionHeader('Identity'),
          TileGroup(
            children: <Widget>[
              _IdentityRow(
                icon: Icons.alternate_email,
                label: 'Username',
                value: session?.username == null
                    ? 'Not available'
                    : '@${session!.username}',
              ),
              _IdentityRow(
                icon: Icons.badge_outlined,
                label: 'Account ID',
                value: accountId == null ? 'Not available' : shortId(accountId),
                mono: true,
                copyValue: accountId,
              ),
              _IdentityRow(
                icon: Icons.devices_outlined,
                label: 'Current device',
                value: currentDevice?.name ??
                    (session?.deviceId == null
                        ? 'Not available'
                        : shortId(session!.deviceId!)),
                copyValue: session?.deviceId,
              ),
              _IdentityRow(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Instance role',
                // Left exactly as the server reports it. Title-casing a role
                // makes it look like a display name rather than the literal
                // value, and `profile_screen_test.dart` pins the lowercase.
                value: session?.role ?? 'member',
              ),
            ],
          ),
          const SectionHeader('Encryption'),
          TileGroup(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.lock_clock_outlined),
                title: const Text('Encryption identity pending'),
                subtitle: Text(
                  'Safety-number verification and profile editing remain '
                  'unavailable until the reviewed encryption engine ships.',
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
              tooltip: 'Copy $label',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyValue!));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$label copied.')),
                  );
                }
              },
              icon: const Icon(Icons.copy_outlined),
            ),
    );
  }
}
