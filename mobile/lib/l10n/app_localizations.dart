import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Dismisses a dialog without doing anything.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Proceeds from a dialog step.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// Confirms creating a new item from a dialog.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get commonCreate;

  /// Tooltip for a button that reloads the current screen.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get commonRefresh;

  /// Button or tooltip that revokes a device or invite.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get commonRevoke;

  /// Chat list timestamp for activity on the previous calendar day.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get listTimeYesterday;

  /// Inline error under an empty community or channel name field.
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get validationNameRequired;

  /// Inline error when a community or channel name exceeds the server limit.
  ///
  /// In en, this message translates to:
  /// **'That name is too long.'**
  String get validationNameTooLong;

  /// Inline error under an empty group name field.
  ///
  /// In en, this message translates to:
  /// **'Enter a group name.'**
  String get validationGroupNameRequired;

  /// Inline error when a group name exceeds the server limit.
  ///
  /// In en, this message translates to:
  /// **'That group name is too long.'**
  String get validationGroupNameTooLong;

  /// Inline composer error when a message exceeds the maximum length.
  ///
  /// In en, this message translates to:
  /// **'Too long to send. Shorten it or split it into several messages.'**
  String get validationMessageTooLong;

  /// Explains why the attachment button is disabled outside demo builds.
  ///
  /// In en, this message translates to:
  /// **'Attachments need the reviewed encryption engine'**
  String get gatedAttachmentsUnavailable;

  /// Cancel button of a confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get confirmCancel;

  /// Appearance option: follow the device light/dark setting.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceSystem;

  /// Appearance option: always light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// Appearance option: always dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// Legal line in the About dialog and license page.
  ///
  /// In en, this message translates to:
  /// **'Free software under the GNU Affero General Public License, version 3 or later ({license}). Source code: {url}'**
  String aboutLegalese(String license, String url);

  /// Settings row that opens the About dialog.
  ///
  /// In en, this message translates to:
  /// **'About {productName}'**
  String aboutTitle(String productName);

  /// Subtitle of the About row.
  ///
  /// In en, this message translates to:
  /// **'Version {version} · {license}'**
  String aboutVersion(String version, String license);

  /// Settings row that opens the license page.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get aboutLicenses;

  /// Subtitle of the open-source licenses row.
  ///
  /// In en, this message translates to:
  /// **'Notices for Veritra and its components'**
  String get aboutLicensesDetail;

  /// Title of the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsSectionAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsSectionAccount;

  /// No description provided for @settingsSectionDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get settingsSectionDevices;

  /// No description provided for @settingsSectionSafety.
  ///
  /// In en, this message translates to:
  /// **'Safety'**
  String get settingsSectionSafety;

  /// No description provided for @settingsSectionYourData.
  ///
  /// In en, this message translates to:
  /// **'Your data'**
  String get settingsSectionYourData;

  /// No description provided for @settingsSectionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsSectionNotifications;

  /// No description provided for @settingsSectionSession.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get settingsSectionSession;

  /// No description provided for @settingsSectionRecovery.
  ///
  /// In en, this message translates to:
  /// **'Recovery'**
  String get settingsSectionRecovery;

  /// No description provided for @settingsSectionComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get settingsSectionComingSoon;

  /// No description provided for @settingsSectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsSectionAppearance;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsSectionAbout;

  /// No description provided for @settingsSectionDangerZone.
  ///
  /// In en, this message translates to:
  /// **'Danger zone'**
  String get settingsSectionDangerZone;

  /// No description provided for @settingsAccountId.
  ///
  /// In en, this message translates to:
  /// **'Account ID'**
  String get settingsAccountId;

  /// No description provided for @settingsAccountIdUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get settingsAccountIdUnknown;

  /// No description provided for @settingsCopyAccountId.
  ///
  /// In en, this message translates to:
  /// **'Copy account ID'**
  String get settingsCopyAccountId;

  /// Snackbar after copying a value.
  ///
  /// In en, this message translates to:
  /// **'{label} copied.'**
  String settingsCopied(String label);

  /// No description provided for @settingsChangePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get settingsChangePassword;

  /// No description provided for @settingsChangePasswordDetail.
  ///
  /// In en, this message translates to:
  /// **'Ends sessions on your other devices'**
  String get settingsChangePasswordDetail;

  /// No description provided for @settingsInvites.
  ///
  /// In en, this message translates to:
  /// **'Invites'**
  String get settingsInvites;

  /// No description provided for @settingsInvitesDetail.
  ///
  /// In en, this message translates to:
  /// **'Create codes so others can join'**
  String get settingsInvitesDetail;

  /// No description provided for @settingsLinkDevice.
  ///
  /// In en, this message translates to:
  /// **'Link a new device'**
  String get settingsLinkDevice;

  /// No description provided for @settingsLinkDeviceDetail.
  ///
  /// In en, this message translates to:
  /// **'Generate a pairing code for another device'**
  String get settingsLinkDeviceDetail;

  /// No description provided for @settingsLoadingDevices.
  ///
  /// In en, this message translates to:
  /// **'Loading devices…'**
  String get settingsLoadingDevices;

  /// No description provided for @settingsBlockedAccounts.
  ///
  /// In en, this message translates to:
  /// **'Blocked accounts'**
  String get settingsBlockedAccounts;

  /// No description provided for @settingsBlockedNone.
  ///
  /// In en, this message translates to:
  /// **'No one is blocked'**
  String get settingsBlockedNone;

  /// How many accounts are blocked.
  ///
  /// In en, this message translates to:
  /// **'{count} blocked'**
  String settingsBlockedCount(int count);

  /// No description provided for @settingsBlockedReview.
  ///
  /// In en, this message translates to:
  /// **'Review and undo blocks'**
  String get settingsBlockedReview;

  /// No description provided for @settingsExport.
  ///
  /// In en, this message translates to:
  /// **'Export account data'**
  String get settingsExport;

  /// No description provided for @settingsExportDetail.
  ///
  /// In en, this message translates to:
  /// **'Save encrypted messages and account metadata locally'**
  String get settingsExportDetail;

  /// No description provided for @settingsExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Account export failed.'**
  String get settingsExportFailed;

  /// No description provided for @settingsExportSaved.
  ///
  /// In en, this message translates to:
  /// **'Account export saved locally.'**
  String get settingsExportSaved;

  /// No description provided for @settingsAllowNotifications.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications'**
  String get settingsAllowNotifications;

  /// No description provided for @settingsAllowNotificationsDetail.
  ///
  /// In en, this message translates to:
  /// **'Notifications say only that a message arrived.'**
  String get settingsAllowNotificationsDetail;

  /// No description provided for @settingsPushProvider.
  ///
  /// In en, this message translates to:
  /// **'Push provider'**
  String get settingsPushProvider;

  /// No description provided for @settingsPushProviderDetail.
  ///
  /// In en, this message translates to:
  /// **'Choose an Android UnifiedPush provider'**
  String get settingsPushProviderDetail;

  /// No description provided for @settingsTestPush.
  ///
  /// In en, this message translates to:
  /// **'Send a test notification'**
  String get settingsTestPush;

  /// No description provided for @settingsTestPushUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Available once this device is registered'**
  String get settingsTestPushUnavailable;

  /// Which push service this device registered with.
  ///
  /// In en, this message translates to:
  /// **'Registered with {provider}'**
  String settingsTestPushRegistered(String provider);

  /// No description provided for @settingsSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get settingsSignOut;

  /// No description provided for @settingsSignOutOthers.
  ///
  /// In en, this message translates to:
  /// **'Sign out other devices'**
  String get settingsSignOutOthers;

  /// No description provided for @settingsSignOutOthersDetail.
  ///
  /// In en, this message translates to:
  /// **'Ends every session except this one'**
  String get settingsSignOutOthersDetail;

  /// No description provided for @settingsBackup.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup'**
  String get settingsBackup;

  /// No description provided for @settingsBackupDetail.
  ///
  /// In en, this message translates to:
  /// **'Backup & recovery code'**
  String get settingsBackupDetail;

  /// No description provided for @settingsRecoveryComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Recovery'**
  String get settingsRecoveryComingSoon;

  /// No description provided for @settingsRecoveryComingSoonDetail.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup & recovery key'**
  String get settingsRecoveryComingSoonDetail;

  /// No description provided for @settingsCallsComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get settingsCallsComingSoon;

  /// No description provided for @settingsCallsComingSoonDetail.
  ///
  /// In en, this message translates to:
  /// **'1:1 audio/video'**
  String get settingsCallsComingSoonDetail;

  /// No description provided for @settingsDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// No description provided for @settingsDeleteAccountDetail.
  ///
  /// In en, this message translates to:
  /// **'Disables sign-in and revokes your devices. Some encrypted records may remain under server retention rules.'**
  String get settingsDeleteAccountDetail;

  /// Identity header when the server gave no username.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get settingsSignedIn;

  /// No description provided for @settingsRevokeDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke device?'**
  String get settingsRevokeDeviceTitle;

  /// No description provided for @settingsRevokeDeviceMessage.
  ///
  /// In en, this message translates to:
  /// **'\"{deviceName}\" will lose access immediately.'**
  String settingsRevokeDeviceMessage(String deviceName);

  /// No description provided for @settingsSignOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get settingsSignOutTitle;

  /// No description provided for @settingsSignOutMessage.
  ///
  /// In en, this message translates to:
  /// **'This device stops receiving messages until you sign in again with your password.'**
  String get settingsSignOutMessage;

  /// No description provided for @settingsSignOutOthersTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out other devices?'**
  String get settingsSignOutOthersTitle;

  /// No description provided for @settingsSignOutOthersMessage.
  ///
  /// In en, this message translates to:
  /// **'Every session except this one will be ended.'**
  String get settingsSignOutOthersMessage;

  /// No description provided for @settingsSignOutOthersConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign out others'**
  String get settingsSignOutOthersConfirm;

  /// No description provided for @settingsDeleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get settingsDeleteAccountTitle;

  /// No description provided for @settingsDeleteAccountMessage.
  ///
  /// In en, this message translates to:
  /// **'This disables your account, ends its sessions, and revokes its devices. Encrypted messages and other records may remain according to the server retention policy.'**
  String get settingsDeleteAccountMessage;

  /// No description provided for @settingsDeleteAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'Disable account'**
  String get settingsDeleteAccountConfirm;

  /// No description provided for @settingsReauthTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm your password'**
  String get settingsReauthTitle;

  /// No description provided for @settingsReauthField.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get settingsReauthField;

  /// No description provided for @settingsNewPassword.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get settingsNewPassword;

  /// No description provided for @settingsNewPasswordHelper.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters.'**
  String get settingsNewPasswordHelper;

  /// No description provided for @settingsConfirmNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get settingsConfirmNewPassword;

  /// No description provided for @settingsPasswordsMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match.'**
  String get settingsPasswordsMismatch;

  /// No description provided for @settingsChangePasswordConfirm.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get settingsChangePasswordConfirm;

  /// No description provided for @settingsPasswordChanged.
  ///
  /// In en, this message translates to:
  /// **'Password changed. Your other devices were signed out.'**
  String get settingsPasswordChanged;

  /// No description provided for @settingsPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a new password.'**
  String get settingsPasswordRequired;

  /// No description provided for @settingsPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least 12 characters.'**
  String get settingsPasswordTooShort;

  /// No description provided for @settingsPasswordTooLong.
  ///
  /// In en, this message translates to:
  /// **'That password is too long. Use a shorter one.'**
  String get settingsPasswordTooLong;

  /// No description provided for @settingsPushDesktopTitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop notifications are not available yet'**
  String get settingsPushDesktopTitle;

  /// No description provided for @settingsPushDesktopDetail.
  ///
  /// In en, this message translates to:
  /// **'Messages arrive while the app is running, even in the background.'**
  String get settingsPushDesktopDetail;

  /// No description provided for @settingsPushServerDisabledTitle.
  ///
  /// In en, this message translates to:
  /// **'This server has no push provider'**
  String get settingsPushServerDisabledTitle;

  /// No description provided for @settingsPushServerDisabledDetail.
  ///
  /// In en, this message translates to:
  /// **'The operator has not configured push. Messages arrive while the app is open.'**
  String get settingsPushServerDisabledDetail;

  /// No description provided for @settingsPushRegisteringTitle.
  ///
  /// In en, this message translates to:
  /// **'Setting up push'**
  String get settingsPushRegisteringTitle;

  /// No description provided for @settingsPushRegisteringDetail.
  ///
  /// In en, this message translates to:
  /// **'Waiting for this device to register.'**
  String get settingsPushRegisteringDetail;

  /// No description provided for @settingsPushNoDistributorTitle.
  ///
  /// In en, this message translates to:
  /// **'No push distributor registered'**
  String get settingsPushNoDistributorTitle;

  /// No description provided for @settingsPushNoDistributorDetail.
  ///
  /// In en, this message translates to:
  /// **'Install a UnifiedPush distributor and pick it below, or messages will only arrive while the app is open.'**
  String get settingsPushNoDistributorDetail;

  /// No description provided for @settingsPushFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Push registration failed'**
  String get settingsPushFailedTitle;

  /// No description provided for @settingsPushFailedDetail.
  ///
  /// In en, this message translates to:
  /// **'This device could not register for push. It tries again the next time the app starts.'**
  String get settingsPushFailedDetail;

  /// No description provided for @settingsPushDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications are turned off'**
  String get settingsPushDeniedTitle;

  /// No description provided for @settingsPushDeniedDetail.
  ///
  /// In en, this message translates to:
  /// **'The app still syncs when woken, but shows nothing. Allow notifications for Veritra in the system settings.'**
  String get settingsPushDeniedDetail;

  /// No description provided for @settingsPushActiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Push notifications are active'**
  String get settingsPushActiveTitle;

  /// No description provided for @settingsPushActiveDetail.
  ///
  /// In en, this message translates to:
  /// **'Notifications never contain message text or sender names.'**
  String get settingsPushActiveDetail;

  /// No description provided for @settingsDeviceLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last seen {time}'**
  String settingsDeviceLastSeen(String time);

  /// No description provided for @settingsDeviceAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {date}'**
  String settingsDeviceAdded(String date);

  /// No description provided for @settingsDeviceRevoked.
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get settingsDeviceRevoked;

  /// No description provided for @settingsDeviceCurrent.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get settingsDeviceCurrent;

  /// No description provided for @backupReplaceTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace your backup?'**
  String get backupReplaceTitle;

  /// No description provided for @backupReplaceMessage.
  ///
  /// In en, this message translates to:
  /// **'The previous backup and its recovery code will stop working. Keep the new code somewhere safe.'**
  String get backupReplaceMessage;

  /// No description provided for @backupReplaceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Replace backup'**
  String get backupReplaceConfirm;

  /// No description provided for @inviteRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke invite?'**
  String get inviteRevokeTitle;

  /// No description provided for @inviteRevokeMessage.
  ///
  /// In en, this message translates to:
  /// **'Code {code} stops working immediately. People who already joined with it keep their accounts.'**
  String inviteRevokeMessage(String code);

  /// No description provided for @connectFreshInstanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Fresh instance detected'**
  String get connectFreshInstanceTitle;

  /// No description provided for @connectFreshInstanceMessage.
  ///
  /// In en, this message translates to:
  /// **'No owner account exists yet — create it below.'**
  String get connectFreshInstanceMessage;

  /// No description provided for @connectInstanceUrl.
  ///
  /// In en, this message translates to:
  /// **'Instance URL'**
  String get connectInstanceUrl;

  /// No description provided for @connectCheckApproval.
  ///
  /// In en, this message translates to:
  /// **'Check approval'**
  String get connectCheckApproval;

  /// No description provided for @connectLinkInstead.
  ///
  /// In en, this message translates to:
  /// **'Link this device instead'**
  String get connectLinkInstead;

  /// No description provided for @connectOtherWays.
  ///
  /// In en, this message translates to:
  /// **'Other ways to connect'**
  String get connectOtherWays;

  /// No description provided for @connectRestoreBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore from a backup'**
  String get connectRestoreBackup;

  /// No description provided for @connectLinkCode.
  ///
  /// In en, this message translates to:
  /// **'Link code'**
  String get connectLinkCode;

  /// No description provided for @connectLinkCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the link code from your existing device.'**
  String get connectLinkCodeRequired;

  /// No description provided for @connectLinkCodeHint.
  ///
  /// In en, this message translates to:
  /// **'From Settings → Link device'**
  String get connectLinkCodeHint;

  /// No description provided for @connectScanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get connectScanQr;

  /// No description provided for @connectVerificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Verification code'**
  String get connectVerificationTitle;

  /// No description provided for @connectVerificationMessage.
  ///
  /// In en, this message translates to:
  /// **'Confirm this code on your already-linked device, then check approval below.'**
  String get connectVerificationMessage;

  /// No description provided for @connectInviteCode.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get connectInviteCode;

  /// No description provided for @connectInviteCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the invite code you received.'**
  String get connectInviteCodeRequired;

  /// No description provided for @connectInviteCodeHint.
  ///
  /// In en, this message translates to:
  /// **'From an admin on this instance'**
  String get connectInviteCodeHint;

  /// No description provided for @connectUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get connectUsername;

  /// No description provided for @connectUsernameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a username.'**
  String get connectUsernameRequired;

  /// No description provided for @connectUsernameHint.
  ///
  /// In en, this message translates to:
  /// **'Your name on this instance'**
  String get connectUsernameHint;

  /// No description provided for @connectPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get connectPassword;

  /// No description provided for @connectPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters'**
  String get connectPasswordHint;

  /// No description provided for @connectHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get connectHidePassword;

  /// No description provided for @connectShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get connectShowPassword;

  /// No description provided for @connectConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get connectConfirmPassword;

  /// No description provided for @connectConfirmPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Repeat your password'**
  String get connectConfirmPasswordHint;

  /// No description provided for @connectSetupToken.
  ///
  /// In en, this message translates to:
  /// **'Setup token'**
  String get connectSetupToken;

  /// No description provided for @connectSetupTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Required unless connecting on loopback'**
  String get connectSetupTokenHint;

  /// No description provided for @connectUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the instance URL.'**
  String get connectUrlRequired;

  /// No description provided for @connectUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a full URL, e.g. https://chat.example.org'**
  String get connectUrlInvalid;

  /// No description provided for @connectUrlOriginOnly.
  ///
  /// In en, this message translates to:
  /// **'Enter only the server origin, e.g. https://chat.example.org'**
  String get connectUrlOriginOnly;

  /// No description provided for @connectUrlHttpsRequired.
  ///
  /// In en, this message translates to:
  /// **'Veritra requires HTTPS. Use an https:// server origin.'**
  String get connectUrlHttpsRequired;

  /// No description provided for @connectUrlLoopbackOnly.
  ///
  /// In en, this message translates to:
  /// **'Use https://, or http:// only for this computer (localhost or 127.0.0.1).'**
  String get connectUrlLoopbackOnly;

  /// No description provided for @connectPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your password.'**
  String get connectPasswordRequired;

  /// No description provided for @connectModeOwnerTitle.
  ///
  /// In en, this message translates to:
  /// **'Create the owner account'**
  String get connectModeOwnerTitle;

  /// No description provided for @connectModeSignInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get connectModeSignInTitle;

  /// No description provided for @connectModeJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'Join with an invite'**
  String get connectModeJoinTitle;

  /// No description provided for @connectModeLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Link this device'**
  String get connectModeLinkTitle;

  /// No description provided for @connectModeOwnerDetail.
  ///
  /// In en, this message translates to:
  /// **'First run only: create the owner account on a fresh self-hosted instance.'**
  String get connectModeOwnerDetail;

  /// No description provided for @connectModeSignInDetail.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your password on a device that has already been linked to your account.'**
  String get connectModeSignInDetail;

  /// No description provided for @connectModeJoinDetail.
  ///
  /// In en, this message translates to:
  /// **'Registration is invite-only. Enter the invite code you received from an admin.'**
  String get connectModeJoinDetail;

  /// No description provided for @connectModeLinkDetail.
  ///
  /// In en, this message translates to:
  /// **'Enter the link code generated on your existing device (Settings → Link device).'**
  String get connectModeLinkDetail;

  /// No description provided for @connectNotDeviceLinkQr.
  ///
  /// In en, this message translates to:
  /// **'That is not a Veritra device-link QR.'**
  String get connectNotDeviceLinkQr;

  /// No description provided for @connectOriginFilled.
  ///
  /// In en, this message translates to:
  /// **'Server origin filled. Verify it before continuing.'**
  String get connectOriginFilled;

  /// No description provided for @connectConfirmServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm server'**
  String get connectConfirmServerTitle;

  /// No description provided for @connectConfirmServerMessage.
  ///
  /// In en, this message translates to:
  /// **'This QR code suggests {origin}. The app will still probe the server before using it. Continue with this HTTPS origin?'**
  String connectConfirmServerMessage(String origin);

  /// No description provided for @connectUseOrigin.
  ///
  /// In en, this message translates to:
  /// **'Use origin'**
  String get connectUseOrigin;

  /// No description provided for @connectSubmitOwner.
  ///
  /// In en, this message translates to:
  /// **'Create owner'**
  String get connectSubmitOwner;

  /// No description provided for @connectSubmitSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get connectSubmitSignIn;

  /// No description provided for @connectSubmitJoin.
  ///
  /// In en, this message translates to:
  /// **'Join with invite'**
  String get connectSubmitJoin;

  /// No description provided for @connectSubmitLink.
  ///
  /// In en, this message translates to:
  /// **'Claim link'**
  String get connectSubmitLink;

  /// No description provided for @connectTagline.
  ///
  /// In en, this message translates to:
  /// **'Self-hosted, end-to-end encrypted messaging'**
  String get connectTagline;

  /// No description provided for @qrScanLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan link QR'**
  String get qrScanLinkTitle;

  /// No description provided for @qrToggleTorch.
  ///
  /// In en, this message translates to:
  /// **'Toggle torch'**
  String get qrToggleTorch;

  /// No description provided for @qrSwitchCamera.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get qrSwitchCamera;

  /// No description provided for @qrPointCamera.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the QR code on your existing device (Settings → Link a new device).'**
  String get qrPointCamera;

  /// No description provided for @qrPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is required to scan. Enable it in system settings, or type the link code manually.'**
  String get qrPermissionDenied;

  /// No description provided for @qrUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device can’t scan QR codes. Type the link code manually.'**
  String get qrUnsupported;

  /// No description provided for @qrCameraFailed.
  ///
  /// In en, this message translates to:
  /// **'The camera could not be started. Type the link code manually.'**
  String get qrCameraFailed;

  /// No description provided for @qrEnterManually.
  ///
  /// In en, this message translates to:
  /// **'Enter code manually'**
  String get qrEnterManually;

  /// No description provided for @newConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get newConversationTitle;

  /// No description provided for @newConversationDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct message'**
  String get newConversationDirect;

  /// No description provided for @newConversationGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get newConversationGroup;

  /// No description provided for @newConversationGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get newConversationGroupName;

  /// No description provided for @newConversationWho.
  ///
  /// In en, this message translates to:
  /// **'Who do you want to message?'**
  String get newConversationWho;

  /// No description provided for @newConversationAddMembers.
  ///
  /// In en, this message translates to:
  /// **'Add members'**
  String get newConversationAddMembers;

  /// No description provided for @newConversationStartDm.
  ///
  /// In en, this message translates to:
  /// **'Start DM'**
  String get newConversationStartDm;

  /// No description provided for @newConversationCreateGroup.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get newConversationCreateGroup;

  /// No description provided for @newConversationPickPerson.
  ///
  /// In en, this message translates to:
  /// **'Pick the person to message first.'**
  String get newConversationPickPerson;

  /// No description provided for @newConversationAddOneMember.
  ///
  /// In en, this message translates to:
  /// **'Add at least one other member.'**
  String get newConversationAddOneMember;

  /// No description provided for @blockedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No blocked accounts'**
  String get blockedEmptyTitle;

  /// No description provided for @blockedEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Block someone from a direct message to stop the server delivering their messages to you.'**
  String get blockedEmptyMessage;

  /// No description provided for @blockedLabel.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blockedLabel;

  /// No description provided for @blockedOn.
  ///
  /// In en, this message translates to:
  /// **'Blocked {date}'**
  String blockedOn(String date);

  /// No description provided for @blockedUnblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get blockedUnblock;

  /// No description provided for @blockedUnblocked.
  ///
  /// In en, this message translates to:
  /// **'{label} unblocked.'**
  String blockedUnblocked(String label);

  /// No description provided for @blockedUnblockFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not unblock {label}.'**
  String blockedUnblockFailed(String label);

  /// No description provided for @blockedLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load blocked accounts'**
  String get blockedLoadFailed;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @accountPickerHelper.
  ///
  /// In en, this message translates to:
  /// **'Exact username, or paste an account ID (acct_…).'**
  String get accountPickerHelper;

  /// No description provided for @accountPickerNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No account found with that exact username.'**
  String get accountPickerNoMatch;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search people, communities, channels…'**
  String get searchHint;

  /// No description provided for @searchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get searchClear;

  /// No description provided for @searchIntroTitle.
  ///
  /// In en, this message translates to:
  /// **'Search metadata'**
  String get searchIntroTitle;

  /// No description provided for @searchIntroMessage.
  ///
  /// In en, this message translates to:
  /// **'Find people by exact username, plus communities and channels by name. Message contents are end-to-end encrypted and never searchable on the server.'**
  String get searchIntroMessage;

  /// No description provided for @searchNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get searchNoResultsTitle;

  /// No description provided for @searchNoResultsMessage.
  ///
  /// In en, this message translates to:
  /// **'Nothing matched. Usernames must match exactly, and message contents are never searchable.'**
  String get searchNoResultsMessage;

  /// No description provided for @searchNoOpenChannel.
  ///
  /// In en, this message translates to:
  /// **'No channel you can open yet'**
  String get searchNoOpenChannel;

  /// No description provided for @searchJoinCommunity.
  ///
  /// In en, this message translates to:
  /// **'Join the community to open it'**
  String get searchJoinCommunity;

  /// No description provided for @searchTypeConversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get searchTypeConversation;

  /// No description provided for @searchTypeCommunity.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get searchTypeCommunity;

  /// No description provided for @searchTypeChannel.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get searchTypeChannel;

  /// No description provided for @searchTypeAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get searchTypeAccount;

  /// No description provided for @searchUnblockAccount.
  ///
  /// In en, this message translates to:
  /// **'Unblock {label}'**
  String searchUnblockAccount(String label);

  /// No description provided for @searchBlockAccount.
  ///
  /// In en, this message translates to:
  /// **'Block {label}'**
  String searchBlockAccount(String label);

  /// No description provided for @searchBlocked.
  ///
  /// In en, this message translates to:
  /// **'{label} blocked.'**
  String searchBlocked(String label);

  /// No description provided for @searchBlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the block.'**
  String get searchBlockFailed;

  /// No description provided for @inviteCreateSection.
  ///
  /// In en, this message translates to:
  /// **'Create an invite'**
  String get inviteCreateSection;

  /// No description provided for @inviteMaxUses.
  ///
  /// In en, this message translates to:
  /// **'Max uses'**
  String get inviteMaxUses;

  /// No description provided for @inviteMaxUsesOption.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String inviteMaxUsesOption(int count);

  /// No description provided for @inviteExpires.
  ///
  /// In en, this message translates to:
  /// **'Expires'**
  String get inviteExpires;

  /// No description provided for @durationDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day} other{{count} days}}'**
  String durationDays(int count);

  /// No description provided for @inviteCreate.
  ///
  /// In en, this message translates to:
  /// **'Create invite'**
  String get inviteCreate;

  /// No description provided for @inviteEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No invites yet'**
  String get inviteEmptyTitle;

  /// No description provided for @inviteEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Invite codes you create appear here. Share them over a secure channel.'**
  String get inviteEmptyMessage;

  /// No description provided for @inviteYourInvites.
  ///
  /// In en, this message translates to:
  /// **'Your invites'**
  String get inviteYourInvites;

  /// No description provided for @inviteUsesPill.
  ///
  /// In en, this message translates to:
  /// **'{uses}/{maxUses}'**
  String inviteUsesPill(int uses, int maxUses);

  /// No description provided for @inviteUsesSemantics.
  ///
  /// In en, this message translates to:
  /// **'{uses} of {maxUses} uses'**
  String inviteUsesSemantics(int uses, int maxUses);

  /// No description provided for @inviteNeverExpires.
  ///
  /// In en, this message translates to:
  /// **'Never expires'**
  String get inviteNeverExpires;

  /// No description provided for @inviteExpiresAt.
  ///
  /// In en, this message translates to:
  /// **'Expires {time}'**
  String inviteExpiresAt(String time);

  /// No description provided for @inviteActions.
  ///
  /// In en, this message translates to:
  /// **'Invite actions'**
  String get inviteActions;

  /// No description provided for @inviteCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite code copied.'**
  String get inviteCodeCopied;

  /// No description provided for @inviteCopyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get inviteCopyCode;

  /// No description provided for @profileThisInstance.
  ///
  /// In en, this message translates to:
  /// **'this instance'**
  String get profileThisInstance;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTitle;

  /// No description provided for @profileYourAccount.
  ///
  /// In en, this message translates to:
  /// **'Your account'**
  String get profileYourAccount;

  /// No description provided for @profileSectionIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get profileSectionIdentity;

  /// No description provided for @profileNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Not available'**
  String get profileNotAvailable;

  /// No description provided for @profileCurrentDevice.
  ///
  /// In en, this message translates to:
  /// **'Current device'**
  String get profileCurrentDevice;

  /// No description provided for @profileInstanceRole.
  ///
  /// In en, this message translates to:
  /// **'Instance role'**
  String get profileInstanceRole;

  /// No description provided for @profileSectionEncryption.
  ///
  /// In en, this message translates to:
  /// **'Encryption'**
  String get profileSectionEncryption;

  /// No description provided for @profileEncryptionPending.
  ///
  /// In en, this message translates to:
  /// **'Encryption identity pending'**
  String get profileEncryptionPending;

  /// No description provided for @profileEncryptionPendingDetail.
  ///
  /// In en, this message translates to:
  /// **'Safety-number verification and profile editing remain unavailable until the reviewed encryption engine ships.'**
  String get profileEncryptionPendingDetail;

  /// No description provided for @profileCopyLabel.
  ///
  /// In en, this message translates to:
  /// **'Copy {label}'**
  String profileCopyLabel(String label);

  /// No description provided for @navChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navCommunities.
  ///
  /// In en, this message translates to:
  /// **'Communities'**
  String get navCommunities;

  /// No description provided for @shellNoConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversation selected'**
  String get shellNoConversationTitle;

  /// No description provided for @shellNoConversationMessage.
  ///
  /// In en, this message translates to:
  /// **'Pick a conversation from the list to read it here.'**
  String get shellNoConversationMessage;

  /// No description provided for @shellRestoring.
  ///
  /// In en, this message translates to:
  /// **'Restoring this device…'**
  String get shellRestoring;

  /// No description provided for @shellResetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset this device?'**
  String get shellResetTitle;

  /// No description provided for @shellResetMessage.
  ///
  /// In en, this message translates to:
  /// **'This device starts empty and must be linked again. Its current messages stay unreadable here; they are moved aside, not deleted, in case the key comes back.'**
  String get shellResetMessage;

  /// No description provided for @shellResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get shellResetConfirm;

  /// No description provided for @shellRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Device recovery needed'**
  String get shellRecoveryTitle;

  /// No description provided for @shellRecoveryFallback.
  ///
  /// In en, this message translates to:
  /// **'This device needs attention before it can be used.'**
  String get shellRecoveryFallback;

  /// No description provided for @shellRetryRestore.
  ///
  /// In en, this message translates to:
  /// **'Retry restore'**
  String get shellRetryRestore;

  /// No description provided for @shellContinueToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Continue to sign in'**
  String get shellContinueToSignIn;

  /// No description provided for @shellResetDevice.
  ///
  /// In en, this message translates to:
  /// **'Reset this device'**
  String get shellResetDevice;

  /// No description provided for @communityNew.
  ///
  /// In en, this message translates to:
  /// **'New community'**
  String get communityNew;

  /// No description provided for @communityEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No communities yet'**
  String get communityEmptyTitle;

  /// No description provided for @communityEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Create a community to organize people around shared channels — private by default, encrypted everywhere.'**
  String get communityEmptyMessage;

  /// No description provided for @communityOtherChannels.
  ///
  /// In en, this message translates to:
  /// **'Other channels you are in'**
  String get communityOtherChannels;

  /// No description provided for @communityChannelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Community channel'**
  String get communityChannelSubtitle;

  /// No description provided for @communityName.
  ///
  /// In en, this message translates to:
  /// **'Community name'**
  String get communityName;

  /// No description provided for @communityNewChannelIn.
  ///
  /// In en, this message translates to:
  /// **'New channel in {community}'**
  String communityNewChannelIn(String community);

  /// No description provided for @communityChannelName.
  ///
  /// In en, this message translates to:
  /// **'Channel name'**
  String get communityChannelName;

  /// No description provided for @communityNoChannels.
  ///
  /// In en, this message translates to:
  /// **'No channels yet'**
  String get communityNoChannels;

  /// No description provided for @communityChannelCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 channel} other{{count} channels}}'**
  String communityChannelCount(int count);

  /// No description provided for @communityNewChannel.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get communityNewChannel;

  /// No description provided for @communityNoChannelsHint.
  ///
  /// In en, this message translates to:
  /// **'Use + to create the first one.'**
  String get communityNoChannelsHint;

  /// No description provided for @communityNotMember.
  ///
  /// In en, this message translates to:
  /// **'You are not a member yet'**
  String get communityNotMember;

  /// No description provided for @backupIntro.
  ///
  /// In en, this message translates to:
  /// **'A backup holds this device\'s keys and message history, encrypted on this device. The server stores it but cannot read it. Restoring it on a new device needs the recovery code shown when you make it.'**
  String get backupIntro;

  /// No description provided for @backupSectionStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get backupSectionStatus;

  /// No description provided for @backupNone.
  ///
  /// In en, this message translates to:
  /// **'No backup from this device yet'**
  String get backupNone;

  /// No description provided for @backupLast.
  ///
  /// In en, this message translates to:
  /// **'Last backup {time}'**
  String backupLast(String time);

  /// No description provided for @backupReplacesPrevious.
  ///
  /// In en, this message translates to:
  /// **'A new backup replaces the previous one and its code.'**
  String get backupReplacesPrevious;

  /// No description provided for @backupMake.
  ///
  /// In en, this message translates to:
  /// **'Make a backup'**
  String get backupMake;

  /// No description provided for @backupMakeNew.
  ///
  /// In en, this message translates to:
  /// **'Make a new backup'**
  String get backupMakeNew;

  /// No description provided for @backupSaveCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Save your recovery code'**
  String get backupSaveCodeTitle;

  /// No description provided for @backupSaveCodeMessage.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this code can restore your messages. Keep it somewhere safe and offline. It is shown only now, and it stops working after it is used or when you make a new backup.'**
  String get backupSaveCodeMessage;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @backupSavedIt.
  ///
  /// In en, this message translates to:
  /// **'I saved it'**
  String get backupSavedIt;

  /// No description provided for @backupRestoreMessage.
  ///
  /// In en, this message translates to:
  /// **'This device takes the place of the one that made the backup. Stop using that device first.'**
  String get backupRestoreMessage;

  /// No description provided for @backupRecoveryCode.
  ///
  /// In en, this message translates to:
  /// **'Recovery code'**
  String get backupRecoveryCode;

  /// No description provided for @backupRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupRestore;

  /// No description provided for @deviceLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Link a device'**
  String get deviceLinkTitle;

  /// No description provided for @deviceLinkIntro.
  ///
  /// In en, this message translates to:
  /// **'Generate a one-time code, enter it on the new device, then approve it here with the verification code the new device shows.'**
  String get deviceLinkIntro;

  /// No description provided for @deviceLinkCreate.
  ///
  /// In en, this message translates to:
  /// **'Create link'**
  String get deviceLinkCreate;

  /// No description provided for @deviceLinkCreateNew.
  ///
  /// In en, this message translates to:
  /// **'Create new link'**
  String get deviceLinkCreateNew;

  /// No description provided for @deviceLinkQrSemantics.
  ///
  /// In en, this message translates to:
  /// **'QR code containing the device link. Scan it with the new device.'**
  String get deviceLinkQrSemantics;

  /// No description provided for @deviceLinkQrHint.
  ///
  /// In en, this message translates to:
  /// **'Scan it with the Veritra app on the new device, or type the link code below.'**
  String get deviceLinkQrHint;

  /// No description provided for @deviceLinkStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'STATUS'**
  String get deviceLinkStatusLabel;

  /// No description provided for @deviceLinkState.
  ///
  /// In en, this message translates to:
  /// **'{state, select, pending{pending} claimed{claimed} approved{approved} expired{expired} other{{state}}}'**
  String deviceLinkState(String state);

  /// No description provided for @deviceLinkClaimedBy.
  ///
  /// In en, this message translates to:
  /// **'Claimed by'**
  String get deviceLinkClaimedBy;

  /// No description provided for @deviceLinkRefreshStatus.
  ///
  /// In en, this message translates to:
  /// **'Refresh status'**
  String get deviceLinkRefreshStatus;

  /// No description provided for @deviceLinkApproveDevice.
  ///
  /// In en, this message translates to:
  /// **'Approve device'**
  String get deviceLinkApproveDevice;

  /// No description provided for @deviceLinkApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get deviceLinkApprove;

  /// No description provided for @bannerQueued.
  ///
  /// In en, this message translates to:
  /// **'Messages you send stay queued on this device.'**
  String get bannerQueued;

  /// No description provided for @bannerReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to the server…'**
  String get bannerReconnecting;

  /// No description provided for @bannerLastSynced.
  ///
  /// In en, this message translates to:
  /// **'Last synced {time}.'**
  String bannerLastSynced(String time);

  /// No description provided for @bannerOfflineSemantics.
  ///
  /// In en, this message translates to:
  /// **'Offline. {detail}'**
  String bannerOfflineSemantics(String detail);

  /// No description provided for @bannerConnectingSemantics.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the server. {detail}'**
  String bannerConnectingSemantics(String detail);

  /// No description provided for @bannerOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get bannerOffline;

  /// No description provided for @bannerConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get bannerConnecting;

  /// No description provided for @bannerPaused.
  ///
  /// In en, this message translates to:
  /// **'Messages paused'**
  String get bannerPaused;

  /// No description provided for @bannerTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get bannerTryAgain;

  /// No description provided for @bannerRelink.
  ///
  /// In en, this message translates to:
  /// **'Link this device again'**
  String get bannerRelink;

  /// No description provided for @bannerRelinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Link this device again?'**
  String get bannerRelinkTitle;

  /// No description provided for @bannerRelinkMessage.
  ///
  /// In en, this message translates to:
  /// **'This signs this device out and deletes its messages and encryption keys. Link it again from another device afterwards. Messages that are only on this device cannot be recovered.'**
  String get bannerRelinkMessage;

  /// No description provided for @bannerRelinkConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete and sign out'**
  String get bannerRelinkConfirm;

  /// No description provided for @attachmentPickUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Files cannot be picked on this device.'**
  String get attachmentPickUnavailable;

  /// No description provided for @attachmentSendTitle.
  ///
  /// In en, this message translates to:
  /// **'Send this file?'**
  String get attachmentSendTitle;

  /// No description provided for @attachmentSendMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} ({size}) is encrypted on this device before it is uploaded. Everyone in this conversation can open it.'**
  String attachmentSendMessage(String name, String size);

  /// No description provided for @attachmentSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get attachmentSend;

  /// No description provided for @attachmentSendFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be sent.'**
  String get attachmentSendFailed;

  /// No description provided for @attachmentDemoImagesOnly.
  ///
  /// In en, this message translates to:
  /// **'In the demo, only images can be opened on this device.'**
  String get attachmentDemoImagesOnly;

  /// No description provided for @attachmentSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved {fileName}.'**
  String attachmentSaved(String fileName);

  /// No description provided for @attachmentDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be downloaded or decrypted.'**
  String get attachmentDownloadFailed;

  /// No description provided for @attachmentImageSemantics.
  ///
  /// In en, this message translates to:
  /// **'Image {fileName}, {size}'**
  String attachmentImageSemantics(String fileName, String size);

  /// No description provided for @attachmentFileSemantics.
  ///
  /// In en, this message translates to:
  /// **'File {fileName}, {size}'**
  String attachmentFileSemantics(String fileName, String size);

  /// No description provided for @attachmentSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get attachmentSave;

  /// No description provided for @attachmentImageFailed.
  ///
  /// In en, this message translates to:
  /// **'The image could not be downloaded or decrypted.'**
  String get attachmentImageFailed;

  /// No description provided for @attachmentImageUnshowable.
  ///
  /// In en, this message translates to:
  /// **'This image cannot be shown.'**
  String get attachmentImageUnshowable;

  /// No description provided for @fileSizeBytes.
  ///
  /// In en, this message translates to:
  /// **'{size} B'**
  String fileSizeBytes(int size);

  /// No description provided for @fileSizeKilobytes.
  ///
  /// In en, this message translates to:
  /// **'{size} KB'**
  String fileSizeKilobytes(int size);

  /// No description provided for @fileSizeMegabytes.
  ///
  /// In en, this message translates to:
  /// **'{size} MB'**
  String fileSizeMegabytes(double size);

  /// No description provided for @chatListSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatListSearch;

  /// No description provided for @chatListNewChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get chatListNewChat;

  /// No description provided for @chatListEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get chatListEmptyTitle;

  /// No description provided for @chatListEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Start a direct message or create a group. Everything is end-to-end encrypted.'**
  String get chatListEmptyMessage;

  /// No description provided for @chatListUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute notifications'**
  String get chatListUnmute;

  /// No description provided for @chatListMute.
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get chatListMute;

  /// No description provided for @chatListDetails.
  ///
  /// In en, this message translates to:
  /// **'Conversation details'**
  String get chatListDetails;

  /// No description provided for @chatListMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get chatListMuted;

  /// No description provided for @chatListDisappearingAfter.
  ///
  /// In en, this message translates to:
  /// **'Disappearing after {duration}'**
  String chatListDisappearingAfter(String duration);

  /// No description provided for @chatListUnreadSpoken.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 unread message} other{{count} unread messages}}'**
  String chatListUnreadSpoken(int count);

  /// No description provided for @chatListUnreadCount.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String chatListUnreadCount(int count);

  /// No description provided for @chatListUnreadOverflow.
  ///
  /// In en, this message translates to:
  /// **'99+'**
  String get chatListUnreadOverflow;

  /// No description provided for @conversationGroupChat.
  ///
  /// In en, this message translates to:
  /// **'Group chat'**
  String get conversationGroupChat;

  /// No description provided for @conversationPrivateGroup.
  ///
  /// In en, this message translates to:
  /// **'Private group'**
  String get conversationPrivateGroup;

  /// No description provided for @conversationEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Encrypted'**
  String get conversationEncrypted;

  /// No description provided for @conversationDisappearing.
  ///
  /// In en, this message translates to:
  /// **'Disappearing ({duration})'**
  String conversationDisappearing(String duration);

  /// No description provided for @durationHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour} other{{count} hours}}'**
  String durationHours(int count);

  /// No description provided for @durationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String durationMinutes(int count);

  /// No description provided for @durationChipDays.
  ///
  /// In en, this message translates to:
  /// **'{count}d'**
  String durationChipDays(int count);

  /// No description provided for @durationChipHours.
  ///
  /// In en, this message translates to:
  /// **'{count}h'**
  String durationChipHours(int count);

  /// No description provided for @durationChipMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count}m'**
  String durationChipMinutes(int count);

  /// No description provided for @safetyMarkTitle.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified?'**
  String get safetyMarkTitle;

  /// No description provided for @safetyMarkMessage.
  ///
  /// In en, this message translates to:
  /// **'Only do this after comparing the number with the other person in person or over a call you trust. Both of you must see exactly the same sixty digits.'**
  String get safetyMarkMessage;

  /// No description provided for @safetyTheyMatch.
  ///
  /// In en, this message translates to:
  /// **'They match'**
  String get safetyTheyMatch;

  /// No description provided for @safetySaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The verification could not be saved. Try again.'**
  String get safetySaveFailed;

  /// No description provided for @safetyScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan safety code'**
  String get safetyScanTitle;

  /// No description provided for @safetyReadFailed.
  ///
  /// In en, this message translates to:
  /// **'The safety number could not be read. Try again.'**
  String get safetyReadFailed;

  /// No description provided for @safetyMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Codes do not match'**
  String get safetyMismatchTitle;

  /// No description provided for @safetyMismatchMessage.
  ///
  /// In en, this message translates to:
  /// **'This is not the same safety code. Make sure you scanned the code for this conversation and that both devices have received the latest messages, then try again. If it still does not match, do not treat this conversation as verified.'**
  String get safetyMismatchMessage;

  /// No description provided for @commonOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @safetyCodesMatch.
  ///
  /// In en, this message translates to:
  /// **'The codes match.'**
  String get safetyCodesMatch;

  /// No description provided for @safetyCodesMatchVerified.
  ///
  /// In en, this message translates to:
  /// **'The codes match. Marked as verified.'**
  String get safetyCodesMatchVerified;

  /// No description provided for @safetyTitle.
  ///
  /// In en, this message translates to:
  /// **'Safety number'**
  String get safetyTitle;

  /// No description provided for @safetyGroupIntro.
  ///
  /// In en, this message translates to:
  /// **'Every member of this group sees the same number. Compare it in person or scan each other\'s code.'**
  String get safetyGroupIntro;

  /// No description provided for @safetyPeerIntro.
  ///
  /// In en, this message translates to:
  /// **'Compare this number with {peer} in person, or scan each other\'s code.'**
  String safetyPeerIntro(String peer);

  /// No description provided for @safetyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Safety number unavailable'**
  String get safetyUnavailable;

  /// No description provided for @safetyUnavailableDetail.
  ///
  /// In en, this message translates to:
  /// **'This device has not joined the encrypted group yet, or its group state could not be read.'**
  String get safetyUnavailableDetail;

  /// No description provided for @safetyDigitsSemantics.
  ///
  /// In en, this message translates to:
  /// **'Safety number, twelve groups of five: {groups}'**
  String safetyDigitsSemantics(String groups);

  /// No description provided for @safetyQrSemantics.
  ///
  /// In en, this message translates to:
  /// **'QR code of this safety number. The other person can scan it to compare.'**
  String get safetyQrSemantics;

  /// No description provided for @safetyVerifiedDetail.
  ///
  /// In en, this message translates to:
  /// **'You verified this number.'**
  String get safetyVerifiedDetail;

  /// No description provided for @safetyChangedDetail.
  ///
  /// In en, this message translates to:
  /// **'A device in this conversation was added, removed or replaced since you verified. Compare the new number again.'**
  String get safetyChangedDetail;

  /// No description provided for @safetyUnverifiedDetail.
  ///
  /// In en, this message translates to:
  /// **'Not verified yet.'**
  String get safetyUnverifiedDetail;

  /// No description provided for @safetyVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get safetyVerified;

  /// No description provided for @safetyChanged.
  ///
  /// In en, this message translates to:
  /// **'Changed'**
  String get safetyChanged;

  /// No description provided for @safetyUnverified.
  ///
  /// In en, this message translates to:
  /// **'Not verified'**
  String get safetyUnverified;

  /// No description provided for @safetyScanTheirCode.
  ///
  /// In en, this message translates to:
  /// **'Scan their code'**
  String get safetyScanTheirCode;

  /// No description provided for @safetyMarkVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified'**
  String get safetyMarkVerified;

  /// No description provided for @detailsNotFound.
  ///
  /// In en, this message translates to:
  /// **'Conversation not found.'**
  String get detailsNotFound;

  /// No description provided for @detailsConversationIdLabel.
  ///
  /// In en, this message translates to:
  /// **'CONVERSATION ID'**
  String get detailsConversationIdLabel;

  /// No description provided for @detailsCopyId.
  ///
  /// In en, this message translates to:
  /// **'Copy ID'**
  String get detailsCopyId;

  /// No description provided for @detailsConversationId.
  ///
  /// In en, this message translates to:
  /// **'Conversation ID'**
  String get detailsConversationId;

  /// No description provided for @detailsCreatedLabel.
  ///
  /// In en, this message translates to:
  /// **'CREATED'**
  String get detailsCreatedLabel;

  /// No description provided for @detailsMuteDetail.
  ///
  /// In en, this message translates to:
  /// **'Stops push for this conversation. Messages still arrive and still count as unread.'**
  String get detailsMuteDetail;

  /// No description provided for @detailsSectionMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get detailsSectionMembers;

  /// No description provided for @detailsLoadingMembers.
  ///
  /// In en, this message translates to:
  /// **'Loading members…'**
  String get detailsLoadingMembers;

  /// No description provided for @detailsMembersUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Member list unavailable'**
  String get detailsMembersUnavailable;

  /// No description provided for @detailsMembersUnavailableDetail.
  ///
  /// In en, this message translates to:
  /// **'The server did not return the roster for this conversation.'**
  String get detailsMembersUnavailableDetail;

  /// No description provided for @detailsAddMember.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get detailsAddMember;

  /// No description provided for @detailsAddMemberDetail.
  ///
  /// In en, this message translates to:
  /// **'Look up an account by username'**
  String get detailsAddMemberDetail;

  /// No description provided for @detailsAddMemberNoPermission.
  ///
  /// In en, this message translates to:
  /// **'Moderator permission required'**
  String get detailsAddMemberNoPermission;

  /// No description provided for @detailsMembershipNote.
  ///
  /// In en, this message translates to:
  /// **'This is the server\'s membership record. Encrypted delivery follows a separate group update, so a change here is not by itself proof of who can decrypt new messages.'**
  String get detailsMembershipNote;

  /// No description provided for @detailsSafetyDetail.
  ///
  /// In en, this message translates to:
  /// **'Compare it with the other members to check that no one is intercepting this conversation.'**
  String get detailsSafetyDetail;

  /// No description provided for @detailsLeaveDm.
  ///
  /// In en, this message translates to:
  /// **'Leave this conversation'**
  String get detailsLeaveDm;

  /// No description provided for @detailsLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave conversation'**
  String get detailsLeave;

  /// No description provided for @detailsLeaveDetail.
  ///
  /// In en, this message translates to:
  /// **'You stop receiving new messages. Messages already on other members\' devices are not deleted.'**
  String get detailsLeaveDetail;

  /// No description provided for @detailsSectionDisappearing.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages'**
  String get detailsSectionDisappearing;

  /// No description provided for @detailsDisappearingNote.
  ///
  /// In en, this message translates to:
  /// **'When set, messages sent from then on are deleted from the server after this time window. Existing messages keep the timer they were sent with.'**
  String get detailsDisappearingNote;

  /// No description provided for @detailsRetentionOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get detailsRetentionOff;

  /// No description provided for @detailsRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {label}?'**
  String detailsRemoveTitle(String label);

  /// No description provided for @detailsRemoveMessage.
  ///
  /// In en, this message translates to:
  /// **'They stop receiving new messages in this conversation. Messages they already received stay on their device, and encrypted delivery only changes once the group update is committed.'**
  String get detailsRemoveMessage;

  /// No description provided for @detailsRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get detailsRemoveConfirm;

  /// No description provided for @detailsRemoved.
  ///
  /// In en, this message translates to:
  /// **'{label} removed from the conversation.'**
  String detailsRemoved(String label);

  /// No description provided for @detailsRemoveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove {label}.'**
  String detailsRemoveFailed(String label);

  /// No description provided for @detailsLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave conversation?'**
  String get detailsLeaveTitle;

  /// No description provided for @detailsLeaveMessage.
  ///
  /// In en, this message translates to:
  /// **'You stop receiving new messages and the conversation is removed from this device. Messages other members already received are not deleted.'**
  String get detailsLeaveMessage;

  /// No description provided for @detailsLeaveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get detailsLeaveConfirm;

  /// No description provided for @detailsRetentionOffMessage.
  ///
  /// In en, this message translates to:
  /// **'New messages will no longer disappear. Messages that already have a timer keep it.'**
  String get detailsRetentionOffMessage;

  /// No description provided for @detailsRetentionOnMessage.
  ///
  /// In en, this message translates to:
  /// **'Messages sent from now on will be deleted from the server {duration} after they are sent. Existing messages are not affected.'**
  String detailsRetentionOnMessage(String duration);

  /// No description provided for @detailsRetentionOffTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn off disappearing messages?'**
  String get detailsRetentionOffTitle;

  /// No description provided for @detailsRetentionOnTitle.
  ///
  /// In en, this message translates to:
  /// **'Disappear after {duration}?'**
  String detailsRetentionOnTitle(String duration);

  /// No description provided for @detailsApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get detailsApply;

  /// No description provided for @detailsAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get detailsAdd;

  /// No description provided for @detailsMemberAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {label} to the conversation. Encrypted delivery starts once the group update is committed.'**
  String detailsMemberAdded(String label);

  /// No description provided for @roleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get roleOwner;

  /// No description provided for @roleAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get roleAdmin;

  /// No description provided for @roleModerator.
  ///
  /// In en, this message translates to:
  /// **'Moderator'**
  String get roleModerator;

  /// No description provided for @roleMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get roleMember;

  /// No description provided for @detailsYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get detailsYou;

  /// No description provided for @detailsJoined.
  ///
  /// In en, this message translates to:
  /// **'Joined {date}'**
  String detailsJoined(String date);

  /// No description provided for @detailsRemoveMember.
  ///
  /// In en, this message translates to:
  /// **'Remove {label}'**
  String detailsRemoveMember(String label);

  /// No description provided for @detailsBlockedDetail.
  ///
  /// In en, this message translates to:
  /// **'Their messages are hidden from this account until you unblock them.'**
  String get detailsBlockedDetail;

  /// No description provided for @detailsBlockDetail.
  ///
  /// In en, this message translates to:
  /// **'The server stops delivering their messages to your account. They are not told, and messages already on your devices stay.'**
  String get detailsBlockDetail;

  /// No description provided for @chatStatusMutedEncrypted.
  ///
  /// In en, this message translates to:
  /// **'MUTED · ENCRYPTED'**
  String get chatStatusMutedEncrypted;

  /// No description provided for @chatStatusEncrypted.
  ///
  /// In en, this message translates to:
  /// **'ENCRYPTED'**
  String get chatStatusEncrypted;

  /// No description provided for @chatNoConversationMessage.
  ///
  /// In en, this message translates to:
  /// **'Pick a conversation from the chat list.'**
  String get chatNoConversationMessage;

  /// No description provided for @chatEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get chatEmptyTitle;

  /// No description provided for @chatEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Messages are stored as encrypted envelopes only the members can read.'**
  String get chatEmptyMessage;

  /// No description provided for @chatJumpToLatest.
  ///
  /// In en, this message translates to:
  /// **'Jump to latest'**
  String get chatJumpToLatest;

  /// No description provided for @chatReact.
  ///
  /// In en, this message translates to:
  /// **'React {reaction}'**
  String chatReact(String reaction);

  /// No description provided for @chatReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get chatReply;

  /// No description provided for @chatCopyText.
  ///
  /// In en, this message translates to:
  /// **'Copy text'**
  String get chatCopyText;

  /// No description provided for @chatEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatEdit;

  /// No description provided for @chatDeleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get chatDeleteForEveryone;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone?'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Members\' devices remove the text. The server never had it.'**
  String get chatDeleteMessage;

  /// No description provided for @chatDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDelete;

  /// No description provided for @chatEditEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter the new text, or delete the message instead.'**
  String get chatEditEmpty;

  /// No description provided for @chatEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get chatEditTitle;

  /// No description provided for @chatLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load messages'**
  String get chatLoadFailed;

  /// No description provided for @chatReplyEarlier.
  ///
  /// In en, this message translates to:
  /// **'Reply to an earlier message'**
  String get chatReplyEarlier;

  /// No description provided for @chatReplyDeleted.
  ///
  /// In en, this message translates to:
  /// **'Reply to a deleted message'**
  String get chatReplyDeleted;

  /// No description provided for @chatLoadOlder.
  ///
  /// In en, this message translates to:
  /// **'Load older messages'**
  String get chatLoadOlder;

  /// No description provided for @chatPendingSendingSemantics.
  ///
  /// In en, this message translates to:
  /// **'Encrypted message sending'**
  String get chatPendingSendingSemantics;

  /// No description provided for @chatPendingTerminalSemantics.
  ///
  /// In en, this message translates to:
  /// **'Encrypted message failed permanently. Copy or discard available.'**
  String get chatPendingTerminalSemantics;

  /// No description provided for @chatPendingFailedSemantics.
  ///
  /// In en, this message translates to:
  /// **'Encrypted message failed to send. Retry available.'**
  String get chatPendingFailedSemantics;

  /// No description provided for @chatPendingSending.
  ///
  /// In en, this message translates to:
  /// **'Sending encrypted message'**
  String get chatPendingSending;

  /// No description provided for @chatPendingTerminal.
  ///
  /// In en, this message translates to:
  /// **'Message needs attention'**
  String get chatPendingTerminal;

  /// No description provided for @chatPendingFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed'**
  String get chatPendingFailed;

  /// No description provided for @chatDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get chatDiscard;

  /// No description provided for @chatSenderYou.
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get chatSenderYou;

  /// No description provided for @chatAttachmentUnopenable.
  ///
  /// In en, this message translates to:
  /// **'This attachment cannot be opened.'**
  String get chatAttachmentUnopenable;

  /// No description provided for @chatMessageActions.
  ///
  /// In en, this message translates to:
  /// **'Message actions'**
  String get chatMessageActions;

  /// No description provided for @chatDeletedSemantics.
  ///
  /// In en, this message translates to:
  /// **'Deleted message from {sender}'**
  String chatDeletedSemantics(String sender);

  /// No description provided for @chatUnverifiedSemantics.
  ///
  /// In en, this message translates to:
  /// **'Message with an unverified sender, {time}'**
  String chatUnverifiedSemantics(String time);

  /// No description provided for @chatMessageSemantics.
  ///
  /// In en, this message translates to:
  /// **'Message from {sender}, {time}: {text}'**
  String chatMessageSemantics(String sender, String time, String text);

  /// No description provided for @chatAttachmentSemantics.
  ///
  /// In en, this message translates to:
  /// **'Attachment from {sender}, {time}'**
  String chatAttachmentSemantics(String sender, String time);

  /// No description provided for @chatEncryptedSemantics.
  ///
  /// In en, this message translates to:
  /// **'Encrypted message from {sender}, {time}'**
  String chatEncryptedSemantics(String sender, String time);

  /// No description provided for @chatMessageDeleted.
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get chatMessageDeleted;

  /// No description provided for @chatSenderUnverified.
  ///
  /// In en, this message translates to:
  /// **'Sender could not be verified. Message hidden.'**
  String get chatSenderUnverified;

  /// No description provided for @chatReactionCount.
  ///
  /// In en, this message translates to:
  /// **'{reaction} {count}'**
  String chatReactionCount(String reaction, int count);

  /// No description provided for @chatEdited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get chatEdited;

  /// No description provided for @chatReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to: {preview}'**
  String chatReplyingTo(String preview);

  /// No description provided for @chatCancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get chatCancelReply;

  /// No description provided for @chatSendingFile.
  ///
  /// In en, this message translates to:
  /// **'Sending file'**
  String get chatSendingFile;

  /// No description provided for @chatAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach a file'**
  String get chatAttachFile;

  /// No description provided for @chatComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatComposerHint;

  /// No description provided for @chatComposerCounter.
  ///
  /// In en, this message translates to:
  /// **'{length} / {max}'**
  String chatComposerCounter(int length, int max);

  /// No description provided for @chatPausedNotice.
  ///
  /// In en, this message translates to:
  /// **'Sending is paused here: the server rejected an encryption update for this conversation. Other conversations still work.'**
  String get chatPausedNotice;

  /// No description provided for @chatAttachment.
  ///
  /// In en, this message translates to:
  /// **'Attachment'**
  String get chatAttachment;

  /// No description provided for @chatAttachmentOne.
  ///
  /// In en, this message translates to:
  /// **'Attachment: {name}'**
  String chatAttachmentOne(String name);

  /// No description provided for @chatAttachmentMany.
  ///
  /// In en, this message translates to:
  /// **'Attachments: {name} and {count} more'**
  String chatAttachmentMany(String name, int count);

  /// No description provided for @demoBannerLabel.
  ///
  /// In en, this message translates to:
  /// **'Demo build · unreviewed encryption'**
  String get demoBannerLabel;

  /// No description provided for @demoBannerNotice.
  ///
  /// In en, this message translates to:
  /// **'{label}. Not for real conversations.'**
  String demoBannerNotice(String label);

  /// No description provided for @dateTimeJoined.
  ///
  /// In en, this message translates to:
  /// **'{date} · {time}'**
  String dateTimeJoined(String date, String time);

  /// No description provided for @backupErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'The server could not be reached. Try again; the restore continues where it stopped.'**
  String get backupErrorNetwork;

  /// No description provided for @backupErrorNotFound.
  ///
  /// In en, this message translates to:
  /// **'This recovery code is unknown, expired or already used.'**
  String get backupErrorNotFound;

  /// No description provided for @backupErrorBusy.
  ///
  /// In en, this message translates to:
  /// **'This backup is being downloaded elsewhere. Try again in a few minutes.'**
  String get backupErrorBusy;

  /// No description provided for @backupErrorWrongKey.
  ///
  /// In en, this message translates to:
  /// **'This recovery code does not open the backup.'**
  String get backupErrorWrongKey;

  /// No description provided for @backupErrorCorrupt.
  ///
  /// In en, this message translates to:
  /// **'The backup is damaged and cannot be restored.'**
  String get backupErrorCorrupt;

  /// No description provided for @backupErrorDeviceNotEmpty.
  ///
  /// In en, this message translates to:
  /// **'This device already has an account. Sign out and reset it before restoring a backup.'**
  String get backupErrorDeviceNotEmpty;

  /// No description provided for @backupErrorTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The backup is larger than this app supports.'**
  String get backupErrorTooLarge;

  /// No description provided for @backupErrorStorage.
  ///
  /// In en, this message translates to:
  /// **'This device could not store the backup.'**
  String get backupErrorStorage;

  /// No description provided for @syncErrorCursorExpired.
  ///
  /// In en, this message translates to:
  /// **'This device was away longer than the server keeps updates. Restore a backup or link this device again.'**
  String get syncErrorCursorExpired;

  /// No description provided for @syncErrorControlMissing.
  ///
  /// In en, this message translates to:
  /// **'An encryption update for a conversation is missing or damaged. Messages are paused so none are skipped.'**
  String get syncErrorControlMissing;

  /// No description provided for @syncErrorMlsState.
  ///
  /// In en, this message translates to:
  /// **'This device could not update its encryption state. Messages are paused so none are skipped.'**
  String get syncErrorMlsState;

  /// No description provided for @syncErrorUndecryptable.
  ///
  /// In en, this message translates to:
  /// **'A message could not be read on this device. Messages are paused so none are skipped.'**
  String get syncErrorUndecryptable;

  /// No description provided for @syncErrorUnsupportedEvent.
  ///
  /// In en, this message translates to:
  /// **'The server sent an update this app version does not know. Update the app, then try again.'**
  String get syncErrorUnsupportedEvent;

  /// No description provided for @syncErrorCryptoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Encryption is unavailable in this build, so encrypted updates cannot be applied.'**
  String get syncErrorCryptoUnavailable;

  /// No description provided for @syncErrorStopped.
  ///
  /// In en, this message translates to:
  /// **'Sync stopped. Try again.'**
  String get syncErrorStopped;

  /// No description provided for @apiErrorSessionInvalid.
  ///
  /// In en, this message translates to:
  /// **'Your session is no longer valid. Sign in again.'**
  String get apiErrorSessionInvalid;

  /// No description provided for @apiErrorInvalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed. Check your username and password.'**
  String get apiErrorInvalidCredentials;

  /// No description provided for @apiErrorRecentAuth.
  ///
  /// In en, this message translates to:
  /// **'Confirm your password before this sensitive action.'**
  String get apiErrorRecentAuth;

  /// No description provided for @apiErrorDeviceNotLinked.
  ///
  /// In en, this message translates to:
  /// **'This device must be linked before password sign-in.'**
  String get apiErrorDeviceNotLinked;

  /// No description provided for @apiErrorForbidden.
  ///
  /// In en, this message translates to:
  /// **'You do not have permission to do that.'**
  String get apiErrorForbidden;

  /// No description provided for @apiErrorNotFound.
  ///
  /// In en, this message translates to:
  /// **'That item was not found. It may have been removed.'**
  String get apiErrorNotFound;

  /// No description provided for @apiErrorAlreadySetup.
  ///
  /// In en, this message translates to:
  /// **'This server already has an owner. Sign in or join with an invite instead.'**
  String get apiErrorAlreadySetup;

  /// No description provided for @apiErrorLastOwner.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership before disabling the last owner account.'**
  String get apiErrorLastOwner;

  /// No description provided for @apiErrorWeakPassword.
  ///
  /// In en, this message translates to:
  /// **'Password must be 12–72 characters.'**
  String get apiErrorWeakPassword;

  /// No description provided for @apiErrorInvalidInvite.
  ///
  /// In en, this message translates to:
  /// **'That invite code is not valid, has expired, or has already been used up.'**
  String get apiErrorInvalidInvite;

  /// No description provided for @apiErrorInvalidDeviceLink.
  ///
  /// In en, this message translates to:
  /// **'That link code is not valid or has expired. Generate a new one on your linked device.'**
  String get apiErrorInvalidDeviceLink;

  /// No description provided for @apiErrorTranscriptMismatch.
  ///
  /// In en, this message translates to:
  /// **'The locally verified device credentials changed. Generate a new link and compare both devices again.'**
  String get apiErrorTranscriptMismatch;

  /// No description provided for @apiErrorInvalidDeviceName.
  ///
  /// In en, this message translates to:
  /// **'That device name is not valid.'**
  String get apiErrorInvalidDeviceName;

  /// No description provided for @apiErrorInvalidName.
  ///
  /// In en, this message translates to:
  /// **'That name is not valid.'**
  String get apiErrorInvalidName;

  /// No description provided for @apiErrorInvalidMaxUses.
  ///
  /// In en, this message translates to:
  /// **'The invite use limit is not valid.'**
  String get apiErrorInvalidMaxUses;

  /// No description provided for @apiErrorInvalidExpiry.
  ///
  /// In en, this message translates to:
  /// **'That expiry time is not valid.'**
  String get apiErrorInvalidExpiry;

  /// No description provided for @apiErrorInvalidConversationKind.
  ///
  /// In en, this message translates to:
  /// **'The server rejected this conversation type.'**
  String get apiErrorInvalidConversationKind;

  /// No description provided for @apiErrorInvalidRetention.
  ///
  /// In en, this message translates to:
  /// **'That disappearing-message duration is not supported.'**
  String get apiErrorInvalidRetention;

  /// No description provided for @apiErrorInvalidRole.
  ///
  /// In en, this message translates to:
  /// **'That member role is not valid.'**
  String get apiErrorInvalidRole;

  /// No description provided for @apiErrorAccountRequired.
  ///
  /// In en, this message translates to:
  /// **'Choose an account to add.'**
  String get apiErrorAccountRequired;

  /// No description provided for @apiErrorUploadTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That file is too large to upload.'**
  String get apiErrorUploadTooLarge;

  /// No description provided for @apiErrorKeyPackageRefused.
  ///
  /// In en, this message translates to:
  /// **'The server refused this build’s encryption keys. A client with production encryption support is required.'**
  String get apiErrorKeyPackageRefused;

  /// No description provided for @apiErrorStorage.
  ///
  /// In en, this message translates to:
  /// **'The server had a storage problem. Try again shortly.'**
  String get apiErrorStorage;

  /// No description provided for @apiErrorStorageFull.
  ///
  /// In en, this message translates to:
  /// **'The server is out of storage for this account. Delete older attachments or ask the administrator for more space.'**
  String get apiErrorStorageFull;

  /// No description provided for @apiErrorBlobIntegrity.
  ///
  /// In en, this message translates to:
  /// **'The encrypted attachment could not be verified. Discard it and try again.'**
  String get apiErrorBlobIntegrity;

  /// No description provided for @apiErrorSetupToken.
  ///
  /// In en, this message translates to:
  /// **'The setup token is missing or wrong. Use the one the server printed when it started (the demo keeps it in data/demo/setup-token).'**
  String get apiErrorSetupToken;

  /// No description provided for @apiErrorDraining.
  ///
  /// In en, this message translates to:
  /// **'The server is restarting. Try again shortly.'**
  String get apiErrorDraining;

  /// No description provided for @apiErrorIdempotencyConflict.
  ///
  /// In en, this message translates to:
  /// **'This message was already submitted with different data. Discard it and compose a new message.'**
  String get apiErrorIdempotencyConflict;

  /// No description provided for @apiErrorMessageExpired.
  ///
  /// In en, this message translates to:
  /// **'That message has expired.'**
  String get apiErrorMessageExpired;

  /// No description provided for @apiErrorRecoveryInProgress.
  ///
  /// In en, this message translates to:
  /// **'Another restore is already downloading this backup. Try again shortly.'**
  String get apiErrorRecoveryInProgress;

  /// No description provided for @apiErrorWriteRateLimited.
  ///
  /// In en, this message translates to:
  /// **'You are sending a lot right now. Wait a minute and try again.'**
  String get apiErrorWriteRateLimited;

  /// No description provided for @apiErrorServerStorageLow.
  ///
  /// In en, this message translates to:
  /// **'The server is almost out of space, so new messages and uploads are paused. Ask the administrator to free some up.'**
  String get apiErrorServerStorageLow;

  /// No description provided for @apiErrorDeviceLimit.
  ///
  /// In en, this message translates to:
  /// **'This account already has the most devices allowed. Remove one in Settings first.'**
  String get apiErrorDeviceLimit;

  /// No description provided for @apiErrorDeviceLinkLimit.
  ///
  /// In en, this message translates to:
  /// **'Too many device links are waiting. Finish or cancel one first.'**
  String get apiErrorDeviceLinkLimit;

  /// No description provided for @apiErrorConversationLimit.
  ///
  /// In en, this message translates to:
  /// **'You have reached the most conversations allowed on this server. Leave or delete one first.'**
  String get apiErrorConversationLimit;

  /// No description provided for @apiErrorConversationMemberLimit.
  ///
  /// In en, this message translates to:
  /// **'This conversation is full.'**
  String get apiErrorConversationMemberLimit;

  /// No description provided for @apiErrorConflict.
  ///
  /// In en, this message translates to:
  /// **'This changed on the server in the meantime. Refresh and try again.'**
  String get apiErrorConflict;

  /// No description provided for @apiErrorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a moment and try again.'**
  String get apiErrorRateLimited;

  /// No description provided for @apiErrorEncryption.
  ///
  /// In en, this message translates to:
  /// **'The server rejected the encrypted data from this build.'**
  String get apiErrorEncryption;

  /// No description provided for @apiErrorServer.
  ///
  /// In en, this message translates to:
  /// **'The server had a problem. Try again shortly.'**
  String get apiErrorServer;

  /// No description provided for @apiErrorInvalidRequest.
  ///
  /// In en, this message translates to:
  /// **'The server rejected the request. Check your input and try again.'**
  String get apiErrorInvalidRequest;

  /// No description provided for @errorUnexpectedResponse.
  ///
  /// In en, this message translates to:
  /// **'The server returned an unexpected response.'**
  String get errorUnexpectedResponse;

  /// No description provided for @errorConversationPaused.
  ///
  /// In en, this message translates to:
  /// **'Sending is paused in this conversation.'**
  String get errorConversationPaused;

  /// No description provided for @errorOutboxFull.
  ///
  /// In en, this message translates to:
  /// **'Your encrypted message queue is full. Send or discard a pending message before composing another.'**
  String get errorOutboxFull;

  /// No description provided for @errorConversationPausedDetail.
  ///
  /// In en, this message translates to:
  /// **'Sending is paused in this conversation because the server rejected an encryption update. Other conversations still work.'**
  String get errorConversationPausedDetail;

  /// No description provided for @errorEncryptionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This build does not include the production encryption engine yet, so this action is unavailable.'**
  String get errorEncryptionUnavailable;

  /// No description provided for @errorActionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This action is unavailable in this build.'**
  String get errorActionUnavailable;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorGeneric;

  /// No description provided for @errorTimeout.
  ///
  /// In en, this message translates to:
  /// **'The server took too long to respond. Try again.'**
  String get errorTimeout;

  /// No description provided for @errorUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check the instance URL and your connection.'**
  String get errorUnreachable;

  /// No description provided for @probeChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking the server…'**
  String get probeChecking;

  /// No description provided for @probeReached.
  ///
  /// In en, this message translates to:
  /// **'Veritra server reached.'**
  String get probeReached;

  /// No description provided for @probeConnectedTo.
  ///
  /// In en, this message translates to:
  /// **'Connected to {name}.'**
  String probeConnectedTo(String name);

  /// No description provided for @probeInvalidOrigin.
  ///
  /// In en, this message translates to:
  /// **'Enter an HTTPS server origin, for example https://chat.example.org.'**
  String get probeInvalidOrigin;

  /// No description provided for @probeInsecure.
  ///
  /// In en, this message translates to:
  /// **'Veritra requires HTTPS. Put a self-hosted server behind TLS with a trusted certificate or Caddy.'**
  String get probeInsecure;

  /// No description provided for @probeDnsFailure.
  ///
  /// In en, this message translates to:
  /// **'That address could not be found. Check the hostname and try again.'**
  String get probeDnsFailure;

  /// No description provided for @probeTlsFailure.
  ///
  /// In en, this message translates to:
  /// **'The server certificate was not accepted. Use a trusted certificate or configure Caddy TLS.'**
  String get probeTlsFailure;

  /// No description provided for @probeTimedOut.
  ///
  /// In en, this message translates to:
  /// **'The server took too long to respond. Check the address and connection.'**
  String get probeTimedOut;

  /// No description provided for @probeNotVeritra.
  ///
  /// In en, this message translates to:
  /// **'That address does not look like a Veritra server.'**
  String get probeNotVeritra;

  /// No description provided for @probeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check the address and your connection.'**
  String get probeUnavailable;

  /// No description provided for @outboxSendFailed.
  ///
  /// In en, this message translates to:
  /// **'This encrypted message could not be sent. Copy it or discard it.'**
  String get outboxSendFailed;

  /// No description provided for @recoveryRestoreFailed.
  ///
  /// In en, this message translates to:
  /// **'This device could not restore its encrypted session. Retry or continue to sign in without clearing local data.'**
  String get recoveryRestoreFailed;

  /// No description provided for @recoveryProfileLocked.
  ///
  /// In en, this message translates to:
  /// **'This profile is already open in another Veritra window. Close that window, then retry.'**
  String get recoveryProfileLocked;

  /// No description provided for @recoveryKeyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This device could not read its secure storage. Unlock the device and retry. Your messages are kept.'**
  String get recoveryKeyUnavailable;

  /// No description provided for @recoveryKeyMissing.
  ///
  /// In en, this message translates to:
  /// **'The key that protects this device\'s messages is missing or does not match. Nothing has been deleted. You can retry, or reset this device and link it again.'**
  String get recoveryKeyMissing;

  /// No description provided for @recoveryResetFailed.
  ///
  /// In en, this message translates to:
  /// **'The reset did not finish. Nothing was deleted. Retry.'**
  String get recoveryResetFailed;

  /// No description provided for @errorPasswordLoginNeedsLink.
  ///
  /// In en, this message translates to:
  /// **'Password login requires this device to be linked first.'**
  String get errorPasswordLoginNeedsLink;

  /// No description provided for @attachmentSendFailedState.
  ///
  /// In en, this message translates to:
  /// **'The attachment could not be sent.'**
  String get attachmentSendFailedState;

  /// No description provided for @errorRelinkRequired.
  ///
  /// In en, this message translates to:
  /// **'This device must be linked again.'**
  String get errorRelinkRequired;

  /// No description provided for @pushTestSent.
  ///
  /// In en, this message translates to:
  /// **'Test sent. A notification should arrive within a minute.'**
  String get pushTestSent;

  /// No description provided for @pushTestGone.
  ///
  /// In en, this message translates to:
  /// **'The push provider no longer accepts this device. Registering again.'**
  String get pushTestGone;

  /// No description provided for @pushTestRejected.
  ///
  /// In en, this message translates to:
  /// **'The push provider did not accept the test. Try again later.'**
  String get pushTestRejected;

  /// No description provided for @pushTestRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Wait a minute before sending another test.'**
  String get pushTestRateLimited;

  /// No description provided for @pushTestNotRegistered.
  ///
  /// In en, this message translates to:
  /// **'This device is not registered for push yet.'**
  String get pushTestNotRegistered;

  /// No description provided for @pushTestFailed.
  ///
  /// In en, this message translates to:
  /// **'The test could not be sent.'**
  String get pushTestFailed;

  /// No description provided for @errorServerNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'This build does not allow the server address {url}. Use an https:// server origin.'**
  String errorServerNotAllowed(String url);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
