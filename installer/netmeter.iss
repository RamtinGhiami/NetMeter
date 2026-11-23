; Per-user installer (no administrator rights). Build: ISCC installer\netmeter.iss  (after `flutter build windows --release`)
#ifndef AppVersion
#define AppVersion "0.4.2"
#endif
[Setup]
AppId={{9D4B7E21-6A35-4F0C-8C1E-5B2F7A93D6E8}
AppName=NetMeter
AppVersion={#AppVersion}
AppPublisher=NetMeter contributors
DefaultDirName={localappdata}\Programs\NetMeterApp
DefaultGroupName=NetMeter
PrivilegesRequired=lowest
OutputDir=..\build\installer
OutputBaseFilename=NetMeter-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\netmeter.exe
CloseApplications=force
RestartApplications=no
DisableProgramGroupPage=yes
WizardStyle=modern
LicenseFile=..\LICENSE
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
[Icons]
Name: "{autoprograms}\NetMeter"; Filename: "{app}\netmeter.exe"
Name: "{autodesktop}\NetMeter"; Filename: "{app}\netmeter.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "startup"; Description: "Start NetMeter with Windows (quietly, in the tray)"
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "NetMeterApp"; ValueData: """{app}\netmeter.exe"" --minimized"; Tasks: startup; Flags: uninsdeletevalue
[Run]
Filename: "{app}\netmeter.exe"; Description: "Start NetMeter"; Flags: nowait postinstall runasoriginaluser
