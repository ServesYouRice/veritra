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
}
