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
      'Овај уређај заузима место уређаја који је направио резервну копију. Прво престаните да користите тај уређај.';

  @override
  String get backupRecoveryCode => 'Код за опоравак';

  @override
  String get backupRestore => 'Врати';

  @override
  String get deviceLinkTitle => 'Повежи уређај';

  @override
  String get deviceLinkIntro =>
      'Генеришите једнократни код, унесите га на новом уређају, а затим га овде одобрите помоћу верификационог кода који приказује нови уређај.';

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
  String chatReactionCount(String reaction, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$reaction $countString';
  }

  @override
  String get chatEdited => 'измењено';

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
  String get errorOutboxFull =>
      'Ваш ред шифрованих порука је пун. Пошаљите или одбаците поруку на чекању пре него што напишете нову.';

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
      'Ovaj uređaj zauzima mesto uređaja koji je napravio rezervnu kopiju. Prvo prestanite da koristite taj uređaj.';

  @override
  String get backupRecoveryCode => 'Kod za oporavak';

  @override
  String get backupRestore => 'Vrati';

  @override
  String get deviceLinkTitle => 'Poveži uređaj';

  @override
  String get deviceLinkIntro =>
      'Generišite jednokratni kod, unesite ga na novom uređaju, a zatim ga ovde odobrite pomoću verifikacionog koda koji prikazuje novi uređaj.';

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
  String chatReactionCount(String reaction, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$reaction $countString';
  }

  @override
  String get chatEdited => 'izmenjeno';

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
  String get errorOutboxFull =>
      'Vaš red šifrovanih poruka je pun. Pošaljite ili odbacite poruku na čekanju pre nego što napišete novu.';

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
}
