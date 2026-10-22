import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// English strings, used when a widget is built outside [VeritraApp]'s
/// localizations (widget tests, the bare demo error screen). The app itself
/// always provides [AppLocalizations.delegate].
final AppLocalizations englishL10n = lookupAppLocalizations(const Locale('en'));

extension VeritraL10n on BuildContext {
  /// The app's localized strings for this context.
  AppLocalizations get l10n => AppLocalizations.of(this) ?? englishL10n;
}
