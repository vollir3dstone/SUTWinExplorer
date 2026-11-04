# Shell Explorer Architecture and Decisions

> **Transition note:** The embedded Shell content view is currently inactive.
> Its architecture below is historical; see [SutShell Windows implementation](SUTSHELL_WINDOWS.md)
> for the current ContentView data boundary and its limitations.

> **Document scope:** This file records architecture, implementation details, API ownership, technical findings, decisions, and unresolved engineering work. It is not the user-facing behavior specification; see [SHELL_EXPLORER_BEHAVIOR_SPEC.md](SHELL_EXPLORER_BEHAVIOR_SPEC.md) for observable requirements and acceptance criteria.

## Decision Record

### 2026-11-01: Separate product name from internal identity

**Decision owner:** Volker.

**Decision:** Use `KIS Explorer` for the user-facing product name and `SUT`
for the publisher, as specified in
[SHELL_EXPLORER_BEHAVIOR_SPEC.md](SHELL_EXPLORER_BEHAVIOR_SPEC.md#product-identity).
Keep `SUTWinExplorer` as the development and internal identity. The project
file, .NET assembly, namespaces, XAML class and namespace references, embedded
resource names, diagnostic environment variables and log names, and the
internal folder-context-menu registry key retain their existing names. These
technical identifiers are not to be renamed merely to match the product name.

The Debug app host and both published application executables are named
`KIS Explorer.exe` without renaming the internal `SUTWinExplorer.dll` assembly.
The EXE's Windows product and description fields use `KIS Explorer` and its
company field uses `SUT`; technical `OriginalFilename` and `InternalName`
fields continue to identify `SUTWinExplorer.dll`. The project configures
the Debug host and development run command separately from the assembly and
renames the completed single-file Release output.

The installer uses the new application ID
`C49BDCBD-2354-49FC-A4F3-287C7C1E2E9E`, distinct from the old SUTWinExplorer
installer ID `7A143DD2-DB42-4ED7-A92E-8D9DB4656FC9`. Keep the new ID stable
for subsequent KIS Explorer releases. There is no migration or automatic
upgrade from the old installation; uninstall it manually first. In particular,
the context-menu registry key remains an internal identifier shared with the
old installer, so the two installations must not be treated as independent
coexisting installations.

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
labels. The browsable tree's virtual **Top** location is the explicit
non-filesystem exception described below.

**Application:** Custom tree labels, the address field and its open-tab
dropdown, the content-pane heading, and tab headers use Shell-provided display
names. The address field resolves typed localized path components back to
filesystem paths before navigation. The Shell-hosted content view continues to
render its own localized names. Custom tree sibling collections sort
lexicographically by those display names; the Shell content view retains its
configured sort column and direction.

#### GUID display names and address resolution

`ShellDisplayNameProvider.GetDisplayName` first calls `SHParseDisplayName` and
`SHGetNameFromIDList` with `SIGDN_NORMALDISPLAY`. The Shell can return a GUID
parsing name instead of the name shown by Explorer even for a filesystem path.
For example, on the development machine the OneDrive directory's PIDL normal
display name was `::{018D5C66-4533-4307-9B53-224DE2ED1FE6}`, whereas
`SHGetFileInfo` with `SHGFI_DISPLAYNAME` returned `OneDrive` for that same path.

When the initial display name has the form `::{GUID}`, the provider uses
`SHGetFileInfo` on a fully qualified original path and returns its nonempty
display name if available. Otherwise, it attempts to resolve the GUID itself
as a Shell parsing name and falls back to the original GUID if that fails.
This is a general Shell fallback, not a OneDrive-specific mapping. It depends
on the Shell providing a useful name; a GUID may remain visible if neither
lookup resolves it. If the initial PIDL lookup fails, the provider returns no
name and callers can fall back to the filesystem leaf name.

The provider changes presentation only: tree entries, navigation, history and
file operations retain the original internal filesystem path. The virtual
**Top** location remains the explicit Shell parsing-name exception below.

`ResolvePath` performs the reverse translation in the application, not by
asking the Shell to reverse an entire display path. It expands environment
variables and resolves relative input against the process working directory.
An existing full filesystem path wins immediately. Otherwise, it walks from
the root: an existing filesystem child wins; for any other component it
enumerates the parent's directories and compares their display names using the
same provider, case-insensitively. The first matching directory supplies the
internal path component. If enumeration fails or no name matches, the input
component is retained and navigation may subsequently fail. Duplicate display
names are therefore ambiguous, and a bare name such as `OneDrive` is not a
global search for the OneDrive folder. The localized **This PC** name and the
English `This PC` are handled separately as the virtual **Top** location.

The OneDrive example was checked in both directions on the development machine:
the display path `C:\Benutzer\Volker\OneDrive` resolved back to the internal
path `C:\Users\Volker\OneDrive`. This verifies that example, not every Shell
extension or GUID.

**Rationale:** Localized display names are presentation values and may not be
valid filesystem path components. Canonical paths remain suitable for
navigation, history, tab state, and filesystem operations across Windows
languages.

### Virtual This PC root and path expressions

The browsable tree's **Top** entry represents the Windows Shell **This PC**
known folder, not a filesystem directory. `ShellLocations.TopPath` stores its Shell
parsing name (`::{20D04FE0-3AEA-1069-A2D8-08002B30309D}`) as the internal
navigation/history value. The Shell browser navigates to that parsing name and
reports the virtual location back as `TopPath`; the tree's children are the
available filesystem drives.

The **Top** tree item gets its normal display name from the Shell and its icon
from the Shell image list using the parsed PIDL. Both are therefore localized
and follow the active Windows Shell configuration. They are presentation data,
not filesystem path components. Any composed filesystem path expression must
omit the **This PC** display label: for example, `C:\Benutzer\Volker` remains
that filesystem path rather than `This PC\C:\Benutzer\Volker`. The Shell
display name may still be shown in a location label such as the address field.

### Tab header label shortening

Fixed tabs use their complete custom name as the tab label when one is set.
Without a custom name, `MainWindow.GetTabLabelFromPath` builds the label from
localized Shell display names and normally targets `MaxDisplayedPathLength`
(currently 40 characters), subject to the minimum-current-name exception
below. An unavailable path retains its `!` marker before either label. The
tooltip continues to show the path or its failure message.
Filesystem roots use the filesystem drive designator without a trailing
separator (for example, `C:`), matching the address field and content-pane path
display rather than the Shell's volume label. For other paths, the default
label starts with an ellipsis and the
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
- The outer application tabs set `TabItem.MinWidth` from the measured width of
  sixteen lowercase `n` glyphs using the title `TextBlock`'s font properties
  and DPI. Each header uses a two-column `Grid`: a stretching `*` title column
  with centered text, and an `Auto` close-button column. The outer
  `ExplorerTabs.HorizontalContentAlignment="Stretch"` lets that header Grid
  occupy the tab's full width. These settings are applied when `MainWindow`
  creates its browsable and fixed tabs; they do not affect nested Pathview tabs.
- The application-wide implicit `TabItem` style, its Aero2 source, and the
  intentional corner-radius and border-overlap adaptations are documented in
  [TAB_ITEM_STYLE.md](TAB_ITEM_STYLE.md).
- Each application tab contains one `Pathview`. A `Pathview` is the complete
  per-tab browsing unit for the displays and settings attached to that tab: it
  owns the active path, left directory-tree pane, right
  content pane, status display, and temporary view settings. The browsable
  Pathview shows only **Active path and siblings**; non-browsable Pathviews show
  only **Active path**. **Hide directories** and each pane's **Hide internal**
  setting are tab-local; sort parameters are captured from the Shell folder
  view rather than stored independently by the `Pathview`.
- `ContentView` owns the content filter and action rows, the private spike
  table, the hosted Shell view, and their refresh and scroll synchronization.
  `Pathview` requests content navigation and passes committed locations and
  directory-notification paths to it; navigation completion, failure, folder
  activation, and filesystem changes are reported back as events. The Shell
  host stays private to `ContentView`. `Pathview` continues to own navigation
  history, success-gated tree selection, and notification-route calculation.
  Copy and Move workflow state remains shared across Pathviews. Common frame,
  button, and icon resources are defined once in `App.xaml` for both views.
  See [CONTENT_VIEW.md](./CONTENT_VIEW.md) for the component's behavior,
  interface, and implementation.
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
  after each successful location commit. Entries remain indexed after an
  initial navigation failure and are removed when a fixed tab closes.
- `App` owns a machine-wide named mutex and loads the active `default` profile
  before creating `MainWindow`. `ProfileStore` validates and saves the profile
  under roaming application data; `MainWindow` associates fixed Pathviews with
  their profile entries and synchronizes successful location changes and
  explicit closes. Startup restores tabs without selecting them. Failed
  locations remain associated and marked. See [Configuration.md](Configuration.md).
- `ProfilesView` owns profile-list selection, the read-only Pathview display,
  and the profile-name draft and edit state. It raises create, rename, delete,
  and activation requests to `MainWindow`. `ProfileStore` discovers and loads
  profiles, creates without overwriting, renames, and protects `default` from
  rename and deletion. `MainWindow` validates activation, removes Fixed tabs
  without deleting their entries, switches the active store and profile, and
  restores the target's Fixed tabs. A newly created profile is activated;
  deleting the active profile activates `default`. The BROWSE tab is retained.
  The toolbar icon toggles the two top-level views outside name editing.
  See [ProfilesView.md](ProfilesView.md).
- **Pin** looks up the browsable Pathview's current path in the fixed-path map.
  It selects the mapped tab when present, otherwise it creates a fixed
  Pathview, registers it, adds the tab after the first item, and selects it.
  This prevents duplicate fixed Pathviews at the same normalized path. The
  button is disabled for **This PC**, and `MainWindow` also rejects requests
  to create a fixed Pathview for that virtual location.
- Typed address input is resolved to a filesystem path and normalized to the
- Typed address input is resolved to a filesystem path and normalized to the
  same map key, then uses `MainWindow.NavigateWithHistory`. The **Browse**
  button uses that same history-aware operation but explicitly disables
  fixed-tab preference, so it always navigates the browsable Pathview.
  Selecting an address dropdown entry remains a direct tab selection for the
  associated Pathview. The browsable Pathview stores the shared path history;
  successful navigation and tab activation record paths in order.
- Navigation is split into two layers. `MainWindow.DisplayPathHistoryAgnostic`
  is the lower, shared presentation layer: it selects an exact matching fixed
  Pathview when preferred and available; otherwise it selects the browsable tab
  and invokes the supplied action on the browsable Pathview. It does not update
  history. `MainWindow.NavigateWithHistory` is the upper layer for normal
  activation: it calls the shared presentation layer, then records a visit when
  that layer selected a fixed tab. When the destination is shown in BROWSE,
  `Pathview.Navigate` records normal history only after Shell navigation
  succeeds. This keeps failed navigation out of history.
- Back and Forward are separate history-aware upper operations over the same
  presentation layer. If the destination belongs to an open fixed Pathview,
  the layer selects it and the caller advances the browsable Pathview's shared
  history with `ActivateHistoryLocation`. Otherwise, the layer selects BROWSE
  and invokes `GoBack` or `GoForward`, which navigate with the corresponding
  history action. Programmatic tab selection during history navigation does
  not add another visit. Up uses `NavigateWithHistory` for the parent path with
  `preferFixedView: false`, so it records normal navigation while always staying
  in the browsable Pathview.
- `MainWindow.NavigateWithHistory` accepts four optional nullable settings. A `null`
  filter setting means "leave the browsable Pathview's current setting
  unchanged"; it does not mean to use the checkbox default. `preferFixedView`
  has different null semantics: `null` is treated as `true`. If true, an exact
  matching open fixed Pathview is selected when available; if false, the path
  is always navigated in the browsable Pathview.

  | Caller | `hideSiblings` | `hideInternalDirectories` | `hideInternalContentItems` | `preferFixedView` |
  | --- | --- | --- | --- | --- |
  | Fixed **Path** tree, **Sub directories**, or Shell content directory activation | `true` | Fixed **Sub directories / Hide internal** value | Fixed content **Hide internal** value | omitted (`null`, therefore prefer fixed) |
  | Fixed **Browse** button | `true` | Fixed **Sub directories / Hide internal** value | Fixed content **Hide internal** value | `false` (always browse) |
  | Typed address input / Go | omitted (`null`, keep current) | omitted (`null`, keep current) | omitted (`null`, keep current) | omitted (`null`, therefore prefer fixed) |
  | Back / Forward history | Not passed to `NavigateWithHistory`; each uses the shared display layer and its own history action | Not passed | Not passed | Not passed |
  | Up | omitted (`null`, keep current) | omitted (`null`, keep current) | omitted (`null`, keep current) | `false` (always browse; normal history is written) |

- App-owned navigation is ignored by non-browsable Pathviews. For navigation
  initiated inside the hosted Shell view, its `IExplorerBrowserEvents.OnNavigationPending`
  callback returns `E_ABORT` for unapproved navigation on non-browsable
  Pathviews. The host records each app-requested destination and allows a
  pending browse only when its filesystem path matches that requested
  destination; this permits initialization and other explicit app navigation.
  Rejected Shell folder navigation does not disable the Shell pane or its other
  commands and file operations. Explicit folder opening is separate from
  navigation of the fixed Pathview: single-clicking a directory in its Active
  path tree or Sub directories list, or double-clicking one in its Shell content
  view, requests that path through `NavigateWithHistory`, selects an exact
  matching fixed Pathview when available, and leaves the source fixed Pathview's
  location unchanged. A Shell-view `.lnk` targeting a directory requests its
  resolved target path in the same way.
- Each Pathview's location header spans the full width above its body. The
  visible **Browse** or **Pin** button is first; a non-browsable Pathview places
  its **FIXED** badge next, followed by the current directory's Shell icon and
  path expression. A pencil button before the color picker opens a custom-name
  dialog. The Pathview constructor receives the initial nullable name and a
  name-change callback; `MainWindow` owns the profile entry and saves accepted
  changes. The dialog editor is 28 DIP high and uses the path display's font
  and foreground. Its undefined-name placeholder uses the same font with a
  lighter gray foreground. Apply saves the name, including `null` for an empty
  value; Cancel or Escape discards changes. Opening a Fixed tab or applying its
  name requests focus on the native Shell content when available; the host
  retries after delayed navigation only while it still has focus. BROWSE has
  no name-edit button. At the far right, every Pathview has a 28-by-28-DIP
  button for opening the current location in Windows Explorer. The main area below is
  split horizontally, with the role-specific directory-tree pane on the left
  and the content pane on the right. **Hide directories** and content **Hide
  internal** appear below the location header in the content pane. The
  location-row widget grid has a symmetric 10-DIP horizontal margin, and its
  outer border has a 36-DIP minimum height; inner widgets use 2-DIP vertical
  margins so the color-picker visibility does not change row height. The
  second row containing the sidebar, splitter, and content pane has a 4-DIP
  white inset; the outer `ExplorerTabs` has `Padding="0"`. Fixed Pathviews show a
  right-aligned name-edit pencil, color-palette button, and Explorer button, in
  that order. Their location
  header starts white; choosing one of twelve light spectrum colors changes
  that header and the matching application tab. The browsable Pathview has no
  palette button.
  `LocationIconSlot` reserves a 24-by-24-DIP square before the path expression.
  `ShellIconProvider.GetIconAtSize` requests its base image from
  `IShellItemImageFactory.GetImage` at the equivalent physical-pixel size for
  the current DPI. The Shell image-list icon remains the fallback; its overlay
  and hidden-item opacity are composed separately. The Explorer button shows
  the Shell icon for `%WINDIR%\\explorer.exe` at 16 DIP.
  `OpenInExplorerButton_Click` starts `explorer.exe` using
  `UseShellExecute=true` and the command-line convention
  `/n, "<CurrentPath>"`; `/n,` requests a new window and the quoted current
  path is its target. The button is enabled after the Pathview commits a
  successful current path.
  `PaneColorPalette` contains the brushes, displayed by
  `PaneColorSwatchTemplate` in a six-column grid. The swatch click updates the
  Pathview's `PaneBackground` and reports the color through a callback.
  `MainWindow` updates the matching `TabItem` and saves the color in the
  associated profile entry. The constructor receives the initial color;
  `null` preserves the default appearance. A color selected before an entry
  exists is included when initial navigation creates that entry.

  Tab coloring has a separate selected-state brush because the tab template's
  selected overlay would otherwise cover the `TabItem.Background`. Each tab's
  `TabItemChrome.SelectedBackground` defaults to white, preserving the normal
  white-selected/gray-unselected appearance before a picker selection. On a
  selection, `MainWindow.SetPathviewTabBackground` sets both the tab's normal
  `Background` (used when unselected) and its `SelectedBackground` (used by the
  selected overlay). `Browse` and `Pin` use `ContentPaneButtonStyle`, which
  suppresses the visible focus visual without making the buttons
  non-focusable.
- Content operations are presented by each ContentView, but Copy and Move
  prepared state is shared across tabs. `MainWindow` owns the optional
  Shell-copy integration; its interaction with the shared workflows is
  described in [CONTENT_VIEW.md](./CONTENT_VIEW.md#transfer-and-selection-implementation).
- The browsable **Active path and siblings** tree has a **Top** root named with
  the localized Shell display name for **This PC** and shown with its Shell
  icon; its children are the available drives. Selecting it navigates the
  Shell browser to **This PC** and makes **Top** the active path. The This PC
  label is omitted from composed filesystem path expressions. The tree has a
  default-checked **Hide siblings** checkbox before its default-checked
  **Hide internal** checkbox. **Hide siblings** limits the displayed drives to
  the active drive, shows only the next active-path directory at each ancestor,
  and shows all immediate child directories of the active directory. When
  disabled, the tree retains its normal active-path-and-siblings behavior.
  **Hide internal** independently omits child directories whose filesystem
  names begin with `.` or `$`; a directory with the Windows System attribute is
  omitted only when enumerating its contents returns access-denied. Hidden-only
  directories, accessible System directories, and junctions are not excluded
  by those classifications alone. Active-path ancestors remain visible. The
  filter is applied by the shared tree-child refresh path, including
  filesystem-change reconciliation. In the browsable Pathview, the filter row
  and tree occupy `Auto`, 8-DIP spacer, and `*` rows in a `Grid`. Both are inset
  4 DIP horizontally; the tree is wrapped in a `Border` using the shared
  `ViewFrameBrush`, with the TreeView's own border disabled.
- A fixed Pathview's **Active path** pane has its own default-checked
  **Hide internal** checkbox above the subfolder list. It applies the same
  internal-item predicate to that list's immediate children only; it does not
  change the content-pane filter or the browsable tree filter. The list does not
  expose a persistent, user-managed or multiple selection like the content
  table. Pointer actions identify the clicked or dragged folder; WPF selection
  may be used temporarily for menus or keyboard interaction. Entering a row and
  closing its item menu clear that selection. An open menu keeps its target;
  prepared transfers retain their own source paths and use the current directory
  as their destination.
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
  **FOR SELECTED:** and **FIXED** badges.
- The right content pane is a separate `ContentView`. Production creates one
  `ShellExplorerBrowserHost` inside each `ContentView`; it derives from
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
  request errors, or superseding navigation. At commit, the active route node is
  marked selected first; then its ancestors expand to reveal it, followed by
- The legacy WPF `ListView`, its filtering, icon binding, sizing, and menus are
  retained. `UseLegacyWpfFileList` in `ContentView.xaml.cs` is the explicit
  rollback switch: `false` selects the Shell view (production default); `true`
  makes the WPF list active again.

### Custom Tree Templates

programmatic expansion to a requested destination are committed only after the
Shell content view reports successful navigation. Until then, the previous
committed path remains selected. A tree-originated request is shown separately
through `TreeEntry.IsNavigationPending`; it is not WPF selection.

`DirectoryTreeItemStyle`. Its templates provide the following behavior:

- `ShellIconTemplate` displays each `TreeEntry`'s base shell icon and overlay.
- `HierarchicalDataTemplate` displays the entry's `Name` and uses `Children`
  for nested tree items.
- `DirectoryTreeItemStyle` binds each item's expanded and selected states to
  the `TreeEntry`, and supplies the custom `TreeViewItem` control template.
  The `TreeViewItem` control template puts a directional disclosure triangle,
  expanded children below the header. Clicking any part of a row requests
  navigation; its directory becomes active and selected only after the Shell
  view successfully opens it. Only the triangle can collapse an expanded
  branch. If the collapsed directory is active, navigation to its parent must
  succeed before the parent becomes active and selected. The
  filtering, so internal and directory-link entries count. Hidden filesystem
  items retain their Shell icon and are rendered with reduced opacity. The
  template hides placeholder entries. Application resources `ItemHoverBrush`,
  `ItemSelectionBrush`, `ItemSelectionBorderBrush`, and `ItemRequestBrush`
  define the shared hover, selection, selection-border, and pending-request
  colors. The tree and application-owned lists use these brushes; the hosted
  Shell content view renders its own states. Tree hover applies to the header
  row only, not its expanded descendants. Selection overrides hover, and a
  pending request overrides hover without replacing the selected active path.

`ActivePathTree` sits in a `GroupBox` headed **Path**. Its height is set to
the active route's row count times `Pathview.DirectoryTreeRowHeight`; both tree
scrollbars are disabled. The tree is wrapped in a `Border` using the shared
`ViewFrameBrush` and `ViewFrameThickness` resources, matching the other framed
application-owned trees and lists. `ViewFrameThickness` is 0.7 DIP and applies
to all borders using `ViewFrameBrush`, including the hosted Shell view. Both
active-path sections remain actual WPF `GroupBox`es, so their
grouping, headers, and content are preserved. `HeaderLineGroupBoxStyle`
replaces only the usual outer frame: its template places each header between
two horizontal rules that remain 1 DIP high, with 8-DIP gaps beside the title,
and presents the GroupBox content below it using the control's `Padding`. The lower star-sized
row is headed **Sub directories** and contains the default-checked
`HideInternalSubfoldersCheckBox` and a `ListView` inside its own frame, with
16-DIP horizontal margins. The header rules use the shared `ViewFrameBrush`;
the inner list frame uses the same brush at 0.7 DIP. The `ListView` fills the
remaining area and scrolls vertically; its item-container height uses the same
`DirectoryTreeRowHeight` as the tree.
The list remains selectable. Its item containers use the shared hover and
selection brushes. On every `MouseEnter` over a list item, the selection is
cleared. Closing a folder's context menu also clears selection, whether the
menu was opened by mouse or keyboard. A later click or keyboard action can
select an item again.

The **Active path** tab page's two-section Grid has an 8-DIP margin to the
tab-page edges. The sidebar `TabControl` has a 4-DIP right margin to separate
it from the horizontal `GridSplitter`; the containing two-pane Grid retains a
4-DIP margin.

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

## ContentView and Shell host

Pathview requests navigation through ContentView and commits location and history
only after successful Shell navigation. ContentView encapsulates the host; its
[implementation and navigation details](./CONTENT_VIEW.md#shell-view-host) are
documented with the component.

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

## ContentView sizing and filtering

Shell content sizing and filter internals are documented in
[CONTENT_VIEW.md](./CONTENT_VIEW.md#shell-details-column-sizing).

## Native Context Menus and Operations

The hosted Shell content view supplies its own item and background menus,
clipboard context-menu verbs, and drag/drop. The app still uses
`ShellContextMenu` for context menus requested from the custom WPF directory
tree and Sub directories list. The **Path** tree in the **Active path** tab has
no context menu. The helper queries native Shell context menus and forwards required
`IContextMenu2`/`IContextMenu3` menu messages.

The custom ContentView and participating sidebar widgets use the paired menus
described in [CONTEXT_MENU_SPEC.md](CONTEXT_MENU_SPEC.md). Their controller
temporarily monitors mouse movement during a menu sequence: leaving the system
double-click area or executing a command resets it, without closing an open
popup on movement. The next normal right-click starts a new Base Menu; native
fallback and keyboard-invoked menus do not start this sequence. The monitor is
released on reset or view unload.

The custom table and Sub directories list share `ListViewDragSource` and
`ListViewDropTarget` for left-button filesystem drag-and-drop. The table supplies
its selection, while the list supplies only the clicked folder. `ShellDragDrop`
obtains a Shell data object and delegates incoming drags to the native folder
drop target. Directory rows select their own destination; file rows and the
background select the current directory. Non-filesystem and right-button drags
are rejected, and tree views do not participate. Ordinary right-click menu
handlers remain independent of drag-and-drop. Integration tests in
[ShellDragDrop.Tests.ps1](tests/ShellDragDrop.Tests.ps1) exercise real gestures,
modifier effects, cross-process data and right-click behavior.

For **Active path and siblings** tree and **Sub directories** items, the helper requests `CMF_CANRENAME` and
dispatches the Shell's rename command to a WPF inline editor; committing calls
the parent Shell folder's `SetNameOf`. Open Pathviews remap affected locations
and history to the returned filesystem path. The virtual **This PC** tree root
has no rename editor.

Shell keyboard routing and the corresponding spike checks are documented in
[CONTENT_VIEW.md](./CONTENT_VIEW.md#shell-keyboard-routing).

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