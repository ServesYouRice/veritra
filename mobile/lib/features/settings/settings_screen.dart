import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import 'blocked_accounts_screen.dart';
import 'device_link_screen.dart';
import 'invite_screen.dart';
import 'profile_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final session = state.session;
        final isAdmin = session?.role == 'owner' || session?.role == 'admin';
        return Scaffold(
          appBar: LargeTitleBar(
            title: 'Settings',
            actions: <Widget>[
              IconButton(
                tooltip: 'Refresh',
                onPressed: state.busy ? null : state.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              _IdentityHeader(
                session: session,
                onTap: session?.username == null
                    ? null
                    : () => Navigator.of(context).push(
                          sharedAxisRoute<void>(
                            (_) => ProfileScreen(state: state),
                          ),
                        ),
              ),
              const SectionHeader('Account'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Account ID'),
                    subtitle: Text(
                      session?.accountId == null
                          ? 'Unknown'
                          : shortId(session!.accountId!),
                      style: BoneType.mono.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: session?.accountId == null
                        ? null
                        : IconButton(
                            tooltip: 'Copy account ID',
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: () => _copy(
                              context,
                              session!.accountId!,
                              'Account ID',
                            ),
                          ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('Change password'),
                    subtitle: const Text('Ends sessions on your other devices'),
                    onTap: state.busy ? null : () => _changePassword(context),
                  ),
                  if (isAdmin)
                    ListTile(
                      leading: const Icon(Icons.card_giftcard_outlined),
                      title: const Text('Invites'),
                      subtitle: const Text('Create codes so others can join'),
                      onTap: () async {
                        if (await _reauthenticate(context) && context.mounted) {
                          Navigator.of(context).push(sharedAxisRoute<void>(
                            (_) => InviteScreen(state: state),
                          ));
                        }
                      },
                    ),
                ],
              ),
              const SectionHeader('Devices'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.qr_code_2),
                    title: const Text('Link a new device'),
                    subtitle: const Text(
                        'Generate a pairing code for another device'),
                    onTap: () async {
                      if (await _reauthenticate(context) && context.mounted) {
                        Navigator.of(context).push(sharedAxisRoute<void>(
                          (_) => DeviceLinkScreen(state: state),
                        ));
                      }
                    },
                  ),
                  if (state.devices.isEmpty && !state.devicesLoaded)
                    const ListTile(
                      leading: SizedBox.square(
                        dimension: 24,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                      title: Text('Loading devices…'),
                    ),
                  for (final device in state.devices)
                    _DeviceTile(
                      device: device,
                      isCurrent: device.id == session?.deviceId,
                      busy: state.busy,
                      onRevoke: () => _confirmRevoke(context, device),
                    ),
                ],
              ),
              const SectionHeader('Safety'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.block_outlined),
                    title: const Text('Blocked accounts'),
                    subtitle: Text(
                      state.blocksLoaded
                          ? (state.blockedAccounts.isEmpty
                              ? 'No one is blocked'
                              : '${state.blockedAccounts.length} blocked')
                          : 'Review and undo blocks',
                    ),
                    onTap: () => Navigator.of(context).push(
                      sharedAxisRoute<void>(
                        (_) => BlockedAccountsScreen(state: state),
                      ),
                    ),
                  ),
                ],
              ),
              const SectionHeader('Your data'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('Export account data'),
                    subtitle: const Text(
                        'Save encrypted messages and account metadata locally'),
                    onTap: state.busy ? null : () => _exportAccount(context),
                  ),
                ],
              ),
              const SectionHeader('Notifications'),
              _PushStatusRow(state: state),
              const SizedBox(height: BoneSpacing.sm),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    enabled: state.pushConfigured && !state.busy,
                    leading: const Icon(Icons.notifications_outlined),
                    title: const Text('Push provider'),
                    subtitle: Text(state.pushConfigured
                        ? 'Choose an Android UnifiedPush provider'
                        : 'Not configured by this server'),
                    onTap: state.choosePushDistributor,
                  ),
                ],
              ),
              const SectionHeader('Session'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out'),
                    onTap: state.busy ? null : state.logout,
                  ),
                  ListTile(
                    leading: const Icon(Icons.phonelink_erase_outlined),
                    title: const Text('Sign out other devices'),
                    subtitle: const Text('Ends every session except this one'),
                    onTap:
                        state.busy ? null : () => _confirmLogoutOthers(context),
                  ),
                ],
              ),
              const SectionHeader('Coming soon'),
              const TileGroup(
                children: <Widget>[
                  ListTile(
                    enabled: false,
                    leading: Icon(Icons.key_outlined),
                    title: Text('Recovery'),
                    subtitle: Text('Encrypted backup & recovery key'),
                  ),
                  ListTile(
                    enabled: false,
                    leading: Icon(Icons.video_call_outlined),
                    title: Text('Calls'),
                    subtitle: Text('1:1 audio/video'),
                  ),
                ],
              ),
              const SectionHeader('Danger zone'),
              // The one filled surface left in this direction. It is doing
              // real work — it is the only row on the screen you cannot undo.
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(BoneRadii.lg),
                  border: Border.all(color: theme.colorScheme.error),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  title: Text(
                    'Delete account',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                  subtitle: Text(
                    'Disables sign-in and revokes your devices. Some encrypted '
                    'records may remain under server retention rules.',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                  onTap:
                      state.busy ? null : () => _confirmDeleteAccount(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied.')),
    );
  }

  Future<void> _confirmRevoke(BuildContext context, Device device) async {
    final confirmed = await _confirm(
      context,
      title: 'Revoke device?',
      message: '"${device.name}" will lose access immediately.',
      confirmLabel: 'Revoke',
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.revokeDevice(device.id);
      }
    }
  }

  Future<void> _confirmLogoutOthers(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Sign out other devices?',
      message: 'Every session except this one will be ended.',
      confirmLabel: 'Sign out others',
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.logoutOtherDevices();
      }
    }
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Delete account?',
      message: 'This disables your account, ends its sessions, and revokes its '
          'devices. Encrypted messages and other records may remain according '
          'to the server retention policy.',
      confirmLabel: 'Disable account',
      destructive: true,
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.deleteAccount();
      }
    }
  }

  Future<bool> _reauthenticate(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final password = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm your password'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Current password'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (password == null || password.isEmpty) {
        return false;
      }
      final ok = await state.reauthenticate(password);
      if (!ok && context.mounted && state.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(state.error!)));
      }
      return ok;
    } finally {
      controller.dispose();
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    if (!await _reauthenticate(context) || !context.mounted) {
      return;
    }
    final password = TextEditingController();
    final confirmation = TextEditingController();
    final formKey = GlobalKey<FormState>();
    try {
      // Validation lives inside the dialog: silently closing on a mismatch
      // left the user unable to tell whether a security-sensitive change had
      // been applied.
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Change password'),
          content: Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    helperText: 'At least 12 characters.',
                  ),
                  validator: _validateNewPassword,
                  // Re-run the confirmation check when the first field
                  // changes, so an already-typed confirmation is not left
                  // showing a stale "matches" state.
                  onChanged: (_) => formKey.currentState?.validate(),
                ),
                TextFormField(
                  controller: confirmation,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Confirm new password'),
                  validator: (value) => (value ?? '') != password.text
                      ? 'Passwords do not match.'
                      : null,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(dialogContext).pop(true);
                  }
                },
                child: const Text('Change')),
          ],
        ),
      );
      if (accepted != true) {
        return;
      }
      await state.changePassword(password.text);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.error ??
              'Password changed. Your other devices were signed out.'),
        ),
      );
    } finally {
      password.dispose();
      confirmation.dispose();
    }
  }

  Future<void> _exportAccount(BuildContext context) async {
    if (!await _reauthenticate(context) || !context.mounted) {
      return;
    }
    final path = await state.exportAccount();
    if (!context.mounted) {
      return;
    }
    final message = path == null
        ? (state.error ?? 'Account export failed.')
        : 'Account export saved locally.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ));
  }

  /// Length is checked in UTF-8 bytes to match the server's bcrypt limit, but
  /// the message stays in user language.
  static String? _validateNewPassword(String? value) {
    final raw = value ?? '';
    if (raw.isEmpty) {
      return 'Enter a new password.';
    }
    final bytes = utf8.encode(raw).length;
    if (bytes < 12) {
      return 'Use at least 12 characters.';
    }
    if (bytes > 72) {
      return 'That password is too long. Use a shorter one.';
    }
    return null;
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final theme = Theme.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// Identity at the top of settings: who you are and which instance you are on
/// (`docs/design.md` §6). The host matters on a self-hosted product — it
/// is the one piece of context that tells you which server this session is
/// actually talking to.
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.session, this.onTap});

  final Session? session;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final username = session?.username;
    final accountId = session?.accountId;
    final host = session == null
        ? null
        : (Uri.tryParse(session!.baseUrl)?.host ?? session!.baseUrl);
    final colors = avatarColorsFor(context, accountId ?? 'unknown');
    return Padding(
      padding: const EdgeInsets.only(bottom: BoneSpacing.sm),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(BoneRadii.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(BoneRadii.lg),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.sm,
              vertical: BoneSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.fill,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.ring),
                    ),
                    child: Text(
                      accountInitials(accountId ?? '', username),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: colors.glyph,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: BoneSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        username == null ? 'Signed in' : '@$username',
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (host != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          host,
                          style: BoneType.mono.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (session?.role != null) ...<Widget>[
                  const SizedBox(width: BoneSpacing.sm),
                  StatusPill(label: session!.role!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// States plainly whether this device will actually receive notifications.
/// Silence about a missing distributor or an unsupported platform reads as
/// "push works", which is the one thing it must never imply.
///
/// The state palette earns its keep here: warning amber and verified green
/// say which of the two this is before the sentence is read.
class _PushStatusRow extends StatelessWidget {
  const _PushStatusRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iOS = defaultTargetPlatform == TargetPlatform.iOS;
    final String title;
    final String detail;
    final IconData icon;
    var warn = true;
    if (iOS) {
      title = 'Push is not available on iOS yet';
      detail = 'Messages arrive while the app is open. Apple push delivery '
          'is still being integrated.';
      icon = Icons.notifications_off_outlined;
    } else if (!state.pushConfigured) {
      title = 'This server has no push provider';
      detail = 'The operator has not configured push keys. Messages arrive '
          'while the app is open.';
      icon = Icons.cloud_off_outlined;
    } else if (!state.pushRegistered) {
      title = 'No push distributor registered';
      detail = 'Install a UnifiedPush distributor and pick it below, or '
          'messages will only arrive while the app is open.';
      icon = Icons.warning_amber_outlined;
    } else {
      title = 'Push notifications are active';
      detail = 'Notifications never contain message text or sender names.';
      icon = Icons.notifications_active_outlined;
      warn = false;
    }
    final scheme = theme.colorScheme;
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    final tint = warn ? states.warning : states.verified;
    return TileGroup(
      children: <Widget>[
        ListTile(
          leading: Icon(icon, color: tint),
          title: Text(title),
          subtitle: Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.isCurrent,
    required this.busy,
    required this.onRevoke,
  });

  final Device device;
  final bool isCurrent;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revoked = device.revokedAt != null;
    // State moved out of the joined string and onto a pill: "Revoked" is the
    // fact that changes what the row means, and it was previously the second
    // clause of a ' · '-joined sentence.
    final details = <String>[
      if (device.lastSeenAt != null)
        'Last seen ${formatDateTime(context, device.lastSeenAt!)}',
      'Added ${formatDate(context, device.createdAt)}',
    ];
    return ListTile(
      leading: Icon(
        isCurrent ? Icons.phone_android : Icons.devices_other,
        color: revoked ? theme.disabledColor : null,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: revoked
                  ? TextStyle(
                      color: theme.disabledColor,
                      decoration: TextDecoration.lineThrough,
                    )
                  : null,
            ),
          ),
          if (revoked) ...<Widget>[
            const SizedBox(width: BoneSpacing.sm),
            const StatusPill(label: 'Revoked', tone: StatusTone.error),
          ] else if (isCurrent) ...<Widget>[
            const SizedBox(width: BoneSpacing.sm),
            const StatusPill(label: 'This device'),
          ],
        ],
      ),
      subtitle: Text(
        details.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: revoked
          ? null
          : IconButton(
              tooltip: 'Revoke',
              onPressed: busy ? null : onRevoke,
              icon: const Icon(Icons.block),
            ),
    );
  }
}
