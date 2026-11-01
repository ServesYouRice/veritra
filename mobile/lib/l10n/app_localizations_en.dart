// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonCreate => 'Create';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonRevoke => 'Revoke';

  @override
  String get listTimeYesterday => 'Yesterday';

  @override
  String get validationNameRequired => 'Enter a name.';

  @override
  String get validationNameTooLong => 'That name is too long.';

  @override
  String get validationGroupNameRequired => 'Enter a group name.';

  @override
  String get validationGroupNameTooLong => 'That group name is too long.';

  @override
  String get validationMessageTooLong =>
      'Too long to send. Shorten it or split it into several messages.';

  @override
  String get gatedAttachmentsUnavailable =>
      'Attachments need the reviewed encryption engine';

  @override
  String get confirmCancel => 'Cancel';

  @override
  String get appearanceSystem => 'System';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceDark => 'Dark';

  @override
  String aboutLegalese(String license, String url) {
    return 'Free software under the GNU Affero General Public License, version 3 or later ($license). Source code: $url';
  }

  @override
  String aboutTitle(String productName) {
    return 'About $productName';
  }

  @override
  String aboutVersion(String version, String license) {
    return 'Version $version · $license';
  }

  @override
  String get aboutLicenses => 'Open-source licenses';

  @override
  String get aboutLicensesDetail => 'Notices for Veritra and its components';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionAccount => 'Account';

  @override
  String get settingsSectionDevices => 'Devices';

  @override
  String get settingsSectionSafety => 'Safety';

  @override
  String get settingsSectionYourData => 'Your data';

  @override
  String get settingsSectionNotifications => 'Notifications';

  @override
  String get settingsSectionSession => 'Session';

  @override
  String get settingsSectionRecovery => 'Recovery';

  @override
  String get settingsSectionComingSoon => 'Coming soon';

  @override
  String get settingsSectionAppearance => 'Appearance';

  @override
  String get settingsHideNotificationPreview => 'Hide message preview';

  @override
  String get settingsHideNotificationPreviewDetail =>
      'Notifications say \"New message\" and show no sender or text.';

  @override
  String get notificationNewMessage => 'New message';

  @override
  String get trayOpen => 'Open';

  @override
  String get trayQuit => 'Quit';

  @override
  String get settingsSectionPrivacy => 'Privacy';

  @override
  String get settingsReadReceiptsTitle => 'Read receipts';

  @override
  String get settingsReadReceiptsDetail =>
      'Applies to all your devices. When off, you send no read receipts and you do not see when others have read your messages. Sent and delivered ticks stay.';

  @override
  String get settingsReadReceiptsFailed =>
      'The setting could not be changed. Check your connection and try again.';

  @override
  String get settingsReadReceiptsNotSaved =>
      'This device could not save the setting. It applies for now but may reset when the app restarts.';

  @override
  String get settingsSectionAbout => 'About';

  @override
  String get settingsSectionDangerZone => 'Danger zone';

  @override
  String get settingsAccountId => 'Account ID';

  @override
  String get settingsAccountIdUnknown => 'Unknown';

  @override
  String get settingsCopyAccountId => 'Copy account ID';

  @override
  String settingsCopied(String label) {
    return '$label copied.';
  }

  @override
  String get settingsChangePassword => 'Change password';

  @override
  String get settingsChangePasswordDetail =>
      'Ends sessions on your other devices';

  @override
  String get settingsInvites => 'Invites';

  @override
  String get settingsInvitesDetail => 'Create codes so others can join';

  @override
  String get settingsLinkDevice => 'Link a new device';

  @override
  String get settingsLinkDeviceDetail =>
      'Generate a pairing code for another device';

  @override
  String get settingsLoadingDevices => 'Loading devices…';

  @override
  String get settingsBlockedAccounts => 'Blocked accounts';

  @override
  String get settingsBlockedNone => 'No one is blocked';

  @override
  String settingsBlockedCount(int count) {
    return '$count blocked';
  }

  @override
  String get settingsBlockedReview => 'Review and undo blocks';

  @override
  String get settingsExport => 'Export account data';

  @override
  String get settingsExportDetail =>
      'Save encrypted messages and account metadata locally';

  @override
  String get settingsExportFailed => 'Account export failed.';

  @override
  String get settingsExportSaved => 'Account export saved locally.';

  @override
  String get settingsAllowNotifications => 'Allow notifications';

  @override
  String get settingsAllowNotificationsDetail =>
      'Notifications say only that a message arrived.';

  @override
  String get settingsPushProvider => 'Push provider';

  @override
  String get settingsPushProviderDetail =>
      'Choose an Android UnifiedPush provider';

  @override
  String get settingsTestPush => 'Send a test notification';

  @override
  String get settingsTestPushUnavailable =>
      'Available once this device is registered';

  @override
  String settingsTestPushRegistered(String provider) {
    return 'Registered with $provider';
  }

  @override
  String get settingsSignOut => 'Sign out';

  @override
  String get settingsSignOutOthers => 'Sign out other devices';

  @override
  String get settingsSignOutOthersDetail =>
      'Ends every session except this one';

  @override
  String get settingsBackup => 'Encrypted backup';

  @override
  String get settingsBackupDetail => 'Backup & recovery code';

  @override
  String get settingsRecoveryComingSoon => 'Recovery';

  @override
  String get settingsRecoveryComingSoonDetail =>
      'Encrypted backup & recovery key';

  @override
  String get settingsCallsComingSoon => 'Calls';

  @override
  String get settingsCallsComingSoonDetail => '1:1 audio/video';

  @override
  String get settingsDeleteAccount => 'Delete account';

  @override
  String get settingsDeleteAccountDetail =>
      'Disables sign-in and revokes your devices. Some encrypted records may remain under server retention rules.';

  @override
  String get settingsSignedIn => 'Signed in';

  @override
  String get settingsRevokeDeviceTitle => 'Revoke device?';

  @override
  String settingsRevokeDeviceMessage(String deviceName) {
    return '\"$deviceName\" will lose access immediately.';
  }

  @override
  String get settingsSignOutTitle => 'Sign out?';

  @override
  String get settingsSignOutMessage =>
      'This device stops receiving messages until you sign in again with your password.';

  @override
  String get settingsSignOutOthersTitle => 'Sign out other devices?';

  @override
  String get settingsSignOutOthersMessage =>
      'Every session except this one will be ended.';

  @override
  String get settingsSignOutOthersConfirm => 'Sign out others';

  @override
  String get settingsDeleteAccountTitle => 'Delete account?';

  @override
  String get settingsDeleteAccountMessage =>
      'This disables your account, ends its sessions, and revokes its devices. Encrypted messages and other records may remain according to the server retention policy.';

  @override
  String get settingsDeleteAccountConfirm => 'Disable account';

  @override
  String get settingsReauthTitle => 'Confirm your password';

  @override
  String get settingsReauthField => 'Current password';

  @override
  String get settingsNewPassword => 'New password';

  @override
  String get settingsNewPasswordHelper => 'At least 12 characters.';

  @override
  String get settingsConfirmNewPassword => 'Confirm new password';

  @override
  String get settingsPasswordsMismatch => 'Passwords do not match.';

  @override
  String get settingsChangePasswordConfirm => 'Change';

  @override
  String get settingsPasswordChanged =>
      'Password changed. Your other devices were signed out.';

  @override
  String get settingsPasswordRequired => 'Enter a new password.';

  @override
  String get settingsPasswordTooShort => 'Use at least 12 characters.';

  @override
  String get settingsPasswordTooLong =>
      'That password is too long. Use a shorter one.';

  @override
  String get settingsPushDesktopTitle =>
      'Desktop notifications are not available yet';

  @override
  String get settingsPushDesktopDetail =>
      'Messages arrive while the app is running, even in the background.';

  @override
  String get settingsPushServerDisabledTitle =>
      'This server has no push provider';

  @override
  String get settingsPushServerDisabledDetail =>
      'The operator has not configured push. Messages arrive while the app is open.';

  @override
  String get settingsPushRegisteringTitle => 'Setting up push';

  @override
  String get settingsPushRegisteringDetail =>
      'Waiting for this device to register.';

  @override
  String get settingsPushNoDistributorTitle => 'No push distributor registered';

  @override
  String get settingsPushNoDistributorDetail =>
      'Install a UnifiedPush distributor and pick it below, or messages will only arrive while the app is open.';

  @override
  String get settingsPushFailedTitle => 'Push registration failed';

  @override
  String get settingsPushFailedDetail =>
      'This device could not register for push. It tries again the next time the app starts.';

  @override
  String get settingsPushDeniedTitle => 'Notifications are turned off';

  @override
  String get settingsPushDeniedDetail =>
      'The app still syncs when woken, but shows nothing. Allow notifications for Veritra in the system settings.';

  @override
  String get settingsPushNotAllowedTitle => 'Notifications are not allowed yet';

  @override
  String get settingsPushNotAllowedDetail =>
      'Allow notifications below to be alerted. Until then the app syncs when woken but shows nothing.';

  @override
  String get settingsPushUnconfirmedTitle =>
      'Notifications cannot be confirmed';

  @override
  String get settingsPushUnconfirmedDetail =>
      'This device did not confirm that notifications are allowed, so none may be shown. Check the system settings for Veritra.';

  @override
  String get settingsPushActiveTitle => 'Push notifications are active';

  @override
  String get settingsPushActiveDetail =>
      'Notifications never contain message text or sender names.';

  @override
  String settingsDeviceLastSeen(String time) {
    return 'Last seen $time';
  }

  @override
  String settingsDeviceAdded(String date) {
    return 'Added $date';
  }

  @override
  String get settingsDeviceRevoked => 'Revoked';

  @override
  String get settingsDeviceCurrent => 'This device';

  @override
  String get backupReplaceTitle => 'Replace your backup?';

  @override
  String get backupReplaceMessage =>
      'The previous backup and its recovery code will stop working. Keep the new code somewhere safe.';

  @override
  String get backupReplaceConfirm => 'Replace backup';

  @override
  String get inviteRevokeTitle => 'Revoke invite?';

  @override
  String inviteRevokeMessage(String code) {
    return 'Code $code stops working immediately. People who already joined with it keep their accounts.';
  }

  @override
  String get connectFreshInstanceTitle => 'Fresh instance detected';

  @override
  String get connectFreshInstanceMessage =>
      'No owner account exists yet — create it below.';

  @override
  String get connectInstanceUrl => 'Instance URL';

  @override
  String get connectCheckApproval => 'Check approval';

  @override
  String get connectLinkInstead => 'Link this device instead';

  @override
  String get connectOtherWays => 'Other ways to connect';

  @override
  String get connectRestoreBackup => 'Restore from a backup';

  @override
  String get connectLinkCode => 'Link code';

  @override
  String get connectLinkCodeRequired =>
      'Enter the link code from your existing device.';

  @override
  String get connectLinkCodeHint => 'From Settings → Link device';

  @override
  String get connectScanQr => 'Scan QR code';

  @override
  String get connectVerificationTitle => 'Verification code';

  @override
  String get connectVerificationMessage =>
      'Confirm this code on your already-linked device, then check approval below.';

  @override
  String get connectInviteCode => 'Invite code';

  @override
  String get connectInviteCodeRequired => 'Enter the invite code you received.';

  @override
  String get connectInviteCodeHint => 'From an admin on this instance';

  @override
  String get connectUsername => 'Username';

  @override
  String get connectUsernameRequired => 'Enter a username.';

  @override
  String get connectUsernameHint => 'Your name on this instance';

  @override
  String get connectPassword => 'Password';

  @override
  String get connectPasswordHint => 'At least 12 characters';

  @override
  String get connectHidePassword => 'Hide password';

  @override
  String get connectShowPassword => 'Show password';

  @override
  String get connectConfirmPassword => 'Confirm password';

  @override
  String get connectConfirmPasswordHint => 'Repeat your password';

  @override
  String get connectSetupToken => 'Setup token';

  @override
  String get connectSetupTokenHint => 'Required unless connecting on loopback';

  @override
  String get connectUrlRequired => 'Enter the instance URL.';

  @override
  String get connectUrlInvalid =>
      'Enter a full URL, e.g. https://chat.example.org';

  @override
  String get connectUrlOriginOnly =>
      'Enter only the server origin, e.g. https://chat.example.org';

  @override
  String get connectUrlHttpsRequired =>
      'Veritra requires HTTPS. Use an https:// server origin.';

  @override
  String get connectUrlLoopbackOnly =>
      'Use https://, or http:// only for this computer (localhost or 127.0.0.1).';

  @override
  String get connectPasswordRequired => 'Enter your password.';

  @override
  String get connectModeOwnerTitle => 'Create the owner account';

  @override
  String get connectModeSignInTitle => 'Sign in';

  @override
  String get connectModeJoinTitle => 'Join with an invite';

  @override
  String get connectModeLinkTitle => 'Link this device';

  @override
  String get connectModeOwnerDetail =>
      'First run only: create the owner account on a fresh self-hosted instance.';

  @override
  String get connectModeSignInDetail =>
      'Sign in with your password on a device that has already been linked to your account.';

  @override
  String get connectModeJoinDetail =>
      'Registration is invite-only. Enter the invite code you received from an admin.';

  @override
  String get connectModeLinkDetail =>
      'Enter the link code generated on your existing device (Settings → Link device).';

  @override
  String get connectNotDeviceLinkQr => 'That is not a Veritra device-link QR.';

  @override
  String get connectOriginFilled =>
      'Server origin filled. Verify it before continuing.';

  @override
  String get connectConfirmServerTitle => 'Confirm server';

  @override
  String connectConfirmServerMessage(String origin) {
    return 'This QR code suggests $origin. The app will still probe the server before using it. Continue with this HTTPS origin?';
  }

  @override
  String get connectUseOrigin => 'Use origin';

  @override
  String get connectSubmitOwner => 'Create owner';

  @override
  String get connectSubmitSignIn => 'Sign in';

  @override
  String get connectSubmitJoin => 'Join with invite';

  @override
  String get connectSubmitLink => 'Claim link';

  @override
  String get connectTagline => 'Self-hosted, end-to-end encrypted messaging';

  @override
  String get qrScanLinkTitle => 'Scan link QR';

  @override
  String get qrToggleTorch => 'Toggle torch';

  @override
  String get qrSwitchCamera => 'Switch camera';

  @override
  String get qrPointCamera =>
      'Point the camera at the QR code on your existing device (Settings → Link a new device).';

  @override
  String get qrPermissionDenied =>
      'Camera permission is required to scan. Enable it in system settings, or type the link code manually.';

  @override
  String get qrUnsupported =>
      'This device can’t scan QR codes. Type the link code manually.';

  @override
  String get qrCameraFailed =>
      'The camera could not be started. Type the link code manually.';

  @override
  String get qrEnterManually => 'Enter code manually';

  @override
  String get newConversationTitle => 'New conversation';

  @override
  String get newConversationDirect => 'Direct message';

  @override
  String get newConversationGroup => 'Group';

  @override
  String get newConversationGroupName => 'Group name';

  @override
  String get newConversationWho => 'Who do you want to message?';

  @override
  String get newConversationAddMembers => 'Add members';

  @override
  String get newConversationStartDm => 'Start DM';

  @override
  String get newConversationCreateGroup => 'Create group';

  @override
  String get newConversationPickPerson => 'Pick the person to message first.';

  @override
  String get newConversationAddOneMember => 'Add at least one other member.';

  @override
  String get blockedEmptyTitle => 'No blocked accounts';

  @override
  String get blockedEmptyMessage =>
      'Block someone from a direct message to stop the server delivering their messages to you.';

  @override
  String get blockedLabel => 'Blocked';

  @override
  String blockedOn(String date) {
    return 'Blocked $date';
  }

  @override
  String get blockedUnblock => 'Unblock';

  @override
  String blockedUnblocked(String label) {
    return '$label unblocked.';
  }

  @override
  String blockedUnblockFailed(String label) {
    return 'Could not unblock $label.';
  }

  @override
  String get blockedLoadFailed => 'Couldn’t load blocked accounts';

  @override
  String get commonRetry => 'Retry';

  @override
  String get accountPickerHelper =>
      'Exact username, or paste an account ID (acct_…).';

  @override
  String get accountPickerNoMatch =>
      'No account found with that exact username.';

  @override
  String get searchHint => 'Search people, communities, channels…';

  @override
  String get searchClear => 'Clear search';

  @override
  String get searchIntroTitle => 'Search metadata';

  @override
  String get searchIntroMessage =>
      'Find people by exact username, plus communities and channels by name. Message contents are end-to-end encrypted and never searchable on the server.';

  @override
  String get searchNoResultsTitle => 'No results';

  @override
  String get searchNoResultsMessage =>
      'Nothing matched. Usernames must match exactly, and message contents are never searchable.';

  @override
  String get searchNoOpenChannel => 'No channel you can open yet';

  @override
  String get searchJoinCommunity => 'Join the community to open it';

  @override
  String get searchTypeConversation => 'Conversation';

  @override
  String get searchTypeCommunity => 'Community';

  @override
  String get searchTypeChannel => 'Channel';

  @override
  String get searchTypeAccount => 'Account';

  @override
  String searchUnblockAccount(String label) {
    return 'Unblock $label';
  }

  @override
  String searchBlockAccount(String label) {
    return 'Block $label';
  }

  @override
  String searchBlocked(String label) {
    return '$label blocked.';
  }

  @override
  String get searchBlockFailed => 'Could not update the block.';

  @override
  String get inviteCreateSection => 'Create an invite';

  @override
  String get inviteMaxUses => 'Max uses';

  @override
  String inviteMaxUsesOption(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get inviteExpires => 'Expires';

  @override
  String durationDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get inviteCreate => 'Create invite';

  @override
  String get inviteEmptyTitle => 'No invites yet';

  @override
  String get inviteEmptyMessage =>
      'Invite codes you create appear here. Share them over a secure channel.';

  @override
  String get inviteLoadFailed =>
      'Your invites could not be loaded. Check the connection and try again.';

  @override
  String get inviteYourInvites => 'Your invites';

  @override
  String inviteUsesPill(int uses, int maxUses) {
    final intl.NumberFormat usesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String usesString = usesNumberFormat.format(uses);
    final intl.NumberFormat maxUsesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String maxUsesString = maxUsesNumberFormat.format(maxUses);

    return '$usesString/$maxUsesString';
  }

  @override
  String inviteUsesSemantics(int uses, int maxUses) {
    final intl.NumberFormat usesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String usesString = usesNumberFormat.format(uses);
    final intl.NumberFormat maxUsesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String maxUsesString = maxUsesNumberFormat.format(maxUses);

    return '$usesString of $maxUsesString uses';
  }

  @override
  String get inviteNeverExpires => 'Never expires';

  @override
  String inviteExpiresAt(String time) {
    return 'Expires $time';
  }

  @override
  String get inviteActions => 'Invite actions';

  @override
  String get inviteCodeCopied => 'Invite code copied.';

  @override
  String get inviteCopyCode => 'Copy code';

  @override
  String get profileThisInstance => 'this instance';

  @override
  String get profileTitle => 'Profile';

  @override
  String get profileYourAccount => 'Your account';

  @override
  String get profileSectionIdentity => 'Identity';

  @override
  String get profileNotAvailable => 'Not available';

  @override
  String get profileCurrentDevice => 'Current device';

  @override
  String get profileInstanceRole => 'Instance role';

  @override
  String get profileSectionEncryption => 'Encryption';

  @override
  String get profileEncryptionPending => 'Encryption identity pending';

  @override
  String get profileEncryptionPendingDetail =>
      'Safety-number verification and profile editing remain unavailable until the reviewed encryption engine ships.';

  @override
  String profileCopyLabel(String label) {
    return 'Copy $label';
  }

  @override
  String get navChats => 'Chats';

  @override
  String get navCommunities => 'Communities';

  @override
  String get shellNoConversationTitle => 'No conversation selected';

  @override
  String get shellNoConversationMessage =>
      'Pick a conversation from the list to read it here.';

  @override
  String get shellRestoring => 'Restoring this device…';

  @override
  String get shellResetTitle => 'Reset this device?';

  @override
  String get shellResetMessage =>
      'This device starts empty and must be linked again. Its current messages stay unreadable here; they are moved aside, not deleted, in case the key comes back.';

  @override
  String get shellResetConfirm => 'Reset';

  @override
  String get shellRecoveryTitle => 'Device recovery needed';

  @override
  String get shellRecoveryFallback =>
      'This device needs attention before it can be used.';

  @override
  String get shellRetryRestore => 'Retry restore';

  @override
  String get shellContinueToSignIn => 'Continue to sign in';

  @override
  String get shellResetDevice => 'Reset this device';

  @override
  String get communityNew => 'New community';

  @override
  String get communityEmptyTitle => 'No communities yet';

  @override
  String get communityEmptyMessage =>
      'Create a community to organize people around shared channels — private by default, encrypted everywhere.';

  @override
  String get communityOtherChannels => 'Other channels you are in';

  @override
  String get communityChannelSubtitle => 'Community channel';

  @override
  String get communityName => 'Community name';

  @override
  String communityNewChannelIn(String community) {
    return 'New channel in $community';
  }

  @override
  String get communityChannelName => 'Channel name';

  @override
  String get communityNoChannels => 'No channels yet';

  @override
  String communityChannelCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString channels',
      one: '1 channel',
    );
    return '$_temp0';
  }

  @override
  String get communityNewChannel => 'New channel';

  @override
  String get communityNoChannelsHint => 'Use + to create the first one.';

  @override
  String get communityNotMember => 'You are not a member yet';

  @override
  String get backupIntro =>
      'A backup holds this device\'s keys and message history, encrypted on this device. The server stores it but cannot read it. Restoring it on a new device needs the recovery code shown when you make it.';

  @override
  String get backupSectionStatus => 'Status';

  @override
  String get backupNone => 'No backup from this device yet';

  @override
  String backupLast(String time) {
    return 'Last backup $time';
  }

  @override
  String get backupReplacesPrevious =>
      'A new backup replaces the previous one and its code.';

  @override
  String get backupMake => 'Make a backup';

  @override
  String get backupMakeNew => 'Make a new backup';

  @override
  String get backupSaveCodeTitle => 'Save your recovery code';

  @override
  String get backupSaveCodeMessage =>
      'Anyone with this code can restore your messages. Keep it somewhere safe and offline. It is shown only now, and it stops working after it is used or when you make a new backup.';

  @override
  String get commonCopy => 'Copy';

  @override
  String get backupSavedIt => 'I saved it';

  @override
  String get backupRestoreMessage =>
      'Your messages and settings come back on this device. The backup holds no sign-in, so this device then joins your account as a new device.';

  @override
  String get backupRecoveryCode => 'Recovery code';

  @override
  String get backupRestore => 'Restore';

  @override
  String get deviceLinkTitle => 'Link a device';

  @override
  String get deviceLinkIntro =>
      'Generate a one-time code, enter it on the new device, then approve it here with the verification code the new device shows.';

  @override
  String get deviceLinkCreate => 'Create link';

  @override
  String get deviceLinkCreateNew => 'Create new link';

  @override
  String get deviceLinkQrSemantics =>
      'QR code containing the device link. Scan it with the new device.';

  @override
  String get deviceLinkQrHint =>
      'Scan it with the Veritra app on the new device, or type the link code below.';

  @override
  String get deviceLinkStatusLabel => 'STATUS';

  @override
  String deviceLinkState(String state) {
    String _temp0 = intl.Intl.selectLogic(
      state,
      {
        'pending': 'pending',
        'claimed': 'claimed',
        'approved': 'approved',
        'expired': 'expired',
        'other': '$state',
      },
    );
    return '$_temp0';
  }

  @override
  String get deviceLinkClaimedBy => 'Claimed by';

  @override
  String get deviceLinkRefreshStatus => 'Refresh status';

  @override
  String get deviceLinkApproveDevice => 'Approve device';

  @override
  String get deviceLinkApprove => 'Approve';

  @override
  String get deviceLinkApproveHint =>
      'Enter the 8-digit code shown on the new device. Never use a code you were sent or read out to you.';

  @override
  String get bannerQueued => 'Messages you send stay queued on this device.';

  @override
  String get bannerReconnecting => 'Reconnecting to the server…';

  @override
  String bannerLastSynced(String time) {
    return 'Last synced $time.';
  }

  @override
  String bannerOfflineSemantics(String detail) {
    return 'Offline. $detail';
  }

  @override
  String bannerConnectingSemantics(String detail) {
    return 'Connecting to the server. $detail';
  }

  @override
  String get bannerOffline => 'Offline';

  @override
  String get bannerConnecting => 'Connecting…';

  @override
  String get bannerPaused => 'Messages paused';

  @override
  String get bannerTryAgain => 'Try again';

  @override
  String get bannerRelink => 'Link this device again';

  @override
  String get bannerRestoreBackup => 'Restore from backup';

  @override
  String get bannerRelinkTitle => 'Link this device again?';

  @override
  String get bannerRelinkMessage =>
      'This signs this device out and deletes its messages and encryption keys. Link it again from another device afterwards. Messages that are only on this device cannot be recovered.';

  @override
  String get bannerRelinkConfirm => 'Delete and sign out';

  @override
  String get attachmentPickUnavailable =>
      'Files cannot be picked on this device.';

  @override
  String get attachmentSendTitle => 'Send this file?';

  @override
  String attachmentSendMessage(String name, String size) {
    return '$name ($size) is encrypted on this device before it is uploaded. Everyone in this conversation can open it.';
  }

  @override
  String get attachmentSend => 'Send';

  @override
  String get attachmentSendFailed => 'The file could not be sent.';

  @override
  String get attachmentDemoImagesOnly =>
      'In the demo, only images can be opened on this device.';

  @override
  String attachmentSaved(String fileName) {
    return 'Saved $fileName.';
  }

  @override
  String get attachmentDownloadFailed =>
      'The file could not be downloaded or decrypted.';

  @override
  String attachmentImageSemantics(String fileName, String size) {
    return 'Image $fileName, $size';
  }

  @override
  String attachmentFileSemantics(String fileName, String size) {
    return 'File $fileName, $size';
  }

  @override
  String get attachmentSave => 'Save';

  @override
  String get attachmentImageFailed =>
      'The image could not be downloaded or decrypted.';

  @override
  String get attachmentImageUnshowable => 'This image cannot be shown.';

  @override
  String fileSizeBytes(int size) {
    final intl.NumberFormat sizeNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String sizeString = sizeNumberFormat.format(size);

    return '$sizeString B';
  }

  @override
  String fileSizeKilobytes(int size) {
    final intl.NumberFormat sizeNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String sizeString = sizeNumberFormat.format(size);

    return '$sizeString KB';
  }

  @override
  String fileSizeMegabytes(double size) {
    final intl.NumberFormat sizeNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
            locale: localeName, decimalDigits: 1);
    final String sizeString = sizeNumberFormat.format(size);

    return '$sizeString MB';
  }

  @override
  String get chatListSearch => 'Search';

  @override
  String get chatListNewChat => 'New chat';

  @override
  String get chatListEmptyTitle => 'No conversations yet';

  @override
  String get chatListEmptyMessage =>
      'Start a direct message or create a group. Everything is end-to-end encrypted.';

  @override
  String get chatListUnmute => 'Unmute notifications';

  @override
  String get chatListMute => 'Mute notifications';

  @override
  String get chatListDetails => 'Conversation details';

  @override
  String get chatListMuted => 'Muted';

  @override
  String chatListDisappearingAfter(String duration) {
    return 'Disappearing after $duration';
  }

  @override
  String chatListUnreadSpoken(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString unread messages',
      one: '1 unread message',
    );
    return '$_temp0';
  }

  @override
  String chatListUnreadCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get chatListUnreadOverflow => '99+';

  @override
  String get conversationGroupChat => 'Group chat';

  @override
  String get conversationPrivateGroup => 'Private group';

  @override
  String get conversationEncrypted => 'Encrypted';

  @override
  String conversationDisappearing(String duration) {
    return 'Disappearing ($duration)';
  }

  @override
  String durationHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String durationChipDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d';
  }

  @override
  String durationChipHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h';
  }

  @override
  String durationChipMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String get safetyMarkTitle => 'Mark as verified?';

  @override
  String get safetyMarkMessage =>
      'Only do this after comparing the number with the other person in person or over a call you trust. Both of you must see exactly the same sixty digits.';

  @override
  String get safetyTheyMatch => 'They match';

  @override
  String get safetySaveFailed =>
      'The verification could not be saved. Try again.';

  @override
  String get safetyScanTitle => 'Scan safety code';

  @override
  String get safetyReadFailed =>
      'The safety number could not be read. Try again.';

  @override
  String get safetyMismatchTitle => 'Codes do not match';

  @override
  String get safetyMismatchMessage =>
      'This is not the same safety code. Make sure you scanned the code for this conversation and that both devices have received the latest messages, then try again. If it still does not match, do not treat this conversation as verified.';

  @override
  String get commonOk => 'OK';

  @override
  String get safetyCodesMatch => 'The codes match.';

  @override
  String get safetyCodesMatchVerified => 'The codes match. Marked as verified.';

  @override
  String get safetyTitle => 'Safety number';

  @override
  String get safetyGroupIntro =>
      'Every member of this group sees the same number. Compare it in person or scan each other\'s code.';

  @override
  String safetyPeerIntro(String peer) {
    return 'Compare this number with $peer in person, or scan each other\'s code.';
  }

  @override
  String get safetyUnavailable => 'Safety number unavailable';

  @override
  String get safetyUnavailableDetail =>
      'This device has not joined the encrypted group yet, or its group state could not be read.';

  @override
  String safetyDigitsSemantics(String groups) {
    return 'Safety number, twelve groups of five: $groups';
  }

  @override
  String get safetyQrSemantics =>
      'QR code of this safety number. The other person can scan it to compare.';

  @override
  String get safetyVerifiedDetail => 'You verified this number.';

  @override
  String get safetyChangedDetail =>
      'A device in this conversation was added, removed or replaced since you verified. Compare the new number again.';

  @override
  String get safetyChangedWhileComparing =>
      'The safety number changed while you were comparing it, so nothing was saved. Compare the new number again.';

  @override
  String get safetyUnverifiedDetail => 'Not verified yet.';

  @override
  String get safetyVerified => 'Verified';

  @override
  String get safetyChanged => 'Changed';

  @override
  String get safetyUnverified => 'Not verified';

  @override
  String get safetyScanTheirCode => 'Scan their code';

  @override
  String get safetyMarkVerified => 'Mark as verified';

  @override
  String get detailsNotFound => 'Conversation not found.';

  @override
  String get detailsConversationIdLabel => 'CONVERSATION ID';

  @override
  String get detailsCopyId => 'Copy ID';

  @override
  String get detailsConversationId => 'Conversation ID';

  @override
  String get detailsCreatedLabel => 'CREATED';

  @override
  String get detailsMuteDetail =>
      'Stops push for this conversation. Messages still arrive and still count as unread.';

  @override
  String get detailsSectionMembers => 'Members';

  @override
  String get detailsLoadingMembers => 'Loading members…';

  @override
  String get detailsMembersUnavailable => 'Member list unavailable';

  @override
  String get detailsMembersUnavailableDetail =>
      'The server did not return the roster for this conversation.';

  @override
  String get detailsAddMember => 'Add member';

  @override
  String get detailsAddMemberDetail => 'Look up an account by username';

  @override
  String get detailsAddMemberNoPermission => 'Moderator permission required';

  @override
  String get detailsMembershipNote =>
      'This is the server\'s membership record. Encrypted delivery follows a separate group update, so a change here is not by itself proof of who can decrypt new messages.';

  @override
  String get detailsSafetyDetail =>
      'Compare it with the other members to check that no one is intercepting this conversation.';

  @override
  String get detailsLeaveDm => 'Leave this conversation';

  @override
  String get detailsLeave => 'Leave conversation';

  @override
  String get detailsLeaveDetail =>
      'You stop receiving new messages. Messages already on other members\' devices are not deleted.';

  @override
  String get detailsSectionDisappearing => 'Disappearing messages';

  @override
  String get detailsDisappearingNote =>
      'When set, messages sent from then on are deleted from the server after this time window. Existing messages keep the timer they were sent with.';

  @override
  String get detailsRetentionOff => 'Off';

  @override
  String detailsRemoveTitle(String label) {
    return 'Remove $label?';
  }

  @override
  String get detailsRemoveMessage =>
      'They stop receiving new messages in this conversation. Messages they already received stay on their device, and encrypted delivery only changes once the group update is committed.';

  @override
  String get detailsRemoveConfirm => 'Remove';

  @override
  String detailsRemoved(String label) {
    return '$label removed from the conversation.';
  }

  @override
  String detailsRemoveFailed(String label) {
    return 'Could not remove $label.';
  }

  @override
  String get detailsLeaveTitle => 'Leave conversation?';

  @override
  String get detailsLeaveMessage =>
      'You stop receiving new messages and the conversation is removed from this device. Messages other members already received are not deleted.';

  @override
  String get detailsLeaveConfirm => 'Leave';

  @override
  String get detailsRetentionOffMessage =>
      'New messages will no longer disappear. Messages that already have a timer keep it.';

  @override
  String detailsRetentionOnMessage(String duration) {
    return 'Messages sent from now on will be deleted from the server $duration after they are sent. Existing messages are not affected.';
  }

  @override
  String get detailsRetentionOffTitle => 'Turn off disappearing messages?';

  @override
  String detailsRetentionOnTitle(String duration) {
    return 'Disappear after $duration?';
  }

  @override
  String get detailsApply => 'Apply';

  @override
  String get detailsAdd => 'Add';

  @override
  String detailsMemberAdded(String label) {
    return 'Added $label to the conversation. Encrypted delivery starts once the group update is committed.';
  }

  @override
  String get roleOwner => 'Owner';

  @override
  String get roleAdmin => 'Admin';

  @override
  String get roleModerator => 'Moderator';

  @override
  String get roleMember => 'Member';

  @override
  String get detailsYou => 'You';

  @override
  String detailsJoined(String date) {
    return 'Joined $date';
  }

  @override
  String detailsRemoveMember(String label) {
    return 'Remove $label';
  }

  @override
  String get detailsBlockedDetail =>
      'Their messages are hidden from this account until you unblock them.';

  @override
  String get detailsBlockDetail =>
      'The server stops delivering their messages to your account. They are not told, and messages already on your devices stay.';

  @override
  String get chatStatusMutedEncrypted => 'MUTED · ENCRYPTED';

  @override
  String get chatStatusEncrypted => 'ENCRYPTED';

  @override
  String get chatNoConversationMessage =>
      'Pick a conversation from the chat list.';

  @override
  String get chatEmptyTitle => 'No messages yet';

  @override
  String get chatEmptyMessage =>
      'Messages are stored as encrypted envelopes only the members can read.';

  @override
  String get chatJumpToLatest => 'Jump to latest';

  @override
  String chatReact(String reaction) {
    return 'React $reaction';
  }

  @override
  String get chatReply => 'Reply';

  @override
  String get chatCopyText => 'Copy text';

  @override
  String get chatEdit => 'Edit';

  @override
  String get chatDeleteForEveryone => 'Delete for everyone';

  @override
  String get chatDeleteTitle => 'Delete for everyone?';

  @override
  String get chatDeleteMessage =>
      'Members\' devices remove the text. The server never had it.';

  @override
  String get chatDelete => 'Delete';

  @override
  String get chatEditEmpty =>
      'Enter the new text, or delete the message instead.';

  @override
  String get chatEditTitle => 'Edit message';

  @override
  String get chatLoadFailed => 'Couldn’t load messages';

  @override
  String get chatReplyEarlier => 'Reply to an earlier message';

  @override
  String get chatReplyDeleted => 'Reply to a deleted message';

  @override
  String get chatLoadOlder => 'Load older messages';

  @override
  String get chatPendingSendingSemantics => 'Encrypted message sending';

  @override
  String get chatPendingTerminalSemantics =>
      'Encrypted message failed permanently. Copy or discard available.';

  @override
  String get chatPendingFailedSemantics =>
      'Encrypted message failed to send. Retry available.';

  @override
  String get chatPendingSending => 'Sending encrypted message';

  @override
  String get chatPendingTerminal => 'Message needs attention';

  @override
  String get chatPendingFailed => 'Send failed';

  @override
  String get chatDiscard => 'Discard';

  @override
  String get chatSenderYou => 'you';

  @override
  String get chatAttachmentUnopenable => 'This attachment cannot be opened.';

  @override
  String get chatMessageActions => 'Message actions';

  @override
  String chatDeletedSemantics(String sender) {
    return 'Deleted message from $sender';
  }

  @override
  String chatUnverifiedSemantics(String time) {
    return 'Message with an unverified sender, $time';
  }

  @override
  String chatMessageSemantics(String sender, String time, String text) {
    return 'Message from $sender, $time: $text';
  }

  @override
  String chatAttachmentSemantics(String sender, String time) {
    return 'Attachment from $sender, $time';
  }

  @override
  String chatEncryptedSemantics(String sender, String time) {
    return 'Encrypted message from $sender, $time';
  }

  @override
  String get chatMessageDeleted => 'Message deleted';

  @override
  String get chatSenderUnverified =>
      'Sender could not be verified. Message hidden.';

  @override
  String get chatMessageUnsupported =>
      'This message needs a newer version of Veritra';

  @override
  String get chatMessageInvalid => 'A message could not be read';

  @override
  String get chatMessageUndecryptable => 'Couldn\'t unlock this message';

  @override
  String get chatMessageWelcomeUnavailable =>
      'Couldn\'t join this chat. Ask a member to add you again.';

  @override
  String chatReactionCount(String reaction, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$reaction $countString';
  }

  @override
  String get chatEdited => 'edited';

  @override
  String get chatTickSent => 'Sent';

  @override
  String get chatTickDelivered => 'Delivered';

  @override
  String get chatTickRead => 'Read';

  @override
  String chatTypingOne(String name) {
    return '$name is typing…';
  }

  @override
  String chatTypingTwo(String first, String second) {
    return '$first and $second are typing…';
  }

  @override
  String get chatTypingMany => 'Several people are typing…';

  @override
  String chatReplyingTo(String preview) {
    return 'Replying to: $preview';
  }

  @override
  String get chatCancelReply => 'Cancel reply';

  @override
  String get chatSendingFile => 'Sending file';

  @override
  String get chatAttachFile => 'Attach a file';

  @override
  String get chatComposerHint => 'Message';

  @override
  String chatComposerCounter(int length, int max) {
    final intl.NumberFormat lengthNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String lengthString = lengthNumberFormat.format(length);
    final intl.NumberFormat maxNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String maxString = maxNumberFormat.format(max);

    return '$lengthString / $maxString';
  }

  @override
  String get chatPausedNotice =>
      'Sending is paused here: the server rejected an encryption update for this conversation. Other conversations still work.';

  @override
  String get chatRemovalHoldNotice =>
      'Your message waits until the removed member\'s encryption update finishes, then sends.';

  @override
  String get chatNoPeerReadOnly =>
      'No one else in this conversation can add this device back, so its history is read-only here. Start a new conversation to send messages.';

  @override
  String get chatAttachment => 'Attachment';

  @override
  String chatAttachmentOne(String name) {
    return 'Attachment: $name';
  }

  @override
  String chatAttachmentMany(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Attachments: $name and $countString more';
  }

  @override
  String get demoBannerLabel => 'Demo build · unreviewed encryption';

  @override
  String demoBannerNotice(String label) {
    return '$label. Not for real conversations.';
  }

  @override
  String dateTimeJoined(String date, String time) {
    return '$date · $time';
  }

  @override
  String get backupErrorNetwork =>
      'The server could not be reached. Try again; the restore continues where it stopped.';

  @override
  String get backupErrorNotFound =>
      'This recovery code is unknown, expired or already used.';

  @override
  String get backupErrorBusy =>
      'This backup is being downloaded elsewhere. Try again in a few minutes.';

  @override
  String get backupErrorWrongKey =>
      'This recovery code does not open the backup.';

  @override
  String get backupErrorCorrupt =>
      'The backup is damaged and cannot be restored.';

  @override
  String get backupErrorDeviceNotEmpty =>
      'This device already has an account. Sign out and reset it before restoring a backup.';

  @override
  String get backupErrorTooLarge =>
      'The backup is larger than this app supports.';

  @override
  String get backupErrorStorage => 'This device could not store the backup.';

  @override
  String get backupRestoredLinkToFinish =>
      'Your messages and settings are restored on this device. To finish, link this device from another device that is signed in to your account. If you lost every device, use “Lost all your devices?” with your password and recovery key.';

  @override
  String get syncErrorCursorExpired =>
      'This device was away longer than the server keeps updates. Restore a backup or link this device again.';

  @override
  String get syncErrorControlMissing =>
      'An encryption update for a conversation is missing or damaged. Messages are paused so none are skipped.';

  @override
  String get syncErrorMlsState =>
      'This device could not update its encryption state. Messages are paused so none are skipped.';

  @override
  String get syncErrorUndecryptable =>
      'A message could not be read on this device. Messages are paused so none are skipped.';

  @override
  String get syncErrorUnsupportedEvent =>
      'The server sent an update this app version does not know. Update the app, then try again.';

  @override
  String get syncErrorCryptoUnavailable =>
      'Encryption is unavailable in this build, so encrypted updates cannot be applied.';

  @override
  String get syncErrorStopped => 'Sync stopped. Try again.';

  @override
  String get syncErrorLocalStorage =>
      'This device could not read or write its local storage. Messages are paused so none are skipped. Free up space or restart the app, then try again.';

  @override
  String get syncErrorRecordLimit =>
      'A conversation has grown too large for this device to store its encryption data. Messages are paused so none are skipped. Leave that conversation to continue.';

  @override
  String get syncErrorRecordLimitDevice =>
      'This device\'s encryption data has grown too large to store. Messages are paused so none are skipped. Link this device again to continue.';

  @override
  String syncErrorRecordLimitNamed(String title) {
    return '\"$title\" has grown too large for this device to store its encryption data. Messages are paused so none are skipped. Leave that conversation to continue.';
  }

  @override
  String bannerLeaveNamed(String title) {
    return 'Leave \"$title\"';
  }

  @override
  String bannerLeaveNamedTitle(String title) {
    return 'Leave \"$title\"?';
  }

  @override
  String get syncErrorStorageBusy =>
      'This device\'s storage is busy or full. Sync will try again shortly.';

  @override
  String get apiErrorSessionInvalid =>
      'Your session is no longer valid. Sign in again.';

  @override
  String get apiErrorInvalidCredentials =>
      'Sign-in failed. Check your username and password.';

  @override
  String get apiErrorRecentAuth =>
      'Confirm your password before this sensitive action.';

  @override
  String get apiErrorDeviceNotLinked =>
      'This device must be linked before password sign-in.';

  @override
  String get apiErrorForbidden => 'You do not have permission to do that.';

  @override
  String get apiErrorNotFound =>
      'That item was not found. It may have been removed.';

  @override
  String get apiErrorAlreadySetup =>
      'This server already has an owner. Sign in or join with an invite instead.';

  @override
  String get apiErrorLastOwner =>
      'Transfer ownership before disabling the last owner account.';

  @override
  String get apiErrorWeakPassword => 'Password must be 12–72 characters.';

  @override
  String get apiErrorInvalidInvite =>
      'That invite code is not valid, has expired, or has already been used up.';

  @override
  String get apiErrorInvalidDeviceLink =>
      'That link code is not valid or has expired. Generate a new one on your linked device.';

  @override
  String get apiErrorTranscriptMismatch =>
      'The locally verified device credentials changed. Generate a new link and compare both devices again.';

  @override
  String get apiErrorInvalidDeviceName => 'That device name is not valid.';

  @override
  String get apiErrorInvalidName => 'That name is not valid.';

  @override
  String get apiErrorInvalidMaxUses => 'The invite use limit is not valid.';

  @override
  String get apiErrorInvalidExpiry => 'That expiry time is not valid.';

  @override
  String get apiErrorInvalidConversationKind =>
      'The server rejected this conversation type.';

  @override
  String get apiErrorInvalidRetention =>
      'That disappearing-message duration is not supported.';

  @override
  String get apiErrorInvalidRole => 'That member role is not valid.';

  @override
  String get apiErrorAccountRequired => 'Choose an account to add.';

  @override
  String get apiErrorUploadTooLarge => 'That file is too large to upload.';

  @override
  String get apiErrorKeyPackageRefused =>
      'The server refused this build’s encryption keys. A client with production encryption support is required.';

  @override
  String get apiErrorStorage =>
      'The server had a storage problem. Try again shortly.';

  @override
  String get apiErrorStorageFull =>
      'The server is out of storage for this account. Delete older attachments or ask the administrator for more space.';

  @override
  String get apiErrorBlobIntegrity =>
      'The encrypted attachment could not be verified. Discard it and try again.';

  @override
  String get apiErrorSetupToken =>
      'The setup token is missing or wrong. Use the one the server printed when it started (the demo keeps it in data/demo/setup-token).';

  @override
  String get apiErrorDraining => 'The server is restarting. Try again shortly.';

  @override
  String get apiErrorIdempotencyConflict =>
      'This message was already submitted with different data. Discard it and compose a new message.';

  @override
  String get apiErrorMessageExpired => 'That message has expired.';

  @override
  String get apiErrorRecoveryInProgress =>
      'Another restore is already downloading this backup. Try again shortly.';

  @override
  String get apiErrorWriteRateLimited =>
      'You are sending a lot right now. Wait a minute and try again.';

  @override
  String get apiErrorServerStorageLow =>
      'The server is almost out of space, so new messages and uploads are paused. Ask the administrator to free some up.';

  @override
  String get apiErrorDeviceLimit =>
      'This account already has the most devices allowed. Remove one in Settings first.';

  @override
  String get apiErrorDeviceLinkLimit =>
      'Too many device links are waiting. Finish or cancel one first.';

  @override
  String get apiErrorConversationLimit =>
      'You have reached the most conversations allowed on this server. Leave or delete one first.';

  @override
  String get apiErrorConversationMemberLimit => 'This conversation is full.';

  @override
  String get apiErrorConflict =>
      'This changed on the server in the meantime. Refresh and try again.';

  @override
  String get apiErrorRateLimited =>
      'Too many attempts. Wait a moment and try again.';

  @override
  String get apiErrorEncryption =>
      'The server rejected the encrypted data from this build.';

  @override
  String get apiErrorServer => 'The server had a problem. Try again shortly.';

  @override
  String get apiErrorInvalidRequest =>
      'The server rejected the request. Check your input and try again.';

  @override
  String get errorUnexpectedResponse =>
      'The server returned an unexpected response.';

  @override
  String get errorConversationPaused =>
      'Sending is paused in this conversation.';

  @override
  String get errorOutboxFull =>
      'Your encrypted message queue is full. Send or discard a pending message before composing another.';

  @override
  String get errorCryptoStateFormatUnsupported =>
      'This device\'s encrypted data was saved in a format this version of the app cannot read. Link this device again to keep messaging.';

  @override
  String get errorConversationTooLarge =>
      'This conversation has grown too large for this device to store its encryption data. Nothing was changed. You can leave the conversation to keep the others working.';

  @override
  String get errorCryptoRecordLimit =>
      'This device\'s encryption data has grown too large to store. Nothing was changed. Link this device again to keep messaging.';

  @override
  String get errorConversationPausedDetail =>
      'Sending is paused in this conversation because the server rejected an encryption update. Other conversations still work.';

  @override
  String get errorEncryptionUnavailable =>
      'This build does not include the production encryption engine yet, so this action is unavailable.';

  @override
  String get errorActionUnavailable =>
      'This action is unavailable in this build.';

  @override
  String get errorGeneric => 'Something went wrong. Please try again.';

  @override
  String get errorTimeout => 'The server took too long to respond. Try again.';

  @override
  String get errorUnreachable =>
      'Could not reach the server. Check the instance URL and your connection.';

  @override
  String get probeChecking => 'Checking the server…';

  @override
  String get probeReached => 'Veritra server reached.';

  @override
  String probeConnectedTo(String name) {
    return 'Connected to $name.';
  }

  @override
  String get probeInvalidOrigin =>
      'Enter an HTTPS server origin, for example https://chat.example.org.';

  @override
  String get probeInsecure =>
      'Veritra requires HTTPS. Put a self-hosted server behind TLS with a trusted certificate or Caddy.';

  @override
  String get probeDnsFailure =>
      'That address could not be found. Check the hostname and try again.';

  @override
  String get probeTlsFailure =>
      'The server certificate was not accepted. Use a trusted certificate or configure Caddy TLS.';

  @override
  String get probeTimedOut =>
      'The server took too long to respond. Check the address and connection.';

  @override
  String get probeNotVeritra =>
      'That address does not look like a Veritra server.';

  @override
  String get probeUnavailable =>
      'Could not reach the server. Check the address and your connection.';

  @override
  String get outboxSendFailed =>
      'This encrypted message could not be sent. Copy it or discard it.';

  @override
  String get recoveryRestoreFailed =>
      'This device could not restore its encrypted session. Retry or continue to sign in without clearing local data.';

  @override
  String get recoveryProfileLocked =>
      'This profile is already open in another Veritra window. Close that window, then retry.';

  @override
  String get recoveryKeyUnavailable =>
      'This device could not read its secure storage. Unlock the device and retry. Your messages are kept.';

  @override
  String get recoveryKeyMissing =>
      'The key that protects this device\'s messages is missing or does not match. Nothing has been deleted. You can retry, or reset this device and link it again.';

  @override
  String get recoveryResetFailed =>
      'The reset did not finish. Nothing was deleted. Retry.';

  @override
  String get recoveryUpgradeFailed =>
      'This device could not update its message storage for this version of Veritra, for example because the device is full. Nothing has been changed or deleted. Free up some space, then retry.';

  @override
  String get recoveryUpgradeStillFull =>
      'This device still could not update its message storage. Nothing has been changed or deleted. Free up more space and retry, or reset this device and link it again.';

  @override
  String get recoveryUpgradeError =>
      'This device could not update its message storage for this version of Veritra. Nothing has been changed or deleted. Retry. If it keeps failing, you can reset this device and link it again.';

  @override
  String get recoveryStorageDamaged =>
      'This device\'s message storage is damaged and cannot be read, so sync has stopped. Nothing has been deleted. Retry, or reset this device and link it again.';

  @override
  String get recoverySqliteFeatureMissing =>
      'This build of Veritra cannot open its message storage: the database engine lacks encryption or search support. Your data has not been changed or deleted. Install a Veritra build that supports them.';

  @override
  String get errorPasswordLoginNeedsLink =>
      'Password login requires this device to be linked first.';

  @override
  String get attachmentSendFailedState => 'The attachment could not be sent.';

  @override
  String get errorRelinkRequired => 'This device must be linked again.';

  @override
  String get pushTestSent =>
      'Test sent. A notification should arrive within a minute.';

  @override
  String get pushTestGone =>
      'The push provider no longer accepts this device. Registering again.';

  @override
  String get pushTestRejected =>
      'The push provider did not accept the test. Try again later.';

  @override
  String get pushTestRateLimited =>
      'Wait a minute before sending another test.';

  @override
  String get pushTestNotRegistered =>
      'This device is not registered for push yet.';

  @override
  String get pushTestFailed => 'The test could not be sent.';

  @override
  String errorServerNotAllowed(String url) {
    return 'This build does not allow the server address $url. Use an https:// server origin.';
  }

  @override
  String get muteEightHours => 'For 8 hours';

  @override
  String get muteOneWeek => 'For 1 week';

  @override
  String get muteAlways => 'Until I turn it back on';

  @override
  String get muteStatusAlways => 'Muted until you turn it back on.';

  @override
  String muteStatusUntil(String time) {
    return 'Muted until $time.';
  }

  @override
  String get chatMoreReactions => 'More reactions';

  @override
  String get emojiSearchHint => 'Search by name, or type or paste an emoji';

  @override
  String emojiUseTyped(String emoji) {
    return 'Use $emoji';
  }

  @override
  String get emojiNoResults =>
      'No emoji with that name. Type or paste one instead.';

  @override
  String get emojiGroupSmileys => 'Smileys';

  @override
  String get emojiGroupPeople => 'People';

  @override
  String get emojiGroupAnimals => 'Animals and nature';

  @override
  String get emojiGroupFood => 'Food and drink';

  @override
  String get emojiGroupTravel => 'Travel and places';

  @override
  String get emojiGroupActivities => 'Activities';

  @override
  String get emojiGroupObjects => 'Objects';

  @override
  String get emojiGroupSymbols => 'Symbols';

  @override
  String get emojiGroupFlags => 'Flags';

  @override
  String get searchModeMessages => 'Messages';

  @override
  String get searchModePeople => 'People and communities';

  @override
  String get searchMessagesHint => 'Search messages on this device…';

  @override
  String get searchMessagesIntroTitle => 'Search this device';

  @override
  String get searchMessagesIntroMessage =>
      'Finds text in the messages this device holds. The search happens here and is never sent to the server.';

  @override
  String get searchMessagesNoResultsTitle => 'No messages found';

  @override
  String get searchMessagesNoResultsMessage =>
      'Nothing on this device matches. Messages that expired or were deleted are gone from search too.';

  @override
  String get searchMessagesFailed =>
      'The search could not read the local database.';

  @override
  String attachmentTooLarge(String fileName, String limit) {
    return '$fileName is larger than this server allows ($limit).';
  }

  @override
  String attachmentEmptyFile(String fileName) {
    return '$fileName is empty and cannot be sent.';
  }

  @override
  String attachmentTooMany(int count) {
    return 'At most $count files can wait to be sent together.';
  }

  @override
  String attachmentRemove(String fileName) {
    return 'Remove $fileName';
  }

  @override
  String get attachmentOpenFailed =>
      'The file could not be opened. This device may have no app for it.';

  @override
  String get attachmentDropHint => 'Drop files to attach them';

  @override
  String attachmentSentCount(int done, int total) {
    return 'Sending file $done of $total';
  }

  @override
  String get settingsAdmin => 'Administration';

  @override
  String get settingsAdminDetail => 'Accounts and audit log';

  @override
  String get adminAccountsTab => 'Accounts';

  @override
  String get adminAuditTab => 'Audit log';

  @override
  String get adminSuspend => 'Suspend';

  @override
  String get adminUnsuspend => 'Reactivate';

  @override
  String get adminSuspendTitle => 'Suspend this account?';

  @override
  String adminSuspendMessage(String username) {
    return '@$username will be signed out everywhere and cannot sign in until you reactivate the account.';
  }

  @override
  String get adminUnsuspendTitle => 'Reactivate this account?';

  @override
  String adminUnsuspendMessage(String username) {
    return '@$username will be able to sign in again.';
  }

  @override
  String get adminSuspendedPill => 'Suspended';

  @override
  String adminAccountSummary(String role, int devices, String storage) {
    String _temp0 = intl.Intl.pluralLogic(
      devices,
      locale: localeName,
      other: '$devices devices',
      one: '1 device',
    );
    return '$role · $_temp0 · $storage';
  }

  @override
  String adminEventBy(String actor) {
    return 'By $actor';
  }

  @override
  String get adminLoadMore => 'Load more';

  @override
  String get adminNoAccounts => 'No accounts';

  @override
  String get adminNoEvents => 'No audit events yet';

  @override
  String requestsSection(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Requests ($countString)';
  }

  @override
  String get requestsTitle => 'Message request';

  @override
  String requestFrom(String name) {
    return '$name wants to message you';
  }

  @override
  String get requestUnknownSender => 'Someone you do not know';

  @override
  String get requestExplanation =>
      'Nothing from this person is shown or downloaded, and they cannot see that you read anything, until you accept.';

  @override
  String get requestAccept => 'Accept';

  @override
  String get requestBlock => 'Block';

  @override
  String get requestDelete => 'Delete';

  @override
  String get requestBlockTitle => 'Block this person?';

  @override
  String requestBlockMessage(String name) {
    return '$name will no longer be able to message you, and this conversation will be removed.';
  }

  @override
  String get requestDeleteTitle => 'Delete this request?';

  @override
  String get requestDeleteMessage =>
      'The conversation is removed from this device. The sender is not told.';

  @override
  String get w8PinnedMessage => 'Pinned message';

  @override
  String get w8Pin => 'Pin message';

  @override
  String get w8Unpin => 'Unpin message';

  @override
  String w8PinDays(int days) {
    return 'Pin for $days days';
  }

  @override
  String get w8Forward => 'Forward';

  @override
  String get w8Forwarded => 'Forwarded';

  @override
  String get w8ForwardedMany => 'Forwarded many times';

  @override
  String get w8Star => 'Star on this device';

  @override
  String get w8Unstar => 'Remove star';

  @override
  String get w8DeleteForMe => 'Delete for me on this device';

  @override
  String get w8Archive => 'Archive on this device';

  @override
  String get w8Unarchive => 'Unarchive';

  @override
  String get w8PinChat => 'Pin chat on this device';

  @override
  String get w8UnpinChat => 'Unpin chat';

  @override
  String get w8ArchivedChats => 'Archived chats';

  @override
  String get w8Chats => 'Chats';

  @override
  String get w8MentionsMuted => 'Mentions in muted chats';

  @override
  String get w8MentionsMutedDetail =>
      'Notify when a member mentions you, even in a muted chat.';

  @override
  String get w8HiddenSpoiler => 'Message containing a hidden spoiler';

  @override
  String get w8StarredMessages => 'Starred messages on this device';

  @override
  String get k2CopiedHistory => 'Copied history · device snapshot';

  @override
  String get k2HistoryOnlyTitle => 'Copied history';

  @override
  String get k2HistoryOnlyNotice =>
      'Copied from your other device. Read-only: this device is not a member of this conversation, so nothing can be sent here.';

  @override
  String get k2HistoryUntitled => 'Earlier conversation';

  @override
  String get k2HistoryOtherMember => 'Another member';

  @override
  String get k2HistoryAttachment => 'Attachment, not downloaded on this device';

  @override
  String get k2HistoryEmpty =>
      'No copied messages are left in this conversation.';

  @override
  String get settingsRecoveryKey => 'Recovery key';

  @override
  String get recoveryUnavailableHere =>
      'Account recovery is not available in this build.';

  @override
  String get recoveryKeyTitle => 'Recovery key';

  @override
  String get recoveryKeyIntro =>
      'If you lose every device, your password and this recovery key get your account back on a new device. Keep the key on paper, somewhere safe. It does not bring back your message history.';

  @override
  String recoveryKeyStatusSet(String date) {
    return 'Set on $date';
  }

  @override
  String get recoveryKeyStatusNotSet => 'Not set';

  @override
  String get recoveryKeyStatusUnknown => 'Status unavailable right now';

  @override
  String get recoveryKeyStatusOff =>
      'This server has account recovery turned off';

  @override
  String get recoveryKeyCreate => 'Create a recovery key';

  @override
  String get recoveryKeyReplace => 'Replace the recovery key';

  @override
  String get recoveryKeyReplaceNote =>
      'A new key replaces the old one at once and cancels any recovery that is waiting.';

  @override
  String get recoveryKeyShowTitle => 'Write down your recovery key';

  @override
  String get recoveryKeyShowDetail =>
      'Write these 52 characters on paper and keep it safe. Anyone with this key and your password can take over your account. Do not take a screenshot or keep it in a chat.';

  @override
  String get recoveryKeyWritten => 'I wrote it down';

  @override
  String get recoveryKeyConfirmTitle => 'Type your recovery key';

  @override
  String get recoveryKeyConfirmDetail =>
      'Type the whole key from your paper to check it. Dashes and spaces do not matter.';

  @override
  String get recoveryKeyField => 'Recovery key';

  @override
  String get recoveryKeyRequired => 'Enter the recovery key.';

  @override
  String get recoveryKeyMismatch =>
      'That is not the key shown. Check your paper and try again.';

  @override
  String get recoveryKeyShowAgain => 'Show the key again';

  @override
  String get recoveryKeySave => 'Save recovery key';

  @override
  String get recoveryKeySaved => 'Recovery key saved.';

  @override
  String get recoveryFollowUpTitle => 'Finish recovering your account';

  @override
  String get recoveryFollowUpKeyDetail =>
      'Your account is back on this device, and your other devices were signed out. Before your chats open, replace your recovery key and then your password: someone else may know them.';

  @override
  String get recoveryFollowUpPasswordDetail =>
      'Last step: choose a new password.';

  @override
  String get connectLostAllDevices => 'Lost all your devices?';

  @override
  String get recoveryStartTitle => 'Recover your account';

  @override
  String get recoveryStartDetail =>
      'Use this only if you lost every device signed in to your account. You need your password and your recovery key. If any of your devices was used in the last 7 days, this device joins only after 7 days, and those devices can cancel it. Your message history comes back only from a backup restored on this device.';

  @override
  String get recoveryStartSubmit => 'Start recovery';

  @override
  String get recoveryKeyUnreadable =>
      'That recovery key is not valid. Check it for a typo.';

  @override
  String get recoveryClaimRefused =>
      'The password or recovery key is wrong, the server address differs from the one you wrote down, or this account cannot be recovered.';

  @override
  String get recoveryBackupOtherAccount =>
      'The backup restored on this device belongs to another account or server. Recover that account here, or reset this device first.';

  @override
  String get recoverySignedInAlready => 'This device is already signed in.';

  @override
  String get recoveryAlreadyPending =>
      'A recovery is already waiting on this device.';

  @override
  String get recoveryWaitingTitle => 'Recovery is waiting';

  @override
  String recoveryWaitingDetail(String date) {
    return 'This device joins your account after $date. The app checks by itself while it is open. Your other devices can cancel this recovery.';
  }

  @override
  String get recoveryReadyDetail => 'The wait is over. Check now to finish.';

  @override
  String get recoveryCheckNow => 'Check now';

  @override
  String get recoveryAbandon => 'Stop recovery';

  @override
  String get recoveryAbandonTitle => 'Stop recovery on this device?';

  @override
  String get recoveryAbandonMessage =>
      'This device forgets the request. To try again you need your password and recovery key again.';

  @override
  String get recoveryRequestEnded =>
      'This recovery was cancelled or has expired. A password or recovery key change, or one of your devices, cancels it. You can start again.';

  @override
  String get recoveryLoginTitle => 'Sign in to finish';

  @override
  String get recoveryLoginDetail =>
      'Your account was recovered on this device, but the answer did not arrive. Enter your password to finish.';

  @override
  String get recoveryLoginSubmit => 'Sign in';

  @override
  String recoveryAccountLabel(String username) {
    return 'Account: $username';
  }

  @override
  String recoveryPendingNotice(String device, String date) {
    return 'Someone is recovering your account on “$device”, finishing $date. Not you? Cancel, or change your password or recovery key.';
  }

  @override
  String get recoveryPendingCancel => 'Cancel recovery';

  @override
  String get recoveryCancelTitle => 'Cancel this recovery?';

  @override
  String get recoveryCancelMessage =>
      'The new device will not join your account. If it was not you, change your password too.';

  @override
  String get recoveryCancelled => 'Recovery cancelled.';

  @override
  String get passwordLeakNotice =>
      'Your password was used with a wrong recovery key many times. Change your password.';

  @override
  String get passwordLeakDismiss => 'Dismiss';

  @override
  String get apiErrorRecoveryNotConfigured =>
      'This server has not turned on account recovery.';

  @override
  String get apiErrorRecoveryBackoff =>
      'Too many attempts. Wait a while, then try again.';

  @override
  String get apiErrorInvalidRecoveryKey =>
      'The server refused this recovery key. Create a new one.';

  @override
  String get recoveryAlreadyEnded =>
      'This recovery had already ended or was replaced by a newer one.';

  @override
  String get apiErrorPasswordUnchanged =>
      'Choose a password different from your current one.';

  @override
  String get recoveryKeyServerAddress =>
      'Write down the server address with it:';

  @override
  String recoveryKeyOriginMismatch(String current, String origin) {
    return 'This device uses $current, but the server\'s recovery address is $origin. Recovery works only from $origin.';
  }
}
