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
