# IExplorerBrowser Spike Results

> **Document scope:** This is the historical report from the isolated Shell-browser spike. Its observations describe that test build, not necessarily the current production state. See [SHELL_EXPLORER_ARCHITECTURE.md](SHELL_EXPLORER_ARCHITECTURE.md) for the current decision and implementation, and [SHELL_EXPLORER_BEHAVIOR_SPEC.md](SHELL_EXPLORER_BEHAVIOR_SPEC.md) for user-facing behavior.

## Scope and build

The spike is launched only with `SUTWinExplorer.exe --shell-browser-spike`. It
creates a unique fixture under `%TEMP%` containing two text files and a nested
folder, then removes it when the spike window closes. Normal startup still
shows the existing WPF `ListView`.

Both targets built successfully to their standard output folders:

- `bin\Debug\net8.0-windows`
- `bin\Debug\net10.0-windows`

The runtime test used `net10.0-windows` on Windows.

## Initial spike questions and results

| Check | Result | Observation |
| --- | --- | --- |
| Display files and folders | Pass | The hosted Details view exposed both fixture files and the nested folder. |
| Select an item | Pass | Right-clicking an item selected it and opened its native menu. |
| Item context menu and execute a command | Pass | The menu appeared and Properties opened for both `Nested.txt` and the created text document. |
| Empty-space background menu | Pass | The folder-background menu appeared and its Properties command opened the folder dialog. |
| Background > New > Text Document | Pass | Created and displayed `Textdokument (neu).txt` in the current folder. |
| Context-menu Copy/Paste within the hosted view | Pass | Copying the created document in `Nested` and pasting into the fixture root created a copy. |
| Ctrl+C/Ctrl+V keyboard shortcuts | Fail | The file was not copied with the keyboard sequence and Paste remained disabled. Context-menu Copy/Paste did work. |
| Paste shortcut | Pass | `Verknüpfung einfügen` created a shortcut file as expected. |
| Clipboard between hosted view and Windows Explorer | Pass | Context-menu Paste worked in both directions. |
| Drag/drop between hosted view and Windows Explorer | Pass | Right-button drag and `Hierher kopieren` worked both ways. An expected replace prompt appeared when the destination already contained the file. |
| Custom address navigation and completion sync | Pass | The existing WPF address box navigated to `Nested`; the completion event updated the location label and tab path state, and the Shell view showed `Nested.txt`. |
| Custom tree click navigation | Pass | Single-clicking the folder name navigated both the tree and hosted content view and updated the active path. |
| Independent app tabs | Pass | One tab retained `Nested`/`Nested.txt`; another retained the fixture root with `Alpha.txt`, `Beta.txt`, and `Nested`. |
| Shell Type column description | Pass | The Type column showed the localized file-type description rather than only the extension. |
| Details columns | Fail | Shell-provided Name, Date modified, Type, and Size columns appeared, but increasing the window width left the table at its original width and expanded blank space to its right. Name did not fill remaining width. |
| Icon overlays | Pass | The small overlay badge on the `.link` file was visible. |
| No built-in Explorer pane/frame | Pass | The host contained the ExplorerBrowser control and Shell DefView without a navigation tree or Explorer frame. `EBO_SHOWFRAMES` is not enabled. |
| Normal production startup | Pass | A no-argument launch exposed the existing WPF `ListView`; no ExplorerBrowser host was created. |

The user manually verified item/background menus, Properties, New Text Document,
context-menu clipboard operations, Paste shortcut, drag/drop, custom-tree
navigation, and a rendered `.link` overlay. Keyboard Ctrl+C/Ctrl+V and the
Name-column fill policy failed.

## Advantages and disadvantages

### Advantages observed

- Native item and background menus worked, including Properties and creating a
  new text document.
- Context-menu Copy/Paste worked inside the hosted view and between it and
  Windows Explorer. Paste shortcut created a shortcut, and right-button drag
  copied files in both directions.
- The Shell provided localized file-type descriptions, system icons, and the
  visible `.link` overlay without recreating those details in WPF.
- The existing WPF address bar and single-click custom trees drove the view.
  Navigation completion synchronized the active path, and separate tabs kept
  independent locations with separate browser instances.
- The hosted view showed no Explorer navigation pane or frame, leaving the
  application's own tabs, address bar, and custom trees in control.

### Disadvantages and constraints observed

- Ctrl+C/Ctrl+V failed, although the equivalent context-menu clipboard commands
  worked. Standard keyboard workflows need additional focus/accelerator work.
- The Name column did not resize with the host; increasing the window width
  left growing blank space. The required column layout needs explicit control.
- Hosting is COM/HWND integration rather than a normal WPF control. It requires
  STA use, native resizing, navigation callbacks, and deterministic COM/PIDL
  cleanup for every tab/view lifecycle.
- Shell-provided labels and verbs follow Windows localization and registered
  file types, so wording and available commands are not fully app-controlled.
- At the time of the spike, hiding folders had not been implemented or tested;
  it required a Shell callback/service integration.

## Integration work present in the spike

- One `IExplorerBrowser` COM instance is owned by each test-mode tab and hosted
  in an `HwndHost` on the WPF STA thread.
- `SetRect` handles view resizing; navigation uses `SHParseDisplayName` and
  `BrowseToIDList`; the allocated PIDL and callback path strings are freed.
- The host advises/unadvises `IExplorerBrowserEvents`, destroys the browser,
  and releases the COM object with the HWND host lifecycle.
- Shell navigation completion updates the app's active path, existing custom
  trees, tab title, and address choices. Filesystem path conversion failures
  are reported as non-filesystem/unknown locations.
- Details mode is requested through `FOLDERSETTINGS`. No Explorer frame is
  requested, so the application keeps its own tabs, address bar, and trees.

The spike findings below are historical. Production now uses one
`IExplorerBrowser` per application tab. The old WPF `ListView` is retained and
can be reactivated by setting `UseLegacyWpfFileList` to true in
`ExplorerTabView.xaml.cs`; its production value is false.

The Show directories checkbox is now implemented through the browser site's
`IServiceProvider` and `ICommDlgBrowser.IncludeObject`. It checks `SFGAO_FOLDER`
and returns `S_FALSE` for directories when unchecked. Runtime UI Automation
verified that the row count changes from files-only to files-plus-directories
and back when toggled.

The spike's Name-column fill failure was later fixed in the production host.
The implementation uses `IColumnManager` to preserve other visible column
widths and size Name from the current Shell view client width. Runtime checks
verified no horizontal scroll range at startup and after widening the window.
The measured Shell-specific trailing allowance and its portability caveat are
documented in [SHELL_EXPLORER_ARCHITECTURE.md](SHELL_EXPLORER_ARCHITECTURE.md).

Remaining production follow-up includes focused handling of Shell-originated
selection and navigation/history. The spike's keyboard-routing failure was
fixed later in the production host; see
[SHELL_EXPLORER_ARCHITECTURE.md](SHELL_EXPLORER_ARCHITECTURE.md).

### Implementation suggestions

- The column-sizing suggestion above describes the production implementation
  added after this spike. If future work changes visible columns with
  `SetColumns`, reapply per-column state afterward because `SetColumns` clears
  it.
- The keyboard-routing suggestion above was the spike follow-up. Production
  now forwards accelerators through `IInputObject.TranslateAcceleratorIO`
  with `IShellView.TranslateAccelerator` fallback and has runtime coverage for
  Ctrl+A/C/X/V/Z.
- If files-only content is required, expose `ICommDlgBrowser` through the
  host's `IServiceProvider` for `SID_SExplorerBrowserFrame`. Implement
  `IncludeObject` to return `S_FALSE` for folder items and `S_OK` for files,
  testing Shell item attributes rather than extensions. The app's custom trees
  and address bar can remain the folder-navigation route. This was not added or
  tested in the spike.
- If Shell-originated selection or navigation must synchronize with app state,
  use `IExplorerBrowserEvents` for location changes and query the current view
  (for example, `IFolderView2`) for selection. Define how that interacts with
  per-tab back/forward history. Custom-tree and address navigation worked, but
  opening a folder from inside the hosted Shell view was not separately tested.

## Production decision and current status

The application has switched production content panes to the Shell-hosted view
while retaining WPF tabs, address navigation, and custom directory trees. The
legacy WPF content view remains behind `UseLegacyWpfFileList` for rollback.

The checkbox filter, Name-column fill sizing, and Ctrl+A/C/X/V/Z keyboard
shortcuts have been implemented and runtime-verified. Remaining known work is
focused testing of Shell-originated selection and navigation/history; the user
chose the Shell view because native common file behaviors take priority over
recreating them in WPF.