import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_sr.dart';

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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('sr'),
    Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn')
  ];

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

  /// Snackbar action that reverses what was just done.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get commonUndo;

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

  /// Inline error when a community or channel name has control, line-break or direction characters.
  ///
  /// In en, this message translates to:
  /// **'That name has characters that are not allowed.'**
  String get validationNameInvalid;

  /// Inline error under a channel topic field.
  ///
  /// In en, this message translates to:
  /// **'That topic is too long or has characters that are not allowed.'**
  String get validationTopicInvalid;

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

  /// No description provided for @settingsHideNotificationPreview.
  ///
  /// In en, this message translates to:
  /// **'Hide message preview'**
  String get settingsHideNotificationPreview;

  /// No description provided for @settingsHideNotificationPreviewDetail.
  ///
  /// In en, this message translates to:
  /// **'Notifications say \"New message\" and show no sender or text.'**
  String get settingsHideNotificationPreviewDetail;

  /// No description provided for @notificationNewMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get notificationNewMessage;

  /// No description provided for @trayOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get trayOpen;

  /// No description provided for @trayQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get trayQuit;

  /// No description provided for @settingsSectionPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get settingsSectionPrivacy;

  /// No description provided for @settingsSectionPrivacySafety.
  ///
  /// In en, this message translates to:
  /// **'Privacy and safety'**
  String get settingsSectionPrivacySafety;

  /// No description provided for @settingsReadReceiptsTitle.
  ///
  /// In en, this message translates to:
  /// **'Read receipts'**
  String get settingsReadReceiptsTitle;

  /// No description provided for @settingsReadReceiptsDetail.
  ///
  /// In en, this message translates to:
  /// **'Applies to all your devices. When off, you send no read receipts and you do not see when others have read your messages. Sent and delivered ticks stay.'**
  String get settingsReadReceiptsDetail;

  /// No description provided for @settingsReadReceiptsFailed.
  ///
  /// In en, this message translates to:
  /// **'The setting could not be changed. Check your connection and try again.'**
  String get settingsReadReceiptsFailed;

  /// No description provided for @settingsReadReceiptsNotSaved.
  ///
  /// In en, this message translates to:
  /// **'This device could not save the setting. It applies for now but may reset when the app restarts.'**
  String get settingsReadReceiptsNotSaved;

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

  /// No description provided for @settingsDeviceListSetup.
  ///
  /// In en, this message translates to:
  /// **'Approve your devices'**
  String get settingsDeviceListSetup;

  /// No description provided for @settingsDeviceListSetupDetail.
  ///
  /// In en, this message translates to:
  /// **'Your contacts can\'t add your devices to chats until you confirm which ones are yours.'**
  String get settingsDeviceListSetupDetail;

  /// No description provided for @settingsRecoveryRetype.
  ///
  /// In en, this message translates to:
  /// **'Type your recovery key again to finish recovery'**
  String get settingsRecoveryRetype;

  /// No description provided for @settingsRecoveryRetypeDetail.
  ///
  /// In en, this message translates to:
  /// **'Your contacts can\'t add this device to chats until you do.'**
  String get settingsRecoveryRetypeDetail;

  /// No description provided for @settingsRecoveryConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm your recovery key to keep recovery working'**
  String get settingsRecoveryConfirm;

  /// No description provided for @settingsRecoveryConfirmDetail.
  ///
  /// In en, this message translates to:
  /// **'Your recovery key was set before approved-device lists. Type it once, or recovering your account with it will be refused.'**
  String get settingsRecoveryConfirmDetail;

  /// No description provided for @deviceListReviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Which devices are yours?'**
  String get deviceListReviewTitle;

  /// No description provided for @deviceListReviewBody.
  ///
  /// In en, this message translates to:
  /// **'Untick any device you don\'t recognise. The ticked ones become your approved devices; the others are signed out.'**
  String get deviceListReviewBody;

  /// No description provided for @deviceListReviewConfirm.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get deviceListReviewConfirm;

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

  /// No description provided for @settingsTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get settingsTurnOn;

  /// No description provided for @settingsPushProvider.
  ///
  /// In en, this message translates to:
  /// **'Delivery service'**
  String get settingsPushProvider;

  /// No description provided for @settingsPushProviderDetail.
  ///
  /// In en, this message translates to:
  /// **'Choose an Android UnifiedPush delivery service'**
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

  /// No description provided for @settingsDirectCallsTitle.
  ///
  /// In en, this message translates to:
  /// **'Direct calls'**
  String get settingsDirectCallsTitle;

  /// No description provided for @settingsDirectCallsNote.
  ///
  /// In en, this message translates to:
  /// **'Faster; the other person sees your IP.'**
  String get settingsDirectCallsNote;

  /// No description provided for @settingsDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// No description provided for @settingsDeleteAccountDetail.
  ///
  /// In en, this message translates to:
  /// **'Permanently deletes your account, its devices and its keys on the server. Messages you already sent stay in other people\'s chats, encrypted.'**
  String get settingsDeleteAccountDetail;

  /// Identity header when the server gave no username.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get settingsSignedIn;

  /// No description provided for @settingsRevokeDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out device?'**
  String get settingsRevokeDeviceTitle;

  /// No description provided for @settingsRevokeDeviceMessage.
  ///
  /// In en, this message translates to:
  /// **'\"{deviceName}\" will lose access immediately.'**
  String settingsRevokeDeviceMessage(String deviceName);

  /// Title of the confirmation for signing a device out.
  ///
  /// In en, this message translates to:
  /// **'Sign out \"{deviceName}\"?'**
  String settingsSignOutDeviceTitle(String deviceName);

  /// No description provided for @settingsSignOutDeviceButton.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get settingsSignOutDeviceButton;

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
  /// **'This permanently deletes your account. You lose:\n• your sign-in, passkeys, username and profile\n• every device signed in to it\n• your memberships, uploaded files, backups and recovery key on the server\n\nMessages you already sent stay in other people\'s chats, encrypted, and some encrypted records may stay under the server\'s retention rules. This cannot be undone.'**
  String get settingsDeleteAccountMessage;

  /// No description provided for @settingsDeleteAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
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
  /// **'This server has no notification delivery service'**
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

  /// No description provided for @settingsPushNotAllowedTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications are not allowed yet'**
  String get settingsPushNotAllowedTitle;

  /// No description provided for @settingsPushNotAllowedDetail.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications below to be alerted. Until then the app syncs when woken but shows nothing.'**
  String get settingsPushNotAllowedDetail;

  /// No description provided for @settingsPushUnconfirmedTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications cannot be confirmed'**
  String get settingsPushUnconfirmedTitle;

  /// No description provided for @settingsPushUnconfirmedDetail.
  ///
  /// In en, this message translates to:
  /// **'This device did not confirm that notifications are allowed, so none may be shown. Check the system settings for Veritra.'**
  String get settingsPushUnconfirmedDetail;

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
  /// **'Signed out'**
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
  /// **'Turn off this invite?'**
  String get inviteRevokeTitle;

  /// No description provided for @inviteRevokeMessage.
  ///
  /// In en, this message translates to:
  /// **'It stops working immediately. People who already joined with it keep their accounts.'**
  String get inviteRevokeMessage;

  /// No description provided for @inviteTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get inviteTurnOff;

  /// No description provided for @inviteCannotReshare.
  ///
  /// In en, this message translates to:
  /// **'Can\'t be shared again'**
  String get inviteCannotReshare;

  /// No description provided for @connectFreshInstanceTitle.
  ///
  /// In en, this message translates to:
  /// **'This server is new'**
  String get connectFreshInstanceTitle;

  /// No description provided for @connectFreshInstanceMessage.
  ///
  /// In en, this message translates to:
  /// **'No owner account exists yet — create it below.'**
  String get connectFreshInstanceMessage;

  /// No description provided for @connectFreshInstanceAction.
  ///
  /// In en, this message translates to:
  /// **'Set up this server'**
  String get connectFreshInstanceAction;

  /// No description provided for @connectInstanceUrl.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get connectInstanceUrl;

  /// No description provided for @connectCheckApproval.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
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
  /// **'Type this code on your other device'**
  String get connectVerificationTitle;

  /// No description provided for @connectVerificationMessage.
  ///
  /// In en, this message translates to:
  /// **'On the device you already use, type this code. Never send it to anyone or read it out to them.'**
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
  /// **'From an admin of this server'**
  String get connectInviteCodeHint;

  /// No description provided for @connectInviteLink.
  ///
  /// In en, this message translates to:
  /// **'Invite link'**
  String get connectInviteLink;

  /// No description provided for @connectInviteLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the link you were sent'**
  String get connectInviteLinkHint;

  /// No description provided for @connectInviteLinkRequired.
  ///
  /// In en, this message translates to:
  /// **'Paste the invite link you received.'**
  String get connectInviteLinkRequired;

  /// No description provided for @connectInviteLinkInvalid.
  ///
  /// In en, this message translates to:
  /// **'This is not a Veritra invite link. Check that you copied all of it.'**
  String get connectInviteLinkInvalid;

  /// No description provided for @connectInviteTypeInstead.
  ///
  /// In en, this message translates to:
  /// **'Type the server address and code instead'**
  String get connectInviteTypeInstead;

  /// No description provided for @connectInviteLinkInstead.
  ///
  /// In en, this message translates to:
  /// **'Paste an invite link instead'**
  String get connectInviteLinkInstead;

  /// No description provided for @connectJoinLinkDetail.
  ///
  /// In en, this message translates to:
  /// **'Paste the invite link you were sent, or scan its QR code.'**
  String get connectJoinLinkDetail;

  /// No description provided for @connectJoinAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a username and password'**
  String get connectJoinAccountTitle;

  /// No description provided for @connectJoiningServer.
  ///
  /// In en, this message translates to:
  /// **'Joining {server}'**
  String connectJoiningServer(String server);

  /// No description provided for @connectJoinChangeServer.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get connectJoinChangeServer;

  /// No description provided for @connectScanInviteTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan invite QR'**
  String get connectScanInviteTitle;

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
  /// **'Your name on this server'**
  String get connectUsernameHint;

  /// No description provided for @connectUsernameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use 3 to 32 letters, digits, _ or -.'**
  String get connectUsernameInvalid;

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
  /// **'Setup code'**
  String get connectSetupToken;

  /// No description provided for @connectSetupTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Required unless connecting on loopback'**
  String get connectSetupTokenHint;

  /// No description provided for @connectUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address.'**
  String get connectUrlRequired;

  /// No description provided for @connectUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a full URL, e.g. https://chat.example.org'**
  String get connectUrlInvalid;

  /// No description provided for @connectUrlOriginOnly.
  ///
  /// In en, this message translates to:
  /// **'Enter only the server address, with no path, e.g. https://chat.example.org'**
  String get connectUrlOriginOnly;

  /// No description provided for @connectUrlHttpsRequired.
  ///
  /// In en, this message translates to:
  /// **'Veritra requires HTTPS. Use an https:// server address.'**
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
  /// **'First run only: create the owner account on a new self-hosted server.'**
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
  /// **'Server address filled. Check it before continuing.'**
  String get connectOriginFilled;

  /// No description provided for @connectConfirmServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm server'**
  String get connectConfirmServerTitle;

  /// No description provided for @connectConfirmServerMessage.
  ///
  /// In en, this message translates to:
  /// **'This QR code suggests {origin}. The app will still check the server before using it. Continue with this HTTPS address?'**
  String connectConfirmServerMessage(String origin);

  /// No description provided for @connectUseOrigin.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
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
  /// **'Add this phone'**
  String get connectSubmitLink;

  /// No description provided for @connectTagline.
  ///
  /// In en, this message translates to:
  /// **'Self-hosted, end-to-end encrypted messaging'**
  String get connectTagline;

  /// No description provided for @connectStepBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get connectStepBack;

  /// No description provided for @welcomeHaveInvite.
  ///
  /// In en, this message translates to:
  /// **'I have an invite'**
  String get welcomeHaveInvite;

  /// No description provided for @welcomeHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'I already have an account'**
  String get welcomeHaveAccount;

  /// No description provided for @welcomeSetUpServer.
  ///
  /// In en, this message translates to:
  /// **'Set up a new server'**
  String get welcomeSetUpServer;

  /// No description provided for @welcomeAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'How do you want to sign in?'**
  String get welcomeAccountTitle;

  /// No description provided for @welcomeNewDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'This is a new device'**
  String get welcomeNewDeviceTitle;

  /// No description provided for @welcomeNewDeviceDetail.
  ///
  /// In en, this message translates to:
  /// **'Add it using a device you already use.'**
  String get welcomeNewDeviceDetail;

  /// No description provided for @welcomeSignedInBeforeTitle.
  ///
  /// In en, this message translates to:
  /// **'I\'ve signed in here before'**
  String get welcomeSignedInBeforeTitle;

  /// No description provided for @welcomeSignedInBeforeDetail.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your username and password.'**
  String get welcomeSignedInBeforeDetail;

  /// No description provided for @welcomeLostDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'I lost all my devices'**
  String get welcomeLostDevicesTitle;

  /// No description provided for @welcomeLostDevicesDetail.
  ///
  /// In en, this message translates to:
  /// **'Get back in with your password and recovery key.'**
  String get welcomeLostDevicesDetail;

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

  /// No description provided for @qrPointCameraInvite.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the invite QR code.'**
  String get qrPointCameraInvite;

  /// No description provided for @qrPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Veritra needs the camera to scan. Allow it in Settings, or type the code instead.'**
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

  /// No description provided for @qrOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get qrOpenSettings;

  /// No description provided for @qrOpenSettingsFailed.
  ///
  /// In en, this message translates to:
  /// **'Settings could not be opened. Allow the camera for Veritra in your device\'s settings.'**
  String get qrOpenSettingsFailed;

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
  /// **'Message'**
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

  /// No description provided for @accountPickerKnown.
  ///
  /// In en, this message translates to:
  /// **'People you know'**
  String get accountPickerKnown;

  /// No description provided for @accountPickerNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No account found with that exact username.'**
  String get accountPickerNoMatch;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search communities, channels or @username…'**
  String get searchHint;

  /// No description provided for @searchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get searchClear;

  /// No description provided for @searchLookUpAccount.
  ///
  /// In en, this message translates to:
  /// **'Look up an @username'**
  String get searchLookUpAccount;

  /// No description provided for @searchIntroTitle.
  ///
  /// In en, this message translates to:
  /// **'Search people and communities'**
  String get searchIntroTitle;

  /// No description provided for @searchIntroMessage.
  ///
  /// In en, this message translates to:
  /// **'Communities and channels are found on this device as you type. To find a person, type @ and their exact username, then press Enter: only that is sent to the server. Message contents are end-to-end encrypted and never searchable on the server.'**
  String get searchIntroMessage;

  /// No description provided for @searchNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get searchNoResultsTitle;

  /// No description provided for @searchNoResultsMessage.
  ///
  /// In en, this message translates to:
  /// **'Nothing matched. To find a person, type @ and their exact username. Only communities and channels whose names this device holds can be found.'**
  String get searchNoResultsMessage;

  /// No description provided for @searchNoOpenChannel.
  ///
  /// In en, this message translates to:
  /// **'No channel you can open yet'**
  String get searchNoOpenChannel;

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

  /// Heading over community results in the People search.
  ///
  /// In en, this message translates to:
  /// **'Communities'**
  String get searchHeadingCommunities;

  /// Heading over channel results in the People search.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get searchHeadingChannels;

  /// Heading over conversation results in the People search.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get searchHeadingConversations;

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

  /// No description provided for @searchBlockConfirm.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get searchBlockConfirm;

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

  /// No description provided for @inviteLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Your invites could not be loaded. Check the connection and try again.'**
  String get inviteLoadFailed;

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

  /// No description provided for @inviteUsedOf.
  ///
  /// In en, this message translates to:
  /// **'{uses} of {maxUses} used'**
  String inviteUsedOf(int uses, int maxUses);

  /// No description provided for @inviteUsedUnlimited.
  ///
  /// In en, this message translates to:
  /// **'{uses} used'**
  String inviteUsedUnlimited(int uses);

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

  /// No description provided for @inviteExpiresIn.
  ///
  /// In en, this message translates to:
  /// **'Expires in {time}'**
  String inviteExpiresIn(String time);

  /// No description provided for @inviteExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get inviteExpired;

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

  /// No description provided for @inviteCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get inviteCopyLink;

  /// No description provided for @inviteLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite link copied.'**
  String get inviteLinkCopied;

  /// No description provided for @inviteShowQr.
  ///
  /// In en, this message translates to:
  /// **'Show QR code'**
  String get inviteShowQr;

  /// No description provided for @inviteQrTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite QR code'**
  String get inviteQrTitle;

  /// No description provided for @inviteQrHint.
  ///
  /// In en, this message translates to:
  /// **'On the new phone, open Veritra, tap “I have an invite” and scan this code.'**
  String get inviteQrHint;

  /// No description provided for @profileThisInstance.
  ///
  /// In en, this message translates to:
  /// **'this server'**
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

  /// No description provided for @profileDisplaySection.
  ///
  /// In en, this message translates to:
  /// **'Display name and photo'**
  String get profileDisplaySection;

  /// No description provided for @profileDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get profileDisplayNameLabel;

  /// No description provided for @profileDisplayNameHint.
  ///
  /// In en, this message translates to:
  /// **'How people you chat with see you'**
  String get profileDisplayNameHint;

  /// No description provided for @profileDisplayHelp.
  ///
  /// In en, this message translates to:
  /// **'Only people you share a chat with can see your name and photo. The server can\'t read them.'**
  String get profileDisplayHelp;

  /// No description provided for @profileEditTile.
  ///
  /// In en, this message translates to:
  /// **'Name and photo'**
  String get profileEditTile;

  /// No description provided for @profileEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Name and photo'**
  String get profileEditTitle;

  /// No description provided for @profilePhotoChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get profilePhotoChoose;

  /// No description provided for @profilePhotoRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get profilePhotoRemove;

  /// No description provided for @profilePhotoUnusable.
  ///
  /// In en, this message translates to:
  /// **'That picture can\'t be used. Try another one.'**
  String get profilePhotoUnusable;

  /// No description provided for @profileSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get profileSave;

  /// No description provided for @profileSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get profileSaved;

  /// No description provided for @profileSaveConflict.
  ///
  /// In en, this message translates to:
  /// **'This profile was changed on another device. Try again in a moment.'**
  String get profileSaveConflict;

  /// No description provided for @profileSaveInvalid.
  ///
  /// In en, this message translates to:
  /// **'That name or photo can\'t be used.'**
  String get profileSaveInvalid;

  /// No description provided for @profileNameTooLong.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters.'**
  String profileNameTooLong(int max);

  /// No description provided for @profileNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use letters and numbers; no control or direction characters.'**
  String get profileNameInvalid;

  /// No description provided for @groupProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'Group name and photo'**
  String get groupProfileTitle;

  /// No description provided for @groupProfileNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupProfileNameLabel;

  /// No description provided for @groupProfileHelp.
  ///
  /// In en, this message translates to:
  /// **'Members of this group can see its name and photo. The server can\'t read them.'**
  String get groupProfileHelp;

  /// No description provided for @profileBlockNote.
  ///
  /// In en, this message translates to:
  /// **'In groups you share, they may still see your profile.'**
  String get profileBlockNote;

  /// No description provided for @profileSectionIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get profileSectionIdentity;

  /// No description provided for @profileSectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get profileSectionAdvanced;

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
  /// **'Server role'**
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

  /// Short label of the Join action in the Communities top bar. Its tooltip and screen-reader name is the longer "Join with a link".
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get communityJoinAction;

  /// Short label of the New action in the Communities top bar. Its tooltip and screen-reader name is "New community".
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get communityNewAction;

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

  /// Label of the menu on a community card that holds edit, categories, roles, reports and new channel.
  ///
  /// In en, this message translates to:
  /// **'Actions for {community}'**
  String communityActionsTooltip(String community);

  /// No description provided for @communityNoChannelsHint.
  ///
  /// In en, this message translates to:
  /// **'Use + to create the first one.'**
  String get communityNoChannelsHint;

  /// No description provided for @communityPlaceholderName.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get communityPlaceholderName;

  /// No description provided for @channelPlaceholderName.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get channelPlaceholderName;

  /// No description provided for @channelPrivatePlaceholderName.
  ///
  /// In en, this message translates to:
  /// **'Private channel'**
  String get channelPrivatePlaceholderName;

  /// No description provided for @communityInfoEditFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the info. Try again.'**
  String get communityInfoEditFailed;

  /// No description provided for @communityEditInfo.
  ///
  /// In en, this message translates to:
  /// **'Edit community'**
  String get communityEditInfo;

  /// No description provided for @channelEditInfo.
  ///
  /// In en, this message translates to:
  /// **'Edit channel'**
  String get channelEditInfo;

  /// No description provided for @channelTopic.
  ///
  /// In en, this message translates to:
  /// **'Topic'**
  String get channelTopic;

  /// No description provided for @channelEditFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the channel. Try again.'**
  String get channelEditFailed;

  /// No description provided for @channelSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get channelSave;

  /// Edit community or channel: shown beside Save when Save is disabled because this account may no longer edit.
  ///
  /// In en, this message translates to:
  /// **'You cannot save changes here any more, because your role or account has changed.'**
  String get channelEditNotAllowed;

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
  /// **'Your messages and settings come back on this device. The backup holds no sign-in, so this device then joins your account as a new device.'**
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
  /// **'Add a new phone or computer to your account in three steps. On the new device, open Veritra and choose Link this device.'**
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

  /// No description provided for @deviceLinkApproveHint.
  ///
  /// In en, this message translates to:
  /// **'The new device now shows an 8-digit code. Type it here.'**
  String get deviceLinkApproveHint;

  /// No description provided for @deviceLinkApproveWarning.
  ///
  /// In en, this message translates to:
  /// **'Never use a code someone sent you or read out to you. Type only the code you see yourself on the new device\'s screen.'**
  String get deviceLinkApproveWarning;

  /// No description provided for @deviceLinkCodeField.
  ///
  /// In en, this message translates to:
  /// **'Code from the new device'**
  String get deviceLinkCodeField;

  /// No description provided for @deviceLinkCompareTitle.
  ///
  /// In en, this message translates to:
  /// **'Type the code from the new device'**
  String get deviceLinkCompareTitle;

  /// No description provided for @deviceLinkStepScan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get deviceLinkStepScan;

  /// No description provided for @deviceLinkStepCompare.
  ///
  /// In en, this message translates to:
  /// **'Compare'**
  String get deviceLinkStepCompare;

  /// No description provided for @deviceLinkStepDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get deviceLinkStepDone;

  /// No description provided for @deviceLinkStepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of 3: {name}'**
  String deviceLinkStepOf(int step, String name);

  /// No description provided for @deviceLinkScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan this code with the new device'**
  String get deviceLinkScanTitle;

  /// No description provided for @deviceLinkExpiresAt.
  ///
  /// In en, this message translates to:
  /// **'This code works until {time}.'**
  String deviceLinkExpiresAt(String time);

  /// No description provided for @deviceLinkWaitingClaim.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the new device. This screen updates by itself.'**
  String get deviceLinkWaitingClaim;

  /// No description provided for @deviceLinkCannotScan.
  ///
  /// In en, this message translates to:
  /// **'Cannot scan?'**
  String get deviceLinkCannotScan;

  /// No description provided for @deviceLinkTypeCodeHint.
  ///
  /// In en, this message translates to:
  /// **'On the new device, choose to type the link code, then enter this one:'**
  String get deviceLinkTypeCodeHint;

  /// No description provided for @deviceLinkNewDevice.
  ///
  /// In en, this message translates to:
  /// **'New device: {name}'**
  String deviceLinkNewDevice(String name);

  /// No description provided for @deviceLinkChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking the new device. If this does not change, try again.'**
  String get deviceLinkChecking;

  /// No description provided for @deviceLinkDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Your new device is linked'**
  String get deviceLinkDoneTitle;

  /// No description provided for @deviceLinkDoneDetail.
  ///
  /// In en, this message translates to:
  /// **'Your chat history is copied to it, encrypted. Keep both devices online until it finishes.'**
  String get deviceLinkDoneDetail;

  /// No description provided for @deviceLinkEndedHere.
  ///
  /// In en, this message translates to:
  /// **'This link has ended. Create a new one to link a device.'**
  String get deviceLinkEndedHere;

  /// No description provided for @deviceLinkUnavailableHere.
  ///
  /// In en, this message translates to:
  /// **'Linking devices is not available in this build.'**
  String get deviceLinkUnavailableHere;

  /// No description provided for @deviceLinkAlreadyPending.
  ///
  /// In en, this message translates to:
  /// **'A device link is already waiting on this device. Check it or cancel it first.'**
  String get deviceLinkAlreadyPending;

  /// No description provided for @deviceLinkRecoveryInProgress.
  ///
  /// In en, this message translates to:
  /// **'An account recovery is waiting on this device, so a device cannot be linked here until it is finished or cancelled.'**
  String get deviceLinkRecoveryInProgress;

  /// No description provided for @deviceLinkEnded.
  ///
  /// In en, this message translates to:
  /// **'This link was cancelled or has expired. Ask your other device for a new one.'**
  String get deviceLinkEnded;

  /// No description provided for @deviceLinkApprovalInvalid.
  ///
  /// In en, this message translates to:
  /// **'That approval could not be verified, so this device was not linked. Create a new link on your other device and try again.'**
  String get deviceLinkApprovalInvalid;

  /// No description provided for @deviceLinkCodeMismatch.
  ///
  /// In en, this message translates to:
  /// **'That code does not match the one on the new device. Check it and try again.'**
  String get deviceLinkCodeMismatch;

  /// No description provided for @deviceLinkRefreshFirst.
  ///
  /// In en, this message translates to:
  /// **'Refresh the status first, then approve the device.'**
  String get deviceLinkRefreshFirst;

  /// No description provided for @deviceLinkCancelWaiting.
  ///
  /// In en, this message translates to:
  /// **'Cancel this link'**
  String get deviceLinkCancelWaiting;

  /// No description provided for @deviceLinkWaitingApproval.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your other device to approve. This screen updates by itself.'**
  String get deviceLinkWaitingApproval;

  /// No description provided for @deviceLinkWaitingCode.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your other device. The code to confirm appears here in a moment.'**
  String get deviceLinkWaitingCode;

  /// No description provided for @deviceLinkCommitmentMismatch.
  ///
  /// In en, this message translates to:
  /// **'Your other device\'s link check did not match, so this device was not linked. Create a new link on your other device and try again.'**
  String get deviceLinkCommitmentMismatch;

  /// No description provided for @historyCopySendWorking.
  ///
  /// In en, this message translates to:
  /// **'Sending your history to the new device…'**
  String get historyCopySendWorking;

  /// No description provided for @historyCopySendWaiting.
  ///
  /// In en, this message translates to:
  /// **'Your history is ready. Waiting for the new device to receive it.'**
  String get historyCopySendWaiting;

  /// No description provided for @historyCopyReceiveWorking.
  ///
  /// In en, this message translates to:
  /// **'Receiving your history from your other device…'**
  String get historyCopyReceiveWorking;

  /// No description provided for @historyCopyReceiveWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your other device to send your history. Keep it online.'**
  String get historyCopyReceiveWaiting;

  /// No description provided for @historyCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Copying your history did not finish. It will be tried again.'**
  String get historyCopyFailed;

  /// No description provided for @historyCopyEnded.
  ///
  /// In en, this message translates to:
  /// **'Copying your history stopped. Link the device again to copy it.'**
  String get historyCopyEnded;

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

  /// Button under the one notice that is showing, when others are folded behind it.
  ///
  /// In en, this message translates to:
  /// **'{count} more'**
  String noticesMore(int count);

  /// No description provided for @noticesShowFewer.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get noticesShowFewer;

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

  /// No description provided for @bannerRestoreBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore from backup'**
  String get bannerRestoreBackup;

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

  /// No description provided for @chatListStartChat.
  ///
  /// In en, this message translates to:
  /// **'Start a chat'**
  String get chatListStartChat;

  /// No description provided for @chatListInviteSomeone.
  ///
  /// In en, this message translates to:
  /// **'Invite someone'**
  String get chatListInviteSomeone;

  /// No description provided for @chatListArchivedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No archived chats'**
  String get chatListArchivedEmptyTitle;

  /// No description provided for @chatListArchivedEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Chats you archive are kept here, out of your main list.'**
  String get chatListArchivedEmptyMessage;

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

  /// No description provided for @chatPreviewYou.
  ///
  /// In en, this message translates to:
  /// **'You: {text}'**
  String chatPreviewYou(String text);

  /// No description provided for @chatPreviewFrom.
  ///
  /// In en, this message translates to:
  /// **'{name}: {text}'**
  String chatPreviewFrom(String name, String text);

  /// No description provided for @chatPreviewPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get chatPreviewPhoto;

  /// No description provided for @chatPreviewVoiceNote.
  ///
  /// In en, this message translates to:
  /// **'Voice note'**
  String get chatPreviewVoiceNote;

  /// No description provided for @chatPreviewPoll.
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get chatPreviewPoll;

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

  /// No description provided for @durationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second} other{{count} seconds}}'**
  String durationSeconds(int count);

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
  /// **'Compare this number with the other members to be sure nobody else can read this chat.'**
  String get safetyGroupIntro;

  /// No description provided for @safetyPeerIntro.
  ///
  /// In en, this message translates to:
  /// **'Compare this number with {peer} to be sure nobody else can read your chat.'**
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

  /// No description provided for @safetyChangedWhileComparing.
  ///
  /// In en, this message translates to:
  /// **'The safety number changed while you were comparing it, so nothing was saved. Compare the new number again.'**
  String get safetyChangedWhileComparing;

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

  /// No description provided for @safetyHowTitle.
  ///
  /// In en, this message translates to:
  /// **'How are you comparing?'**
  String get safetyHowTitle;

  /// No description provided for @safetyTogether.
  ///
  /// In en, this message translates to:
  /// **'We are together'**
  String get safetyTogether;

  /// No description provided for @safetyTogetherDetail.
  ///
  /// In en, this message translates to:
  /// **'Scan each other\'s code.'**
  String get safetyTogetherDetail;

  /// No description provided for @safetyOnCall.
  ///
  /// In en, this message translates to:
  /// **'We are on a call'**
  String get safetyOnCall;

  /// No description provided for @safetyOnCallDetail.
  ///
  /// In en, this message translates to:
  /// **'Read the number aloud to each other.'**
  String get safetyOnCallDetail;

  /// No description provided for @safetyTogetherSteps.
  ///
  /// In en, this message translates to:
  /// **'Let them scan this code with their phone, then scan theirs.'**
  String get safetyTogetherSteps;

  /// No description provided for @safetyTogetherNoCamera.
  ///
  /// In en, this message translates to:
  /// **'Let them scan this code with their phone, or compare the numbers below.'**
  String get safetyTogetherNoCamera;

  /// No description provided for @safetyCompareByEye.
  ///
  /// In en, this message translates to:
  /// **'Or compare the numbers group by group. Every group must be the same:'**
  String get safetyCompareByEye;

  /// No description provided for @safetyCallSteps.
  ///
  /// In en, this message translates to:
  /// **'Take turns reading the groups aloud, row by row. Every group must be the same. Only then mark the number as verified.'**
  String get safetyCallSteps;

  /// No description provided for @safetyOtherWay.
  ///
  /// In en, this message translates to:
  /// **'Compare another way'**
  String get safetyOtherWay;

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

  /// No description provided for @detailsActionMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get detailsActionMute;

  /// No description provided for @detailsActionUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get detailsActionUnmute;

  /// No description provided for @detailsActionCall.
  ///
  /// In en, this message translates to:
  /// **'Call'**
  String get detailsActionCall;

  /// No description provided for @detailsSectionMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get detailsSectionMembers;

  /// Tab on a community page (admins): invitation links.
  ///
  /// In en, this message translates to:
  /// **'Invites'**
  String get communityTabInvites;

  /// Tab on a community page (admins): requests to join.
  ///
  /// In en, this message translates to:
  /// **'Requests'**
  String get communityTabRequests;

  /// No description provided for @detailsSectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get detailsSectionAdvanced;

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

  /// No description provided for @detailsRetentionLocked.
  ///
  /// In en, this message translates to:
  /// **'Only an owner, admin or moderator of this chat can change this.'**
  String get detailsRetentionLocked;

  /// No description provided for @detailsRetentionLockedDm.
  ///
  /// In en, this message translates to:
  /// **'Only the person who started this chat can change this.'**
  String get detailsRetentionLockedDm;

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

  /// No description provided for @chatStatusMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get chatStatusMuted;

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

  /// No description provided for @chatEmptyMessageDm.
  ///
  /// In en, this message translates to:
  /// **'Only you two can read this.'**
  String get chatEmptyMessageDm;

  /// No description provided for @chatEmptyMessageGroup.
  ///
  /// In en, this message translates to:
  /// **'Only the members can read this.'**
  String get chatEmptyMessageGroup;

  /// No description provided for @chatNoticeEncryptedDm.
  ///
  /// In en, this message translates to:
  /// **'Messages here are end-to-end encrypted. Only you two can read them.'**
  String get chatNoticeEncryptedDm;

  /// No description provided for @chatNoticeEncryptedGroup.
  ///
  /// In en, this message translates to:
  /// **'Messages here are end-to-end encrypted. Only the members can read them.'**
  String get chatNoticeEncryptedGroup;

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

  /// No description provided for @chatSelectText.
  ///
  /// In en, this message translates to:
  /// **'Select text'**
  String get chatSelectText;

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

  /// No description provided for @chatPendingNotSentRetry.
  ///
  /// In en, this message translates to:
  /// **'Not sent · Retry'**
  String get chatPendingNotSentRetry;

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

  /// No description provided for @chatMessageUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This message needs a newer version of Veritra'**
  String get chatMessageUnsupported;

  /// No description provided for @chatMessageInvalid.
  ///
  /// In en, this message translates to:
  /// **'A message could not be read'**
  String get chatMessageInvalid;

  /// No description provided for @chatMessageUndecryptable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t unlock this message'**
  String get chatMessageUndecryptable;

  /// No description provided for @chatMessageUnapprovedDevice.
  ///
  /// In en, this message translates to:
  /// **'A message from a device that isn\'t approved was hidden.'**
  String get chatMessageUnapprovedDevice;

  /// No description provided for @chatKeyRenewalNoAdmin.
  ///
  /// In en, this message translates to:
  /// **'No admin or moderator in this channel can renew its key; ask one to join.'**
  String get chatKeyRenewalNoAdmin;

  /// No description provided for @chatSentFromRemovedDevice.
  ///
  /// In en, this message translates to:
  /// **'Sent from a device {name} removed'**
  String chatSentFromRemovedDevice(String name);

  /// No description provided for @chatSentFromOwnRemovedDevice.
  ///
  /// In en, this message translates to:
  /// **'Sent from a device you removed'**
  String get chatSentFromOwnRemovedDevice;

  /// No description provided for @chatDevicesNotJoined.
  ///
  /// In en, this message translates to:
  /// **'Some of {name}\'s devices haven\'t joined yet.'**
  String chatDevicesNotJoined(String name);

  /// No description provided for @chatHoldChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking {name}\'s devices. Sending in this chat is paused until they\'re checked.'**
  String chatHoldChecking(String name);

  /// No description provided for @chatHoldWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for {name} to open the app and approve their devices. Sending in this chat is paused.'**
  String chatHoldWaiting(String name);

  /// No description provided for @chatHoldRemoved.
  ///
  /// In en, this message translates to:
  /// **'A device {name} removed is still in this chat. Sending is paused until it leaves.'**
  String chatHoldRemoved(String name);

  /// No description provided for @chatHoldOwnRemoved.
  ///
  /// In en, this message translates to:
  /// **'A device you removed is still in this chat. Sending is paused until it leaves.'**
  String get chatHoldOwnRemoved;

  /// No description provided for @chatHoldUnapproved.
  ///
  /// In en, this message translates to:
  /// **'A device that isn\'t on {name}\'s approved list is in this chat. Sending is paused until it\'s approved or leaves.'**
  String chatHoldUnapproved(String name);

  /// No description provided for @chatHoldOwnUnapproved.
  ///
  /// In en, this message translates to:
  /// **'A device you didn\'t approve was added to this chat. Sending is paused. Check your devices in Settings.'**
  String get chatHoldOwnUnapproved;

  /// No description provided for @chatHoldConflict.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s device list changed in a way that can\'t be verified. Sending in this chat is paused.'**
  String chatHoldConflict(String name);

  /// No description provided for @chatHoldOwnConflict.
  ///
  /// In en, this message translates to:
  /// **'Your device list changed in a way that can\'t be verified. Sending in this chat is paused.'**
  String get chatHoldOwnConflict;

  /// No description provided for @chatHoldCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get chatHoldCheckAgain;

  /// No description provided for @chatHoldCompare.
  ///
  /// In en, this message translates to:
  /// **'Compare safety numbers'**
  String get chatHoldCompare;

  /// No description provided for @chatHoldTrust.
  ///
  /// In en, this message translates to:
  /// **'Trust current list'**
  String get chatHoldTrust;

  /// No description provided for @chatHoldTrustTitle.
  ///
  /// In en, this message translates to:
  /// **'Trust {name}\'s current device list?'**
  String chatHoldTrustTitle(String name);

  /// No description provided for @chatHoldTrustBody.
  ///
  /// In en, this message translates to:
  /// **'One of {name}\'s devices, or their recovery key, signed two different versions of their device list. Ask {name} to check their devices and remove any they don\'t recognise. Matching safety numbers show that you both see the same devices in this chat, but not which version is real. Trust the list only after {name} confirms the devices in this chat are theirs.'**
  String chatHoldTrustBody(String name);

  /// No description provided for @chatHoldTrustNewDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices that weren\'t on {name}\'s list before it changed: {count}. Trusting the list approves them, and they can be added to your chats.'**
  String chatHoldTrustNewDevices(String name, int count);

  /// No description provided for @chatHoldTrustRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'This version also changes {name}\'s recovery key. Whoever holds that key can replace all of {name}\'s devices.'**
  String chatHoldTrustRecoveryKey(String name);

  /// No description provided for @chatHoldTrustConfirm.
  ///
  /// In en, this message translates to:
  /// **'Trust list'**
  String get chatHoldTrustConfirm;

  /// No description provided for @chatHoldTrustRefused.
  ///
  /// In en, this message translates to:
  /// **'The list the server shows now isn\'t one of the two signed versions, so nothing changed. Try again later.'**
  String get chatHoldTrustRefused;

  /// No description provided for @chatHoldTrusted.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s current device list is trusted now.'**
  String chatHoldTrusted(String name);

  /// No description provided for @chatMessageWelcomeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t join this chat. Ask a member to add you again.'**
  String get chatMessageWelcomeUnavailable;

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

  /// No description provided for @chatTickSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get chatTickSent;

  /// No description provided for @chatTickDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatTickDelivered;

  /// No description provided for @chatTickRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get chatTickRead;

  /// No description provided for @chatTypingOne.
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String chatTypingOne(String name);

  /// No description provided for @chatTypingTwo.
  ///
  /// In en, this message translates to:
  /// **'{first} and {second} are typing…'**
  String chatTypingTwo(String first, String second);

  /// No description provided for @chatTypingMany.
  ///
  /// In en, this message translates to:
  /// **'Several people are typing…'**
  String get chatTypingMany;

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

  /// No description provided for @chatAddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add a file or poll'**
  String get chatAddTooltip;

  /// No description provided for @chatComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatComposerHint;

  /// Hint shown in chat composer when posting is restricted to admins.
  ///
  /// In en, this message translates to:
  /// **'Only admins can post'**
  String get chatPostingRestricted;

  /// No description provided for @chatComposerCounter.
  ///
  /// In en, this message translates to:
  /// **'{length} / {max}'**
  String chatComposerCounter(int length, int max);

  /// No description provided for @chatPausedNotice.
  ///
  /// In en, this message translates to:
  /// **'Sending is paused here: an encryption update for this conversation could not be sent. Try it again, or discard it. Other conversations still work.'**
  String get chatPausedNotice;

  /// No description provided for @chatPausedDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard update'**
  String get chatPausedDiscard;

  /// Paused-chat notice when the stuck encryption update cannot be discarded (a group's first update, or one that is not a commit bundle).
  ///
  /// In en, this message translates to:
  /// **'Sending is paused here: an encryption update for this conversation could not be sent. Try it again. Other conversations still work.'**
  String get chatPausedNoticeRetryOnly;

  /// No description provided for @chatPausedDiscardRefused.
  ///
  /// In en, this message translates to:
  /// **'This encryption update cannot be discarded. Try it again, or leave the conversation.'**
  String get chatPausedDiscardRefused;

  /// No description provided for @chatPausedRoleChangeNotMade.
  ///
  /// In en, this message translates to:
  /// **'The update was discarded, so the role change was not made. Make it again if you still want it.'**
  String get chatPausedRoleChangeNotMade;

  /// No description provided for @chatSyncPausedNotice.
  ///
  /// In en, this message translates to:
  /// **'Messages in this conversation are paused: an encryption update could not be applied. Nothing was skipped, and other conversations keep working.'**
  String get chatSyncPausedNotice;

  /// No description provided for @chatSyncHeldNotice.
  ///
  /// In en, this message translates to:
  /// **'Messages in this conversation are waiting: a membership or role change needs a confirmation this device does not have yet. It is checked again automatically. Nothing was skipped, and other conversations keep working.'**
  String get chatSyncHeldNotice;

  /// No description provided for @chatRemovalHoldNotice.
  ///
  /// In en, this message translates to:
  /// **'Your message waits until the removed member\'s encryption update finishes, then sends.'**
  String get chatRemovalHoldNotice;

  /// No description provided for @chatNoPeerReadOnly.
  ///
  /// In en, this message translates to:
  /// **'No one else in this conversation can add this device back, so its history is read-only here. Start a new conversation to send messages.'**
  String get chatNoPeerReadOnly;

  /// No description provided for @chatNoPeerCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Can\'t check this conversation\'s members right now. Try again in a moment.'**
  String get chatNoPeerCheckFailed;

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

  /// No description provided for @backupRestoredLinkToFinish.
  ///
  /// In en, this message translates to:
  /// **'Your messages and settings are restored on this device. To finish, link this device from another device that is signed in to your account. If you lost every device, use “Lost all your devices?” with your password and recovery key.'**
  String get backupRestoredLinkToFinish;

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

  /// No description provided for @syncErrorLocalStorage.
  ///
  /// In en, this message translates to:
  /// **'This device could not read or write its local storage. Messages are paused so none are skipped. Free up space or restart the app, then try again.'**
  String get syncErrorLocalStorage;

  /// No description provided for @syncErrorRecordLimit.
  ///
  /// In en, this message translates to:
  /// **'A conversation has grown too large for this device to store its encryption data. Messages are paused so none are skipped. Leave that conversation to continue.'**
  String get syncErrorRecordLimit;

  /// No description provided for @syncErrorRecordLimitDevice.
  ///
  /// In en, this message translates to:
  /// **'This device\'s encryption data has grown too large to store. Messages are paused so none are skipped. Link this device again to continue.'**
  String get syncErrorRecordLimitDevice;

  /// No description provided for @syncErrorRecordLimitNamed.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" has grown too large for this device to store its encryption data. Messages are paused so none are skipped. Leave that conversation to continue.'**
  String syncErrorRecordLimitNamed(String title);

  /// No description provided for @bannerLeaveNamed.
  ///
  /// In en, this message translates to:
  /// **'Leave \"{title}\"'**
  String bannerLeaveNamed(String title);

  /// No description provided for @bannerLeaveNamedTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave \"{title}\"?'**
  String bannerLeaveNamedTitle(String title);

  /// No description provided for @syncErrorStorageBusy.
  ///
  /// In en, this message translates to:
  /// **'This device\'s storage is busy or full. Sync will try again shortly.'**
  String get syncErrorStorageBusy;

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
  /// **'The setup code is missing or wrong. Use the one the server printed when it started (the demo keeps it in data/demo/setup-token).'**
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

  /// No description provided for @errorConversationApprovalHeld.
  ///
  /// In en, this message translates to:
  /// **'Sending is paused: a device in this chat isn\'t on its owner\'s approved list, or the list couldn\'t be checked yet.'**
  String get errorConversationApprovalHeld;

  /// No description provided for @errorDeviceListNotApproved.
  ///
  /// In en, this message translates to:
  /// **'That device isn\'t on its owner\'s approved list yet. It will be added once it is.'**
  String get errorDeviceListNotApproved;

  /// No description provided for @errorDeviceListConflict.
  ///
  /// In en, this message translates to:
  /// **'Your account\'s approved-device list changed in a way that can\'t be verified. Compare safety numbers with a contact before changing devices.'**
  String get errorDeviceListConflict;

  /// No description provided for @errorOutboxFull.
  ///
  /// In en, this message translates to:
  /// **'Your encrypted message queue is full. Send or discard a pending message before composing another.'**
  String get errorOutboxFull;

  /// No description provided for @errorCryptoStateFormatUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device\'s encrypted data was saved in a format this version of the app cannot read. Link this device again to keep messaging.'**
  String get errorCryptoStateFormatUnsupported;

  /// No description provided for @errorConversationTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This conversation has grown too large for this device to store its encryption data. Nothing was changed. You can leave the conversation to keep the others working.'**
  String get errorConversationTooLarge;

  /// No description provided for @errorCryptoRecordLimit.
  ///
  /// In en, this message translates to:
  /// **'This device\'s encryption data has grown too large to store. Nothing was changed. Link this device again to keep messaging.'**
  String get errorCryptoRecordLimit;

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
  /// **'Could not reach the server. Check the server address and your connection.'**
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
  /// **'Enter an HTTPS server address, for example https://chat.example.org.'**
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

  /// L2-3 sealed sender: the server would not take a message hidden.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t send hidden: the server would not take this message without your name. Send it normally, and the server will see it is from you, or discard it.'**
  String get outboxSealedRefused;

  /// L2-3 sealed sender: the server would not take a message hidden. Sends it with your name visible to the server.
  ///
  /// In en, this message translates to:
  /// **'Send normally'**
  String get chatSendNormally;

  /// L2-3 sealed sender: the server would not take a message hidden.
  ///
  /// In en, this message translates to:
  /// **'This chat is updating its encryption. Try again in a moment.'**
  String get outboxSealedResendHeld;

  /// L2-3 sealed sender: the server would not take a message hidden.
  ///
  /// In en, this message translates to:
  /// **'This message can no longer be sent normally. Copy it or discard it.'**
  String get outboxSealedResendUnavailable;

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

  /// Recovery screen message when the encrypted local database opened with its key but upgrading it to the app's new version failed because the device is full or could not write. The database is unchanged; retrying after freeing storage completes the upgrade.
  ///
  /// In en, this message translates to:
  /// **'This device could not update its message storage for this version of Veritra, for example because the device is full. Nothing has been changed or deleted. Free up some space, then retry.'**
  String get recoveryUpgradeFailed;

  /// Recovery screen message when the storage upgrade failed for lack of space again after a retry. The reset it mentions moves the old data aside and needs confirmation.
  ///
  /// In en, this message translates to:
  /// **'This device still could not update its message storage. Nothing has been changed or deleted. Free up more space and retry, or reset this device and link it again.'**
  String get recoveryUpgradeStillFull;

  /// Recovery screen message when the encrypted local database opened with its key but upgrading or opening it for the app's new version failed for a reason other than a full device (for example, a damaged file). The reset it mentions moves the old data aside and needs confirmation.
  ///
  /// In en, this message translates to:
  /// **'This device could not update its message storage for this version of Veritra. Nothing has been changed or deleted. Retry. If it keeps failing, you can reset this device and link it again.'**
  String get recoveryUpgradeError;

  /// Recovery screen message when sync found the encrypted local database corrupt or not a database while the app was running. Retry reopens it; the reset it mentions moves the old data aside and needs confirmation.
  ///
  /// In en, this message translates to:
  /// **'This device\'s message storage is damaged and cannot be read, so sync has stopped. Nothing has been deleted. Retry, or reset this device and link it again.'**
  String get recoveryStorageDamaged;

  /// Recovery screen message when the SQLite library in this build has no encryption cipher or no FTS5 search support. The database and key are untouched; retrying or resetting cannot help.
  ///
  /// In en, this message translates to:
  /// **'This build of Veritra cannot open its message storage: the database engine lacks encryption or search support. Your data has not been changed or deleted. Install a Veritra build that supports them.'**
  String get recoverySqliteFeatureMissing;

  /// No description provided for @errorPasswordLoginNeedsLink.
  ///
  /// In en, this message translates to:
  /// **'New phone? Add it using a device you already use.'**
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

  /// Shown when saving a new recovery key is refused because the recovery follow-up went back to its restore step first (Back was tapped while the save waited).
  ///
  /// In en, this message translates to:
  /// **'You went back to the restore step, so this recovery key was not saved. Finish or skip the restore, then set a key.'**
  String get recoveryKeyStepMovedBack;

  /// No description provided for @pushTestSent.
  ///
  /// In en, this message translates to:
  /// **'Test sent. A notification should arrive within a minute.'**
  String get pushTestSent;

  /// No description provided for @pushTestGone.
  ///
  /// In en, this message translates to:
  /// **'The delivery service no longer accepts this device. Registering again.'**
  String get pushTestGone;

  /// No description provided for @pushTestRejected.
  ///
  /// In en, this message translates to:
  /// **'The delivery service did not accept the test. Try again later.'**
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
  /// **'This build does not allow the server address {url}. Use an https:// server address.'**
  String errorServerNotAllowed(String url);

  /// No description provided for @muteEightHours.
  ///
  /// In en, this message translates to:
  /// **'For 8 hours'**
  String get muteEightHours;

  /// No description provided for @muteOneWeek.
  ///
  /// In en, this message translates to:
  /// **'For 1 week'**
  String get muteOneWeek;

  /// No description provided for @muteAlways.
  ///
  /// In en, this message translates to:
  /// **'Until I turn it back on'**
  String get muteAlways;

  /// No description provided for @muteStatusAlways.
  ///
  /// In en, this message translates to:
  /// **'Muted until you turn it back on.'**
  String get muteStatusAlways;

  /// No description provided for @muteStatusUntil.
  ///
  /// In en, this message translates to:
  /// **'Muted until {time}.'**
  String muteStatusUntil(String time);

  /// No description provided for @chatMoreReactions.
  ///
  /// In en, this message translates to:
  /// **'More reactions'**
  String get chatMoreReactions;

  /// No description provided for @emojiSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search by name, or type or paste an emoji'**
  String get emojiSearchHint;

  /// No description provided for @emojiUseTyped.
  ///
  /// In en, this message translates to:
  /// **'Use {emoji}'**
  String emojiUseTyped(String emoji);

  /// No description provided for @emojiNoResults.
  ///
  /// In en, this message translates to:
  /// **'No emoji with that name. Type or paste one instead.'**
  String get emojiNoResults;

  /// No description provided for @emojiGroupSmileys.
  ///
  /// In en, this message translates to:
  /// **'Smileys'**
  String get emojiGroupSmileys;

  /// No description provided for @emojiGroupPeople.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get emojiGroupPeople;

  /// No description provided for @emojiGroupAnimals.
  ///
  /// In en, this message translates to:
  /// **'Animals and nature'**
  String get emojiGroupAnimals;

  /// No description provided for @emojiGroupFood.
  ///
  /// In en, this message translates to:
  /// **'Food and drink'**
  String get emojiGroupFood;

  /// No description provided for @emojiGroupTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel and places'**
  String get emojiGroupTravel;

  /// No description provided for @emojiGroupActivities.
  ///
  /// In en, this message translates to:
  /// **'Activities'**
  String get emojiGroupActivities;

  /// No description provided for @emojiGroupObjects.
  ///
  /// In en, this message translates to:
  /// **'Objects'**
  String get emojiGroupObjects;

  /// No description provided for @emojiGroupSymbols.
  ///
  /// In en, this message translates to:
  /// **'Symbols'**
  String get emojiGroupSymbols;

  /// No description provided for @emojiGroupFlags.
  ///
  /// In en, this message translates to:
  /// **'Flags'**
  String get emojiGroupFlags;

  /// No description provided for @searchModeMessages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get searchModeMessages;

  /// No description provided for @searchModePeople.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get searchModePeople;

  /// No description provided for @searchMessagesHint.
  ///
  /// In en, this message translates to:
  /// **'Search messages on this device…'**
  String get searchMessagesHint;

  /// No description provided for @searchMessagesIntroTitle.
  ///
  /// In en, this message translates to:
  /// **'Search this device'**
  String get searchMessagesIntroTitle;

  /// No description provided for @searchMessagesIntroMessage.
  ///
  /// In en, this message translates to:
  /// **'Finds text in the messages this device holds. The search happens here and is never sent to the server.'**
  String get searchMessagesIntroMessage;

  /// No description provided for @searchMessagesNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No messages found'**
  String get searchMessagesNoResultsTitle;

  /// No description provided for @searchMessagesNoResultsMessage.
  ///
  /// In en, this message translates to:
  /// **'Nothing on this device matches. Messages that expired or were deleted are gone from search too.'**
  String get searchMessagesNoResultsMessage;

  /// No description provided for @searchMessagesFailed.
  ///
  /// In en, this message translates to:
  /// **'The search could not read the local database.'**
  String get searchMessagesFailed;

  /// No description provided for @attachmentTooLarge.
  ///
  /// In en, this message translates to:
  /// **'{fileName} is larger than this server allows ({limit}).'**
  String attachmentTooLarge(String fileName, String limit);

  /// No description provided for @attachmentEmptyFile.
  ///
  /// In en, this message translates to:
  /// **'{fileName} is empty and cannot be sent.'**
  String attachmentEmptyFile(String fileName);

  /// No description provided for @attachmentTooMany.
  ///
  /// In en, this message translates to:
  /// **'At most {count} files can wait to be sent together.'**
  String attachmentTooMany(int count);

  /// No description provided for @attachmentRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove {fileName}'**
  String attachmentRemove(String fileName);

  /// No description provided for @attachmentOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be opened. This device may have no app for it.'**
  String get attachmentOpenFailed;

  /// No description provided for @attachmentDropHint.
  ///
  /// In en, this message translates to:
  /// **'Drop files to attach them'**
  String get attachmentDropHint;

  /// No description provided for @attachmentSentCount.
  ///
  /// In en, this message translates to:
  /// **'Sending file {done} of {total}'**
  String attachmentSentCount(int done, int total);

  /// No description provided for @settingsAdmin.
  ///
  /// In en, this message translates to:
  /// **'Administration'**
  String get settingsAdmin;

  /// No description provided for @settingsAdminDetail.
  ///
  /// In en, this message translates to:
  /// **'Accounts and audit log'**
  String get settingsAdminDetail;

  /// No description provided for @adminAccountsTab.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get adminAccountsTab;

  /// No description provided for @adminAuditTab.
  ///
  /// In en, this message translates to:
  /// **'Audit log'**
  String get adminAuditTab;

  /// No description provided for @adminSuspend.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get adminSuspend;

  /// No description provided for @adminUnsuspend.
  ///
  /// In en, this message translates to:
  /// **'Reactivate'**
  String get adminUnsuspend;

  /// No description provided for @adminSuspendTitle.
  ///
  /// In en, this message translates to:
  /// **'Suspend this account?'**
  String get adminSuspendTitle;

  /// No description provided for @adminSuspendMessage.
  ///
  /// In en, this message translates to:
  /// **'@{username} will be signed out everywhere and cannot sign in until you reactivate the account.'**
  String adminSuspendMessage(String username);

  /// No description provided for @adminUnsuspendTitle.
  ///
  /// In en, this message translates to:
  /// **'Reactivate this account?'**
  String get adminUnsuspendTitle;

  /// No description provided for @adminUnsuspendMessage.
  ///
  /// In en, this message translates to:
  /// **'@{username} will be able to sign in again.'**
  String adminUnsuspendMessage(String username);

  /// No description provided for @adminSuspendedPill.
  ///
  /// In en, this message translates to:
  /// **'Suspended'**
  String get adminSuspendedPill;

  /// No description provided for @adminAccountSummary.
  ///
  /// In en, this message translates to:
  /// **'{role} · {devices, plural, =1{1 device} other{{devices} devices}} · {storage}'**
  String adminAccountSummary(String role, int devices, String storage);

  /// No description provided for @adminEventBy.
  ///
  /// In en, this message translates to:
  /// **'By {actor}'**
  String adminEventBy(String actor);

  /// No description provided for @adminActorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Someone'**
  String get adminActorUnknown;

  /// No description provided for @adminEventSuspended.
  ///
  /// In en, this message translates to:
  /// **'{actor} suspended {target}'**
  String adminEventSuspended(String actor, String target);

  /// No description provided for @adminEventReactivated.
  ///
  /// In en, this message translates to:
  /// **'{actor} reactivated {target}'**
  String adminEventReactivated(String actor, String target);

  /// No description provided for @adminEventRegistered.
  ///
  /// In en, this message translates to:
  /// **'{actor} joined the server'**
  String adminEventRegistered(String actor);

  /// No description provided for @adminEventOwnerCreated.
  ///
  /// In en, this message translates to:
  /// **'{actor} created the owner account'**
  String adminEventOwnerCreated(String actor);

  /// No description provided for @adminEventSignedIn.
  ///
  /// In en, this message translates to:
  /// **'{actor} signed in'**
  String adminEventSignedIn(String actor);

  /// No description provided for @adminEventSignedOut.
  ///
  /// In en, this message translates to:
  /// **'{actor} signed out'**
  String adminEventSignedOut(String actor);

  /// No description provided for @adminEventSignedOutOthers.
  ///
  /// In en, this message translates to:
  /// **'{actor} signed out their other devices'**
  String adminEventSignedOutOthers(String actor);

  /// No description provided for @adminEventPasswordChanged.
  ///
  /// In en, this message translates to:
  /// **'{actor} changed their password'**
  String adminEventPasswordChanged(String actor);

  /// No description provided for @adminEventDeviceSignedOut.
  ///
  /// In en, this message translates to:
  /// **'{actor} signed out a device'**
  String adminEventDeviceSignedOut(String actor);

  /// No description provided for @adminEventInviteCreated.
  ///
  /// In en, this message translates to:
  /// **'{actor} made an invite'**
  String adminEventInviteCreated(String actor);

  /// No description provided for @adminEventInviteRevoked.
  ///
  /// In en, this message translates to:
  /// **'{actor} turned off an invite'**
  String adminEventInviteRevoked(String actor);

  /// Fallback sentence for an audit event with no wording of its own.
  ///
  /// In en, this message translates to:
  /// **'{actor}: {event}'**
  String adminEventOther(String actor, String event);

  /// No description provided for @adminLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get adminLoadMore;

  /// No description provided for @adminNoAccounts.
  ///
  /// In en, this message translates to:
  /// **'No accounts'**
  String get adminNoAccounts;

  /// No description provided for @adminNoEvents.
  ///
  /// In en, this message translates to:
  /// **'No audit events yet'**
  String get adminNoEvents;

  /// No description provided for @requestsSection.
  ///
  /// In en, this message translates to:
  /// **'Requests ({count})'**
  String requestsSection(int count);

  /// No description provided for @requestsTitle.
  ///
  /// In en, this message translates to:
  /// **'Message request'**
  String get requestsTitle;

  /// No description provided for @requestFrom.
  ///
  /// In en, this message translates to:
  /// **'{name} wants to message you'**
  String requestFrom(String name);

  /// No description provided for @requestUnknownSender.
  ///
  /// In en, this message translates to:
  /// **'Someone you do not know'**
  String get requestUnknownSender;

  /// No description provided for @requestExplanation.
  ///
  /// In en, this message translates to:
  /// **'Nothing from this person is shown or downloaded, and they cannot see that you read anything, until you accept.'**
  String get requestExplanation;

  /// No description provided for @requestSharedTitle.
  ///
  /// In en, this message translates to:
  /// **'What they can see'**
  String get requestSharedTitle;

  /// No description provided for @requestSharedNow.
  ///
  /// In en, this message translates to:
  /// **'Now: they are not told you opened this, and no read receipt is sent.'**
  String get requestSharedNow;

  /// No description provided for @requestSharedAccept.
  ///
  /// In en, this message translates to:
  /// **'If you accept: they can see when you are typing and, if read receipts are on in Settings, when you read their messages.'**
  String get requestSharedAccept;

  /// No description provided for @requestSharedDelete.
  ///
  /// In en, this message translates to:
  /// **'If you delete: they are not told.'**
  String get requestSharedDelete;

  /// No description provided for @requestAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get requestAccept;

  /// No description provided for @requestBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get requestBlock;

  /// No description provided for @requestDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get requestDelete;

  /// No description provided for @requestBlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Block this person?'**
  String get requestBlockTitle;

  /// No description provided for @requestBlockMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} will no longer be able to message you, and this conversation will be removed.'**
  String requestBlockMessage(String name);

  /// No description provided for @requestDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this request?'**
  String get requestDeleteTitle;

  /// No description provided for @requestDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'The conversation is removed from this device. The sender is not told.'**
  String get requestDeleteMessage;

  /// No description provided for @w8PinnedMessage.
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get w8PinnedMessage;

  /// No description provided for @w8Pin.
  ///
  /// In en, this message translates to:
  /// **'Pin message'**
  String get w8Pin;

  /// No description provided for @w8Unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin message'**
  String get w8Unpin;

  /// No description provided for @w8PinDays.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{Pin for 1 day} other{Pin for {days} days}}'**
  String w8PinDays(int days);

  /// No description provided for @w8Forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get w8Forward;

  /// No description provided for @w8Forwarded.
  ///
  /// In en, this message translates to:
  /// **'Forwarded'**
  String get w8Forwarded;

  /// No description provided for @w8ForwardedMany.
  ///
  /// In en, this message translates to:
  /// **'Forwarded many times'**
  String get w8ForwardedMany;

  /// No description provided for @w8Star.
  ///
  /// In en, this message translates to:
  /// **'Star'**
  String get w8Star;

  /// No description provided for @w8Unstar.
  ///
  /// In en, this message translates to:
  /// **'Remove star'**
  String get w8Unstar;

  /// No description provided for @w8DeleteForMe.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get w8DeleteForMe;

  /// No description provided for @w8DeletedForMe.
  ///
  /// In en, this message translates to:
  /// **'Deleted on this device'**
  String get w8DeletedForMe;

  /// No description provided for @w8DeleteForMeUndoFailed.
  ///
  /// In en, this message translates to:
  /// **'This message could not be brought back.'**
  String get w8DeleteForMeUndoFailed;

  /// No description provided for @w8Archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get w8Archive;

  /// No description provided for @w8Unarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get w8Unarchive;

  /// No description provided for @w8PinChat.
  ///
  /// In en, this message translates to:
  /// **'Pin chat'**
  String get w8PinChat;

  /// No description provided for @w8UnpinChat.
  ///
  /// In en, this message translates to:
  /// **'Unpin chat'**
  String get w8UnpinChat;

  /// No description provided for @w8ArchivedChats.
  ///
  /// In en, this message translates to:
  /// **'Archived chats'**
  String get w8ArchivedChats;

  /// No description provided for @w8Chats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get w8Chats;

  /// No description provided for @w8MentionsMuted.
  ///
  /// In en, this message translates to:
  /// **'Mentions in muted chats'**
  String get w8MentionsMuted;

  /// No description provided for @w8MentionsMutedDetail.
  ///
  /// In en, this message translates to:
  /// **'Notify when a member mentions you, even in a muted chat.'**
  String get w8MentionsMutedDetail;

  /// No description provided for @chatPreviewsSetting.
  ///
  /// In en, this message translates to:
  /// **'Show last message'**
  String get chatPreviewsSetting;

  /// No description provided for @chatPreviewsSettingDetail.
  ///
  /// In en, this message translates to:
  /// **'Read from this device only.'**
  String get chatPreviewsSettingDetail;

  /// No description provided for @b2LinkPreviews.
  ///
  /// In en, this message translates to:
  /// **'Link previews'**
  String get b2LinkPreviews;

  /// No description provided for @b2LinkPreviewsDetail.
  ///
  /// In en, this message translates to:
  /// **'When you send a link, this device can fetch the page and put a preview in the encrypted message. The site sees this device\'s address. The server and the people you write to never fetch it.'**
  String get b2LinkPreviewsDetail;

  /// No description provided for @b2LinkPreviewsOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get b2LinkPreviewsOff;

  /// No description provided for @b2LinkPreviewsKnown.
  ///
  /// In en, this message translates to:
  /// **'Known sites'**
  String get b2LinkPreviewsKnown;

  /// No description provided for @b2LinkPreviewsAll.
  ///
  /// In en, this message translates to:
  /// **'All sites'**
  String get b2LinkPreviewsAll;

  /// No description provided for @w8HiddenSpoiler.
  ///
  /// In en, this message translates to:
  /// **'Message containing a hidden spoiler'**
  String get w8HiddenSpoiler;

  /// No description provided for @w8StarredMessages.
  ///
  /// In en, this message translates to:
  /// **'Starred messages'**
  String get w8StarredMessages;

  /// No description provided for @w8MessageActionsLocalNote.
  ///
  /// In en, this message translates to:
  /// **'Star and Delete for me apply to this device only.'**
  String get w8MessageActionsLocalNote;

  /// No description provided for @w8ChatActionsLocalNote.
  ///
  /// In en, this message translates to:
  /// **'Archive and Pin chat apply to this device only.'**
  String get w8ChatActionsLocalNote;

  /// No description provided for @k2CopiedHistory.
  ///
  /// In en, this message translates to:
  /// **'Copied history · device snapshot'**
  String get k2CopiedHistory;

  /// No description provided for @k2HistoryOnlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Copied history'**
  String get k2HistoryOnlyTitle;

  /// No description provided for @k2HistoryOnlyNotice.
  ///
  /// In en, this message translates to:
  /// **'Copied from your other device. Read-only: this device is not a member of this conversation, so nothing can be sent here.'**
  String get k2HistoryOnlyNotice;

  /// No description provided for @k2HistoryUntitled.
  ///
  /// In en, this message translates to:
  /// **'Earlier conversation'**
  String get k2HistoryUntitled;

  /// No description provided for @k2HistoryOtherMember.
  ///
  /// In en, this message translates to:
  /// **'Another member'**
  String get k2HistoryOtherMember;

  /// No description provided for @k2HistoryAttachment.
  ///
  /// In en, this message translates to:
  /// **'Attachment, not downloaded on this device'**
  String get k2HistoryAttachment;

  /// No description provided for @k2HistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No copied messages are left in this conversation.'**
  String get k2HistoryEmpty;

  /// No description provided for @settingsRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'Recovery key'**
  String get settingsRecoveryKey;

  /// No description provided for @recoveryUnavailableHere.
  ///
  /// In en, this message translates to:
  /// **'Account recovery is not available in this build.'**
  String get recoveryUnavailableHere;

  /// No description provided for @recoveryKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery key'**
  String get recoveryKeyTitle;

  /// No description provided for @recoveryKeyIntro.
  ///
  /// In en, this message translates to:
  /// **'If you lose every device, your password and this recovery key get your account back on a new device. Keep the key on paper, somewhere safe. It does not bring back your message history.'**
  String get recoveryKeyIntro;

  /// No description provided for @recoveryKeyStatusSet.
  ///
  /// In en, this message translates to:
  /// **'Set on {date}'**
  String recoveryKeyStatusSet(String date);

  /// No description provided for @recoveryKeyStatusNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get recoveryKeyStatusNotSet;

  /// No description provided for @recoveryKeyStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unavailable right now'**
  String get recoveryKeyStatusUnknown;

  /// No description provided for @recoveryKeyStatusOff.
  ///
  /// In en, this message translates to:
  /// **'This server has account recovery turned off'**
  String get recoveryKeyStatusOff;

  /// No description provided for @recoveryKeyCreate.
  ///
  /// In en, this message translates to:
  /// **'Create a recovery key'**
  String get recoveryKeyCreate;

  /// No description provided for @recoveryKeyReplace.
  ///
  /// In en, this message translates to:
  /// **'Replace the recovery key'**
  String get recoveryKeyReplace;

  /// No description provided for @recoveryKeyReplaceNote.
  ///
  /// In en, this message translates to:
  /// **'A new key replaces the old one at once and cancels any recovery that is waiting.'**
  String get recoveryKeyReplaceNote;

  /// No description provided for @recoveryKeyShowTitle.
  ///
  /// In en, this message translates to:
  /// **'Write down your recovery key'**
  String get recoveryKeyShowTitle;

  /// No description provided for @recoveryKeyShowDetail.
  ///
  /// In en, this message translates to:
  /// **'Write these 52 characters on paper, or save them in your password manager. Anyone with this key and your password can take over your account. Do not take a screenshot or keep it in a chat.'**
  String get recoveryKeyShowDetail;

  /// No description provided for @recoveryKeyWritten.
  ///
  /// In en, this message translates to:
  /// **'I have saved it'**
  String get recoveryKeyWritten;

  /// No description provided for @recoveryKeyCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy for a password manager'**
  String get recoveryKeyCopy;

  /// No description provided for @recoveryKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied. Paste it into your password manager now. The app clears it from the clipboard when you continue, or after about a minute and a half.'**
  String get recoveryKeyCopied;

  /// No description provided for @recoveryKeyConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Type your recovery key'**
  String get recoveryKeyConfirmTitle;

  /// No description provided for @recoveryKeyConfirmDetail.
  ///
  /// In en, this message translates to:
  /// **'Type the whole key from your paper or password manager to check it. Dashes and spaces do not matter.'**
  String get recoveryKeyConfirmDetail;

  /// No description provided for @recoveryKeyField.
  ///
  /// In en, this message translates to:
  /// **'Recovery key'**
  String get recoveryKeyField;

  /// No description provided for @recoveryKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the recovery key.'**
  String get recoveryKeyRequired;

  /// No description provided for @recoveryKeyMismatch.
  ///
  /// In en, this message translates to:
  /// **'That is not the key shown. Check your paper and try again.'**
  String get recoveryKeyMismatch;

  /// No description provided for @recoveryKeyGroupWrong.
  ///
  /// In en, this message translates to:
  /// **'Group {group} does not match. Check it on your copy.'**
  String recoveryKeyGroupWrong(int group);

  /// No description provided for @recoveryKeyGroupsMatched.
  ///
  /// In en, this message translates to:
  /// **'{count} of 13 groups match.'**
  String recoveryKeyGroupsMatched(int count);

  /// No description provided for @recoveryKeyCheck.
  ///
  /// In en, this message translates to:
  /// **'Check my key'**
  String get recoveryKeyCheck;

  /// No description provided for @recoveryKeyCheckOk.
  ///
  /// In en, this message translates to:
  /// **'This is your key. Nothing was saved yet.'**
  String get recoveryKeyCheckOk;

  /// No description provided for @recoveryKeyCheckSavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Check a saved key'**
  String get recoveryKeyCheckSavedTitle;

  /// No description provided for @recoveryKeyCheckSavedDetail.
  ///
  /// In en, this message translates to:
  /// **'Type the recovery key you saved, from your paper or password manager. It is checked on this device and is never sent. Dashes and spaces do not matter.'**
  String get recoveryKeyCheckSavedDetail;

  /// No description provided for @recoveryKeyCheckSavedCurrent.
  ///
  /// In en, this message translates to:
  /// **'This is your account\'s current recovery key. Keep it safe, with your server address.'**
  String get recoveryKeyCheckSavedCurrent;

  /// No description provided for @recoveryKeyCheckSavedNotCurrent.
  ///
  /// In en, this message translates to:
  /// **'This is a recovery key, but not this account\'s current one. It may be an older key that was replaced, or the key of another account. If you cannot find the current one, create a new key.'**
  String get recoveryKeyCheckSavedNotCurrent;

  /// No description provided for @recoveryKeyCheckSavedUnknown.
  ///
  /// In en, this message translates to:
  /// **'The key could not be checked right now. Try again later.'**
  String get recoveryKeyCheckSavedUnknown;

  /// No description provided for @recoveryKeyTooLong.
  ///
  /// In en, this message translates to:
  /// **'This is longer than the key. Check for extra characters.'**
  String get recoveryKeyTooLong;

  /// No description provided for @recoveryKeyShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Show the key again'**
  String get recoveryKeyShowAgain;

  /// No description provided for @recoveryKeySave.
  ///
  /// In en, this message translates to:
  /// **'Save recovery key'**
  String get recoveryKeySave;

  /// No description provided for @recoveryKeySaved.
  ///
  /// In en, this message translates to:
  /// **'Recovery key saved.'**
  String get recoveryKeySaved;

  /// No description provided for @recoveryFollowUpTitle.
  ///
  /// In en, this message translates to:
  /// **'Finish recovering your account'**
  String get recoveryFollowUpTitle;

  /// No description provided for @recoveryFollowUpStepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total}'**
  String recoveryFollowUpStepOf(int step, int total);

  /// No description provided for @recoveryFollowUpKeyDetail.
  ///
  /// In en, this message translates to:
  /// **'Your account is back on this device, and your other devices were signed out. Before your chats open, replace your recovery key and then your password: someone else may know them.'**
  String get recoveryFollowUpKeyDetail;

  /// No description provided for @recoveryFollowUpPasswordDetail.
  ///
  /// In en, this message translates to:
  /// **'Last step: choose a new password.'**
  String get recoveryFollowUpPasswordDetail;

  /// No description provided for @connectLostAllDevices.
  ///
  /// In en, this message translates to:
  /// **'Lost all your devices?'**
  String get connectLostAllDevices;

  /// No description provided for @recoveryStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Recover your account'**
  String get recoveryStartTitle;

  /// No description provided for @recoveryStartDetail.
  ///
  /// In en, this message translates to:
  /// **'Use this only if you lost every device signed in to your account. You need your password and your recovery key. If any of your devices was used in the last 7 days, this device joins only after 7 days, and those devices can cancel it. Your message history comes back only from a backup restored on this device.'**
  String get recoveryStartDetail;

  /// No description provided for @recoveryStartPointLost.
  ///
  /// In en, this message translates to:
  /// **'Use this only if you lost every device signed in to your account.'**
  String get recoveryStartPointLost;

  /// No description provided for @recoveryStartPointNeed.
  ///
  /// In en, this message translates to:
  /// **'You need your password and your recovery key.'**
  String get recoveryStartPointNeed;

  /// No description provided for @recoveryStartPointWait.
  ///
  /// In en, this message translates to:
  /// **'If one of your devices was used in the last 7 days, you wait 7 days, and your devices can cancel the recovery.'**
  String get recoveryStartPointWait;

  /// No description provided for @recoveryStartHowItWorks.
  ///
  /// In en, this message translates to:
  /// **'How recovery works'**
  String get recoveryStartHowItWorks;

  /// No description provided for @recoveryStartSubmit.
  ///
  /// In en, this message translates to:
  /// **'Start recovery'**
  String get recoveryStartSubmit;

  /// No description provided for @recoveryKeyUnreadable.
  ///
  /// In en, this message translates to:
  /// **'That recovery key is not valid. Check it for a typo.'**
  String get recoveryKeyUnreadable;

  /// No description provided for @recoveryKeyNotThisAccount.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t this account\'s recovery key. Check your paper and try again.'**
  String get recoveryKeyNotThisAccount;

  /// No description provided for @recoveryKeyConfirmedForList.
  ///
  /// In en, this message translates to:
  /// **'Recovery key confirmed.'**
  String get recoveryKeyConfirmedForList;

  /// No description provided for @recoveryRetypeDone.
  ///
  /// In en, this message translates to:
  /// **'Recovery finished on this device.'**
  String get recoveryRetypeDone;

  /// No description provided for @recoveryClaimRefused.
  ///
  /// In en, this message translates to:
  /// **'The password or recovery key is wrong, the server address differs from the one you wrote down, or this account cannot be recovered.'**
  String get recoveryClaimRefused;

  /// No description provided for @recoveryBackupOtherAccount.
  ///
  /// In en, this message translates to:
  /// **'The backup restored on this device belongs to another account or server. Recover that account here, or reset this device first.'**
  String get recoveryBackupOtherAccount;

  /// No description provided for @recoverySignedInAlready.
  ///
  /// In en, this message translates to:
  /// **'This device is already signed in.'**
  String get recoverySignedInAlready;

  /// No description provided for @recoveryAlreadyPending.
  ///
  /// In en, this message translates to:
  /// **'A recovery is already waiting on this device.'**
  String get recoveryAlreadyPending;

  /// No description provided for @recoveryDeviceLinkInProgress.
  ///
  /// In en, this message translates to:
  /// **'A device link is in progress on this device, so an account recovery cannot start here.'**
  String get recoveryDeviceLinkInProgress;

  /// No description provided for @recoveryWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery is waiting'**
  String get recoveryWaitingTitle;

  /// No description provided for @recoveryWaitingDetail.
  ///
  /// In en, this message translates to:
  /// **'This device joins your account after {date}. The app checks by itself while it is open. Your other devices can cancel this recovery.'**
  String recoveryWaitingDetail(String date);

  /// No description provided for @recoveryTimeLeft.
  ///
  /// In en, this message translates to:
  /// **'{time} left'**
  String recoveryTimeLeft(String time);

  /// No description provided for @recoveryReadyDetail.
  ///
  /// In en, this message translates to:
  /// **'The wait is over. Check now to finish.'**
  String get recoveryReadyDetail;

  /// No description provided for @recoveryCheckNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get recoveryCheckNow;

  /// No description provided for @recoveryAbandon.
  ///
  /// In en, this message translates to:
  /// **'Stop recovery'**
  String get recoveryAbandon;

  /// No description provided for @recoveryAbandonTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop recovery on this device?'**
  String get recoveryAbandonTitle;

  /// No description provided for @recoveryAbandonMessage.
  ///
  /// In en, this message translates to:
  /// **'This device forgets the request. To try again you need your password and recovery key again.'**
  String get recoveryAbandonMessage;

  /// No description provided for @recoveryRequestEnded.
  ///
  /// In en, this message translates to:
  /// **'This recovery was cancelled or has expired. A password or recovery key change, or one of your devices, cancels it. You can start again.'**
  String get recoveryRequestEnded;

  /// No description provided for @recoveryLoginTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to finish'**
  String get recoveryLoginTitle;

  /// No description provided for @recoveryLoginDetail.
  ///
  /// In en, this message translates to:
  /// **'Your account was recovered on this device, but the answer did not arrive. Enter your password to finish.'**
  String get recoveryLoginDetail;

  /// No description provided for @recoveryLoginSubmit.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get recoveryLoginSubmit;

  /// No description provided for @recoveryAccountLabel.
  ///
  /// In en, this message translates to:
  /// **'Account: {username}'**
  String recoveryAccountLabel(String username);

  /// No description provided for @recoveryPendingNotice.
  ///
  /// In en, this message translates to:
  /// **'Someone is recovering your account on “{device}”, finishing {date}. Not you? Cancel, or change your password or recovery key.'**
  String recoveryPendingNotice(String device, String date);

  /// No description provided for @recoveryPendingTitle.
  ///
  /// In en, this message translates to:
  /// **'Account recovery attempt'**
  String get recoveryPendingTitle;

  /// No description provided for @recoveryPendingNotMe.
  ///
  /// In en, this message translates to:
  /// **'This is not me'**
  String get recoveryPendingNotMe;

  /// No description provided for @recoveryPendingCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel recovery'**
  String get recoveryPendingCancel;

  /// No description provided for @recoveryCancelTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel this recovery?'**
  String get recoveryCancelTitle;

  /// No description provided for @recoveryCancelMessage.
  ///
  /// In en, this message translates to:
  /// **'The new device will not join your account. If it was not you, change your password too.'**
  String get recoveryCancelMessage;

  /// No description provided for @recoveryCancelled.
  ///
  /// In en, this message translates to:
  /// **'Recovery cancelled.'**
  String get recoveryCancelled;

  /// No description provided for @passwordLeakNotice.
  ///
  /// In en, this message translates to:
  /// **'Your password was used with a wrong recovery key many times. Change your password.'**
  String get passwordLeakNotice;

  /// No description provided for @passwordLeakDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get passwordLeakDismiss;

  /// No description provided for @apiErrorRecoveryNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'This server has not turned on account recovery.'**
  String get apiErrorRecoveryNotConfigured;

  /// No description provided for @apiErrorRecoveryBackoff.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a while, then try again.'**
  String get apiErrorRecoveryBackoff;

  /// No description provided for @apiErrorInvalidRecoveryKey.
  ///
  /// In en, this message translates to:
  /// **'The server refused this recovery key. Create a new one.'**
  String get apiErrorInvalidRecoveryKey;

  /// No description provided for @recoveryAlreadyEnded.
  ///
  /// In en, this message translates to:
  /// **'This recovery had already ended or was replaced by a newer one.'**
  String get recoveryAlreadyEnded;

  /// No description provided for @apiErrorPasswordUnchanged.
  ///
  /// In en, this message translates to:
  /// **'Choose a password different from your current one.'**
  String get apiErrorPasswordUnchanged;

  /// No description provided for @recoveryKeyServerAddress.
  ///
  /// In en, this message translates to:
  /// **'Write down the server address with it:'**
  String get recoveryKeyServerAddress;

  /// No description provided for @recoveryKeyOriginMismatch.
  ///
  /// In en, this message translates to:
  /// **'This device uses {current}, but the server\'s recovery address is {origin}. Recovery works only from {origin}.'**
  String recoveryKeyOriginMismatch(String current, String origin);

  /// No description provided for @joinTitle.
  ///
  /// In en, this message translates to:
  /// **'Join with a link'**
  String get joinTitle;

  /// No description provided for @joinLinkLabel.
  ///
  /// In en, this message translates to:
  /// **'Invitation link'**
  String get joinLinkLabel;

  /// No description provided for @joinLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the link you were sent'**
  String get joinLinkHint;

  /// No description provided for @joinCheck.
  ///
  /// In en, this message translates to:
  /// **'Check link'**
  String get joinCheck;

  /// No description provided for @joinLinkInvalid.
  ///
  /// In en, this message translates to:
  /// **'This is not an invitation link for this server.'**
  String get joinLinkInvalid;

  /// No description provided for @joinLinkUnusable.
  ///
  /// In en, this message translates to:
  /// **'This link no longer works. Ask for a new one.'**
  String get joinLinkUnusable;

  /// No description provided for @joinKindGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get joinKindGroup;

  /// No description provided for @joinKindCommunity.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get joinKindCommunity;

  /// No description provided for @joinInvitedBy.
  ///
  /// In en, this message translates to:
  /// **'Invited by {username}'**
  String joinInvitedBy(String username);

  /// No description provided for @joinRequestButton.
  ///
  /// In en, this message translates to:
  /// **'Ask to join'**
  String get joinRequestButton;

  /// No description provided for @joinRequestNote.
  ///
  /// In en, this message translates to:
  /// **'An owner or admin has to approve your request. You get no access until then.'**
  String get joinRequestNote;

  /// No description provided for @joinAlreadyMember.
  ///
  /// In en, this message translates to:
  /// **'You are already a member.'**
  String get joinAlreadyMember;

  /// No description provided for @joinRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Request sent. It stays under Your requests until someone decides.'**
  String get joinRequestSent;

  /// No description provided for @joinYourRequests.
  ///
  /// In en, this message translates to:
  /// **'Your requests'**
  String get joinYourRequests;

  /// No description provided for @joinNoRequests.
  ///
  /// In en, this message translates to:
  /// **'No requests yet.'**
  String get joinNoRequests;

  /// No description provided for @joinStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval'**
  String get joinStatusPending;

  /// No description provided for @joinStatusApproved.
  ///
  /// In en, this message translates to:
  /// **'Approved. Encrypted access follows once a member\'s device updates the group.'**
  String get joinStatusApproved;

  /// No description provided for @joinStatusRejected.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get joinStatusRejected;

  /// No description provided for @joinStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get joinStatusCancelled;

  /// No description provided for @joinCancelRequest.
  ///
  /// In en, this message translates to:
  /// **'Cancel request'**
  String get joinCancelRequest;

  /// No description provided for @membInviteSection.
  ///
  /// In en, this message translates to:
  /// **'Invitation links'**
  String get membInviteSection;

  /// No description provided for @membInviteManage.
  ///
  /// In en, this message translates to:
  /// **'Invitations and join requests'**
  String get membInviteManage;

  /// No description provided for @membInviteCreate.
  ///
  /// In en, this message translates to:
  /// **'Create invitation link'**
  String get membInviteCreate;

  /// No description provided for @membInviteCreateDetail.
  ///
  /// In en, this message translates to:
  /// **'Works for 7 days and for up to 10 people, and each one still needs your approval.'**
  String get membInviteCreateDetail;

  /// No description provided for @membInviteCreatedNote.
  ///
  /// In en, this message translates to:
  /// **'Copy this link now. It is not stored on the server and cannot be shown again.'**
  String get membInviteCreatedNote;

  /// No description provided for @membInviteCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get membInviteCopy;

  /// No description provided for @membInviteCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied.'**
  String get membInviteCopied;

  /// No description provided for @membInviteNone.
  ///
  /// In en, this message translates to:
  /// **'No active links.'**
  String get membInviteNone;

  /// No description provided for @membInviteUses.
  ///
  /// In en, this message translates to:
  /// **'{used} of {max} used · expires {date}'**
  String membInviteUses(int used, int max, String date);

  /// No description provided for @membInviteRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke link'**
  String get membInviteRevoke;

  /// No description provided for @membInviteTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get membInviteTurnOff;

  /// No description provided for @membInviteTurnOffTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn off this link?'**
  String get membInviteTurnOffTitle;

  /// No description provided for @membInviteTurnOffMessage.
  ///
  /// In en, this message translates to:
  /// **'No one can join with it any more. People who already asked keep their requests.'**
  String get membInviteTurnOffMessage;

  /// No description provided for @joinReqSection.
  ///
  /// In en, this message translates to:
  /// **'Join requests'**
  String get joinReqSection;

  /// No description provided for @joinReqNone.
  ///
  /// In en, this message translates to:
  /// **'No one is waiting.'**
  String get joinReqNone;

  /// No description provided for @settingsInvitesSection.
  ///
  /// In en, this message translates to:
  /// **'Community invitations'**
  String get settingsInvitesSection;

  /// No description provided for @settingsInvitesSharedOnlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Only accept community invites from people I share a group with'**
  String get settingsInvitesSharedOnlyTitle;

  /// No description provided for @settingsInvitesSharedOnlyNote.
  ///
  /// In en, this message translates to:
  /// **'Invites from anyone else are refused.'**
  String get settingsInvitesSharedOnlyNote;

  /// No description provided for @joinInviteFromStranger.
  ///
  /// In en, this message translates to:
  /// **'You only accept community invites from people you share a group with. To join, turn this off in Settings › Privacy and safety › Blocked accounts.'**
  String get joinInviteFromStranger;

  /// No description provided for @joinRequestNoticeText.
  ///
  /// In en, this message translates to:
  /// **'New join request'**
  String get joinRequestNoticeText;

  /// No description provided for @joinRequestNoticeDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get joinRequestNoticeDismiss;

  /// No description provided for @joinReqPausedNote.
  ///
  /// In en, this message translates to:
  /// **'Invitations are paused. You can decline requests now and approve them once the pause ends.'**
  String get joinReqPausedNote;

  /// No description provided for @moderationSectionDepartedTimeouts.
  ///
  /// In en, this message translates to:
  /// **'Timed out after leaving'**
  String get moderationSectionDepartedTimeouts;

  /// No description provided for @moderationDepartedTimeoutsNote.
  ///
  /// In en, this message translates to:
  /// **'These timeouts come back if the person rejoins.'**
  String get moderationDepartedTimeoutsNote;

  /// No description provided for @moderationNoDepartedTimeouts.
  ///
  /// In en, this message translates to:
  /// **'No one who left is timed out.'**
  String get moderationNoDepartedTimeouts;

  /// No description provided for @moderationDepartedTimeoutUntil.
  ///
  /// In en, this message translates to:
  /// **'Until {time}'**
  String moderationDepartedTimeoutUntil(String time);

  /// No description provided for @moderationLiftTimeout.
  ///
  /// In en, this message translates to:
  /// **'Lift timeout for {username}'**
  String moderationLiftTimeout(String username);

  /// No description provided for @joinReqAskedAt.
  ///
  /// In en, this message translates to:
  /// **'Asked {date}'**
  String joinReqAskedAt(String date);

  /// No description provided for @joinReqApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve {username}'**
  String joinReqApprove(String username);

  /// No description provided for @joinReqReject.
  ///
  /// In en, this message translates to:
  /// **'Decline {username}'**
  String joinReqReject(String username);

  /// No description provided for @joinReqDeclineButton.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get joinReqDeclineButton;

  /// No description provided for @joinReqApproveButton.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get joinReqApproveButton;

  /// No description provided for @joinReqRejectedSnack.
  ///
  /// In en, this message translates to:
  /// **'Request declined.'**
  String get joinReqRejectedSnack;

  /// No description provided for @communityRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {username} from the community?'**
  String communityRemoveTitle(String username);

  /// No description provided for @communityRemoveMessage.
  ///
  /// In en, this message translates to:
  /// **'They lose access to every channel at once. Messages already on their devices are not deleted.'**
  String get communityRemoveMessage;

  /// No description provided for @communityRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get communityRemoveConfirm;

  /// No description provided for @communityLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave this community?'**
  String get communityLeaveTitle;

  /// No description provided for @communityLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave community'**
  String get communityLeave;

  /// No description provided for @communityLeaveDetail.
  ///
  /// In en, this message translates to:
  /// **'You leave every channel at once. You can join again with a new link.'**
  String get communityLeaveDetail;

  /// No description provided for @communityLeaveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get communityLeaveConfirm;

  /// No description provided for @pollComposerTitle.
  ///
  /// In en, this message translates to:
  /// **'New poll'**
  String get pollComposerTitle;

  /// No description provided for @pollQuestionLabel.
  ///
  /// In en, this message translates to:
  /// **'Question'**
  String get pollQuestionLabel;

  /// No description provided for @pollOptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Option {number}'**
  String pollOptionLabel(String number);

  /// No description provided for @pollAddOption.
  ///
  /// In en, this message translates to:
  /// **'Add option'**
  String get pollAddOption;

  /// No description provided for @pollRemoveOption.
  ///
  /// In en, this message translates to:
  /// **'Remove option'**
  String get pollRemoveOption;

  /// No description provided for @pollMultipleChoice.
  ///
  /// In en, this message translates to:
  /// **'Allow several answers'**
  String get pollMultipleChoice;

  /// No description provided for @pollSend.
  ///
  /// In en, this message translates to:
  /// **'Send poll'**
  String get pollSend;

  /// No description provided for @pollInvalidHint.
  ///
  /// In en, this message translates to:
  /// **'Add a question and at least two different options.'**
  String get pollInvalidHint;

  /// No description provided for @pollVisibleNotice.
  ///
  /// In en, this message translates to:
  /// **'Everyone in this chat can see who voted for what.'**
  String get pollVisibleNotice;

  /// No description provided for @pollVoteTotal.
  ///
  /// In en, this message translates to:
  /// **'Votes: {count}'**
  String pollVoteTotal(String count);

  /// No description provided for @pollChooseOne.
  ///
  /// In en, this message translates to:
  /// **'Choose one'**
  String get pollChooseOne;

  /// No description provided for @pollChooseSeveral.
  ///
  /// In en, this message translates to:
  /// **'Choose one or more'**
  String get pollChooseSeveral;

  /// No description provided for @pollClose.
  ///
  /// In en, this message translates to:
  /// **'Close poll'**
  String get pollClose;

  /// No description provided for @pollClosedNotice.
  ///
  /// In en, this message translates to:
  /// **'This poll is closed.'**
  String get pollClosedNotice;

  /// No description provided for @voiceNoteRecord.
  ///
  /// In en, this message translates to:
  /// **'Record a voice note'**
  String get voiceNoteRecord;

  /// No description provided for @voiceNoteStop.
  ///
  /// In en, this message translates to:
  /// **'Stop and attach'**
  String get voiceNoteStop;

  /// No description provided for @voiceNoteDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard recording'**
  String get voiceNoteDiscard;

  /// No description provided for @voiceNoteRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording {time}'**
  String voiceNoteRecording(String time);

  /// No description provided for @voiceNotePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access is off. Allow it in the system settings to record.'**
  String get voiceNotePermissionDenied;

  /// No description provided for @voiceNoteRecordFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be started.'**
  String get voiceNoteRecordFailed;

  /// No description provided for @voiceNotePlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get voiceNotePlay;

  /// No description provided for @voiceNotePause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get voiceNotePause;

  /// No description provided for @voiceNoteSemantics.
  ///
  /// In en, this message translates to:
  /// **'Voice note, {size}'**
  String voiceNoteSemantics(String size);

  /// No description provided for @voiceNotePlayFailed.
  ///
  /// In en, this message translates to:
  /// **'The voice note could not be played.'**
  String get voiceNotePlayFailed;

  /// No description provided for @callStartVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice call'**
  String get callStartVoice;

  /// No description provided for @callStartVideo.
  ///
  /// In en, this message translates to:
  /// **'Video call'**
  String get callStartVideo;

  /// No description provided for @callUnknownContact.
  ///
  /// In en, this message translates to:
  /// **'Unknown contact'**
  String get callUnknownContact;

  /// No description provided for @callIncoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get callIncoming;

  /// No description provided for @callIncomingVideo.
  ///
  /// In en, this message translates to:
  /// **'Incoming video call'**
  String get callIncomingVideo;

  /// No description provided for @callRinging.
  ///
  /// In en, this message translates to:
  /// **'Calling…'**
  String get callRinging;

  /// No description provided for @callConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get callConnecting;

  /// No description provided for @callInProgress.
  ///
  /// In en, this message translates to:
  /// **'Call in progress'**
  String get callInProgress;

  /// No description provided for @callAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get callAccept;

  /// No description provided for @callDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get callDecline;

  /// No description provided for @callHangUp.
  ///
  /// In en, this message translates to:
  /// **'Hang up'**
  String get callHangUp;

  /// No description provided for @callMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get callMute;

  /// No description provided for @callUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get callUnmute;

  /// No description provided for @callSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get callSpeaker;

  /// No description provided for @callCameraOff.
  ///
  /// In en, this message translates to:
  /// **'Camera off'**
  String get callCameraOff;

  /// No description provided for @callCameraOn.
  ///
  /// In en, this message translates to:
  /// **'Camera on'**
  String get callCameraOn;

  /// No description provided for @callDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get callDismiss;

  /// Button on the missed-call card: starts a voice call to the same chat.
  ///
  /// In en, this message translates to:
  /// **'Call back'**
  String get callBack;

  /// No description provided for @callNoticeMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed call from {name}'**
  String callNoticeMissed(String name);

  /// No description provided for @callNoticeDeclined.
  ///
  /// In en, this message translates to:
  /// **'{name} declined the call'**
  String callNoticeDeclined(String name);

  /// No description provided for @callNoticeNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'{name} didn\'t answer'**
  String callNoticeNoAnswer(String name);

  /// No description provided for @callNoticeBusy.
  ///
  /// In en, this message translates to:
  /// **'{name} called while you were on another call'**
  String callNoticeBusy(String name);

  /// No description provided for @callNoticeFailed.
  ///
  /// In en, this message translates to:
  /// **'The call could not connect. Calls need the server\'s relay (TURN) service to be set up.'**
  String get callNoticeFailed;

  /// No description provided for @roomStart.
  ///
  /// In en, this message translates to:
  /// **'Group call'**
  String get roomStart;

  /// No description provided for @roomTitle.
  ///
  /// In en, this message translates to:
  /// **'Group call'**
  String get roomTitle;

  /// No description provided for @roomJoining.
  ///
  /// In en, this message translates to:
  /// **'Joining…'**
  String get roomJoining;

  /// No description provided for @roomConnected.
  ///
  /// In en, this message translates to:
  /// **'In the call'**
  String get roomConnected;

  /// No description provided for @roomEncryptedNote.
  ///
  /// In en, this message translates to:
  /// **'Voice and video are end-to-end encrypted. The server passes them on but cannot listen.'**
  String get roomEncryptedNote;

  /// No description provided for @roomLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get roomLeave;

  /// No description provided for @roomYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get roomYou;

  /// No description provided for @roomMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get roomMute;

  /// No description provided for @roomUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get roomUnmute;

  /// No description provided for @roomShareScreen.
  ///
  /// In en, this message translates to:
  /// **'Share screen'**
  String get roomShareScreen;

  /// No description provided for @roomStopSharing.
  ///
  /// In en, this message translates to:
  /// **'Stop sharing'**
  String get roomStopSharing;

  /// No description provided for @roomFailedFull.
  ///
  /// In en, this message translates to:
  /// **'This call is full.'**
  String get roomFailedFull;

  /// No description provided for @roomFailedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Group calls are not set up on this server.'**
  String get roomFailedUnavailable;

  /// No description provided for @roomFailedWelcome.
  ///
  /// In en, this message translates to:
  /// **'Joining safely was not possible. Try again.'**
  String get roomFailedWelcome;

  /// No description provided for @roomFailedOther.
  ///
  /// In en, this message translates to:
  /// **'The call could not continue.'**
  String get roomFailedOther;

  /// No description provided for @roomFailedCryptor.
  ///
  /// In en, this message translates to:
  /// **'This device cannot protect call media, so it did not join.'**
  String get roomFailedCryptor;

  /// No description provided for @roomPeople.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 person} other{{count} people}}'**
  String roomPeople(int count);

  /// No description provided for @roomCameraOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on camera'**
  String get roomCameraOn;

  /// No description provided for @roomCameraOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off camera'**
  String get roomCameraOff;

  /// No description provided for @roomPickSourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose what to share'**
  String get roomPickSourceTitle;

  /// No description provided for @roomSourceScreen.
  ///
  /// In en, this message translates to:
  /// **'Screen'**
  String get roomSourceScreen;

  /// No description provided for @roomSourceWindow.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get roomSourceWindow;

  /// No description provided for @roomSharingYou.
  ///
  /// In en, this message translates to:
  /// **'You are sharing your screen'**
  String get roomSharingYou;

  /// No description provided for @roomNoticeCamera.
  ///
  /// In en, this message translates to:
  /// **'The camera could not be started.'**
  String get roomNoticeCamera;

  /// No description provided for @roomNoticeScreen.
  ///
  /// In en, this message translates to:
  /// **'The screen could not be shared.'**
  String get roomNoticeScreen;

  /// No description provided for @roomNoticeNoSource.
  ///
  /// In en, this message translates to:
  /// **'There is no screen or window to share.'**
  String get roomNoticeNoSource;

  /// No description provided for @roomNoticeVideoFull.
  ///
  /// In en, this message translates to:
  /// **'This call has too many people for video. Voice only.'**
  String get roomNoticeVideoFull;

  /// No description provided for @roomTileScreen.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s screen'**
  String roomTileScreen(String name);

  /// No description provided for @moderationTitle.
  ///
  /// In en, this message translates to:
  /// **'Moderation'**
  String get moderationTitle;

  /// No description provided for @moderationDetail.
  ///
  /// In en, this message translates to:
  /// **'Bans, timeouts, slow mode, paused invitations and the activity log'**
  String get moderationDetail;

  /// Moderation screen: shown with Retry when the bans, slow mode, invitation state or activity log could not be read. Nothing is guessed in its place.
  ///
  /// In en, this message translates to:
  /// **'Could not load'**
  String get moderationLoadFailed;

  /// No description provided for @memberModerateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Moderate {username}'**
  String memberModerateTooltip(String username);

  /// No description provided for @memberBanAction.
  ///
  /// In en, this message translates to:
  /// **'Ban…'**
  String get memberBanAction;

  /// No description provided for @memberTimeoutAction.
  ///
  /// In en, this message translates to:
  /// **'Time out…'**
  String get memberTimeoutAction;

  /// No description provided for @memberTimeoutLift.
  ///
  /// In en, this message translates to:
  /// **'Lift timeout'**
  String get memberTimeoutLift;

  /// Under a community member's name while the verified role record holds a timeout for them.
  ///
  /// In en, this message translates to:
  /// **'Timed out until {time}'**
  String memberTimedOutUntil(String time);

  /// Under a community member's name, for owners and admins, while the server holds a running timeout that the verified role record lacks (it came back when they rejoined).
  ///
  /// In en, this message translates to:
  /// **'Timed out until {time} (server only)'**
  String memberServerTimeoutUntil(String time);

  /// Member menu action: writes the server-only timeout into the group's verified role record, so every member's app sees it.
  ///
  /// In en, this message translates to:
  /// **'Apply to the record'**
  String get memberTimeoutApplyToRecord;

  /// No description provided for @memberTimeoutAppliedToRecord.
  ///
  /// In en, this message translates to:
  /// **'Timeout added to the record.'**
  String get memberTimeoutAppliedToRecord;

  /// No description provided for @banTitle.
  ///
  /// In en, this message translates to:
  /// **'Ban {username}?'**
  String banTitle(String username);

  /// No description provided for @banMessage.
  ///
  /// In en, this message translates to:
  /// **'They are removed from the community and cannot return until the ban is lifted.'**
  String get banMessage;

  /// No description provided for @banConfirm.
  ///
  /// In en, this message translates to:
  /// **'Ban'**
  String get banConfirm;

  /// No description provided for @timeoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Time out {username} for how long?'**
  String timeoutTitle(String username);

  /// No description provided for @timeoutDone.
  ///
  /// In en, this message translates to:
  /// **'Timeout set.'**
  String get timeoutDone;

  /// No description provided for @moderationSectionInvites.
  ///
  /// In en, this message translates to:
  /// **'Invitations'**
  String get moderationSectionInvites;

  /// No description provided for @moderationInvitesOpen.
  ///
  /// In en, this message translates to:
  /// **'Invitation links work normally.'**
  String get moderationInvitesOpen;

  /// No description provided for @moderationInvitesPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused until {time}.'**
  String moderationInvitesPaused(String time);

  /// No description provided for @moderationPauseInvites.
  ///
  /// In en, this message translates to:
  /// **'Pause invitations'**
  String get moderationPauseInvites;

  /// No description provided for @moderationResumeInvites.
  ///
  /// In en, this message translates to:
  /// **'Resume invitations'**
  String get moderationResumeInvites;

  /// No description provided for @moderationSectionSlow.
  ///
  /// In en, this message translates to:
  /// **'Slow mode'**
  String get moderationSectionSlow;

  /// No description provided for @moderationSlowOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get moderationSlowOff;

  /// No description provided for @moderationSlowEvery.
  ///
  /// In en, this message translates to:
  /// **'One message every {interval}'**
  String moderationSlowEvery(String interval);

  /// No description provided for @moderationSlowTitle.
  ///
  /// In en, this message translates to:
  /// **'Slow mode in {channel}'**
  String moderationSlowTitle(String channel);

  /// No description provided for @moderationSectionBans.
  ///
  /// In en, this message translates to:
  /// **'Banned accounts'**
  String get moderationSectionBans;

  /// No description provided for @moderationNoBans.
  ///
  /// In en, this message translates to:
  /// **'Nobody is banned.'**
  String get moderationNoBans;

  /// No description provided for @moderationUnban.
  ///
  /// In en, this message translates to:
  /// **'Lift ban for {username}'**
  String moderationUnban(String username);

  /// No description provided for @moderationSectionLog.
  ///
  /// In en, this message translates to:
  /// **'Activity log'**
  String get moderationSectionLog;

  /// No description provided for @moderationNoEvents.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet.'**
  String get moderationNoEvents;

  /// No description provided for @moderationLogKick.
  ///
  /// In en, this message translates to:
  /// **'{actor} removed {target}'**
  String moderationLogKick(String actor, String target);

  /// No description provided for @moderationLogBan.
  ///
  /// In en, this message translates to:
  /// **'{actor} banned {target}'**
  String moderationLogBan(String actor, String target);

  /// No description provided for @moderationLogUnban.
  ///
  /// In en, this message translates to:
  /// **'{actor} lifted the ban on {target}'**
  String moderationLogUnban(String actor, String target);

  /// No description provided for @moderationLogTimeout.
  ///
  /// In en, this message translates to:
  /// **'{actor} timed out {target}'**
  String moderationLogTimeout(String actor, String target);

  /// No description provided for @moderationLogTimeoutCleared.
  ///
  /// In en, this message translates to:
  /// **'{actor} lifted the timeout of {target}'**
  String moderationLogTimeoutCleared(String actor, String target);

  /// No description provided for @moderationLogSlowMode.
  ///
  /// In en, this message translates to:
  /// **'{actor} changed slow mode'**
  String moderationLogSlowMode(String actor);

  /// No description provided for @moderationLogInvitesPaused.
  ///
  /// In en, this message translates to:
  /// **'{actor} paused invitations'**
  String moderationLogInvitesPaused(String actor);

  /// No description provided for @moderationLogInvitesResumed.
  ///
  /// In en, this message translates to:
  /// **'{actor} resumed invitations'**
  String moderationLogInvitesResumed(String actor);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report message'**
  String get c6ReportMessage;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report this message'**
  String get c6ReportTitle;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This sends this one message and the reason you pick, with what is needed to check it, to the people who handle reports here. It is sealed, so the server itself cannot read it. Nothing else from the chat is sent.'**
  String get c6ReportIntro;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This message will be sent'**
  String get c6ReportPreviewLabel;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'A message without text, such as an attachment. Its details are sent, including the key that opens the file, not the file itself.'**
  String get c6ReportPreviewNoText;

  /// C6 reports (U33): heading above the fixed list of reasons. A reason must be chosen before sending.
  ///
  /// In en, this message translates to:
  /// **'Why are you reporting it?'**
  String get c6ReportReasonLabel;

  /// C6 reports (U33): under the reason list. The reason is sealed inside the report; the server cannot read it.
  ///
  /// In en, this message translates to:
  /// **'Only the people who get the report see the reason. It is sealed with the message.'**
  String get c6ReportReasonNote;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Spam or scam'**
  String get c6ReportReasonSpam;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Harassment or bullying'**
  String get c6ReportReasonHarassment;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Hate speech'**
  String get c6ReportReasonHate;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Threats or violence'**
  String get c6ReportReasonViolence;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Sexual content'**
  String get c6ReportReasonSexual;

  /// C6 report reason (U33): child safety.
  ///
  /// In en, this message translates to:
  /// **'Puts a child at risk'**
  String get c6ReportReasonChildSafety;

  /// C6 report reason (U33).
  ///
  /// In en, this message translates to:
  /// **'Self-harm or suicide'**
  String get c6ReportReasonSelfHarm;

  /// C6 report reason (U33): doxxing.
  ///
  /// In en, this message translates to:
  /// **'Shares someone\'s private information'**
  String get c6ReportReasonPrivateInfo;

  /// C6 report reason (U33): the last choice, for anything the list does not name.
  ///
  /// In en, this message translates to:
  /// **'Something else'**
  String get c6ReportReasonOther;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Send report'**
  String get c6ReportSend;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report sent.'**
  String get c6ReportSent;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Server owners who get a copy: {count}'**
  String c6ReportRecipientCount(int count);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Check the owner keys'**
  String get c6ReportPinTitle;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Ask each owner to read you the code from Settings, Reports, on their device. If it matches, trust it. If it does not, do not send the report.'**
  String get c6ReportPinBody;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Owner {owner}: {fingerprint}'**
  String c6ReportOwnerKey(String owner, String fingerprint);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This owner\'s key changed since you last trusted it. Ask them whether they changed it.'**
  String get c6ReportKeyChanged;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'An owner you trusted before gets no copy now. The server may be holding it back.'**
  String get c6ReportKeyMissing;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Trust and continue'**
  String get c6ReportTrust;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This community has no verified roles, so the app can\'t tell who its moderators are.'**
  String get c6ReportCommunityUnavailable;

  /// C6 reports: no moderator key is authenticated over MLS yet.
  ///
  /// In en, this message translates to:
  /// **'No moderator\'s key has reached this device yet. Keys arrive through the community. Try again later.'**
  String get c6ReportModeratorKeysPending;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Moderators who get a copy: {count}'**
  String c6ReportModeratorCount(int count);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Moderators whose key has not reached this device yet, and who get no copy: {count}'**
  String c6ReportModeratorsUnconfirmed(int count);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'No server owner can receive reports yet. Ask them to set up a report key.'**
  String get c6ReportNoOwnerKey;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This message cannot be reported. It was received before reporting existed, was sent without proof, or has been deleted.'**
  String get c6ReportNotReportable;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'An owner key is not trusted yet. Open the report again and check it.'**
  String get c6ReportKeysNotPinned;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'You already reported this message.'**
  String get c6ReportAlready;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reporting is not available in this build.'**
  String get c6ReportUnavailable;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get c6ReportsTitle;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Messages people reported to you as server owner'**
  String get c6ReportsSettingsDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report key'**
  String get c6ReportsKeySection;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This device has no report key. Without one, nobody can report to you.'**
  String get c6ReportsKeyNone;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This device holds your report key. Read its code to people who ask to check it.'**
  String get c6ReportsKeyActive;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Code: {fingerprint}'**
  String c6ReportsKeyCode(String fingerprint);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Create report key'**
  String get c6ReportsKeyCreate;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Create a new report key here?'**
  String get c6ReportsKeyCreateTitle;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'If you already have a report key on another device, this replaces it. Reports already sent to the old key open only on a device that still holds that key, and are lost on this one. People must trust your new key before they can report again.'**
  String get c6ReportsKeyCreateBody;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Replace key'**
  String get c6ReportsKeyReplace;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Publish key again'**
  String get c6ReportsKeyPublish;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report key published.'**
  String get c6ReportsKeyReady;

  /// C6 reports: the server refused a key publish because another device of the account published or replaced the key since this screen loaded.
  ///
  /// In en, this message translates to:
  /// **'Another device changed your report key while you were deciding. Nothing was changed here. Check the key below and choose again.'**
  String get c6ReportsKeyChangedMeanwhile;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'No reports'**
  String get c6ReportsEmpty;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reports are kept until you dismiss them, or for 90 days.'**
  String get c6ReportsEmptyDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Community reports'**
  String get c6ReportsCommunity;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reports about a community go to its moderators. A moderator opens them from the community.'**
  String get c6ReportsCommunityUnavailable;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reported {when}'**
  String c6ReportsFiled(String when);

  /// C6 reports: the second line of an inbox row.
  ///
  /// In en, this message translates to:
  /// **'Reported by {reporter}, {when}'**
  String c6ReportsFiledBy(String reporter, String when);

  /// C6 reports: the chat or channel the reported message was in.
  ///
  /// In en, this message translates to:
  /// **'In {place}'**
  String c6ReportsWhere(String place);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Cannot open'**
  String get c6ReportsLocked;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This device has no report key, so it cannot open this report. Open it on the device that made your key.'**
  String get c6ReportsLockedNoSeed;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Sent to an older report key that this device does not hold.'**
  String get c6ReportsLockedOtherKey;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This report is damaged or was not meant for you.'**
  String get c6ReportsLockedDamaged;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reported message'**
  String get c6ReportsMessageLabel;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Not a text message. Its details, including the key that opens the file, are in the report, not the file itself.'**
  String get c6ReportsNoText;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Reported by {account}'**
  String c6ReportsReporter(String account);

  /// C6 reports (U33): the reporter's chosen reason, one of the c6ReportReason labels. It is the reporter's claim, not something the check proves.
  ///
  /// In en, this message translates to:
  /// **'Reason given by the reporter: {reason}'**
  String c6ReportsReason(String reason);

  /// C6 reports (U33): first part of an inbox row's second line. Names the reason as the reporter's claim, never a finding.
  ///
  /// In en, this message translates to:
  /// **'Reporter\'s reason: {reason}'**
  String c6ReportsRowReason(String reason);

  /// C6 reports (U33): an opened report from before reasons existed.
  ///
  /// In en, this message translates to:
  /// **'No reason given. Reports from older app versions carry none.'**
  String get c6ReportsReasonNone;

  /// C6 reports (U33): under the reason. Must not suggest the franking check says anything about the reason.
  ///
  /// In en, this message translates to:
  /// **'The check covers the message only, not the reason.'**
  String get c6ReportsReasonNotChecked;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Sent by {account}'**
  String c6ReportsSender(String account);

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Check against the server record'**
  String get c6ReportsCheck;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get c6ReportsChecking;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Checking tells the server which message this report is about.'**
  String get c6ReportsCheckNote;

  /// C6 reports: opens the careful explanation under the verdict.
  ///
  /// In en, this message translates to:
  /// **'Why not certain?'**
  String get c6ReportsWhyNotCertain;

  /// C6 reports: what a franking check can and cannot show. Must not claim more than C6 does.
  ///
  /// In en, this message translates to:
  /// **'Even a match shows only that the server\'s record agrees this account sent this exact message in this conversation. It cannot show what came before or after it, or what was meant, and it is only as trustworthy as that record.'**
  String get c6ReportsWhyNotCertainCommon;

  /// C6 reports: next step beside Dismiss once a report holds up.
  ///
  /// In en, this message translates to:
  /// **'Copy message text'**
  String get c6ReportsCopyText;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Message text copied.'**
  String get c6ReportsCopied;

  /// C6 reports: shown beside Dismiss when the check did not hold up.
  ///
  /// In en, this message translates to:
  /// **'Nothing here backs this report up. You can dismiss it.'**
  String get c6ReportsNothingBacksUp;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Matches the server record'**
  String get c6VerdictVerified;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'The server recorded this exact message from this sender in this conversation. That is only as trustworthy as the server\'s own record.'**
  String get c6VerdictVerifiedDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Does not match'**
  String get c6VerdictMismatch;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'The server\'s record disagrees with this report. Treat it as unproven or forged.'**
  String get c6VerdictMismatchDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Cannot be checked'**
  String get c6VerdictGone;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'The server no longer has this message, so nothing can be compared.'**
  String get c6VerdictGoneDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Cannot be proven'**
  String get c6VerdictUnfranked;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This message was sent by an app that adds no proof.'**
  String get c6VerdictUnfrankedDetail;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Dismiss report'**
  String get c6ReportsDismiss;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Dismiss this report?'**
  String get c6ReportsDismissTitle;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This removes your copy for good. Other owners keep theirs.'**
  String get c6ReportsDismissBody;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Report dismissed.'**
  String get c6ReportsDismissed;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Your report key is held on another device. Reports to it open there, not here.'**
  String get c6ReportsKeyElsewhere;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'Another device replaced your report key. New reports go to the key below; this device only opens reports sent to its older key.'**
  String get c6ReportsKeyReplacedElsewhere;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This device holds a report key that is not published yet. Publish it so people can report to you.'**
  String get c6ReportsKeyUnpublished;

  /// C6 reports.
  ///
  /// In en, this message translates to:
  /// **'This device holds your report key. Signing out deletes it, and reports already sent to it can no longer be opened. Deal with your reports first.'**
  String get c6SignOutSeedWarning;

  /// No description provided for @autoBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic backups'**
  String get autoBackupTitle;

  /// No description provided for @autoBackupIntro.
  ///
  /// In en, this message translates to:
  /// **'Every day this device backs up your chats, locked with your recovery key. Only that key opens them; the server cannot. The new backup replaces the old one. Disappearing messages are never backed up.'**
  String get autoBackupIntro;

  /// No description provided for @autoBackupIntroPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone backs up your chats when you open the app, at most once a day, locked with your recovery key. Only that key opens them; the server cannot. The new backup replaces the old one. Disappearing messages are never backed up.'**
  String get autoBackupIntroPhone;

  /// No description provided for @autoBackupLast.
  ///
  /// In en, this message translates to:
  /// **'Last backup {date}'**
  String autoBackupLast(String date);

  /// No description provided for @autoBackupPending.
  ///
  /// In en, this message translates to:
  /// **'First backup not made yet'**
  String get autoBackupPending;

  /// No description provided for @autoBackupServerOff.
  ///
  /// In en, this message translates to:
  /// **'This server has backups turned off'**
  String get autoBackupServerOff;

  /// No description provided for @autoBackupNoKey.
  ///
  /// In en, this message translates to:
  /// **'Save a recovery key to turn on backups'**
  String get autoBackupNoKey;

  /// No description provided for @autoBackupNeedsKeyHere.
  ///
  /// In en, this message translates to:
  /// **'Type your recovery key to turn on backups here'**
  String get autoBackupNeedsKeyHere;

  /// No description provided for @autoBackupKeyChanged.
  ///
  /// In en, this message translates to:
  /// **'Your recovery key changed. Type the new key to go on backing up here.'**
  String get autoBackupKeyChanged;

  /// No description provided for @autoBackupErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'The last backup could not reach the server. It will try again.'**
  String get autoBackupErrorNetwork;

  /// No description provided for @autoBackupErrorSpace.
  ///
  /// In en, this message translates to:
  /// **'Backup space is full. The last good backup is kept.'**
  String get autoBackupErrorSpace;

  /// No description provided for @autoBackupErrorTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Your history is too large to back up. The last good backup is kept.'**
  String get autoBackupErrorTooLarge;

  /// No description provided for @autoBackupErrorFailed.
  ///
  /// In en, this message translates to:
  /// **'The last backup failed. It will try again.'**
  String get autoBackupErrorFailed;

  /// No description provided for @autoBackupStale.
  ///
  /// In en, this message translates to:
  /// **'No backup for over a week.'**
  String get autoBackupStale;

  /// No description provided for @autoBackupPhoneNote.
  ///
  /// In en, this message translates to:
  /// **'This phone backs up when you open the app.'**
  String get autoBackupPhoneNote;

  /// No description provided for @autoBackupNow.
  ///
  /// In en, this message translates to:
  /// **'Back up now'**
  String get autoBackupNow;

  /// No description provided for @autoBackupRunning.
  ///
  /// In en, this message translates to:
  /// **'Backing up…'**
  String get autoBackupRunning;

  /// No description provided for @autoBackupTypeKey.
  ///
  /// In en, this message translates to:
  /// **'Type recovery key'**
  String get autoBackupTypeKey;

  /// No description provided for @autoBackupKeySubmit.
  ///
  /// In en, this message translates to:
  /// **'Turn on backups'**
  String get autoBackupKeySubmit;

  /// No description provided for @autoBackupKeyWrong.
  ///
  /// In en, this message translates to:
  /// **'That is not this account\'s recovery key.'**
  String get autoBackupKeyWrong;

  /// No description provided for @autoBackupKeyOn.
  ///
  /// In en, this message translates to:
  /// **'Backups are on for this device.'**
  String get autoBackupKeyOn;

  /// No description provided for @autoBackupPromptMessage.
  ///
  /// In en, this message translates to:
  /// **'Save a recovery key. It turns on automatic backups and gets your account back if you lose every device.'**
  String get autoBackupPromptMessage;

  /// No description provided for @autoBackupPromptSave.
  ///
  /// In en, this message translates to:
  /// **'Save key'**
  String get autoBackupPromptSave;

  /// No description provided for @autoBackupPromptLater.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get autoBackupPromptLater;

  /// No description provided for @channelPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private channel'**
  String get channelPrivate;

  /// No description provided for @channelPrivateDisclosure.
  ///
  /// In en, this message translates to:
  /// **'Only selected members can see this channel. The server can see who is in it.'**
  String get channelPrivateDisclosure;

  /// No description provided for @channelOpenDisclosure.
  ///
  /// In en, this message translates to:
  /// **'Every community member can see this channel.'**
  String get channelOpenDisclosure;

  /// No description provided for @channelCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not create the channel. Try again.'**
  String get channelCreateFailed;

  /// No description provided for @channelMembersFailed.
  ///
  /// In en, this message translates to:
  /// **'The channel was created. Some members could not be added. Retry to add only those members.'**
  String get channelMembersFailed;

  /// No description provided for @channelMembersSkipped.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member was not added: they are in too many chats. Add them later from the channel\'s members.} other{{count} members were not added: they are in too many chats. Add them later from the channel\'s members.}}'**
  String channelMembersSkipped(int count);

  /// No description provided for @channelAdminOnly.
  ///
  /// In en, this message translates to:
  /// **'Only owners and admins can create channels.'**
  String get channelAdminOnly;

  /// No description provided for @k1ConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Check your recovery key'**
  String get k1ConfirmTitle;

  /// No description provided for @k1ConfirmDetail.
  ///
  /// In en, this message translates to:
  /// **'Type it once more to be sure you still have it. It never leaves this device.'**
  String get k1ConfirmDetail;

  /// No description provided for @k1ConfirmOk.
  ///
  /// In en, this message translates to:
  /// **'That is your recovery key.'**
  String get k1ConfirmOk;

  /// No description provided for @k1ConfirmMismatch.
  ///
  /// In en, this message translates to:
  /// **'That does not match. If you lost your key, make a new one in Recovery key settings.'**
  String get k1ConfirmMismatch;

  /// No description provided for @k1SecondCopyChoose.
  ///
  /// In en, this message translates to:
  /// **'Keep a second copy in a folder'**
  String get k1SecondCopyChoose;

  /// No description provided for @k1SecondCopyFolder.
  ///
  /// In en, this message translates to:
  /// **'Second copy: {folder}'**
  String k1SecondCopyFolder(String folder);

  /// No description provided for @k1SecondCopyDetail.
  ///
  /// In en, this message translates to:
  /// **'The same locked backup, saved where you choose. Only your recovery key opens it.'**
  String get k1SecondCopyDetail;

  /// No description provided for @k1SecondCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'The last copy to this folder failed. Check the folder.'**
  String get k1SecondCopyFailed;

  /// No description provided for @k1SecondCopyOff.
  ///
  /// In en, this message translates to:
  /// **'Stop the second copy'**
  String get k1SecondCopyOff;

  /// No description provided for @k1SecondCopyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This device cannot keep a second copy. The backup stays on the server.'**
  String get k1SecondCopyUnavailable;

  /// No description provided for @k1SecondCopyChosenFolder.
  ///
  /// In en, this message translates to:
  /// **'Second copy: the folder you chose'**
  String get k1SecondCopyChosenFolder;

  /// No description provided for @k1SecondCopyPickFailed.
  ///
  /// In en, this message translates to:
  /// **'That folder cannot be used. Pick another one.'**
  String get k1SecondCopyPickFailed;

  /// No description provided for @k1SecondCopySave.
  ///
  /// In en, this message translates to:
  /// **'Save a copy of the backup'**
  String get k1SecondCopySave;

  /// No description provided for @k1SecondCopySaveDetail.
  ///
  /// In en, this message translates to:
  /// **'Saves this phone\'s latest backup where you choose. Only your recovery key opens it. Save again now and then: this copy does not update itself.'**
  String get k1SecondCopySaveDetail;

  /// No description provided for @k1SecondCopySavedAt.
  ///
  /// In en, this message translates to:
  /// **'Copy saved {date}'**
  String k1SecondCopySavedAt(String date);

  /// No description provided for @k1SecondCopyNoneYet.
  ///
  /// In en, this message translates to:
  /// **'There is no backup from this phone yet. Back up now, then save a copy.'**
  String get k1SecondCopyNoneYet;

  /// No description provided for @k1SecondCopySaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The copy could not be saved. Try again.'**
  String get k1SecondCopySaveFailed;

  /// No description provided for @recoveryFollowUpRestoreDetail.
  ///
  /// In en, this message translates to:
  /// **'Before you replace your recovery key, you can bring your history back from the backups your lost devices made. They open with your old recovery key, which stops working for them once you replace it.'**
  String get recoveryFollowUpRestoreDetail;

  /// No description provided for @recoveryFollowUpRestoreSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get recoveryFollowUpRestoreSkip;

  /// No description provided for @recoveryFollowUpRestoreSkipWarning.
  ///
  /// In en, this message translates to:
  /// **'If you skip, older backups become unusable after you replace your recovery key. Skip anyway?'**
  String get recoveryFollowUpRestoreSkipWarning;

  /// No description provided for @k1RestoreOpen.
  ///
  /// In en, this message translates to:
  /// **'Restore from a backup'**
  String get k1RestoreOpen;

  /// No description provided for @k1RestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore from a backup'**
  String get k1RestoreTitle;

  /// No description provided for @k1RestoreIntro.
  ///
  /// In en, this message translates to:
  /// **'Pick a backup made by one of your other devices and type your recovery key. Your history is merged in; messages already here stay.'**
  String get k1RestoreIntro;

  /// No description provided for @k1RestoreLoading.
  ///
  /// In en, this message translates to:
  /// **'Looking for backups…'**
  String get k1RestoreLoading;

  /// No description provided for @k1RestoreEmpty.
  ///
  /// In en, this message translates to:
  /// **'No backup from another device was found.'**
  String get k1RestoreEmpty;

  /// No description provided for @k1RestoreLegacyRefused.
  ///
  /// In en, this message translates to:
  /// **'Backups in the old format (made before automatic backups) can no longer be restored. They were never changed, but the app will not open them.'**
  String get k1RestoreLegacyRefused;

  /// No description provided for @k1RestoreLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The list of backups could not be loaded.'**
  String get k1RestoreLoadFailed;

  /// No description provided for @k1RestoreEntry.
  ///
  /// In en, this message translates to:
  /// **'{device} · {date}'**
  String k1RestoreEntry(String device, String date);

  /// No description provided for @k1RestoreEntryPrevious.
  ///
  /// In en, this message translates to:
  /// **'{device} · {date} (the copy before)'**
  String k1RestoreEntryPrevious(String device, String date);

  /// No description provided for @k1RestoreOlderCopy.
  ///
  /// In en, this message translates to:
  /// **'Older copy'**
  String get k1RestoreOlderCopy;

  /// No description provided for @k1RestoreDeviceUnnamed.
  ///
  /// In en, this message translates to:
  /// **'A device'**
  String get k1RestoreDeviceUnnamed;

  /// No description provided for @k1RestoreDeviceRevoked.
  ///
  /// In en, this message translates to:
  /// **'This device was removed from your account.'**
  String get k1RestoreDeviceRevoked;

  /// No description provided for @k1RestoreDone.
  ///
  /// In en, this message translates to:
  /// **'History restored.'**
  String get k1RestoreDone;

  /// No description provided for @k1RestoreWrongKey.
  ///
  /// In en, this message translates to:
  /// **'That is not a valid recovery key for this account.'**
  String get k1RestoreWrongKey;

  /// No description provided for @k1RestoreOtherKey.
  ///
  /// In en, this message translates to:
  /// **'This backup was locked with a different recovery key.'**
  String get k1RestoreOtherKey;

  /// No description provided for @k1RestoreCorrupt.
  ///
  /// In en, this message translates to:
  /// **'This backup could not be opened. It may be damaged.'**
  String get k1RestoreCorrupt;

  /// No description provided for @k1RestoreNetwork.
  ///
  /// In en, this message translates to:
  /// **'The server could not be reached. Nothing changed.'**
  String get k1RestoreNetwork;

  /// No description provided for @k1RestoreUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This device cannot restore from a backup.'**
  String get k1RestoreUnavailable;

  /// No description provided for @connectSignInPasskey.
  ///
  /// In en, this message translates to:
  /// **'Sign in with a passkey'**
  String get connectSignInPasskey;

  /// No description provided for @passkeySignInFailed.
  ///
  /// In en, this message translates to:
  /// **'Passkey sign-in failed. Try again, or use your password.'**
  String get passkeySignInFailed;

  /// No description provided for @passkeyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Passkeys are not available on this device, or not set up for this server.'**
  String get passkeyUnavailable;

  /// No description provided for @passkeyPinRefused.
  ///
  /// In en, this message translates to:
  /// **'This server asked for a passkey for a different address, so the app refused.'**
  String get passkeyPinRefused;

  /// No description provided for @apiErrorPasskeyLimit.
  ///
  /// In en, this message translates to:
  /// **'You have reached the passkey limit. Remove one first.'**
  String get apiErrorPasskeyLimit;

  /// No description provided for @apiErrorPasskeyExists.
  ///
  /// In en, this message translates to:
  /// **'This passkey is already added.'**
  String get apiErrorPasskeyExists;

  /// No description provided for @apiErrorInvalidPasskey.
  ///
  /// In en, this message translates to:
  /// **'The server could not verify that passkey.'**
  String get apiErrorInvalidPasskey;

  /// No description provided for @apiErrorPasskeysOff.
  ///
  /// In en, this message translates to:
  /// **'This server does not offer passkeys.'**
  String get apiErrorPasskeysOff;

  /// No description provided for @settingsPasskeys.
  ///
  /// In en, this message translates to:
  /// **'Passkeys'**
  String get settingsPasskeys;

  /// No description provided for @settingsPasskeysDetail.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your phone\'s screen lock instead of the password'**
  String get settingsPasskeysDetail;

  /// No description provided for @passkeysIntro.
  ///
  /// In en, this message translates to:
  /// **'A passkey signs you in on this device instead of the password. Changing settings still asks for your password. The service that keeps your passkey, such as Google or Apple, learns this server\'s address.'**
  String get passkeysIntro;

  /// No description provided for @passkeysNotOffered.
  ///
  /// In en, this message translates to:
  /// **'Passkeys are not available for this server on this device.'**
  String get passkeysNotOffered;

  /// No description provided for @passkeysEmpty.
  ///
  /// In en, this message translates to:
  /// **'No passkeys yet.'**
  String get passkeysEmpty;

  /// No description provided for @passkeysAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a passkey'**
  String get passkeysAdd;

  /// No description provided for @passkeysAdded.
  ///
  /// In en, this message translates to:
  /// **'Passkey added.'**
  String get passkeysAdded;

  /// No description provided for @passkeyCreated.
  ///
  /// In en, this message translates to:
  /// **'Added {date}'**
  String passkeyCreated(String date);

  /// No description provided for @passkeyLastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used {date}'**
  String passkeyLastUsed(String date);

  /// No description provided for @passkeyBackedUp.
  ///
  /// In en, this message translates to:
  /// **'Backed up'**
  String get passkeyBackedUp;

  /// No description provided for @passkeyRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get passkeyRename;

  /// No description provided for @passkeyRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get passkeyRemove;

  /// No description provided for @passkeyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get passkeyNameLabel;

  /// No description provided for @passkeyRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this passkey?'**
  String get passkeyRemoveTitle;

  /// No description provided for @passkeyRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” will no longer sign in to this account. You can add it again later.'**
  String passkeyRemoveBody(String name);

  /// No description provided for @passkeyRemoved.
  ///
  /// In en, this message translates to:
  /// **'Passkey removed.'**
  String get passkeyRemoved;

  /// No description provided for @passkeyNoticeAdded.
  ///
  /// In en, this message translates to:
  /// **'A passkey was added to your account. Not you? Change your password.'**
  String get passkeyNoticeAdded;

  /// No description provided for @passkeyNoticeRemoved.
  ///
  /// In en, this message translates to:
  /// **'A passkey was removed from your account.'**
  String get passkeyNoticeRemoved;

  /// No description provided for @passkeyNoticeDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get passkeyNoticeDismiss;

  /// No description provided for @passkeyNamePrefix.
  ///
  /// In en, this message translates to:
  /// **'Passkey'**
  String get passkeyNamePrefix;

  /// No description provided for @settingsAccounts.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get settingsAccounts;

  /// No description provided for @settingsAccountsDetail.
  ///
  /// In en, this message translates to:
  /// **'Switch between the accounts on this device'**
  String get settingsAccountsDetail;

  /// No description provided for @accountsTitle.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get accountsTitle;

  /// No description provided for @accountsIntro.
  ///
  /// In en, this message translates to:
  /// **'One account is open at a time. The others are paused: no messages or notifications arrive for them until you switch to them.'**
  String get accountsIntro;

  /// No description provided for @accountsOpenNow.
  ///
  /// In en, this message translates to:
  /// **'Open now'**
  String get accountsOpenNow;

  /// No description provided for @accountsPending.
  ///
  /// In en, this message translates to:
  /// **'Not signed in yet'**
  String get accountsPending;

  /// No description provided for @accountsRemoving.
  ///
  /// In en, this message translates to:
  /// **'Removing…'**
  String get accountsRemoving;

  /// No description provided for @accountsNewAccount.
  ///
  /// In en, this message translates to:
  /// **'New account'**
  String get accountsNewAccount;

  /// No description provided for @accountsAdd.
  ///
  /// In en, this message translates to:
  /// **'Add an account'**
  String get accountsAdd;

  /// No description provided for @accountsFull.
  ///
  /// In en, this message translates to:
  /// **'This device holds {count} accounts, the most it can. Remove one to add another.'**
  String accountsFull(String count);

  /// No description provided for @accountsSameServer.
  ///
  /// In en, this message translates to:
  /// **'This server can tell that these accounts are on the same device.'**
  String get accountsSameServer;

  /// No description provided for @accountsSwitching.
  ///
  /// In en, this message translates to:
  /// **'Switching…'**
  String get accountsSwitching;

  /// No description provided for @accountsSwitchTo.
  ///
  /// In en, this message translates to:
  /// **'Switch to {name}'**
  String accountsSwitchTo(String name);

  /// No description provided for @accountsRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from this device'**
  String get accountsRemove;

  /// No description provided for @accountsRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from this device?'**
  String accountsRemoveTitle(String name);

  /// No description provided for @accountsRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'This signs the account out and deletes its messages and keys from this device. The account stays on its server. If you will not use this device again, remove it from the account\'s device list on another device.'**
  String get accountsRemoveBody;

  /// No description provided for @accountsPushFailTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch anyway?'**
  String get accountsPushFailTitle;

  /// No description provided for @accountsPushFailBody.
  ///
  /// In en, this message translates to:
  /// **'Notifications for {name} could not be turned off. You may get notifications for this account until you open it again.'**
  String accountsPushFailBody(String name);

  /// No description provided for @accountsSwitchAnyway.
  ///
  /// In en, this message translates to:
  /// **'Switch anyway'**
  String get accountsSwitchAnyway;

  /// No description provided for @accountsErrorOpen.
  ///
  /// In en, this message translates to:
  /// **'That account could not be opened. The previous account is open again.'**
  String get accountsErrorOpen;

  /// No description provided for @accountsErrorRegistry.
  ///
  /// In en, this message translates to:
  /// **'The account list could not be saved.'**
  String get accountsErrorRegistry;

  /// No description provided for @accountsErrorRemove.
  ///
  /// In en, this message translates to:
  /// **'The account could not be removed. Try again.'**
  String get accountsErrorRemove;

  /// No description provided for @accountsDuplicate.
  ///
  /// In en, this message translates to:
  /// **'This device already has that account, so the extra sign-in was removed. Remove this device\'s extra entry from the account\'s device list.'**
  String get accountsDuplicate;

  /// No description provided for @accountsBack.
  ///
  /// In en, this message translates to:
  /// **'Back to my accounts'**
  String get accountsBack;

  /// No description provided for @settingsSectionUpdates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get settingsSectionUpdates;

  /// No description provided for @settingsAutoUpdateCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically'**
  String get settingsAutoUpdateCheck;

  /// No description provided for @settingsAutoUpdateCheckDetail.
  ///
  /// In en, this message translates to:
  /// **'Check for genuine new versions on launch'**
  String get settingsAutoUpdateCheckDetail;

  /// No description provided for @settingsCheckForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get settingsCheckForUpdates;

  /// No description provided for @settingsCheckingForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get settingsCheckingForUpdates;

  /// No description provided for @settingsUpdateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Veritra is up to date'**
  String get settingsUpdateUpToDate;

  /// No description provided for @settingsUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available'**
  String settingsUpdateAvailable(String version);

  /// No description provided for @settingsUpdateError.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates'**
  String get settingsUpdateError;

  /// No description provided for @settingsUpdateDisabled.
  ///
  /// In en, this message translates to:
  /// **'Automatic update checks are turned off'**
  String get settingsUpdateDisabled;

  /// No description provided for @settingsUpdateUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Update checks are not available in this build'**
  String get settingsUpdateUnavailable;

  /// No description provided for @settingsUpdateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download update'**
  String get settingsUpdateDownload;

  /// No description provided for @settingsUpdateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading the update…'**
  String get settingsUpdateDownloading;

  /// No description provided for @settingsUpdateDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'The update could not be downloaded or verified'**
  String get settingsUpdateDownloadFailed;

  /// No description provided for @settingsUpdateRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart to update'**
  String get settingsUpdateRestart;

  /// No description provided for @settingsUpdateReady.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is ready'**
  String settingsUpdateReady(String version);

  /// No description provided for @settingsScreenGuard.
  ///
  /// In en, this message translates to:
  /// **'Screen guard'**
  String get settingsScreenGuard;

  /// No description provided for @settingsScreenGuardDetail.
  ///
  /// In en, this message translates to:
  /// **'Block screenshots and AI-assistant screen reading in chats.'**
  String get settingsScreenGuardDetail;

  /// No description provided for @communityInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Categories and icon'**
  String get communityInfoTitle;

  /// No description provided for @communityIconChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose an icon'**
  String get communityIconChoose;

  /// No description provided for @communityIconRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove icon'**
  String get communityIconRemove;

  /// No description provided for @communityCategories.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get communityCategories;

  /// No description provided for @communityCategoryNew.
  ///
  /// In en, this message translates to:
  /// **'New category'**
  String get communityCategoryNew;

  /// No description provided for @communityCategoryName.
  ///
  /// In en, this message translates to:
  /// **'Category name'**
  String get communityCategoryName;

  /// No description provided for @communityCategoryRename.
  ///
  /// In en, this message translates to:
  /// **'Rename category'**
  String get communityCategoryRename;

  /// No description provided for @communityCategoryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete category'**
  String get communityCategoryDelete;

  /// No description provided for @communityCategoryDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this category? Its channels stay and show without a category.'**
  String get communityCategoryDeleteConfirm;

  /// No description provided for @communityCategoryPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get communityCategoryPlaceholder;

  /// No description provided for @communityCategoryNone.
  ///
  /// In en, this message translates to:
  /// **'No category'**
  String get communityCategoryNone;

  /// No description provided for @communityChannelPlaces.
  ///
  /// In en, this message translates to:
  /// **'Where channels sit'**
  String get communityChannelPlaces;

  /// No description provided for @communityInfoSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save. Try again.'**
  String get communityInfoSaveFailed;

  /// No description provided for @communityInfoOpen.
  ///
  /// In en, this message translates to:
  /// **'Categories and icon'**
  String get communityInfoOpen;

  /// No description provided for @rolesTitle.
  ///
  /// In en, this message translates to:
  /// **'Roles'**
  String get rolesTitle;

  /// No description provided for @rolesDetail.
  ///
  /// In en, this message translates to:
  /// **'Checked by every member\'s app, not by the server.'**
  String get rolesDetail;

  /// No description provided for @rolesNoRecord.
  ///
  /// In en, this message translates to:
  /// **'This group was made before verified roles, so the roles shown are the server\'s.'**
  String get rolesNoRecord;

  /// No description provided for @rolesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Roles can\'t be read on this device right now.'**
  String get rolesUnavailable;

  /// No description provided for @rolesYou.
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String rolesYou(String name);

  /// No description provided for @rolesElector.
  ///
  /// In en, this message translates to:
  /// **'Votes for a new owner'**
  String get rolesElector;

  /// No description provided for @rolesMakeAdmin.
  ///
  /// In en, this message translates to:
  /// **'Make admin'**
  String get rolesMakeAdmin;

  /// No description provided for @rolesMakeModerator.
  ///
  /// In en, this message translates to:
  /// **'Make moderator'**
  String get rolesMakeModerator;

  /// No description provided for @rolesMakeMember.
  ///
  /// In en, this message translates to:
  /// **'Make member'**
  String get rolesMakeMember;

  /// No description provided for @rolesStepDown.
  ///
  /// In en, this message translates to:
  /// **'Step down'**
  String get rolesStepDown;

  /// No description provided for @rolesChangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Change {name}\'s role?'**
  String rolesChangeTitle(String name);

  /// No description provided for @rolesChangeMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} becomes {role}. Everyone in the group sees the change.'**
  String rolesChangeMessage(String name, String role);

  /// No description provided for @rolesChangeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Change role'**
  String get rolesChangeConfirm;

  /// No description provided for @rolesStepDownTitle.
  ///
  /// In en, this message translates to:
  /// **'Step down?'**
  String get rolesStepDownTitle;

  /// No description provided for @rolesStepDownMessage.
  ///
  /// In en, this message translates to:
  /// **'You become a member. Only someone with a higher role can give your role back.'**
  String get rolesStepDownMessage;

  /// No description provided for @rolesElectorOn.
  ///
  /// In en, this message translates to:
  /// **'Let them vote for a new owner'**
  String get rolesElectorOn;

  /// No description provided for @rolesElectorOff.
  ///
  /// In en, this message translates to:
  /// **'Stop them voting for a new owner'**
  String get rolesElectorOff;

  /// No description provided for @rolesTransfer.
  ///
  /// In en, this message translates to:
  /// **'Make owner'**
  String get rolesTransfer;

  /// No description provided for @rolesTransferConfirm.
  ///
  /// In en, this message translates to:
  /// **'Hand this group to {name}? You become an admin.'**
  String rolesTransferConfirm(String name);

  /// No description provided for @rolesOwnership.
  ///
  /// In en, this message translates to:
  /// **'Ownership'**
  String get rolesOwnership;

  /// No description provided for @rolesElectionOpen.
  ///
  /// In en, this message translates to:
  /// **'An owner election is open. Votes: {votes} of {total}.'**
  String rolesElectionOpen(String votes, String total);

  /// No description provided for @rolesElectionNone.
  ///
  /// In en, this message translates to:
  /// **'If the owner is away for more than 30 days, the admins can choose a new one.'**
  String get rolesElectionNone;

  /// No description provided for @rolesStartElection.
  ///
  /// In en, this message translates to:
  /// **'Start an owner election'**
  String get rolesStartElection;

  /// No description provided for @rolesVoteFor.
  ///
  /// In en, this message translates to:
  /// **'Vote for {name}'**
  String rolesVoteFor(String name);

  /// No description provided for @rolesCloseElection.
  ///
  /// In en, this message translates to:
  /// **'End the election'**
  String get rolesCloseElection;

  /// No description provided for @rolesOwnerCancelNote.
  ///
  /// In en, this message translates to:
  /// **'You are the owner: your app ends this election by itself.'**
  String get rolesOwnerCancelNote;

  /// No description provided for @rolesEarlyWin.
  ///
  /// In en, this message translates to:
  /// **'This handover came sooner than this device allows: 30 days without the owner and 7 days with the election open, both by its own clock. Ask the other members if it was expected.'**
  String get rolesEarlyWin;

  /// No description provided for @rolesElectorHint.
  ///
  /// In en, this message translates to:
  /// **'Admins without the vote mark cannot choose a new owner if you are away. Give it to the admins you trust.'**
  String get rolesElectorHint;

  /// No description provided for @rolesOnlyAdminsPost.
  ///
  /// In en, this message translates to:
  /// **'Only admins post'**
  String get rolesOnlyAdminsPost;

  /// No description provided for @channelHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'History for new members'**
  String get channelHistoryTitle;

  /// No description provided for @channelHistoryFullLabel.
  ///
  /// In en, this message translates to:
  /// **'People who join later can read earlier posts'**
  String get channelHistoryFullLabel;

  /// No description provided for @channelHistoryOnConfirm.
  ///
  /// In en, this message translates to:
  /// **'New posts can be read by people who join later.'**
  String get channelHistoryOnConfirm;

  /// Second point of the turn-on confirmation for history for new members (C7): newcomers read from the switch on.
  ///
  /// In en, this message translates to:
  /// **'Posts made before you turn this on stay hidden from them.'**
  String get channelHistoryOnEarlier;

  /// No description provided for @channelHistoryOffConfirm.
  ///
  /// In en, this message translates to:
  /// **'People who join later won\'t see earlier posts.'**
  String get channelHistoryOffConfirm;

  /// Second point of the turn-off confirmation for history for new members (C7): existing members keep what they have.
  ///
  /// In en, this message translates to:
  /// **'Members who already have earlier posts keep them.'**
  String get channelHistoryOffKept;

  /// Third point of the turn-off confirmation (C7): after off and on again, newcomers read only the newest period.
  ///
  /// In en, this message translates to:
  /// **'If you turn it back on later, new members will only see posts made after that.'**
  String get channelHistoryOffAgain;

  /// No description provided for @channelHistoryProofConfirm.
  ///
  /// In en, this message translates to:
  /// **'Posts are signed, so a post can be proven to be its author\'s. Anyone who gets this channel\'s history, for example the server\'s stored copy with a key from one member\'s device, can show who wrote each post. Authors cannot deny their posts.'**
  String get channelHistoryProofConfirm;

  /// No description provided for @channelHistoryProofLine.
  ///
  /// In en, this message translates to:
  /// **'Posts can be proven to be their author\'s'**
  String get channelHistoryProofLine;

  /// No description provided for @channelHistoryProofAccept.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get channelHistoryProofAccept;

  /// No description provided for @channelHistoryLineFull.
  ///
  /// In en, this message translates to:
  /// **'New posts can be read by people who join later'**
  String get channelHistoryLineFull;

  /// No description provided for @channelHistoryLineFromJoin.
  ///
  /// In en, this message translates to:
  /// **'New posts can be read only by people who are members when they are sent'**
  String get channelHistoryLineFromJoin;

  /// No description provided for @channelHistoryPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the change to go through'**
  String get channelHistoryPending;

  /// No description provided for @channelHistoryTimeout.
  ///
  /// In en, this message translates to:
  /// **'The change did not go through. Try again.'**
  String get channelHistoryTimeout;

  /// No description provided for @channelHistoryLost.
  ///
  /// In en, this message translates to:
  /// **'Another admin changed this setting at the same time. Check it and try again.'**
  String get channelHistoryLost;

  /// No description provided for @channelHistoryPaused.
  ///
  /// In en, this message translates to:
  /// **'History for new members is paused until the next membership change.'**
  String get channelHistoryPaused;

  /// No description provided for @channelHistoryEarlier.
  ///
  /// In en, this message translates to:
  /// **'Load earlier posts'**
  String get channelHistoryEarlier;

  /// No description provided for @channelHistoryAttachmentHidden.
  ///
  /// In en, this message translates to:
  /// **'Attachment from before you joined'**
  String get channelHistoryAttachmentHidden;

  /// No description provided for @channelHistoryFormerMember.
  ///
  /// In en, this message translates to:
  /// **'From a former member'**
  String get channelHistoryFormerMember;

  /// No description provided for @channelHistoryFormerMemberUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Former member'**
  String get channelHistoryFormerMemberUnnamed;

  /// No description provided for @channelConvertToPrivate.
  ///
  /// In en, this message translates to:
  /// **'Make this channel private'**
  String get channelConvertToPrivate;

  /// No description provided for @channelConvertToOpen.
  ///
  /// In en, this message translates to:
  /// **'Make this channel open'**
  String get channelConvertToOpen;

  /// No description provided for @channelConvertOpenTitle.
  ///
  /// In en, this message translates to:
  /// **'Make this channel open?'**
  String get channelConvertOpenTitle;

  /// No description provided for @channelConvertOpenConfirm.
  ///
  /// In en, this message translates to:
  /// **'Earlier posts in this channel will become visible to everyone who can read the open channel, including community members who were never in this private channel.'**
  String get channelConvertOpenConfirm;

  /// Making a private channel open, when its earlier posts do not open for the shared group: channel history is off, or the channel keeps posts from each member's join.
  ///
  /// In en, this message translates to:
  /// **'Earlier posts in this channel stay with the people who already had them. Community members who were never in this private channel will see only posts made after it opens.'**
  String get channelConvertOpenConfirmKept;

  /// No description provided for @channelConvertOpenAccept.
  ///
  /// In en, this message translates to:
  /// **'Make open'**
  String get channelConvertOpenAccept;

  /// No description provided for @channelConvertPrivateTitle.
  ///
  /// In en, this message translates to:
  /// **'Make this channel private?'**
  String get channelConvertPrivateTitle;

  /// No description provided for @channelConvertPrivatePick.
  ///
  /// In en, this message translates to:
  /// **'Everyone ticked is added to the private channel and keeps its earlier posts. Anyone you untick loses access to the channel and its earlier posts.'**
  String get channelConvertPrivatePick;

  /// No description provided for @channelConvertPrivateNoReaders.
  ///
  /// In en, this message translates to:
  /// **'No one else reads this channel yet.'**
  String get channelConvertPrivateNoReaders;

  /// No description provided for @channelConvertReadersFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load who reads this channel. Try again.'**
  String get channelConvertReadersFailed;

  /// No description provided for @channelConvertPrivateAccept.
  ///
  /// In en, this message translates to:
  /// **'Make private'**
  String get channelConvertPrivateAccept;

  /// Shown after an open channel was made private when some ticked readers could not be added.
  ///
  /// In en, this message translates to:
  /// **'The channel is private now, but these ticked readers could not be added: {names}. Add them from the channel\'s members.'**
  String channelConvertNotAdded(String names);

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Sender not confirmed'**
  String get c6VerdictSenderUnverified;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'The message matches, but its sender\'s key could not be checked against their signed device list.'**
  String get c6VerdictSenderUnverifiedDetail;

  /// L2-3 sealed sender: report verdict when the sender's device list was first seen too late to rule out the server.
  ///
  /// In en, this message translates to:
  /// **'Matches, if the server is honest'**
  String get c6VerdictServerTrusted;

  /// L2-3 sealed sender: report verdict when the sender's device list was first seen too late to rule out the server.
  ///
  /// In en, this message translates to:
  /// **'The proof checks, but this device first got the sender’s signed device list from the server only after this report arrived. A dishonest server could have made up that list and this proof. Treat the sender as unconfirmed unless you trust the server.'**
  String get c6VerdictServerTrustedDetail;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Not provable to you'**
  String get c6VerdictNotDesignated;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'The message matches, but it was sent without your name and was not made provable to your current report key. Its sender\'s app had not pinned your key, or you replaced the key since. It cannot be proven here.'**
  String get c6VerdictNotDesignatedDetail;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Proof does not check'**
  String get c6VerdictProofFailed;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'The message matches, but its proof for you does not check out for the sender it names. Do not rely on who sent it.'**
  String get c6VerdictProofFailedDetail;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'No owner\'s report key is pinned on this device yet. A message you send without your name can then be proven to no one if it is reported. The app pins the owners\' keys the first time the server lists them.'**
  String get l2SealedProvableNone;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'A message you send without your name can be proven, if reported, only to the owners whose report keys this app pinned: {count}. Only they can check the proof; it convinces no one else.'**
  String l2SealedProvableOwners(int count);

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Send without your name'**
  String get l2SealedKeyTitle;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Messages without your name'**
  String get l2SealedKeyTile;

  /// No description provided for @l2SealedOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get l2SealedOn;

  /// No description provided for @l2SealedOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get l2SealedOff;

  /// No description provided for @l2SealedSummaryOn.
  ///
  /// In en, this message translates to:
  /// **'The server delivers your messages without learning who sent them.'**
  String get l2SealedSummaryOn;

  /// No description provided for @l2SealedSummaryChanged.
  ///
  /// In en, this message translates to:
  /// **'Paused: the server\'s key changed. Your messages carry your name.'**
  String get l2SealedSummaryChanged;

  /// No description provided for @l2SealedSummaryNotOffered.
  ///
  /// In en, this message translates to:
  /// **'This server does not offer it right now, so your messages carry your name.'**
  String get l2SealedSummaryNotOffered;

  /// No description provided for @l2SealedTechnicalDetails.
  ///
  /// In en, this message translates to:
  /// **'Technical details'**
  String get l2SealedTechnicalDetails;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'This server signs the tokens that let your messages reach it without naming you. The app pinned its key the first time it saw it.'**
  String get l2SealedKeyIntro;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'This server does not offer it, so your messages carry your name.'**
  String get l2SealedKeyOff;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'It turns on after the next sync with this server.'**
  String get l2SealedKeyNone;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Pinned key'**
  String get l2SealedKeyPinned;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Until you answer, your messages carry your name, as before. Say yes only if the server\'s operator told you: a key made just for you would let the server pick out your messages.'**
  String get l2SealedKeyChanged;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'New key'**
  String get l2SealedKeyNew;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Accept new key'**
  String get l2SealedKeyAccept;

  /// No description provided for @l2SealedKeyQuestion.
  ///
  /// In en, this message translates to:
  /// **'Did the server\'s operator tell you its key changed?'**
  String get l2SealedKeyQuestion;

  /// No description provided for @l2SealedKeyKeep.
  ///
  /// In en, this message translates to:
  /// **'No, or I am not sure'**
  String get l2SealedKeyKeep;

  /// No description provided for @l2SealedKeyAcceptAnswer.
  ///
  /// In en, this message translates to:
  /// **'Yes, use the new key'**
  String get l2SealedKeyAcceptAnswer;

  /// No description provided for @l2SealedKeyKept.
  ///
  /// In en, this message translates to:
  /// **'Nothing changed. Your messages keep your name until you accept the new key.'**
  String get l2SealedKeyKept;

  /// No description provided for @l2SealedKeyChangeAnswer.
  ///
  /// In en, this message translates to:
  /// **'Change my answer'**
  String get l2SealedKeyChangeAnswer;

  /// L2-3 sealed sender.
  ///
  /// In en, this message translates to:
  /// **'Accept only if the server\'s operator told you the key changed. A key made only for you would let the server tell your messages apart from everyone else\'s.'**
  String get l2SealedKeyAcceptWarning;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'The owners\' report keys changed. Review them.'**
  String get l2OwnerKeysReviewTile;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'The server\'s list of the owners\' report keys differs from the keys this app pinned. Until you accept a change, a message you send without your name is provable only to the owners pinned before.'**
  String get l2OwnerKeysReviewIntro;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'Owner {account} has a different report key.'**
  String l2OwnerKeyChanged(String account);

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'Owner {account} is new.'**
  String l2OwnerKeyAdded(String account);

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'Owner {account} is no longer listed.'**
  String l2OwnerKeyMissing(String account);

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get l2OwnerKeyAccept;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'No, keep it as it was'**
  String get l2OwnerKeyReject;

  /// No description provided for @l2OwnerKeyQuestion.
  ///
  /// In en, this message translates to:
  /// **'Did you expect this change?'**
  String get l2OwnerKeyQuestion;

  /// No description provided for @l2OwnerKeyAcceptAnswer.
  ///
  /// In en, this message translates to:
  /// **'Yes, accept it'**
  String get l2OwnerKeyAcceptAnswer;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'Accept only if you know the owners or their keys changed. Whoever holds this key can check who sent a message without your name if they are shown it. Reports never go to a key accepted here; reporting asks you to compare codes.'**
  String get l2OwnerKeyAcceptWarning;

  /// L2-3 sealed sender owner keys.
  ///
  /// In en, this message translates to:
  /// **'The list changed meanwhile. Look at it again.'**
  String get l2OwnerKeyStale;
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
      <String>['en', 'sr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'sr':
      {
        switch (locale.scriptCode) {
          case 'Latn':
            return AppLocalizationsSrLatn();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'sr':
      return AppLocalizationsSr();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
