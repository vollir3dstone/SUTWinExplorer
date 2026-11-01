[Setup]
AppId={{C49BDCBD-2354-49FC-A4F3-287C7C1E2E9E}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
OutputDir={#InstallerOutputDir}
OutputBaseFilename={#AppName}-{#ProfileId}-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"

#if AddFolderContextMenu
[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer"; ValueType: string; ValueName: ""; ValueData: "KIS Explorer hier öffnen"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\{#AppExeName}"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%V"""; Flags: uninsdeletekey
#endif