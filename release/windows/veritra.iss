; Inno Setup 6 definition for the Veritra Windows installer. UNSIGNED.
;
; Build (on Windows, after scripts\repro\build.ps1 produced the app folder):
;   iscc /DAppDir=C:\out\a /DAppVersion=0.1.0 /DOutDir=C:\out\installer release\windows\veritra.iss
;
; Not run here (no Windows). Inno Setup is a build tool, not a dependency of
; the app; check its license (free, custom) with the owner before first use.
;
; SIGNING PLACEHOLDER (owner): after the owner buys a code-signing certificate,
; define a SignTool named "veritra" in Inno's IDE or pass
;   /Sveritra="signtool.exe sign /fd sha256 /tr <timestamp-url> /td sha256 /f <cert> /p <password> $f"
; and remove the comment marker on the two SignTool lines below. The
; certificate and password never go into this repository.

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
; Reproducibility of the installer itself is NOT measured (Inno stores file
; timestamps); only the app folder it packages is checked by verify.ps1.
UninstallDisplayIcon={app}\private_messenger.exe
LicenseFile={#SourcePath}\..\..\LICENSE
; SignTool=veritra
; SignedUninstaller=yes

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Veritra"; Filename: "{app}\private_messenger.exe"
Name: "{autodesktop}\Veritra"; Filename: "{app}\private_messenger.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\private_messenger.exe"; Description: "Start Veritra"; Flags: nowait postinstall skipifsilent
