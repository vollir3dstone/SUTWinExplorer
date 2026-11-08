# KIS Explorer

KIS Explorer is a Windows file explorer from SUT, designed around a single
application instance, persistent directories, and a more structured view of
files and their available actions. It combines its own WPF interface with
Windows Shell services for file operations, icons, and context-menu commands.

## What makes it different

### Overview

Compared to Windows Explorer, KIS Explorer uses the idea of anchor points:
The user pins directories in tabs they can switch between.
And instead of using multiple KIS Explorer instances, one instance suffices.
Of course, if the user needs to browse, this is possible and seemlessly
integrated. But still, the pinned directories keep their location.

Also, to launch a document in an application, running or not, the user
does not have to leave the KIS Explorer: There is a special context menu
action that opens a document in an already running application. This means,
there is no need for drag'n'drop between KIS Explorer and the app's window.

Talking about context menus: The actions of the standard context menu, together
with newly defined actions, are split into two context menus:
- The **Base Menu**, that has a black box view of the selected file (item), i.e.,
  it offers operations that make sense for all types of files, independent of
  their type or content. Examples are renaming, copying, zipping, versioning
  and virus scanning.
- The **Content Menu**, that looks inside the box, and offers actions dependent
  on the file type or associations. To find associated operations, the Windows
  shell functionality is used, so the familiar operations are offered known
  from Windows Explorer.

Toggling through the two context menus for a file is easy: The first right mouse
click opens the Base Menu, the second switched to the Content Menu, and the third
closes the context menu sequence altogether.

Compared to other explorers, there is no support for file content preview.
KIS Explorer is rather interested in file operations and classifications
then in content.

### One instance, browsable and pinned directories

Only one KIS Explorer instance can run on a machine.

A **Pathview** is a tab's view to a directory and its location.
The permanent **BROWSE** Pathview is used to navigate. **Pin** turns
its current filesystem location into a **Fixed** Pathview: a separate tab that
stays at that directory. Opening a directory from a Fixed Pathview navigates
BROWSE or selects an already pinned destination; it does not change the Fixed
Pathview's location. Fixed tabs can have custom names and colors.

Pinned directories belong to a **use case**, so different tasks can have
different sets of Fixed Pathviews. The `default` use case is activated at
startup; its pinned directories are restored.

### The Pathview

The Pathview is the central view of directory, displaying
- the path,
- the sub directories,
- and the files,

in 3 distinct sub views.

The **Content View** holds a table view that displays the files and, if activated,
also the sub directories which are already available in a second view.

The user can set filter criteria like
- hide directories,
- hide internal,
- and a name pattern,

to filter for certain items (files and directories).

They can also define the sorting of the items based on column names,
using a dedicated Sorting-Control widget.

From the context menus (and from buttons if activated) the user can start
various actions on the active directory itself and on items selected in the
Content View.

If the user double clicks on a directory item, either in the Content View or
in the sub directories view, the active Pathview Tab switches to the BROWSE
tab where the new locatrion is displayed. The pinned Pathview is forbidden to
navigate via double clicks.

### Two logically organized context menus

KIS Explorer divides actions into a **Base Menu** and a **Content Menu**. The
distinction is inspired by a black-box/white-box view:

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
perfectly, but the distinction is by best effort and the support Windows offers.

For eligible items and directory backgrounds, repeated right-clicks at the
same position cycle through Base Menu, Content Menu, and no menu. Moving the
pointer away or invoking a command resets the sequence. **Shift-right-click**
opens the native Windows menu.

### Media types and additional columns

The content table distinguishes an application's own abstract file categories
from Windows' file associations. 

A **Media Type** identifies the type of a file by its modality:
- Executable
- Archive (zip etc.)
- Text file without stated purpose
- Code file (programming languages)
- Structured data, no matter if text based or not (csv, MS Excel, JSON, XML, MS Access, sqlite etc.)
- Book or presentation, no matter if text based or not (pdf, MS Word, html etc.)
- Image
- Video
- Audio

A **Media Type Sub Type** identifies the type of a file by its interaction effort:
- Mostly used for viewing, listening or consumption in general
- Mostly used for editing
- Text file; this cannot be clearly assigned to one of the two types above

As an example take a "Book" type file: A PDF is for viewing, a Word file for editing,
and an HTML file is a text file.

Media Type and Sub Type are displayed as icons in two columns.

These are classifications based on file extensions, not inspection or
validation of file contents. The mapping is maintained in
[media-types.json](Assets/media-types.json) and embedded at build time;
unknown extensions have no media type icon. 


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

## Repository structure

- `sources/`: C# application code, WPF views, and XAML styles.
- `sources_docs/`: application specifications, architecture notes, and
  development and test documentation.
- `scripts/`: build and release scripts, media-type validation, and installer
  configuration and template.
- `scripts_docs/`: build, installer, and release guides.
- `Assets/`: application icons, localized strings, and embedded JSON mappings
  for media types, Shell menus, and running applications.
- `Properties/`: publish profiles for included and framework-dependent builds.
- `tests/`: automated tests, integration and manual probes, benchmarks, test
  resources, and experimental tests.
- `devResources/`: icon source materials used during development.
- `bin/` and `obj/`: build and publish outputs and intermediate build files.
- `installer/`: generated installer packages in `Release/` and temporary
  installer scripts and build files in `Temp/`.
- `artifacts/`: local diagnostic outputs such as screenshots and test builds.
- `.git/`: local Git repository metadata.

The project file, this README, the release description, and the release list
remain at the repository root. Generated and local directories may vary between
workspaces.

## Build

Development requires Windows x64 and the .NET 10 SDK. From the project root:

```powershell
dotnet build .\SUTWinExplorer.csproj -c Debug
```

The executable is `bin\Debug\net10.0-windows\KIS Explorer.exe`. For
distribution, the Included publish profile bundles the runtime; the Dependent
profile requires the .NET 10 Desktop Runtime for Windows x64. See
[Build and Release](scripts_docs/BUILD_AND_RELEASE.md) for publishing and installers.
Older SUTWinExplorer installations are not automatically migrated or upgraded;
uninstall them before installing KIS Explorer.

## Further reading

Start with these specifications, in this order:

1. [Shell Explorer Behavior Specification](sources_docs/SHELL_EXPLORER_BEHAVIOR_SPEC.md):
   navigation, Pathviews, file operations, and acceptance criteria. Its Shell-host
   implementation status includes historical material; check the transition note.
2. [Configuration](sources_docs/Configuration.md): settings, storage, startup, and use case
   persistence.
3. [UseCasesView](sources_docs/UseCasesView.md): managing and activating use cases.
4. [Context Menu Specification](sources_docs/CONTEXT_MENU_SPEC.md): menu composition,
   interaction, Shell integration, and limitations.
5. [ContentView](sources_docs/CONTENT_VIEW.md): current table, columns, filtering, sorting,
   and loading. Its lower historical Shell-host section is not current behavior.

For specific topics, see [Open with Running App](sources_docs/OPEN_WITH_RUNNING_APP_SPEC.md),
[SutShell API](sources_docs/SUTSHELL_API.md), [Directory Observation](sources_docs/DIRECTORY_OBSERVATION.md),
[Icon Cache](sources_docs/ICON_CACHE_SPEC.md), and [Test Specification](sources_docs/TEST_SPEC.md).
The architecture and spike documents contain historical investigations; their
transition notes distinguish them from the current implementation.