// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Serbian (`sr`).
class AppLocalizationsSr extends AppLocalizations {
  AppLocalizationsSr([String locale = 'sr']) : super(locale);

  @override
  String get commonCancel => 'Откажи';

  @override
  String get commonContinue => 'Настави';

  @override
  String get commonCreate => 'Направи';

  @override
  String get commonRefresh => 'Освежи';

  @override
  String get commonRevoke => 'Опозови';

  @override
  String get listTimeYesterday => 'Јуче';

  @override
  String get validationNameRequired => 'Унесите назив.';

  @override
  String get validationNameTooLong => 'Тај назив је предугачак.';

  @override
  String get validationGroupNameRequired => 'Унесите назив групе.';

  @override
  String get validationGroupNameTooLong => 'Тај назив групе је предугачак.';

  @override
  String get validationMessageTooLong =>
      'Предугачко за слање. Скратите поруку или је поделите на више порука.';

  @override
  String get gatedAttachmentsUnavailable =>
      'Прилози захтевају механизам за шифровање који је прошао ревизију';

  @override
  String get confirmCancel => 'Откажи';

  @override
  String get appearanceSystem => 'Системски';

  @override
  String get appearanceLight => 'Светли';

  @override
  String get appearanceDark => 'Тамни';

  @override
  String aboutLegalese(String license, String url) {
    return 'Слободан софтвер под лиценцом GNU Affero General Public License, верзија 3 или новија ($license). Изворни код: $url';
  }

  @override
  String aboutTitle(String productName) {
    return 'О апликацији $productName';
  }

  @override
  String aboutVersion(String version, String license) {
    return 'Верзија $version · $license';
  }

  @override
  String get aboutLicenses => 'Лиценце отвореног кода';

  @override
  String get aboutLicensesDetail =>
      'Напомене о лиценцама за Veritra и њене компоненте';

  @override
  String get settingsTitle => 'Подешавања';

  @override
  String get settingsSectionAccount => 'Налог';

  @override
  String get settingsSectionDevices => 'Уређаји';

  @override
  String get settingsSectionSafety => 'Безбедност';

  @override
  String get settingsSectionYourData => 'Ваши подаци';

  @override
  String get settingsSectionNotifications => 'Обавештења';

  @override
  String get settingsSectionSession => 'Сесија';

  @override
  String get settingsSectionRecovery => 'Опоравак';

  @override
  String get settingsSectionComingSoon => 'Ускоро';

  @override
  String get settingsSectionAppearance => 'Изглед';

  @override
  String get settingsHideNotificationPreview => 'Сакриј преглед поруке';

  @override
  String get settingsHideNotificationPreviewDetail =>
      'Обавештења приказују „Нова порука“ без пошиљаоца и текста.';

  @override
  String get notificationNewMessage => 'Нова порука';

  @override
  String get trayOpen => 'Отвори';

  @override
  String get trayQuit => 'Затвори апликацију';

  @override
  String get settingsSectionPrivacy => 'Приватност';

  @override
  String get settingsReadReceiptsTitle => 'Потврде о читању';

  @override
  String get settingsReadReceiptsDetail =>
      'Важи за све ваше уређаје. Када је искључено, не шаљете потврде о читању и не видите када су други прочитали ваше поруке. Ознаке послато и достављено остају.';

  @override
  String get settingsReadReceiptsFailed =>
      'Подешавање није могло да се промени. Проверите везу и покушајте поново.';

  @override
  String get settingsReadReceiptsNotSaved =>
      'Овај уређај није могао да сачува подешавање. Важи за сада, али може да се врати када се апликација поново покрене.';

  @override
  String get settingsSectionAbout => 'О апликацији';

  @override
  String get settingsSectionDangerZone => 'Опасна зона';

  @override
  String get settingsAccountId => 'ИД налога';

  @override
  String get settingsAccountIdUnknown => 'Непознато';

  @override
  String get settingsCopyAccountId => 'Копирај ИД налога';

  @override
  String settingsCopied(String label) {
    return 'Копирано: $label.';
  }

  @override
  String get settingsChangePassword => 'Промени лозинку';

  @override
  String get settingsChangePasswordDetail =>
      'Завршава сесије на вашим другим уређајима';

  @override
  String get settingsInvites => 'Позивнице';

  @override
  String get settingsInvitesDetail =>
      'Направите кодове да би се други придружили';

  @override
  String get settingsLinkDevice => 'Повежи нови уређај';

  @override
  String get settingsLinkDeviceDetail =>
      'Генеришите код за упаривање за други уређај';

  @override
  String get settingsDeviceListSetup => 'Одобрите своје уређаје';

  @override
  String get settingsDeviceListSetupDetail =>
      'Ваши контакти не могу да додају ваше уређаје у ћаскања док не потврдите који су ваши.';

  @override
  String get settingsRecoveryRetype =>
      'Поново унесите кључ за опоравак да бисте довршили опоравак';

  @override
  String get settingsRecoveryRetypeDetail =>
      'Ваши контакти не могу да додају овај уређај у ћаскања док то не урадите.';

  @override
  String get settingsRecoveryConfirm =>
      'Потврдите кључ за опоравак да би опоравак и даље радио';

  @override
  String get settingsRecoveryConfirmDetail =>
      'Ваш кључ за опоравак је постављен пре листа одобрених уређаја. Унесите га једном, иначе ће опоравак налога њиме бити одбијен.';

  @override
  String get deviceListReviewTitle => 'Који уређаји су ваши?';

  @override
  String get deviceListReviewBody =>
      'Уклоните ознаку са сваког уређаја који не препознајете. Означени постају ваши одобрени уређаји, а остали се одјављују.';

  @override
  String get deviceListReviewConfirm => 'Одобри';

  @override
  String get settingsLoadingDevices => 'Учитавање уређаја…';

  @override
  String get settingsBlockedAccounts => 'Блокирани налози';

  @override
  String get settingsBlockedNone => 'Нико није блокиран';

  @override
  String settingsBlockedCount(int count) {
    return 'Блокирано: $count';
  }

  @override
  String get settingsBlockedReview => 'Прегледајте и поништите блокирања';

  @override
  String get settingsExport => 'Извези податке налога';

  @override
  String get settingsExportDetail =>
      'Сачувајте шифроване поруке и метаподатке налога локално';

  @override
  String get settingsExportFailed => 'Извоз налога није успео.';

  @override
  String get settingsExportSaved => 'Извоз налога је сачуван локално.';

  @override
  String get settingsAllowNotifications => 'Дозволи обавештења';

  @override
  String get settingsAllowNotificationsDetail =>
      'Обавештења кажу само да је стигла порука.';

  @override
  String get settingsPushProvider => 'Push добављач';

  @override
  String get settingsPushProviderDetail =>
      'Изаберите UnifiedPush добављача за Android';

  @override
  String get settingsTestPush => 'Пошаљи пробно обавештење';

  @override
  String get settingsTestPushUnavailable =>
      'Доступно када се овај уређај региструје';

  @override
  String settingsTestPushRegistered(String provider) {
    return 'Регистровано: $provider';
  }

  @override
  String get settingsSignOut => 'Одјави се';

  @override
  String get settingsSignOutOthers => 'Одјави друге уређаје';

  @override
  String get settingsSignOutOthersDetail => 'Завршава све сесије осим ове';

  @override
  String get settingsBackup => 'Шифрована резервна копија';

  @override
  String get settingsBackupDetail => 'Резервна копија и код за опоравак';

  @override
  String get settingsRecoveryComingSoon => 'Опоравак';

  @override
  String get settingsRecoveryComingSoonDetail =>
      'Шифрована резервна копија и кључ за опоравак';

  @override
  String get settingsCallsComingSoon => 'Позиви';

  @override
  String get settingsCallsComingSoonDetail => 'Аудио и видео позиви 1:1';

  @override
  String get settingsDeleteAccount => 'Избриши налог';

  @override
  String get settingsDeleteAccountDetail =>
      'Онемогућава пријављивање и опозива ваше уређаје. Неки шифровани записи могу остати у складу са правилима чувања на серверу.';

  @override
  String get settingsSignedIn => 'Пријављени сте';

  @override
  String get settingsRevokeDeviceTitle => 'Опозвати уређај?';

  @override
  String settingsRevokeDeviceMessage(String deviceName) {
    return '„$deviceName“ ће одмах изгубити приступ.';
  }

  @override
  String get settingsSignOutTitle => 'Одјавити се?';

  @override
  String get settingsSignOutMessage =>
      'Овај уређај престаје да прима поруке док се поново не пријавите лозинком.';

  @override
  String get settingsSignOutOthersTitle => 'Одјавити друге уређаје?';

  @override
  String get settingsSignOutOthersMessage =>
      'Све сесије осим ове биће завршене.';

  @override
  String get settingsSignOutOthersConfirm => 'Одјави остале';

  @override
  String get settingsDeleteAccountTitle => 'Избрисати налог?';

  @override
  String get settingsDeleteAccountMessage =>
      'Ово онемогућава ваш налог, завршава његове сесије и опозива његове уређаје. Шифроване поруке и други записи могу остати у складу са правилима сервера о чувању података.';

  @override
  String get settingsDeleteAccountConfirm => 'Онемогући налог';

  @override
  String get settingsReauthTitle => 'Потврдите лозинку';

  @override
  String get settingsReauthField => 'Тренутна лозинка';

  @override
  String get settingsNewPassword => 'Нова лозинка';

  @override
  String get settingsNewPasswordHelper => 'Најмање 12 знакова.';

  @override
  String get settingsConfirmNewPassword => 'Потврдите нову лозинку';

  @override
  String get settingsPasswordsMismatch => 'Лозинке се не подударају.';

  @override
  String get settingsChangePasswordConfirm => 'Промени';

  @override
  String get settingsPasswordChanged =>
      'Лозинка је промењена. Ваши други уређаји су одјављени.';

  @override
  String get settingsPasswordRequired => 'Унесите нову лозинку.';

  @override
  String get settingsPasswordTooShort => 'Користите најмање 12 знакова.';

  @override
  String get settingsPasswordTooLong =>
      'Та лозинка је предугачка. Користите краћу.';

  @override
  String get settingsPushDesktopTitle =>
      'Обавештења на рачунару још нису доступна';

  @override
  String get settingsPushDesktopDetail =>
      'Поруке стижу док апликација ради, чак и у позадини.';

  @override
  String get settingsPushServerDisabledTitle =>
      'Овај сервер нема push добављача';

  @override
  String get settingsPushServerDisabledDetail =>
      'Оператер сервера није подесио push обавештења. Поруке стижу док је апликација отворена.';

  @override
  String get settingsPushRegisteringTitle => 'Подешавање push обавештења';

  @override
  String get settingsPushRegisteringDetail =>
      'Чека се да се овај уређај региструје.';

  @override
  String get settingsPushNoDistributorTitle =>
      'Није регистрован ниједан push дистрибутер';

  @override
  String get settingsPushNoDistributorDetail =>
      'Инсталирајте UnifiedPush дистрибутер и изаберите га испод, иначе ће поруке стизати само док је апликација отворена.';

  @override
  String get settingsPushFailedTitle => 'Регистрација за push није успела';

  @override
  String get settingsPushFailedDetail =>
      'Овај уређај није успео да се региструје за push обавештења. Покушаће поново при следећем покретању апликације.';

  @override
  String get settingsPushDeniedTitle => 'Обавештења су искључена';

  @override
  String get settingsPushDeniedDetail =>
      'Апликација се и даље синхронизује када се пробуди, али ништа не приказује. Дозволите обавештења за Veritra у системским подешавањима.';

  @override
  String get settingsPushNotAllowedTitle => 'Обавештења још нису дозвољена';

  @override
  String get settingsPushNotAllowedDetail =>
      'Дозволите обавештења испод да бисте били обавештавани. До тада се апликација синхронизује када се пробуди, али ништа не приказује.';

  @override
  String get settingsPushUnconfirmedTitle => 'Обавештења се не могу потврдити';

  @override
  String get settingsPushUnconfirmedDetail =>
      'Овај уређај није потврдио да су обавештења дозвољена, па можда ништа неће бити приказано. Проверите системска подешавања за Veritra.';

  @override
  String get settingsPushActiveTitle => 'Push обавештења су активна';

  @override
  String get settingsPushActiveDetail =>
      'Обавештења никада не садрже текст поруке нити имена пошиљалаца.';

  @override
  String settingsDeviceLastSeen(String time) {
    return 'Последња активност: $time';
  }

  @override
  String settingsDeviceAdded(String date) {
    return 'Додат $date';
  }

  @override
  String get settingsDeviceRevoked => 'Опозван';

  @override
  String get settingsDeviceCurrent => 'Овај уређај';

  @override
  String get backupReplaceTitle => 'Заменити резервну копију?';

  @override
  String get backupReplaceMessage =>
      'Претходна резервна копија и њен код за опоравак престаће да раде. Нови код чувајте на безбедном месту.';

  @override
  String get backupReplaceConfirm => 'Замени резервну копију';

  @override
  String get inviteRevokeTitle => 'Опозвати позивницу?';

  @override
  String inviteRevokeMessage(String code) {
    return 'Код $code одмах престаје да ради. Особе које су се већ придружиле помоћу њега задржавају своје налоге.';
  }

  @override
  String get connectFreshInstanceTitle => 'Откривена је нова инстанца';

  @override
  String get connectFreshInstanceMessage =>
      'Налог власника још не постоји — направите га испод.';

  @override
  String get connectInstanceUrl => 'URL инстанце';

  @override
  String get connectCheckApproval => 'Провери одобрење';

  @override
  String get connectLinkInstead => 'Уместо тога повежи овај уређај';

  @override
  String get connectOtherWays => 'Други начини повезивања';

  @override
  String get connectRestoreBackup => 'Врати из резервне копије';

  @override
  String get connectLinkCode => 'Код за повезивање';

  @override
  String get connectLinkCodeRequired =>
      'Унесите код за повезивање са постојећег уређаја.';

  @override
  String get connectLinkCodeHint => 'Из Подешавања → Повежи нови уређај';

  @override
  String get connectScanQr => 'Скенирај QR код';

  @override
  String get connectVerificationTitle => 'Верификациони код';

  @override
  String get connectVerificationMessage =>
      'Потврдите овај код на свом већ повезаном уређају, а затим проверите одобрење испод.';

  @override
  String get connectInviteCode => 'Код позивнице';

  @override
  String get connectInviteCodeRequired =>
      'Унесите код позивнице који сте добили.';

  @override
  String get connectInviteCodeHint => 'Од администратора ове инстанце';

  @override
  String get connectUsername => 'Корисничко име';

  @override
  String get connectUsernameRequired => 'Унесите корисничко име.';

  @override
  String get connectUsernameHint => 'Ваше име на овој инстанци';

  @override
  String get connectPassword => 'Лозинка';

  @override
  String get connectPasswordHint => 'Најмање 12 знакова';

  @override
  String get connectHidePassword => 'Сакриј лозинку';

  @override
  String get connectShowPassword => 'Прикажи лозинку';

  @override
  String get connectConfirmPassword => 'Потврдите лозинку';

  @override
  String get connectConfirmPasswordHint => 'Поновите лозинку';

  @override
  String get connectSetupToken => 'Токен за подешавање';

  @override
  String get connectSetupTokenHint =>
      'Обавезан, осим при повезивању преко loopback адресе';

  @override
  String get connectUrlRequired => 'Унесите URL инстанце.';

  @override
  String get connectUrlInvalid =>
      'Унесите пун URL, нпр. https://chat.example.org';

  @override
  String get connectUrlOriginOnly =>
      'Унесите само основну адресу сервера (origin), нпр. https://chat.example.org';

  @override
  String get connectUrlHttpsRequired =>
      'Veritra захтева HTTPS. Користите https:// адресу сервера.';

  @override
  String get connectUrlLoopbackOnly =>
      'Користите https://, или http:// само за овај рачунар (localhost или 127.0.0.1).';

  @override
  String get connectPasswordRequired => 'Унесите лозинку.';

  @override
  String get connectModeOwnerTitle => 'Направите налог власника';

  @override
  String get connectModeSignInTitle => 'Пријава';

  @override
  String get connectModeJoinTitle => 'Придружите се уз позивницу';

  @override
  String get connectModeLinkTitle => 'Повежите овај уређај';

  @override
  String get connectModeOwnerDetail =>
      'Само при првом покретању: направите налог власника на новој инстанци коју сами хостујете.';

  @override
  String get connectModeSignInDetail =>
      'Пријавите се лозинком на уређају који је већ повезан са вашим налогом.';

  @override
  String get connectModeJoinDetail =>
      'Регистрација је могућа само уз позивницу. Унесите код позивнице који сте добили од администратора.';

  @override
  String get connectModeLinkDetail =>
      'Унесите код за повезивање генерисан на постојећем уређају (Подешавања → Повежи нови уређај).';

  @override
  String get connectNotDeviceLinkQr =>
      'То није Veritra QR код за повезивање уређаја.';

  @override
  String get connectOriginFilled =>
      'Адреса сервера је попуњена. Проверите је пре него што наставите.';

  @override
  String get connectConfirmServerTitle => 'Потврдите сервер';

  @override
  String connectConfirmServerMessage(String origin) {
    return 'Овај QR код предлаже $origin. Апликација ће ипак проверити сервер пре него што га употреби. Наставити са овом HTTPS адресом?';
  }

  @override
  String get connectUseOrigin => 'Користи адресу';

  @override
  String get connectSubmitOwner => 'Направи власника';

  @override
  String get connectSubmitSignIn => 'Пријави се';

  @override
  String get connectSubmitJoin => 'Придружи се уз позивницу';

  @override
  String get connectSubmitLink => 'Искористи код';

  @override
  String get connectTagline =>
      'Самостално хостована размена порука, шифрована с краја на крај';

  @override
  String get qrScanLinkTitle => 'Скенирај QR код за повезивање';

  @override
  String get qrToggleTorch => 'Укључи или искључи лампу';

  @override
  String get qrSwitchCamera => 'Промени камеру';

  @override
  String get qrPointCamera =>
      'Усмерите камеру ка QR коду на постојећем уређају (Подешавања → Повежи нови уређај).';

  @override
  String get qrPermissionDenied =>
      'За скенирање је потребна дозвола за камеру. Омогућите је у системским подешавањима или ручно унесите код за повезивање.';

  @override
  String get qrUnsupported =>
      'Овај уређај не може да скенира QR кодове. Ручно унесите код за повезивање.';

  @override
  String get qrCameraFailed =>
      'Камера није могла да се покрене. Ручно унесите код за повезивање.';

  @override
  String get qrEnterManually => 'Унеси код ручно';

  @override
  String get newConversationTitle => 'Нови разговор';

  @override
  String get newConversationDirect => 'Директна порука';

  @override
  String get newConversationGroup => 'Група';

  @override
  String get newConversationGroupName => 'Назив групе';

  @override
  String get newConversationWho => 'Коме желите да пишете?';

  @override
  String get newConversationAddMembers => 'Додај чланове';

  @override
  String get newConversationStartDm => 'Започни разговор';

  @override
  String get newConversationCreateGroup => 'Направи групу';

  @override
  String get newConversationPickPerson => 'Прво изаберите особу којој пишете.';

  @override
  String get newConversationAddOneMember => 'Додајте бар још једног члана.';

  @override
  String get blockedEmptyTitle => 'Нема блокираних налога';

  @override
  String get blockedEmptyMessage =>
      'Блокирајте налог из директне поруке да би сервер престао да вам доставља поруке тог налога.';

  @override
  String get blockedLabel => 'Блокиран';

  @override
  String blockedOn(String date) {
    return 'Блокиран $date';
  }

  @override
  String get blockedUnblock => 'Деблокирај';

  @override
  String blockedUnblocked(String label) {
    return 'Налог $label је деблокиран.';
  }

  @override
  String blockedUnblockFailed(String label) {
    return 'Деблокирање налога $label није успело.';
  }

  @override
  String get blockedLoadFailed => 'Учитавање блокираних налога није успело';

  @override
  String get commonRetry => 'Покушај поново';

  @override
  String get accountPickerHelper =>
      'Унесите тачно корисничко име или налепите ИД налога (acct_…).';

  @override
  String get accountPickerNoMatch =>
      'Није пронађен налог са тачно тим корисничким именом.';

  @override
  String get searchHint => 'Претражите особе, заједнице, канале…';

  @override
  String get searchClear => 'Обриши претрагу';

  @override
  String get searchIntroTitle => 'Претрага метаподатака';

  @override
  String get searchIntroMessage =>
      'Пронађите особе по тачном корисничком имену, као и заједнице и канале по називу. Садржај порука је шифрован с краја на крај и на серверу се никада не може претраживати.';

  @override
  String get searchNoResultsTitle => 'Нема резултата';

  @override
  String get searchNoResultsMessage =>
      'Ништа се не подудара. Корисничка имена морају се тачно подударати, а садржај порука се никада не може претраживати.';

  @override
  String get searchNoOpenChannel => 'Још нема канала који можете да отворите';

  @override
  String get searchJoinCommunity =>
      'Придружите се заједници да бисте је отворили';

  @override
  String get searchTypeConversation => 'Разговор';

  @override
  String get searchTypeCommunity => 'Заједница';

  @override
  String get searchTypeChannel => 'Канал';

  @override
  String get searchTypeAccount => 'Налог';

  @override
  String searchUnblockAccount(String label) {
    return 'Деблокирај $label';
  }

  @override
  String searchBlockAccount(String label) {
    return 'Блокирај $label';
  }

  @override
  String searchBlocked(String label) {
    return 'Налог $label је блокиран.';
  }

  @override
  String get searchBlockFailed => 'Блокирање није могло да се ажурира.';

  @override
  String get inviteCreateSection => 'Направите позивницу';

  @override
  String get inviteMaxUses => 'Највише коришћења';

  @override
  String inviteMaxUsesOption(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get inviteExpires => 'Истиче';

  @override
  String durationDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString дана',
      few: '$countString дана',
      one: '$countString дан',
    );
    return '$_temp0';
  }

  @override
  String get inviteCreate => 'Направи позивницу';

  @override
  String get inviteEmptyTitle => 'Још нема позивница';

  @override
  String get inviteEmptyMessage =>
      'Кодови позивница које направите појављују се овде. Делите их преко безбедног канала.';

  @override
  String get inviteLoadFailed =>
      'Ваше позивнице нису могле да се учитају. Проверите везу и покушајте поново.';

  @override
  String get inviteYourInvites => 'Ваше позивнице';

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

    return 'Искоришћено $usesString од $maxUsesString';
  }

  @override
  String get inviteNeverExpires => 'Никада не истиче';

  @override
  String inviteExpiresAt(String time) {
    return 'Истиче $time';
  }

  @override
  String get inviteActions => 'Радње за позивницу';

  @override
  String get inviteCodeCopied => 'Код позивнице је копиран.';

  @override
  String get inviteCopyCode => 'Копирај код';

  @override
  String get profileThisInstance => 'ова инстанца';

  @override
  String get profileTitle => 'Профил';

  @override
  String get profileYourAccount => 'Ваш налог';

  @override
  String get profileDisplaySection => 'Приказно име и слика';

  @override
  String get profileDisplayNameLabel => 'Приказно име';

  @override
  String get profileDisplayNameHint =>
      'Како вас виде људи са којима разговарате';

  @override
  String get profileDisplayHelp =>
      'Име и слику виде само људи са којима делите разговор. Сервер их не може прочитати.';

  @override
  String get profileEditTile => 'Име и слика';

  @override
  String get profileEditTitle => 'Име и слика';

  @override
  String get profilePhotoChoose => 'Изабери слику';

  @override
  String get profilePhotoRemove => 'Уклони слику';

  @override
  String get profilePhotoUnusable =>
      'Ова слика се не може користити. Пробајте другу.';

  @override
  String get profileSave => 'Сачувај';

  @override
  String get profileSaved => 'Сачувано';

  @override
  String get profileSaveConflict =>
      'Овај профил је промењен на другом уређају. Покушајте поново за тренутак.';

  @override
  String get profileSaveInvalid => 'То име или слика се не могу користити.';

  @override
  String profileNameTooLong(int max) {
    return 'Највише $max знакова.';
  }

  @override
  String get profileNameInvalid =>
      'Користите слова и бројеве; без контролних знакова и знакова смера.';

  @override
  String get groupProfileTitle => 'Име и слика групе';

  @override
  String get groupProfileNameLabel => 'Име групе';

  @override
  String get groupProfileHelp =>
      'Чланови ове групе виде њено име и слику. Сервер их не може прочитати.';

  @override
  String get profileBlockNote =>
      'У групама које делите, можда и даље виде ваш профил.';

  @override
  String get profileSectionIdentity => 'Идентитет';

  @override
  String get profileNotAvailable => 'Није доступно';

  @override
  String get profileCurrentDevice => 'Тренутни уређај';

  @override
  String get profileInstanceRole => 'Улога на инстанци';

  @override
  String get profileSectionEncryption => 'Шифровање';

  @override
  String get profileEncryptionPending =>
      'Идентитет за шифровање још није спреман';

  @override
  String get profileEncryptionPendingDetail =>
      'Провера безбедносног броја и измена профила остају недоступне док не буде објављен механизам за шифровање који је прошао ревизију.';

  @override
  String profileCopyLabel(String label) {
    return 'Копирај: $label';
  }

  @override
  String get navChats => 'Ћаскања';

  @override
  String get navCommunities => 'Заједнице';

  @override
  String get shellNoConversationTitle => 'Није изабран ниједан разговор';

  @override
  String get shellNoConversationMessage =>
      'Изаберите разговор са листе да бисте га читали овде.';

  @override
  String get shellRestoring => 'Враћање овог уређаја…';

  @override
  String get shellResetTitle => 'Ресетовати овај уређај?';

  @override
  String get shellResetMessage =>
      'Овај уређај ће бити празан и мора поново да се повеже. Његове тренутне поруке овде остају нечитљиве; склањају се у страну, а не бришу, за случај да се кључ врати.';

  @override
  String get shellResetConfirm => 'Ресетуј';

  @override
  String get shellRecoveryTitle => 'Потребан је опоравак уређаја';

  @override
  String get shellRecoveryFallback =>
      'Овом уређају је потребна пажња пре него што може да се користи.';

  @override
  String get shellRetryRestore => 'Поново покушај враћање';

  @override
  String get shellContinueToSignIn => 'Настави на пријаву';

  @override
  String get shellResetDevice => 'Ресетуј овај уређај';

  @override
  String get communityNew => 'Нова заједница';

  @override
  String get communityEmptyTitle => 'Још нема заједница';

  @override
  String get communityEmptyMessage =>
      'Направите заједницу да окупите људе око заједничких канала — подразумевано приватно, свуда шифровано.';

  @override
  String get communityOtherChannels => 'Други канали у којима сте';

  @override
  String get communityChannelSubtitle => 'Канал заједнице';

  @override
  String get communityName => 'Назив заједнице';

  @override
  String communityNewChannelIn(String community) {
    return 'Нови канал у заједници $community';
  }

  @override
  String get communityChannelName => 'Назив канала';

  @override
  String get communityNoChannels => 'Још нема канала';

  @override
  String communityChannelCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString канала',
      few: '$countString канала',
      one: '$countString канал',
    );
    return '$_temp0';
  }

  @override
  String get communityNewChannel => 'Нови канал';

  @override
  String get communityNoChannelsHint => 'Користите + да направите први.';

  @override
  String get communityPlaceholderName => 'Заједница';

  @override
  String get channelPlaceholderName => 'Канал';

  @override
  String get channelPrivatePlaceholderName => 'Приватни канал';

  @override
  String get communityInfoEditFailed =>
      'Није могуће сачувати податке. Покушајте поново.';

  @override
  String get communityEditInfo => 'Уреди заједницу';

  @override
  String get channelEditInfo => 'Уреди канал';

  @override
  String get channelTopic => 'Тема';

  @override
  String get channelEditFailed => 'Канал није сачуван. Покушајте поново.';

  @override
  String get channelSave => 'Сачувај';

  @override
  String get communityNotMember => 'Још нисте члан';

  @override
  String get backupIntro =>
      'Резервна копија садржи кључеве и историју порука овог уређаја, шифроване на овом уређају. Сервер је чува, али не може да је прочита. За враћање на новом уређају потребан је код за опоравак који се приказује када је направите.';

  @override
  String get backupSectionStatus => 'Статус';

  @override
  String get backupNone => 'Још нема резервне копије са овог уређаја';

  @override
  String backupLast(String time) {
    return 'Последња резервна копија: $time';
  }

  @override
  String get backupReplacesPrevious =>
      'Нова резервна копија замењује претходну и њен код.';

  @override
  String get backupMake => 'Направи резервну копију';

  @override
  String get backupMakeNew => 'Направи нову резервну копију';

  @override
  String get backupSaveCodeTitle => 'Сачувајте код за опоравак';

  @override
  String get backupSaveCodeMessage =>
      'Свако ко има овај код може да врати ваше поруке. Чувајте га на безбедном месту, ван мреже. Приказује се само сада и престаје да ради када се искористи или када направите нову резервну копију.';

  @override
  String get commonCopy => 'Копирај';

  @override
  String get backupSavedIt => 'Код је сачуван';

  @override
  String get backupRestoreMessage =>
      'Ваше поруке и подешавања враћају се на овај уређај. Резервна копија не садржи пријаву, па се овај уређај затим придружује вашем налогу као нови уређај.';

  @override
  String get backupRecoveryCode => 'Код за опоравак';

  @override
  String get backupRestore => 'Врати';

  @override
  String get deviceLinkTitle => 'Повежи уређај';

  @override
  String get deviceLinkIntro =>
      'Генеришите једнократни код, унесите га на новом уређају, а затим га овде одобрите помоћу верификационог кода који приказује нови уређај. Ваша историја разговора се затим шифрована копира на нови уређај, па оба уређаја држите на мрежи.';

  @override
  String get deviceLinkCreate => 'Направи везу';

  @override
  String get deviceLinkCreateNew => 'Направи нову везу';

  @override
  String get deviceLinkQrSemantics =>
      'QR код са везом за повезивање уређаја. Скенирајте га новим уређајем.';

  @override
  String get deviceLinkQrHint =>
      'Скенирајте га апликацијом Veritra на новом уређају или унесите код за повезивање испод.';

  @override
  String get deviceLinkStatusLabel => 'СТАТУС';

  @override
  String deviceLinkState(String state) {
    String _temp0 = intl.Intl.selectLogic(
      state,
      {
        'pending': 'на чекању',
        'claimed': 'преузето',
        'approved': 'одобрено',
        'expired': 'истекло',
        'other': '$state',
      },
    );
    return '$_temp0';
  }

  @override
  String get deviceLinkClaimedBy => 'Преузео уређај';

  @override
  String get deviceLinkRefreshStatus => 'Освежи статус';

  @override
  String get deviceLinkApproveDevice => 'Одобри уређај';

  @override
  String get deviceLinkApprove => 'Одобри';

  @override
  String get deviceLinkApproveHint =>
      'Унесите осмоцифрени код приказан на новом уређају. Никада не користите код који вам је неко послао или прочитао.';

  @override
  String get deviceLinkUnavailableHere =>
      'Повезивање уређаја није доступно у овој верзији.';

  @override
  String get deviceLinkAlreadyPending =>
      'На овом уређају већ чека веза уређаја. Прво је проверите или откажите.';

  @override
  String get deviceLinkRecoveryInProgress =>
      'На овом уређају чека опоравак налога, па се уређај не може повезати овде док се не заврши или откаже.';

  @override
  String get deviceLinkEnded =>
      'Ова веза је отказана или је истекла. Затражите нову са свог другог уређаја.';

  @override
  String get deviceLinkApprovalInvalid =>
      'То одобрење није могло да се провери, па уређај није повезан. Направите нову везу на свом другом уређају и покушајте поново.';

  @override
  String get deviceLinkCodeMismatch =>
      'Тај код се не поклапа са оним на новом уређају. Проверите га и покушајте поново.';

  @override
  String get deviceLinkRefreshFirst =>
      'Прво освежите статус, а затим одобрите уређај.';

  @override
  String get deviceLinkCancelWaiting => 'Откажи ову везу';

  @override
  String get deviceLinkWaitingApproval =>
      'Чека се да ваш други уређај одобри. Оставите овај екран отворен.';

  @override
  String get deviceLinkWaitingCode =>
      'Чека се ваш други уређај. Код за потврду ће се ускоро појавити овде.';

  @override
  String get deviceLinkCommitmentMismatch =>
      'Провера везе са вашег другог уређаја се није поклопила, па уређај није повезан. Направите нову везу на свом другом уређају и покушајте поново.';

  @override
  String get historyCopySendWorking => 'Шаљем вашу историју на нови уређај…';

  @override
  String get historyCopySendWaiting =>
      'Ваша историја је спремна. Чека се да је нови уређај прими.';

  @override
  String get historyCopyReceiveWorking =>
      'Примам вашу историју са другог уређаја…';

  @override
  String get historyCopyReceiveWaiting =>
      'Чека се да ваш други уређај пошаље историју. Оставите га на мрежи.';

  @override
  String get historyCopyFailed =>
      'Копирање ваше историје није завршено. Покушаће се поново.';

  @override
  String get historyCopyEnded =>
      'Копирање ваше историје је заустављено. Поново повежите уређај да бисте је копирали.';

  @override
  String get bannerQueued =>
      'Поруке које шаљете остају у реду чекања на овом уређају.';

  @override
  String get bannerReconnecting => 'Поновно повезивање са сервером…';

  @override
  String bannerLastSynced(String time) {
    return 'Последња синхронизација: $time.';
  }

  @override
  String bannerOfflineSemantics(String detail) {
    return 'Ван мреже. $detail';
  }

  @override
  String bannerConnectingSemantics(String detail) {
    return 'Повезивање са сервером. $detail';
  }

  @override
  String get bannerOffline => 'Ван мреже';

  @override
  String get bannerConnecting => 'Повезивање…';

  @override
  String get bannerPaused => 'Поруке су паузиране';

  @override
  String get bannerTryAgain => 'Покушај поново';

  @override
  String get bannerRelink => 'Поново повежи овај уређај';

  @override
  String get bannerRestoreBackup => 'Врати из резервне копије';

  @override
  String get bannerRelinkTitle => 'Поново повезати овај уређај?';

  @override
  String get bannerRelinkMessage =>
      'Ово одјављује овај уређај и брише његове поруке и кључеве за шифровање. После тога га поново повежите са другог уређаја. Поруке које постоје само на овом уређају не могу се повратити.';

  @override
  String get bannerRelinkConfirm => 'Избриши и одјави';

  @override
  String get attachmentPickUnavailable =>
      'На овом уређају није могуће бирати датотеке.';

  @override
  String get attachmentSendTitle => 'Послати ову датотеку?';

  @override
  String attachmentSendMessage(String name, String size) {
    return 'Датотека $name ($size) се шифрује на овом уређају пре отпремања. Сви у овом разговору могу да је отворе.';
  }

  @override
  String get attachmentSend => 'Пошаљи';

  @override
  String get attachmentSendFailed => 'Датотека није могла да се пошаље.';

  @override
  String get attachmentDemoImagesOnly =>
      'У демо верзији на овом уређају могу да се отварају само слике.';

  @override
  String attachmentSaved(String fileName) {
    return 'Сачувано: $fileName.';
  }

  @override
  String get attachmentDownloadFailed =>
      'Датотека није могла да се преузме или дешифрује.';

  @override
  String attachmentImageSemantics(String fileName, String size) {
    return 'Слика $fileName, $size';
  }

  @override
  String attachmentFileSemantics(String fileName, String size) {
    return 'Датотека $fileName, $size';
  }

  @override
  String get attachmentSave => 'Сачувај';

  @override
  String get attachmentImageFailed =>
      'Слика није могла да се преузме или дешифрује.';

  @override
  String get attachmentImageUnshowable => 'Ова слика не може да се прикаже.';

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
  String get chatListSearch => 'Претрага';

  @override
  String get chatListNewChat => 'Ново ћаскање';

  @override
  String get chatListEmptyTitle => 'Још нема разговора';

  @override
  String get chatListEmptyMessage =>
      'Започните директну поруку или направите групу. Све је шифровано с краја на крај.';

  @override
  String get chatListUnmute => 'Укључи обавештења';

  @override
  String get chatListMute => 'Искључи обавештења';

  @override
  String get chatListDetails => 'Детаљи разговора';

  @override
  String get chatListMuted => 'Утишано';

  @override
  String chatListDisappearingAfter(String duration) {
    return 'Нестајуће поруке: $duration';
  }

  @override
  String chatListUnreadSpoken(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString непрочитаних порука',
      few: '$countString непрочитане поруке',
      one: '$countString непрочитана порука',
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
  String get conversationGroupChat => 'Групно ћаскање';

  @override
  String get conversationPrivateGroup => 'Приватна група';

  @override
  String get conversationEncrypted => 'Шифровано';

  @override
  String conversationDisappearing(String duration) {
    return 'Нестајуће ($duration)';
  }

  @override
  String durationHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString сати',
      few: '$countString сата',
      one: '$countString сат',
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
      other: '$countString минута',
      few: '$countString минута',
      one: '$countString минут',
    );
    return '$_temp0';
  }

  @override
  String durationChipDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString д';
  }

  @override
  String durationChipHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString ч';
  }

  @override
  String durationChipMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString мин';
  }

  @override
  String get safetyMarkTitle => 'Означити као верификовано?';

  @override
  String get safetyMarkMessage =>
      'Урадите ово само након што сте број упоредили са другом особом уживо или у позиву у који имате поверења. Обоје морате да видите потпуно истих шездесет цифара.';

  @override
  String get safetyTheyMatch => 'Подударају се';

  @override
  String get safetySaveFailed =>
      'Верификација није могла да се сачува. Покушајте поново.';

  @override
  String get safetyScanTitle => 'Скенирај безбедносни код';

  @override
  String get safetyReadFailed =>
      'Безбедносни број није могао да се прочита. Покушајте поново.';

  @override
  String get safetyMismatchTitle => 'Кодови се не подударају';

  @override
  String get safetyMismatchMessage =>
      'Ово није исти безбедносни код. Проверите да ли сте скенирали код за овај разговор и да ли су оба уређаја примила најновије поруке, па покушајте поново. Ако се и даље не подудара, не сматрајте овај разговор верификованим.';

  @override
  String get commonOk => 'У реду';

  @override
  String get safetyCodesMatch => 'Кодови се подударају.';

  @override
  String get safetyCodesMatchVerified =>
      'Кодови се подударају. Означено као верификовано.';

  @override
  String get safetyTitle => 'Безбедносни број';

  @override
  String get safetyGroupIntro =>
      'Сваки члан ове групе види исти број. Упоредите га уживо или међусобно скенирајте кодове.';

  @override
  String safetyPeerIntro(String peer) {
    return 'Упоредите овај број са корисником $peer уживо или међусобно скенирајте кодове.';
  }

  @override
  String get safetyUnavailable => 'Безбедносни број није доступан';

  @override
  String get safetyUnavailableDetail =>
      'Овај уређај се још није придружио шифрованој групи или стање његове групе није могло да се прочита.';

  @override
  String safetyDigitsSemantics(String groups) {
    return 'Безбедносни број, дванаест група од по пет цифара: $groups';
  }

  @override
  String get safetyQrSemantics =>
      'QR код овог безбедносног броја. Друга особа може да га скенира ради поређења.';

  @override
  String get safetyVerifiedDetail => 'Верификовали сте овај број.';

  @override
  String get safetyChangedDetail =>
      'Откако сте верификовали, у овом разговору је неки уређај додат, уклоњен или замењен. Поново упоредите нови број.';

  @override
  String get safetyChangedWhileComparing =>
      'Безбедносни број се променио док сте га упоређивали, па ништа није сачувано. Поново упоредите нови број.';

  @override
  String get safetyUnverifiedDetail => 'Још није верификовано.';

  @override
  String get safetyVerified => 'Верификовано';

  @override
  String get safetyChanged => 'Промењено';

  @override
  String get safetyUnverified => 'Није верификовано';

  @override
  String get safetyScanTheirCode => 'Скенирај код друге особе';

  @override
  String get safetyMarkVerified => 'Означи као верификовано';

  @override
  String get detailsNotFound => 'Разговор није пронађен.';

  @override
  String get detailsConversationIdLabel => 'ИД РАЗГОВОРА';

  @override
  String get detailsCopyId => 'Копирај ИД';

  @override
  String get detailsConversationId => 'ИД разговора';

  @override
  String get detailsCreatedLabel => 'НАПРАВЉЕН';

  @override
  String get detailsMuteDetail =>
      'Зауставља push обавештења за овај разговор. Поруке и даље стижу и рачунају се као непрочитане.';

  @override
  String get detailsSectionMembers => 'Чланови';

  @override
  String get detailsLoadingMembers => 'Учитавање чланова…';

  @override
  String get detailsMembersUnavailable => 'Списак чланова није доступан';

  @override
  String get detailsMembersUnavailableDetail =>
      'Сервер није вратио списак чланова за овај разговор.';

  @override
  String get detailsAddMember => 'Додај члана';

  @override
  String get detailsAddMemberDetail => 'Пронађите налог по корисничком имену';

  @override
  String get detailsAddMemberNoPermission => 'Потребна је дозвола модератора';

  @override
  String get detailsMembershipNote =>
      'Ово је евиденција чланства на серверу. Шифрована достава прати засебно ажурирање групе, па промена овде сама по себи није доказ о томе ко може да дешифрује нове поруке.';

  @override
  String get detailsSafetyDetail =>
      'Упоредите га са другим члановима да бисте проверили да нико не пресреће овај разговор.';

  @override
  String get detailsLeaveDm => 'Напусти овај разговор';

  @override
  String get detailsLeave => 'Напусти разговор';

  @override
  String get detailsLeaveDetail =>
      'Престајете да примате нове поруке. Поруке које су већ на уређајима других чланова се не бришу.';

  @override
  String get detailsSectionDisappearing => 'Нестајуће поруке';

  @override
  String get detailsDisappearingNote =>
      'Када је ово подешено, поруке послате од тада бришу се са сервера након овог временског периода. Постојеће поруке задржавају тајмер са којим су послате.';

  @override
  String get detailsRetentionOff => 'Искључено';

  @override
  String detailsRemoveTitle(String label) {
    return 'Уклонити $label?';
  }

  @override
  String get detailsRemoveMessage =>
      'Тај налог престаје да прима нове поруке у овом разговору. Поруке које је већ примио остају на његовом уређају, а шифрована достава се мења тек када се ажурирање групе потврди.';

  @override
  String get detailsRemoveConfirm => 'Уклони';

  @override
  String detailsRemoved(String label) {
    return 'Налог $label је уклоњен из разговора.';
  }

  @override
  String detailsRemoveFailed(String label) {
    return 'Уклањање налога $label није успело.';
  }

  @override
  String get detailsLeaveTitle => 'Напустити разговор?';

  @override
  String get detailsLeaveMessage =>
      'Престајете да примате нове поруке, а разговор се уклања са овог уређаја. Поруке које су други чланови већ примили се не бришу.';

  @override
  String get detailsLeaveConfirm => 'Напусти';

  @override
  String get detailsRetentionOffMessage =>
      'Нове поруке више неће нестајати. Поруке које већ имају тајмер задржавају га.';

  @override
  String detailsRetentionOnMessage(String duration) {
    return 'Поруке послате од сада биће обрисане са сервера $duration након слања. Постојеће поруке се не мењају.';
  }

  @override
  String get detailsRetentionOffTitle => 'Искључити нестајуће поруке?';

  @override
  String detailsRetentionOnTitle(String duration) {
    return 'Подесити нестајање на $duration?';
  }

  @override
  String get detailsApply => 'Примени';

  @override
  String get detailsAdd => 'Додај';

  @override
  String detailsMemberAdded(String label) {
    return 'Налог $label је додат у разговор. Шифрована достава почиње када се ажурирање групе потврди.';
  }

  @override
  String get roleOwner => 'Власник';

  @override
  String get roleAdmin => 'Администратор';

  @override
  String get roleModerator => 'Модератор';

  @override
  String get roleMember => 'Члан';

  @override
  String get detailsYou => 'Ви';

  @override
  String detailsJoined(String date) {
    return 'Члан од $date';
  }

  @override
  String detailsRemoveMember(String label) {
    return 'Уклони $label';
  }

  @override
  String get detailsBlockedDetail =>
      'Поруке тог налога су скривене за овај налог док га не деблокирате.';

  @override
  String get detailsBlockDetail =>
      'Сервер престаје да доставља поруке тог налога вашем налогу. Тај налог о томе неће бити обавештен, а поруке које су већ на вашим уређајима остају.';

  @override
  String get chatStatusMutedEncrypted => 'УТИШАНО · ШИФРОВАНО';

  @override
  String get chatStatusEncrypted => 'ШИФРОВАНО';

  @override
  String get chatNoConversationMessage =>
      'Изаберите разговор са листе ћаскања.';

  @override
  String get chatEmptyTitle => 'Још нема порука';

  @override
  String get chatEmptyMessage =>
      'Поруке се чувају као шифровани коверти које могу да прочитају само чланови.';

  @override
  String get chatJumpToLatest => 'Иди на најновије';

  @override
  String chatReact(String reaction) {
    return 'Реагуј: $reaction';
  }

  @override
  String get chatReply => 'Одговори';

  @override
  String get chatCopyText => 'Копирај текст';

  @override
  String get chatEdit => 'Измени';

  @override
  String get chatDeleteForEveryone => 'Избриши за све';

  @override
  String get chatDeleteTitle => 'Избрисати за све?';

  @override
  String get chatDeleteMessage =>
      'Уређаји чланова уклањају текст. Сервер га никада није имао.';

  @override
  String get chatDelete => 'Избриши';

  @override
  String get chatEditEmpty =>
      'Унесите нови текст или уместо тога избришите поруку.';

  @override
  String get chatEditTitle => 'Измени поруку';

  @override
  String get chatLoadFailed => 'Учитавање порука није успело';

  @override
  String get chatReplyEarlier => 'Одговор на ранију поруку';

  @override
  String get chatReplyDeleted => 'Одговор на обрисану поруку';

  @override
  String get chatLoadOlder => 'Учитај старије поруке';

  @override
  String get chatPendingSendingSemantics => 'Шифрована порука се шаље';

  @override
  String get chatPendingTerminalSemantics =>
      'Слање шифроване поруке трајно није успело. Можете је копирати или одбацити.';

  @override
  String get chatPendingFailedSemantics =>
      'Слање шифроване поруке није успело. Можете покушати поново.';

  @override
  String get chatPendingSending => 'Шаље се шифрована порука';

  @override
  String get chatPendingTerminal => 'Порука захтева пажњу';

  @override
  String get chatPendingFailed => 'Слање није успело';

  @override
  String get chatDiscard => 'Одбаци';

  @override
  String get chatSenderYou => 'вас';

  @override
  String get chatAttachmentUnopenable => 'Овај прилог не може да се отвори.';

  @override
  String get chatMessageActions => 'Радње за поруку';

  @override
  String chatDeletedSemantics(String sender) {
    return 'Обрисана порука од $sender';
  }

  @override
  String chatUnverifiedSemantics(String time) {
    return 'Порука од пошиљаоца који није верификован, $time';
  }

  @override
  String chatMessageSemantics(String sender, String time, String text) {
    return 'Порука од $sender, $time: $text';
  }

  @override
  String chatAttachmentSemantics(String sender, String time) {
    return 'Прилог од $sender, $time';
  }

  @override
  String chatEncryptedSemantics(String sender, String time) {
    return 'Шифрована порука од $sender, $time';
  }

  @override
  String get chatMessageDeleted => 'Порука је обрисана';

  @override
  String get chatSenderUnverified =>
      'Пошиљалац није могао да се верификује. Порука је скривена.';

  @override
  String get chatMessageUnsupported =>
      'Ова порука захтева новију верзију апликације Veritra';

  @override
  String get chatMessageInvalid => 'Једна порука није могла да се прочита';

  @override
  String get chatMessageUndecryptable => 'Ова порука није могла да се откључа';

  @override
  String get chatMessageUnapprovedDevice =>
      'Сакривена је порука са уређаја који није одобрен.';

  @override
  String chatDevicesNotJoined(String name) {
    return 'Неки уређаји корисника $name се још нису придружили.';
  }

  @override
  String get chatMessageWelcomeUnavailable =>
      'Придруживање овом ћаскању није успело. Замолите члана да вас поново дода.';

  @override
  String chatReactionCount(String reaction, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$reaction $countString';
  }

  @override
  String get chatEdited => 'измењено';

  @override
  String get chatTickSent => 'Послато';

  @override
  String get chatTickDelivered => 'Достављено';

  @override
  String get chatTickRead => 'Прочитано';

  @override
  String chatTypingOne(String name) {
    return '$name куца…';
  }

  @override
  String chatTypingTwo(String first, String second) {
    return '$first и $second куцају…';
  }

  @override
  String get chatTypingMany => 'Неколико особа куца…';

  @override
  String chatReplyingTo(String preview) {
    return 'Одговор на: $preview';
  }

  @override
  String get chatCancelReply => 'Откажи одговор';

  @override
  String get chatSendingFile => 'Слање датотеке';

  @override
  String get chatAttachFile => 'Приложи датотеку';

  @override
  String get chatComposerHint => 'Порука';

  @override
  String get chatPostingRestricted => 'Само администратори могу да објављују';

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
      'Слање је овде паузирано: сервер је одбио ажурирање шифровања за овај разговор. Остали разговори и даље раде.';

  @override
  String get chatSyncPausedNotice =>
      'Поруке у овом разговору су паузиране: ажурирање шифровања није могло да се примени. Ниједна порука није прескочена, а остали разговори и даље раде.';

  @override
  String get chatRemovalHoldNotice =>
      'Ваша порука чека да се заврши ажурирање шифровања после уклањања члана, а затим се шаље.';

  @override
  String get chatNoPeerReadOnly =>
      'Нико други у овом разговору не може поново да дода овај уређај, па је историја овде само за читање. Започните нови разговор да бисте слали поруке.';

  @override
  String get chatNoPeerCheckFailed =>
      'Тренутно не можемо да проверимо чланове овог разговора. Покушајте поново за тренутак.';

  @override
  String get chatAttachment => 'Прилог';

  @override
  String chatAttachmentOne(String name) {
    return 'Прилог: $name';
  }

  @override
  String chatAttachmentMany(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Прилози: $name и још $countString';
  }

  @override
  String get demoBannerLabel => 'Демо верзија · шифровање без ревизије';

  @override
  String demoBannerNotice(String label) {
    return '$label. Није за стварне разговоре.';
  }

  @override
  String dateTimeJoined(String date, String time) {
    return '$date · $time';
  }

  @override
  String get backupErrorNetwork =>
      'Сервер није доступан. Покушајте поново; враћање се наставља тамо где је стало.';

  @override
  String get backupErrorNotFound =>
      'Овај код за опоравак је непознат, истекао је или је већ искоришћен.';

  @override
  String get backupErrorBusy =>
      'Ова резервна копија се управо преузима на другом месту. Покушајте поново за неколико минута.';

  @override
  String get backupErrorWrongKey =>
      'Овај код за опоравак не отвара резервну копију.';

  @override
  String get backupErrorCorrupt =>
      'Резервна копија је оштећена и не може да се врати.';

  @override
  String get backupErrorDeviceNotEmpty =>
      'Овај уређај већ има налог. Одјавите се и ресетујте уређај пре враћања резервне копије.';

  @override
  String get backupErrorTooLarge =>
      'Резервна копија је већа од онога што ова апликација подржава.';

  @override
  String get backupErrorStorage =>
      'Овај уређај није могао да сачува резервну копију.';

  @override
  String get backupRestoredLinkToFinish =>
      'Ваше поруке и подешавања су враћени на овај уређај. Да бисте завршили, повежите овај уређај са другог уређаја који је пријављен на ваш налог. Ако сте изгубили све уређаје, користите „Изгубили сте све уређаје?” са лозинком и кључем за опоравак.';

  @override
  String get syncErrorCursorExpired =>
      'Овај уређај је био одсутан дуже него што сервер чува ажурирања. Вратите резервну копију или поново повежите овај уређај.';

  @override
  String get syncErrorControlMissing =>
      'Ажурирање шифровања за неки разговор недостаје или је оштећено. Поруке су паузиране да ниједна не би била прескочена.';

  @override
  String get syncErrorMlsState =>
      'Овај уређај није могао да ажурира своје стање шифровања. Поруке су паузиране да ниједна не би била прескочена.';

  @override
  String get syncErrorUndecryptable =>
      'Порука није могла да се прочита на овом уређају. Поруке су паузиране да ниједна не би била прескочена.';

  @override
  String get syncErrorUnsupportedEvent =>
      'Сервер је послао ажурирање које ова верзија апликације не препознаје. Ажурирајте апликацију, па покушајте поново.';

  @override
  String get syncErrorCryptoUnavailable =>
      'Шифровање није доступно у овој верзији апликације, па шифрована ажурирања не могу да се примене.';

  @override
  String get syncErrorStopped =>
      'Синхронизација је заустављена. Покушајте поново.';

  @override
  String get syncErrorLocalStorage =>
      'Овај уређај није могао да чита или пише у своје локално складиште. Поруке су паузиране да ниједна не би била прескочена. Ослободите простор или поново покрените апликацију, па покушајте поново.';

  @override
  String get syncErrorRecordLimit =>
      'Један разговор је постао превелик да би овај уређај сачувао његове шифроване податке. Поруке су паузиране да ниједна не би била прескочена. Напустите тај разговор да бисте наставили.';

  @override
  String get syncErrorRecordLimitDevice =>
      'Шифровани подаци овог уређаја постали су превелики за чување. Поруке су паузиране да ниједна не би била прескочена. Поново повежите овај уређај да бисте наставили.';

  @override
  String syncErrorRecordLimitNamed(String title) {
    return 'Разговор „$title“ је постао превелик да би овај уређај сачувао његове шифроване податке. Поруке су паузиране да ниједна не би била прескочена. Напустите тај разговор да бисте наставили.';
  }

  @override
  String bannerLeaveNamed(String title) {
    return 'Напусти „$title“';
  }

  @override
  String bannerLeaveNamedTitle(String title) {
    return 'Напустити „$title“?';
  }

  @override
  String get syncErrorStorageBusy =>
      'Складиште овог уређаја је заузето или пуно. Синхронизација ће ускоро покушати поново.';

  @override
  String get apiErrorSessionInvalid =>
      'Ваша сесија више није важећа. Пријавите се поново.';

  @override
  String get apiErrorInvalidCredentials =>
      'Пријава није успела. Проверите корисничко име и лозинку.';

  @override
  String get apiErrorRecentAuth => 'Потврдите лозинку пре ове осетљиве радње.';

  @override
  String get apiErrorDeviceNotLinked =>
      'Овај уређај мора бити повезан пре пријаве лозинком.';

  @override
  String get apiErrorForbidden => 'Немате дозволу за то.';

  @override
  String get apiErrorNotFound => 'Та ставка није пронађена. Можда је уклоњена.';

  @override
  String get apiErrorAlreadySetup =>
      'Овај сервер већ има власника. Уместо тога се пријавите или се придружите уз позивницу.';

  @override
  String get apiErrorLastOwner =>
      'Пренесите власништво пре него што онемогућите последњи налог власника.';

  @override
  String get apiErrorWeakPassword => 'Лозинка мора имати 12–72 знака.';

  @override
  String get apiErrorInvalidInvite =>
      'Тај код позивнице није важећи, истекао је или је већ искоришћен до краја.';

  @override
  String get apiErrorInvalidDeviceLink =>
      'Тај код за повезивање није важећи или је истекао. Генеришите нови на повезаном уређају.';

  @override
  String get apiErrorTranscriptMismatch =>
      'Локално верификовани акредитиви уређаја су се променили. Генеришите нову везу и поново упоредите оба уређаја.';

  @override
  String get apiErrorInvalidDeviceName => 'Тај назив уређаја није важећи.';

  @override
  String get apiErrorInvalidName => 'Тај назив није важећи.';

  @override
  String get apiErrorInvalidMaxUses =>
      'Ограничење броја коришћења позивнице није важеће.';

  @override
  String get apiErrorInvalidExpiry => 'То време истека није важеће.';

  @override
  String get apiErrorInvalidConversationKind =>
      'Сервер је одбио ову врсту разговора.';

  @override
  String get apiErrorInvalidRetention =>
      'То трајање нестајућих порука није подржано.';

  @override
  String get apiErrorInvalidRole => 'Та улога члана није важећа.';

  @override
  String get apiErrorAccountRequired =>
      'Изаберите налог који желите да додате.';

  @override
  String get apiErrorUploadTooLarge => 'Та датотека је превелика за отпремање.';

  @override
  String get apiErrorKeyPackageRefused =>
      'Сервер је одбио кључеве за шифровање ове верзије апликације. Потребан је клијент са подршком за продукционо шифровање.';

  @override
  String get apiErrorStorage =>
      'Сервер је имао проблем са складиштем. Покушајте поново ускоро.';

  @override
  String get apiErrorStorageFull =>
      'Сервер нема више простора за овај налог. Избришите старије прилоге или затражите од администратора више простора.';

  @override
  String get apiErrorBlobIntegrity =>
      'Шифровани прилог није могао да се верификује. Одбаците га и покушајте поново.';

  @override
  String get apiErrorSetupToken =>
      'Токен за подешавање недостаје или је погрешан. Користите онај који је сервер исписао при покретању (демо га чува у data/demo/setup-token).';

  @override
  String get apiErrorDraining =>
      'Сервер се поново покреће. Покушајте поново ускоро.';

  @override
  String get apiErrorIdempotencyConflict =>
      'Ова порука је већ послата са другачијим подацима. Одбаците је и напишите нову поруку.';

  @override
  String get apiErrorMessageExpired => 'Та порука је истекла.';

  @override
  String get apiErrorRecoveryInProgress =>
      'Друго враћање већ преузима ову резервну копију. Покушајте поново ускоро.';

  @override
  String get apiErrorWriteRateLimited =>
      'Тренутно шаљете много. Сачекајте минут и покушајте поново.';

  @override
  String get apiErrorServerStorageLow =>
      'Серверу скоро понестаје простора, па су нове поруке и отпремања паузирани. Замолите администратора да ослободи простор.';

  @override
  String get apiErrorDeviceLimit =>
      'Овај налог већ има највећи дозвољени број уређаја. Прво уклоните један у Подешавањима.';

  @override
  String get apiErrorDeviceLinkLimit =>
      'Превише повезивања уређаја је на чекању. Прво довршите или откажите једно.';

  @override
  String get apiErrorConversationLimit =>
      'Достигли сте највећи дозвољени број разговора на овом серверу. Прво напустите или избришите један.';

  @override
  String get apiErrorConversationMemberLimit => 'Овај разговор је пун.';

  @override
  String get apiErrorConflict =>
      'Ово се у међувремену променило на серверу. Освежите и покушајте поново.';

  @override
  String get apiErrorRateLimited =>
      'Превише покушаја. Сачекајте тренутак и покушајте поново.';

  @override
  String get apiErrorEncryption =>
      'Сервер је одбио шифроване податке из ове верзије апликације.';

  @override
  String get apiErrorServer =>
      'Сервер је имао проблем. Покушајте поново ускоро.';

  @override
  String get apiErrorInvalidRequest =>
      'Сервер је одбио захтев. Проверите унос и покушајте поново.';

  @override
  String get errorUnexpectedResponse => 'Сервер је вратио неочекиван одговор.';

  @override
  String get errorConversationPaused => 'Слање је паузирано у овом разговору.';

  @override
  String get errorConversationApprovalHeld =>
      'Слање је паузирано: уређај у овом ћаскању није на одобреној листи свог власника или листа још није могла да се провери.';

  @override
  String get errorDeviceListNotApproved =>
      'Тај уређај још није на одобреној листи свог власника. Биће додат када буде.';

  @override
  String get errorDeviceListConflict =>
      'Одобрена листа уређаја вашег налога промењена је на начин који не може да се провери. Упоредите сигурносне бројеве са контактом пре него што промените уређаје.';

  @override
  String get errorOutboxFull =>
      'Ваш ред шифрованих порука је пун. Пошаљите или одбаците поруку на чекању пре него што напишете нову.';

  @override
  String get errorCryptoStateFormatUnsupported =>
      'Шифровани подаци на овом уређају сачувани су у формату који ова верзија апликације не може да прочита. Поново повежите овај уређај да бисте наставили да шаљете поруке.';

  @override
  String get errorConversationTooLarge =>
      'Овај разговор је постао превелик да би овај уређај сачувао његове шифроване податке. Ништа није промењено. Можете да напустите разговор да би остали радили.';

  @override
  String get errorCryptoRecordLimit =>
      'Шифровани подаци овог уређаја постали су превелики за чување. Ништа није промењено. Поново повежите овај уређај да бисте наставили да шаљете поруке.';

  @override
  String get errorConversationPausedDetail =>
      'Слање је паузирано у овом разговору јер је сервер одбио ажурирање шифровања. Остали разговори и даље раде.';

  @override
  String get errorEncryptionUnavailable =>
      'Ова верзија апликације још не садржи продукциони механизам за шифровање, па ова радња није доступна.';

  @override
  String get errorActionUnavailable =>
      'Ова радња није доступна у овој верзији апликације.';

  @override
  String get errorGeneric => 'Дошло је до грешке. Покушајте поново.';

  @override
  String get errorTimeout =>
      'Серверу је требало предуго да одговори. Покушајте поново.';

  @override
  String get errorUnreachable =>
      'Сервер није доступан. Проверите URL инстанце и везу.';

  @override
  String get probeChecking => 'Провера сервера…';

  @override
  String get probeReached => 'Veritra сервер је доступан.';

  @override
  String probeConnectedTo(String name) {
    return 'Повезано са сервером $name.';
  }

  @override
  String get probeInvalidOrigin =>
      'Унесите HTTPS адресу сервера, на пример https://chat.example.org.';

  @override
  String get probeInsecure =>
      'Veritra захтева HTTPS. Поставите сервер који сами хостујете иза TLS-а са поузданим сертификатом или иза Caddy-ја.';

  @override
  String get probeDnsFailure =>
      'Та адреса није пронађена. Проверите назив хоста и покушајте поново.';

  @override
  String get probeTlsFailure =>
      'Сертификат сервера није прихваћен. Користите поуздан сертификат или подесите Caddy TLS.';

  @override
  String get probeTimedOut =>
      'Серверу је требало предуго да одговори. Проверите адресу и везу.';

  @override
  String get probeNotVeritra => 'Та адреса не изгледа као Veritra сервер.';

  @override
  String get probeUnavailable =>
      'Сервер није доступан. Проверите адресу и везу.';

  @override
  String get outboxSendFailed =>
      'Ова шифрована порука није могла да се пошаље. Копирајте је или је одбаците.';

  @override
  String get recoveryRestoreFailed =>
      'Овај уређај није могао да врати своју шифровану сесију. Покушајте поново или наставите на пријаву без брисања локалних података.';

  @override
  String get recoveryProfileLocked =>
      'Овај профил је већ отворен у другом Veritra прозору. Затворите тај прозор, па покушајте поново.';

  @override
  String get recoveryKeyUnavailable =>
      'Овај уређај није могао да прочита своје безбедно складиште. Откључајте уређај и покушајте поново. Ваше поруке су сачуване.';

  @override
  String get recoveryKeyMissing =>
      'Кључ који штити поруке овог уређаја недостаје или се не подудара. Ништа није обрисано. Можете покушати поново или ресетовати овај уређај и поново га повезати.';

  @override
  String get recoveryResetFailed =>
      'Ресетовање није завршено. Ништа није обрисано. Покушајте поново.';

  @override
  String get recoveryUpgradeFailed =>
      'Овај уређај није могао да ажурира складиште порука за ову верзију апликације Veritra, на пример зато што је уређај пун. Ништа није промењено нити обрисано. Ослободите мало простора, па покушајте поново.';

  @override
  String get recoveryUpgradeStillFull =>
      'Овај уређај ни сада није могао да ажурира складиште порука. Ништа није промењено нити обрисано. Ослободите још простора и покушајте поново или ресетујте овај уређај и поново га повежите.';

  @override
  String get recoveryUpgradeError =>
      'Овај уређај није могао да ажурира складиште порука за ову верзију апликације Veritra. Ништа није промењено нити обрисано. Покушајте поново. Ако и даље не успева, можете да ресетујете овај уређај и поново га повежете.';

  @override
  String get recoveryStorageDamaged =>
      'Складиште порука на овом уређају је оштећено и не може да се прочита, па је синхронизација заустављена. Ништа није обрисано. Покушајте поново или ресетујте овај уређај и поново га повежите.';

  @override
  String get recoverySqliteFeatureMissing =>
      'Ова верзија апликације Veritra не може да отвори своје складиште порука: у машини базе података недостаје подршка за шифровање или претрагу. Ваши подаци нису промењени нити обрисани. Инсталирајте верзију апликације Veritra која их подржава.';

  @override
  String get errorPasswordLoginNeedsLink =>
      'За пријаву лозинком овај уређај прво мора бити повезан.';

  @override
  String get attachmentSendFailedState => 'Прилог није могао да се пошаље.';

  @override
  String get errorRelinkRequired => 'Овај уређај мора поново да се повеже.';

  @override
  String get pushTestSent =>
      'Проба је послата. Обавештење би требало да стигне у року од једног минута.';

  @override
  String get pushTestGone =>
      'Push добављач више не прихвата овај уређај. Регистрација се понавља.';

  @override
  String get pushTestRejected =>
      'Push добављач није прихватио пробу. Покушајте поново касније.';

  @override
  String get pushTestRateLimited => 'Сачекајте минут пре слања нове пробе.';

  @override
  String get pushTestNotRegistered =>
      'Овај уређај још није регистрован за push обавештења.';

  @override
  String get pushTestFailed => 'Проба није могла да се пошаље.';

  @override
  String errorServerNotAllowed(String url) {
    return 'Ова верзија апликације не дозвољава адресу сервера $url. Користите https:// адресу сервера.';
  }

  @override
  String get muteEightHours => '8 сати';

  @override
  String get muteOneWeek => '1 недељу';

  @override
  String get muteAlways => 'Док поново не укључим';

  @override
  String get muteStatusAlways => 'Утишано док поново не укључите обавештења.';

  @override
  String muteStatusUntil(String time) {
    return 'Утишано до $time.';
  }

  @override
  String get chatMoreReactions => 'Више реакција';

  @override
  String get emojiSearchHint =>
      'Претражите по имену или унесите или налепите емоџи';

  @override
  String emojiUseTyped(String emoji) {
    return 'Користи $emoji';
  }

  @override
  String get emojiNoResults =>
      'Нема емоџија са тим именом. Унесите или налепите га.';

  @override
  String get emojiGroupSmileys => 'Смајлији';

  @override
  String get emojiGroupPeople => 'Људи';

  @override
  String get emojiGroupAnimals => 'Животиње и природа';

  @override
  String get emojiGroupFood => 'Храна и пиће';

  @override
  String get emojiGroupTravel => 'Путовања и места';

  @override
  String get emojiGroupActivities => 'Активности';

  @override
  String get emojiGroupObjects => 'Предмети';

  @override
  String get emojiGroupSymbols => 'Симболи';

  @override
  String get emojiGroupFlags => 'Заставе';

  @override
  String get searchModeMessages => 'Поруке';

  @override
  String get searchModePeople => 'Људи и заједнице';

  @override
  String get searchMessagesHint => 'Претражите поруке на овом уређају…';

  @override
  String get searchMessagesIntroTitle => 'Претрага овог уређаја';

  @override
  String get searchMessagesIntroMessage =>
      'Налази текст у порукама које овај уређај чува. Претрага се одвија овде и никада се не шаље серверу.';

  @override
  String get searchMessagesNoResultsTitle => 'Нема пронађених порука';

  @override
  String get searchMessagesNoResultsMessage =>
      'Ништа на овом уређају не одговара. Поруке које су истекле или су обрисане нестају и из претраге.';

  @override
  String get searchMessagesFailed =>
      'Претрага није могла да прочита локалну базу података.';

  @override
  String attachmentTooLarge(String fileName, String limit) {
    return 'Датотека $fileName је већа него што овај сервер дозвољава ($limit).';
  }

  @override
  String attachmentEmptyFile(String fileName) {
    return 'Датотека $fileName је празна и не може да се пошаље.';
  }

  @override
  String attachmentTooMany(int count) {
    return 'Највише $count датотека може да чека на заједничко слање.';
  }

  @override
  String attachmentRemove(String fileName) {
    return 'Уклоните $fileName';
  }

  @override
  String get attachmentOpenFailed =>
      'Датотека није могла да се отвори. Овај уређај можда нема апликацију за њу.';

  @override
  String get attachmentDropHint => 'Отпустите датотеке да бисте их приложили';

  @override
  String attachmentSentCount(int done, int total) {
    return 'Шаље се датотека $done од $total';
  }

  @override
  String get settingsAdmin => 'Администрација';

  @override
  String get settingsAdminDetail => 'Налози и дневник ревизије';

  @override
  String get adminAccountsTab => 'Налози';

  @override
  String get adminAuditTab => 'Дневник ревизије';

  @override
  String get adminSuspend => 'Суспендуј';

  @override
  String get adminUnsuspend => 'Поново активирај';

  @override
  String get adminSuspendTitle => 'Суспендовати овај налог?';

  @override
  String adminSuspendMessage(String username) {
    return '@$username ће бити одјављен свуда и неће моћи да се пријави док не активирате налог поново.';
  }

  @override
  String get adminUnsuspendTitle => 'Поново активирати овај налог?';

  @override
  String adminUnsuspendMessage(String username) {
    return '@$username ће поново моћи да се пријави.';
  }

  @override
  String get adminSuspendedPill => 'Суспендован';

  @override
  String adminAccountSummary(String role, int devices, String storage) {
    String _temp0 = intl.Intl.pluralLogic(
      devices,
      locale: localeName,
      other: '$devices уређаја',
      few: '$devices уређаја',
      one: '$devices уређај',
    );
    return '$role · $_temp0 · $storage';
  }

  @override
  String adminEventBy(String actor) {
    return 'Извршио: $actor';
  }

  @override
  String get adminLoadMore => 'Учитај још';

  @override
  String get adminNoAccounts => 'Нема налога';

  @override
  String get adminNoEvents => 'Још нема догађаја ревизије';

  @override
  String requestsSection(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Захтеви ($countString)';
  }

  @override
  String get requestsTitle => 'Захтев за поруку';

  @override
  String requestFrom(String name) {
    return '$name жели да вам пише';
  }

  @override
  String get requestUnknownSender => 'Неко кога не познајете';

  @override
  String get requestExplanation =>
      'Ништа од ове особе се не приказује нити преузима, и она не може да види да сте нешто прочитали, док не прихватите.';

  @override
  String get requestAccept => 'Прихвати';

  @override
  String get requestBlock => 'Блокирај';

  @override
  String get requestDelete => 'Обриши';

  @override
  String get requestBlockTitle => 'Блокирати ову особу?';

  @override
  String requestBlockMessage(String name) {
    return '$name више неће моћи да вам пише, а овај разговор ће бити уклоњен.';
  }

  @override
  String get requestDeleteTitle => 'Обрисати овај захтев?';

  @override
  String get requestDeleteMessage =>
      'Разговор се уклања са овог уређаја. Пошиљалац није обавештен.';

  @override
  String get w8PinnedMessage => 'Закачена порука';

  @override
  String get w8Pin => 'Закачи поруку';

  @override
  String get w8Unpin => 'Откачи поруку';

  @override
  String w8PinDays(int days) {
    return 'Закачи на $days дана';
  }

  @override
  String get w8Forward => 'Проследи';

  @override
  String get w8Forwarded => 'Прослеђено';

  @override
  String get w8ForwardedMany => 'Прослеђено више пута';

  @override
  String get w8Star => 'Означи звездицом на овом уређају';

  @override
  String get w8Unstar => 'Уклони звездицу';

  @override
  String get w8DeleteForMe => 'Избриши за мене на овом уређају';

  @override
  String get w8Archive => 'Архивирај на овом уређају';

  @override
  String get w8Unarchive => 'Врати из архиве';

  @override
  String get w8PinChat => 'Закачи ћаскање на овом уређају';

  @override
  String get w8UnpinChat => 'Откачи ћаскање';

  @override
  String get w8ArchivedChats => 'Архивирана ћаскања';

  @override
  String get w8Chats => 'Ћаскања';

  @override
  String get w8MentionsMuted => 'Помињања у утишаним ћаскањима';

  @override
  String get w8MentionsMutedDetail =>
      'Обавести ме када ме члан помене, чак и у утишаном ћаскању.';

  @override
  String get b2LinkPreviews => 'Прегледи веза';

  @override
  String get b2LinkPreviewsDetail =>
      'Када пошаљете везу, овај уређај може да преузме страницу и стави преглед у шифровану поруку. Сајт види адресу овог уређаја. Сервер и особе којима пишете никада не преузимају везу.';

  @override
  String get b2LinkPreviewsOff => 'Искључено';

  @override
  String get b2LinkPreviewsKnown => 'Само познати сајтови';

  @override
  String get b2LinkPreviewsAll => 'Сви сајтови';

  @override
  String get w8HiddenSpoiler => 'Порука са скривеним спојлером';

  @override
  String get w8StarredMessages => 'Поруке са звездицом на овом уређају';

  @override
  String get k2CopiedHistory => 'Копирана историја · снимак са уређаја';

  @override
  String get k2HistoryOnlyTitle => 'Копирана историја';

  @override
  String get k2HistoryOnlyNotice =>
      'Копирано са вашег другог уређаја. Само за читање: овај уређај није члан овог разговора, па се овде ништа не може послати.';

  @override
  String get k2HistoryUntitled => 'Ранији разговор';

  @override
  String get k2HistoryOtherMember => 'Други члан';

  @override
  String get k2HistoryAttachment => 'Прилог, није преузет на овом уређају';

  @override
  String get k2HistoryEmpty =>
      'У овом разговору није остала ниједна копирана порука.';

  @override
  String get settingsRecoveryKey => 'Кључ за опоравак';

  @override
  String get recoveryUnavailableHere =>
      'Опоравак налога није доступан у овој верзији апликације.';

  @override
  String get recoveryKeyTitle => 'Кључ за опоравак';

  @override
  String get recoveryKeyIntro =>
      'Ако изгубите све уређаје, лозинка и овај кључ за опоравак враћају ваш налог на нови уређај. Чувајте кључ на папиру, на сигурном месту. Он не враћа историју порука.';

  @override
  String recoveryKeyStatusSet(String date) {
    return 'Постављен $date';
  }

  @override
  String get recoveryKeyStatusNotSet => 'Није постављен';

  @override
  String get recoveryKeyStatusUnknown => 'Стање тренутно није доступно';

  @override
  String get recoveryKeyStatusOff => 'Овај сервер има искључен опоравак налога';

  @override
  String get recoveryKeyCreate => 'Направи кључ за опоравак';

  @override
  String get recoveryKeyReplace => 'Замени кључ за опоравак';

  @override
  String get recoveryKeyReplaceNote =>
      'Нови кључ одмах замењује стари и отказује опоравак који чека.';

  @override
  String get recoveryKeyShowTitle => 'Запишите кључ за опоравак';

  @override
  String get recoveryKeyShowDetail =>
      'Запишите ова 52 знака на папир и чувајте га на сигурном. Свако ко има овај кључ и вашу лозинку може да преузме ваш налог. Не правите снимак екрана и не чувајте га у разговору.';

  @override
  String get recoveryKeyWritten => 'Кључ је записан';

  @override
  String get recoveryKeyConfirmTitle => 'Унесите кључ за опоравак';

  @override
  String get recoveryKeyConfirmDetail =>
      'Унесите цео кључ са папира да бисте га проверили. Цртице и размаци нису битни.';

  @override
  String get recoveryKeyField => 'Кључ за опоравак';

  @override
  String get recoveryKeyRequired => 'Унесите кључ за опоравак.';

  @override
  String get recoveryKeyMismatch =>
      'То није приказани кључ. Проверите папир и покушајте поново.';

  @override
  String get recoveryKeyShowAgain => 'Прикажи кључ поново';

  @override
  String get recoveryKeySave => 'Сачувај кључ за опоравак';

  @override
  String get recoveryKeySaved => 'Кључ за опоравак је сачуван.';

  @override
  String get recoveryFollowUpTitle => 'Завршите опоравак налога';

  @override
  String get recoveryFollowUpKeyDetail =>
      'Ваш налог је враћен на овај уређај, а ваши други уређаји су одјављени. Пре него што се разговори отворе, замените кључ за опоравак, а затим лозинку: можда их неко други зна.';

  @override
  String get recoveryFollowUpPasswordDetail =>
      'Последњи корак: изаберите нову лозинку.';

  @override
  String get connectLostAllDevices => 'Изгубили сте све уређаје?';

  @override
  String get recoveryStartTitle => 'Опоравак налога';

  @override
  String get recoveryStartDetail =>
      'Користите ово само ако сте изгубили сваки уређај пријављен на ваш налог. Потребни су вам лозинка и кључ за опоравак. Ако је неки ваш уређај коришћен у последњих 7 дана, овај уређај се придружује тек после 7 дана, а ти уређаји могу да откажу опоравак. Историја порука се враћа само из резервне копије враћене на овај уређај.';

  @override
  String get recoveryStartSubmit => 'Започни опоравак';

  @override
  String get recoveryKeyUnreadable =>
      'Тај кључ за опоравак није исправан. Проверите да ли има грешака у куцању.';

  @override
  String get recoveryKeyNotThisAccount =>
      'То није кључ за опоравак овог налога. Проверите папир и покушајте поново.';

  @override
  String get recoveryKeyConfirmedForList => 'Кључ за опоравак је потврђен.';

  @override
  String get recoveryRetypeDone => 'Опоравак је довршен на овом уређају.';

  @override
  String get recoveryClaimRefused =>
      'Лозинка или кључ за опоравак није исправан, адреса сервера се разликује од записане, или овај налог не може да се опорави.';

  @override
  String get recoveryBackupOtherAccount =>
      'Резервна копија враћена на овај уређај припада другом налогу или серверу. Овде опоравите тај налог или прво ресетујте овај уређај.';

  @override
  String get recoverySignedInAlready => 'Овај уређај је већ пријављен.';

  @override
  String get recoveryAlreadyPending => 'Опоравак већ чека на овом уређају.';

  @override
  String get recoveryDeviceLinkInProgress =>
      'На овом уређају је у току повезивање уређаја, па опоравак налога не може да почне овде.';

  @override
  String get recoveryWaitingTitle => 'Опоравак чека';

  @override
  String recoveryWaitingDetail(String date) {
    return 'Овај уређај се придружује вашем налогу после $date. Апликација сама проверава док је отворена. Ваши други уређаји могу да откажу овај опоравак.';
  }

  @override
  String get recoveryReadyDetail =>
      'Чекање је завршено. Проверите сада да бисте завршили.';

  @override
  String get recoveryCheckNow => 'Провери сада';

  @override
  String get recoveryAbandon => 'Прекини опоравак';

  @override
  String get recoveryAbandonTitle => 'Прекинути опоравак на овом уређају?';

  @override
  String get recoveryAbandonMessage =>
      'Овај уређај заборавља захтев. Да бисте покушали поново, поново су вам потребни лозинка и кључ за опоравак.';

  @override
  String get recoveryRequestEnded =>
      'Овај опоравак је отказан или је истекао. Отказује га промена лозинке или кључа за опоравак, или неки ваш уређај. Можете да почнете поново.';

  @override
  String get recoveryLoginTitle => 'Пријавите се да бисте завршили';

  @override
  String get recoveryLoginDetail =>
      'Ваш налог је опорављен на овом уређају, али одговор није стигао. Унесите лозинку да бисте завршили.';

  @override
  String get recoveryLoginSubmit => 'Пријави се';

  @override
  String recoveryAccountLabel(String username) {
    return 'Налог: $username';
  }

  @override
  String recoveryPendingNotice(String device, String date) {
    return 'Неко опоравља ваш налог на уређају „$device”, до $date. Нисте ви? Откажите или промените лозинку или кључ за опоравак.';
  }

  @override
  String get recoveryPendingCancel => 'Откажи опоравак';

  @override
  String get recoveryCancelTitle => 'Отказати овај опоравак?';

  @override
  String get recoveryCancelMessage =>
      'Нови уређај се неће придружити вашем налогу. Ако то нисте били ви, промените и лозинку.';

  @override
  String get recoveryCancelled => 'Опоравак је отказан.';

  @override
  String get passwordLeakNotice =>
      'Ваша лозинка је много пута употребљена са погрешним кључем за опоравак. Промените лозинку.';

  @override
  String get passwordLeakDismiss => 'Затвори';

  @override
  String get apiErrorRecoveryNotConfigured =>
      'Овај сервер није укључио опоравак налога.';

  @override
  String get apiErrorRecoveryBackoff =>
      'Превише покушаја. Сачекајте мало, па покушајте поново.';

  @override
  String get apiErrorInvalidRecoveryKey =>
      'Сервер је одбио овај кључ за опоравак. Направите нови.';

  @override
  String get recoveryAlreadyEnded =>
      'Овај опоравак је већ завршен или га је заменио новији.';

  @override
  String get apiErrorPasswordUnchanged =>
      'Изаберите лозинку која се разликује од тренутне.';

  @override
  String get recoveryKeyServerAddress => 'Уз њега запишите и адресу сервера:';

  @override
  String recoveryKeyOriginMismatch(String current, String origin) {
    return 'Овај уређај користи $current, али адреса сервера за опоравак је $origin. Опоравак ради само преко адресе $origin.';
  }

  @override
  String get joinTitle => 'Придружи се линком';

  @override
  String get joinLinkLabel => 'Позивни линк';

  @override
  String get joinLinkHint => 'Налепите линк који сте добили';

  @override
  String get joinCheck => 'Провери линк';

  @override
  String get joinLinkInvalid => 'Ово није позивни линк за овај сервер.';

  @override
  String get joinLinkUnusable => 'Овај линк више не ради. Затражите нови.';

  @override
  String get joinKindGroup => 'Група';

  @override
  String get joinKindCommunity => 'Заједница';

  @override
  String joinInvitedBy(String username) {
    return 'Позвао вас је $username';
  }

  @override
  String get joinRequestButton => 'Затражи придруживање';

  @override
  String get joinRequestNote =>
      'Власник или администратор мора да одобри ваш захтев. До тада немате приступ.';

  @override
  String get joinAlreadyMember => 'Већ сте члан.';

  @override
  String get joinRequestSent =>
      'Захтев је послат. Остаје међу вашим захтевима док неко не одлучи.';

  @override
  String get joinYourRequests => 'Ваши захтеви';

  @override
  String get joinNoRequests => 'Још нема захтева.';

  @override
  String get joinStatusPending => 'Чека одобрење';

  @override
  String get joinStatusApproved =>
      'Одобрено. Шифровани приступ следи када уређај неког члана ажурира групу.';

  @override
  String get joinStatusRejected => 'Одбијено';

  @override
  String get joinStatusCancelled => 'Отказано';

  @override
  String get joinCancelRequest => 'Откажи захтев';

  @override
  String get membInviteSection => 'Позивни линкови';

  @override
  String get membInviteManage => 'Позиви и захтеви за придруживање';

  @override
  String get membInviteCreate => 'Направи позивни линк';

  @override
  String get membInviteCreateDetail =>
      'Важи 7 дана и за највише 10 људи, а сваку особу и даље морате да одобрите.';

  @override
  String get membInviteCreatedNote =>
      'Копирајте овај линк сада. Није сачуван на серверу и не може се поново приказати.';

  @override
  String get membInviteCopy => 'Копирај линк';

  @override
  String get membInviteCopied => 'Линк је копиран.';

  @override
  String get membInviteNone => 'Нема активних линкова.';

  @override
  String membInviteUses(int used, int max, String date) {
    return '$used од $max искоришћено · истиче $date';
  }

  @override
  String get membInviteRevoke => 'Опозови линк';

  @override
  String get joinReqSection => 'Захтеви за придруживање';

  @override
  String get joinReqNone => 'Нико не чека.';

  @override
  String joinReqAskedAt(String date) {
    return 'Затражено $date';
  }

  @override
  String joinReqApprove(String username) {
    return 'Одобри $username';
  }

  @override
  String joinReqReject(String username) {
    return 'Одбиј $username';
  }

  @override
  String get joinReqRejectedSnack => 'Захтев је одбијен.';

  @override
  String communityRemoveTitle(String username) {
    return 'Уклонити $username из заједнице?';
  }

  @override
  String get communityRemoveMessage =>
      'Одмах губе приступ свим каналима. Поруке које су већ на њиховим уређајима нису обрисане.';

  @override
  String get communityRemoveConfirm => 'Уклони';

  @override
  String get communityLeaveTitle => 'Напустити ову заједницу?';

  @override
  String get communityLeave => 'Напусти заједницу';

  @override
  String get communityLeaveDetail =>
      'Напуштате све канале одједном. Поново се можете придружити новим линком.';

  @override
  String get communityLeaveConfirm => 'Напусти';

  @override
  String get pollComposerTitle => 'Нова анкета';

  @override
  String get pollQuestionLabel => 'Питање';

  @override
  String pollOptionLabel(String number) {
    return 'Опција $number';
  }

  @override
  String get pollAddOption => 'Додај опцију';

  @override
  String get pollRemoveOption => 'Уклони опцију';

  @override
  String get pollMultipleChoice => 'Дозволи више одговора';

  @override
  String get pollSend => 'Пошаљи анкету';

  @override
  String get pollInvalidHint => 'Додајте питање и бар две различите опције.';

  @override
  String get pollVisibleNotice =>
      'Сви у овом разговору виде ко је за шта гласао.';

  @override
  String pollVoteTotal(String count) {
    return 'Гласова: $count';
  }

  @override
  String get pollChooseOne => 'Изаберите једну опцију';

  @override
  String get pollChooseSeveral => 'Изаберите једну или више опција';

  @override
  String get pollClose => 'Затвори анкету';

  @override
  String get pollClosedNotice => 'Ова анкета је затворена.';

  @override
  String get voiceNoteRecord => 'Снимите гласовну поруку';

  @override
  String get voiceNoteStop => 'Заустави и приложи';

  @override
  String get voiceNoteDiscard => 'Одбаци снимак';

  @override
  String voiceNoteRecording(String time) {
    return 'Снимање $time';
  }

  @override
  String get voiceNotePermissionDenied =>
      'Приступ микрофону је искључен. Дозволите га у подешавањима система да бисте снимали.';

  @override
  String get voiceNoteRecordFailed => 'Снимање није могло да почне.';

  @override
  String get voiceNotePlay => 'Пусти';

  @override
  String get voiceNotePause => 'Паузирај';

  @override
  String voiceNoteSemantics(String size) {
    return 'Гласовна порука, $size';
  }

  @override
  String get voiceNotePlayFailed => 'Гласовна порука није могла да се пусти.';

  @override
  String get callStartVoice => 'Гласовни позив';

  @override
  String get callStartVideo => 'Видео позив';

  @override
  String get callUnknownContact => 'Непознат контакт';

  @override
  String get callIncoming => 'Долазни позив';

  @override
  String get callIncomingVideo => 'Долазни видео позив';

  @override
  String get callRinging => 'Позивам…';

  @override
  String get callConnecting => 'Повезујем…';

  @override
  String get callInProgress => 'Позив у току';

  @override
  String get callRelayNote =>
      'Овај позив иде преко релеја сервера, па друга страна никад не види вашу мрежну адресу.';

  @override
  String get callAccept => 'Прихвати';

  @override
  String get callDecline => 'Одбиј';

  @override
  String get callHangUp => 'Прекини';

  @override
  String get callMute => 'Искључи звук';

  @override
  String get callUnmute => 'Укључи звук';

  @override
  String get callSpeaker => 'Звучник';

  @override
  String get callCameraOff => 'Искључи камеру';

  @override
  String get callCameraOn => 'Укључи камеру';

  @override
  String get callDismiss => 'Затвори';

  @override
  String callNoticeMissed(String name) {
    return 'Пропуштен позив: $name';
  }

  @override
  String callNoticeDeclined(String name) {
    return '$name је одбио/ла позив';
  }

  @override
  String callNoticeNoAnswer(String name) {
    return '$name се није јавио/ла';
  }

  @override
  String callNoticeBusy(String name) {
    return '$name је звао/ла док сте разговарали';
  }

  @override
  String get callNoticeFailed =>
      'Позив није успео да се повеже. За позиве је потребна подешена релејна (TURN) услуга сервера.';

  @override
  String get roomStart => 'Групни позив';

  @override
  String get roomTitle => 'Групни позив';

  @override
  String get roomJoining => 'Придружујем се…';

  @override
  String get roomConnected => 'У позиву';

  @override
  String get roomEncryptedNote =>
      'Глас и видео су шифровани од краја до краја. Сервер их преноси, али не може да их чује.';

  @override
  String get roomLeave => 'Напусти';

  @override
  String get roomYou => 'Ви';

  @override
  String get roomMute => 'Искључи звук';

  @override
  String get roomUnmute => 'Укључи звук';

  @override
  String get roomShareScreen => 'Подели екран';

  @override
  String get roomStopSharing => 'Заустави дељење';

  @override
  String get roomFailedFull => 'Овај позив је пун.';

  @override
  String get roomFailedUnavailable =>
      'Групни позиви нису подешени на овом серверу.';

  @override
  String get roomFailedWelcome =>
      'Безбедно придруживање није успело. Покушајте поново.';

  @override
  String get roomFailedOther => 'Позив није могао да се настави.';

  @override
  String get roomFailedCryptor =>
      'Овај уређај не може да заштити медије позива, па се није придружио.';

  @override
  String roomPeople(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count особа',
      few: '$count особе',
      one: '$count особа',
    );
    return '$_temp0';
  }

  @override
  String get moderationTitle => 'Модерација';

  @override
  String get moderationDetail =>
      'Забране, утишавање чланова, спори режим, паузирање позивница и дневник активности';

  @override
  String memberModerateTooltip(String username) {
    return 'Модерирај $username';
  }

  @override
  String get memberBanAction => 'Забрани…';

  @override
  String get memberTimeoutAction => 'Привремено утишај…';

  @override
  String get memberTimeoutLift => 'Укини утишавање';

  @override
  String banTitle(String username) {
    return 'Забранити $username?';
  }

  @override
  String get banMessage =>
      'Уклањају се из заједнице и не могу се вратити док се забрана не укине.';

  @override
  String get banConfirm => 'Забрани';

  @override
  String timeoutTitle(String username) {
    return 'Колико дуго утишати $username?';
  }

  @override
  String get timeoutDone => 'Утишавање је постављено.';

  @override
  String get moderationSectionInvites => 'Позивнице';

  @override
  String get moderationInvitesOpen => 'Везе за позивнице раде нормално.';

  @override
  String moderationInvitesPaused(String time) {
    return 'Паузирано до $time.';
  }

  @override
  String get moderationPauseInvites => 'Паузирај позивнице';

  @override
  String get moderationResumeInvites => 'Настави позивнице';

  @override
  String get moderationSectionSlow => 'Спори режим';

  @override
  String get moderationSlowOff => 'Искључено';

  @override
  String moderationSlowEvery(String interval) {
    return 'Једна порука на сваких $interval';
  }

  @override
  String moderationSlowTitle(String channel) {
    return 'Спори режим у каналу $channel';
  }

  @override
  String get moderationSectionBans => 'Забрањени налози';

  @override
  String get moderationNoBans => 'Нико није забрањен.';

  @override
  String moderationUnban(String username) {
    return 'Укини забрану за $username';
  }

  @override
  String get moderationSectionLog => 'Дневник активности';

  @override
  String get moderationNoEvents => 'Још ништа.';

  @override
  String moderationLogKick(String actor, String target) {
    return '$actor је уклонио/ла $target';
  }

  @override
  String moderationLogBan(String actor, String target) {
    return '$actor је забранио/ла $target';
  }

  @override
  String moderationLogUnban(String actor, String target) {
    return '$actor је укинуо/ла забрану за $target';
  }

  @override
  String moderationLogTimeout(String actor, String target) {
    return '$actor је утишао/ла $target';
  }

  @override
  String moderationLogTimeoutCleared(String actor, String target) {
    return '$actor је укинуо/ла утишавање за $target';
  }

  @override
  String moderationLogSlowMode(String actor) {
    return '$actor је променио/ла спори режим';
  }

  @override
  String moderationLogInvitesPaused(String actor) {
    return '$actor је паузирао/ла позивнице';
  }

  @override
  String moderationLogInvitesResumed(String actor) {
    return '$actor је наставио/ла позивнице';
  }

  @override
  String get c6ReportMessage => 'Пријави поруку';

  @override
  String get c6ReportTitle => 'Пријави ову поруку';

  @override
  String get c6ReportIntro =>
      'Овим се шаље само ова једна порука, са доказом да је аутентична, власницима овог сервера. Запечаћена је, па је сам сервер не може прочитати. Ништа друго из ћаскања се не шаље.';

  @override
  String get c6ReportPreviewLabel => 'Ова порука ће бити послата';

  @override
  String get c6ReportPreviewNoText =>
      'Порука без текста, на пример прилог. Шаљу се њени подаци, укључујући кључ којим се датотека отвара, али не и сама датотека.';

  @override
  String get c6ReportSend => 'Пошаљи пријаву';

  @override
  String get c6ReportSent => 'Пријава је послата.';

  @override
  String c6ReportRecipientCount(int count) {
    return 'Власника сервера који добијају копију: $count';
  }

  @override
  String get c6ReportPinTitle => 'Провери кључеве власника';

  @override
  String get c6ReportPinBody =>
      'Замоли сваког власника да ти прочита код из Подешавања, Пријаве, на свом уређају. Ако се поклапа, веруј му. Ако се не поклапа, не шаљи пријаву.';

  @override
  String c6ReportOwnerKey(String owner, String fingerprint) {
    return 'Власник $owner: $fingerprint';
  }

  @override
  String get c6ReportKeyChanged =>
      'Кључ овог власника се променио од када си му последњи пут веровао. Питај га да ли га је променио.';

  @override
  String get c6ReportKeyMissing =>
      'Власник коме си раније веровао сада не добија копију. Могуће је да га сервер задржава.';

  @override
  String get c6ReportTrust => 'Верујем, настави';

  @override
  String get c6ReportCommunityUnavailable =>
      'Пријаве модераторима заједнице још нису доступне.';

  @override
  String get c6ReportNoOwnerKey =>
      'Ниједан власник сервера још не може да прима пријаве. Замоли га да подеси кључ за пријаве.';

  @override
  String get c6ReportNotReportable =>
      'Ова порука се не може пријавити. Примљена је пре увођења пријава, послата је без доказа или је обрисана.';

  @override
  String get c6ReportKeysNotPinned =>
      'Кључ власника још није поверен. Поново отвори пријаву и провери га.';

  @override
  String get c6ReportAlready => 'Већ си пријавио ову поруку.';

  @override
  String get c6ReportUnavailable =>
      'Пријављивање није доступно у овој верзији.';

  @override
  String get c6ReportsTitle => 'Пријаве';

  @override
  String get c6ReportsSettingsDetail =>
      'Поруке које су ти људи пријавили као власнику сервера';

  @override
  String get c6ReportsKeySection => 'Кључ за пријаве';

  @override
  String get c6ReportsKeyNone =>
      'Овај уређај нема кључ за пријаве. Без њега ти нико не може слати пријаве.';

  @override
  String get c6ReportsKeyActive =>
      'Овај уређај држи твој кључ за пријаве. Прочитај његов код људима који траже да га провере.';

  @override
  String c6ReportsKeyCode(String fingerprint) {
    return 'Код: $fingerprint';
  }

  @override
  String get c6ReportsKeyCreate => 'Направи кључ за пријаве';

  @override
  String get c6ReportsKeyCreateTitle => 'Направити нови кључ за пријаве овде?';

  @override
  String get c6ReportsKeyCreateBody =>
      'Ако већ имаш кључ за пријаве на другом уређају, овај га замењује. Пријаве већ послате на стари кључ отварају се само на уређају који још држи тај кључ, а на овом су изгубљене. Људи морају да поверују новом кључу пре следеће пријаве.';

  @override
  String get c6ReportsKeyReplace => 'Замени кључ';

  @override
  String get c6ReportsKeyPublish => 'Објави кључ поново';

  @override
  String get c6ReportsKeyReady => 'Кључ за пријаве је објављен.';

  @override
  String get c6ReportsEmpty => 'Нема пријава';

  @override
  String get c6ReportsEmptyDetail =>
      'Пријаве се чувају док их не одбациш или 90 дана.';

  @override
  String get c6ReportsCommunity => 'Пријаве заједнице';

  @override
  String get c6ReportsCommunityUnavailable =>
      'Још није доступно. Пријаве модераторима стижу уз улоге у заједници.';

  @override
  String c6ReportsFiled(String when) {
    return 'Пријављено $when';
  }

  @override
  String get c6ReportsLocked => 'Не може да се отвори';

  @override
  String get c6ReportsLockedNoSeed =>
      'Овај уређај нема кључ за пријаве, па не може да отвори ову пријаву. Отвори је на уређају који је направио твој кључ.';

  @override
  String get c6ReportsLockedOtherKey =>
      'Послато на старији кључ за пријаве који овај уређај не држи.';

  @override
  String get c6ReportsLockedDamaged =>
      'Ова пријава је оштећена или није била намењена теби.';

  @override
  String get c6ReportsMessageLabel => 'Пријављена порука';

  @override
  String get c6ReportsNoText =>
      'Није текстуална порука. Њени подаци, укључујући кључ којим се датотека отвара, налазе се у пријави, али не и сама датотека.';

  @override
  String c6ReportsReporter(String account) {
    return 'Пријавио налог $account';
  }

  @override
  String c6ReportsSender(String account) {
    return 'Послао налог $account';
  }

  @override
  String get c6ReportsCheck => 'Провери према записима сервера';

  @override
  String get c6ReportsChecking => 'Проверавам…';

  @override
  String get c6ReportsCheckNote =>
      'Провером сервер сазнаје о којој се поруци ради у овој пријави.';

  @override
  String get c6VerdictVerified => 'Поклапа се са записом сервера';

  @override
  String get c6VerdictVerifiedDetail =>
      'Сервер је забележио баш ову поруку овог пошиљаоца у овом разговору. То је поуздано само колико и сопствени запис сервера.';

  @override
  String get c6VerdictMismatch => 'Не поклапа се';

  @override
  String get c6VerdictMismatchDetail =>
      'Запис сервера се не слаже са овом пријавом. Сматрај је недоказаном или лажном.';

  @override
  String get c6VerdictGone => 'Не може да се провери';

  @override
  String get c6VerdictGoneDetail =>
      'Сервер више нема ову поруку, па нема шта да се упореди.';

  @override
  String get c6VerdictUnfranked => 'Не може да се докаже';

  @override
  String get c6VerdictUnfrankedDetail =>
      'Ову поруку је послала апликација која не додаје доказ.';

  @override
  String get c6ReportsDismiss => 'Одбаци пријаву';

  @override
  String get c6ReportsDismissTitle => 'Одбацити ову пријаву?';

  @override
  String get c6ReportsDismissBody =>
      'Ово заувек уклања твоју копију. Остали власници задржавају своје.';

  @override
  String get c6ReportsDismissed => 'Пријава је одбачена.';

  @override
  String get c6ReportsKeyElsewhere =>
      'Твој кључ за пријаве је на другом уређају. Пријаве за њега се отварају тамо, не овде.';

  @override
  String get c6ReportsKeyReplacedElsewhere =>
      'Други уређај је заменио твој кључ за пријаве. Нове пријаве иду на кључ испод; овај уређај отвара само пријаве послате на његов старији кључ.';

  @override
  String get c6ReportsKeyUnpublished =>
      'Овај уређај држи кључ за пријаве који још није објављен. Објави га да би ти људи могли слати пријаве.';

  @override
  String get c6SignOutSeedWarning =>
      'Овај уређај држи твој кључ за пријаве. Одјавом се он брише, а пријаве већ послате на њега више се не могу отворити. Прво обради своје пријаве.';

  @override
  String get autoBackupTitle => 'Аутоматске резервне копије';

  @override
  String get autoBackupIntro =>
      'Сваког дана овај уређај прави резервну копију ваших разговора, закључану вашим кључем за опоравак. Само тај кључ је отвара; сервер не може. Нова копија замењује стару. Поруке које нестају се никада не копирају.';

  @override
  String get autoBackupIntroPhone =>
      'Овај телефон прави резервну копију ваших разговора када отворите апликацију, највише једном дневно, закључану вашим кључем за опоравак. Само тај кључ је отвара; сервер не може. Нова копија замењује стару. Поруке које нестају се никада не копирају.';

  @override
  String autoBackupLast(String date) {
    return 'Последња копија $date';
  }

  @override
  String get autoBackupPending => 'Прва копија још није направљена';

  @override
  String get autoBackupServerOff => 'Овај сервер има искључене резервне копије';

  @override
  String get autoBackupNoKey =>
      'Сачувајте кључ за опоравак да бисте укључили резервне копије';

  @override
  String get autoBackupNeedsKeyHere =>
      'Унесите кључ за опоравак да бисте укључили резервне копије овде';

  @override
  String get autoBackupKeyChanged =>
      'Ваш кључ за опоравак је промењен. Унесите нови кључ да би се копије наставиле овде.';

  @override
  String get autoBackupErrorNetwork =>
      'Последња копија није стигла до сервера. Покушаће поново.';

  @override
  String get autoBackupErrorSpace =>
      'Простор за копије је пун. Последња добра копија се чува.';

  @override
  String get autoBackupErrorTooLarge =>
      'Ваша историја је превелика за копију. Последња добра копија се чува.';

  @override
  String get autoBackupErrorFailed =>
      'Последња копија није успела. Покушаће поново.';

  @override
  String get autoBackupStale => 'Нема копије више од недељу дана.';

  @override
  String get autoBackupPhoneNote =>
      'Овај телефон прави копију када отворите апликацију.';

  @override
  String get autoBackupNow => 'Направи копију сада';

  @override
  String get autoBackupRunning => 'Прави се копија…';

  @override
  String get autoBackupTypeKey => 'Унесите кључ за опоравак';

  @override
  String get autoBackupKeyWrong => 'То није кључ за опоравак овог налога.';

  @override
  String get autoBackupKeyOn => 'Резервне копије су укључене на овом уређају.';

  @override
  String get autoBackupPromptMessage =>
      'Сачувајте кључ за опоравак. Укључује аутоматске резервне копије и враћа ваш налог ако изгубите све уређаје.';

  @override
  String get autoBackupPromptSave => 'Сачувај кључ';

  @override
  String get autoBackupPromptLater => 'Не сада';

  @override
  String get channelPrivate => 'Приватни канал';

  @override
  String get channelPrivateDisclosure =>
      'Само изабрани чланови виде овај канал. Сервер види ко је у њему.';

  @override
  String get channelOpenDisclosure => 'Сваки члан заједнице види овај канал.';

  @override
  String get channelCreateFailed => 'Канал није направљен. Покушајте поново.';

  @override
  String get channelMembersFailed =>
      'Канал је направљен. Неки чланови нису додати. Покушајте поново да додате само те чланове.';

  @override
  String get channelAdminOnly =>
      'Само власници и администратори могу да праве канале.';

  @override
  String get k1ConfirmTitle => 'Проверите кључ за опоравак';

  @override
  String get k1ConfirmDetail =>
      'Унесите га још једном да будете сигурни да га имате. Никад не напушта овај уређај.';

  @override
  String get k1ConfirmOk => 'То је ваш кључ за опоравак.';

  @override
  String get k1ConfirmMismatch =>
      'Не поклапа се. Ако сте изгубили кључ, направите нови у подешавањима кључа за опоравак.';

  @override
  String get k1SecondCopyChoose => 'Чувај другу копију у фасцикли';

  @override
  String k1SecondCopyFolder(String folder) {
    return 'Друга копија: $folder';
  }

  @override
  String get k1SecondCopyDetail =>
      'Иста закључана копија, сачувана где изаберете. Отвара је само кључ за опоравак.';

  @override
  String get k1SecondCopyFailed =>
      'Последње копирање у ову фасциклу није успело. Проверите фасциклу.';

  @override
  String get k1SecondCopyOff => 'Заустави другу копију';

  @override
  String get k1SecondCopyPhone =>
      'Друга копија у фасцикли је доступна на рачунару. Телефони чувају копију само на серверу.';

  @override
  String get recoveryFollowUpRestoreDetail =>
      'Пре него што замените кључ за опоравак, можете вратити историју из копија које су направили ваши изгубљени уређаји. Оне се отварају вашим старим кључем, који за њих престаје да важи кад га замените.';

  @override
  String get recoveryFollowUpRestoreSkip => 'Прескочи';

  @override
  String get recoveryFollowUpRestoreSkipWarning =>
      'Ако прескочите, старије копије постају неупотребљиве чим замените кључ за опоравак. Прескочити ипак?';

  @override
  String get k1RestoreOpen => 'Врати из резервне копије';

  @override
  String get k1RestoreTitle => 'Враћање из резервне копије';

  @override
  String get k1RestoreIntro =>
      'Изаберите копију коју је направио неки други ваш уређај и унесите кључ за опоравак. Историја се спаја са овом; поруке које већ постоје остају.';

  @override
  String get k1RestoreLoading => 'Тражим резервне копије…';

  @override
  String get k1RestoreEmpty => 'Није пронађена копија са другог уређаја.';

  @override
  String get k1RestoreLegacyRefused =>
      'Копије у старом формату (направљене пре аутоматских копија) више се не могу вратити. Нису мењане, али их апликација не отвара.';

  @override
  String get k1RestoreLoadFailed => 'Списак резервних копија није учитан.';

  @override
  String k1RestoreEntry(String device, String date) {
    return '$device · $date';
  }

  @override
  String k1RestoreEntryPrevious(String device, String date) {
    return '$device · $date (претходна копија)';
  }

  @override
  String get k1RestoreDeviceUnnamed => 'Уређај';

  @override
  String get k1RestoreDeviceRevoked =>
      'Овај уређај је уклоњен са вашег налога.';

  @override
  String get k1RestoreDone => 'Историја је враћена.';

  @override
  String get k1RestoreWrongKey =>
      'То није исправан кључ за опоравак овог налога.';

  @override
  String get k1RestoreOtherKey =>
      'Ова копија је закључана другим кључем за опоравак.';

  @override
  String get k1RestoreCorrupt =>
      'Копија се не може отворити. Можда је оштећена.';

  @override
  String get k1RestoreNetwork => 'Сервер није доступан. Ништа није промењено.';

  @override
  String get k1RestoreUnavailable => 'Овај уређај не може да врати копију.';

  @override
  String get connectSignInPasskey => 'Пријава приступним кључем';

  @override
  String get passkeySignInFailed =>
      'Пријава приступним кључем није успела. Покушајте поново или користите лозинку.';

  @override
  String get passkeyUnavailable =>
      'Приступни кључеви нису доступни на овом уређају или нису подешени за овај сервер.';

  @override
  String get passkeyPinRefused =>
      'Сервер је затражио приступни кључ за другу адресу, па га апликација одбија.';

  @override
  String get apiErrorPasskeyLimit =>
      'Достигли сте границу броја приступних кључева. Прво уклоните један.';

  @override
  String get apiErrorPasskeyExists => 'Овај приступни кључ је већ додат.';

  @override
  String get apiErrorInvalidPasskey =>
      'Сервер није могао да провери тај приступни кључ.';

  @override
  String get apiErrorPasskeysOff => 'Овај сервер не нуди приступне кључеве.';

  @override
  String get settingsPasskeys => 'Приступни кључеви';

  @override
  String get settingsPasskeysDetail =>
      'Пријава закључавањем екрана уместо лозинке';

  @override
  String get passkeysIntro =>
      'Приступни кључ вас пријављује на овом уређају уместо лозинке. За промене подешавања и даље се тражи лозинка. Услуга која чува ваш приступни кључ, на пример Google или Apple, сазнаје адресу овог сервера.';

  @override
  String get passkeysNotOffered =>
      'Приступни кључеви нису доступни за овај сервер на овом уређају.';

  @override
  String get passkeysEmpty => 'Још нема приступних кључева.';

  @override
  String get passkeysAdd => 'Додај приступни кључ';

  @override
  String get passkeysAdded => 'Приступни кључ је додат.';

  @override
  String passkeyCreated(String date) {
    return 'Додат $date';
  }

  @override
  String passkeyLastUsed(String date) {
    return 'Последња употреба $date';
  }

  @override
  String get passkeyBackedUp => 'Резервна копија постоји';

  @override
  String get passkeyRename => 'Преименуј';

  @override
  String get passkeyRemove => 'Уклони';

  @override
  String get passkeyNameLabel => 'Назив';

  @override
  String get passkeyRemoveTitle => 'Уклонити овај приступни кључ?';

  @override
  String passkeyRemoveBody(String name) {
    return '„$name” се више неће пријављивати на овај налог. Можете га поново додати касније.';
  }

  @override
  String get passkeyRemoved => 'Приступни кључ је уклоњен.';

  @override
  String get passkeyNoticeAdded =>
      'Приступни кључ је додат вашем налогу. Нисте ви? Промените лозинку.';

  @override
  String get passkeyNoticeRemoved =>
      'Приступни кључ је уклоњен са вашег налога.';

  @override
  String get passkeyNoticeDismiss => 'Одбаци';

  @override
  String get passkeyNamePrefix => 'Приступни кључ';

  @override
  String get settingsAccounts => 'Налози';

  @override
  String get settingsAccountsDetail =>
      'Пребацивање између налога на овом уређају';

  @override
  String get accountsTitle => 'Налози';

  @override
  String get accountsIntro =>
      'Један налог је отворен у исто време. Остали су паузирани: за њих не стижу поруке ни обавештења док се на њих не пребаците.';

  @override
  String get accountsOpenNow => 'Отворен';

  @override
  String get accountsPending => 'Још није пријављен';

  @override
  String get accountsRemoving => 'Уклањање…';

  @override
  String get accountsNewAccount => 'Нови налог';

  @override
  String get accountsAdd => 'Додај налог';

  @override
  String accountsFull(String count) {
    return 'Овај уређај држи $count налога, највише што може. Уклоните један да бисте додали други.';
  }

  @override
  String get accountsSameServer =>
      'Овај сервер може да закључи да су ови налози на истом уређају.';

  @override
  String get accountsSwitching => 'Пребацивање…';

  @override
  String accountsSwitchTo(String name) {
    return 'Пребаци на $name';
  }

  @override
  String get accountsRemove => 'Уклони са овог уређаја';

  @override
  String accountsRemoveTitle(String name) {
    return 'Уклонити $name са овог уређаја?';
  }

  @override
  String get accountsRemoveBody =>
      'Налог се одјављује, а његове поруке и кључеви бришу са овог уређаја. Налог остаје на свом серверу. Ако више нећете користити овај уређај, уклоните га са листе уређаја налога на другом уређају.';

  @override
  String get accountsPushFailTitle => 'Ипак пребацити?';

  @override
  String accountsPushFailBody(String name) {
    return 'Обавештења за $name нису могла да се искључе. Можда ћете добијати обавештења за овај налог док га поново не отворите.';
  }

  @override
  String get accountsSwitchAnyway => 'Ипак пребаци';

  @override
  String get accountsErrorOpen =>
      'Тај налог није могао да се отвори. Претходни налог је поново отворен.';

  @override
  String get accountsErrorRegistry => 'Списак налога није могао да се сачува.';

  @override
  String get accountsErrorRemove =>
      'Налог није могао да се уклони. Покушајте поново.';

  @override
  String get accountsDuplicate =>
      'Овај уређај већ има тај налог, па је додатна пријава уклоњена. Уклоните вишак уређаја са листе уређаја налога.';

  @override
  String get accountsBack => 'Назад на моје налоге';

  @override
  String get settingsSectionUpdates => 'Ажурирања';

  @override
  String get settingsAutoUpdateCheck => 'Аутоматски проверавај ажурирања';

  @override
  String get settingsAutoUpdateCheckDetail =>
      'Проверавај нове верзије при покретању';

  @override
  String get settingsCheckForUpdates => 'Провери ажурирања';

  @override
  String get settingsCheckingForUpdates => 'Провера ажурирања…';

  @override
  String get settingsUpdateUpToDate => 'Veritra је ажурирана';

  @override
  String settingsUpdateAvailable(String version) {
    return 'Верзија $version је доступна';
  }

  @override
  String get settingsUpdateError => 'Провера ажурирања није успела';

  @override
  String get settingsUpdateDisabled =>
      'Аутоматска провера ажурирања је искључена';

  @override
  String get settingsScreenGuard => 'Заштита екрана';

  @override
  String get settingsScreenGuardDetail =>
      'Блокирај снимке екрана и читање екрана од стране AI асистената у ћаскањима.';

  @override
  String get communityInfoTitle => 'Категорије и иконица';

  @override
  String get communityIconChoose => 'Изабери иконицу';

  @override
  String get communityIconRemove => 'Уклони иконицу';

  @override
  String get communityCategories => 'Категорије';

  @override
  String get communityCategoryNew => 'Нова категорија';

  @override
  String get communityCategoryName => 'Назив категорије';

  @override
  String get communityCategoryRename => 'Преименуј категорију';

  @override
  String get communityCategoryDelete => 'Обриши категорију';

  @override
  String get communityCategoryDeleteConfirm =>
      'Обрисати ову категорију? Њени канали остају и приказују се без категорије.';

  @override
  String get communityCategoryPlaceholder => 'Категорија';

  @override
  String get communityCategoryNone => 'Без категорије';

  @override
  String get communityChannelPlaces => 'Где су канали';

  @override
  String get communityInfoSaveFailed => 'Чување није успело. Покушај поново.';

  @override
  String get communityInfoOpen => 'Категорије и иконица';

  @override
  String get rolesTitle => 'Улоге';

  @override
  String get rolesDetail => 'Проверава апликација сваког члана, а не сервер.';

  @override
  String get rolesNoRecord =>
      'Ова група је направљена пре проверених улога, па су приказане улоге оне које каже сервер.';

  @override
  String get rolesUnavailable =>
      'Улоге тренутно не могу да се прочитају на овом уређају.';

  @override
  String rolesYou(String name) {
    return '$name (ти)';
  }

  @override
  String get rolesElector => 'Гласа за новог власника';

  @override
  String get rolesMakeAdmin => 'Постави за администратора';

  @override
  String get rolesMakeModerator => 'Постави за модератора';

  @override
  String get rolesMakeMember => 'Врати у члана';

  @override
  String get rolesStepDown => 'Одступи';

  @override
  String get rolesElectorOn => 'Дозволи гласање за новог власника';

  @override
  String get rolesElectorOff => 'Забрани гласање за новог власника';

  @override
  String get rolesTransfer => 'Предај власништво';

  @override
  String rolesTransferConfirm(String name) {
    return 'Предати ову групу кориснику $name? Ти постајеш администратор.';
  }

  @override
  String get rolesOwnership => 'Власништво';

  @override
  String rolesElectionOpen(String votes, String total) {
    return 'Избор власника је у току. Гласова: $votes од $total.';
  }

  @override
  String get rolesElectionNone =>
      'Ако власник није ту дуже од 30 дана, администратори могу да изаберу новог.';

  @override
  String get rolesStartElection => 'Покрени избор власника';

  @override
  String rolesVoteFor(String name) {
    return 'Гласај за: $name';
  }

  @override
  String get rolesCloseElection => 'Заврши избор';

  @override
  String get rolesOwnerCancelNote =>
      'Ти си власник: твоја апликација сама завршава овај избор.';

  @override
  String get rolesOnlyAdminsPost => 'Само администратори објављују';
}

/// The translations for Serbian, using the Latin script (`sr_Latn`).
class AppLocalizationsSrLatn extends AppLocalizationsSr {
  AppLocalizationsSrLatn() : super('sr_Latn');

  @override
  String get commonCancel => 'Otkaži';

  @override
  String get commonContinue => 'Nastavi';

  @override
  String get commonCreate => 'Napravi';

  @override
  String get commonRefresh => 'Osveži';

  @override
  String get commonRevoke => 'Opozovi';

  @override
  String get listTimeYesterday => 'Juče';

  @override
  String get validationNameRequired => 'Unesite naziv.';

  @override
  String get validationNameTooLong => 'Taj naziv je predugačak.';

  @override
  String get validationGroupNameRequired => 'Unesite naziv grupe.';

  @override
  String get validationGroupNameTooLong => 'Taj naziv grupe je predugačak.';

  @override
  String get validationMessageTooLong =>
      'Predugačko za slanje. Skratite poruku ili je podelite na više poruka.';

  @override
  String get gatedAttachmentsUnavailable =>
      'Prilozi zahtevaju mehanizam za šifrovanje koji je prošao reviziju';

  @override
  String get confirmCancel => 'Otkaži';

  @override
  String get appearanceSystem => 'Sistemski';

  @override
  String get appearanceLight => 'Svetli';

  @override
  String get appearanceDark => 'Tamni';

  @override
  String aboutLegalese(String license, String url) {
    return 'Slobodan softver pod licencom GNU Affero General Public License, verzija 3 ili novija ($license). Izvorni kod: $url';
  }

  @override
  String aboutTitle(String productName) {
    return 'O aplikaciji $productName';
  }

  @override
  String aboutVersion(String version, String license) {
    return 'Verzija $version · $license';
  }

  @override
  String get aboutLicenses => 'Licence otvorenog koda';

  @override
  String get aboutLicensesDetail =>
      'Napomene o licencama za Veritra i njene komponente';

  @override
  String get settingsTitle => 'Podešavanja';

  @override
  String get settingsSectionAccount => 'Nalog';

  @override
  String get settingsSectionDevices => 'Uređaji';

  @override
  String get settingsSectionSafety => 'Bezbednost';

  @override
  String get settingsSectionYourData => 'Vaši podaci';

  @override
  String get settingsSectionNotifications => 'Obaveštenja';

  @override
  String get settingsSectionSession => 'Sesija';

  @override
  String get settingsSectionRecovery => 'Oporavak';

  @override
  String get settingsSectionComingSoon => 'Uskoro';

  @override
  String get settingsSectionAppearance => 'Izgled';

  @override
  String get settingsHideNotificationPreview => 'Sakrij pregled poruke';

  @override
  String get settingsHideNotificationPreviewDetail =>
      'Obaveštenja prikazuju „Nova poruka“ bez pošiljaoca i teksta.';

  @override
  String get notificationNewMessage => 'Nova poruka';

  @override
  String get trayOpen => 'Otvori';

  @override
  String get trayQuit => 'Zatvori aplikaciju';

  @override
  String get settingsSectionPrivacy => 'Privatnost';

  @override
  String get settingsReadReceiptsTitle => 'Potvrde o čitanju';

  @override
  String get settingsReadReceiptsDetail =>
      'Važi za sve vaše uređaje. Kada je isključeno, ne šaljete potvrde o čitanju i ne vidite kada su drugi pročitali vaše poruke. Oznake poslato i dostavljeno ostaju.';

  @override
  String get settingsReadReceiptsFailed =>
      'Podešavanje nije moglo da se promeni. Proverite vezu i pokušajte ponovo.';

  @override
  String get settingsReadReceiptsNotSaved =>
      'Ovaj uređaj nije mogao da sačuva podešavanje. Važi za sada, ali može da se vrati kada se aplikacija ponovo pokrene.';

  @override
  String get settingsSectionAbout => 'O aplikaciji';

  @override
  String get settingsSectionDangerZone => 'Opasna zona';

  @override
  String get settingsAccountId => 'ID naloga';

  @override
  String get settingsAccountIdUnknown => 'Nepoznato';

  @override
  String get settingsCopyAccountId => 'Kopiraj ID naloga';

  @override
  String settingsCopied(String label) {
    return 'Kopirano: $label.';
  }

  @override
  String get settingsChangePassword => 'Promeni lozinku';

  @override
  String get settingsChangePasswordDetail =>
      'Završava sesije na vašim drugim uređajima';

  @override
  String get settingsInvites => 'Pozivnice';

  @override
  String get settingsInvitesDetail =>
      'Napravite kodove da bi se drugi pridružili';

  @override
  String get settingsLinkDevice => 'Poveži novi uređaj';

  @override
  String get settingsLinkDeviceDetail =>
      'Generišite kod za uparivanje za drugi uređaj';

  @override
  String get settingsDeviceListSetup => 'Odobrite svoje uređaje';

  @override
  String get settingsDeviceListSetupDetail =>
      'Vaši kontakti ne mogu da dodaju vaše uređaje u ćaskanja dok ne potvrdite koji su vaši.';

  @override
  String get settingsRecoveryRetype =>
      'Ponovo unesite ključ za oporavak da biste dovršili oporavak';

  @override
  String get settingsRecoveryRetypeDetail =>
      'Vaši kontakti ne mogu da dodaju ovaj uređaj u ćaskanja dok to ne uradite.';

  @override
  String get settingsRecoveryConfirm =>
      'Potvrdite ključ za oporavak da bi oporavak i dalje radio';

  @override
  String get settingsRecoveryConfirmDetail =>
      'Vaš ključ za oporavak je postavljen pre lista odobrenih uređaja. Unesite ga jednom, inače će oporavak naloga njime biti odbijen.';

  @override
  String get deviceListReviewTitle => 'Koji uređaji su vaši?';

  @override
  String get deviceListReviewBody =>
      'Uklonite oznaku sa svakog uređaja koji ne prepoznajete. Označeni postaju vaši odobreni uređaji, a ostali se odjavljuju.';

  @override
  String get deviceListReviewConfirm => 'Odobri';

  @override
  String get settingsLoadingDevices => 'Učitavanje uređaja…';

  @override
  String get settingsBlockedAccounts => 'Blokirani nalozi';

  @override
  String get settingsBlockedNone => 'Niko nije blokiran';

  @override
  String settingsBlockedCount(int count) {
    return 'Blokirano: $count';
  }

  @override
  String get settingsBlockedReview => 'Pregledajte i poništite blokiranja';

  @override
  String get settingsExport => 'Izvezi podatke naloga';

  @override
  String get settingsExportDetail =>
      'Sačuvajte šifrovane poruke i metapodatke naloga lokalno';

  @override
  String get settingsExportFailed => 'Izvoz naloga nije uspeo.';

  @override
  String get settingsExportSaved => 'Izvoz naloga je sačuvan lokalno.';

  @override
  String get settingsAllowNotifications => 'Dozvoli obaveštenja';

  @override
  String get settingsAllowNotificationsDetail =>
      'Obaveštenja kažu samo da je stigla poruka.';

  @override
  String get settingsPushProvider => 'Push dobavljač';

  @override
  String get settingsPushProviderDetail =>
      'Izaberite UnifiedPush dobavljača za Android';

  @override
  String get settingsTestPush => 'Pošalji probno obaveštenje';

  @override
  String get settingsTestPushUnavailable =>
      'Dostupno kada se ovaj uređaj registruje';

  @override
  String settingsTestPushRegistered(String provider) {
    return 'Registrovano: $provider';
  }

  @override
  String get settingsSignOut => 'Odjavi se';

  @override
  String get settingsSignOutOthers => 'Odjavi druge uređaje';

  @override
  String get settingsSignOutOthersDetail => 'Završava sve sesije osim ove';

  @override
  String get settingsBackup => 'Šifrovana rezervna kopija';

  @override
  String get settingsBackupDetail => 'Rezervna kopija i kod za oporavak';

  @override
  String get settingsRecoveryComingSoon => 'Oporavak';

  @override
  String get settingsRecoveryComingSoonDetail =>
      'Šifrovana rezervna kopija i ključ za oporavak';

  @override
  String get settingsCallsComingSoon => 'Pozivi';

  @override
  String get settingsCallsComingSoonDetail => 'Audio i video pozivi 1:1';

  @override
  String get settingsDeleteAccount => 'Izbriši nalog';

  @override
  String get settingsDeleteAccountDetail =>
      'Onemogućava prijavljivanje i opoziva vaše uređaje. Neki šifrovani zapisi mogu ostati u skladu sa pravilima čuvanja na serveru.';

  @override
  String get settingsSignedIn => 'Prijavljeni ste';

  @override
  String get settingsRevokeDeviceTitle => 'Opozvati uređaj?';

  @override
  String settingsRevokeDeviceMessage(String deviceName) {
    return '„$deviceName“ će odmah izgubiti pristup.';
  }

  @override
  String get settingsSignOutTitle => 'Odjaviti se?';

  @override
  String get settingsSignOutMessage =>
      'Ovaj uređaj prestaje da prima poruke dok se ponovo ne prijavite lozinkom.';

  @override
  String get settingsSignOutOthersTitle => 'Odjaviti druge uređaje?';

  @override
  String get settingsSignOutOthersMessage =>
      'Sve sesije osim ove biće završene.';

  @override
  String get settingsSignOutOthersConfirm => 'Odjavi ostale';

  @override
  String get settingsDeleteAccountTitle => 'Izbrisati nalog?';

  @override
  String get settingsDeleteAccountMessage =>
      'Ovo onemogućava vaš nalog, završava njegove sesije i opoziva njegove uređaje. Šifrovane poruke i drugi zapisi mogu ostati u skladu sa pravilima servera o čuvanju podataka.';

  @override
  String get settingsDeleteAccountConfirm => 'Onemogući nalog';

  @override
  String get settingsReauthTitle => 'Potvrdite lozinku';

  @override
  String get settingsReauthField => 'Trenutna lozinka';

  @override
  String get settingsNewPassword => 'Nova lozinka';

  @override
  String get settingsNewPasswordHelper => 'Najmanje 12 znakova.';

  @override
  String get settingsConfirmNewPassword => 'Potvrdite novu lozinku';

  @override
  String get settingsPasswordsMismatch => 'Lozinke se ne podudaraju.';

  @override
  String get settingsChangePasswordConfirm => 'Promeni';

  @override
  String get settingsPasswordChanged =>
      'Lozinka je promenjena. Vaši drugi uređaji su odjavljeni.';

  @override
  String get settingsPasswordRequired => 'Unesite novu lozinku.';

  @override
  String get settingsPasswordTooShort => 'Koristite najmanje 12 znakova.';

  @override
  String get settingsPasswordTooLong =>
      'Ta lozinka je predugačka. Koristite kraću.';

  @override
  String get settingsPushDesktopTitle =>
      'Obaveštenja na računaru još nisu dostupna';

  @override
  String get settingsPushDesktopDetail =>
      'Poruke stižu dok aplikacija radi, čak i u pozadini.';

  @override
  String get settingsPushServerDisabledTitle =>
      'Ovaj server nema push dobavljača';

  @override
  String get settingsPushServerDisabledDetail =>
      'Operater servera nije podesio push obaveštenja. Poruke stižu dok je aplikacija otvorena.';

  @override
  String get settingsPushRegisteringTitle => 'Podešavanje push obaveštenja';

  @override
  String get settingsPushRegisteringDetail =>
      'Čeka se da se ovaj uređaj registruje.';

  @override
  String get settingsPushNoDistributorTitle =>
      'Nije registrovan nijedan push distributer';

  @override
  String get settingsPushNoDistributorDetail =>
      'Instalirajte UnifiedPush distributer i izaberite ga ispod, inače će poruke stizati samo dok je aplikacija otvorena.';

  @override
  String get settingsPushFailedTitle => 'Registracija za push nije uspela';

  @override
  String get settingsPushFailedDetail =>
      'Ovaj uređaj nije uspeo da se registruje za push obaveštenja. Pokušaće ponovo pri sledećem pokretanju aplikacije.';

  @override
  String get settingsPushDeniedTitle => 'Obaveštenja su isključena';

  @override
  String get settingsPushDeniedDetail =>
      'Aplikacija se i dalje sinhronizuje kada se probudi, ali ništa ne prikazuje. Dozvolite obaveštenja za Veritra u sistemskim podešavanjima.';

  @override
  String get settingsPushNotAllowedTitle => 'Obaveštenja još nisu dozvoljena';

  @override
  String get settingsPushNotAllowedDetail =>
      'Dozvolite obaveštenja ispod da biste bili obaveštavani. Do tada se aplikacija sinhronizuje kada se probudi, ali ništa ne prikazuje.';

  @override
  String get settingsPushUnconfirmedTitle => 'Obaveštenja se ne mogu potvrditi';

  @override
  String get settingsPushUnconfirmedDetail =>
      'Ovaj uređaj nije potvrdio da su obaveštenja dozvoljena, pa možda ništa neće biti prikazano. Proverite sistemska podešavanja za Veritra.';

  @override
  String get settingsPushActiveTitle => 'Push obaveštenja su aktivna';

  @override
  String get settingsPushActiveDetail =>
      'Obaveštenja nikada ne sadrže tekst poruke niti imena pošiljalaca.';

  @override
  String settingsDeviceLastSeen(String time) {
    return 'Poslednja aktivnost: $time';
  }

  @override
  String settingsDeviceAdded(String date) {
    return 'Dodat $date';
  }

  @override
  String get settingsDeviceRevoked => 'Opozvan';

  @override
  String get settingsDeviceCurrent => 'Ovaj uređaj';

  @override
  String get backupReplaceTitle => 'Zameniti rezervnu kopiju?';

  @override
  String get backupReplaceMessage =>
      'Prethodna rezervna kopija i njen kod za oporavak prestaće da rade. Novi kod čuvajte na bezbednom mestu.';

  @override
  String get backupReplaceConfirm => 'Zameni rezervnu kopiju';

  @override
  String get inviteRevokeTitle => 'Opozvati pozivnicu?';

  @override
  String inviteRevokeMessage(String code) {
    return 'Kod $code odmah prestaje da radi. Osobe koje su se već pridružile pomoću njega zadržavaju svoje naloge.';
  }

  @override
  String get connectFreshInstanceTitle => 'Otkrivena je nova instanca';

  @override
  String get connectFreshInstanceMessage =>
      'Nalog vlasnika još ne postoji — napravite ga ispod.';

  @override
  String get connectInstanceUrl => 'URL instance';

  @override
  String get connectCheckApproval => 'Proveri odobrenje';

  @override
  String get connectLinkInstead => 'Umesto toga poveži ovaj uređaj';

  @override
  String get connectOtherWays => 'Drugi načini povezivanja';

  @override
  String get connectRestoreBackup => 'Vrati iz rezervne kopije';

  @override
  String get connectLinkCode => 'Kod za povezivanje';

  @override
  String get connectLinkCodeRequired =>
      'Unesite kod za povezivanje sa postojećeg uređaja.';

  @override
  String get connectLinkCodeHint => 'Iz Podešavanja → Poveži novi uređaj';

  @override
  String get connectScanQr => 'Skeniraj QR kod';

  @override
  String get connectVerificationTitle => 'Verifikacioni kod';

  @override
  String get connectVerificationMessage =>
      'Potvrdite ovaj kod na svom već povezanom uređaju, a zatim proverite odobrenje ispod.';

  @override
  String get connectInviteCode => 'Kod pozivnice';

  @override
  String get connectInviteCodeRequired =>
      'Unesite kod pozivnice koji ste dobili.';

  @override
  String get connectInviteCodeHint => 'Od administratora ove instance';

  @override
  String get connectUsername => 'Korisničko ime';

  @override
  String get connectUsernameRequired => 'Unesite korisničko ime.';

  @override
  String get connectUsernameHint => 'Vaše ime na ovoj instanci';

  @override
  String get connectPassword => 'Lozinka';

  @override
  String get connectPasswordHint => 'Najmanje 12 znakova';

  @override
  String get connectHidePassword => 'Sakrij lozinku';

  @override
  String get connectShowPassword => 'Prikaži lozinku';

  @override
  String get connectConfirmPassword => 'Potvrdite lozinku';

  @override
  String get connectConfirmPasswordHint => 'Ponovite lozinku';

  @override
  String get connectSetupToken => 'Token za podešavanje';

  @override
  String get connectSetupTokenHint =>
      'Obavezan, osim pri povezivanju preko loopback adrese';

  @override
  String get connectUrlRequired => 'Unesite URL instance.';

  @override
  String get connectUrlInvalid =>
      'Unesite pun URL, npr. https://chat.example.org';

  @override
  String get connectUrlOriginOnly =>
      'Unesite samo osnovnu adresu servera (origin), npr. https://chat.example.org';

  @override
  String get connectUrlHttpsRequired =>
      'Veritra zahteva HTTPS. Koristite https:// adresu servera.';

  @override
  String get connectUrlLoopbackOnly =>
      'Koristite https://, ili http:// samo za ovaj računar (localhost ili 127.0.0.1).';

  @override
  String get connectPasswordRequired => 'Unesite lozinku.';

  @override
  String get connectModeOwnerTitle => 'Napravite nalog vlasnika';

  @override
  String get connectModeSignInTitle => 'Prijava';

  @override
  String get connectModeJoinTitle => 'Pridružite se uz pozivnicu';

  @override
  String get connectModeLinkTitle => 'Povežite ovaj uređaj';

  @override
  String get connectModeOwnerDetail =>
      'Samo pri prvom pokretanju: napravite nalog vlasnika na novoj instanci koju sami hostujete.';

  @override
  String get connectModeSignInDetail =>
      'Prijavite se lozinkom na uređaju koji je već povezan sa vašim nalogom.';

  @override
  String get connectModeJoinDetail =>
      'Registracija je moguća samo uz pozivnicu. Unesite kod pozivnice koji ste dobili od administratora.';

  @override
  String get connectModeLinkDetail =>
      'Unesite kod za povezivanje generisan na postojećem uređaju (Podešavanja → Poveži novi uređaj).';

  @override
  String get connectNotDeviceLinkQr =>
      'To nije Veritra QR kod za povezivanje uređaja.';

  @override
  String get connectOriginFilled =>
      'Adresa servera je popunjena. Proverite je pre nego što nastavite.';

  @override
  String get connectConfirmServerTitle => 'Potvrdite server';

  @override
  String connectConfirmServerMessage(String origin) {
    return 'Ovaj QR kod predlaže $origin. Aplikacija će ipak proveriti server pre nego što ga upotrebi. Nastaviti sa ovom HTTPS adresom?';
  }

  @override
  String get connectUseOrigin => 'Koristi adresu';

  @override
  String get connectSubmitOwner => 'Napravi vlasnika';

  @override
  String get connectSubmitSignIn => 'Prijavi se';

  @override
  String get connectSubmitJoin => 'Pridruži se uz pozivnicu';

  @override
  String get connectSubmitLink => 'Iskoristi kod';

  @override
  String get connectTagline =>
      'Samostalno hostovana razmena poruka, šifrovana s kraja na kraj';

  @override
  String get qrScanLinkTitle => 'Skeniraj QR kod za povezivanje';

  @override
  String get qrToggleTorch => 'Uključi ili isključi lampu';

  @override
  String get qrSwitchCamera => 'Promeni kameru';

  @override
  String get qrPointCamera =>
      'Usmerite kameru ka QR kodu na postojećem uređaju (Podešavanja → Poveži novi uređaj).';

  @override
  String get qrPermissionDenied =>
      'Za skeniranje je potrebna dozvola za kameru. Omogućite je u sistemskim podešavanjima ili ručno unesite kod za povezivanje.';

  @override
  String get qrUnsupported =>
      'Ovaj uređaj ne može da skenira QR kodove. Ručno unesite kod za povezivanje.';

  @override
  String get qrCameraFailed =>
      'Kamera nije mogla da se pokrene. Ručno unesite kod za povezivanje.';

  @override
  String get qrEnterManually => 'Unesi kod ručno';

  @override
  String get newConversationTitle => 'Novi razgovor';

  @override
  String get newConversationDirect => 'Direktna poruka';

  @override
  String get newConversationGroup => 'Grupa';

  @override
  String get newConversationGroupName => 'Naziv grupe';

  @override
  String get newConversationWho => 'Kome želite da pišete?';

  @override
  String get newConversationAddMembers => 'Dodaj članove';

  @override
  String get newConversationStartDm => 'Započni razgovor';

  @override
  String get newConversationCreateGroup => 'Napravi grupu';

  @override
  String get newConversationPickPerson => 'Prvo izaberite osobu kojoj pišete.';

  @override
  String get newConversationAddOneMember => 'Dodajte bar još jednog člana.';

  @override
  String get blockedEmptyTitle => 'Nema blokiranih naloga';

  @override
  String get blockedEmptyMessage =>
      'Blokirajte nalog iz direktne poruke da bi server prestao da vam dostavlja poruke tog naloga.';

  @override
  String get blockedLabel => 'Blokiran';

  @override
  String blockedOn(String date) {
    return 'Blokiran $date';
  }

  @override
  String get blockedUnblock => 'Deblokiraj';

  @override
  String blockedUnblocked(String label) {
    return 'Nalog $label je deblokiran.';
  }

  @override
  String blockedUnblockFailed(String label) {
    return 'Deblokiranje naloga $label nije uspelo.';
  }

  @override
  String get blockedLoadFailed => 'Učitavanje blokiranih naloga nije uspelo';

  @override
  String get commonRetry => 'Pokušaj ponovo';

  @override
  String get accountPickerHelper =>
      'Unesite tačno korisničko ime ili nalepite ID naloga (acct_…).';

  @override
  String get accountPickerNoMatch =>
      'Nije pronađen nalog sa tačno tim korisničkim imenom.';

  @override
  String get searchHint => 'Pretražite osobe, zajednice, kanale…';

  @override
  String get searchClear => 'Obriši pretragu';

  @override
  String get searchIntroTitle => 'Pretraga metapodataka';

  @override
  String get searchIntroMessage =>
      'Pronađite osobe po tačnom korisničkom imenu, kao i zajednice i kanale po nazivu. Sadržaj poruka je šifrovan s kraja na kraj i na serveru se nikada ne može pretraživati.';

  @override
  String get searchNoResultsTitle => 'Nema rezultata';

  @override
  String get searchNoResultsMessage =>
      'Ništa se ne podudara. Korisnička imena moraju se tačno podudarati, a sadržaj poruka se nikada ne može pretraživati.';

  @override
  String get searchNoOpenChannel => 'Još nema kanala koji možete da otvorite';

  @override
  String get searchJoinCommunity =>
      'Pridružite se zajednici da biste je otvorili';

  @override
  String get searchTypeConversation => 'Razgovor';

  @override
  String get searchTypeCommunity => 'Zajednica';

  @override
  String get searchTypeChannel => 'Kanal';

  @override
  String get searchTypeAccount => 'Nalog';

  @override
  String searchUnblockAccount(String label) {
    return 'Deblokiraj $label';
  }

  @override
  String searchBlockAccount(String label) {
    return 'Blokiraj $label';
  }

  @override
  String searchBlocked(String label) {
    return 'Nalog $label je blokiran.';
  }

  @override
  String get searchBlockFailed => 'Blokiranje nije moglo da se ažurira.';

  @override
  String get inviteCreateSection => 'Napravite pozivnicu';

  @override
  String get inviteMaxUses => 'Najviše korišćenja';

  @override
  String inviteMaxUsesOption(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get inviteExpires => 'Ističe';

  @override
  String durationDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString dana',
      few: '$countString dana',
      one: '$countString dan',
    );
    return '$_temp0';
  }

  @override
  String get inviteCreate => 'Napravi pozivnicu';

  @override
  String get inviteEmptyTitle => 'Još nema pozivnica';

  @override
  String get inviteEmptyMessage =>
      'Kodovi pozivnica koje napravite pojavljuju se ovde. Delite ih preko bezbednog kanala.';

  @override
  String get inviteLoadFailed =>
      'Vaše pozivnice nisu mogle da se učitaju. Proverite vezu i pokušajte ponovo.';

  @override
  String get inviteYourInvites => 'Vaše pozivnice';

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

    return 'Iskorišćeno $usesString od $maxUsesString';
  }

  @override
  String get inviteNeverExpires => 'Nikada ne ističe';

  @override
  String inviteExpiresAt(String time) {
    return 'Ističe $time';
  }

  @override
  String get inviteActions => 'Radnje za pozivnicu';

  @override
  String get inviteCodeCopied => 'Kod pozivnice je kopiran.';

  @override
  String get inviteCopyCode => 'Kopiraj kod';

  @override
  String get profileThisInstance => 'ova instanca';

  @override
  String get profileTitle => 'Profil';

  @override
  String get profileYourAccount => 'Vaš nalog';

  @override
  String get profileDisplaySection => 'Prikazno ime i slika';

  @override
  String get profileDisplayNameLabel => 'Prikazno ime';

  @override
  String get profileDisplayNameHint =>
      'Kako vas vide ljudi sa kojima razgovarate';

  @override
  String get profileDisplayHelp =>
      'Ime i sliku vide samo ljudi sa kojima delite razgovor. Server ih ne može pročitati.';

  @override
  String get profileEditTile => 'Ime i slika';

  @override
  String get profileEditTitle => 'Ime i slika';

  @override
  String get profilePhotoChoose => 'Izaberi sliku';

  @override
  String get profilePhotoRemove => 'Ukloni sliku';

  @override
  String get profilePhotoUnusable =>
      'Ova slika se ne može koristiti. Probajte drugu.';

  @override
  String get profileSave => 'Sačuvaj';

  @override
  String get profileSaved => 'Sačuvano';

  @override
  String get profileSaveConflict =>
      'Ovaj profil je promenjen na drugom uređaju. Pokušajte ponovo za trenutak.';

  @override
  String get profileSaveInvalid => 'To ime ili slika se ne mogu koristiti.';

  @override
  String profileNameTooLong(int max) {
    return 'Najviše $max znakova.';
  }

  @override
  String get profileNameInvalid =>
      'Koristite slova i brojeve; bez kontrolnih znakova i znakova smera.';

  @override
  String get groupProfileTitle => 'Ime i slika grupe';

  @override
  String get groupProfileNameLabel => 'Ime grupe';

  @override
  String get groupProfileHelp =>
      'Članovi ove grupe vide njeno ime i sliku. Server ih ne može pročitati.';

  @override
  String get profileBlockNote =>
      'U grupama koje delite, možda i dalje vide vaš profil.';

  @override
  String get profileSectionIdentity => 'Identitet';

  @override
  String get profileNotAvailable => 'Nije dostupno';

  @override
  String get profileCurrentDevice => 'Trenutni uređaj';

  @override
  String get profileInstanceRole => 'Uloga na instanci';

  @override
  String get profileSectionEncryption => 'Šifrovanje';

  @override
  String get profileEncryptionPending =>
      'Identitet za šifrovanje još nije spreman';

  @override
  String get profileEncryptionPendingDetail =>
      'Provera bezbednosnog broja i izmena profila ostaju nedostupne dok ne bude objavljen mehanizam za šifrovanje koji je prošao reviziju.';

  @override
  String profileCopyLabel(String label) {
    return 'Kopiraj: $label';
  }

  @override
  String get navChats => 'Ćaskanja';

  @override
  String get navCommunities => 'Zajednice';

  @override
  String get shellNoConversationTitle => 'Nije izabran nijedan razgovor';

  @override
  String get shellNoConversationMessage =>
      'Izaberite razgovor sa liste da biste ga čitali ovde.';

  @override
  String get shellRestoring => 'Vraćanje ovog uređaja…';

  @override
  String get shellResetTitle => 'Resetovati ovaj uređaj?';

  @override
  String get shellResetMessage =>
      'Ovaj uređaj će biti prazan i mora ponovo da se poveže. Njegove trenutne poruke ovde ostaju nečitljive; sklanjaju se u stranu, a ne brišu, za slučaj da se ključ vrati.';

  @override
  String get shellResetConfirm => 'Resetuj';

  @override
  String get shellRecoveryTitle => 'Potreban je oporavak uređaja';

  @override
  String get shellRecoveryFallback =>
      'Ovom uređaju je potrebna pažnja pre nego što može da se koristi.';

  @override
  String get shellRetryRestore => 'Ponovo pokušaj vraćanje';

  @override
  String get shellContinueToSignIn => 'Nastavi na prijavu';

  @override
  String get shellResetDevice => 'Resetuj ovaj uređaj';

  @override
  String get communityNew => 'Nova zajednica';

  @override
  String get communityEmptyTitle => 'Još nema zajednica';

  @override
  String get communityEmptyMessage =>
      'Napravite zajednicu da okupite ljude oko zajedničkih kanala — podrazumevano privatno, svuda šifrovano.';

  @override
  String get communityOtherChannels => 'Drugi kanali u kojima ste';

  @override
  String get communityChannelSubtitle => 'Kanal zajednice';

  @override
  String get communityName => 'Naziv zajednice';

  @override
  String communityNewChannelIn(String community) {
    return 'Novi kanal u zajednici $community';
  }

  @override
  String get communityChannelName => 'Naziv kanala';

  @override
  String get communityNoChannels => 'Još nema kanala';

  @override
  String communityChannelCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString kanala',
      few: '$countString kanala',
      one: '$countString kanal',
    );
    return '$_temp0';
  }

  @override
  String get communityNewChannel => 'Novi kanal';

  @override
  String get communityNoChannelsHint => 'Koristite + da napravite prvi.';

  @override
  String get communityPlaceholderName => 'Zajednica';

  @override
  String get channelPlaceholderName => 'Kanal';

  @override
  String get channelPrivatePlaceholderName => 'Privatni kanal';

  @override
  String get communityInfoEditFailed =>
      'Nije moguće sačuvati podatke. Pokušajte ponovo.';

  @override
  String get communityEditInfo => 'Uredi zajednicu';

  @override
  String get channelEditInfo => 'Uredi kanal';

  @override
  String get channelTopic => 'Tema';

  @override
  String get channelEditFailed => 'Kanal nije sačuvan. Pokušajte ponovo.';

  @override
  String get channelSave => 'Sačuvaj';

  @override
  String get communityNotMember => 'Još niste član';

  @override
  String get backupIntro =>
      'Rezervna kopija sadrži ključeve i istoriju poruka ovog uređaja, šifrovane na ovom uređaju. Server je čuva, ali ne može da je pročita. Za vraćanje na novom uređaju potreban je kod za oporavak koji se prikazuje kada je napravite.';

  @override
  String get backupSectionStatus => 'Status';

  @override
  String get backupNone => 'Još nema rezervne kopije sa ovog uređaja';

  @override
  String backupLast(String time) {
    return 'Poslednja rezervna kopija: $time';
  }

  @override
  String get backupReplacesPrevious =>
      'Nova rezervna kopija zamenjuje prethodnu i njen kod.';

  @override
  String get backupMake => 'Napravi rezervnu kopiju';

  @override
  String get backupMakeNew => 'Napravi novu rezervnu kopiju';

  @override
  String get backupSaveCodeTitle => 'Sačuvajte kod za oporavak';

  @override
  String get backupSaveCodeMessage =>
      'Svako ko ima ovaj kod može da vrati vaše poruke. Čuvajte ga na bezbednom mestu, van mreže. Prikazuje se samo sada i prestaje da radi kada se iskoristi ili kada napravite novu rezervnu kopiju.';

  @override
  String get commonCopy => 'Kopiraj';

  @override
  String get backupSavedIt => 'Kod je sačuvan';

  @override
  String get backupRestoreMessage =>
      'Vaše poruke i podešavanja vraćaju se na ovaj uređaj. Rezervna kopija ne sadrži prijavu, pa se ovaj uređaj zatim pridružuje vašem nalogu kao novi uređaj.';

  @override
  String get backupRecoveryCode => 'Kod za oporavak';

  @override
  String get backupRestore => 'Vrati';

  @override
  String get deviceLinkTitle => 'Poveži uređaj';

  @override
  String get deviceLinkIntro =>
      'Generišite jednokratni kod, unesite ga na novom uređaju, a zatim ga ovde odobrite pomoću verifikacionog koda koji prikazuje novi uređaj. Vaša istorija razgovora se zatim šifrovana kopira na novi uređaj, pa oba uređaja držite na mreži.';

  @override
  String get deviceLinkCreate => 'Napravi vezu';

  @override
  String get deviceLinkCreateNew => 'Napravi novu vezu';

  @override
  String get deviceLinkQrSemantics =>
      'QR kod sa vezom za povezivanje uređaja. Skenirajte ga novim uređajem.';

  @override
  String get deviceLinkQrHint =>
      'Skenirajte ga aplikacijom Veritra na novom uređaju ili unesite kod za povezivanje ispod.';

  @override
  String get deviceLinkStatusLabel => 'STATUS';

  @override
  String deviceLinkState(String state) {
    String _temp0 = intl.Intl.selectLogic(
      state,
      {
        'pending': 'na čekanju',
        'claimed': 'preuzeto',
        'approved': 'odobreno',
        'expired': 'isteklo',
        'other': '$state',
      },
    );
    return '$_temp0';
  }

  @override
  String get deviceLinkClaimedBy => 'Preuzeo uređaj';

  @override
  String get deviceLinkRefreshStatus => 'Osveži status';

  @override
  String get deviceLinkApproveDevice => 'Odobri uređaj';

  @override
  String get deviceLinkApprove => 'Odobri';

  @override
  String get deviceLinkApproveHint =>
      'Unesite osmocifreni kod prikazan na novom uređaju. Nikada ne koristite kod koji vam je neko poslao ili pročitao.';

  @override
  String get deviceLinkUnavailableHere =>
      'Povezivanje uređaja nije dostupno u ovoj verziji.';

  @override
  String get deviceLinkAlreadyPending =>
      'Na ovom uređaju već čeka veza uređaja. Prvo je proverite ili otkažite.';

  @override
  String get deviceLinkRecoveryInProgress =>
      'Na ovom uređaju čeka oporavak naloga, pa se uređaj ne može povezati ovde dok se ne završi ili otkaže.';

  @override
  String get deviceLinkEnded =>
      'Ova veza je otkazana ili je istekla. Zatražite novu sa svog drugog uređaja.';

  @override
  String get deviceLinkApprovalInvalid =>
      'To odobrenje nije moglo da se proveri, pa uređaj nije povezan. Napravite novu vezu na svom drugom uređaju i pokušajte ponovo.';

  @override
  String get deviceLinkCodeMismatch =>
      'Taj kod se ne poklapa sa onim na novom uređaju. Proverite ga i pokušajte ponovo.';

  @override
  String get deviceLinkRefreshFirst =>
      'Prvo osvežite status, a zatim odobrite uređaj.';

  @override
  String get deviceLinkCancelWaiting => 'Otkaži ovu vezu';

  @override
  String get deviceLinkWaitingApproval =>
      'Čeka se da vaš drugi uređaj odobri. Ostavite ovaj ekran otvoren.';

  @override
  String get deviceLinkWaitingCode =>
      'Čeka se vaš drugi uređaj. Kod za potvrdu će se uskoro pojaviti ovde.';

  @override
  String get deviceLinkCommitmentMismatch =>
      'Provera veze sa vašeg drugog uređaja se nije poklopila, pa uređaj nije povezan. Napravite novu vezu na svom drugom uređaju i pokušajte ponovo.';

  @override
  String get historyCopySendWorking => 'Šaljem vašu istoriju na novi uređaj…';

  @override
  String get historyCopySendWaiting =>
      'Vaša istorija je spremna. Čeka se da je novi uređaj primi.';

  @override
  String get historyCopyReceiveWorking =>
      'Primam vašu istoriju sa drugog uređaja…';

  @override
  String get historyCopyReceiveWaiting =>
      'Čeka se da vaš drugi uređaj pošalje istoriju. Ostavite ga na mreži.';

  @override
  String get historyCopyFailed =>
      'Kopiranje vaše istorije nije završeno. Pokušaće se ponovo.';

  @override
  String get historyCopyEnded =>
      'Kopiranje vaše istorije je zaustavljeno. Ponovo povežite uređaj da biste je kopirali.';

  @override
  String get bannerQueued =>
      'Poruke koje šaljete ostaju u redu čekanja na ovom uređaju.';

  @override
  String get bannerReconnecting => 'Ponovno povezivanje sa serverom…';

  @override
  String bannerLastSynced(String time) {
    return 'Poslednja sinhronizacija: $time.';
  }

  @override
  String bannerOfflineSemantics(String detail) {
    return 'Van mreže. $detail';
  }

  @override
  String bannerConnectingSemantics(String detail) {
    return 'Povezivanje sa serverom. $detail';
  }

  @override
  String get bannerOffline => 'Van mreže';

  @override
  String get bannerConnecting => 'Povezivanje…';

  @override
  String get bannerPaused => 'Poruke su pauzirane';

  @override
  String get bannerTryAgain => 'Pokušaj ponovo';

  @override
  String get bannerRelink => 'Ponovo poveži ovaj uređaj';

  @override
  String get bannerRestoreBackup => 'Vrati iz rezervne kopije';

  @override
  String get bannerRelinkTitle => 'Ponovo povezati ovaj uređaj?';

  @override
  String get bannerRelinkMessage =>
      'Ovo odjavljuje ovaj uređaj i briše njegove poruke i ključeve za šifrovanje. Posle toga ga ponovo povežite sa drugog uređaja. Poruke koje postoje samo na ovom uređaju ne mogu se povratiti.';

  @override
  String get bannerRelinkConfirm => 'Izbriši i odjavi';

  @override
  String get attachmentPickUnavailable =>
      'Na ovom uređaju nije moguće birati datoteke.';

  @override
  String get attachmentSendTitle => 'Poslati ovu datoteku?';

  @override
  String attachmentSendMessage(String name, String size) {
    return 'Datoteka $name ($size) se šifruje na ovom uređaju pre otpremanja. Svi u ovom razgovoru mogu da je otvore.';
  }

  @override
  String get attachmentSend => 'Pošalji';

  @override
  String get attachmentSendFailed => 'Datoteka nije mogla da se pošalje.';

  @override
  String get attachmentDemoImagesOnly =>
      'U demo verziji na ovom uređaju mogu da se otvaraju samo slike.';

  @override
  String attachmentSaved(String fileName) {
    return 'Sačuvano: $fileName.';
  }

  @override
  String get attachmentDownloadFailed =>
      'Datoteka nije mogla da se preuzme ili dešifruje.';

  @override
  String attachmentImageSemantics(String fileName, String size) {
    return 'Slika $fileName, $size';
  }

  @override
  String attachmentFileSemantics(String fileName, String size) {
    return 'Datoteka $fileName, $size';
  }

  @override
  String get attachmentSave => 'Sačuvaj';

  @override
  String get attachmentImageFailed =>
      'Slika nije mogla da se preuzme ili dešifruje.';

  @override
  String get attachmentImageUnshowable => 'Ova slika ne može da se prikaže.';

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
  String get chatListSearch => 'Pretraga';

  @override
  String get chatListNewChat => 'Novo ćaskanje';

  @override
  String get chatListEmptyTitle => 'Još nema razgovora';

  @override
  String get chatListEmptyMessage =>
      'Započnite direktnu poruku ili napravite grupu. Sve je šifrovano s kraja na kraj.';

  @override
  String get chatListUnmute => 'Uključi obaveštenja';

  @override
  String get chatListMute => 'Isključi obaveštenja';

  @override
  String get chatListDetails => 'Detalji razgovora';

  @override
  String get chatListMuted => 'Utišano';

  @override
  String chatListDisappearingAfter(String duration) {
    return 'Nestajuće poruke: $duration';
  }

  @override
  String chatListUnreadSpoken(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString nepročitanih poruka',
      few: '$countString nepročitane poruke',
      one: '$countString nepročitana poruka',
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
  String get conversationGroupChat => 'Grupno ćaskanje';

  @override
  String get conversationPrivateGroup => 'Privatna grupa';

  @override
  String get conversationEncrypted => 'Šifrovano';

  @override
  String conversationDisappearing(String duration) {
    return 'Nestajuće ($duration)';
  }

  @override
  String durationHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString sati',
      few: '$countString sata',
      one: '$countString sat',
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
      other: '$countString minuta',
      few: '$countString minuta',
      one: '$countString minut',
    );
    return '$_temp0';
  }

  @override
  String durationChipDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString d';
  }

  @override
  String durationChipHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString č';
  }

  @override
  String durationChipMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString min';
  }

  @override
  String get safetyMarkTitle => 'Označiti kao verifikovano?';

  @override
  String get safetyMarkMessage =>
      'Uradite ovo samo nakon što ste broj uporedili sa drugom osobom uživo ili u pozivu u koji imate poverenja. Oboje morate da vidite potpuno istih šezdeset cifara.';

  @override
  String get safetyTheyMatch => 'Podudaraju se';

  @override
  String get safetySaveFailed =>
      'Verifikacija nije mogla da se sačuva. Pokušajte ponovo.';

  @override
  String get safetyScanTitle => 'Skeniraj bezbednosni kod';

  @override
  String get safetyReadFailed =>
      'Bezbednosni broj nije mogao da se pročita. Pokušajte ponovo.';

  @override
  String get safetyMismatchTitle => 'Kodovi se ne podudaraju';

  @override
  String get safetyMismatchMessage =>
      'Ovo nije isti bezbednosni kod. Proverite da li ste skenirali kod za ovaj razgovor i da li su oba uređaja primila najnovije poruke, pa pokušajte ponovo. Ako se i dalje ne podudara, ne smatrajte ovaj razgovor verifikovanim.';

  @override
  String get commonOk => 'U redu';

  @override
  String get safetyCodesMatch => 'Kodovi se podudaraju.';

  @override
  String get safetyCodesMatchVerified =>
      'Kodovi se podudaraju. Označeno kao verifikovano.';

  @override
  String get safetyTitle => 'Bezbednosni broj';

  @override
  String get safetyGroupIntro =>
      'Svaki član ove grupe vidi isti broj. Uporedite ga uživo ili međusobno skenirajte kodove.';

  @override
  String safetyPeerIntro(String peer) {
    return 'Uporedite ovaj broj sa korisnikom $peer uživo ili međusobno skenirajte kodove.';
  }

  @override
  String get safetyUnavailable => 'Bezbednosni broj nije dostupan';

  @override
  String get safetyUnavailableDetail =>
      'Ovaj uređaj se još nije pridružio šifrovanoj grupi ili stanje njegove grupe nije moglo da se pročita.';

  @override
  String safetyDigitsSemantics(String groups) {
    return 'Bezbednosni broj, dvanaest grupa od po pet cifara: $groups';
  }

  @override
  String get safetyQrSemantics =>
      'QR kod ovog bezbednosnog broja. Druga osoba može da ga skenira radi poređenja.';

  @override
  String get safetyVerifiedDetail => 'Verifikovali ste ovaj broj.';

  @override
  String get safetyChangedDetail =>
      'Otkako ste verifikovali, u ovom razgovoru je neki uređaj dodat, uklonjen ili zamenjen. Ponovo uporedite novi broj.';

  @override
  String get safetyChangedWhileComparing =>
      'Bezbednosni broj se promenio dok ste ga upoređivali, pa ništa nije sačuvano. Ponovo uporedite novi broj.';

  @override
  String get safetyUnverifiedDetail => 'Još nije verifikovano.';

  @override
  String get safetyVerified => 'Verifikovano';

  @override
  String get safetyChanged => 'Promenjeno';

  @override
  String get safetyUnverified => 'Nije verifikovano';

  @override
  String get safetyScanTheirCode => 'Skeniraj kod druge osobe';

  @override
  String get safetyMarkVerified => 'Označi kao verifikovano';

  @override
  String get detailsNotFound => 'Razgovor nije pronađen.';

  @override
  String get detailsConversationIdLabel => 'ID RAZGOVORA';

  @override
  String get detailsCopyId => 'Kopiraj ID';

  @override
  String get detailsConversationId => 'ID razgovora';

  @override
  String get detailsCreatedLabel => 'NAPRAVLJEN';

  @override
  String get detailsMuteDetail =>
      'Zaustavlja push obaveštenja za ovaj razgovor. Poruke i dalje stižu i računaju se kao nepročitane.';

  @override
  String get detailsSectionMembers => 'Članovi';

  @override
  String get detailsLoadingMembers => 'Učitavanje članova…';

  @override
  String get detailsMembersUnavailable => 'Spisak članova nije dostupan';

  @override
  String get detailsMembersUnavailableDetail =>
      'Server nije vratio spisak članova za ovaj razgovor.';

  @override
  String get detailsAddMember => 'Dodaj člana';

  @override
  String get detailsAddMemberDetail => 'Pronađite nalog po korisničkom imenu';

  @override
  String get detailsAddMemberNoPermission => 'Potrebna je dozvola moderatora';

  @override
  String get detailsMembershipNote =>
      'Ovo je evidencija članstva na serveru. Šifrovana dostava prati zasebno ažuriranje grupe, pa promena ovde sama po sebi nije dokaz o tome ko može da dešifruje nove poruke.';

  @override
  String get detailsSafetyDetail =>
      'Uporedite ga sa drugim članovima da biste proverili da niko ne presreće ovaj razgovor.';

  @override
  String get detailsLeaveDm => 'Napusti ovaj razgovor';

  @override
  String get detailsLeave => 'Napusti razgovor';

  @override
  String get detailsLeaveDetail =>
      'Prestajete da primate nove poruke. Poruke koje su već na uređajima drugih članova se ne brišu.';

  @override
  String get detailsSectionDisappearing => 'Nestajuće poruke';

  @override
  String get detailsDisappearingNote =>
      'Kada je ovo podešeno, poruke poslate od tada brišu se sa servera nakon ovog vremenskog perioda. Postojeće poruke zadržavaju tajmer sa kojim su poslate.';

  @override
  String get detailsRetentionOff => 'Isključeno';

  @override
  String detailsRemoveTitle(String label) {
    return 'Ukloniti $label?';
  }

  @override
  String get detailsRemoveMessage =>
      'Taj nalog prestaje da prima nove poruke u ovom razgovoru. Poruke koje je već primio ostaju na njegovom uređaju, a šifrovana dostava se menja tek kada se ažuriranje grupe potvrdi.';

  @override
  String get detailsRemoveConfirm => 'Ukloni';

  @override
  String detailsRemoved(String label) {
    return 'Nalog $label je uklonjen iz razgovora.';
  }

  @override
  String detailsRemoveFailed(String label) {
    return 'Uklanjanje naloga $label nije uspelo.';
  }

  @override
  String get detailsLeaveTitle => 'Napustiti razgovor?';

  @override
  String get detailsLeaveMessage =>
      'Prestajete da primate nove poruke, a razgovor se uklanja sa ovog uređaja. Poruke koje su drugi članovi već primili se ne brišu.';

  @override
  String get detailsLeaveConfirm => 'Napusti';

  @override
  String get detailsRetentionOffMessage =>
      'Nove poruke više neće nestajati. Poruke koje već imaju tajmer zadržavaju ga.';

  @override
  String detailsRetentionOnMessage(String duration) {
    return 'Poruke poslate od sada biće obrisane sa servera $duration nakon slanja. Postojeće poruke se ne menjaju.';
  }

  @override
  String get detailsRetentionOffTitle => 'Isključiti nestajuće poruke?';

  @override
  String detailsRetentionOnTitle(String duration) {
    return 'Podesiti nestajanje na $duration?';
  }

  @override
  String get detailsApply => 'Primeni';

  @override
  String get detailsAdd => 'Dodaj';

  @override
  String detailsMemberAdded(String label) {
    return 'Nalog $label je dodat u razgovor. Šifrovana dostava počinje kada se ažuriranje grupe potvrdi.';
  }

  @override
  String get roleOwner => 'Vlasnik';

  @override
  String get roleAdmin => 'Administrator';

  @override
  String get roleModerator => 'Moderator';

  @override
  String get roleMember => 'Član';

  @override
  String get detailsYou => 'Vi';

  @override
  String detailsJoined(String date) {
    return 'Član od $date';
  }

  @override
  String detailsRemoveMember(String label) {
    return 'Ukloni $label';
  }

  @override
  String get detailsBlockedDetail =>
      'Poruke tog naloga su skrivene za ovaj nalog dok ga ne deblokirate.';

  @override
  String get detailsBlockDetail =>
      'Server prestaje da dostavlja poruke tog naloga vašem nalogu. Taj nalog o tome neće biti obavešten, a poruke koje su već na vašim uređajima ostaju.';

  @override
  String get chatStatusMutedEncrypted => 'UTIŠANO · ŠIFROVANO';

  @override
  String get chatStatusEncrypted => 'ŠIFROVANO';

  @override
  String get chatNoConversationMessage =>
      'Izaberite razgovor sa liste ćaskanja.';

  @override
  String get chatEmptyTitle => 'Još nema poruka';

  @override
  String get chatEmptyMessage =>
      'Poruke se čuvaju kao šifrovani koverti koje mogu da pročitaju samo članovi.';

  @override
  String get chatJumpToLatest => 'Idi na najnovije';

  @override
  String chatReact(String reaction) {
    return 'Reaguj: $reaction';
  }

  @override
  String get chatReply => 'Odgovori';

  @override
  String get chatCopyText => 'Kopiraj tekst';

  @override
  String get chatEdit => 'Izmeni';

  @override
  String get chatDeleteForEveryone => 'Izbriši za sve';

  @override
  String get chatDeleteTitle => 'Izbrisati za sve?';

  @override
  String get chatDeleteMessage =>
      'Uređaji članova uklanjaju tekst. Server ga nikada nije imao.';

  @override
  String get chatDelete => 'Izbriši';

  @override
  String get chatEditEmpty =>
      'Unesite novi tekst ili umesto toga izbrišite poruku.';

  @override
  String get chatEditTitle => 'Izmeni poruku';

  @override
  String get chatLoadFailed => 'Učitavanje poruka nije uspelo';

  @override
  String get chatReplyEarlier => 'Odgovor na raniju poruku';

  @override
  String get chatReplyDeleted => 'Odgovor na obrisanu poruku';

  @override
  String get chatLoadOlder => 'Učitaj starije poruke';

  @override
  String get chatPendingSendingSemantics => 'Šifrovana poruka se šalje';

  @override
  String get chatPendingTerminalSemantics =>
      'Slanje šifrovane poruke trajno nije uspelo. Možete je kopirati ili odbaciti.';

  @override
  String get chatPendingFailedSemantics =>
      'Slanje šifrovane poruke nije uspelo. Možete pokušati ponovo.';

  @override
  String get chatPendingSending => 'Šalje se šifrovana poruka';

  @override
  String get chatPendingTerminal => 'Poruka zahteva pažnju';

  @override
  String get chatPendingFailed => 'Slanje nije uspelo';

  @override
  String get chatDiscard => 'Odbaci';

  @override
  String get chatSenderYou => 'vas';

  @override
  String get chatAttachmentUnopenable => 'Ovaj prilog ne može da se otvori.';

  @override
  String get chatMessageActions => 'Radnje za poruku';

  @override
  String chatDeletedSemantics(String sender) {
    return 'Obrisana poruka od $sender';
  }

  @override
  String chatUnverifiedSemantics(String time) {
    return 'Poruka od pošiljaoca koji nije verifikovan, $time';
  }

  @override
  String chatMessageSemantics(String sender, String time, String text) {
    return 'Poruka od $sender, $time: $text';
  }

  @override
  String chatAttachmentSemantics(String sender, String time) {
    return 'Prilog od $sender, $time';
  }

  @override
  String chatEncryptedSemantics(String sender, String time) {
    return 'Šifrovana poruka od $sender, $time';
  }

  @override
  String get chatMessageDeleted => 'Poruka je obrisana';

  @override
  String get chatSenderUnverified =>
      'Pošiljalac nije mogao da se verifikuje. Poruka je skrivena.';

  @override
  String get chatMessageUnsupported =>
      'Ova poruka zahteva noviju verziju aplikacije Veritra';

  @override
  String get chatMessageInvalid => 'Jedna poruka nije mogla da se pročita';

  @override
  String get chatMessageUndecryptable => 'Ova poruka nije mogla da se otključa';

  @override
  String get chatMessageUnapprovedDevice =>
      'Sakrivena je poruka sa uređaja koji nije odobren.';

  @override
  String chatDevicesNotJoined(String name) {
    return 'Neki uređaji korisnika $name se još nisu pridružili.';
  }

  @override
  String get chatMessageWelcomeUnavailable =>
      'Pridruživanje ovom ćaskanju nije uspelo. Zamolite člana da vas ponovo doda.';

  @override
  String chatReactionCount(String reaction, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$reaction $countString';
  }

  @override
  String get chatEdited => 'izmenjeno';

  @override
  String get chatTickSent => 'Poslato';

  @override
  String get chatTickDelivered => 'Dostavljeno';

  @override
  String get chatTickRead => 'Pročitano';

  @override
  String chatTypingOne(String name) {
    return '$name kuca…';
  }

  @override
  String chatTypingTwo(String first, String second) {
    return '$first i $second kucaju…';
  }

  @override
  String get chatTypingMany => 'Nekoliko osoba kuca…';

  @override
  String chatReplyingTo(String preview) {
    return 'Odgovor na: $preview';
  }

  @override
  String get chatCancelReply => 'Otkaži odgovor';

  @override
  String get chatSendingFile => 'Slanje datoteke';

  @override
  String get chatAttachFile => 'Priloži datoteku';

  @override
  String get chatComposerHint => 'Poruka';

  @override
  String get chatPostingRestricted => 'Samo administratori mogu da objavljuju';

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
      'Slanje je ovde pauzirano: server je odbio ažuriranje šifrovanja za ovaj razgovor. Ostali razgovori i dalje rade.';

  @override
  String get chatSyncPausedNotice =>
      'Poruke u ovom razgovoru su pauzirane: ažuriranje šifrovanja nije moglo da se primeni. Nijedna poruka nije preskočena, a ostali razgovori i dalje rade.';

  @override
  String get chatRemovalHoldNotice =>
      'Vaša poruka čeka da se završi ažuriranje šifrovanja posle uklanjanja člana, a zatim se šalje.';

  @override
  String get chatNoPeerReadOnly =>
      'Niko drugi u ovom razgovoru ne može ponovo da doda ovaj uređaj, pa je istorija ovde samo za čitanje. Započnite novi razgovor da biste slali poruke.';

  @override
  String get chatNoPeerCheckFailed =>
      'Trenutno ne možemo da proverimo članove ovog razgovora. Pokušajte ponovo za trenutak.';

  @override
  String get chatAttachment => 'Prilog';

  @override
  String chatAttachmentOne(String name) {
    return 'Prilog: $name';
  }

  @override
  String chatAttachmentMany(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Prilozi: $name i još $countString';
  }

  @override
  String get demoBannerLabel => 'Demo verzija · šifrovanje bez revizije';

  @override
  String demoBannerNotice(String label) {
    return '$label. Nije za stvarne razgovore.';
  }

  @override
  String dateTimeJoined(String date, String time) {
    return '$date · $time';
  }

  @override
  String get backupErrorNetwork =>
      'Server nije dostupan. Pokušajte ponovo; vraćanje se nastavlja tamo gde je stalo.';

  @override
  String get backupErrorNotFound =>
      'Ovaj kod za oporavak je nepoznat, istekao je ili je već iskorišćen.';

  @override
  String get backupErrorBusy =>
      'Ova rezervna kopija se upravo preuzima na drugom mestu. Pokušajte ponovo za nekoliko minuta.';

  @override
  String get backupErrorWrongKey =>
      'Ovaj kod za oporavak ne otvara rezervnu kopiju.';

  @override
  String get backupErrorCorrupt =>
      'Rezervna kopija je oštećena i ne može da se vrati.';

  @override
  String get backupErrorDeviceNotEmpty =>
      'Ovaj uređaj već ima nalog. Odjavite se i resetujte uređaj pre vraćanja rezervne kopije.';

  @override
  String get backupErrorTooLarge =>
      'Rezervna kopija je veća od onoga što ova aplikacija podržava.';

  @override
  String get backupErrorStorage =>
      'Ovaj uređaj nije mogao da sačuva rezervnu kopiju.';

  @override
  String get backupRestoredLinkToFinish =>
      'Vaše poruke i podešavanja su vraćeni na ovaj uređaj. Da biste završili, povežite ovaj uređaj sa drugog uređaja koji je prijavljen na vaš nalog. Ako ste izgubili sve uređaje, koristite „Izgubili ste sve uređaje?” sa lozinkom i ključem za oporavak.';

  @override
  String get syncErrorCursorExpired =>
      'Ovaj uređaj je bio odsutan duže nego što server čuva ažuriranja. Vratite rezervnu kopiju ili ponovo povežite ovaj uređaj.';

  @override
  String get syncErrorControlMissing =>
      'Ažuriranje šifrovanja za neki razgovor nedostaje ili je oštećeno. Poruke su pauzirane da nijedna ne bi bila preskočena.';

  @override
  String get syncErrorMlsState =>
      'Ovaj uređaj nije mogao da ažurira svoje stanje šifrovanja. Poruke su pauzirane da nijedna ne bi bila preskočena.';

  @override
  String get syncErrorUndecryptable =>
      'Poruka nije mogla da se pročita na ovom uređaju. Poruke su pauzirane da nijedna ne bi bila preskočena.';

  @override
  String get syncErrorUnsupportedEvent =>
      'Server je poslao ažuriranje koje ova verzija aplikacije ne prepoznaje. Ažurirajte aplikaciju, pa pokušajte ponovo.';

  @override
  String get syncErrorCryptoUnavailable =>
      'Šifrovanje nije dostupno u ovoj verziji aplikacije, pa šifrovana ažuriranja ne mogu da se primene.';

  @override
  String get syncErrorStopped =>
      'Sinhronizacija je zaustavljena. Pokušajte ponovo.';

  @override
  String get syncErrorLocalStorage =>
      'Ovaj uređaj nije mogao da čita ili piše u svoje lokalno skladište. Poruke su pauzirane da nijedna ne bi bila preskočena. Oslobodite prostor ili ponovo pokrenite aplikaciju, pa pokušajte ponovo.';

  @override
  String get syncErrorRecordLimit =>
      'Jedan razgovor je postao prevelik da bi ovaj uređaj sačuvao njegove šifrovane podatke. Poruke su pauzirane da nijedna ne bi bila preskočena. Napustite taj razgovor da biste nastavili.';

  @override
  String get syncErrorRecordLimitDevice =>
      'Šifrovani podaci ovog uređaja postali su preveliki za čuvanje. Poruke su pauzirane da nijedna ne bi bila preskočena. Ponovo povežite ovaj uređaj da biste nastavili.';

  @override
  String syncErrorRecordLimitNamed(String title) {
    return 'Razgovor „$title“ je postao prevelik da bi ovaj uređaj sačuvao njegove šifrovane podatke. Poruke su pauzirane da nijedna ne bi bila preskočena. Napustite taj razgovor da biste nastavili.';
  }

  @override
  String bannerLeaveNamed(String title) {
    return 'Napusti „$title“';
  }

  @override
  String bannerLeaveNamedTitle(String title) {
    return 'Napustiti „$title“?';
  }

  @override
  String get syncErrorStorageBusy =>
      'Skladište ovog uređaja je zauzeto ili puno. Sinhronizacija će uskoro pokušati ponovo.';

  @override
  String get apiErrorSessionInvalid =>
      'Vaša sesija više nije važeća. Prijavite se ponovo.';

  @override
  String get apiErrorInvalidCredentials =>
      'Prijava nije uspela. Proverite korisničko ime i lozinku.';

  @override
  String get apiErrorRecentAuth =>
      'Potvrdite lozinku pre ove osetljive radnje.';

  @override
  String get apiErrorDeviceNotLinked =>
      'Ovaj uređaj mora biti povezan pre prijave lozinkom.';

  @override
  String get apiErrorForbidden => 'Nemate dozvolu za to.';

  @override
  String get apiErrorNotFound =>
      'Ta stavka nije pronađena. Možda je uklonjena.';

  @override
  String get apiErrorAlreadySetup =>
      'Ovaj server već ima vlasnika. Umesto toga se prijavite ili se pridružite uz pozivnicu.';

  @override
  String get apiErrorLastOwner =>
      'Prenesite vlasništvo pre nego što onemogućite poslednji nalog vlasnika.';

  @override
  String get apiErrorWeakPassword => 'Lozinka mora imati 12–72 znaka.';

  @override
  String get apiErrorInvalidInvite =>
      'Taj kod pozivnice nije važeći, istekao je ili je već iskorišćen do kraja.';

  @override
  String get apiErrorInvalidDeviceLink =>
      'Taj kod za povezivanje nije važeći ili je istekao. Generišite novi na povezanom uređaju.';

  @override
  String get apiErrorTranscriptMismatch =>
      'Lokalno verifikovani akreditivi uređaja su se promenili. Generišite novu vezu i ponovo uporedite oba uređaja.';

  @override
  String get apiErrorInvalidDeviceName => 'Taj naziv uređaja nije važeći.';

  @override
  String get apiErrorInvalidName => 'Taj naziv nije važeći.';

  @override
  String get apiErrorInvalidMaxUses =>
      'Ograničenje broja korišćenja pozivnice nije važeće.';

  @override
  String get apiErrorInvalidExpiry => 'To vreme isteka nije važeće.';

  @override
  String get apiErrorInvalidConversationKind =>
      'Server je odbio ovu vrstu razgovora.';

  @override
  String get apiErrorInvalidRetention =>
      'To trajanje nestajućih poruka nije podržano.';

  @override
  String get apiErrorInvalidRole => 'Ta uloga člana nije važeća.';

  @override
  String get apiErrorAccountRequired =>
      'Izaberite nalog koji želite da dodate.';

  @override
  String get apiErrorUploadTooLarge =>
      'Ta datoteka je prevelika za otpremanje.';

  @override
  String get apiErrorKeyPackageRefused =>
      'Server je odbio ključeve za šifrovanje ove verzije aplikacije. Potreban je klijent sa podrškom za produkciono šifrovanje.';

  @override
  String get apiErrorStorage =>
      'Server je imao problem sa skladištem. Pokušajte ponovo uskoro.';

  @override
  String get apiErrorStorageFull =>
      'Server nema više prostora za ovaj nalog. Izbrišite starije priloge ili zatražite od administratora više prostora.';

  @override
  String get apiErrorBlobIntegrity =>
      'Šifrovani prilog nije mogao da se verifikuje. Odbacite ga i pokušajte ponovo.';

  @override
  String get apiErrorSetupToken =>
      'Token za podešavanje nedostaje ili je pogrešan. Koristite onaj koji je server ispisao pri pokretanju (demo ga čuva u data/demo/setup-token).';

  @override
  String get apiErrorDraining =>
      'Server se ponovo pokreće. Pokušajte ponovo uskoro.';

  @override
  String get apiErrorIdempotencyConflict =>
      'Ova poruka je već poslata sa drugačijim podacima. Odbacite je i napišite novu poruku.';

  @override
  String get apiErrorMessageExpired => 'Ta poruka je istekla.';

  @override
  String get apiErrorRecoveryInProgress =>
      'Drugo vraćanje već preuzima ovu rezervnu kopiju. Pokušajte ponovo uskoro.';

  @override
  String get apiErrorWriteRateLimited =>
      'Trenutno šaljete mnogo. Sačekajte minut i pokušajte ponovo.';

  @override
  String get apiErrorServerStorageLow =>
      'Serveru skoro ponestaje prostora, pa su nove poruke i otpremanja pauzirani. Zamolite administratora da oslobodi prostor.';

  @override
  String get apiErrorDeviceLimit =>
      'Ovaj nalog već ima najveći dozvoljeni broj uređaja. Prvo uklonite jedan u Podešavanjima.';

  @override
  String get apiErrorDeviceLinkLimit =>
      'Previše povezivanja uređaja je na čekanju. Prvo dovršite ili otkažite jedno.';

  @override
  String get apiErrorConversationLimit =>
      'Dostigli ste najveći dozvoljeni broj razgovora na ovom serveru. Prvo napustite ili izbrišite jedan.';

  @override
  String get apiErrorConversationMemberLimit => 'Ovaj razgovor je pun.';

  @override
  String get apiErrorConflict =>
      'Ovo se u međuvremenu promenilo na serveru. Osvežite i pokušajte ponovo.';

  @override
  String get apiErrorRateLimited =>
      'Previše pokušaja. Sačekajte trenutak i pokušajte ponovo.';

  @override
  String get apiErrorEncryption =>
      'Server je odbio šifrovane podatke iz ove verzije aplikacije.';

  @override
  String get apiErrorServer =>
      'Server je imao problem. Pokušajte ponovo uskoro.';

  @override
  String get apiErrorInvalidRequest =>
      'Server je odbio zahtev. Proverite unos i pokušajte ponovo.';

  @override
  String get errorUnexpectedResponse => 'Server je vratio neočekivan odgovor.';

  @override
  String get errorConversationPaused => 'Slanje je pauzirano u ovom razgovoru.';

  @override
  String get errorConversationApprovalHeld =>
      'Slanje je pauzirano: uređaj u ovom ćaskanju nije na odobrenoj listi svog vlasnika ili lista još nije mogla da se proveri.';

  @override
  String get errorDeviceListNotApproved =>
      'Taj uređaj još nije na odobrenoj listi svog vlasnika. Biće dodat kada bude.';

  @override
  String get errorDeviceListConflict =>
      'Odobrena lista uređaja vašeg naloga promenjena je na način koji ne može da se proveri. Uporedite sigurnosne brojeve sa kontaktom pre nego što promenite uređaje.';

  @override
  String get errorOutboxFull =>
      'Vaš red šifrovanih poruka je pun. Pošaljite ili odbacite poruku na čekanju pre nego što napišete novu.';

  @override
  String get errorCryptoStateFormatUnsupported =>
      'Šifrovani podaci na ovom uređaju sačuvani su u formatu koji ova verzija aplikacije ne može da pročita. Ponovo povežite ovaj uređaj da biste nastavili da šaljete poruke.';

  @override
  String get errorConversationTooLarge =>
      'Ovaj razgovor je postao prevelik da bi ovaj uređaj sačuvao njegove šifrovane podatke. Ništa nije promenjeno. Možete da napustite razgovor da bi ostali radili.';

  @override
  String get errorCryptoRecordLimit =>
      'Šifrovani podaci ovog uređaja postali su preveliki za čuvanje. Ništa nije promenjeno. Ponovo povežite ovaj uređaj da biste nastavili da šaljete poruke.';

  @override
  String get errorConversationPausedDetail =>
      'Slanje je pauzirano u ovom razgovoru jer je server odbio ažuriranje šifrovanja. Ostali razgovori i dalje rade.';

  @override
  String get errorEncryptionUnavailable =>
      'Ova verzija aplikacije još ne sadrži produkcioni mehanizam za šifrovanje, pa ova radnja nije dostupna.';

  @override
  String get errorActionUnavailable =>
      'Ova radnja nije dostupna u ovoj verziji aplikacije.';

  @override
  String get errorGeneric => 'Došlo je do greške. Pokušajte ponovo.';

  @override
  String get errorTimeout =>
      'Serveru je trebalo predugo da odgovori. Pokušajte ponovo.';

  @override
  String get errorUnreachable =>
      'Server nije dostupan. Proverite URL instance i vezu.';

  @override
  String get probeChecking => 'Provera servera…';

  @override
  String get probeReached => 'Veritra server je dostupan.';

  @override
  String probeConnectedTo(String name) {
    return 'Povezano sa serverom $name.';
  }

  @override
  String get probeInvalidOrigin =>
      'Unesite HTTPS adresu servera, na primer https://chat.example.org.';

  @override
  String get probeInsecure =>
      'Veritra zahteva HTTPS. Postavite server koji sami hostujete iza TLS-a sa pouzdanim sertifikatom ili iza Caddy-ja.';

  @override
  String get probeDnsFailure =>
      'Ta adresa nije pronađena. Proverite naziv hosta i pokušajte ponovo.';

  @override
  String get probeTlsFailure =>
      'Sertifikat servera nije prihvaćen. Koristite pouzdan sertifikat ili podesite Caddy TLS.';

  @override
  String get probeTimedOut =>
      'Serveru je trebalo predugo da odgovori. Proverite adresu i vezu.';

  @override
  String get probeNotVeritra => 'Ta adresa ne izgleda kao Veritra server.';

  @override
  String get probeUnavailable =>
      'Server nije dostupan. Proverite adresu i vezu.';

  @override
  String get outboxSendFailed =>
      'Ova šifrovana poruka nije mogla da se pošalje. Kopirajte je ili je odbacite.';

  @override
  String get recoveryRestoreFailed =>
      'Ovaj uređaj nije mogao da vrati svoju šifrovanu sesiju. Pokušajte ponovo ili nastavite na prijavu bez brisanja lokalnih podataka.';

  @override
  String get recoveryProfileLocked =>
      'Ovaj profil je već otvoren u drugom Veritra prozoru. Zatvorite taj prozor, pa pokušajte ponovo.';

  @override
  String get recoveryKeyUnavailable =>
      'Ovaj uređaj nije mogao da pročita svoje bezbedno skladište. Otključajte uređaj i pokušajte ponovo. Vaše poruke su sačuvane.';

  @override
  String get recoveryKeyMissing =>
      'Ključ koji štiti poruke ovog uređaja nedostaje ili se ne podudara. Ništa nije obrisano. Možete pokušati ponovo ili resetovati ovaj uređaj i ponovo ga povezati.';

  @override
  String get recoveryResetFailed =>
      'Resetovanje nije završeno. Ništa nije obrisano. Pokušajte ponovo.';

  @override
  String get recoveryUpgradeFailed =>
      'Ovaj uređaj nije mogao da ažurira skladište poruka za ovu verziju aplikacije Veritra, na primer zato što je uređaj pun. Ništa nije promenjeno niti obrisano. Oslobodite malo prostora, pa pokušajte ponovo.';

  @override
  String get recoveryUpgradeStillFull =>
      'Ovaj uređaj ni sada nije mogao da ažurira skladište poruka. Ništa nije promenjeno niti obrisano. Oslobodite još prostora i pokušajte ponovo ili resetujte ovaj uređaj i ponovo ga povežite.';

  @override
  String get recoveryUpgradeError =>
      'Ovaj uređaj nije mogao da ažurira skladište poruka za ovu verziju aplikacije Veritra. Ništa nije promenjeno niti obrisano. Pokušajte ponovo. Ako i dalje ne uspeva, možete da resetujete ovaj uređaj i ponovo ga povežete.';

  @override
  String get recoveryStorageDamaged =>
      'Skladište poruka na ovom uređaju je oštećeno i ne može da se pročita, pa je sinhronizacija zaustavljena. Ništa nije obrisano. Pokušajte ponovo ili resetujte ovaj uređaj i ponovo ga povežite.';

  @override
  String get recoverySqliteFeatureMissing =>
      'Ova verzija aplikacije Veritra ne može da otvori svoje skladište poruka: u mašini baze podataka nedostaje podrška za šifrovanje ili pretragu. Vaši podaci nisu promenjeni niti obrisani. Instalirajte verziju aplikacije Veritra koja ih podržava.';

  @override
  String get errorPasswordLoginNeedsLink =>
      'Za prijavu lozinkom ovaj uređaj prvo mora biti povezan.';

  @override
  String get attachmentSendFailedState => 'Prilog nije mogao da se pošalje.';

  @override
  String get errorRelinkRequired => 'Ovaj uređaj mora ponovo da se poveže.';

  @override
  String get pushTestSent =>
      'Proba je poslata. Obaveštenje bi trebalo da stigne u roku od jednog minuta.';

  @override
  String get pushTestGone =>
      'Push dobavljač više ne prihvata ovaj uređaj. Registracija se ponavlja.';

  @override
  String get pushTestRejected =>
      'Push dobavljač nije prihvatio probu. Pokušajte ponovo kasnije.';

  @override
  String get pushTestRateLimited => 'Sačekajte minut pre slanja nove probe.';

  @override
  String get pushTestNotRegistered =>
      'Ovaj uređaj još nije registrovan za push obaveštenja.';

  @override
  String get pushTestFailed => 'Proba nije mogla da se pošalje.';

  @override
  String errorServerNotAllowed(String url) {
    return 'Ova verzija aplikacije ne dozvoljava adresu servera $url. Koristite https:// adresu servera.';
  }

  @override
  String get muteEightHours => '8 sati';

  @override
  String get muteOneWeek => '1 nedelju';

  @override
  String get muteAlways => 'Dok ponovo ne uključim';

  @override
  String get muteStatusAlways => 'Utišano dok ponovo ne uključite obaveštenja.';

  @override
  String muteStatusUntil(String time) {
    return 'Utišano do $time.';
  }

  @override
  String get chatMoreReactions => 'Više reakcija';

  @override
  String get emojiSearchHint =>
      'Pretražite po imenu ili unesite ili nalepite emodži';

  @override
  String emojiUseTyped(String emoji) {
    return 'Koristi $emoji';
  }

  @override
  String get emojiNoResults =>
      'Nema emodžija sa tim imenom. Unesite ili nalepite ga.';

  @override
  String get emojiGroupSmileys => 'Smajliji';

  @override
  String get emojiGroupPeople => 'Ljudi';

  @override
  String get emojiGroupAnimals => 'Životinje i priroda';

  @override
  String get emojiGroupFood => 'Hrana i piće';

  @override
  String get emojiGroupTravel => 'Putovanja i mesta';

  @override
  String get emojiGroupActivities => 'Aktivnosti';

  @override
  String get emojiGroupObjects => 'Predmeti';

  @override
  String get emojiGroupSymbols => 'Simboli';

  @override
  String get emojiGroupFlags => 'Zastave';

  @override
  String get searchModeMessages => 'Poruke';

  @override
  String get searchModePeople => 'Ljudi i zajednice';

  @override
  String get searchMessagesHint => 'Pretražite poruke na ovom uređaju…';

  @override
  String get searchMessagesIntroTitle => 'Pretraga ovog uređaja';

  @override
  String get searchMessagesIntroMessage =>
      'Nalazi tekst u porukama koje ovaj uređaj čuva. Pretraga se odvija ovde i nikada se ne šalje serveru.';

  @override
  String get searchMessagesNoResultsTitle => 'Nema pronađenih poruka';

  @override
  String get searchMessagesNoResultsMessage =>
      'Ništa na ovom uređaju ne odgovara. Poruke koje su istekle ili su obrisane nestaju i iz pretrage.';

  @override
  String get searchMessagesFailed =>
      'Pretraga nije mogla da pročita lokalnu bazu podataka.';

  @override
  String attachmentTooLarge(String fileName, String limit) {
    return 'Datoteka $fileName je veća nego što ovaj server dozvoljava ($limit).';
  }

  @override
  String attachmentEmptyFile(String fileName) {
    return 'Datoteka $fileName je prazna i ne može da se pošalje.';
  }

  @override
  String attachmentTooMany(int count) {
    return 'Najviše $count datoteka može da čeka na zajedničko slanje.';
  }

  @override
  String attachmentRemove(String fileName) {
    return 'Uklonite $fileName';
  }

  @override
  String get attachmentOpenFailed =>
      'Datoteka nije mogla da se otvori. Ovaj uređaj možda nema aplikaciju za nju.';

  @override
  String get attachmentDropHint => 'Otpustite datoteke da biste ih priložili';

  @override
  String attachmentSentCount(int done, int total) {
    return 'Šalje se datoteka $done od $total';
  }

  @override
  String get settingsAdmin => 'Administracija';

  @override
  String get settingsAdminDetail => 'Nalozi i dnevnik revizije';

  @override
  String get adminAccountsTab => 'Nalozi';

  @override
  String get adminAuditTab => 'Dnevnik revizije';

  @override
  String get adminSuspend => 'Suspenduj';

  @override
  String get adminUnsuspend => 'Ponovo aktiviraj';

  @override
  String get adminSuspendTitle => 'Suspendovati ovaj nalog?';

  @override
  String adminSuspendMessage(String username) {
    return '@$username će biti odjavljen svuda i neće moći da se prijavi dok ne aktivirate nalog ponovo.';
  }

  @override
  String get adminUnsuspendTitle => 'Ponovo aktivirati ovaj nalog?';

  @override
  String adminUnsuspendMessage(String username) {
    return '@$username će ponovo moći da se prijavi.';
  }

  @override
  String get adminSuspendedPill => 'Suspendovan';

  @override
  String adminAccountSummary(String role, int devices, String storage) {
    String _temp0 = intl.Intl.pluralLogic(
      devices,
      locale: localeName,
      other: '$devices uređaja',
      few: '$devices uređaja',
      one: '$devices uređaj',
    );
    return '$role · $_temp0 · $storage';
  }

  @override
  String adminEventBy(String actor) {
    return 'Izvršio: $actor';
  }

  @override
  String get adminLoadMore => 'Učitaj još';

  @override
  String get adminNoAccounts => 'Nema naloga';

  @override
  String get adminNoEvents => 'Još nema događaja revizije';

  @override
  String requestsSection(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Zahtevi ($countString)';
  }

  @override
  String get requestsTitle => 'Zahtev za poruku';

  @override
  String requestFrom(String name) {
    return '$name želi da vam piše';
  }

  @override
  String get requestUnknownSender => 'Neko koga ne poznajete';

  @override
  String get requestExplanation =>
      'Ništa od ove osobe se ne prikazuje niti preuzima, i ona ne može da vidi da ste nešto pročitali, dok ne prihvatite.';

  @override
  String get requestAccept => 'Prihvati';

  @override
  String get requestBlock => 'Blokiraj';

  @override
  String get requestDelete => 'Obriši';

  @override
  String get requestBlockTitle => 'Blokirati ovu osobu?';

  @override
  String requestBlockMessage(String name) {
    return '$name više neće moći da vam piše, a ovaj razgovor će biti uklonjen.';
  }

  @override
  String get requestDeleteTitle => 'Obrisati ovaj zahtev?';

  @override
  String get requestDeleteMessage =>
      'Razgovor se uklanja sa ovog uređaja. Pošiljalac nije obavešten.';

  @override
  String get w8PinnedMessage => 'Zakačena poruka';

  @override
  String get w8Pin => 'Zakači poruku';

  @override
  String get w8Unpin => 'Otkači poruku';

  @override
  String w8PinDays(int days) {
    return 'Zakači na $days dana';
  }

  @override
  String get w8Forward => 'Prosledi';

  @override
  String get w8Forwarded => 'Prosleđeno';

  @override
  String get w8ForwardedMany => 'Prosleđeno više puta';

  @override
  String get w8Star => 'Označi zvezdicom na ovom uređaju';

  @override
  String get w8Unstar => 'Ukloni zvezdicu';

  @override
  String get w8DeleteForMe => 'Izbriši za mene na ovom uređaju';

  @override
  String get w8Archive => 'Arhiviraj na ovom uređaju';

  @override
  String get w8Unarchive => 'Vrati iz arhive';

  @override
  String get w8PinChat => 'Zakači ćaskanje na ovom uređaju';

  @override
  String get w8UnpinChat => 'Otkači ćaskanje';

  @override
  String get w8ArchivedChats => 'Arhivirana ćaskanja';

  @override
  String get w8Chats => 'Ćaskanja';

  @override
  String get w8MentionsMuted => 'Pominjanja u utišanim ćaskanjima';

  @override
  String get w8MentionsMutedDetail =>
      'Obavesti me kada me član pomene, čak i u utišanom ćaskanju.';

  @override
  String get b2LinkPreviews => 'Pregledi veza';

  @override
  String get b2LinkPreviewsDetail =>
      'Kada pošaljete vezu, ovaj uređaj može da preuzme stranicu i stavi pregled u šifrovanu poruku. Sajt vidi adresu ovog uređaja. Server i osobe kojima pišete nikada ne preuzimaju vezu.';

  @override
  String get b2LinkPreviewsOff => 'Isključeno';

  @override
  String get b2LinkPreviewsKnown => 'Samo poznati sajtovi';

  @override
  String get b2LinkPreviewsAll => 'Svi sajtovi';

  @override
  String get w8HiddenSpoiler => 'Poruka sa skrivenim spojlerom';

  @override
  String get w8StarredMessages => 'Poruke sa zvezdicom na ovom uređaju';

  @override
  String get k2CopiedHistory => 'Kopirana istorija · snimak sa uređaja';

  @override
  String get k2HistoryOnlyTitle => 'Kopirana istorija';

  @override
  String get k2HistoryOnlyNotice =>
      'Kopirano sa vašeg drugog uređaja. Samo za čitanje: ovaj uređaj nije član ovog razgovora, pa se ovde ništa ne može poslati.';

  @override
  String get k2HistoryUntitled => 'Raniji razgovor';

  @override
  String get k2HistoryOtherMember => 'Drugi član';

  @override
  String get k2HistoryAttachment => 'Prilog, nije preuzet na ovom uređaju';

  @override
  String get k2HistoryEmpty =>
      'U ovom razgovoru nije ostala nijedna kopirana poruka.';

  @override
  String get settingsRecoveryKey => 'Ključ za oporavak';

  @override
  String get recoveryUnavailableHere =>
      'Oporavak naloga nije dostupan u ovoj verziji aplikacije.';

  @override
  String get recoveryKeyTitle => 'Ključ za oporavak';

  @override
  String get recoveryKeyIntro =>
      'Ako izgubite sve uređaje, lozinka i ovaj ključ za oporavak vraćaju vaš nalog na novi uređaj. Čuvajte ključ na papiru, na sigurnom mestu. On ne vraća istoriju poruka.';

  @override
  String recoveryKeyStatusSet(String date) {
    return 'Postavljen $date';
  }

  @override
  String get recoveryKeyStatusNotSet => 'Nije postavljen';

  @override
  String get recoveryKeyStatusUnknown => 'Stanje trenutno nije dostupno';

  @override
  String get recoveryKeyStatusOff =>
      'Ovaj server ima isključen oporavak naloga';

  @override
  String get recoveryKeyCreate => 'Napravi ključ za oporavak';

  @override
  String get recoveryKeyReplace => 'Zameni ključ za oporavak';

  @override
  String get recoveryKeyReplaceNote =>
      'Novi ključ odmah zamenjuje stari i otkazuje oporavak koji čeka.';

  @override
  String get recoveryKeyShowTitle => 'Zapišite ključ za oporavak';

  @override
  String get recoveryKeyShowDetail =>
      'Zapišite ova 52 znaka na papir i čuvajte ga na sigurnom. Svako ko ima ovaj ključ i vašu lozinku može da preuzme vaš nalog. Ne pravite snimak ekrana i ne čuvajte ga u razgovoru.';

  @override
  String get recoveryKeyWritten => 'Ključ je zapisan';

  @override
  String get recoveryKeyConfirmTitle => 'Unesite ključ za oporavak';

  @override
  String get recoveryKeyConfirmDetail =>
      'Unesite ceo ključ sa papira da biste ga proverili. Crtice i razmaci nisu bitni.';

  @override
  String get recoveryKeyField => 'Ključ za oporavak';

  @override
  String get recoveryKeyRequired => 'Unesite ključ za oporavak.';

  @override
  String get recoveryKeyMismatch =>
      'To nije prikazani ključ. Proverite papir i pokušajte ponovo.';

  @override
  String get recoveryKeyShowAgain => 'Prikaži ključ ponovo';

  @override
  String get recoveryKeySave => 'Sačuvaj ključ za oporavak';

  @override
  String get recoveryKeySaved => 'Ključ za oporavak je sačuvan.';

  @override
  String get recoveryFollowUpTitle => 'Završite oporavak naloga';

  @override
  String get recoveryFollowUpKeyDetail =>
      'Vaš nalog je vraćen na ovaj uređaj, a vaši drugi uređaji su odjavljeni. Pre nego što se razgovori otvore, zamenite ključ za oporavak, a zatim lozinku: možda ih neko drugi zna.';

  @override
  String get recoveryFollowUpPasswordDetail =>
      'Poslednji korak: izaberite novu lozinku.';

  @override
  String get connectLostAllDevices => 'Izgubili ste sve uređaje?';

  @override
  String get recoveryStartTitle => 'Oporavak naloga';

  @override
  String get recoveryStartDetail =>
      'Koristite ovo samo ako ste izgubili svaki uređaj prijavljen na vaš nalog. Potrebni su vam lozinka i ključ za oporavak. Ako je neki vaš uređaj korišćen u poslednjih 7 dana, ovaj uređaj se pridružuje tek posle 7 dana, a ti uređaji mogu da otkažu oporavak. Istorija poruka se vraća samo iz rezervne kopije vraćene na ovaj uređaj.';

  @override
  String get recoveryStartSubmit => 'Započni oporavak';

  @override
  String get recoveryKeyUnreadable =>
      'Taj ključ za oporavak nije ispravan. Proverite da li ima grešaka u kucanju.';

  @override
  String get recoveryKeyNotThisAccount =>
      'To nije ključ za oporavak ovog naloga. Proverite papir i pokušajte ponovo.';

  @override
  String get recoveryKeyConfirmedForList => 'Ključ za oporavak je potvrđen.';

  @override
  String get recoveryRetypeDone => 'Oporavak je dovršen na ovom uređaju.';

  @override
  String get recoveryClaimRefused =>
      'Lozinka ili ključ za oporavak nije ispravan, adresa servera se razlikuje od zapisane, ili ovaj nalog ne može da se oporavi.';

  @override
  String get recoveryBackupOtherAccount =>
      'Rezervna kopija vraćena na ovaj uređaj pripada drugom nalogu ili serveru. Ovde oporavite taj nalog ili prvo resetujte ovaj uređaj.';

  @override
  String get recoverySignedInAlready => 'Ovaj uređaj je već prijavljen.';

  @override
  String get recoveryAlreadyPending => 'Oporavak već čeka na ovom uređaju.';

  @override
  String get recoveryDeviceLinkInProgress =>
      'Na ovom uređaju je u toku povezivanje uređaja, pa oporavak naloga ne može da počne ovde.';

  @override
  String get recoveryWaitingTitle => 'Oporavak čeka';

  @override
  String recoveryWaitingDetail(String date) {
    return 'Ovaj uređaj se pridružuje vašem nalogu posle $date. Aplikacija sama proverava dok je otvorena. Vaši drugi uređaji mogu da otkažu ovaj oporavak.';
  }

  @override
  String get recoveryReadyDetail =>
      'Čekanje je završeno. Proverite sada da biste završili.';

  @override
  String get recoveryCheckNow => 'Proveri sada';

  @override
  String get recoveryAbandon => 'Prekini oporavak';

  @override
  String get recoveryAbandonTitle => 'Prekinuti oporavak na ovom uređaju?';

  @override
  String get recoveryAbandonMessage =>
      'Ovaj uređaj zaboravlja zahtev. Da biste pokušali ponovo, ponovo su vam potrebni lozinka i ključ za oporavak.';

  @override
  String get recoveryRequestEnded =>
      'Ovaj oporavak je otkazan ili je istekao. Otkazuje ga promena lozinke ili ključa za oporavak, ili neki vaš uređaj. Možete da počnete ponovo.';

  @override
  String get recoveryLoginTitle => 'Prijavite se da biste završili';

  @override
  String get recoveryLoginDetail =>
      'Vaš nalog je oporavljen na ovom uređaju, ali odgovor nije stigao. Unesite lozinku da biste završili.';

  @override
  String get recoveryLoginSubmit => 'Prijavi se';

  @override
  String recoveryAccountLabel(String username) {
    return 'Nalog: $username';
  }

  @override
  String recoveryPendingNotice(String device, String date) {
    return 'Neko oporavlja vaš nalog na uređaju „$device”, do $date. Niste vi? Otkažite ili promenite lozinku ili ključ za oporavak.';
  }

  @override
  String get recoveryPendingCancel => 'Otkaži oporavak';

  @override
  String get recoveryCancelTitle => 'Otkazati ovaj oporavak?';

  @override
  String get recoveryCancelMessage =>
      'Novi uređaj se neće pridružiti vašem nalogu. Ako to niste bili vi, promenite i lozinku.';

  @override
  String get recoveryCancelled => 'Oporavak je otkazan.';

  @override
  String get passwordLeakNotice =>
      'Vaša lozinka je mnogo puta upotrebljena sa pogrešnim ključem za oporavak. Promenite lozinku.';

  @override
  String get passwordLeakDismiss => 'Zatvori';

  @override
  String get apiErrorRecoveryNotConfigured =>
      'Ovaj server nije uključio oporavak naloga.';

  @override
  String get apiErrorRecoveryBackoff =>
      'Previše pokušaja. Sačekajte malo, pa pokušajte ponovo.';

  @override
  String get apiErrorInvalidRecoveryKey =>
      'Server je odbio ovaj ključ za oporavak. Napravite novi.';

  @override
  String get recoveryAlreadyEnded =>
      'Ovaj oporavak je već završen ili ga je zamenio noviji.';

  @override
  String get apiErrorPasswordUnchanged =>
      'Izaberite lozinku koja se razlikuje od trenutne.';

  @override
  String get recoveryKeyServerAddress => 'Uz njega zapišite i adresu servera:';

  @override
  String recoveryKeyOriginMismatch(String current, String origin) {
    return 'Ovaj uređaj koristi $current, ali adresa servera za oporavak je $origin. Oporavak radi samo preko adrese $origin.';
  }

  @override
  String get joinTitle => 'Pridruži se linkom';

  @override
  String get joinLinkLabel => 'Pozivni link';

  @override
  String get joinLinkHint => 'Nalepite link koji ste dobili';

  @override
  String get joinCheck => 'Proveri link';

  @override
  String get joinLinkInvalid => 'Ovo nije pozivni link za ovaj server.';

  @override
  String get joinLinkUnusable => 'Ovaj link više ne radi. Zatražite novi.';

  @override
  String get joinKindGroup => 'Grupa';

  @override
  String get joinKindCommunity => 'Zajednica';

  @override
  String joinInvitedBy(String username) {
    return 'Pozvao vas je $username';
  }

  @override
  String get joinRequestButton => 'Zatraži pridruživanje';

  @override
  String get joinRequestNote =>
      'Vlasnik ili administrator mora da odobri vaš zahtev. Do tada nemate pristup.';

  @override
  String get joinAlreadyMember => 'Već ste član.';

  @override
  String get joinRequestSent =>
      'Zahtev je poslat. Ostaje među vašim zahtevima dok neko ne odluči.';

  @override
  String get joinYourRequests => 'Vaši zahtevi';

  @override
  String get joinNoRequests => 'Još nema zahteva.';

  @override
  String get joinStatusPending => 'Čeka odobrenje';

  @override
  String get joinStatusApproved =>
      'Odobreno. Šifrovani pristup sledi kada uređaj nekog člana ažurira grupu.';

  @override
  String get joinStatusRejected => 'Odbijeno';

  @override
  String get joinStatusCancelled => 'Otkazano';

  @override
  String get joinCancelRequest => 'Otkaži zahtev';

  @override
  String get membInviteSection => 'Pozivni linkovi';

  @override
  String get membInviteManage => 'Pozivi i zahtevi za pridruživanje';

  @override
  String get membInviteCreate => 'Napravi pozivni link';

  @override
  String get membInviteCreateDetail =>
      'Važi 7 dana i za najviše 10 ljudi, a svaku osobu i dalje morate da odobrite.';

  @override
  String get membInviteCreatedNote =>
      'Kopirajte ovaj link sada. Nije sačuvan na serveru i ne može se ponovo prikazati.';

  @override
  String get membInviteCopy => 'Kopiraj link';

  @override
  String get membInviteCopied => 'Link je kopiran.';

  @override
  String get membInviteNone => 'Nema aktivnih linkova.';

  @override
  String membInviteUses(int used, int max, String date) {
    return '$used od $max iskorišćeno · ističe $date';
  }

  @override
  String get membInviteRevoke => 'Opozovi link';

  @override
  String get joinReqSection => 'Zahtevi za pridruživanje';

  @override
  String get joinReqNone => 'Niko ne čeka.';

  @override
  String joinReqAskedAt(String date) {
    return 'Zatraženo $date';
  }

  @override
  String joinReqApprove(String username) {
    return 'Odobri $username';
  }

  @override
  String joinReqReject(String username) {
    return 'Odbij $username';
  }

  @override
  String get joinReqRejectedSnack => 'Zahtev je odbijen.';

  @override
  String communityRemoveTitle(String username) {
    return 'Ukloniti $username iz zajednice?';
  }

  @override
  String get communityRemoveMessage =>
      'Odmah gube pristup svim kanalima. Poruke koje su već na njihovim uređajima nisu obrisane.';

  @override
  String get communityRemoveConfirm => 'Ukloni';

  @override
  String get communityLeaveTitle => 'Napustiti ovu zajednicu?';

  @override
  String get communityLeave => 'Napusti zajednicu';

  @override
  String get communityLeaveDetail =>
      'Napuštate sve kanale odjednom. Ponovo se možete pridružiti novim linkom.';

  @override
  String get communityLeaveConfirm => 'Napusti';

  @override
  String get pollComposerTitle => 'Nova anketa';

  @override
  String get pollQuestionLabel => 'Pitanje';

  @override
  String pollOptionLabel(String number) {
    return 'Opcija $number';
  }

  @override
  String get pollAddOption => 'Dodaj opciju';

  @override
  String get pollRemoveOption => 'Ukloni opciju';

  @override
  String get pollMultipleChoice => 'Dozvoli više odgovora';

  @override
  String get pollSend => 'Pošalji anketu';

  @override
  String get pollInvalidHint => 'Dodajte pitanje i bar dve različite opcije.';

  @override
  String get pollVisibleNotice =>
      'Svi u ovom razgovoru vide ko je za šta glasao.';

  @override
  String pollVoteTotal(String count) {
    return 'Glasova: $count';
  }

  @override
  String get pollChooseOne => 'Izaberite jednu opciju';

  @override
  String get pollChooseSeveral => 'Izaberite jednu ili više opcija';

  @override
  String get pollClose => 'Zatvori anketu';

  @override
  String get pollClosedNotice => 'Ova anketa je zatvorena.';

  @override
  String get voiceNoteRecord => 'Snimite glasovnu poruku';

  @override
  String get voiceNoteStop => 'Zaustavi i priloži';

  @override
  String get voiceNoteDiscard => 'Odbaci snimak';

  @override
  String voiceNoteRecording(String time) {
    return 'Snimanje $time';
  }

  @override
  String get voiceNotePermissionDenied =>
      'Pristup mikrofonu je isključen. Dozvolite ga u podešavanjima sistema da biste snimali.';

  @override
  String get voiceNoteRecordFailed => 'Snimanje nije moglo da počne.';

  @override
  String get voiceNotePlay => 'Pusti';

  @override
  String get voiceNotePause => 'Pauziraj';

  @override
  String voiceNoteSemantics(String size) {
    return 'Glasovna poruka, $size';
  }

  @override
  String get voiceNotePlayFailed => 'Glasovna poruka nije mogla da se pusti.';

  @override
  String get callStartVoice => 'Glasovni poziv';

  @override
  String get callStartVideo => 'Video poziv';

  @override
  String get callUnknownContact => 'Nepoznat kontakt';

  @override
  String get callIncoming => 'Dolazni poziv';

  @override
  String get callIncomingVideo => 'Dolazni video poziv';

  @override
  String get callRinging => 'Pozivam…';

  @override
  String get callConnecting => 'Povezujem…';

  @override
  String get callInProgress => 'Poziv u toku';

  @override
  String get callRelayNote =>
      'Ovaj poziv ide preko releja servera, pa druga strana nikad ne vidi vašu mrežnu adresu.';

  @override
  String get callAccept => 'Prihvati';

  @override
  String get callDecline => 'Odbij';

  @override
  String get callHangUp => 'Prekini';

  @override
  String get callMute => 'Isključi zvuk';

  @override
  String get callUnmute => 'Uključi zvuk';

  @override
  String get callSpeaker => 'Zvučnik';

  @override
  String get callCameraOff => 'Isključi kameru';

  @override
  String get callCameraOn => 'Uključi kameru';

  @override
  String get callDismiss => 'Zatvori';

  @override
  String callNoticeMissed(String name) {
    return 'Propušten poziv: $name';
  }

  @override
  String callNoticeDeclined(String name) {
    return '$name je odbio/la poziv';
  }

  @override
  String callNoticeNoAnswer(String name) {
    return '$name se nije javio/la';
  }

  @override
  String callNoticeBusy(String name) {
    return '$name je zvao/la dok ste razgovarali';
  }

  @override
  String get callNoticeFailed =>
      'Poziv nije uspeo da se poveže. Za pozive je potrebna podešena relejna (TURN) usluga servera.';

  @override
  String get roomStart => 'Grupni poziv';

  @override
  String get roomTitle => 'Grupni poziv';

  @override
  String get roomJoining => 'Pridružujem se…';

  @override
  String get roomConnected => 'U pozivu';

  @override
  String get roomEncryptedNote =>
      'Glas i video su šifrovani od kraja do kraja. Server ih prenosi, ali ne može da ih čuje.';

  @override
  String get roomLeave => 'Napusti';

  @override
  String get roomYou => 'Vi';

  @override
  String get roomMute => 'Isključi zvuk';

  @override
  String get roomUnmute => 'Uključi zvuk';

  @override
  String get roomShareScreen => 'Podeli ekran';

  @override
  String get roomStopSharing => 'Zaustavi deljenje';

  @override
  String get roomFailedFull => 'Ovaj poziv je pun.';

  @override
  String get roomFailedUnavailable =>
      'Grupni pozivi nisu podešeni na ovom serveru.';

  @override
  String get roomFailedWelcome =>
      'Bezbedno pridruživanje nije uspelo. Pokušajte ponovo.';

  @override
  String get roomFailedOther => 'Poziv nije mogao da se nastavi.';

  @override
  String get roomFailedCryptor =>
      'Ovaj uređaj ne može da zaštiti medije poziva, pa se nije pridružio.';

  @override
  String roomPeople(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count osoba',
      few: '$count osobe',
      one: '$count osoba',
    );
    return '$_temp0';
  }

  @override
  String get moderationTitle => 'Moderacija';

  @override
  String get moderationDetail =>
      'Zabrane, utišavanje članova, spori režim, pauziranje pozivnica i dnevnik aktivnosti';

  @override
  String memberModerateTooltip(String username) {
    return 'Moderiraj $username';
  }

  @override
  String get memberBanAction => 'Zabrani…';

  @override
  String get memberTimeoutAction => 'Privremeno utišaj…';

  @override
  String get memberTimeoutLift => 'Ukini utišavanje';

  @override
  String banTitle(String username) {
    return 'Zabraniti $username?';
  }

  @override
  String get banMessage =>
      'Uklanjaju se iz zajednice i ne mogu se vratiti dok se zabrana ne ukine.';

  @override
  String get banConfirm => 'Zabrani';

  @override
  String timeoutTitle(String username) {
    return 'Koliko dugo utišati $username?';
  }

  @override
  String get timeoutDone => 'Utišavanje je postavljeno.';

  @override
  String get moderationSectionInvites => 'Pozivnice';

  @override
  String get moderationInvitesOpen => 'Veze za pozivnice rade normalno.';

  @override
  String moderationInvitesPaused(String time) {
    return 'Pauzirano do $time.';
  }

  @override
  String get moderationPauseInvites => 'Pauziraj pozivnice';

  @override
  String get moderationResumeInvites => 'Nastavi pozivnice';

  @override
  String get moderationSectionSlow => 'Spori režim';

  @override
  String get moderationSlowOff => 'Isključeno';

  @override
  String moderationSlowEvery(String interval) {
    return 'Jedna poruka na svakih $interval';
  }

  @override
  String moderationSlowTitle(String channel) {
    return 'Spori režim u kanalu $channel';
  }

  @override
  String get moderationSectionBans => 'Zabranjeni nalozi';

  @override
  String get moderationNoBans => 'Niko nije zabranjen.';

  @override
  String moderationUnban(String username) {
    return 'Ukini zabranu za $username';
  }

  @override
  String get moderationSectionLog => 'Dnevnik aktivnosti';

  @override
  String get moderationNoEvents => 'Još ništa.';

  @override
  String moderationLogKick(String actor, String target) {
    return '$actor je uklonio/la $target';
  }

  @override
  String moderationLogBan(String actor, String target) {
    return '$actor je zabranio/la $target';
  }

  @override
  String moderationLogUnban(String actor, String target) {
    return '$actor je ukinuo/la zabranu za $target';
  }

  @override
  String moderationLogTimeout(String actor, String target) {
    return '$actor je utišao/la $target';
  }

  @override
  String moderationLogTimeoutCleared(String actor, String target) {
    return '$actor je ukinuo/la utišavanje za $target';
  }

  @override
  String moderationLogSlowMode(String actor) {
    return '$actor je promenio/la spori režim';
  }

  @override
  String moderationLogInvitesPaused(String actor) {
    return '$actor je pauzirao/la pozivnice';
  }

  @override
  String moderationLogInvitesResumed(String actor) {
    return '$actor je nastavio/la pozivnice';
  }

  @override
  String get c6ReportMessage => 'Prijavi poruku';

  @override
  String get c6ReportTitle => 'Prijavi ovu poruku';

  @override
  String get c6ReportIntro =>
      'Ovim se šalje samo ova jedna poruka, sa dokazom da je autentična, vlasnicima ovog servera. Zapečaćena je, pa je sam server ne može pročitati. Ništa drugo iz ćaskanja se ne šalje.';

  @override
  String get c6ReportPreviewLabel => 'Ova poruka će biti poslata';

  @override
  String get c6ReportPreviewNoText =>
      'Poruka bez teksta, na primer prilog. Šalju se njeni podaci, uključujući ključ kojim se datoteka otvara, ali ne i sama datoteka.';

  @override
  String get c6ReportSend => 'Pošalji prijavu';

  @override
  String get c6ReportSent => 'Prijava je poslata.';

  @override
  String c6ReportRecipientCount(int count) {
    return 'Vlasnika servera koji dobijaju kopiju: $count';
  }

  @override
  String get c6ReportPinTitle => 'Proveri ključeve vlasnika';

  @override
  String get c6ReportPinBody =>
      'Zamoli svakog vlasnika da ti pročita kod iz Podešavanja, Prijave, na svom uređaju. Ako se poklapa, veruj mu. Ako se ne poklapa, ne šalji prijavu.';

  @override
  String c6ReportOwnerKey(String owner, String fingerprint) {
    return 'Vlasnik $owner: $fingerprint';
  }

  @override
  String get c6ReportKeyChanged =>
      'Ključ ovog vlasnika se promenio od kada si mu poslednji put verovao. Pitaj ga da li ga je promenio.';

  @override
  String get c6ReportKeyMissing =>
      'Vlasnik kome si ranije verovao sada ne dobija kopiju. Moguće je da ga server zadržava.';

  @override
  String get c6ReportTrust => 'Verujem, nastavi';

  @override
  String get c6ReportCommunityUnavailable =>
      'Prijave moderatorima zajednice još nisu dostupne.';

  @override
  String get c6ReportNoOwnerKey =>
      'Nijedan vlasnik servera još ne može da prima prijave. Zamoli ga da podesi ključ za prijave.';

  @override
  String get c6ReportNotReportable =>
      'Ova poruka se ne može prijaviti. Primljena je pre uvođenja prijava, poslata je bez dokaza ili je obrisana.';

  @override
  String get c6ReportKeysNotPinned =>
      'Ključ vlasnika još nije poveren. Ponovo otvori prijavu i proveri ga.';

  @override
  String get c6ReportAlready => 'Već si prijavio ovu poruku.';

  @override
  String get c6ReportUnavailable =>
      'Prijavljivanje nije dostupno u ovoj verziji.';

  @override
  String get c6ReportsTitle => 'Prijave';

  @override
  String get c6ReportsSettingsDetail =>
      'Poruke koje su ti ljudi prijavili kao vlasniku servera';

  @override
  String get c6ReportsKeySection => 'Ključ za prijave';

  @override
  String get c6ReportsKeyNone =>
      'Ovaj uređaj nema ključ za prijave. Bez njega ti niko ne može slati prijave.';

  @override
  String get c6ReportsKeyActive =>
      'Ovaj uređaj drži tvoj ključ za prijave. Pročitaj njegov kod ljudima koji traže da ga provere.';

  @override
  String c6ReportsKeyCode(String fingerprint) {
    return 'Kod: $fingerprint';
  }

  @override
  String get c6ReportsKeyCreate => 'Napravi ključ za prijave';

  @override
  String get c6ReportsKeyCreateTitle => 'Napraviti novi ključ za prijave ovde?';

  @override
  String get c6ReportsKeyCreateBody =>
      'Ako već imaš ključ za prijave na drugom uređaju, ovaj ga zamenjuje. Prijave već poslate na stari ključ otvaraju se samo na uređaju koji još drži taj ključ, a na ovom su izgubljene. Ljudi moraju da poveruju novom ključu pre sledeće prijave.';

  @override
  String get c6ReportsKeyReplace => 'Zameni ključ';

  @override
  String get c6ReportsKeyPublish => 'Objavi ključ ponovo';

  @override
  String get c6ReportsKeyReady => 'Ključ za prijave je objavljen.';

  @override
  String get c6ReportsEmpty => 'Nema prijava';

  @override
  String get c6ReportsEmptyDetail =>
      'Prijave se čuvaju dok ih ne odbaciš ili 90 dana.';

  @override
  String get c6ReportsCommunity => 'Prijave zajednice';

  @override
  String get c6ReportsCommunityUnavailable =>
      'Još nije dostupno. Prijave moderatorima stižu uz uloge u zajednici.';

  @override
  String c6ReportsFiled(String when) {
    return 'Prijavljeno $when';
  }

  @override
  String get c6ReportsLocked => 'Ne može da se otvori';

  @override
  String get c6ReportsLockedNoSeed =>
      'Ovaj uređaj nema ključ za prijave, pa ne može da otvori ovu prijavu. Otvori je na uređaju koji je napravio tvoj ključ.';

  @override
  String get c6ReportsLockedOtherKey =>
      'Poslato na stariji ključ za prijave koji ovaj uređaj ne drži.';

  @override
  String get c6ReportsLockedDamaged =>
      'Ova prijava je oštećena ili nije bila namenjena tebi.';

  @override
  String get c6ReportsMessageLabel => 'Prijavljena poruka';

  @override
  String get c6ReportsNoText =>
      'Nije tekstualna poruka. Njeni podaci, uključujući ključ kojim se datoteka otvara, nalaze se u prijavi, ali ne i sama datoteka.';

  @override
  String c6ReportsReporter(String account) {
    return 'Prijavio nalog $account';
  }

  @override
  String c6ReportsSender(String account) {
    return 'Poslao nalog $account';
  }

  @override
  String get c6ReportsCheck => 'Proveri prema zapisima servera';

  @override
  String get c6ReportsChecking => 'Proveravam…';

  @override
  String get c6ReportsCheckNote =>
      'Proverom server saznaje o kojoj se poruci radi u ovoj prijavi.';

  @override
  String get c6VerdictVerified => 'Poklapa se sa zapisom servera';

  @override
  String get c6VerdictVerifiedDetail =>
      'Server je zabeležio baš ovu poruku ovog pošiljaoca u ovom razgovoru. To je pouzdano samo koliko i sopstveni zapis servera.';

  @override
  String get c6VerdictMismatch => 'Ne poklapa se';

  @override
  String get c6VerdictMismatchDetail =>
      'Zapis servera se ne slaže sa ovom prijavom. Smatraj je nedokazanom ili lažnom.';

  @override
  String get c6VerdictGone => 'Ne može da se proveri';

  @override
  String get c6VerdictGoneDetail =>
      'Server više nema ovu poruku, pa nema šta da se uporedi.';

  @override
  String get c6VerdictUnfranked => 'Ne može da se dokaže';

  @override
  String get c6VerdictUnfrankedDetail =>
      'Ovu poruku je poslala aplikacija koja ne dodaje dokaz.';

  @override
  String get c6ReportsDismiss => 'Odbaci prijavu';

  @override
  String get c6ReportsDismissTitle => 'Odbaciti ovu prijavu?';

  @override
  String get c6ReportsDismissBody =>
      'Ovo zauvek uklanja tvoju kopiju. Ostali vlasnici zadržavaju svoje.';

  @override
  String get c6ReportsDismissed => 'Prijava je odbačena.';

  @override
  String get c6ReportsKeyElsewhere =>
      'Tvoj ključ za prijave je na drugom uređaju. Prijave za njega se otvaraju tamo, ne ovde.';

  @override
  String get c6ReportsKeyReplacedElsewhere =>
      'Drugi uređaj je zamenio tvoj ključ za prijave. Nove prijave idu na ključ ispod; ovaj uređaj otvara samo prijave poslate na njegov stariji ključ.';

  @override
  String get c6ReportsKeyUnpublished =>
      'Ovaj uređaj drži ključ za prijave koji još nije objavljen. Objavi ga da bi ti ljudi mogli slati prijave.';

  @override
  String get c6SignOutSeedWarning =>
      'Ovaj uređaj drži tvoj ključ za prijave. Odjavom se on briše, a prijave već poslate na njega više se ne mogu otvoriti. Prvo obradi svoje prijave.';

  @override
  String get autoBackupTitle => 'Automatske rezervne kopije';

  @override
  String get autoBackupIntro =>
      'Svakog dana ovaj uređaj pravi rezervnu kopiju vaših razgovora, zaključanu vašim ključem za oporavak. Samo taj ključ je otvara; server ne može. Nova kopija zamenjuje staru. Poruke koje nestaju se nikada ne kopiraju.';

  @override
  String get autoBackupIntroPhone =>
      'Ovaj telefon pravi rezervnu kopiju vaših razgovora kada otvorite aplikaciju, najviše jednom dnevno, zaključanu vašim ključem za oporavak. Samo taj ključ je otvara; server ne može. Nova kopija zamenjuje staru. Poruke koje nestaju se nikada ne kopiraju.';

  @override
  String autoBackupLast(String date) {
    return 'Poslednja kopija $date';
  }

  @override
  String get autoBackupPending => 'Prva kopija još nije napravljena';

  @override
  String get autoBackupServerOff =>
      'Ovaj server ima isključene rezervne kopije';

  @override
  String get autoBackupNoKey =>
      'Sačuvajte ključ za oporavak da biste uključili rezervne kopije';

  @override
  String get autoBackupNeedsKeyHere =>
      'Unesite ključ za oporavak da biste uključili rezervne kopije ovde';

  @override
  String get autoBackupKeyChanged =>
      'Vaš ključ za oporavak je promenjen. Unesite novi ključ da bi se kopije nastavile ovde.';

  @override
  String get autoBackupErrorNetwork =>
      'Poslednja kopija nije stigla do servera. Pokušaće ponovo.';

  @override
  String get autoBackupErrorSpace =>
      'Prostor za kopije je pun. Poslednja dobra kopija se čuva.';

  @override
  String get autoBackupErrorTooLarge =>
      'Vaša istorija je prevelika za kopiju. Poslednja dobra kopija se čuva.';

  @override
  String get autoBackupErrorFailed =>
      'Poslednja kopija nije uspela. Pokušaće ponovo.';

  @override
  String get autoBackupStale => 'Nema kopije više od nedelju dana.';

  @override
  String get autoBackupPhoneNote =>
      'Ovaj telefon pravi kopiju kada otvorite aplikaciju.';

  @override
  String get autoBackupNow => 'Napravi kopiju sada';

  @override
  String get autoBackupRunning => 'Pravi se kopija…';

  @override
  String get autoBackupTypeKey => 'Unesite ključ za oporavak';

  @override
  String get autoBackupKeyWrong => 'To nije ključ za oporavak ovog naloga.';

  @override
  String get autoBackupKeyOn => 'Rezervne kopije su uključene na ovom uređaju.';

  @override
  String get autoBackupPromptMessage =>
      'Sačuvajte ključ za oporavak. Uključuje automatske rezervne kopije i vraća vaš nalog ako izgubite sve uređaje.';

  @override
  String get autoBackupPromptSave => 'Sačuvaj ključ';

  @override
  String get autoBackupPromptLater => 'Ne sada';

  @override
  String get channelPrivate => 'Privatni kanal';

  @override
  String get channelPrivateDisclosure =>
      'Samo izabrani članovi vide ovaj kanal. Server vidi ko je u njemu.';

  @override
  String get channelOpenDisclosure => 'Svaki član zajednice vidi ovaj kanal.';

  @override
  String get channelCreateFailed => 'Kanal nije napravljen. Pokušajte ponovo.';

  @override
  String get channelMembersFailed =>
      'Kanal je napravljen. Neki članovi nisu dodati. Pokušajte ponovo da dodate samo te članove.';

  @override
  String get channelAdminOnly =>
      'Samo vlasnici i administratori mogu da prave kanale.';

  @override
  String get k1ConfirmTitle => 'Proverite ključ za oporavak';

  @override
  String get k1ConfirmDetail =>
      'Unesite ga još jednom da budete sigurni da ga imate. Nikad ne napušta ovaj uređaj.';

  @override
  String get k1ConfirmOk => 'To je vaš ključ za oporavak.';

  @override
  String get k1ConfirmMismatch =>
      'Ne poklapa se. Ako ste izgubili ključ, napravite novi u podešavanjima ključa za oporavak.';

  @override
  String get k1SecondCopyChoose => 'Čuvaj drugu kopiju u fascikli';

  @override
  String k1SecondCopyFolder(String folder) {
    return 'Druga kopija: $folder';
  }

  @override
  String get k1SecondCopyDetail =>
      'Ista zaključana kopija, sačuvana gde izaberete. Otvara je samo ključ za oporavak.';

  @override
  String get k1SecondCopyFailed =>
      'Poslednje kopiranje u ovu fasciklu nije uspelo. Proverite fasciklu.';

  @override
  String get k1SecondCopyOff => 'Zaustavi drugu kopiju';

  @override
  String get k1SecondCopyPhone =>
      'Druga kopija u fascikli je dostupna na računaru. Telefoni čuvaju kopiju samo na serveru.';

  @override
  String get recoveryFollowUpRestoreDetail =>
      'Pre nego što zamenite ključ za oporavak, možete vratiti istoriju iz kopija koje su napravili vaši izgubljeni uređaji. One se otvaraju vašim starim ključem, koji za njih prestaje da važi kad ga zamenite.';

  @override
  String get recoveryFollowUpRestoreSkip => 'Preskoči';

  @override
  String get recoveryFollowUpRestoreSkipWarning =>
      'Ako preskočite, starije kopije postaju neupotrebljive čim zamenite ključ za oporavak. Preskočiti ipak?';

  @override
  String get k1RestoreOpen => 'Vrati iz rezervne kopije';

  @override
  String get k1RestoreTitle => 'Vraćanje iz rezervne kopije';

  @override
  String get k1RestoreIntro =>
      'Izaberite kopiju koju je napravio neki drugi vaš uređaj i unesite ključ za oporavak. Istorija se spaja sa ovom; poruke koje već postoje ostaju.';

  @override
  String get k1RestoreLoading => 'Tražim rezervne kopije…';

  @override
  String get k1RestoreEmpty => 'Nije pronađena kopija sa drugog uređaja.';

  @override
  String get k1RestoreLegacyRefused =>
      'Kopije u starom formatu (napravljene pre automatskih kopija) više se ne mogu vratiti. Nisu menjane, ali ih aplikacija ne otvara.';

  @override
  String get k1RestoreLoadFailed => 'Spisak rezervnih kopija nije učitan.';

  @override
  String k1RestoreEntry(String device, String date) {
    return '$device · $date';
  }

  @override
  String k1RestoreEntryPrevious(String device, String date) {
    return '$device · $date (prethodna kopija)';
  }

  @override
  String get k1RestoreDeviceUnnamed => 'Uređaj';

  @override
  String get k1RestoreDeviceRevoked =>
      'Ovaj uređaj je uklonjen sa vašeg naloga.';

  @override
  String get k1RestoreDone => 'Istorija je vraćena.';

  @override
  String get k1RestoreWrongKey =>
      'To nije ispravan ključ za oporavak ovog naloga.';

  @override
  String get k1RestoreOtherKey =>
      'Ova kopija je zaključana drugim ključem za oporavak.';

  @override
  String get k1RestoreCorrupt =>
      'Kopija se ne može otvoriti. Možda je oštećena.';

  @override
  String get k1RestoreNetwork => 'Server nije dostupan. Ništa nije promenjeno.';

  @override
  String get k1RestoreUnavailable => 'Ovaj uređaj ne može da vrati kopiju.';

  @override
  String get connectSignInPasskey => 'Prijava pristupnim ključem';

  @override
  String get passkeySignInFailed =>
      'Prijava pristupnim ključem nije uspela. Pokušajte ponovo ili koristite lozinku.';

  @override
  String get passkeyUnavailable =>
      'Pristupni ključevi nisu dostupni na ovom uređaju ili nisu podešeni za ovaj server.';

  @override
  String get passkeyPinRefused =>
      'Server je zatražio pristupni ključ za drugu adresu, pa ga aplikacija odbija.';

  @override
  String get apiErrorPasskeyLimit =>
      'Dostigli ste granicu broja pristupnih ključeva. Prvo uklonite jedan.';

  @override
  String get apiErrorPasskeyExists => 'Ovaj pristupni ključ je već dodat.';

  @override
  String get apiErrorInvalidPasskey =>
      'Server nije mogao da proveri taj pristupni ključ.';

  @override
  String get apiErrorPasskeysOff => 'Ovaj server ne nudi pristupne ključeve.';

  @override
  String get settingsPasskeys => 'Pristupni ključevi';

  @override
  String get settingsPasskeysDetail =>
      'Prijava zaključavanjem ekrana umesto lozinke';

  @override
  String get passkeysIntro =>
      'Pristupni ključ vas prijavljuje na ovom uređaju umesto lozinke. Za promene podešavanja i dalje se traži lozinka. Usluga koja čuva vaš pristupni ključ, na primer Google ili Apple, saznaje adresu ovog servera.';

  @override
  String get passkeysNotOffered =>
      'Pristupni ključevi nisu dostupni za ovaj server na ovom uređaju.';

  @override
  String get passkeysEmpty => 'Još nema pristupnih ključeva.';

  @override
  String get passkeysAdd => 'Dodaj pristupni ključ';

  @override
  String get passkeysAdded => 'Pristupni ključ je dodat.';

  @override
  String passkeyCreated(String date) {
    return 'Dodat $date';
  }

  @override
  String passkeyLastUsed(String date) {
    return 'Poslednja upotreba $date';
  }

  @override
  String get passkeyBackedUp => 'Rezervna kopija postoji';

  @override
  String get passkeyRename => 'Preimenuj';

  @override
  String get passkeyRemove => 'Ukloni';

  @override
  String get passkeyNameLabel => 'Naziv';

  @override
  String get passkeyRemoveTitle => 'Ukloniti ovaj pristupni ključ?';

  @override
  String passkeyRemoveBody(String name) {
    return '„$name” se više neće prijavljivati na ovaj nalog. Možete ga ponovo dodati kasnije.';
  }

  @override
  String get passkeyRemoved => 'Pristupni ključ je uklonjen.';

  @override
  String get passkeyNoticeAdded =>
      'Pristupni ključ je dodat vašem nalogu. Niste vi? Promenite lozinku.';

  @override
  String get passkeyNoticeRemoved =>
      'Pristupni ključ je uklonjen sa vašeg naloga.';

  @override
  String get passkeyNoticeDismiss => 'Odbaci';

  @override
  String get passkeyNamePrefix => 'Pristupni ključ';

  @override
  String get settingsAccounts => 'Nalozi';

  @override
  String get settingsAccountsDetail =>
      'Prebacivanje između naloga na ovom uređaju';

  @override
  String get accountsTitle => 'Nalozi';

  @override
  String get accountsIntro =>
      'Jedan nalog je otvoren u isto vreme. Ostali su pauzirani: za njih ne stižu poruke ni obaveštenja dok se na njih ne prebacite.';

  @override
  String get accountsOpenNow => 'Otvoren';

  @override
  String get accountsPending => 'Još nije prijavljen';

  @override
  String get accountsRemoving => 'Uklanjanje…';

  @override
  String get accountsNewAccount => 'Novi nalog';

  @override
  String get accountsAdd => 'Dodaj nalog';

  @override
  String accountsFull(String count) {
    return 'Ovaj uređaj drži $count naloga, najviše što može. Uklonite jedan da biste dodali drugi.';
  }

  @override
  String get accountsSameServer =>
      'Ovaj server može da zaključi da su ovi nalozi na istom uređaju.';

  @override
  String get accountsSwitching => 'Prebacivanje…';

  @override
  String accountsSwitchTo(String name) {
    return 'Prebaci na $name';
  }

  @override
  String get accountsRemove => 'Ukloni sa ovog uređaja';

  @override
  String accountsRemoveTitle(String name) {
    return 'Ukloniti $name sa ovog uređaja?';
  }

  @override
  String get accountsRemoveBody =>
      'Nalog se odjavljuje, a njegove poruke i ključevi brišu sa ovog uređaja. Nalog ostaje na svom serveru. Ako više nećete koristiti ovaj uređaj, uklonite ga sa liste uređaja naloga na drugom uređaju.';

  @override
  String get accountsPushFailTitle => 'Ipak prebaciti?';

  @override
  String accountsPushFailBody(String name) {
    return 'Obaveštenja za $name nisu mogla da se isključe. Možda ćete dobijati obaveštenja za ovaj nalog dok ga ponovo ne otvorite.';
  }

  @override
  String get accountsSwitchAnyway => 'Ipak prebaci';

  @override
  String get accountsErrorOpen =>
      'Taj nalog nije mogao da se otvori. Prethodni nalog je ponovo otvoren.';

  @override
  String get accountsErrorRegistry => 'Spisak naloga nije mogao da se sačuva.';

  @override
  String get accountsErrorRemove =>
      'Nalog nije mogao da se ukloni. Pokušajte ponovo.';

  @override
  String get accountsDuplicate =>
      'Ovaj uređaj već ima taj nalog, pa je dodatna prijava uklonjena. Uklonite višak uređaja sa liste uređaja naloga.';

  @override
  String get accountsBack => 'Nazad na moje naloge';

  @override
  String get settingsSectionUpdates => 'Ažuriranja';

  @override
  String get settingsAutoUpdateCheck => 'Automatski proveravaj ažuriranja';

  @override
  String get settingsAutoUpdateCheckDetail =>
      'Proveravaj nove verzije pri pokretanju';

  @override
  String get settingsCheckForUpdates => 'Proveri ažuriranja';

  @override
  String get settingsCheckingForUpdates => 'Provera ažuriranja…';

  @override
  String get settingsUpdateUpToDate => 'Veritra je ažurirana';

  @override
  String settingsUpdateAvailable(String version) {
    return 'Verzija $version je dostupna';
  }

  @override
  String get settingsUpdateError => 'Provera ažuriranja nije uspela';

  @override
  String get settingsUpdateDisabled =>
      'Automatska provera ažuriranja je isključena';

  @override
  String get settingsScreenGuard => 'Zaštita ekrana';

  @override
  String get settingsScreenGuardDetail =>
      'Blokiraj snimke ekrana i čitanje ekrana od strane AI asistenata u ćaskanjima.';

  @override
  String get communityInfoTitle => 'Kategorije i ikonica';

  @override
  String get communityIconChoose => 'Izaberi ikonicu';

  @override
  String get communityIconRemove => 'Ukloni ikonicu';

  @override
  String get communityCategories => 'Kategorije';

  @override
  String get communityCategoryNew => 'Nova kategorija';

  @override
  String get communityCategoryName => 'Naziv kategorije';

  @override
  String get communityCategoryRename => 'Preimenuj kategoriju';

  @override
  String get communityCategoryDelete => 'Obriši kategoriju';

  @override
  String get communityCategoryDeleteConfirm =>
      'Obrisati ovu kategoriju? Njeni kanali ostaju i prikazuju se bez kategorije.';

  @override
  String get communityCategoryPlaceholder => 'Kategorija';

  @override
  String get communityCategoryNone => 'Bez kategorije';

  @override
  String get communityChannelPlaces => 'Gde su kanali';

  @override
  String get communityInfoSaveFailed => 'Čuvanje nije uspelo. Pokušaj ponovo.';

  @override
  String get communityInfoOpen => 'Kategorije i ikonica';

  @override
  String get rolesTitle => 'Uloge';

  @override
  String get rolesDetail => 'Proverava aplikacija svakog člana, a ne server.';

  @override
  String get rolesNoRecord =>
      'Ova grupa je napravljena pre proverenih uloga, pa su prikazane uloge one koje kaže server.';

  @override
  String get rolesUnavailable =>
      'Uloge trenutno ne mogu da se pročitaju na ovom uređaju.';

  @override
  String rolesYou(String name) {
    return '$name (ti)';
  }

  @override
  String get rolesElector => 'Glasa za novog vlasnika';

  @override
  String get rolesMakeAdmin => 'Postavi za administratora';

  @override
  String get rolesMakeModerator => 'Postavi za moderatora';

  @override
  String get rolesMakeMember => 'Vrati u člana';

  @override
  String get rolesStepDown => 'Odstupi';

  @override
  String get rolesElectorOn => 'Dozvoli glasanje za novog vlasnika';

  @override
  String get rolesElectorOff => 'Zabrani glasanje za novog vlasnika';

  @override
  String get rolesTransfer => 'Predaj vlasništvo';

  @override
  String rolesTransferConfirm(String name) {
    return 'Predati ovu grupu korisniku $name? Ti postaješ administrator.';
  }

  @override
  String get rolesOwnership => 'Vlasništvo';

  @override
  String rolesElectionOpen(String votes, String total) {
    return 'Izbor vlasnika je u toku. Glasova: $votes od $total.';
  }

  @override
  String get rolesElectionNone =>
      'Ako vlasnik nije tu duže od 30 dana, administratori mogu da izaberu novog.';

  @override
  String get rolesStartElection => 'Pokreni izbor vlasnika';

  @override
  String rolesVoteFor(String name) {
    return 'Glasaj za: $name';
  }

  @override
  String get rolesCloseElection => 'Završi izbor';

  @override
  String get rolesOwnerCancelNote =>
      'Ti si vlasnik: tvoja aplikacija sama završava ovaj izbor.';

  @override
  String get rolesOnlyAdminsPost => 'Samo administratori objavljuju';
}
