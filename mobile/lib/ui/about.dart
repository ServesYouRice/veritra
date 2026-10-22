import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'widgets/veritra_mark.dart';

/// The one product name every surface uses.
const String veritraProductName = 'Veritra';

/// Kept equal to the `version:` name in `pubspec.yaml` (a test checks it).
const String veritraVersion = '0.1.0';

const String veritraLicenseName = 'AGPL-3.0-or-later';
const String veritraSourceUrl = 'https://github.com/ServesYouRice/Veritra';

const String veritraLegalese =
    'Free software under the GNU Affero General Public License, version 3 '
    'or later ($veritraLicenseName). Source code: $veritraSourceUrl';

bool _licenseRegistered = false;

/// Adds Veritra's own license next to the bundled dependency notices that
/// Flutter's license page already lists.
void registerVeritraLicense() {
  if (_licenseRegistered) return;
  _licenseRegistered = true;
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.value(
      const LicenseEntryWithLineBreaks(
        <String>[veritraProductName],
        'Veritra is free software: you can redistribute it and/or modify it '
        'under the terms of the GNU Affero General Public License as '
        'published by the Free Software Foundation, either version 3 of the '
        'License, or (at your option) any later version.\n\n'
        'It is distributed in the hope that it will be useful, but WITHOUT '
        'ANY WARRANTY; without even the implied warranty of MERCHANTABILITY '
        'or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General '
        'Public License for more details.\n\n'
        'Source code: $veritraSourceUrl',
      ),
    ),
  );
}

Widget _icon(BuildContext context) =>
    VeritraMark(size: 40, color: Theme.of(context).colorScheme.onSurface);

void showVeritraAbout(BuildContext context) {
  registerVeritraLicense();
  showAboutDialog(
    context: context,
    applicationName: veritraProductName,
    applicationVersion: veritraVersion,
    applicationIcon: _icon(context),
    applicationLegalese: veritraLegalese,
  );
}

void showVeritraLicenses(BuildContext context) {
  registerVeritraLicense();
  showLicensePage(
    context: context,
    applicationName: veritraProductName,
    applicationVersion: veritraVersion,
    applicationIcon: _icon(context),
    applicationLegalese: veritraLegalese,
  );
}
