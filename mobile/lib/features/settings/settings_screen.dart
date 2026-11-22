import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../push/push_service.dart';
import '../../core/models.dart';
import '../../desktop/message_notifications.dart';
import '../../desktop/update_service.dart';
import '../../ui/reauthenticate.dart';
import '../../ui/about.dart';
import '../../ui/appearance.dart';
import 'link_preview_tile.dart';
import 'read_receipts_tile.dart';
import '../../ui/avatar.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/bar_action.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import '../reports/owner_reports_screen.dart';
import '../../core/account_host.dart';
import 'accounts_screen.dart';
import 'auto_backup_screen.dart';
import 'admin_screen.dart';
import 'blocked_accounts_screen.dart';
import 'device_link_screen.dart';
import 'invite_screen.dart';
import 'passkeys_screen.dart';
import 'profile_screen.dart';
import 'recovery_key_screen.dart';
import 'sealed_key_screen.dart';
import 'stacked_trailing_tile.dart';

/// The arrow on a row that opens a page (U18).
const Widget _chevron = Icon(Icons.chevron_right);

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
        final appearance = AppearanceScope.maybeOf(context);
        final notifications = NotificationSettingsScope.maybeOf(context);
        final updates = UpdateSettingsScope.maybeOf(context);
        final l10n = context.l10n;
        return Scaffold(
          appBar: LargeTitleBar(
            title: l10n.settingsTitle,
            actions: <Widget>[
              BarAction(
                label: l10n.commonRefresh,
                onPressed: state.busy ? null : state.refreshDevices,
                icon: Icons.refresh,
              ),
            ],
          ),
          // Compact rows (48 dp) so the tab fits two screens (U18).
          body: ListTileTheme(
            data: ListTileTheme.of(
              context,
            ).copyWith(visualDensity: VisualDensity.compact),
            child: ListView(
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
                      : () =>
                          _open(context, (_) => ProfileScreen(state: state)),
                ),
                // U18: eight groups (Account, Devices, Privacy and safety,
                // Notifications, Appearance, Updates, Admin, About), then Sign
                // out on its own, last. Rows that open a page carry an arrow;
                // rows that open a dialog or act do not.
                _header(l10n.settingsSectionAccount),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.password_outlined),
                      title: Text(l10n.settingsChangePassword),
                      onTap: state.busy ? null : () => _changePassword(context),
                    ),
                    if (state.k1BackupSupported)
                      ListTile(
                        key: const ValueKey<String>('settings-auto-backup'),
                        leading: const Icon(Icons.cloud_upload_outlined),
                        title: Text(l10n.autoBackupTitle),
                        subtitle: Text(autoBackupStatusText(context, state)),
                        trailing: state.k1BackupNeedsAttention
                            ? Icon(
                                Icons.error_outline,
                                color: Theme.of(context).colorScheme.error,
                              )
                            : _chevron,
                        onTap: () => _open(
                          context,
                          (_) => AutoBackupScreen(state: state),
                        ),
                      ),
                    if (AccountHostScope.maybeOf(context) case final host?)
                      ListTile(
                        key: const ValueKey<String>('settings-accounts'),
                        leading: const Icon(Icons.switch_account_outlined),
                        title: Text(l10n.settingsAccounts),
                        trailing: _chevron,
                        onTap: () =>
                            _open(context, (_) => AccountsScreen(host: host)),
                      ),
                    if (state.passkeyClient.platformSupported)
                      ListTile(
                        key: const ValueKey<String>('settings-passkeys'),
                        leading: const Icon(Icons.fingerprint),
                        title: Text(l10n.settingsPasskeys),
                        trailing: _chevron,
                        onTap: () =>
                            _open(context, (_) => PasskeysScreen(state: state)),
                      ),
                    if (state.recoveryAvailable)
                      ListTile(
                        key: const ValueKey<String>('settings-recovery-key'),
                        leading: const Icon(Icons.key_outlined),
                        title: Text(l10n.settingsRecoveryKey),
                        subtitle: Text(_recoveryKeySubtitle(context)),
                        trailing: _chevron,
                        onTap: () => _open(
                          context,
                          (_) => RecoveryKeyScreen(state: state),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: Text(l10n.settingsExport),
                      onTap: state.busy ? null : () => _exportAccount(context),
                    ),
                    ListTile(
                      key: const ValueKey<String>('settings-delete-account'),
                      leading: Icon(
                        Icons.delete_forever_outlined,
                        color: theme.colorScheme.error,
                      ),
                      title: Text(
                        l10n.settingsDeleteAccount,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      onTap: state.busy
                          ? null
                          : () => _confirmDeleteAccount(context),
                    ),
                  ],
                ),
                _header(l10n.settingsSectionDevices),
                TileGroup(
                  children: <Widget>[
                    if (state.ownDeviceListMissing)
                      ListTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: Text(l10n.settingsDeviceListSetup),
                        subtitle: Text(l10n.settingsDeviceListSetupDetail),
                        onTap: () => _reviewDeviceList(context),
                      ),
                    if (state.recoveryListNeedsRetype)
                      ListTile(
                        leading: const Icon(Icons.key_outlined),
                        title: Text(l10n.settingsRecoveryRetype),
                        subtitle: Text(l10n.settingsRecoveryRetypeDetail),
                        onTap: () => _retypeRecoveryKey(context),
                      ),
                    if (state.recoveryKeyNeedsConfirmation)
                      ListTile(
                        leading: const Icon(Icons.key_outlined),
                        title: Text(l10n.settingsRecoveryConfirm),
                        subtitle: Text(l10n.settingsRecoveryConfirmDetail),
                        onTap: () => _confirmPreL1RecoveryKey(context),
                      ),
                    if (state.membershipChangesAvailable)
                      ListTile(
                        leading: const Icon(Icons.qr_code_2),
                        title: Text(l10n.settingsLinkDevice),
                        trailing: _chevron,
                        onTap: () async {
                          if (await _reauthenticate(context) &&
                              context.mounted) {
                            _open(
                              context,
                              (_) => DeviceLinkScreen(state: state),
                            );
                          }
                        },
                      ),
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
                      _DeviceTile(
                        device: device,
                        isCurrent: device.id == session?.deviceId,
                        busy: state.busy,
                        onRevoke: () => _confirmRevoke(context, device),
                      ),
                    ListTile(
                      leading: const Icon(Icons.phonelink_erase_outlined),
                      title: Text(l10n.settingsSignOutOthers),
                      onTap: state.busy
                          ? null
                          : () => _confirmLogoutOthers(context),
                    ),
                  ],
                ),
                _header(l10n.settingsSectionPrivacySafety),
                TileGroup(
                  children: <Widget>[
                    ReadReceiptsTile(
                      preferences: state.receiptPreferences,
                      onChanged: state.setSendReadReceipts,
                    ),
                    if (state.sealedSender != null)
                      ListTile(
                        leading: const Icon(Icons.key_outlined),
                        title: Text(l10n.l2SealedKeyTitle),
                        // L2-3: owner report keys waiting for a decision.
                        subtitle: state.ownerKeyReview.isEmpty
                            ? null
                            : Text(
                                l10n.l2OwnerKeysReviewTile,
                                key: const ValueKey('owner-key-review-tile'),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                        trailing: _chevron,
                        onTap: () => _open(
                          context,
                          (_) => SealedKeyScreen(state: state),
                        ),
                      ),
                    SwitchListTile(
                      secondary: const Icon(Icons.alternate_email),
                      title: Text(l10n.w8MentionsMuted),
                      value: state.mentionsInMutedChats,
                      onChanged: state.setMentionsInMutedChats,
                    ),
                    LinkPreviewTile(
                      mode: state.linkPreviewMode,
                      onChanged: state.setLinkPreviewMode,
                    ),
                    SwitchListTile(
                      key: const ValueKey<String>('settings-chat-previews'),
                      secondary: const Icon(Icons.short_text),
                      title: Text(l10n.chatPreviewsSetting),
                      subtitle: Text(l10n.chatPreviewsSettingDetail),
                      value: state.showChatPreviews,
                      onChanged: state.setShowChatPreviews,
                    ),
                    if (defaultTargetPlatform == TargetPlatform.android)
                      SwitchListTile(
                        key: const ValueKey<String>('settings-screen-guard'),
                        secondary: const Icon(Icons.shield_outlined),
                        title: Text(l10n.settingsScreenGuard),
                        value: state.screenGuardChats,
                        onChanged: state.setScreenGuardChats,
                      ),
                    // How a call is routed, said once here rather than on
                    // every call screen (U36). Relay-only unless switched on
                    // (D56/D134).
                    SwitchListTile(
                      key: const ValueKey<String>('settings-calls-relay'),
                      secondary: const Icon(Icons.call_outlined),
                      title: Text(l10n.settingsDirectCallsTitle),
                      subtitle: Text(l10n.settingsDirectCallsNote),
                      value: state.allowDirectCalls,
                      onChanged: state.setAllowDirectCalls,
                    ),
                    ListTile(
                      leading: const Icon(Icons.block_outlined),
                      title: Text(l10n.settingsBlockedAccounts),
                      // A count only when there is something to count (U18).
                      subtitle:
                          state.blocksLoaded && state.blockedAccounts.isNotEmpty
                              ? Text(
                                  l10n.settingsBlockedCount(
                                    state.blockedAccounts.length,
                                  ),
                                )
                              : null,
                      trailing: _chevron,
                      onTap: () => _open(
                        context,
                        (_) => BlockedAccountsScreen(state: state),
                      ),
                    ),
                  ],
                ),
                _header(l10n.settingsSectionNotifications),
                TileGroup(
                  children: <Widget>[
                    _PushStatusRow(state: state),
                    if (defaultTargetPlatform == TargetPlatform.android &&
                        (state.pushProviders.contains('webpush') ||
                            state.pushProviders.contains('unifiedpush')))
                      ListTile(
                        enabled: state.pushConfigured && !state.busy,
                        leading: const Icon(Icons.hub_outlined),
                        title: Text(l10n.settingsPushProvider),
                        onTap: state.choosePushDistributor,
                      ),
                    if (notifications != null)
                      SwitchListTile(
                        secondary: const Icon(Icons.notifications_outlined),
                        title: Text(l10n.settingsHideNotificationPreview),
                        value: notifications.hidePreview,
                        onChanged: notifications.setHidePreview,
                      ),
                    // Only once this device is registered: a disabled row that
                    // says "available once registered" is noise (U18).
                    if (state.pushState == PushState.registered)
                      ListTile(
                        enabled: !state.isBusy(Ops.pushTest),
                        leading: const Icon(Icons.send_outlined),
                        title: Text(l10n.settingsTestPush),
                        subtitle: Text(
                          state.pushTestResult ??
                              (state.pushProvider == null
                                  ? l10n.settingsTestPushUnavailable
                                  : l10n.settingsTestPushRegistered(
                                      _providerName(state.pushProvider!),
                                    )),
                        ),
                        onTap: state.sendTestPush,
                      ),
                  ],
                ),
                if (appearance != null) ...<Widget>[
                  _header(l10n.settingsSectionAppearance),
                  _AppearanceRow(controller: appearance),
                ],
                if (updates != null) ...<Widget>[
                  _header(l10n.settingsSectionUpdates),
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      updates.settings,
                      updates.service,
                    ]),
                    builder: (context, _) => TileGroup(
                      children: <Widget>[
                        SwitchListTile(
                          key: const ValueKey<String>(
                            'settings-auto-update-check',
                          ),
                          secondary: const Icon(Icons.system_update_outlined),
                          title: Text(l10n.settingsAutoUpdateCheck),
                          value: updates.settings.autoCheckEnabled,
                          onChanged: (value) =>
                              updates.settings.setAutoCheckEnabled(value),
                        ),
                        _updateTile(context, updates.service),
                      ],
                    ),
                  ),
                ],
                if (isAdmin ||
                    (state.reportsAvailable &&
                        state.isInstanceOwner)) ...<Widget>[
                  _header(l10n.settingsAdmin),
                  TileGroup(
                    children: <Widget>[
                      if (isAdmin)
                        ListTile(
                          leading: const Icon(Icons.card_giftcard_outlined),
                          title: Text(l10n.settingsInvites),
                          trailing: _chevron,
                          onTap: () async {
                            if (await _reauthenticate(context) &&
                                context.mounted) {
                              _open(context, (_) => InviteScreen(state: state));
                            }
                          },
                        ),
                      if (state.reportsAvailable && state.isInstanceOwner)
                        ListTile(
                          leading: const Icon(Icons.flag_outlined),
                          title: Text(l10n.c6ReportsTitle),
                          trailing: _chevron,
                          onTap: () => _open(
                            context,
                            (_) => OwnerReportsScreen(
                              state: state,
                              reauthenticate: _reauthenticate,
                            ),
                          ),
                        ),
                      if (isAdmin)
                        ListTile(
                          leading: const Icon(
                            Icons.admin_panel_settings_outlined,
                          ),
                          title: Text(l10n.settingsAdminDetail),
                          trailing: _chevron,
                          onTap: () async {
                            if (await _reauthenticate(context) &&
                                context.mounted) {
                              _open(
                                context,
                                (_) => AdminScreen(
                                  state: state,
                                  reauthenticate: _reauthenticate,
                                ),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ],
                _header(l10n.settingsSectionAbout),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(l10n.aboutTitle(veritraProductName)),
                      subtitle: Text(
                        l10n.aboutVersion(veritraVersion, veritraLicenseName),
                      ),
                      onTap: () => showVeritraAbout(
                        context,
                        demo: state.config.demo,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(l10n.aboutLicenses),
                      trailing: _chevron,
                      onTap: () => showVeritraLicenses(context),
                    ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.sm),
                // Last, and red: it ends this device's session.
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      key: const ValueKey<String>('settings-sign-out'),
                      leading: Icon(
                        Icons.logout,
                        color: theme.colorScheme.error,
                      ),
                      title: Text(
                        l10n.settingsSignOut,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      onTap: state.busy ? null : () => _confirmLogout(context),
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

  /// A group header with tighter spacing than the default, so the tab keeps
  /// fitting two screens at 360 x 800 (U18).
  static Widget _header(String title) => SectionHeader(
        title,
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.xs,
          BoneSpacing.md,
          BoneSpacing.xs,
          BoneSpacing.xs,
        ),
      );

  void _open(BuildContext context, WidgetBuilder builder) {
    Navigator.of(context).push(sharedAxisRoute<void>(builder));
  }

  /// One tile that walks the update steps. Every step is a tap: check,
  /// download, restart. Nothing downloads or installs by itself.
  static Widget _updateTile(BuildContext context, UpdateService service) {
    final l10n = context.l10n;
    final status = service.status;
    final String title;
    final IconData icon;
    final VoidCallback? onTap;
    switch (status.kind) {
      case UpdateStatusKind.updateAvailable when !service.canInstall:
        // An all-users install only reports it (isPerUserWindowsInstall).
        title = l10n.settingsCheckForUpdates;
        icon = Icons.refresh_outlined;
        onTap = () => service.checkForUpdates(force: true);
      case UpdateStatusKind.updateAvailable:
      case UpdateStatusKind.downloadFailed:
        title = l10n.settingsUpdateDownload;
        icon = Icons.download_outlined;
        onTap = status.kind == UpdateStatusKind.updateAvailable
            ? () => service.downloadUpdate()
            : () => service.checkForUpdates(force: true);
      case UpdateStatusKind.readyToInstall:
        title = l10n.settingsUpdateRestart;
        icon = Icons.restart_alt_outlined;
        onTap = () => service.installUpdate();
      case UpdateStatusKind.downloading:
      case UpdateStatusKind.checking:
      case UpdateStatusKind.unavailable:
        title = l10n.settingsCheckForUpdates;
        icon = Icons.refresh_outlined;
        onTap = null;
      case UpdateStatusKind.idle:
      case UpdateStatusKind.upToDate:
      case UpdateStatusKind.disabled:
      case UpdateStatusKind.error:
        title = l10n.settingsCheckForUpdates;
        icon = Icons.refresh_outlined;
        onTap = () => service.checkForUpdates(force: true);
    }
    return ListTile(
      key: const ValueKey<String>('settings-check-for-updates'),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(_updateStatusText(context, status)),
      onTap: onTap,
    );
  }

  static String _updateStatusText(BuildContext context, UpdateStatus status) {
    final l10n = context.l10n;
    switch (status.kind) {
      case UpdateStatusKind.idle:
        return l10n.settingsCheckForUpdates;
      case UpdateStatusKind.checking:
        return l10n.settingsCheckingForUpdates;
      case UpdateStatusKind.updateAvailable:
        return l10n.settingsUpdateAvailable(status.update!.version);
      case UpdateStatusKind.upToDate:
        return l10n.settingsUpdateUpToDate;
      case UpdateStatusKind.disabled:
        return l10n.settingsUpdateDisabled;
      case UpdateStatusKind.error:
        return l10n.settingsUpdateError;
      case UpdateStatusKind.unavailable:
        return l10n.settingsUpdateUnavailable;
      case UpdateStatusKind.downloading:
        return l10n.settingsUpdateDownloading;
      case UpdateStatusKind.readyToInstall:
        return l10n.settingsUpdateReady(status.update!.version);
      case UpdateStatusKind.downloadFailed:
        return l10n.settingsUpdateDownloadFailed;
    }
  }

  String _recoveryKeySubtitle(BuildContext context) {
    final l10n = context.l10n;
    final status = state.recoveryKeyStatus;
    if (status == null) return l10n.recoveryKeyStatusUnknown;
    if (!status.available) return l10n.recoveryKeyStatusOff;
    if (!status.configured) return l10n.recoveryKeyStatusNotSet;
    final setAt = status.setAt;
    return setAt == null
        ? l10n.recoveryKeyStatusUnknown
        : l10n.recoveryKeyStatusSet(formatDate(context, setAt));
  }

  Future<void> _confirmRevoke(BuildContext context, Device device) async {
    final confirmed = await _confirm(
      context,
      title: context.l10n.settingsSignOutDeviceTitle(device.name),
      message: context.l10n.settingsRevokeDeviceMessage(device.name),
      confirmLabel: context.l10n.settingsSignOutDeviceButton,
      destructive: true,
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.revokeDevice(device.id);
      }
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    // C6: signing out deletes this device's report key; say so first.
    final holdsSeed = await state.holdsReportSeed();
    if (!context.mounted) return;
    final confirmed = await _confirm(
      context,
      title: context.l10n.settingsSignOutTitle,
      message: holdsSeed
          ? '${context.l10n.settingsSignOutMessage}\n\n'
              '${context.l10n.c6SignOutSeedWarning}'
          : context.l10n.settingsSignOutMessage,
      confirmLabel: context.l10n.settingsSignOut,
    );
    if (confirmed) {
      await state.logout();
    }
  }

  Future<void> _confirmLogoutOthers(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: context.l10n.settingsSignOutOthersTitle,
      message: context.l10n.settingsSignOutOthersMessage,
      confirmLabel: context.l10n.settingsSignOutOthersConfirm,
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
      title: context.l10n.settingsDeleteAccountTitle,
      message: context.l10n.settingsDeleteAccountMessage,
      confirmLabel: context.l10n.settingsDeleteAccountConfirm,
      destructive: true,
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.deleteAccount();
      }
    }
  }

  /// L1 migration genesis: the user ticks the devices they recognise; they
  /// become the account's approved-device list and the rest are removed.
  Future<void> _reviewDeviceList(BuildContext context) async {
    final own = state.session?.deviceId;
    if (own == null) return;
    final candidates = [
      for (final device in state.devices)
        if (device.revokedAt == null) device,
    ];
    final keep = <String>{for (final device in candidates) device.id};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(dialogContext.l10n.deviceListReviewTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(dialogContext.l10n.deviceListReviewBody),
                for (final device in candidates)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keep.contains(device.id),
                    title: Text(device.name),
                    subtitle: Text(
                      dialogContext.l10n.settingsDeviceAdded(
                        formatDate(dialogContext, device.createdAt),
                      ),
                    ),
                    onChanged: device.id == own
                        ? null
                        : (value) => setDialogState(() {
                              if (value ?? false) {
                                keep.add(device.id);
                              } else {
                                keep.remove(device.id);
                              }
                            }),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.l10n.deviceListReviewConfirm),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    var result = await state.createApprovedDeviceList(keep);
    if (result == RecoveryActionResult.needsRecentAuth && context.mounted) {
      if (!await _reauthenticate(context) || !context.mounted) return;
      result = await state.createApprovedDeviceList(keep);
    }
    if (result == RecoveryActionResult.failed && context.mounted) {
      final message = state.errorFor(Ops.devices);
      if (message != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  /// Asks for the recovery key from the user's paper. The typed text is
  /// handed on and dropped with the dialog; it is never stored.
  Future<String?> _askRecoveryKey(BuildContext context) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.l10n.recoveryKeyConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(dialogContext.l10n.recoveryKeyConfirmDetail),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: dialogContext.l10n.recoveryKeyField,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(dialogContext.l10n.commonContinue),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _showRecoveryResult(BuildContext context, bool ok, String done) {
    final message = ok ? done : state.errorFor(Ops.recoveryKey);
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// L1 recovery retype: the held seed is gone, so the key is typed again.
  Future<void> _retypeRecoveryKey(BuildContext context) async {
    final typed = await _askRecoveryKey(context);
    if (typed == null || typed.trim().isEmpty || !context.mounted) return;
    final ok = await state.finishRecoveryWithTypedKey(typed);
    if (context.mounted) {
      _showRecoveryResult(context, ok, context.l10n.recoveryRetypeDone);
    }
  }

  /// L1: a recovery key from before approved-device lists, typed once.
  Future<void> _confirmPreL1RecoveryKey(BuildContext context) async {
    final typed = await _askRecoveryKey(context);
    if (typed == null || typed.trim().isEmpty || !context.mounted) return;
    var result = await state.confirmPreL1RecoveryKey(typed);
    if (result == RecoveryActionResult.needsRecentAuth && context.mounted) {
      if (!await _reauthenticate(context) || !context.mounted) return;
      result = await state.confirmPreL1RecoveryKey(typed);
    }
    if (context.mounted && result != RecoveryActionResult.needsRecentAuth) {
      _showRecoveryResult(
        context,
        result == RecoveryActionResult.done,
        context.l10n.recoveryKeyConfirmedForList,
      );
    }
  }

  Future<bool> _reauthenticate(BuildContext context) =>
      promptReauthenticate(context, state);

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
          title: Text(dialogContext.l10n.settingsChangePassword),
          content: Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: dialogContext.l10n.settingsNewPassword,
                    helperText: dialogContext.l10n.settingsNewPasswordHelper,
                  ),
                  validator: (value) =>
                      _validateNewPassword(value, dialogContext.l10n),
                  // Re-run the confirmation check when the first field
                  // changes, so an already-typed confirmation is not left
                  // showing a stale "matches" state.
                  onChanged: (_) => formKey.currentState?.validate(),
                ),
                TextFormField(
                  controller: confirmation,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: dialogContext.l10n.settingsConfirmNewPassword,
                  ),
                  validator: (value) => (value ?? '') != password.text
                      ? dialogContext.l10n.settingsPasswordsMismatch
                      : null,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: Text(dialogContext.l10n.settingsChangePasswordConfirm),
            ),
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
          content: Text(state.error ?? context.l10n.settingsPasswordChanged),
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
        ? (state.error ?? context.l10n.settingsExportFailed)
        : context.l10n.settingsExportSaved;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  /// Length is checked in UTF-8 bytes to match the server's bcrypt limit, but
  /// the message stays in user language.
  static String? _validateNewPassword(String? value, AppLocalizations l10n) {
    final raw = value ?? '';
    if (raw.isEmpty) {
      return l10n.settingsPasswordRequired;
    }
    final bytes = utf8.encode(raw).length;
    if (bytes < 12) {
      return l10n.settingsPasswordTooShort;
    }
    if (bytes > 72) {
      return l10n.settingsPasswordTooLong;
    }
    return null;
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) =>
      confirmAction(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        destructive: destructive,
      );
}

/// System/Light/Dark. Saved on this device and applied immediately.
class _AppearanceRow extends StatelessWidget {
  const _AppearanceRow({required this.controller});

  final AppearanceController controller;

  @override
  Widget build(BuildContext context) {
    return TileGroup(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(BoneSpacing.md),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: <ButtonSegment<ThemeMode>>[
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  icon: const Icon(Icons.brightness_auto_outlined),
                  label: Text(context.l10n.appearanceSystem),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  icon: const Icon(Icons.light_mode_outlined),
                  label: Text(context.l10n.appearanceLight),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  icon: const Icon(Icons.dark_mode_outlined),
                  label: Text(context.l10n.appearanceDark),
                ),
              ],
              selected: <ThemeMode>{controller.mode},
              onSelectionChanged: (selection) =>
                  controller.setMode(selection.single),
            ),
          ),
        ),
      ],
    );
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
                        username == null
                            ? context.l10n.settingsSignedIn
                            : '@$username',
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
    final l10n = context.l10n;
    final String title;
    final String detail;
    final IconData icon;
    var warn = true;
    // Notifications are off at the system: offer the way back on (U18).
    var canTurnOn = false;
    final desktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (desktop) {
      title = l10n.settingsPushDesktopTitle;
      detail = l10n.settingsPushDesktopDetail;
      icon = Icons.notifications_off_outlined;
    } else {
      switch (state.pushState) {
        case PushState.serverDisabled:
          title = l10n.settingsPushServerDisabledTitle;
          detail = l10n.settingsPushServerDisabledDetail;
          icon = Icons.cloud_off_outlined;
        case PushState.unknown:
        case PushState.registering:
          title = l10n.settingsPushRegisteringTitle;
          detail = l10n.settingsPushRegisteringDetail;
          icon = Icons.hourglass_empty;
        case PushState.noDistributor:
          title = l10n.settingsPushNoDistributorTitle;
          detail = l10n.settingsPushNoDistributorDetail;
          icon = Icons.warning_amber_outlined;
        case PushState.registrationFailed:
          title = l10n.settingsPushFailedTitle;
          detail = l10n.settingsPushFailedDetail;
          icon = Icons.warning_amber_outlined;
        case PushState.registered:
          // Registered only means the server will send; the system still has
          // to allow showing it. Active is claimed only when it does.
          switch (state.notificationPermission) {
            case NotificationPermission.granted:
              title = l10n.settingsPushActiveTitle;
              detail = l10n.settingsPushActiveDetail;
              icon = Icons.notifications_active_outlined;
              warn = false;
            case NotificationPermission.denied:
              title = l10n.settingsPushDeniedTitle;
              detail = l10n.settingsPushDeniedDetail;
              icon = Icons.notifications_off_outlined;
              canTurnOn = true;
            case NotificationPermission.notDetermined:
              title = l10n.settingsPushNotAllowedTitle;
              detail = l10n.settingsPushNotAllowedDetail;
              icon = Icons.notifications_paused_outlined;
              canTurnOn = true;
            case NotificationPermission.unsupported:
              title = l10n.settingsPushUnconfirmedTitle;
              detail = l10n.settingsPushUnconfirmedDetail;
              icon = Icons.notification_important_outlined;
          }
      }
    }
    final scheme = theme.colorScheme;
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    final tint = warn ? states.warning : states.verified;
    return ListTile(
      leading: Icon(icon, color: tint),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (canTurnOn)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey<String>('settings-notifications-turn-on'),
                onPressed: state.requestNotificationPermission,
                child: Text(l10n.settingsTurnOn),
              ),
            ),
        ],
      ),
    );
  }
}

String _providerName(String provider) {
  switch (provider) {
    case 'fcm':
      return 'Firebase Cloud Messaging';
    case 'apns':
      return 'Apple Push Notification service';
    case 'webpush':
    case 'unifiedpush':
      return 'UnifiedPush';
  }
  return provider;
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
