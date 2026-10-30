import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../push/push_service.dart';
import 'backup_screen.dart';
import '../../core/models.dart';
import '../../desktop/message_notifications.dart';
import '../../ui/about.dart';
import '../../ui/appearance.dart';
import 'read_receipts_tile.dart';
import '../../ui/avatar.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import 'admin_screen.dart';
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
        final appearance = AppearanceScope.maybeOf(context);
        final notifications = NotificationSettingsScope.maybeOf(context);
        final l10n = context.l10n;
        return Scaffold(
          appBar: LargeTitleBar(
            title: l10n.settingsTitle,
            actions: <Widget>[
              IconButton(
                tooltip: l10n.commonRefresh,
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
              SectionHeader(l10n.settingsSectionAccount),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(l10n.settingsAccountId),
                    subtitle: Text(
                      session?.accountId == null
                          ? l10n.settingsAccountIdUnknown
                          : shortId(session!.accountId!),
                      style: BoneType.mono.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: session?.accountId == null
                        ? null
                        : IconButton(
                            tooltip: l10n.settingsCopyAccountId,
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: () => _copy(
                              context,
                              session!.accountId!,
                              l10n.settingsAccountId,
                            ),
                          ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: Text(l10n.settingsChangePassword),
                    subtitle: Text(l10n.settingsChangePasswordDetail),
                    onTap: state.busy ? null : () => _changePassword(context),
                  ),
                  if (isAdmin)
                    ListTile(
                      leading: const Icon(Icons.card_giftcard_outlined),
                      title: Text(l10n.settingsInvites),
                      subtitle: Text(l10n.settingsInvitesDetail),
                      onTap: () async {
                        if (await _reauthenticate(context) && context.mounted) {
                          Navigator.of(context).push(
                            sharedAxisRoute<void>(
                              (_) => InviteScreen(state: state),
                            ),
                          );
                        }
                      },
                    ),
                  if (isAdmin)
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: Text(l10n.settingsAdmin),
                      subtitle: Text(l10n.settingsAdminDetail),
                      onTap: () async {
                        if (await _reauthenticate(context) && context.mounted) {
                          Navigator.of(context).push(
                            sharedAxisRoute<void>(
                              (_) => AdminScreen(
                                state: state,
                                reauthenticate: _reauthenticate,
                              ),
                            ),
                          );
                        }
                      },
                    ),
                ],
              ),
              SectionHeader(l10n.settingsSectionDevices),
              TileGroup(
                children: <Widget>[
                  if (state.membershipChangesAvailable)
                    ListTile(
                      leading: const Icon(Icons.qr_code_2),
                      title: Text(l10n.settingsLinkDevice),
                      subtitle: Text(l10n.settingsLinkDeviceDetail),
                      onTap: () async {
                        if (await _reauthenticate(context) && context.mounted) {
                          Navigator.of(context).push(
                            sharedAxisRoute<void>(
                              (_) => DeviceLinkScreen(state: state),
                            ),
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
                ],
              ),
              SectionHeader(l10n.settingsSectionSafety),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.block_outlined),
                    title: Text(l10n.settingsBlockedAccounts),
                    subtitle: Text(
                      state.blocksLoaded
                          ? (state.blockedAccounts.isEmpty
                              ? l10n.settingsBlockedNone
                              : l10n.settingsBlockedCount(
                                  state.blockedAccounts.length,
                                ))
                          : l10n.settingsBlockedReview,
                    ),
                    onTap: () => Navigator.of(context).push(
                      sharedAxisRoute<void>(
                        (_) => BlockedAccountsScreen(state: state),
                      ),
                    ),
                  ),
                ],
              ),
              SectionHeader(l10n.settingsSectionYourData),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(l10n.settingsExport),
                    subtitle: Text(l10n.settingsExportDetail),
                    onTap: state.busy ? null : () => _exportAccount(context),
                  ),
                ],
              ),
              SectionHeader(l10n.settingsSectionNotifications),
              _PushStatusRow(state: state),
              const SizedBox(height: BoneSpacing.sm),
              TileGroup(
                children: <Widget>[
                  if (state.notificationPermission ==
                      NotificationPermission.notDetermined)
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: Text(l10n.settingsAllowNotifications),
                      subtitle: Text(l10n.settingsAllowNotificationsDetail),
                      onTap: state.requestNotificationPermission,
                    ),
                  if (defaultTargetPlatform == TargetPlatform.android &&
                      state.pushProviders.contains('webpush'))
                    ListTile(
                      enabled: state.pushConfigured && !state.busy,
                      leading: const Icon(Icons.hub_outlined),
                      title: Text(l10n.settingsPushProvider),
                      subtitle: Text(l10n.settingsPushProviderDetail),
                      onTap: state.choosePushDistributor,
                    ),
                  ListTile(
                    enabled: state.pushState == PushState.registered &&
                        !state.isBusy(Ops.pushTest),
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
              SectionHeader(l10n.settingsSectionSession),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: Text(l10n.settingsSignOut),
                    onTap: state.busy ? null : () => _confirmLogout(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.phonelink_erase_outlined),
                    title: Text(l10n.settingsSignOutOthers),
                    subtitle: Text(l10n.settingsSignOutOthersDetail),
                    onTap:
                        state.busy ? null : () => _confirmLogoutOthers(context),
                  ),
                ],
              ),
              if (state.backupAvailable) ...<Widget>[
                SectionHeader(l10n.settingsSectionRecovery),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l10n.settingsBackup),
                      subtitle: Text(l10n.settingsBackupDetail),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BackupScreen(state: state),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              SectionHeader(l10n.settingsSectionComingSoon),
              TileGroup(
                children: <Widget>[
                  if (!state.backupAvailable)
                    ListTile(
                      enabled: false,
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l10n.settingsRecoveryComingSoon),
                      subtitle: Text(l10n.settingsRecoveryComingSoonDetail),
                    ),
                  ListTile(
                    enabled: false,
                    leading: const Icon(Icons.video_call_outlined),
                    title: Text(l10n.settingsCallsComingSoon),
                    subtitle: Text(l10n.settingsCallsComingSoonDetail),
                  ),
                ],
              ),
              if (notifications != null) ...<Widget>[
                SectionHeader(l10n.settingsSectionNotifications),
                TileGroup(
                  children: <Widget>[
                    SwitchListTile(
                      secondary: const Icon(Icons.notifications_outlined),
                      title: Text(l10n.settingsHideNotificationPreview),
                      subtitle:
                          Text(l10n.settingsHideNotificationPreviewDetail),
                      value: notifications.hidePreview,
                      onChanged: notifications.setHidePreview,
                    ),
                  ],
                ),
              ],
              SectionHeader(l10n.settingsSectionPrivacy),
              TileGroup(
                children: <Widget>[
                  ReadReceiptsTile(
                    preferences: state.receiptPreferences,
                    onChanged: state.setSendReadReceipts,
                  ),
                  SwitchListTile(
                      secondary: const Icon(Icons.alternate_email),
                      title: Text(l10n.w8MentionsMuted),
                      subtitle: Text(l10n.w8MentionsMutedDetail),
                      value: state.mentionsInMutedChats,
                      onChanged: state.setMentionsInMutedChats),
                ],
              ),
              if (appearance != null) ...<Widget>[
                SectionHeader(l10n.settingsSectionAppearance),
                _AppearanceRow(controller: appearance),
              ],
              SectionHeader(l10n.settingsSectionAbout),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.aboutTitle(veritraProductName)),
                    subtitle: Text(
                      l10n.aboutVersion(veritraVersion, veritraLicenseName),
                    ),
                    onTap: () => showVeritraAbout(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(l10n.aboutLicenses),
                    subtitle: Text(l10n.aboutLicensesDetail),
                    onTap: () => showVeritraLicenses(context),
                  ),
                ],
              ),
              SectionHeader(l10n.settingsSectionDangerZone),
              // The one filled surface left in this direction. It is doing
              // real work — it is the only row on the screen you cannot undo.
              // A Material, not a decorated Container, so the row's ink
              // splash paints on the filled surface instead of under it.
              Material(
                color: theme.colorScheme.errorContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(BoneRadii.lg),
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  title: Text(
                    l10n.settingsDeleteAccount,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                  subtitle: Text(
                    l10n.settingsDeleteAccountDetail,
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.settingsCopied(label))));
  }

  Future<void> _confirmRevoke(BuildContext context, Device device) async {
    final confirmed = await _confirm(
      context,
      title: context.l10n.settingsRevokeDeviceTitle,
      message: context.l10n.settingsRevokeDeviceMessage(device.name),
      confirmLabel: context.l10n.commonRevoke,
    );
    if (confirmed) {
      if (await _reauthenticate(context)) {
        await state.revokeDevice(device.id);
      }
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: context.l10n.settingsSignOutTitle,
      message: context.l10n.settingsSignOutMessage,
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

  Future<bool> _reauthenticate(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final password = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.l10n.settingsReauthTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(
              labelText: dialogContext.l10n.settingsReauthField,
            ),
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
      if (password == null || password.isEmpty) {
        return false;
      }
      final ok = await state.reauthenticate(password);
      if (!ok && context.mounted && state.error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.error!)));
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
          content: Text(
            state.error ?? context.l10n.settingsPasswordChanged,
          ),
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
    final desktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final denied =
        state.notificationPermission == NotificationPermission.denied;
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
          if (denied) {
            title = l10n.settingsPushDeniedTitle;
            detail = l10n.settingsPushDeniedDetail;
            icon = Icons.notifications_off_outlined;
          } else {
            title = l10n.settingsPushActiveTitle;
            detail = l10n.settingsPushActiveDetail;
            icon = Icons.notifications_active_outlined;
            warn = false;
          }
      }
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

String _providerName(String provider) {
  switch (provider) {
    case 'fcm':
      return 'Firebase Cloud Messaging';
    case 'apns':
      return 'Apple Push Notification service';
    case 'webpush':
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
    return ListTile(
      leading: Icon(
        isCurrent ? Icons.phone_android : Icons.devices_other,
        color: revoked ? theme.disabledColor : null,
      ),
      // A Wrap, not a Row: at 320 px or 200% text the pill no longer fits
      // beside the name and drops below it instead of overflowing (T43C).
      title: Wrap(
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
              tooltip: context.l10n.commonRevoke,
              onPressed: busy ? null : onRevoke,
              icon: const Icon(Icons.block),
            ),
    );
  }
}
