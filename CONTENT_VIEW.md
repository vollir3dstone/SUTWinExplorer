# ContentView

## Scope and relationship to the application

`ContentView` is the content component of one Pathview. Its XAML and code-behind
live in [ContentView.xaml](./ContentView.xaml) and
[ContentView.xaml.cs](./ContentView.xaml.cs). It owns the content filter and
operation rows, the private spike table, and the hosted Shell view. The Shell
host is private to the component; callers do not access it directly.

The [behavior specification](./SHELL_EXPLORER_BEHAVIOR_SPEC.md) remains the
authority for application-visible requirements and acceptance checks. The
[application architecture](./SHELL_EXPLORER_ARCHITECTURE.md) describes how
Pathviews, navigation, trees, tabs, and content views work together. This
document describes the component boundary and its current implementation.

## Behavior

Each ContentView presents the current directory's Shell content and the
adjacent experimental private column. The Shell remains authoritative for
items, their order, selection, and native commands; the private table mirrors
displayed filesystem paths and follows Shell scrolling. The table and
scroll-alignment measurements are a spike, not a replacement for the Shell
view.

The **VIEW** row controls the content's **Hide directories**, **Hide internal**,
and **Name pattern** filters. These settings are local to the Pathview; the
content **Hide internal** setting is independent of the tree filters. The
**FOR SELECTED** row offers Rename, Path get, Copy get/abort/paste, Move
get/abort/paste, and Delete. Button availability depends on the local selection
and on the shared transfer state.

### Copy and Move across ContentViews

Copy and Move are logically content operations, but their prepared states are
shared application-wide, not stored in a ContentView instance. A user can
stage source paths in one tab and paste into the current directory of another
tab. A prepared Copy enables Copy paste and abort and disables the Move group;
a prepared Move does the converse. Abort clears the prepared paths; a
successful paste clears them after the operation returns. Selection and filter
settings remain local to each view.

Staging stores paths, not handles or reservations. Paste performs preflight
checks, but paths and permissions can change afterward; a multi-item operation
is not atomic and can partially complete before a later error. Failed preflight
does not start a transfer and leaves the staged state available. See the
[behavior specification](./SHELL_EXPLORER_BEHAVIOR_SPEC.md#content-listing)
for the full rules, error behavior, and acceptance criteria.

The app-owned workflows do not use the Shell clipboard for their transfer
state. An optional Shell Copy integration bridges Shell Copy into the Copy
workflow; it does not turn Shell Cut into Move. Shell context-menu and
clipboard operations remain Shell-owned.

## Interface to Pathview

These members are the current internal component API, not a separate C#
interface. The enclosing Pathview owns navigation history and success-gated
location/tree updates.

| Member | Contract |
| --- | --- |
| `Initialize(isBrowsable)` | Called once after construction. Configures the content's browsable/fixed role and creates the Shell host in the default mode. A second call throws. |
| `UsesSynchronousNavigation` | Indicates the retained legacy WPF mode. Pathview validates and commits that mode's directory navigation itself. |
| `NavigateTo(path)` | Requests Shell-backed navigation; it does not commit the Pathview location. It throws if asynchronous content navigation is unavailable. |
| `NavigationCompleted(path)` / `NavigationFailed(path)` | Report Shell navigation outcomes. Pathview handles pending requests and commits its location/history only on success; a failure path may be empty. |
| `FolderOpenRequested(path)` | Reports a folder activation for Pathview to route according to its browsable/fixed role. |
| `SetCurrentPath(path)` | Supplies the location committed by Pathview. It neither navigates nor refreshes the content by itself. |
| `HideInternalItems` | Gets or sets this view's nullable content **Hide internal** checkbox state. The other content filters are currently controlled by the view's own UI. |
| `Refresh(refreshView)` / `RefreshStatus()` | Refresh content or its status as requested. In Shell mode, status refresh also schedules private-table repopulation. |
| `SetObservedDirectories(paths)` / `ClearObservedDirectories()` | Pass or clear the directory-notification routes calculated by Pathview. |
| `FileSystemChanged` | Reports a Shell filesystem notification; Pathview coordinates its own deferred content/tree refresh. |

`PrivateTableTopGapOffset` is a WPF binding property for the spike's visual
alignment, not a navigation or Shell API. The action buttons do not expose
the Shell host: ContentView handles them and uses the shared workflow state.

## Implementation

### Component ownership and lifetime

`Initialize` creates one `ShellExplorerBrowserHost` in the default Shell mode
and forwards its navigation, folder-open, and filesystem events. ContentView
attaches the 30-ms scroll timer and workflow/selection notifications when
loaded; on unload it stops its scroll and table-refresh timers and detaches
those subscriptions. Pathview owns calculation and clearing of notification
routes and retains its separate filesystem-refresh timer. The host manages its
native window and COM lifetime.

The retained `UseLegacyWpfFileList` switch is in `ContentView.xaml.cs`:
`false` selects the Shell view and private spike table; `true` selects the
legacy WPF list. The legacy mode has synchronous navigation controlled by
Pathview and does not create the Shell host.

Frame brushes/thickness, content button style, and the Shell icon template are
defined once in [App.xaml](./App.xaml) and reused by ContentView and Pathview.
The virtual This PC path is shared through `ShellLocations`; it is not a
filesystem path.

### Private table and scroll synchronization

`RefreshShellStatusCount` restarts a 300-ms debounce timer in Shell mode. The
timer queries the Shell view's displayed filesystem paths through
`GetDisplayedFileSystemPaths` and fills the private table in Shell order, using
the filesystem leaf names. The query goes through the displayed-items
`IDataObject`/`CF_HDROP` path rather than independently enumerating the
directory. COM or invalid-operation failures are written to debug output.

The Shell view is DirectUI, so the spike polls its vertical scrollbar child
using `GetScrollInfo`, not `LVM_*` or `GetVisibleItem`. The observed range is
item count times 100. Every 30 ms, the table computes
`rowsScrolled = position * itemCount / total` and scrolls its pixel-virtualized
WPF viewer by `rowsScrolled * rowPitch`. The pitch is measured between the first
two realized rows and cached; a single-row fallback is not cached.

The private header is 24 DIP high. A render-only 6-DIP row translation decreases
to zero over the first Shell row, approximating the Shell's initial gap without
changing virtualized item sizes or scroll extent. This is empirically derived,
not a documented Shell metric. At 96 DPI, the latest measured alignment was
0 px from the top through the middle and 1 px at the end; other DPI settings
and Windows versions remain untested. See the
[scroll-sync handoff](./SCROLL_SYNC_HANDOFF.md) for measurements and history.

### Transfer and selection implementation

`CopyWorkflowState.Shared` and `MoveWorkflowState.Shared` hold distinct prepared
path arrays and raise change events. Loaded ContentViews subscribe and update
their button states; they do not own those shared states. `ShellFileOperations`
checks destination and source attributes, resolves all source Shell items
before queuing, and invokes native `IFileOperation`. The control reports
operation errors and clears the prepared state only after the operation
returns successfully. Preflight cannot prevent subsequent changes and no
rollback is performed after a partial transfer.

`MainWindow` owns the optional `ShellCopyIntegration` clipboard listener.
Toolbar Copy get stages the selection and asks this integration to invoke the
Shell Copy verb. An external Shell Copy notification aborts a prepared Move
and attempts to prepare Copy; an already prepared Copy is not replaced.

Rename is enabled for exactly one selected filesystem item and starts the
Shell inline editor. Do not invoke the selection `IContextMenu` with the
canonical `rename` verb: that implementation returned `E_NOTIMPL`. Instead,
the implementation obtains `SVGIO_SELECTION` as an `IDataObject`, reads its
Shell IDList Array as `TYMED_HGLOBAL`, and calls `IShellView.SelectItem` with
the single relative child PIDL and `SVSI_EDIT` (`0x0003`). The medium remains
locked during that call; the medium and managed/raw COM references are
released in `finally`. The Shell owns validation, commit/cancel, and
name-collision behavior. Path get uses the selected filesystem path; Delete
and native Shell context-menu operations remain selection-aware.

### Shell View Host

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
The virtual This PC root is a handled exception; other non-filesystem
namespace locations do not become filesystem paths and are not fully integrated
with the custom trees yet.

For a non-browsable Pathview, single-clicking a directory in the Active path tree
or Sub directories list raises an explicit open request instead of
navigating that Pathview. The Shell view routes its default open command through
`ICommDlgBrowser.OnDefaultCommand`; the host reads the selected filesystem path
and accepts the command only for a directory or a `.lnk` resolving to a
directory. If Shell navigation for a folder or folder shortcut reaches
`OnNavigationPending`, the fixed host still returns `E_ABORT`, but first
resolves a filesystem folder target and raises the same open request. Pathview
forwards this to `MainWindow.NavigateWithHistory`, which selects an existing
matching fixed tab when available; otherwise it navigates the browsable
Pathview and commits its path and history only when its Shell view confirms
success. The source fixed Pathview's location and state are not changed.

The initial browse must not run synchronously inside `BuildWindowCore`.
`BrowseToIDList` can pump Windows messages; doing so during WPF's initial layout
caused a dispatcher exception and prevented startup. Deferring the browse
avoids that reentrancy.

### Shell keyboard routing

The ExplorerBrowser spike verified context-menu New, context-menu Copy/Paste,
Paste shortcut, clipboard interoperability with Windows Explorer, and
right-button drag/drop. Its initial Ctrl+C/Ctrl+V keyboard test failed. The
host now overrides `HwndHost.TranslateAcceleratorCore` and forwards messages to
the current view's `IInputObject.TranslateAcceleratorIO`; if that returns
`S_FALSE`, it falls back to `IShellView.TranslateAccelerator`. Runtime tests
with disposable files verified Ctrl+A selection, Ctrl+C copy, Ctrl+V paste,
Ctrl+X cut, and Ctrl+Z undo. The Shell-hosted view remains responsible for
common file operations; do not duplicate these as custom file-copy code.

### Shell Details Column Sizing

#### Expected behavior

The WPF content pane occupies the remaining width after the sidebar. The hosted
ExplorerBrowser view must follow that pane on both window resize and sidebar
splitter movement. In Details mode, the visible non-Name columns retain their
Shell-provided widths and Name uses the remaining width. The standard column
order is Name, Type, Size, and Date modified; the Shell's Size column provides
the KB-formatted value. The resulting view
must have no horizontal scroll range at the tested layout sizes. Unchecking **Hide directories** can create or remove a vertical Shell scrollbar
without changing the WPF pane size, so that refresh also requires a width
recalculation.

`ContentView.ShellBrowserSlot_SizeChanged` converts the WPF size to physical
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
Shell may replace the current view. After **Hide directories** refreshes the
view, a one-shot 250ms dispatcher timer allows Shell's scrollbar child windows
to settle before measuring the visible vertical scrollbar and recalculating
Name. `IColumnManager` widths are physical pixels. Its COM method declarations
must follow the SDK vtable order (`SetColumnInfo`,
`GetColumnInfo`, `GetColumnCount`, `GetColumns`, `SetColumns`); a different
declaration order dispatches calls to the wrong native methods.

#### Measured behavior

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

Unchecking **Hide directories** in a folder with enough entries to show the
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

### Hide Directories Filter

The **Hide directories** checkbox is WPF-owned and defaults to checked, which
preserves the default-hidden directory behavior. The positive internal
`_showDirectories` value is set to the inverse of the checkbox. The filter is
implemented at the Shell view boundary, so the Shell still owns enumeration,
icons, menus, and file operations.

#### Service registration

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

#### Content item filtering

The **Name pattern** editor, when nonblank, requires the item's Shell display
name (or filesystem leaf name if unavailable) to match its wildcard expression.
When **Hide directories** is checked,
`IncludeObject` excludes items classified as folders. The separate content
**Hide internal** checkbox excludes items matching its rules. If the pattern is
blank and neither hide filter is active, `IncludeObject` returns `S_OK` for
every item. Otherwise it:

The exclusion rules combine with OR: an item is excluded if any enabled rule
matches. Inclusion is the AND of passing each enabled filter:

```text
hideByName = name starts with "." or "$"
hideBySystemAccess = isSystem and accessDenied
patternMatches = pattern is blank or wildcard-matches the display name
exclude = not patternMatches
  or (hideDirectories and isDirectory)
  or (hideInternal and (hideByName or hideBySystemAccess))
include = patternMatches and not (hideDirectories and isDirectory)
  and not (hideInternal and (hideByName or hideBySystemAccess))
```

Equivalently, inclusion requires all of these conditions:

```text
(patternMatches)
and (not hideDirectories or not isDirectory)
and (not hideInternal or
  (not hideByName and (not isSystem or accessAllowed)))
```

For a file, `accessDenied` means it cannot be opened for reading; for a
directory, it means its entries cannot be listed. `isSystem` alone does not
exclude an item. Junction status is not part of either rule.

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
4. Returns `S_FALSE` for folder items when **Hide directories** is checked.
5. When the pattern is nonblank or content **Hide internal** is checked, gets
  the child item's parsing name and combines it with the current path. It
  rejects names that do not match the pattern, then evaluates the shared
  `InternalItemFilter` predicate when **Hide internal** is checked. Dot- and
  dollar-prefixed names are excluded. A System item is excluded only when
  opening a file for read or listing a directory returns access-denied.

The child PIDL passed to `IncludeObject` is borrowed and is not freed. The child
PIDL returned by `SHBindToParent` points into the absolute PIDL allocation and
is also not freed separately. Only the pointer array allocated for
`GetAttributesOf` and the absolute PIDL allocation are freed by this code.
Folder-query and name-resolution failures fail open (`S_OK`) rather than
accidentally hiding ordinary files. Access-denied is the only I/O failure used
to exclude a System item; other I/O failures remain visible.

Directory reparse points follow the same folder and internal-item rules when
the Shell reports `SFGAO_FOLDER`; junction status alone is not a filter
condition. Runtime testing verified ordinary directories; junction/reparse-
point coverage remains a dedicated acceptance test.

When either content checkbox changes, `ShellExplorerBrowserHost` updates the
site state, obtains the current `IShellView` through
`IExplorerBrowser.GetCurrentView`, and calls `IShellView.Refresh` to re-enumerate
the active folder without navigation. `SetShowDirectories` receives the
positive value derived from the inverse of **Hide directories**.

#### Filter debugging findings

- `IShellFolder.GetUIObjectOf` does not support `cidl == 0`; use
  `IShellView.GetItemObject(SVGIO_BACKGROUND, ...)` for folder-background
  menus. That is separate from the directory-filter callback.
- Trying to obtain the current folder with
  `IShellView.GetItemObject(SVGIO_BACKGROUND, IID_IShellFolder)` returned
  `E_NOINTERFACE`. The working filter instead binds the current path through
  `SHParseDisplayName`, `SHBindToParent`, and `BindToObject`.
- A temporary trace confirmed that `QueryService` and `IncludeObject` were
  reached. The trace was removed after fixing folder binding.
- Runtime UI Automation on the default profile observed 23 file rows with
  **Hide directories** checked, 28 rows when unchecked, and 23 again when
  checked. This proves
  live checkbox refresh in that folder; it is not a complete reparse-point
  test.
