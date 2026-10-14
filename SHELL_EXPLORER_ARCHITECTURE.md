# Shell Explorer Architecture and Decisions

> **Document scope:** This file records architecture, implementation details, API ownership, technical findings, decisions, and unresolved engineering work. It is not the user-facing behavior specification; see [SHELL_EXPLORER_BEHAVIOR_SPEC.md](SHELL_EXPLORER_BEHAVIOR_SPEC.md) for observable requirements and acceptance criteria.

## Decision Record

### 2026-10-13: Use the Shell IExplorerBrowser view in production

**Decision owner:** Volker.

**Decision:** Use the Windows Shell `IExplorerBrowser` COM API as the content
view. Keep the WPF application window, application tabs, address field, status
area, and custom directory trees.

**Rationale from Volker:** The priority is not to forget common Windows
Explorer behavior. Recreating Shell operations in a custom list would mean
implementing and maintaining many details ourselves. Volker accepted the
remaining drawbacks because column sizing can be handled separately and
directory visibility can be filtered.

**Evidence:** The spike verified Shell item/background menus, Properties, New
Text Document, context-menu Copy/Paste, Paste shortcut, cross-Explorer
clipboard operations, drag/drop, custom-tree navigation, separate tab
locations, localized type descriptions, and icon overlays. The spike did not
pass Ctrl+C/Ctrl+V keyboard routing or Name-column fill resizing. The directory
filter was implemented and runtime-tested after the decision.

**Scope:** This embeds a Shell folder view, not the complete Windows Explorer
application or its chrome. WPF remains responsible for the app-level navigation
and layout.

## Current Composition

- `MainWindow` owns the WPF application toolbar and `TabControl`.
- Each `ExplorerTabView` owns its active path, back/forward history, two custom
  directory trees, **Show directories**, status count, and one content view.
- Production creates one `ShellExplorerBrowserHost` per tab. It derives from
  `HwndHost` and hosts one Shell `IExplorerBrowser` COM instance.
- `ActivePathTree` shows only the current ancestor route.
- `ActivePathAndSiblingsTree` additionally shows immediate child directories
  along the route. Both continue to navigate the Shell view through the common
  `ExplorerTabView.Navigate` method.
- The legacy WPF `ListView`, its filtering, icon binding, sizing, and menus are
  retained. `UseLegacyWpfFileList` in `ExplorerTabView.xaml.cs` is the explicit
  rollback switch: `false` selects the Shell view (production default); `true`
  makes the WPF list active again.

## Shell View Host

`ShellExplorerBrowserHost` creates a child host window with `CreateWindowExW`,
activates the Shell's `CLSID_ExplorerBrowser` through `CoCreateInstance`, and
hosts it on the WPF UI's STA thread.

Initialization sequence:

1. Create the child HWND in `HwndHost.BuildWindowCore`.
2. Create the `IExplorerBrowser` COM object.
3. Create and attach `ShellBrowserSite` with `IObjectWithSite.SetSite`.
4. Initialize in Details mode with `FOLDERSETTINGS`; do not enable
   `EBO_SHOWFRAMES`, so the Shell navigation pane/frame is not shown.
5. Subscribe to `IExplorerBrowserEvents` using `Advise`.
6. Defer the first `BrowseToIDList` until `DispatcherPriority.Loaded`.
7. On navigation completion, capture the active `IFolderView2` sort columns,
   set Details mode and `FWF_NOGROUPING`, replace the visible columns with
   Name, Type, Size, and Date modified in that order, then restore the captured
   sort. Folder-specific grouping, view mode, and columns are not used; then
   recalculate the Name width for the new view.
8. Update the Shell view's bounds with `SetRect` when the WPF host is resized,
   then use `IColumnManager` to size the visible Name column to the remaining
   width.
9. On teardown, `Unadvise`, call `Destroy`, clear the site, release COM
   references, and destroy the child HWND.

Navigation uses `SHParseDisplayName` to obtain an absolute PIDL and
`IExplorerBrowser.BrowseToIDList`; the allocated PIDL is freed after the call.
`IExplorerBrowserEvents.OnNavigationPending` updates the filter's current path
before item enumeration. `OnNavigationComplete` converts the PIDL with
`SHGetNameFromIDList(SIGDN_FILESYSPATH)`, then dispatches the path update to WPF
so the active path, trees, tab title, status, and address choices synchronize.
Non-filesystem namespace locations do not become filesystem paths and are not
fully integrated with the custom trees yet.

The initial browse must not run synchronously inside `BuildWindowCore`.
`BrowseToIDList` can pump Windows messages; doing so during WPF's initial layout
caused a dispatcher exception and prevented startup. Deferring the browse
avoids that reentrancy.

## Shell Change Notifications

Filesystem synchronization uses the Shell's `SHChangeNotifyRegister`, not
per-property `FileSystemWatcher`s. Each tab registers only the directory route
from the drive root through `CurrentPath`, one non-recursive registration per
route directory. A route directory's registration reports changes to its
immediate children, which is sufficient to update the current listing and the
route nodes' sibling lists. Sibling directories' own contents are not shown in
the tree, so their subtrees are deliberately not registered. Registration
count therefore scales with route depth, not the number of loaded or sibling
directories.

Registrations use `SHCNE_DISKEVENTS` with interrupt, Shell-level, and
new-delivery sources; the latter payload is read with
`SHChangeNotification_Lock` and released with `SHChangeNotification_Unlock`.
The host deregisters all notification IDs when the tab unloads or its native
window is destroyed, and updates route registrations after navigation.

Notifications are coalesced by a 200ms tab-level dispatcher timer. The Shell
owns and refreshes its content view from its own change notifications. When a
notification reaches a visible tab, the app refreshes the item count and
reconciles only the active route's loaded tree nodes, preserving existing
nodes and their expansion/selection state. A hidden tab is marked dirty and
does not update its custom trees immediately; on becoming visible it performs
one rescan and explicitly refreshes the content view in case notifications
were missed while unloaded.

Runtime-verified with external create, rename, and delete in a disposable test
directory: the Shell list and **Active path and siblings** tree updated without
restarting the app. Creating a sibling under an ancestor on the current route
updated the tree without registering that sibling's subtree. A directory
created while its tab was hidden appeared in the tree after switching back.

## Shell Details Column Sizing

### Expected behavior

The WPF content pane occupies the remaining width after the sidebar. The hosted
ExplorerBrowser view must follow that pane on both window resize and sidebar
splitter movement. In Details mode, the visible non-Name columns retain their
Shell-provided widths and Name uses the remaining width. The standard column
order is Name, Type, Size, and Date modified; the Shell's Size column provides
the KB-formatted value. The resulting view
must have no horizontal scroll range at the tested layout sizes. Enabling
**Show directories** can create or remove a vertical Shell scrollbar without
changing the WPF pane size, so that refresh also requires a width recalculation.

`ExplorerTabView.ShellBrowserSlot_SizeChanged` converts the WPF size to physical
pixels and calls `ShellExplorerBrowserHost.SetViewSize`. The host applies those
bounds through `IExplorerBrowser.SetRect`. `OnWindowPositionChanged` is also
retained as a native-host fallback. After a successful `SetRect`, the host
queries the current view for `IColumnManager`, enumerates visible columns, and
uses `PKEY_ItemNameDisplay` (`{B725F130-47EF-101A-A5F1-02608C9EEBAC}`, PID 10)
to identify Name. The target width is:

`UsableShellViewWidth = ShellViewClientWidth - VisibleVerticalScrollBarWidth`

`NameWidth = max(80, UsableShellViewWidth - OtherVisibleColumnWidths - 11)`

The other widths are read with `GetColumnInfo`; the Name width is applied with
`SetColumnInfo`. The width is recalculated after Shell navigation because the
Shell may replace the current view. After **Show directories** refreshes the
view, a one-shot 250ms dispatcher timer allows Shell's scrollbar child windows
to settle before measuring the visible vertical scrollbar and recalculating
Name. `IColumnManager` widths are physical pixels. Its COM method declarations
must follow the SDK vtable order (`SetColumnInfo`,
`GetColumnInfo`, `GetColumnCount`, `GetColumns`, `SetColumns`); a different
declaration order dispatches calls to the wrong native methods.

### Measured behavior

The first implementation sized columns using the outer host width. HWND
inspection showed the host was 1202px wide while the ExplorerBrowser child and
Shell view were 1200px wide, a 2px difference at the tested window size. The
code now gets the current `IShellView` window and uses its `GetClientRect`
width, rather than assuming the HwndHost width is the Shell's usable width.

Using the Shell client width alone still left a small horizontal scroll range.
The Shell's `IColumnManager` reports column widths, but does not expose the
view's complete horizontal content extent or a documented trailing-inset
value. Runtime UI Automation on the Shell `DirectUIHWND` showed that an 8px
allowance still left a small range (the view reported about 99.886% visible at
an 880px client width). An 11px allowance made `HorizontallyScrollable` false
and hid the Shell scrollbar at both the 880px startup view and the 1200px
resized view. The host widths in those checks were 882px and 1202px
respectively. A window-width increase also produced a matching `SetRect` and
Name-width update.

Enabling **Show directories** in a folder with enough entries to show the
vertical bar left the Shell view 880px wide, but its visible vertical scrollbar
was 17px wide, reducing usable width to 863px. The delayed recalculation
reduced Name from 525px to 508px; Size stayed at its Shell-provided 80px, and
UI Automation reported `HorizontallyScrollable = false`. The horizontal bar
had appeared because the Shell's vertical bar consumed width without raising a
WPF resize event.

The 11px value is therefore an empirically derived Shell-specific allowance,
not a documented Windows border metric. It was verified on this Windows build
and at these two widths; different Windows versions, DPI settings, or column
sets may require revalidation. `SUTWINEXPLORER_TRACE_COLUMNS=1` enables an
opt-in per-process trace in `%TEMP%` named
`SUTWinExplorer-column-sizing-<pid>.log`; it records WPF/native sizes, COM
results, and computed widths.

## Show Directories Filter

The checkbox is WPF-owned and defaults to unchecked. The filter is implemented
at the Shell view boundary, so the Shell still owns enumeration, icons, menus,
and file operations.

### Service registration

`ShellBrowserSite` is a managed COM-visible object implementing `IServiceProvider`
and `ICommDlgBrowser`. `IExplorerBrowser` is given this site through
`IObjectWithSite.SetSite`.

`IServiceProvider.QueryService` recognizes `SID_SExplorerBrowserFrame` with
`IID_ICommDlgBrowser` and returns the site's COM interface pointer. The Shell
then calls `ICommDlgBrowser.IncludeObject` for candidate child items.

The callback interfaces must be managed COM-callable interfaces (`ComVisible`),
not `[ComImport]` interfaces. Initially the callback was never useful because
the site did not expose the service correctly; runtime tracing confirmed that
service requests and `IncludeObject` calls were occurring after the COM
visibility correction.

### Folder classification

When **Show directories** is checked, `IncludeObject` returns `S_OK` for all
items. When unchecked, it:

1. Reads the current folder path supplied by the `ShellExplorerBrowserHost`.
   `OnNavigationPending` updates this path before the destination view
   enumerates items.
2. Binds that path to an `IShellFolder`: `SHParseDisplayName` creates the
   absolute PIDL, `SHBindToParent` provides the parent and relative child PIDL,
   and `IShellFolder.BindToObject` obtains the current folder. The bound folder
   interface is cached by path and released when the path changes or the view
   is destroyed.
3. Places the callback's borrowed child PIDL into a one-element pointer array
   and calls `IShellFolder.GetAttributesOf` with `SFGAO_FOLDER`.
4. Returns `S_FALSE` when `SFGAO_FOLDER` is present, hiding the entry; otherwise
   returns `S_OK` so it is displayed.

The child PIDL passed to `IncludeObject` is borrowed and is not freed. The child
PIDL returned by `SHBindToParent` points into the absolute PIDL allocation and
is also not freed separately. Only the pointer array allocated for
`GetAttributesOf` and the absolute PIDL allocation are freed by this code.
Folder-query failures fail open (`S_OK`) rather than accidentally hiding
ordinary files.

Directory reparse points are expected to follow the same behavior when the
Shell reports `SFGAO_FOLDER`. Runtime testing verified ordinary directories;
junction/reparse-point coverage remains a dedicated acceptance test.

When the checkbox changes, `ShellExplorerBrowserHost.SetShowDirectories`
updates the site state, obtains the current `IShellView` through
`IExplorerBrowser.GetCurrentView`, and calls `IShellView.Refresh` to re-enumerate
the active folder without navigation.

### Filter debugging findings

- `IShellFolder.GetUIObjectOf` does not support `cidl == 0`; use
  `IShellView.GetItemObject(SVGIO_BACKGROUND, ...)` for folder-background
  menus. That is separate from the directory-filter callback.
- Trying to obtain the current folder with
  `IShellView.GetItemObject(SVGIO_BACKGROUND, IID_IShellFolder)` returned
  `E_NOINTERFACE`. The working filter instead binds the current path through
  `SHParseDisplayName`, `SHBindToParent`, and `BindToObject`.
- A temporary trace confirmed that `QueryService` and `IncludeObject` were
  reached. The trace was removed after fixing folder binding.
- Runtime UI Automation on the default profile observed 23 file rows with the
  checkbox off, 28 rows with it on, and 23 again when turned off. This proves
  live checkbox refresh in that folder; it is not a complete reparse-point
  test.

## Native Context Menus and Operations

The hosted Shell content view supplies its own item and background menus,
clipboard context-menu verbs, and drag/drop. The app still uses
`ShellContextMenu` for context menus requested from the custom WPF directory
trees. That helper queries native Shell context menus and forwards required
`IContextMenu2`/`IContextMenu3` menu messages.

The ExplorerBrowser spike verified context-menu New, context-menu Copy/Paste,
Paste shortcut, clipboard interoperability with Windows Explorer, and
right-button drag/drop. Its initial Ctrl+C/Ctrl+V keyboard test failed. The
host now overrides `HwndHost.TranslateAcceleratorCore` and forwards messages to
the current view's `IInputObject.TranslateAcceleratorIO`; if that returns
`S_FALSE`, it falls back to `IShellView.TranslateAccelerator`. Runtime tests
with disposable files verified Ctrl+A selection, Ctrl+C copy, Ctrl+V paste,
Ctrl+X cut, and Ctrl+Z undo. The Shell-hosted view remains responsible for
common file operations; do not duplicate these as custom file-copy code.

## Build and Output

The project currently targets `net10.0-windows`. Build normally to the standard
repo-relative folder:

- `bin/Debug/net10.0-windows`

Do not use an alternate artifact output folder unless the user explicitly asks
for it or the standard output is locked by a running app. If an isolated build
is necessary, clearly identify its output location.

## Known Gaps and Follow-up

- Explicit width policies for non-Name columns through the current Shell view's
  `IColumnManager`; their current Shell-provided widths are preserved.
- Synchronize Shell-originated folder opening and selection with all custom
  navigation/history states; current location completion is wired, but all
  history and selection cases need tests.
- Test directory filtering with normal directories, junctions, and other
  directory reparse points.
- Verify navigation to non-filesystem Shell namespace locations and decide
  whether custom trees/address paths should support them.
- Add robust user feedback for Shell navigation failures, unavailable paths,
  and host teardown/recreation.