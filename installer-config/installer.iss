[Setup]
AppId={{7A143DD2-DB42-4ED7-A92E-8D9DB4656FC9}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\SUTWinExplorer.exe
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
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\SUTWinExplorer.exe"

#if AddFolderContextMenu
[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer"; ValueType: string; ValueName: ""; ValueData: "SUTWinExplorer hier öffnen"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\SUTWinExplorer.exe"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\SUTWinExplorer\command"; ValueType: string; ValueName: ""; ValueData: """{app}\SUTWinExplorer.exe"" ""%V"""; Flags: uninsdeletekey
#endif