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
render its own localized names. Custom tree sibling collections sort
lexicographically by those display names; the Shell content view retains its
configured sort column and direction.

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
- The application-wide implicit `TabItem` style, its Aero2 source, and the
  intentional corner-radius and border-overlap adaptations are documented in
  [TAB_ITEM_STYLE.md](TAB_ITEM_STYLE.md).
- Each application tab contains one `Pathview`. A `Pathview` is the complete
  per-tab browsing unit for the displays and settings attached to that tab: it
  owns the active path, back/forward history, left directory-tree pane, right
  content pane, status display, and temporary view settings. The browsable
  Pathview shows only **Active path and siblings**; non-browsable Pathviews show
  only **Active path**. **Hide directories** and each pane's **Hide internal**
  setting are tab-local; sort parameters are captured from the Shell folder
  view rather than stored independently by the `Pathview`.
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
- Each Pathview's location header spans the full width above its body. The
  visible **Browse** or **Pin** button is first; a non-browsable Pathview places
  its **FIXED** badge next, and the path label is always last. The main area
  below is split horizontally, with the role-specific directory-tree pane on
  the left and the content pane on the right. **Hide directories** and content
  **Hide internal** appear below the location header in the content pane. The
  location-row widget grid has a symmetric 10-DIP horizontal margin, and its
  outer border has a 36-DIP minimum height; inner widgets use 2-DIP vertical
  margins so the color-picker visibility does not change row height. The
  second row containing the sidebar, splitter, and content pane has a 4-DIP
  white inset; the outer `ExplorerTabs` has `Padding="0"`. Fixed Pathviews show a
  right-aligned color-palette button. Their location header starts white;
  choosing one of twelve light spectrum colors changes that header and the
  matching application tab. The browsable Pathview has no palette button.
  `PaneColorPalette` contains the brushes, displayed by
  `PaneColorSwatchTemplate` in a six-column grid. The swatch click updates the
  Pathview's `PaneBackground`, then asks `MainWindow` to update the matching
  `TabItem`.

  Tab coloring has a separate selected-state brush because the tab template's
  selected overlay would otherwise cover the `TabItem.Background`. Each tab's
  `TabItemChrome.SelectedBackground` defaults to white, preserving the normal
  white-selected/gray-unselected appearance before a picker selection. On a
  selection, `MainWindow.SetPathviewTabBackground` sets both the tab's normal
  `Background` (used when unselected) and its `SelectedBackground` (used by the
  selected overlay). `Browse` and `Pin` use `ContentPaneButtonStyle`, which
  suppresses the visible focus visual without making the buttons
  non-focusable.
- Below the two visibility checkboxes, each Pathview has a five-group content
  operations toolbar. Copy and Move have separate app-owned path state
  machines, independent of the Shell clipboard. Each Get stages the selected
  filesystem paths; Paste uses native `IFileOperation` to copy or move them to
  the active folder; Abort clears the staged paths. A prepared workflow
  disables the other workflow's entire group, while enabling only its own
  Paste and Abort buttons. The app-owned workflow is independent of the Shell
  clipboard and native context-menu Copy/Cut state; the optional integration
  below is the only bridge from Shell Copy into the app-owned Copy state. The
  staged data consists only of path strings: it holds no file handles and
  creates no locks, reservations, or leases on source objects. At Paste, the
  app checks that the destination is an accessible folder, reads filesystem
  attributes for every source, then resolves all source Shell items before
  queuing the native operation. A failed preflight starts no transfer and is
  surfaced through the operation error dialog; staged state is retained.
  Passing preflight does not prove all file contents are readable or all
  required permissions are granted. This is a point-in-time check, not
  protection against subsequent filesystem changes. If an object, its access
  rights, or the destination changes after preflight, `IFileOperation` can
  still fail. Multi-item operations are not transactional: a late failure may
  occur after earlier items have completed, with no automatic rollback.
  Optional Shell-copy integration lives in the
  removable `ShellCopyIntegration` side path: toolbar Copy get invokes the
  Shell Copy verb, while clipboard updates marked with the Shell Copy drop
  effect stage copied file paths through the internal Copy state transition.
  Shell clipboard state does not otherwise influence either workflow. Rename
  is available only for a single selected item and starts the hosted view's
  native inline editor. Do not invoke the selection `IContextMenu` with the
  canonical `rename` verb: that context-menu implementation returns
  `E_NOTIMPL` even though other verbs may work. Instead, obtain the selected
  item's `IDataObject` with `IShellView.GetItemObject(SVGIO_SELECTION)`, request
  the registered `Shell IDList Array` format as `TYMED_HGLOBAL`, and read its
  CIDA structure. The selected child PIDL is relative to the parent PIDL in
  that structure. The implementation requires exactly one child, then calls
  `IShellView.SelectItem` with that child PIDL and `SVSI_EDIT` (`0x0003`) to
  begin Shell inline editing. Keep the medium locked through that call, then
  unlock it, release the `STGMEDIUM`, and release both managed and raw COM
  references in `finally`. Selection-state refresh exposes whether exactly
  one filesystem item is selected so the toolbar can gate Rename before
  dispatch. The Shell owns edit validation, commit/cancel, and name-collision
  behavior. Path get is enabled only for one selected item and copies that
  item's filesystem path; Delete remains selection-aware. The Shell view's
  native context-menu Copy and Cut commands continue to work normally.
- The browsable **Active path and siblings** tree has a default-unchecked
  **Hide internal** checkbox. When enabled, child directories whose filesystem
  names begin with `.` or `$` are omitted; a directory with the Windows System
  attribute is omitted only when enumerating its contents returns
  access-denied. Hidden-only directories, accessible System directories, and
  junctions are not excluded by those classifications alone. Active-path
  ancestors remain visible. The filter is applied by the shared tree-child
  refresh path, including filesystem-change reconciliation.
- A fixed Pathview's **Active path** pane has its own default-checked
  **Hide internal** checkbox above the subfolder list. It applies the same
  internal-item predicate to that list's immediate children only; it does not
  change the content-pane filter or the browsable tree filter.
- The content pane has a separate, default-checked **Hide internal** checkbox
  beside the default-checked **Hide directories** checkbox. It uses the same
  item predicate for files and directories: it hides dot- and dollar-prefixed
  names, plus System items only when opening a file for read or listing a
  directory returns access-denied. The Shell `ICommDlgBrowser.IncludeObject` hook applies
  the filter to Shell items; the retained WPF list and status count use the same
  helper. This setting is independent of the browsable tree and fixed subfolder
  checkboxes and **Hide directories**. The **Name pattern** editor matches the Shell display
  name case-insensitively, falling back to the filesystem leaf name when no
  display name is available; blank means no pattern constraint, `?` matches one
  character, `*` matches zero or more characters, and `.` is literal.

### Baseline-aligned inline checkbox widget

Use `CheckBoxWrapper` when a checkbox and its one-line label must align with
neighboring text in a `TextBlock`. The stock WPF `CheckBox` aligns its glyph
with its own caption, but an enclosing `TextBlock` sees an embedded checkbox
as one UI element; it does not automatically use the baseline of the caption
hidden inside the checkbox template.

`CheckBoxWrapper` derives from `TextBlock` and places a contentless WPF
`CheckBox` in an `InlineUIContainer`, followed by the label as a `Run`. Its own
text line therefore has the label's baseline. After layout, it copies its
`TextBlock.BaselineOffset` to the attached baseline property used by the outer
`InlineUIContainer`. The outer line must set `BaselineAlignment="Baseline"`:

```xaml
<TextBlock TextWrapping="NoWrap">
    <InlineUIContainer BaselineAlignment="Baseline">
        <local:CheckBoxWrapper x:Name="HideDirectoriesCheckBox"
                               Label="Hide directories"
                               Margin="0,0,16,0" />
    </InlineUIContainer>
    <Run Text="Name pattern " />
</TextBlock>
```

The `local` namespace should resolve to `clr-namespace:SUTWinExplorer`. The
wrapper's `Label` sets the displayed caption. Its `x:Name` identifies the
wrapper, not the inner checkbox; use `GetCheckBox()` to access the actual WPF
control without duplicating or forwarding the checkbox API:

```csharp
HideDirectoriesCheckBox.GetCheckBox().Checked += HideDirectoriesCheckBox_StateChanged;
var isChecked = HideDirectoriesCheckBox.GetCheckBox().IsChecked == true;
```

Attach checkbox events after `InitializeComponent()`. The checkbox is owned by
the wrapper, so event handlers should be attached by the owning view and use
its normal lifetime. The widget's baseline refresh is tied only to its own
`Loaded` and `SizeChanged` events; it does not subscribe to static or
long-lived event sources.

The checkbox is visually translated down by 4 WPF device-independent units;
this render transform does not change the label baseline or layout size. Its
internal right margin (`4`) controls the checkbox-to-label gap. Set the
wrapper's XAML `Margin` to control the gap after the complete checkbox-label
unit (currently `16` in the content-filter row).

- The content filtering row starts with a **VIEW:** badge styled like the
  **SELECTED:** and **FIXED** badges.
- The right content pane is a separate content view. Production creates one
  `ShellExplorerBrowserHost` per `Pathview`; it derives from
  `HwndHost` and hosts one Shell `IExplorerBrowser` COM instance.
- `ActivePathTree` shows only the current ancestor route.
- `ActivePathAndSiblingsTree` additionally shows immediate child directories
  along the route. Both continue to navigate the Shell view through the common
  `Pathview.Navigate` method. Tree selection reflects the committed
  `CurrentPath`, regardless of whether navigation came from the tree, address
  field, toolbar history, or Shell content view. While navigation is pending,
  the prior successful path remains selected; completion commits and selects
  the new path, while failure preserves the prior selection. A browsable-tree
  click sets `TreeEntry.IsNavigationPending` before deferring the navigation
  request to the Shell. Its row uses a light-gray background; this is separate
  from `IsSelected`. The pending state clears on success, failure, synchronous
  request errors, or superseding navigation. At commit, the active route node is
  marked selected first; then its ancestors expand to reveal it, followed by
  expansion of the active node itself.
- The legacy WPF `ListView`, its filtering, icon binding, sizing, and menus are
  retained. `UseLegacyWpfFileList` in `ExplorerTabView.xaml.cs` is the explicit
  rollback switch: `false` selects the Shell view (production default); `true`
  makes the WPF list active again.

### Custom Tree Templates

**Success-gated active route:** `CurrentPath`, the selected tree node, and
programmatic expansion to a requested destination are committed only after the
Shell content view reports successful navigation. Until then, the previous
committed path remains selected. A tree-originated request is shown separately
through `TreeEntry.IsNavigationPending`; it is not WPF selection.

Both directory trees in `ExplorerTabView.xaml` share
`DirectoryTreeItemStyle`. Its templates provide the following behavior:

- `ShellIconTemplate` displays each `TreeEntry`'s base shell icon and overlay.
- `HierarchicalDataTemplate` displays the entry's `Name` and uses `Children`
  for nested tree items.
- `DirectoryTreeItemStyle` binds each item's expanded and selected states to
  the `TreeEntry`, and supplies the custom `TreeViewItem` control template.
  The `TreeViewItem` control template puts a directional disclosure triangle,
  the shell folder icon, and the entry header in separate columns, with
  expanded children below the header. Clicking any part of a row requests
  navigation; its directory becomes active and selected only after the Shell
  view successfully opens it. Only the triangle can collapse an expanded
  branch. If the collapsed directory is active, navigation to its parent must
  succeed before the parent becomes active and selected. The
  triangle is based on the presence of immediate subdirectories before tree
  filtering, so internal and directory-link entries count. Hidden filesystem
  items retain their Shell icon and are rendered with reduced opacity. The
  template hides placeholder entries and applies a light-blue selected-row
  background.

In a non-browsable Pathview, `ActivePathTab` contains a two-row grid. The
`ActivePathTree` sits in a gray-framed `GroupBox` headed **Path**, whose height
is set to the active route's row count times
`Pathview.DirectoryTreeRowHeight`; both tree scrollbars are disabled. The
lower star-sized row is a gray-framed `GroupBox` headed **Sub directories**.
It contains the default-checked
`HideInternalSubfoldersCheckBox` and a `ListView` inside its own frame, with
10px horizontal margins. The outer `GroupBox` frame is `#A6A6A6` at 1 DIP; the
inner list frame is `#646464` at 0.7 DIP. The `ListView` fills the remaining
area and scrolls vertically; its item-container height uses the same
`DirectoryTreeRowHeight` as the tree.

The `Pathview` root enables `UseLayoutRounding` and `SnapsToDevicePixels`, so
the layout and rendered edges throughout the pane use WPF's device-pixel
rounding and snapping. These settings improve edge alignment but do not
guarantee identical physical-pixel thickness at every DPI scale, especially
for fractional-DIP borders.

`RefreshActivePathTree` loads the active route endpoint's immediate child
directories into its `TreeEntry.Children` and binds those entries to
`ActivePathSubfoldersList`. The list reuses `ShellIconTemplate`, so base icons
and overlays match the trees. Tree siblings and subfolders are ordered by the
Shell-localized `TreeEntry.Name`. The subfolder checkbox passes its own filter
choice through `RefreshTreeChildren`; `InternalItemFilter.IsInternal` is shared
with the content and browsable-tree filters, while each view's checkbox state
remains independent.

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
Unchecking **Hide directories** can create or remove a vertical Shell scrollbar
without changing the WPF pane size, so that refresh also requires a width
recalculation.

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
Shell may replace the current view. After **Hide directories** refreshes the
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

## Hide Directories Filter

The **Hide directories** checkbox is WPF-owned and defaults to checked, which
preserves the default-hidden directory behavior. The positive internal
`_showDirectories` value is set to the inverse of the checkbox. The filter is
implemented at the Shell view boundary, so the Shell still owns enumeration,
icons, menus, and file operations.

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

### Content item filtering

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
- Runtime UI Automation on the default profile observed 23 file rows with
  **Hide directories** checked, 28 rows when unchecked, and 23 again when
  checked. This proves
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