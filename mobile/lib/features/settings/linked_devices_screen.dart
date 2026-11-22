import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/reauthenticate.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/bar_action.dart';
import '../../ui/widgets/constrained_body.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import 'device_link_screen.dart';
import 'stacked_trailing_tile.dart';

/// Dedicated device-management screen reached from Settings > Devices.
/// Keeps the main Settings screen concise while giving device listing,
/// linking, and per-device revocation room to breathe.
class LinkedDevicesScreen extends StatelessWidget {
  const LinkedDevicesScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final l10n = context.l10n;
        final session = state.session;
        return Scaffold(
          appBar: LargeTitleBar(
            title: l10n.settingsLinkedDevices,
            actions: <Widget>[
              BarAction(
                label: l10n.commonRefresh,
                onPressed: state.busy ? null : state.refreshDevices,
                icon: Icons.refresh,
              ),
            ],
          ),
          body: ConstrainedBody(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                BoneSpacing.gutter,
                BoneSpacing.sm,
                BoneSpacing.gutter,
                BoneSpacing.xl,
              ),
              children: <Widget>[
                if (state.membershipChangesAvailable) ...<Widget>[
                  TileGroup(
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.qr_code_2),
                        title: Text(l10n.settingsLinkDevice),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          if (await promptReauthenticate(context, state) &&
                              context.mounted) {
                            await Navigator.of(context).push(
                              sharedAxisRoute<void>(
                                (_) => DeviceLinkScreen(state: state),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ],
                SectionHeader(l10n.settingsSectionDevices),
                TileGroup(
                  children: <Widget>[
                    if (state.devices.isEmpty && !state.devicesLoaded)
                      ListTile(
                        leading: const SizedBox.square(
                          dimension: 24,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                        title: Text(l10n.settingsLoadingDevices),
                      ),
                    for (final device in state.devices)
                      DeviceTile(
                        device: device,
                        isCurrent: device.id == session?.deviceId,
                        busy: state.busy,
                        onRevoke: () => _confirmRevoke(context, device),
                      ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.lg),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      key: const ValueKey<String>('devices-sign-out-others'),
                      leading: const Icon(Icons.phonelink_erase_outlined),
                      title: Text(l10n.settingsSignOutOthers),
                      onTap: state.busy
                          ? null
                          : () => _confirmLogoutOthers(context),
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

  Future<void> _confirmRevoke(BuildContext context, Device device) async {
    final confirmed = await confirmAction(
      context,
      title: context.l10n.settingsSignOutDeviceTitle(device.name),
      message: context.l10n.settingsRevokeDeviceMessage(device.name),
      confirmLabel: context.l10n.settingsSignOutDeviceButton,
      destructive: true,
    );
    if (confirmed && context.mounted) {
      if (await promptReauthenticate(context, state)) {
        await state.revokeDevice(device.id);
      }
    }
  }

  Future<void> _confirmLogoutOthers(BuildContext context) async {
    final confirmed = await confirmAction(
      context,
      title: context.l10n.settingsSignOutOthersTitle,
      message: context.l10n.settingsSignOutOthersMessage,
      confirmLabel: context.l10n.settingsSignOutOthersConfirm,
    );
    if (confirmed && context.mounted) {
      if (await promptReauthenticate(context, state)) {
        await state.logoutOtherDevices();
      }
    }
  }
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({
    required this.device,
    required this.isCurrent,
    required this.busy,
    required this.onRevoke,
    super.key,
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
      if (device.lastSeenAt != null)
        context.l10n.settingsDeviceLastSeen(
          formatDateTime(context, device.lastSeenAt!),
        ),
      context.l10n.settingsDeviceAdded(formatDate(context, device.createdAt)),
    ];
    final signOutLabel = context.l10n.settingsSignOutDeviceButton;
    final leading = Icon(
      isCurrent ? Icons.phone_android : Icons.devices_other,
      color: revoked ? theme.disabledColor : null,
    );
    final title = Wrap(
      spacing: BoneSpacing.sm,
      runSpacing: BoneSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
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
        if (revoked)
          StatusPill(
            label: context.l10n.settingsDeviceRevoked,
            tone: StatusTone.error,
          )
        else if (isCurrent)
          StatusPill(label: context.l10n.settingsDeviceCurrent),
      ],
    );
    final subtitle = Text(
      details.join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (revoked) {
      return ListTile(leading: leading, title: title, subtitle: subtitle);
    }
    // A labelled button, not a bare icon (U15). It drops under the text at
    // large sizes so the device name keeps its width (U2).
    return StackedTrailingTile(
      key: ValueKey<String>('device-${device.id}'),
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailingWidth: measureTextWidth(context, signOutLabel) + 32,
      trailing: TextButton(
        key: ValueKey<String>('device-sign-out-${device.id}'),
        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
        onPressed: busy ? null : onRevoke,
        child: Text(signOutLabel),
      ),
    );
  }
}
