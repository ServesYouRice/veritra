import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import 'device_link_screen.dart';
import 'invite_screen.dart';

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
                        subtitle: const Text('Signed in on this instance'),
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
                      leading: const Icon(Icons.card_giftcard_outlined),
                      title: const Text('Invites'),
                      subtitle: const Text('Create codes so others can join'),
                      trailing: const Icon(Icons.chevron_right_outlined),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => InviteScreen(state: state),
                        ),
                      ),
                    ),
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
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DeviceLinkScreen(state: state),
                        ),
                      ),
                    ),
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
                    'Permanently removes your account and data '
                    'from this server.',
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
      await state.revokeDevice(device.id);
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
      await state.logoutOtherDevices();
    }
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Delete account?',
      message: 'This permanently deletes your account, devices, and '
          'memberships on this server. This cannot be undone.',
      confirmLabel: 'Delete forever',
      destructive: true,
    );
    if (confirmed) {
      await state.deleteAccount();
    }
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
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
        'Last seen ${formatDateTime(device.lastSeenAt!)}',
      'Added ${formatDate(device.createdAt)}',
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
