import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Refresh',
                onPressed: state.busy ? null : state.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _SectionHeader(title: 'Account', theme: theme),
              Card(
                child: Column(
                  children: <Widget>[
                    if (session?.username != null) ...<Widget>[
                      ListTile(
                        leading: const Icon(Icons.account_circle_outlined),
                        title: Text('@${session!.username!}'),
                        subtitle:
                            const Text('View account and device identity'),
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ProfileScreen(state: state),
                          ),
                        ),
                      ),
                      const Divider(),
                    ],
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Account ID'),
                      subtitle: Text(
                        session?.accountId == null
                            ? 'Unknown'
                            : shortId(session!.accountId!),
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
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.password_outlined),
                      title: const Text('Change password'),
                      subtitle:
                          const Text('Ends sessions on your other devices'),
                      onTap: state.busy ? null : () => _changePassword(context),
                    ),
                    if (session?.role == 'owner' ||
                        session?.role == 'admin') ...<Widget>[
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.card_giftcard_outlined),
                        title: const Text('Invites'),
                        subtitle: const Text('Create codes so others can join'),
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: () async {
                          if (await _reauthenticate(context) &&
                              context.mounted) {
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => InviteScreen(state: state),
                            ));
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Devices', theme: theme),
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.qr_code_2),
                      title: const Text('Link a new device'),
                      subtitle: const Text(
                          'Generate a pairing code for another device'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () async {
                        if (await _reauthenticate(context) && context.mounted) {
                          Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => DeviceLinkScreen(state: state),
                          ));
                        }
                      },
                    ),
                    if (state.devices.isEmpty && !state.devicesLoaded) ...[
                      const Divider(),
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
                    ],
                    if (state.devices.isNotEmpty) const Divider(),
                    for (final device in state.devices)
                      _DeviceTile(
                        device: device,
                        isCurrent: device.id == session?.deviceId,
                        busy: state.busy,
                        onRevoke: () => _confirmRevoke(context, device),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Safety', theme: theme),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('Blocked accounts'),
                  subtitle: Text(
                    state.blocksLoaded
                        ? (state.blockedAccounts.isEmpty
                            ? 'No one is blocked'
                            : '${state.blockedAccounts.length} blocked')
                        : 'Review and undo blocks',
                  ),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BlockedAccountsScreen(state: state),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Notifications', theme: theme),
              _PushStatusCard(state: state),
              Card(
                child: ListTile(
                  enabled: state.pushConfigured && !state.busy,
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Push provider'),
                  subtitle: Text(state.pushConfigured
                      ? 'Choose an Android UnifiedPush provider'
                      : 'Not configured by this server'),
                  trailing: const Icon(Icons.chevron_right_outlined),
                  onTap: state.choosePushDistributor,
                ),
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Session', theme: theme),
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Sign out'),
                      onTap: state.busy ? null : state.logout,
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.phonelink_erase_outlined),
                      title: const Text('Sign out other devices'),
                      subtitle:
                          const Text('Ends every session except this one'),
                      onTap: state.busy
                          ? null
                          : () => _confirmLogoutOthers(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Coming soon', theme: theme),
              const Card(
                child: Column(
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
              ),
              const SizedBox(height: 16),
              _SectionHeader(title: 'Danger zone', theme: theme),
              Card(
                color: theme.colorScheme.errorContainer,
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
              const SizedBox(height: 24),
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

/// States plainly whether this device will actually receive notifications.
/// Silence about a missing distributor or an unsupported platform reads as
/// "push works", which is the one thing it must never imply.
class _PushStatusCard extends StatelessWidget {
  const _PushStatusCard({required this.state});

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
    return Card(
      color: warn ? scheme.surfaceContainerHighest : null,
      child: ListTile(
        leading: Icon(icon, color: warn ? scheme.onSurfaceVariant : null),
        title: Text(title),
        subtitle: Text(detail),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
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
    final details = <String>[
      if (isCurrent) 'This device',
      if (revoked) 'Revoked',
      if (device.lastSeenAt != null)
        'Last seen ${formatDateTime(context, device.lastSeenAt!)}',
      'Added ${formatDate(context, device.createdAt)}',
    ];
    return ListTile(
      leading: Icon(
        isCurrent ? Icons.phone_android : Icons.devices_other,
        color: revoked ? theme.disabledColor : null,
      ),
      title: Text(
        device.name,
        style: revoked
            ? TextStyle(
                color: theme.disabledColor,
                decoration: TextDecoration.lineThrough,
              )
            : null,
      ),
      subtitle: Text(details.join(' · ')),
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
