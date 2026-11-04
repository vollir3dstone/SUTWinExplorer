# Shell Explorer Behavior Specification

> **Transition note:** The embedded Shell content view has been replaced by an
> initial application-owned table. Shell-specific implementation claims and
> checked implementation statuses below have not yet been revalidated for that
> table. The current gaps are listed in [SutShell API](SUTSHELL_API.md).

> **Document scope:** This file specifies observable user-facing behavior and acceptance criteria only. It intentionally does not prescribe COM interfaces, WPF controls, class names, or other implementation choices. Those belong in [SHELL_EXPLORER_ARCHITECTURE.md](SHELL_EXPLORER_ARCHITECTURE.md).

## Priorities

- **P0**: Core Explorer workflows required for a useful file browser.
- **P1**: Expected conveniences that should follow after core operations are reliable.
- **P2**: Optional Shell namespace and presentation features.

Checkboxes record implementation status, not changes to the expected behavior.

## Terminology

A **Pathview** is the browsing unit attached to an application tab. It comprises
the directory-tree pane, content pane, status display, active location, and
temporary view settings scoped to that tab. Each tab retains its own Pathview
state when the user switches tabs. For example, **Hide directories** is
tab-scoped; sort history is also tab-scoped and remains in effect on navigation.
A Pathview is either browsable or non-browsable; that role is assigned
when it is created and cannot be changed by the user.

A **transfer operation** is the application's Link, Copy or Move workflow. Each
consists of three suboperations:

- **Mark item** prepares the selected files and directories as sources without
  linking, copying or moving them.
- **Execute** creates shortcuts to, copies or moves the prepared sources into the current directory.
- **Abort** discards the prepared sources without transferring them.

The prepared transfer is shared across tabs, so its sources can be selected in
one Pathview and transferred in another. Only one Link, Copy or Move can be prepared at a
time. A successful Execute or Abort returns the transfer to its idle state; if
Execute fails, the prepared sources remain available. A failed transfer may
already have completed some items.

### Clipboard actions and transfer functions

Clipboard actions use the Windows clipboard and are completely independent of
the application's prepared Link, Copy and Move transfers. The full action names
appear in tooltips and Base Menus; the buttons use these compact labels and symbols:

| Action | Button | Effect |
| --- | --- | --- |
| **Name clipboard copy** | `Name` + Clipboard copy icon (clipboard with a left-pointing arrow) | Copies selected filesystem names as text. |
| **Path clipboard copy** | `Path` + Clipboard copy icon | Copies selected full filesystem paths as text. |
| **Item clipboard copy** | `Item` + Clipboard copy icon | Copies selected files and directories to the Windows clipboard. |
| **Item clipboard paste** | `Item` + Clipboard paste icon (clipboard with a right-pointing arrow) | Copies supported clipboard files and directories into the current directory; Cut and Link are rejected. |

The three Clipboard copy buttons are grouped in the selection row. Item clipboard
paste is in the directory column before the transfer buttons. These actions are
also available in the applicable Base Menus, using the same icons as their buttons.

The application-owned transfers have separate controls and do not use clipboard
icons:

| Transfer | Mark item button | Abort button | Execute button |
| --- | --- | --- | --- |
| Link | **Link mark item**: `Link🠝` | **Link abort**: `Link✕` | **Link execute**: `Link🠟` |
| Copy | **Copy mark item**: `Copy🠝` | **Copy abort**: `Copy✕` | **Copy execute**: `Copy🠟` |
| Move | **Move mark item**: `Move🠝` | **Move abort**: `Move✕` | **Move execute**: `Move🠟` |

The upward arrow prepares sources, the cross aborts a prepared transfer, and
the downward arrow performs that transfer. The three Mark item buttons form one
group in the selection row. The corresponding Base Menu entries
use the same symbols, as does Delete. Only one Link, Copy or Move transfer
can be prepared at a time, but clipboard actions remain independent of it:

- Clipboard copy and paste neither prepare, execute, abort nor replace a transfer.
  They remain available during a prepared transfer when their own selection,
  clipboard and destination requirements are met.
- Transfer Mark item, Execute and Abort do not copy to or read from the Windows clipboard.
  In particular, **Copy mark item** prepares an internal Copy; it is not **Item clipboard copy**.
- Clipboard changes or pastes in Windows Explorer or other applications do not
  prepare, complete, cancel or otherwise change the application's transfer state.
  An external paste is not treated as an application's transfer Execute.
- Both mechanisms operate on real filesystem items: changing or removing a staged
  source through either mechanism can still cause a later transfer to fail.

## P0: Core Behavior

### Product identity

- The user-facing product name is **KIS Explorer**; the publisher is **SUT**,
  not the product name. Use the product name wherever the application itself
  is named for the user, including the main window, installer UI, Windows
  installed-app listing, Start Menu shortcut, and folder context-menu command
  **KIS Explorer hier öffnen**. Names of Windows components, user files, and
  third-party applications are not product names and remain unchanged.
- The application executable is `KIS Explorer.exe` in Debug and both Release
  profiles. Installer executable names begin with `KIS Explorer` and include
  the profile and version. The default installation folder is
  `%LOCALAPPDATA%\Programs\KIS Explorer`.
- Windows file properties for the application show **KIS Explorer** as the
  product name and file description and **SUT** as the company. Installer
  properties show **KIS Explorer** as the product and **SUT** as the company;
  the installer description may add **Setup**. The application's technical
  `OriginalFilename` and `InternalName` fields retain the internal
  `SUTWinExplorer.dll` name.
- Earlier SUTWinExplorer installations are not migrated or upgraded. Users
  must uninstall them manually before installing KIS Explorer.
  Internal naming and installer identity are defined in
  [SHELL_EXPLORER_ARCHITECTURE.md](SHELL_EXPLORER_ARCHITECTURE.md#2026-11-01-separate-product-name-from-internal-identity).

### Navigation and tabs
- [x] The active profile restores its stored filesystem Pathviews as Fixed tabs;
  `default` is active at startup. Fixed tabs are saved on successful opening and removed from the
  profile on explicit close; unavailable locations remain marked and stored.
  BROWSE stays selected at startup, and virtual **This PC** cannot be pinned.
  The active profile icon and name appear at the left of the top toolbar before
  the navigation buttons; the name uses the same font as the path display.
  Only one KIS Explorer instance runs on the machine. Profile configuration
  and acceptance checks are specified in [Configuration.md](Configuration.md).
- [x] The profile icon toggles between TabsView and ProfilesView. A single
  profile-list selection displays its contents; double-click activates it and
  returns to TabsView with its Fixed tabs. ProfilesView supports creating,
  renaming, and confirmed deletion; it activates a newly created profile and
  falls back to `default` when the active profile is deleted. `default` cannot
  be renamed or deleted. See [ProfilesView.md](ProfilesView.md).
- [x] The application starts with exactly one browsable Pathview in the first
  tab. Its tab title is **BROWSE**, independent of its current location, and it
  cannot be closed.
- [x] Every other tab contains a non-browsable Pathview. The **New tab** toolbar
  command is absent; a fixed Pathview is created with **Pin**.
- [x] **Pin** creates a non-browsable Pathview at the browsable Pathview's
  current location. If that location already has an open non-browsable
  Pathview, **Pin** selects that tab instead of creating a duplicate. **Pin**
  is disabled at the virtual **This PC** location.
- [x] **Browse** on a non-browsable Pathview selects the first tab and navigates
  the browsable Pathview to the fixed Pathview's location.
- [x] Non-browsable Pathviews can be closed; the browsable Pathview remains
  open, so at least one tab is always present.
- [x] The outer browsable and fixed tabs have a font-relative minimum width
  based on sixteen lowercase **n** characters in the tab-title font. The title
  is centered within its own area; the close button, when present, stays compact
  at the far right. This sizing and alignment do not apply to nested Pathview
  tabs.
- [x] The browsable Pathview shows only the **Active path and siblings** tree
  tab. Each non-browsable Pathview shows only the **Active path** tree tab.
- [x] Each Pathview shows its location row across the full width above the
  side-by-side panes. The visible **Browse** or **Pin** button comes first; a
  non-browsable Pathview then shows its bold **FIXED** badge. A pencil button
  before the color picker opens the custom-name dialog. An undefined name
  displays `(Undefined custom name)`; applying an empty name stores `null`.
  Apply saves changes and Cancel or Escape discards them. Opening a Fixed tab
  and applying its name place keyboard focus in its Shell content when
  available. Names are stored in the active profile. The dialog editor uses
  the path display's font and color; only the undefined-name placeholder uses
  a lighter gray.
  The Fixed tab label shows the complete custom name when set; otherwise it
  uses the shortened path. An unavailable path retains its `!` marker.
  The current directory's Shell icon precedes its path expression. At the far
  right, every Pathview has an **Open in Windows Explorer** button beside the
  fixed-view color picker; fixed Pathviews also have the name-edit pencil
  immediately before the picker. The Explorer button opens a new window at
  that Pathview's current path. The browsable Pathview has no FIXED badge,
  name-edit button, or color picker. Below this row, the
  tree pane is on the left and the content pane is on the right; **Hide
  directories** and **Hide internal** appear below the location row in the
  content pane.
- [x] The location-row widgets sit 10 DIP from both outer horizontal edges.
  Its outer row has a 36-DIP minimum height, independent of whether its color
  picker is visible; the widget group uses 2-DIP vertical margins. The
  second-row split area (sidebar, splitter, and content pane) has a 4-DIP white
  inset; the outer tab content has no additional padding.
- [x] Each fixed Pathview's location row starts with a white background unless
  a profile color is saved. Its right-aligned palette offers twelve light colors
  distributed across the spectrum; choosing one changes only that Pathview's
  location row and tab header and saves the color in the active profile. The
  saved color is restored on profile activation and application restart. Until
  a color is chosen, tab headers retain their normal selected or unselected
  appearance. The browsable Pathview has no color-selection button.
  **Browse** and **Pin** remain keyboard-operable without a visible focus ring.
- [x] Each Pathview retains its own location, **Hide directories**, and
  content **Hide internal** settings and sort history when the user switches
  tabs.
- [x] The address field displays the selected tab's path and offers paths from
  open non-browsable tabs in its dropdown; the browsable tab's current path is
  never a dropdown entry. Selecting a dropdown entry selects its associated tab.
  Typing a path selects an existing Pathview at that location, or navigates the
  browsable Pathview if none exists.
- [x] A single Back/Forward history records successfully activated paths across
  browsable and fixed Pathviews, including tab selections. Consecutive
  activations of the same path do not create duplicate entries. Back and
  Forward select an open fixed Pathview for the destination path; otherwise they
  navigate the browsable Pathview. History navigation does not add entries, and
  failed navigation leaves the history unchanged. Up targets and selects the
  browsable Pathview.
- [x] Renaming a folder through the tree or **Sub directories** inline editor
  updates affected Back and Forward history paths, including descendants.
  External renames do not update the history.
- [ ] Renaming a folder in the Shell content view also updates affected history
  paths without treating external renames as internal operations.
- [x] A non-browsable Pathview does not change its own location through its
  tree, **Sub directories** list, or Shell content pane. Single-clicking a
  directory in the **Path** tree or **Sub directories** list, or double-clicking
  one in the Shell content pane, opens it in the browsable Pathview and selects
  its tab. In the Shell content pane, double-clicking a `.lnk` whose target is
  a directory opens the target there. Single clicks in the Shell content pane
  not navigate; other native Shell commands and file operations remain
  available. These directory activations set the browsable Pathview's **Hide
  siblings** to on, its directory-tree **Hide internal** to the fixed
  Pathview's **Sub directories** **Hide internal** value, and its content-item
  **Hide internal** to the fixed Pathview's content **Hide internal** value.
  Activations prefer an already-open fixed Pathview at the destination before
  navigating the browsable Pathview. The **Browse** button uses the same
  activation and filter metadata but always navigates the browsable Pathview.
  Other navigation, including history, does not supply these filter values.
- [x] Navigation in the browsable Pathview updates the address, custom
  directory tree, and its own content view; the tab title remains **BROWSE**.

### Directory trees

**Success-gated active route:** The tree must not commit a requested directory as
active or selected, or programmatically expand the destination route, until the
Shell content view confirms that the directory opened successfully. While
navigation is pending, the last successfully opened directory remains active
and selected. Failure leaves that path and selection unchanged. A tree click
may show its requested row in light gray without changing the active selection.

- [x] **Active path** shows only the route from the drive root to the active
  directory.
- [x] In a non-browsable Pathview, the **Active path** pane places that route
  in a **Path** section sized to its rows. **Path** and **Sub directories**
  remain GroupBox groups with their headers; only their outer frames are
  omitted, and each title is flanked by horizontal rules. The route tree has a
  thin light-gray frame matching the other application-owned trees and lists,
  and no tree scrollbars.
  The remaining pane space shows the active directory's immediate
  subdirectories in a **Sub directories** section with the same header treatment. Its vertically scrolling,
  single-line list has its own very light gray frame, aligned horizontally with
  the **VIEW:** badge above it. The list is inset 16 DIP from the frame on both
  horizontal sides, with an 8-DIP Grid spacer below the filter row; each row
  shows only the folder's Shell icon (including overlays) and name.
  The sections have a visible gap, and each subfolder row matches the tree's
  row height.
- [x] The **Sub directories** list does not provide a persistent, user-managed
  selection or multiple selection like the content table. Hover highlights the
  row under the pointer; pointer actions use the folder clicked or dragged, not
  a previously selected folder. The list may use a temporary selection for an
  operation or keyboard interaction. Entering a row clears the selection, and
  the selection used for an item context menu is cleared when that menu closes.
  An open menu retains its chosen target; prepared transfers retain their own
  source paths and execute into the current directory. With no temporarily
  selected item, keyboard context-menu commands use the background menu.
- [x] The **Active path** tab page insets its two-section layout 8 DIP from
  the tab-page edges. The sidebar tabs leave a 4-DIP gap before the horizontal
  GridSplitter; the surrounding two-pane layout retains its 4-DIP margin.
- [x] The fixed **Active path** pane has a default-on **Hide internal** checkbox
  above its subfolder list. It uses the content pane's internal-item rules but
  filters only that subfolder list; it is independent from the content pane's
  **Hide internal** setting.
- [x] **Active path and siblings** shows the active route and each route node's
  immediate child directories. Off-route branches remain collapsed.
- [x] The browsable tree's filter row and framed tree have matching 4-DIP
  horizontal insets and are separated by an 8-DIP Grid spacer. The frame uses
  the same very light gray as the fixed **Sub directories** list.
- [x] The browsable **Active path and siblings** tree has a single **Top** root
  whose immediate children are the available drives. Its displayed name is
  the localized Shell name for **This PC**, with its Shell icon. Selecting it
  navigates to that Shell location and makes **Top** the active path. When a
  filesystem path expression is shown, omit **This PC** as a path component;
  for example, the path remains `C:\Benutzer\Volker`, not
  `This PC\C:\Benutzer\Volker`.
  A drive root is displayed without a trailing backslash, for example `C:`.
- [x] The browsable **Active path and siblings** tree has a default-on
  **Hide siblings** checkbox before **Hide internal**. When enabled, only the
  active drive is shown under **Top**; along the route, each directory shows only the next
  directory on the active path, while the active directory shows all of its
  immediate subdirectories. **Hide internal** continues to filter those
  displayed directories independently.
- [x] Tree sibling lists and the fixed **Active path** subfolder list are sorted
  lexicographically by Shell-localized display name. The Shell content view
  retains its configured sort column and direction.
- [x] When a filesystem folder's Shell PIDL name is a GUID, use its Shell
  filesystem display name if available, such as **OneDrive**. Displayed path
  components entered in the address field are matched against the parent
  directory's children to recover internal paths; existing filesystem paths
  take precedence. An unresolved GUID can remain visible, and duplicate
  display names do not guarantee an unambiguous match.
- [x] The successfully opened active directory is highlighted, and the visible
  tree brings it near the vertical center after navigation initiated by the tree,
  address field, toolbar history, or Shell content view, when the scroll range
  permits. A requested destination is not selected while navigation is pending;
  failure preserves the last successfully opened directory and its selection.
- [x] The browsable Pathview's default-on **Hide internal** checkbox filters
  its directory tree: names beginning with `.` or `$` are hidden, as are directories that
  have the Windows System attribute and deny directory listing access. Normal
  directories and junctions remain visible. The active route stays visible
  even when a route directory matches a filter rule; the setting does not
  affect the content view.
- [x] A single click anywhere on a directory row, including its disclosure
  triangle, folder icon, or name, requests that directory be opened in the
  browsable Pathview's content view. It becomes active and selected only after
  navigation succeeds. The route expands to reveal it, and the active node is
  selected before its own branch expands. Immediately after a tree click, before the content view
  is asked to navigate, the requested row gets a light-gray highlight distinct
  from the blue selected active path. The request highlight clears on success,
  failure, or superseding navigation. Clicking the triangle of an expanded
  directory collapses its tree branch; if it is active, navigation to its parent
  is requested and the parent becomes active and selected only after success.
  Clicking its icon or name never collapses it. A disclosure triangle is shown only when
  the directory contains immediate subdirectories, including internal and
  directory-link entries. A non-browsable Pathview's tree does not navigate
  its location.
- [x] Expanding a tree node does not trigger navigation during application
  startup or other programmatic tree updates.
- [x] Application-owned tree and list rows use `#E5F3FF` for hover and
  `#CCE8FF` with a 1-pixel `#0078D4` border for selection. These are the
  Windows Explorer colors in Windows 11 as of October 2026. Selection takes
  precedence over hover. An application-specific pending tree request uses
  `#E6E6E6` and takes precedence over hover without replacing the active
  selection. The hosted Shell content view retains its native rendering.

### Content listing

- [x] The content view displays the active directory's files.
- [x] The content pane separates its filter row, directory and selection action rows, and Shell view
  with 8-DIP Grid spacer rows.
- [x] The hosted Shell content view has a very light gray frame matching the
  fixed **Sub directories** list frame. Its left edge aligns with the **VIEW:**
  **FOR DIRECTORY:** and **FOR SELECTED:** badges above it.
- [x] **Hide directories** controls whether directories appear in the content
  view. It defaults to on; unchecking it displays directories, and changing it
  updates the view without navigating.
- [x] The content pane's default-on **Hide internal** checkbox filters files
  and directories whose names begin with `.` or `$`, and System items only
  when reading a file or listing a directory is denied. It is independent from
  both tree/subfolder **Hide internal** checkboxes and updates the Shell view
  without navigating.
- [x] Content visibility filters are independent exclusions: an item is hidden
  if it matches either enabled hide filter, and displayed only if its name
  matches the pattern and it passes both hide filters. A System attribute alone
  does not hide an item; access must also be denied.
- [x] The **Name pattern** editor filters files and directories by Shell display name.
  Blank applies no pattern constraint; `?` matches one character, `*` matches
  zero or more characters, and `.` is literal. Matching is case-insensitive
  and updates the content view as the pattern is edited. If Shell cannot
  provide a display name, matching falls back to the filesystem leaf name.
- [x] Directory junctions and other directory reparse points follow the same
  visibility rule as ordinary directories when the Shell classifies them as
  folders.
- [x] The content view provides a Details layout with Shell-provided names,
  types, sizes, dates, icons, and available overlays.
- [x] Every folder uses the same Details columns. Size is shown in KB.
  Directories precede files; both groups use the same tab-scoped sort history.
  Clicking any column makes it the primary criterion, and a triangle
  indicates its direction. Earlier columns remain as secondary criteria.
- [x] The adjacent private column is headed `MT`, is 16 DIP wide with 8 DIP
  of space to its left, and displays a 16-by-16 DIP media type icon for each
  filesystem item, in Shell view order.
  Directories use the standard folder icon, `.lnk` files use the Shell-link
  icon asset, and conflicting media type assignments use a warning triangle. Other
  extensions are matched case-insensitively against `Assets/media-types.json`;
  unknown extensions are blank. The manually maintained JSON is embedded at
  build time; media type names remain available to accessibility tools.
- [x] The WPF application chrome keeps the app's custom tabs, address field,
  directory trees, and item-count status area.
- [x] Below the two visibility checkboxes, the content pane provides the
  separated action groups **Properties**; **Name clipboard copy**, **Path clipboard copy**, and **Item clipboard copy**; **Item clipboard paste**; **Link mark item**,
  **Link abort**, and **Link execute**; **Copy mark item**,
  **Copy abort**, and **Copy execute**; **Move mark item**, **Move abort**, and **Move execute**;
  **Rename**; and **Delete**. Properties opens the Windows Shell properties
  for one or more loaded selected items. Link, Copy and Move each have an app-owned two-state workflow,
  independent of Shell clipboard state. Their **mark item** buttons stage selected
  filesystem paths; **execute** performs the operation into the active folder;
  **abort** clears the staged paths. Initially, Mark item is enabled when there is a
  selection, while Execute and Abort are disabled. A prepared transfer disables
  the other transfer groups and enables only its own execute and abort actions.
  Successful Execute or Abort returns that workflow to idle. Link creates a Windows
  Shell shortcut for each source, without modifying it; existing names are not
  overwritten. Copy uses native file copy and Move uses native file move.
  **Item clipboard copy** copies selected files and directories to the Windows clipboard;
  **Item clipboard paste** copies supported clipboard filesystem items into the current directory.
  Item clipboard copy is in the selection-row group with Name and Path clipboard copy; Item clipboard paste is in the directory
  column before the Link group and is enabled for a supported clipboard Copy and an
  existing destination directory. Cut, Link-only and missing or ambiguous drop effects
  are rejected. Copy with Link also permitted is accepted but always performs a copy.
  These actions are independent of all prepared transfers. Internal Mark item, Execute
  and Abort do not change the clipboard, and external clipboard operations do not
  change any internal transfer state. Staging records paths only: it does not keep
  file handles, reserve the objects, or lock them against changes by the user,
  another process, or the Shell. Before Execute starts, the app checks that the
  destination is an accessible folder, reads filesystem attributes for every
  staged source, and resolves all Shell items for Copy and Move before beginning the transfer. If
  these preflight checks fail, no transfer is started, an error is shown, and
  the staged workflow remains available. Passing preflight does not prove
  that all file contents are readable or that permissions allow the complete
  operation. The check cannot protect paths after it completes: an object or
  its permissions may change before or during the operation. Such a late
  failure is reported, but a multi-item operation may already have transferred
  some items; Link, Copy and Move are not atomic and do not roll back completed work.
  **Rename** is enabled only for a single loaded item and starts an inline
  rename editor. Enter commits and Escape cancels; invalid names and existing
  target names are reported without overwriting the existing item.
  **Name clipboard copy** and **Path clipboard copy** are enabled when at least one item is selected
  and every selected item is loaded. Name clipboard copy copies filesystem names, including
  file extensions, to the clipboard; Path clipboard copy copies full filesystem paths. Both
  place plain text, not a file list, on the clipboard. With multiple items, the
  text contains one name or path per line in selection order, separated by Windows
  line breaks (CRLF). There is no line break after the last item; a single item
  is copied without any line break. **Delete** remains
  selection-aware; other selection-dependent actions are disabled when nothing
  is selected.
- [x] After the application-owned **New**, **Link execute**, **Copy execute**, or **Move execute**
  inserts items into the current directory, the destination ContentView selects
  all inserted items and scrolls the first into view. It turns off **Hide
  directories** if an inserted item is a directory, turns off **Hide internal**
  if an inserted item is internal, and clears **Name pattern** if any inserted
  item does not match it. Other filters remain unchanged, as do the settings of
  other views. This also applies to items already transferred before a later
  failure. Copy and Move use the destination paths reported by the Shell,
  including names resulting from conflict resolution. The application-owned
  toolbar and paired-menu actions use the same completion; native Windows
  menus and extensions do not use it.

### Link transfer

- [x] **Link mark item** prepares one or more selected files or directories as
  shortcut targets. It is available in the selection row and the Base Menu,
  after **Item clipboard copy** and before **Copy mark item**. A directory can also be prepared
  from its sidebar Base Menu.
- [x] **Link execute** creates one Windows shortcut (`.lnk`) per prepared path
  in the current directory, including when that directory is in another tab.
  The original files and directories remain unchanged. Each shortcut is named
  after its source with ` - Shortcut.lnk` appended; a number is added when
  needed to avoid overwriting an existing item. Created shortcuts are selected
  and brought into view using the normal insertion completion.
- [x] **Link abort** discards the prepared paths without creating shortcuts.
  Execute and Abort are available in the directory column and in the applicable
  Base Menus, including background menus. While Link is prepared, starting
  another transfer and Delete are disabled. External clipboard operations do not
  cancel the prepared Link.
- [x] If a source or destination is unavailable at execution time, the operation
  reports an error and keeps the prepared Link for retry or abort. All sources
  are checked before creation starts; a later failure can nevertheless leave
  already-created shortcuts in place, without rolling them back.

### Selection and opening

- [x] Users can select items and open files with the expected Windows Shell
  behavior. Folder navigation is available only in the browsable Pathview;
  fixed Pathviews retain other native Shell commands and file operations.
- [x] Selection supports multiple items using the standard extended-selection
  behavior for common file operations.
- [x] Refresh preserves selected paths still present in the filtered listing;
  navigation to another location clears the selection.

### Context menus and file operations

- [x] The Base Menu starts with the application-owned **Properties**, followed
  by a separator, **Name clipboard copy**, **Path clipboard copy**, **Item clipboard copy**, another separator, **Item clipboard paste**, and the available Link, Copy and Move
  actions. Shell commands follow, then a separator, **Rename**, another separator,
  and **Delete**. Unavailable transfer actions are
  omitted; other unavailable actions remain visible and disabled. With an
  eligible selection and no prepared transfer, Link mark item, Copy mark item and Move mark item
  are available. A prepared transfer shows its abort and execute actions. The same rules apply to the content and
  sidebar menus and their backgrounds.
- [x] ContentView file and folder selections use the Base and Content Menu pair
  described in [CONTEXT_MENU_SPEC.md](CONTEXT_MENU_SPEC.md).
- [x] ContentView and the Sub directories list support left-button filesystem
  drag-and-drop between each other and compatible external applications. The
  table drags its selection; the list drags only the clicked folder. Directory
  rows target that directory; file rows and empty space target the current
  directory. Copy, Move and Link use Shell effects and modifier keys; right-button
  drags and non-filesystem data are rejected. Tree views do not participate.
  Clipboard and prepared transfers are independent.
- [x] Leaving the system double-click area around the opening point or executing
  a menu command resets the context-menu sequence, even if the pointer returns.
  Pointer movement does not close an open menu; the next normal right-click on
  an item or background starts again with the Base Menu. Shift-right-click and
  keyboard-invoked menus retain their separate native or keyboard behavior.
- [x] For a single `.lnk` selection, **Open parent** in the Content Menu
  opens the parent directory of the shortcut's file or folder target in KIS
  Explorer. For a folder target, it opens the folder's parent, not the target
  folder itself. The same application action replaces the Windows command in the
  Shift item menu. In a fixed Pathview it opens the location in the browsable
  Pathview. Multiple selections disable the action. An unavailable or
  non-filesystem target reports an error without opening Windows Explorer.
- [x] Right-clicking empty content space cycles through the active folder's
  background Base Menu, Content Menu and no menu; Shift opens the native menu.
- [x] The **Active path and siblings** tree uses the directory Base and Content
  Menu pair. The **Path** tree in the **Active path** tab has no context menu. Where
  renaming is available, **Rename** starts an inline editor in the tree; Enter
  commits and Escape cancels. Renamed active paths and open tabs are updated.
- [x] In a fixed Pathview's **Sub directories** list, right-clicking a folder
  shows the directory Base and Content Menu pair; right-clicking empty list space
  cycles through the background pair and no menu. The Apps key and Shift+F10 show
  the selected folder's menu or, when no folder is selected, the background
  menu. Closing a folder's context menu clears the list selection. Where the
  Shell permits renaming, **Rename** starts an inline editor in the list; Enter
  commits and Escape cancels.
- [x] The native menu can execute common commands, including Properties,
  background New, context-menu Copy/Paste, and Paste shortcut as verified in
  the spike.
- [ ] The Apps key and Shift+F10 show the correct menu for the focused item or
  the folder background in the Shell-hosted content view.
- [x] The Shell view supports context-menu clipboard operations and drag/drop
  to and from Windows Explorer, as verified in the spike.
- [x] Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+Z, and Ctrl+A work in the Shell-hosted
  content view. Copy, paste, cut, and undo were verified with disposable files.

### Refresh and failure handling

- [x] Changing **Hide directories** or content **Hide internal** refreshes the
  current content view.
- [x] External changes made by Explorer or another application appear without
  restarting the application.
- [ ] Empty folders, unavailable drives, access failures, and long paths have
  clear and non-crashing user feedback.
- [ ] Long-running operations expose progress, cancellation, and useful
  per-item error reporting where the Shell operation provides them.

## P1: Expected Conveniences

- [x] Rename starts an inline editor for one selected item; Enter commits,
  Escape cancels, and invalid or conflicting names are reported.
- [ ] Delete uses the Recycle Bin by default and supports confirmation and
  recovery behavior where available.
- [ ] Properties, Open with, sharing, and security prompts use their normal
  Windows behavior.
- [ ] Hidden/system visibility and filename-extension display are consistent
  with the application's documented settings.
- [x] Column widths meet the application layout requirement: Name uses the
  remaining width; other selected columns stay at their configured widths.
- [ ] Common keyboard navigation and action shortcuts behave consistently.
- [ ] Folder junctions/reparse points can be navigated without unintended
  recursive traversal.

## P2: Optional Features

- [ ] Thumbnails, previews, and extra details supplied by Shell providers.
- [ ] Virtual Shell locations such as Recycle Bin, Libraries, and provider
  namespaces that are not ordinary filesystem directories.
- [ ] Third-party cloud/version-control overlays and extension-specific
  commands.
- [ ] Persist the user's selected sort across application sessions.

## Acceptance Checks

Product identity: Verify the application window, installer, installed-app
listing, Start Menu shortcut, and folder context menu use **KIS Explorer**, and
the publisher is **SUT**. Check the Debug executable and both published
executables are named `KIS Explorer.exe`, and check their Windows file
properties, including the retained internal-name fields. Uninstall any old
SUTWinExplorer installation before testing a new installation.

1. With **Hide directories** on, ordinary folders and directory reparse points
  are absent from the content view; unchecking it displays them, and checking
  it hides them again without changing the active path.
2. Navigate the browsable Pathview using its tree, address field, Shell content
  view, and toolbar history. Verify its address, title, tree, and content stay
  synchronized. In a non-browsable Pathview, verify single-clicking a directory
  in the **Path** tree or **Sub directories** list, or double-clicking one in
  the Shell content view, selects the browsable tab and opens the directory
  there without changing the fixed Pathview's location. Verify
  double-clicking a `.lnk` to a directory in the Shell content view opens its
  target in the browsable Pathview.
3. Verify the browsable Pathview's current path is shown in the address field
  but is not offered in its dropdown. Use **Pin** repeatedly at one location
  and type that location into the address field. Verify the existing
  non-browsable tab is selected instead of creating a duplicate. Use a
  dropdown entry to select its associated tab. Activate several browsable and
  fixed paths, then use Back and Forward to traverse them in order. Verify an
  open fixed path selects its tab, a path without a fixed tab opens in BROWSE,
  repeated activation of the same path adds no duplicate, and a new activation
  after Back clears Forward.
4. Open fixed Pathviews at different locations and verify the **Active path**
  tree shows the complete route without a scrollbar and only uses the height
  required for its rows. Verify the remaining pane space shows the active
  folder's immediate subdirectories with Shell icons and overlays, and that
  long lists scroll independently. Verify switching tabs restores each
  location and its **Hide directories** and content **Hide internal** settings.
5. Use item and folder-background menus for Properties, New Text Document,
   Copy/Paste, Paste shortcut, and drag/drop with Windows Explorer.
6. Verify cancellation, name collisions, access denied, and disconnected
  destinations do not crash the application. If folder navigation fails, the
  active path, address, tab title, trees, and history remain on the last
  successfully displayed folder.
7. Select several sort columns in succession and verify their priority, then
  navigate and switch tabs. Verify each tab retains its own sort history and
  that directories remain before files in either direction.
8. In the browsable Pathview, toggle **Hide internal** and verify dot-prefixed
  and dollar-prefixed directories disappear and reappear, and a System
  directory is hidden only when listing its contents is denied. Verify normal
  junctions remain visible, the active route remains visible, and the content
  view is unchanged.
9. In the browsable Pathview, toggle **Hide siblings**. Verify that only the
  active drive remains visible, only the active route is shown before the
  current directory, and all immediate subdirectories of the current directory
  remain visible. At a drive root, verify all of that drive's directories are
  shown and other drives are hidden. Turn the option off and verify the full
  drive list and sibling branches return. Verify **Hide internal** continues
  to filter directories independently.
10. Toggle the content pane's **Hide internal** independently of the tree
  checkbox. Verify dot-prefixed and dollar-prefixed files and directories are
  hidden, System files disappear only when reading them is denied, and System
  directories disappear only when listing them is denied. Verify normal
  junctions remain visible and **Hide directories** still controls directory
  visibility independently.
11. Enter patterns such as `*.txt`, `file?.dat`, and `*.*`. Verify matching is
  case-insensitive, `?` matches exactly one character, `*` matches zero or more
  characters, `.` is literal, and a blank pattern removes only the pattern
  constraint. Verify both files and directories are filtered without
  navigation.
11. Select multiple files and directories and use **Link mark item**. Verify Link
  execute and Link abort become enabled and the other transfer actions are
  disabled. Execute in another tab and verify that each `.lnk` points to its
  original source, existing items are not overwritten, and the sources remain
  unchanged. Repeat with Link abort and with a source removed before execution.
  Select multiple items and use **Copy mark item**. Verify Copy execute and Copy
  abort become enabled, Copy mark item becomes disabled, and all Move buttons remain
  disabled. Verify the clipboard is unchanged. Use Copy execute and verify the items are copied into the active
  folder without changing Shell clipboard state. Repeat and use Copy abort;
  verify the source items remain unchanged. Also stage a Copy, remove or rename
  one source before Execute, and verify preflight reports an error,
  starts no transfer, and preserves the staged workflow. Confirm staging does
  not prevent another process from changing a source path.
12. Use **Move mark item** and verify the Copy group becomes disabled while Move
  execute/abort become enabled. Use Move execute and verify the sources move into
  the active folder without changing Shell clipboard state. Repeat and use
  Move abort; verify the source items remain in place. Select one item and
  verify **Name clipboard copy** copies its filesystem name and **Path clipboard copy** its path.
  Repeat with multiple files and directories and verify one text line per item;
  verify both buttons are disabled when nothing is selected.
  Also stage a Move, remove
  or rename one source before Execute, and verify preflight reports an
  error, starts no transfer, and preserves the staged workflow. A change after
  preflight may still cause a late failure; multi-item Execute is not atomic and
  may leave already-transferred items in place.
  For New, Link execute, Copy execute and Move execute, verify inserted items are selected, the
  first is scrolled into view, and only filters hiding an inserted item are
  reset. Include a directory, an internal item, a nonmatching name, multiple
  items, and an execute from a paired directory menu. Verify unaffected filters
  and other views retain their settings; test partial transfers and Shell
  conflict decisions where available.
13. Select exactly one item and click **Rename** or press F2. Verify the inline
  editor opens with its filesystem name, Enter commits a valid name, Escape
  cancels without changing it, and a collision is reported without overwriting
  the target. Verify Rename is disabled with no selection or multiple selected
  items and that the renamed item remains selected after refresh.