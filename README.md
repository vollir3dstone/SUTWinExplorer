# KIS Explorer

KIS Explorer is a Windows file explorer from SUT, designed around a single
application instance, persistent directories, and a more structured view of
files and their available actions. It combines its own WPF interface with
Windows Shell services for file operations, icons, and context-menu commands.

## What makes it different

### One instance, browsable and pinned directories

Only one KIS Explorer instance can run on a machine, including across Windows
user sessions. A second launch reports the existing instance and exits; it does
not forward its command-line path to that instance.

A **Pathview** is a tab's directory tree, content table, location, and view
settings. The permanent **BROWSE** Pathview is used to navigate. **Pin** turns
its current filesystem location into a **Fixed** Pathview: a separate tab that
stays at that directory. Opening a directory from a Fixed Pathview navigates
BROWSE or selects an already pinned destination; it does not change the Fixed
Pathview's location. Fixed tabs can have custom names and colors.

Pinned directories belong to a **use case**, so different tasks can have
different sets of Fixed Pathviews. The `default` use case is activated at
startup; its pinned directories are restored, with BROWSE selected. Closing a
Fixed tab removes it from the active use case, while closing the application
does not. Unavailable paths remain saved and are marked. The virtual **This PC**
location cannot be pinned.

### Two logically organized context menus

KIS Explorer divides actions into a **Base Menu** and a **Content Menu**. The
distinction is inspired by a black-box/white-box analogy:

- The **Base Menu** treats an item primarily as an object: it groups common
  actions such as Properties, clipboard operations, Rename, Relocate, and
  Delete, along with generally applicable Shell commands.
- The **Content Menu** contains remaining item-specific Shell commands, such
  as Open and Open with, as well as applicable destination actions. These
  depend on the kind of item or the context in which it is used.

This analogy is a mental model, not a strict test of whether a command reads
file contents. Windows and its extensions construct the Shell portions of the
menus, and KIS Explorer filters them; the available commands depend on the
selection and the installed system. Some commands may not be classified
perfectly, and modern Windows 11 extensions are not guaranteed to appear.

For eligible items and directory backgrounds, repeated right-clicks at the
same position cycle through Base Menu, Content Menu, and no menu. Moving the
pointer away or invoking a command resets the sequence. **Shift-right-click**
opens the native Windows menu; for shortcuts, the item menu's Open file
location action is replaced by KIS Explorer's **Open parent** action.

### Media types and additional columns

The content table distinguishes an application's own abstract file categories
from Windows' file associations. The **MT** column shows a media type icon,
such as image, audio, video, structured data, book, or executable. **ST**
shows the independent media subtype `TEXT`, `EDIT`, or `RENDER` when one is
assigned. For example, `.svg` is image/TEXT, `.jpg` is image/RENDER, and
`.zip` is box/EDIT.

These are classifications based on file extensions, not inspection or
validation of file contents. The mapping is maintained in
[media-types.json](Assets/media-types.json) and embedded at build time;
unknown extensions have no media type icon. Directory and shortcut icons have
special handling. Windows-provided information is shown separately:

| Column | Meaning |
| --- | --- |
| MT | KIS Explorer media type icon. |
| ST | KIS Explorer media subtype icon, if assigned. |
| TA1 | Windows Shell base icon, a coarse indication of type or associated app. |
| MO | Windows Shell overlay, shown separately when available. |
| TA2 | Windows Shell type description, a finer indication of type or associated app. |

TA1 and TA2 are approximate descriptions: Windows may supply item-specific
icons and descriptions. Name, Size, and Date modified complete the table.

## Getting started

1. Navigate in **BROWSE** using the directory tree or address field.
2. Select **Pin** to keep a filesystem directory as a Fixed tab. Pinning an
   already open location selects its existing tab.
3. Use the use case icon to inspect, create, or activate sets of pinned
   directories. Double-click a use case to activate it.
4. Right-click a file, directory, or eligible background to open the Base
   Menu; right-click again at the same position for the Content Menu.
5. Use **Hide directories**, **Hide internal**, and **Name pattern** to filter
   the content table. The sort-order control supports multiple priorities.

The gear button opens Configuration. Optional action-button groups and the
application's internal Link, Copy, and Move workflows are disabled by default;
the corresponding settings can be enabled independently. Internal transfers
mark sources in one tab and execute or abort them in another, independently
of Windows clipboard transfers. The interface defaults to English; choosing
the system UI language takes effect after a restart. Windows and Shell
extensions may use different languages.

## Windows integration and limits

- Windows Shell operations support ordinary file actions and clipboard
  transfers with compatible applications. Incoming drag-and-drop accepts only
  the Copy effect chosen by Windows; Move and Link are rejected.
- **Open in running app...** offers matching running application windows for
  selected files. Delivery depends on the application and its configured
  method; it does not guarantee that the selected window opens the file, and
  a drop may modify an existing document.
- The application primarily works with filesystem directories. **This PC**
  provides a drive listing, but other virtual Shell locations are not fully
  supported.
- Configuration and use cases are stored under `%APPDATA%\KIS Explorer`.
  The persistent icon cache is under `%LOCALAPPDATA%\KIS Explorer` and can
  contain visited filesystem paths. Filesystem change notifications are
  best-effort; external moves cannot always be identified reliably.

## Build

Development requires Windows x64 and the .NET 10 SDK. From the project root:

```powershell
dotnet build .\SUTWinExplorer.csproj -c Debug
```

The executable is `bin\Debug\net10.0-windows\KIS Explorer.exe`. For
distribution, the Included publish profile bundles the runtime; the Dependent
profile requires the .NET 10 Desktop Runtime for Windows x64. See
[Build and Release](BUILD_AND_RELEASE.md) for publishing and installers.
Older SUTWinExplorer installations are not automatically migrated or upgraded;
uninstall them before installing KIS Explorer.

## Further reading

Start with these specifications, in this order:

1. [Shell Explorer Behavior Specification](SHELL_EXPLORER_BEHAVIOR_SPEC.md):
   navigation, Pathviews, file operations, and acceptance criteria. Its Shell-host
   implementation status includes historical material; check the transition note.
2. [Configuration](Configuration.md): settings, storage, startup, and use case
   persistence.
3. [UseCasesView](UseCasesView.md): managing and activating use cases.
4. [Context Menu Specification](CONTEXT_MENU_SPEC.md): menu composition,
   interaction, Shell integration, and limitations.
5. [ContentView](CONTENT_VIEW.md): current table, columns, filtering, sorting,
   and loading. Its lower historical Shell-host section is not current behavior.

For specific topics, see [Open with Running App](OPEN_WITH_RUNNING_APP_SPEC.md),
[SutShell API](SUTSHELL_API.md), [Directory Observation](DIRECTORY_OBSERVATION.md),
[Icon Cache](ICON_CACHE_SPEC.md), and [Test Specification](TEST_SPEC.md).
The architecture and spike documents contain historical investigations; their
transition notes distinguish them from the current implementation.