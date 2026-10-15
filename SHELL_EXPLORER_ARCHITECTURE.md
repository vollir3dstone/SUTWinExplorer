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

### 2026-10-14: Keep filesystem paths canonical; localize display names

**Decision owner:** Volker.

**Decision:** Keep actual Windows filesystem paths as the app's internal
navigation and identity values. Use Windows Shell normal display names only
when presenting folders in the UI; never replace stored paths with translated
labels.

**Application:** Custom tree labels, the address field and its open-tab
dropdown, the content-pane heading, and tab headers use Shell-provided display
names. The address field resolves typed localized path components back to
filesystem paths before navigation. The Shell-hosted content view continues to
render its own localized names.

**Rationale:** Localized display names are presentation values and may not be
valid filesystem path components. Canonical paths remain suitable for
navigation, history, tab state, and filesystem operations across Windows
languages.

### Tab header label shortening

`MainWindow.GetTabLabelFromPath` builds tab labels from localized Shell display
names and limits them to `MaxDisplayedPathLength` (currently 40 characters).
Filesystem roots use the filesystem path root (for example, `C:\`), matching
the address field and content-pane path display rather than the Shell's volume
label. For other paths, the default label starts with an ellipsis and the
current directory name. If that alone fills the limit, it is clipped to the
limit with a trailing ellipsis and the parent is omitted.

Otherwise, the label includes the parent and current directory. When it is too
long, the parent name is shortened first, preserving as much of it as needed to
fit and marking the truncation with an ellipsis. If the parent cannot absorb
the full overflow, the current directory name is shortened in five-character
steps and the combined label is recalculated. The current name is not shortened
below ten characters; when the next step would cross that minimum, the current
combined label is returned even if it exceeds the configured length limit.
When there is no non-root parent, the filesystem root replaces it and the
leading ellipsis prefix is omitted.

## Current Composition

- `MainWindow` owns the WPF application toolbar and `TabControl`.
- Each application tab contains one `Pathview`. A `Pathview` is the complete
  per-tab browsing unit for the displays and settings attached to that tab: it
  owns the active path, back/forward history, left directory-tree pane, right
  content pane, status display, and temporary view settings. The browsable
  Pathview shows only **Active path and siblings**; non-browsable Pathviews show
  only **Active path**. **Show directories** is tab-local; sort parameters are
  captured from the Shell folder view rather than stored independently by the
  `Pathview`.
- `Pathview.IsBrowsable` is immutable for the lifetime of a Pathview. `MainWindow`
  creates exactly one browsable Pathview as the `TabControl`'s first item; all
  subsequent Pathviews are non-browsable. The browsable tab is titled **BROWSE**
  regardless of location, has no close button, and is never inserted into the
  fixed-path map. The **New tab** toolbar control was removed; **Pin** is the
  operation for opening a fixed Pathview.
- `MainWindow._fixedPathviewsByPath` is a case-insensitive dictionary keyed by
  normalized full filesystem paths (`Path.GetFullPath`, with a trailing
  directory separator removed). It indexes only non-browsable Pathviews; the
  browsable Pathview is held separately and is never entered in this map. A
  reverse Pathview-to-key map supports cleanup, and a Pathview-to-`TabItem` map
  supports selection without searching the tab collection. A fixed Pathview is
  first registered with its requested initial path, then its key is reconciled
  after each successful location commit. Entries are removed when a fixed tab
  closes or its initial navigation fails.
- **Pin** looks up the browsable Pathview's current path in the fixed-path map.
  It selects the mapped tab when present, otherwise it creates a fixed
  Pathview, registers it, adds the tab after the first item, and selects it.
  This prevents duplicate fixed Pathviews at the same normalized path. **Browse**
  selects the first `TabItem` and navigates its browsable Pathview to the fixed
  Pathview's current location.
- Typed address input is resolved to a filesystem path and normalized to the
  same map key. If a fixed Pathview already owns that path, its tab is selected;
  otherwise the address request selects and navigates the browsable Pathview.
  Selecting an address dropdown entry remains a direct tab selection for the
  associated Pathview. Back, Forward, and Up select and operate on the
  browsable Pathview.
- App-owned navigation is ignored by non-browsable Pathviews. For navigation
  initiated inside the hosted Shell view, its `IExplorerBrowserEvents.OnNavigationPending`
  callback returns `E_ABORT` for unapproved navigation on non-browsable
  Pathviews. The host records each app-requested destination and allows a
  pending browse only when its filesystem path matches that requested
  destination; this permits initialization and other explicit app navigation.
  Rejected Shell folder navigation does not disable the Shell pane or its other
  commands and file operations.
- The content header presents non-browsable Pathviews as **FIXED** badge, path,
  then **Browse** button on one row. The browsable Pathview presents its path
  followed by **Pin**, with no badge. **Show directories** remains on the row
  below. The left pane uses the role-specific tree tab described above.
- The browsable **Active path and siblings** tree has a default-unchecked
  **Hide internal** checkbox. When enabled, child directories whose filesystem
  names begin with `.` or `$` are omitted; a directory with the Windows System
  attribute is omitted only when enumerating its contents returns
  access-denied. Hidden-only directories, accessible System directories, and
  junctions are not excluded by those classifications alone. Active-path
  ancestors remain visible. The filter is applied by the shared tree-child
  refresh path, including filesystem-change reconciliation, and does not
  affect the Shell content view.
- The right content pane is a separate content view. Production creates one
  `ShellExplorerBrowserHost` per `Pathview`; it derives from
  `HwndHost` and hosts one Shell `IExplorerBrowser` COM instance.
- `ActivePathTree` shows only the current ancestor route.
- `ActivePathAndSiblingsTree` additionally shows immediate child directories
  along the route. Both continue to navigate the Shell view through the common
  `Pathview.Navigate` method.
- The legacy WPF `ListView`, its filtering, icon binding, sizing, and menus are
  retained. `UseLegacyWpfFileList` in `ExplorerTabView.xaml.cs` is the explicit
  rollback switch: `false` selects the Shell view (production default); `true`
  makes the WPF list active again.

### Custom Tree Templates

Both directory trees in `ExplorerTabView.xaml` share
`DirectoryTreeItemStyle`. Its templates provide the following behavior:

- `ShellIconTemplate` displays each `TreeEntry`'s base shell icon and overlay.
- `HierarchicalDataTemplate` displays the entry's `Name` and uses `Children`
  for nested tree items.
- `DirectoryTreeItemStyle` binds each item's expanded and selected states to
  the `TreeEntry`, and supplies the custom `TreeViewItem` control template.
  The `TreeViewItem` control template puts a directional disclosure triangle,
  the shell folder icon, and the entry header in separate columns, with
  expanded children below the header. Clicking any part of a row makes its
  directory active; only the triangle can collapse an expanded branch. If the
  collapsed directory is the active browsable path, the parent becomes active
  and selected. The
  triangle is based on the presence of immediate subdirectories before tree
  filtering, so internal and directory-link entries count. Hidden filesystem
  items retain their Shell icon and are rendered with reduced opacity. The
  template hides placeholder entries and applies a light-blue selected-row
  background.

`Pathview.DirectoryTreeRowHeight` in `ExplorerTabView.xaml.cs` sets the
header border's minimum height to **24 WPF device-independent units (DIPs)**.
The header content is vertically centered, so this value controls the minimum
distance between rows in both directory trees. Adjust this constant to change
their row spacing; it does not affect the Shell content view or the retained
WPF file list.

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
Shell-backed navigation does not commit `CurrentPath` or history when the
browse is requested; those values and displays change only after
`OnNavigationComplete`. `OnNavigationFailed` restores the filter to the last
completed path, leaving the active location and history unchanged.
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

`Pathview.ShellBrowserSlot_SizeChanged` converts the WPF size to physical
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