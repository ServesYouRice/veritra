import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final currentDevice = state.devices
        .where((device) => device.id == session?.deviceId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              session?.username == null
                  ? 'Your account'
                  : '@${session!.username}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Identity on ${session?.baseUrl ?? 'this instance'}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: <Widget>[
                _IdentityRow(
                  icon: Icons.alternate_email,
                  label: 'Username',
                  value: session?.username == null
                      ? 'Not available'
                      : '@${session!.username}',
                ),
                const Divider(height: 1),
                _IdentityRow(
                  icon: Icons.badge_outlined,
                  label: 'Account ID',
                  value: session?.accountId == null
                      ? 'Not available'
                      : shortId(session!.accountId!),
                  copyValue: session?.accountId,
                ),
                const Divider(height: 1),
                _IdentityRow(
                  icon: Icons.devices_outlined,
                  label: 'Current device',
                  value: currentDevice?.name ??
                      (session?.deviceId == null
                          ? 'Not available'
                          : shortId(session!.deviceId!)),
                  copyValue: session?.deviceId,
                ),
                const Divider(height: 1),
                _IdentityRow(
                  icon: Icons.admin_panel_settings_outlined,
                  label: 'Instance role',
                  value: session?.role ?? 'member',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Card(
            child: ListTile(
              leading: Icon(Icons.lock_clock_outlined),
              title: Text('Encryption identity pending'),
              subtitle: Text(
                'Safety-number verification and profile editing remain '
                'unavailable until the reviewed encryption engine ships.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    required this.icon,
    required this.label,
    required this.value,
    this.copyValue,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
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
