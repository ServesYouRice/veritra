import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/text_prompt_dialog.dart';
import '../../ui/widgets/tile_group.dart';

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
          appBar: const LargeTitleBar(title: 'Link a device'),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
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
                  const SizedBox(height: BoneSpacing.lg),
                  TileGroup(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(BoneSpacing.lg),
                        child: Column(
                          children: <Widget>[
                            Semantics(
                              label: 'QR code containing the device link. '
                                  'Scan it with the new device.',
                              child: Container(
                                // QR codes need a light, uniform quiet zone
                                // to scan reliably, independent of app theme.
                                padding: const EdgeInsets.all(BoneSpacing.md),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius:
                                      BorderRadius.circular(BoneRadii.md),
                                ),
                                child: QrImageView(
                                  data: link.linkUri!,
                                  version: QrVersions.auto,
                                  size: 220,
                                ),
                              ),
                            ),
                            const SizedBox(height: BoneSpacing.md),
                            Text(
                              'Scan with the new device, or type the link '
                              'code below.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: BoneSpacing.lg),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(
                        'STATUS',
                        style: theme.textTheme.labelSmall,
                      ),
                      trailing: StatusPill(
                        label: link.state,
                        tone: switch (link.state) {
                          'approved' => StatusTone.verified,
                          'claimed' => StatusTone.info,
                          _ => StatusTone.neutral,
                        },
                      ),
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
                      value: formatDateTime(context, link.expiresAt),
                      mono: false,
                    ),
                    if (link.claimedDeviceName != null)
                      _LinkValueTile(
                        icon: Icons.tablet_android_outlined,
                        title: 'Claimed by',
                        value: link.claimedDeviceName!,
                        mono: false,
                      ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.lg),
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
    final code = await showTextPromptDialog(
      context,
      title: 'Verification code',
      label: 'Code shown on the new device',
      confirmLabel: 'Approve',
      keyboardType: TextInputType.number,
      style: BoneType.mono,
      validator: validateVerificationCode,
    );
    if (code == null || code.isEmpty) {
      return;
    }
    await state.approveActiveDeviceLink(code);
  }
}

/// Inline check for the device-link verification code: digits only. The
/// match itself is checked against the link, not here.
String? validateVerificationCode(String value) {
  if (value.isEmpty) return 'Enter the code shown on the new device.';
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
    return 'The code is digits only.';
  }
  return null;
}

/// One link fact: a `micro` label over the value. Codes and URIs render in
/// `mono`, which is the ramp step that exists for identifiers.
class _LinkValueTile extends StatelessWidget {
  const _LinkValueTile({
    required this.icon,
    required this.title,
    required this.value,
    this.copyable = false,
    this.mono = true,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool copyable;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title.toUpperCase(), style: theme.textTheme.labelSmall),
      subtitle: SelectableText(
        value,
        style: mono
            ? BoneType.mono.copyWith(color: theme.colorScheme.onSurface)
            : theme.textTheme.bodyMedium,
      ),
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
