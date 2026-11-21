; Inno Setup 6 definition for the Veritra Windows installer. UNSIGNED.
;
; Build (on Windows, after scripts\repro\build.ps1 produced the app folder):
;   iscc /DAppDir=C:\out\a /DAppVersion=0.1.0 /DOutDir=C:\out\installer release\windows\veritra.iss
;
; Not run here (no Windows). Inno Setup is a build tool, not a dependency of
; the app; the owner checks its license terms before first use.
; Newer code-signing certificates may need a hardware token or cloud signing
; instead of a PFX file: adjust the signtool line to what the CA provides.
; Updates: the app starts this installer with /SILENT /NORESTART /CLOSEAPPLICATIONS
; (mobile/lib/desktop/update_installer.dart) after the user pressed the update
; tile. The fixed AppId makes it replace the earlier install in place;
; CloseApplications closes a still-running Veritra first. A per-user install
; updates without admin rights; an all-users install needs them, so the user
; who chose "all users" is asked by Windows. "skipifsilent" keeps the finished
; installer from starting the app by itself during an update.
;
; SIGNING (owner): nothing in this file holds a certificate. After the owner
; buys a code-signing certificate, build with
;   scripts\build-windows-installer.ps1 -SignToolCommand 'signtool.exe sign /fd sha256 /tr <timestamp-url> /td sha256 /f <cert> /p <password> $f'
; which passes /DSignToolName=veritra and /Sveritra=<that command> to iscc, and
; the #ifdef SignToolName block below then signs the installer and the
; uninstaller. The certificate and password never go into this repository.
; Without it the installer is unsigned and SmartScreen warns on first run.

#ifndef AppDir
  #error Pass /DAppDir=<folder with private_messenger.exe>
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
; Fixed GUID: Windows uses it to find the previous install when updating.
AppId={{6D1B6D0E-5C57-4F5B-9B0B-7E0F7A3A9C11}
AppName=Veritra
AppVersion={#AppVersion}
AppPublisher=Veritra
AppPublisherURL=https://github.com/ServesYouRice/veritra
DefaultDirName={autopf}\Veritra
DefaultGroupName=Veritra
; Per-user install by default; no admin rights needed. The user can choose
; "all users" in the dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=Veritra-Setup-{#AppVersion}-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
SetupIconFile={#SourcePath}\..\..\mobile\windows\runner\resources\app_icon.ico
CloseApplications=yes
RestartApplications=no
; Per-user by default but the dialog can switch to all users: that is intended.
UsedUserAreasWarning=no
; Reproducibility of the installer itself is NOT measured (Inno stores file
; timestamps); only the app folder it packages is checked by verify.ps1.
UninstallDisplayIcon={app}\private_messenger.exe
LicenseFile={#SourcePath}\..\..\LICENSE
#ifdef SignToolName
SignTool={#SignToolName}
SignedUninstaller=yes
#endif

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Veritra"; Filename: "{app}\private_messenger.exe"
Name: "{autodesktop}\Veritra"; Filename: "{app}\private_messenger.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\private_messenger.exe"; Description: "Start Veritra"; Flags: nowait postinstall skipifsilent
