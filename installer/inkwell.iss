; Inno Setup script. Built by the release workflow:
;   ISCC.exe /DAppVersion=1.2.3 installer\inkwell.iss
; Output: dist\inkwell-windows-setup.exe
;
; Installs per-user (no admin prompt), so the in-app updater can run this
; installer silently over the top of an existing install.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define AppName "Inkwell"
#define AppExe "inkwell.exe"

[Setup]
; Never change AppId: it is how upgrades recognise the existing install.
AppId={{6B6C5C2E-3B7A-4C1D-9A55-4E2D2F0B7A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Inkwell
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=inkwell-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\{#AppExe}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; No "skipifsilent": after a silent in-app update the app relaunches itself.
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall
