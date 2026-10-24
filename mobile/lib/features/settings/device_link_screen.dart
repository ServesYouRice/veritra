import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import '../../l10n/l10n.dart';

/// The QR payload for a link code, built here rather than taken from the
/// server's `link_uri`, so a server cannot place anything else (such as an
/// origin) into the code another device scans.
///
/// Neither Android nor iOS registers the `veritra:` scheme, so the URI is
/// only meaningful to the app's own scanner (`parseDeviceLinkCode`). It is
/// never shown or offered for copying as a link that could be opened.
String? deviceLinkQrPayload(String? code) {
  final trimmed = code?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  return Uri(
    scheme: 'veritra',
    host: 'device-link',
    queryParameters: <String, String>{'code': trimmed},
  ).toString();
}

/// Digits in the safety code the new device shows.
const deviceLinkCodeLength = 8;

class DeviceLinkScreen extends StatelessWidget {
  const DeviceLinkScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final link = state.activeDeviceLink;
        final qrPayload = deviceLinkQrPayload(link?.code);
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.deviceLinkTitle),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              Text(
                l10n.deviceLinkIntro,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: state.busy ? null : state.createDeviceLink,
                icon: const Icon(Icons.qr_code_2),
                label: Text(
                  link == null
                      ? l10n.deviceLinkCreate
                      : l10n.deviceLinkCreateNew,
                ),
              ),
              if (link != null) ...<Widget>[
                if (qrPayload != null && link.state == 'pending') ...<Widget>[
                  const SizedBox(height: BoneSpacing.lg),
                  TileGroup(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(BoneSpacing.lg),
                        child: Column(
                          children: <Widget>[
                            Semantics(
                              label: l10n.deviceLinkQrSemantics,
                              child: Container(
                                // QR codes need a light, uniform quiet zone
                                // to scan reliably, independent of app theme.
                                padding: const EdgeInsets.all(BoneSpacing.md),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(
                                    BoneRadii.md,
                                  ),
                                ),
                                child: QrImageView(
                                  key: ValueKey<String>(qrPayload),
                                  data: qrPayload,
                                  version: QrVersions.auto,
                                  size: 220,
                                ),
                              ),
                            ),
                            const SizedBox(height: BoneSpacing.md),
                            Text(
                              l10n.deviceLinkQrHint,
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
                        l10n.deviceLinkStatusLabel,
                        style: theme.textTheme.labelSmall,
                      ),
                      trailing: StatusPill(
                        label: l10n.deviceLinkState(link.state),
                        tone: switch (link.state) {
                          'approved' => StatusTone.verified,
                          'claimed' => StatusTone.info,
                          _ => StatusTone.neutral,
                        },
                      ),
                    ),
                    _LinkValueTile(
                      icon: Icons.pin_outlined,
                      title: l10n.connectLinkCode,
                      value: link.code ?? '',
                      copyable: true,
                    ),
                    _LinkValueTile(
                      icon: Icons.timer_outlined,
                      title: l10n.inviteExpires,
                      value: formatDateTime(context, link.expiresAt),
                      mono: false,
                    ),
                    if (link.claimedDeviceName != null)
                      _LinkValueTile(
                        icon: Icons.tablet_android_outlined,
                        title: l10n.deviceLinkClaimedBy,
                        value: link.claimedDeviceName!,
                        mono: false,
                      ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.lg),
                OutlinedButton.icon(
                  onPressed: state.busy ? null : state.refreshActiveDeviceLink,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.deviceLinkRefreshStatus),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: state.busy ? null : () => _approve(context),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(l10n.deviceLinkApproveDevice),
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
            title: Text(context.l10n.connectVerificationTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: deviceLinkCodeLength,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: InputDecoration(
                hintText: '0' * deviceLinkCodeLength,
                helperText: context.l10n.deviceLinkApproveHint,
                helperMaxLines: 3,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: Text(context.l10n.deviceLinkApprove),
              ),
            ],
          );
        },
      );
      final trimmed = code?.trim();
      if (trimmed == null || trimmed.length != deviceLinkCodeLength) {
        return;
      }
      await state.approveActiveDeviceLink(trimmed);
    } finally {
      controller.dispose();
    }
  }
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
              tooltip: context.l10n.commonCopy,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(
                  SnackBar(content: Text(context.l10n.settingsCopied(title))),
                );
              },
            )
          : null,
    );
  }
}
