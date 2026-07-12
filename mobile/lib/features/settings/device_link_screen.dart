import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';

class DeviceLinkScreen extends StatelessWidget {
  const DeviceLinkScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final link = state.activeDeviceLink;
        return Scaffold(
          appBar: AppBar(title: const Text('Link a device')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text(
                'Generate a one-time code, enter it on the new device, then '
                'approve it here with the verification code the new device '
                'shows.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: state.busy ? null : state.createDeviceLink,
                icon: const Icon(Icons.qr_code_2),
                label: Text(link == null ? 'Create link' : 'Create new link'),
              ),
              if (link != null) ...<Widget>[
                if (link.linkUri != null &&
                    link.state == 'pending') ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: <Widget>[
                          Semantics(
                            label: 'QR code containing the device link. '
                                'Scan it with the new device.',
                            child: Container(
                              // QR codes need a light, uniform quiet zone to
                              // scan reliably, independent of app theme.
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: QrImageView(
                                data: link.linkUri!,
                                version: QrVersions.auto,
                                size: 220,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Scan with the new device, or type the link code '
                            'below.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      children: <Widget>[
                        ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: const Text('Status'),
                          trailing: _StateChip(state: link.state),
                        ),
                        _LinkValueTile(
                          icon: Icons.pin_outlined,
                          title: 'Link code',
                          value: link.code ?? '',
                          copyable: true,
                        ),
                        _LinkValueTile(
                          icon: Icons.verified_outlined,
                          title: 'Verification code',
                          value: link.verificationCode,
                        ),
                        if (link.linkUri != null)
                          _LinkValueTile(
                            icon: Icons.link_outlined,
                            title: 'Link URI',
                            value: link.linkUri!,
                            copyable: true,
                          ),
                        _LinkValueTile(
                          icon: Icons.timer_outlined,
                          title: 'Expires',
                          value: formatDateTime(link.expiresAt),
                        ),
                        if (link.claimedDeviceName != null)
                          _LinkValueTile(
                            icon: Icons.tablet_android_outlined,
                            title: 'Claimed by',
                            value: link.claimedDeviceName!,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: state.busy ? null : state.refreshActiveDeviceLink,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh status'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: state.busy ? null : () => _approve(context),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Approve device'),
                ),
              ],
              if (state.error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  state.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _approve(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final code = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Verification code'),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: '000000'),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Approve'),
              ),
            ],
          );
        },
      );
      final trimmed = code?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        return;
      }
      await state.approveActiveDeviceLink(trimmed);
    } finally {
      controller.dispose();
    }
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (state) {
      'approved' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'claimed' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        state,
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

class _LinkValueTile extends StatelessWidget {
  const _LinkValueTile({
    required this.icon,
    required this.title,
    required this.value,
    this.copyable = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: SelectableText(value),
      trailing: copyable && value.isNotEmpty
          ? IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$title copied.')),
                );
              },
            )
          : null,
    );
  }
}
