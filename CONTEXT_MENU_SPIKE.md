# Context Menu Diagnostic Spike

## Purpose

The diagnostic in [ContextMenuSpike.ps1](tests/ContextMenuSpike.ps1) inspects
the classic Shell context menu for a real selection and lists possible registry
registrations separately. It does not show a menu, invoke a command, change the
registry, or change ContentView. Shell extensions are nevertheless loaded and
executed when the menu is queried; only inspect files and extensions you trust.

Run from the repository root in an STA PowerShell process. The output is JSON:

```powershell
pwsh -NoProfile -STA -File ./tests/ContextMenuSpike.ps1 -Path ./SUTWinExplorer.csproj
pwsh -NoProfile -STA -File ./tests/ContextMenuSpike.ps1 -Path ./SUTWinExplorer.csproj -Generic
pwsh -NoProfile -STA -File ./tests/ContextMenuSpike.ps1 -Path . -Background
pwsh -NoProfile -STA -Command '& ./tests/ContextMenuSpike.ps1 -Path @("./SUTWinExplorer.csproj", "./SutShell.cs")'
```

Without `-Background`, a directory is an item, not its background. Multiple
items must belong to the same parent. The tool uses the current process's Shell
and registry view; menu contents depend on installed extensions, selection,
Shell state and process architecture. It requires PowerShell on Windows.
`-Generic` accepts one file and queries a menu with only the `*` and
`AllFilesystemObjects` association keys. `-NoCanRename` omits `CMF_CANRENAME`
for comparing Shell extension behavior.

`Menu` contains positions, labels, command IDs, optional verb strings, state,
submenus and category hints. IDs are meaningful only within the menu instance
that produced them. `RegistryCandidates` lists registrations under likely
classes, including `*`, filesystem objects, folder types, extensions, their
default ProgID and their declared perceived type. Static verb commands and
handler CLSIDs are included where present. For mixed selections the candidate
classes are a union, not the set of commands supported for every item.

The two lists are deliberately separate: a registry candidate is not proof
that its handler contributed a particular menu item or even appeared. The
registry scan is incomplete, especially for per-user association choices,
other association sources and packaged extensions. The generated `IContextMenu`
is not necessarily the Windows 11 compact Explorer menu. Only submenus populated
by the initial query are inspected; lazy or owner-drawn entries can be missing
or lack readable text. This tool does not exercise menu message forwarding.
Verb strings are optional and may be noncanonical or malformed.

## Experimental File Menu

In ContentView, right-clicking one file opens the experimental menu. Its first
section mirrors the toolbar: Rename, Path get, Copy get/abort/paste, Move
get/abort/paste and Delete. Each command calls the same button handler and has
the same enabled state. Copy and Move use the application's prepared workflows,
not the Windows clipboard; Delete remains disabled while its toolbar button is
disabled. There is no separate Properties button in the toolbar.

The second section comes from `SHCreateDefaultContextMenu` with the `*` and
`AllFilesystemObjects` keys, followed by the Shell's ordinary menu-message
forwarding and invocation. Standard Shell verbs are removed by their canonical
verb to avoid duplicating or replacing the toolbar actions. Providers can omit
canonical verbs, and the Shell can include built-in submenus as well as
extensions. Wildcard registrations can also include type-oriented tools such as
Notepad++; a registration does not guarantee that its commands appear for every
file. Packaged/modern extensions are not guaranteed to be included.

The built-in Open With command is excluded, including its owner-drawn submenu.
That submenu has no canonical verb in the observed menu, so it is identified by
the localized Shell resource `shell32.dll` string 5376 and its submenu/owner-drawn
state. This resource ID is not a documented Shell API contract and should be
rechecked on other Windows versions.

Link Shell Extension manages its own Pick Link Source / Drop As workflow, not
the application's Copy/Move workflow. Its [documentation](https://schinagl.priv.at/nt/hardlinkshellext/linkshellextension.html)
also describes Drop Here As for right-button drag and drop. On this machine,
querying the same file with `CMF_CANRENAME` produced Pick Link Source; omitting
the flag produced the inappropriate Drop Here As submenu instead. The experimental
file menu now supplies `CMF_CANRENAME`, while retaining the toolbar's own Rename
enabled state. The extension's source storage and the complete Pick/Drop workflow
have not been independently verified; no Link Shell Extension commands are filtered.

Shift-right-click opens the original Windows item menu. Folders, background and
multiple selections retain their existing menus. The integration test exercises
the menu's toolbar actions, including Copy and Move paste with temporary files.

`CategoryHints` are text-based guesses for Archive, VersionControl, Links and
Verification, not authoritative classifications or rules for production. The
tool reports all entries, including entries without a hint. For example, the
Shell's ordinary Create shortcut command can match Links; a broad scan keyword
also matched TreeSize, and `rar` as a substring matched Library Location, so
those two patterns were narrowed. Unknown tools and localized or opaque labels
can be missed. Never use these hints to suppress a command automatically.

## Initial Observations

On the development machine, querying the project file found 7-Zip with an archive
submenu and verbs such as `SevenZipCompress`, TortoiseGit commands, Norton 360,
and a Notepad++ edit entry. The wildcard registry class contained registrations
for all of these providers, including Notepad++, so wildcard registration alone
cannot distinguish general operations from application or content operations.
Link Shell Extension was registered as a candidate, but that does not prove a
specific menu entry was contributed by it.

Queries for a folder, its background and a same-directory multi-selection also
returned menus. Background registrations included Link Shell Extension and
TortoiseGit. A temporary empty `.mp4` also exposed MediaInfo both as a video
registration candidate and as a menu entry. The observed commands and availability are specific to these
selections and installations; the spike has not tested command execution.

## Generic Association Inventory

This is a read-only snapshot of the current user's 64-bit merged HKCR view and
current-user package manifests on 2026-11-02. It is an inventory of registrations,
not a list of commands guaranteed to appear. HKCR merges user and machine
classes; registrations can be conditional, disabled, extended, unavailable for a
selection, or programmatic-only. Package and registry registration mechanisms
are distinct, and the same app may use both. No command was invoked.

### Association Classes

| Class or source | Meaning and relevance |
| --- | --- |
| `*` | All files, not folders; the principal generic file class. |
| `AllFilesystemObjects` | Files and filesystem folders. |
| `Directory` | Filesystem folders. |
| `Folder` | Shell folders, including non-filesystem containers. |
| `Drive` | Drive objects; useful for the drive listing, not every file. |
| `Directory\Background` | Folder background, a separate context from selected items. |
| `Unknown` | Fallback for files without a registered ProgID, not all files. |
| `DesktopBackground` | Desktop background, not a generic ContentView file class. |
| `SystemFileAssociations\Folder` | An additional folder-related association present on this machine; actual applicability must be checked for a selection. |
| `SystemFileAssociations\audio`, `video`, `image`, `text`, `document`, `system` | Broad content groups, not universal file classes. Some may have no context-menu entries. |
| `SystemFileAssociations\Directory.Audio`, `Directory.Image`, `Directory.Video`, `MyMusic`, `MyPictures`, `MyVideo` | Folder/content-related classes present on this machine, not universal directory classes. |
| `Kind.*`, `Results`, network and printer classes | Other content or Shell-namespace associations; not universal filesystem classes. Their participation depends on the data source and item. |
| Packaged `windows.fileExplorerContextMenus` | Manifests can register `*`, specific extensions, `Directory`, `Directory\Background` and other supported item types; separate from scanning HKCR. |

On this machine `HKCR\File` describes the `file:` URL protocol and has no
`shell` or `ContextMenuHandlers` entries. `Files` and `All` were absent. This
does not establish them as generic Shell classes. Likewise, the checked
`SystemFileAssociations\*`, `SystemFileAssociations\AllFilesystemObjects`,
`SystemFileAssociations\Directory` and `Drive\Background` keys were absent.

The Shell constructs an ordered association array for a particular item; it is
not simply one registry key. A file can additionally have a ProgID, an
extension-specific `SystemFileAssociations` entry, a perceived type, a user
association or other data-source associations. `Unknown` is used when there is
no registered ProgID. For example, on this machine `MediaInfo` is registered
under both `SystemFileAssociations\audio` and `video`, and also under
`SystemFileAssociations\Folder`. Its `Directory\shell\MediaInfo` registration
has `LegacyDisable`. Registration scope is therefore not a semantic category.

### Third-Party Handler Identities

The following are distinct COM identities found directly under the inspected
generic `shellex\ContextMenuHandlers` keys. Scope names in this table are
registration locations, not proof of actual menu participation.

| Handler / resolved implementation | CLSID | Registered scopes |
| --- | --- | --- |
| 7-Zip, `7-zip.dll` | `{23170F69-40C1-278A-1000-000100020000}` | `*`, `Directory`, `Folder` |
| TortoiseGit, `TortoiseGitStub.dll` | `{10A0FDD2-B0C0-4CD4-A7AE-E594CE3B91C8}` | `*`, `Directory`, `Folder`, `Drive`, `Directory\Background` |
| TortoiseHg, `ThgShellx64.dll` | `{46605027-5B8C-4DCE-BFE0-051B7972D64C}` | `*`, `Directory`, `Folder`, `Drive`, `Directory\Background` |
| Link Shell Extension, `HardlinkShellExt.dll` | `{0A479751-02BC-11D3-A855-0004AC2568AA}` | `*`, `Folder`, `Directory\Background` |
| Norton, `ashShell.dll` | `{472083B2-C522-11CF-8763-00608CC02F24}` | `*`, `AllFilesystemObjects`, `Folder` |
| Attribute Changer, `acshell.dll` | `{D3F9A525-8824-497A-BE36-B23E22F141FC}` | `AllFilesystemObjects`, `Drive` |
| Path Copy Copy, `PCC64.dll` | `{82CB99A2-2F18-4D5D-9476-54347E3B6720}` | `*`, `Folder`, `Directory\Background` |
| Adobe Acrobat, `ContextMenuShim64.dll` | `{A6595CD1-BF77-430A-A452-18696685F7C7}` | `*` |

The indirect examples matter: Norton is registered as `00nll` under
`AllFilesystemObjects` and `norton` elsewhere; Attribute Changer is `ACShell`.
`HardLinkMenu` and `ZZZHardLinkMenu` have the same CLSID. Path Copy Copy uses
`PathCopyCopy` and `ZZZZPathCopyCopy`; TortoiseHg uses `TortoiseHgCMenu` and
Acrobat uses `Adobe.Acrobat.ContextMenu`. Some handler values have a leading
`-`; retain the raw value when investigating rather than treating it as an
ordinary CLSID.

### Other Direct Registrations

These are the remaining directly enumerated names in the inspected generic
classes. Names are registry keys, not necessarily visible menu labels.

| Scope | `shellex\ContextMenuHandlers` entries other than the third-party identities above |
| --- | --- |
| `*` | `Open With`, `Open With EncryptionMenu`, `Sharing`, `WorkFolders`, `{90AA3A4E-1CBA-4233-B8BB-535773D48449}`, `{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}` |
| `AllFilesystemObjects` | `CopyAsPathMenu`, `ModernSharing`, `SendTo`, `{474C98EE-CF3D-41f5-80E3-4AAB0AB04301}`, `{596AB062-B4D2-4215-9F74-E9109B0A8153}`, `{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}` |
| `Unknown` | None |
| `Directory` | `EncryptionMenu`, `Offline Files`, `Sharing`, `WorkFolders`, `{596AB062-B4D2-4215-9F74-E9109B0A8153}` |
| `Folder` | `Library Location`, `Offline Files`, `PintoStartScreen`, `StartMenuExt`, `{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}` |
| `Drive` | `EnhancedStorageShell`, `Sharing`, `{596AB062-B4D2-4215-9F74-E9109B0A8153}`, `{D6791A63-E7E2-4fee-BF52-5DED8E86E9B8}`, `{fbeb8a05-beee-4442-804e-409d6c4515e9}` |
| `Directory\Background` | `New`, `Sharing`, `WorkFolders` |
| `DesktopBackground` | `DesktopSlideshow` |
| `SystemFileAssociations\Folder` | None |

Direct `shell` verb keys were also enumerated:

| Scope | Registered verb keys |
| --- | --- |
| `*` | `ANotepad++64`, `pintohomefile`, `removeproperties`, `UpdateEncryptionSettingsWork`, `view SUTTextViewer` |
| `AllFilesystemObjects` | `LaunchWorkfoldersControl`, `ModernProperties`, `OfflineFilesLaunchSyncCenter` |
| `Unknown` | `InvokeDefaultVerbInOtherProcess`, `Open`, `openas`, `OpenWithSetDefaultOn` |
| `Directory` | `A1opennewwindow`, `AddToPlaylistVLC`, `AnyCode`, `cmd`, `Durchsuchen mit &IrfanView`, `find`, `git_gui`, `git_shell`, `MediaInfo`, `opencmd`, `opencmdconda`, `OpenCmdCondaPyside6`, `PlayWithVLC`, `Powershell`, `pwsh`, `pwshrunas`, `ResonicPlayerBeta.Browse`, `ResonicPlayerBeta.Play`, `runas`, `sunwinexplorer`, `UpdateEncryptionSettings` |
| `Folder` | `explore`, `open`, `opennewprocess`, `opennewtab`, `opennewwindow`, `pintohome`, `TreeSize Free` |
| `Drive` | `change-passphrase`, `change-pin`, `cmd`, `Durchsuchen mit &IrfanView`, `encrypt-bde`, `encrypt-bde-elev`, `find`, `manage-bde`, `opencmd`, `pintohome`, `Powershell`, `pwsh`, `pwshrunas`, `resume-bde`, `resume-bde-elev`, `runas`, `unlock-bde` |
| `Directory\Background` | `AnyCode`, `cmd`, `git_gui`, `git_shell`, `opencmd`, `Powershell`, `pwsh`, `pwshrunas`, `ResonicPlayerBeta.Browse`, `ResonicPlayerBeta.Play`, `runas`, `TreeSize Free` |
| `DesktopBackground` | `.SpotlightLearnMore`, `.SpotlightNextImage`, `Display`, `EditStickers`, `Personalize` |
| `SystemFileAssociations\Folder` | `MediaInfo` |

These lists include system, content, application and generic operations. For
example, Notepad++, SUTTextViewer and Adobe Acrobat are registered for `*`;
IrfanView, VLC and MediaInfo have folder-related registrations. Thus selecting
every entry from a generic class cannot alone produce the desired file-operations
menu. `LegacyDisable`, `ProgrammaticAccessOnly`, `Extended`, `AppliesTo` and
selection restrictions must not be ignored.

### Indirection And Packages

- `*\shell\ANotepad++64` uses `ExplorerCommandHandler` CLSID
  `{B298D29A-A6ED-11DE-BA8C-A68E55D89593}`, whose `InProcServer32` is
  `Notepad++\contextMenu\NppShell.dll`. The key name is not the handler identity.
- `*\shell\UpdateEncryptionSettingsWork` uses `ExtendedSubCommandsKey` and
  a nested `shell\Decrypt` command. Other verbs use `DelegateExecute` CLSIDs.
  `SubCommands` can also refer to the Windows CommandStore. These mechanisms
  require following references, not treating every `shell` key as an executable.
- File-extension default values can refer to ProgIDs, which can use `CurVer`;
  the active user association may differ from the extension's default. No
  `BaseClass` or `CurVer` values/subkeys were found on the inspected generic roots.
- Package manifests for this user contained the following generic registrations:

| Package | Item types | Verb | CLSID |
| --- | --- | --- | --- |
| NotepadPlusPlus | `*` | `EditWithNotepadPlusPlus` | `{E6950302-61F0-4FEB-97DB-855E30D4A991}` |
| JAMSoftware.UltraSearchContextMenu | `Directory`, `Directory\Background`, `Drive` | `UltraSearch` | `{24F6AE64-40A4-4EF1-82B3-089BBD61B978}` |
| `0BF99681-825C-4B2A-A14F-2AC01DB9B70E` | `*`, `Directory`, `Directory\Background` | `TortoiseGit` | `{A4FEC38E-C9F5-489A-ADAB-28DA10F523A3}` |
| Microsoft.WindowsNotepad | `*`, `Directory` | `OpenInNotepad` | `{CA6CC9F1-867A-481E-951E-A28C5E4F01EA}` |
| Microsoft.WindowsTerminal | `Directory`, `Directory\Background` | `OpenTerminalHere` | `{9F156763-7844-4DC4-B2B1-901F640F5155}` |

This package check covers only installed packages visible to the current user
and the specified item types; it is not an exhaustive audit of every registration
mechanism or extension-specific package entry. Package CLSIDs need not resolve
as conventional HKCR `InProcServer32` registrations. The Notepad++ package CLSID
above is distinct from its classic HKCR handler CLSID.

Sources: [Association Arrays](https://learn.microsoft.com/en-us/windows/win32/shell/fa-associationarray),
[Shell Extension Handlers](https://learn.microsoft.com/en-us/windows/win32/shell/handlers),
[Creating Shortcut Menu Handlers](https://learn.microsoft.com/en-us/windows/win32/shell/context-menu-handlers),
[Package ItemType](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-desktop4-itemtype).

## Next Questions

- Determine which entries can be mapped to stable, documented identities and
  when a mapping from a menu entry to a provider is ambiguous.
- Test lazy submenus, owner-drawn entries, invocation and message forwarding
  before attempting to rearrange Shell-owned menus.
- Evaluate explicit provider/verb rules and user overrides against more examples,
  with the complete original menu as a fallback for unidentified entries.