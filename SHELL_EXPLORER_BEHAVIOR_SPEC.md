# Shell Explorer Behavior Specification

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
tab-scoped; sort parameters continue to follow the active folder's configured
view. A Pathview is either browsable or non-browsable; that role is assigned
when it is created and cannot be changed by the user.

## P0: Core Behavior

### Navigation and tabs
- [x] The application starts with exactly one browsable Pathview in the first
  tab. Its tab title is **BROWSE**, independent of its current location, and it
  cannot be closed.
- [x] Every other tab contains a non-browsable Pathview. The **New tab** toolbar
  command is absent; a fixed Pathview is created with **Pin**.
- [x] **Pin** creates a non-browsable Pathview at the browsable Pathview's
  current location. If that location already has an open non-browsable
  Pathview, **Pin** selects that tab instead of creating a duplicate.
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
  non-browsable Pathview then shows its bold **FIXED** badge, and the path is
  always last. The browsable Pathview has no badge. Below this row, the tree
  pane is on the left and the content pane is on the right; **Hide directories**
  and **Hide internal** appear below the location row in the content pane.
- [x] The location-row widgets sit 10 DIP from both outer horizontal edges.
  Its outer row has a 36-DIP minimum height, independent of whether its color
  picker is visible; the widget group uses 2-DIP vertical margins. The
  second-row split area (sidebar, splitter, and content pane) has a 4-DIP white
  inset; the outer tab content has no additional padding.
- [x] Each fixed Pathview's location row starts with a white background. Its
  right-aligned palette offers twelve light colors distributed across the
  spectrum; choosing one changes only that Pathview's location row and tab
  header. Until a color is chosen, tab headers retain their normal selected or
  unselected appearance. The browsable Pathview has no color-selection button.
  **Browse** and **Pin** remain keyboard-operable without a visible focus ring.
- [x] Each Pathview retains its own location, **Hide directories**, and
  content **Hide internal** settings
  when the user switches tabs. Sort parameters continue to follow the active
  folder's configured view.
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
- [x] Navigation in the browsable Pathview updates the address, tab title,
  custom directory tree, and its own content view.

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
  in a gray-framed **Path** section sized to its rows, with no tree scrollbars.
  The remaining pane space shows the active directory's immediate
  subdirectories in a gray-framed **Sub directories** section. Its vertically scrolling,
  single-line list has its own black frame and is inset horizontally by 10 px;
  each row shows only the folder's Shell icon (including overlays) and name.
  The sections have a visible gap, and each subfolder row matches the tree's
  row height.
- [x] The fixed **Active path** pane has a default-on **Hide internal** checkbox
  above its subfolder list. It uses the content pane's internal-item rules but
  filters only that subfolder list; it is independent from the content pane's
  **Hide internal** setting.
- [x] **Active path and siblings** shows the active route and each route node's
  immediate child directories. Off-route branches remain collapsed.
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

### Content listing

- [x] The content view displays the active directory's files.
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
- [x] Every folder uses the same ungrouped Details layout and Name, Type, Size,
  Date modified columns in that order. Size is shown in KB. The active sort
  column and direction come from the folder's configured view; other
  folder-specific view settings are ignored.
- [x] The WPF application chrome keeps the app's custom tabs, address field,
  directory trees, and item-count status area.
- [x] Below the two visibility checkboxes, the content pane provides five
  separated action groups: **Rename**; **Path get**; **Copy get**, **Copy abort**,
  and **Copy paste**; **Move get**, **Move abort**, and **Move paste**; and
  **Delete**. Copy and Move each have an app-owned two-state workflow,
  independent of Shell clipboard state. Their **get** buttons stage selected
  filesystem paths; **paste** performs the operation into the active folder;
  **abort** clears the staged paths. Initially, Get is enabled when there is a
  selection, while Paste and Abort are disabled. A prepared Copy disables all
  Move buttons and enables only Copy paste/abort in its group. A prepared Move
  disables all Copy buttons and enables only Move paste/abort in its group.
  Paste or Abort returns that workflow to idle. Copy uses native file copy and
  Move uses native file move; neither workflow reads or writes Shell clipboard
  state. As an optional integration, toolbar **Copy get** also invokes the
  Shell Copy verb, and an external Shell Copy stages its file paths through the
  same Copy get transition. Shell Cut and unrelated clipboard contents do not
  affect the internal workflows. Staging records paths only: it does not keep
  file handles, reserve the objects, or lock them against changes by the user,
  another process, or the Shell. Before Paste starts, the app checks that the
  destination is an accessible folder, reads filesystem attributes for every
  staged source, and resolves all sources before beginning the transfer. If
  these preflight checks fail, no transfer is started, an error is shown, and
  the staged workflow remains available. Passing preflight does not prove
  that all file contents are readable or that permissions allow the complete
  operation. The check cannot protect paths after it completes: an object or
  its permissions may change before or during the operation. Such a late
  failure is reported, but a multi-item operation may already have transferred
  some items; Copy and Move are not atomic and do not roll back completed work.
  **Rename** is enabled only for a single selected item and starts the Shell
  view's inline rename editor. Enter commits and Escape cancels; name
  validation, extension handling, and collision behavior remain Shell-owned.
  **Path get** is enabled only for a single selected item and copies that
  item's filesystem path to the clipboard. **Delete** remains selection-aware;
  other selection-dependent actions are disabled when nothing is selected.

### Selection and opening

- [x] Users can select items and open files with the expected Windows Shell
  behavior. Folder navigation is available only in the browsable Pathview;
  fixed Pathviews retain other native Shell commands and file operations.
- [ ] Selection supports the expected multi-select and keyboard-focus behavior
  for common file operations.
- [ ] Selection remains predictable when the content view refreshes or
  navigation completes.

### Context menus and file operations

- [x] Right-clicking a file/folder shows its native Windows Shell context menu.
- [x] Right-clicking empty content space shows the active folder's native
  background menu.
- [x] Tree folders show their native Shell context menu. Where the Shell permits
  renaming, **Rename** starts an inline editor in the tree; Enter commits and
  Escape cancels. Renamed active paths and open tabs are updated.
- [x] In a fixed Pathview's **Sub directories** list, right-clicking a folder
  shows its native Shell context menu; right-clicking empty list space shows
  the active folder's native background menu. The Apps key and Shift+F10 show
  the selected folder's menu or, when no folder is selected, the background
  menu. Where the Shell permits renaming, **Rename** starts an inline editor
  in the list; Enter commits and Escape cancels.
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

- [x] Rename starts the native Shell inline editor for one selected item;
  commit, cancel, validation, and name-collision behavior remain Shell-owned.
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
7. Navigate between folders with different saved view modes, groups, columns,
  and sort choices. Verify the content view always uses the standard ungrouped
  Details layout and column order, while retaining each folder's selected
  sort column and direction.
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
11. Select multiple items and use **Copy get**. Verify Copy paste and Copy
  abort become enabled, Copy get becomes disabled, and all Move buttons remain
  disabled. Use Copy paste and verify the items are copied into the active
  folder without changing Shell clipboard state. Repeat and use Copy abort;
  verify the source items remain unchanged. Also stage a Copy, remove or rename
  one source before Paste, and verify preflight reports an error,
  starts no transfer, and preserves the staged workflow. Confirm staging does
  not prevent another process from changing a source path.
12. Use **Move get** and verify the Copy group becomes disabled while Move
  paste/abort become enabled. Use Move paste and verify the sources move into
  the active folder without changing Shell clipboard state. Repeat and use
  Move abort; verify the source items remain in place. Select one item and
  verify **Path get** copies its filesystem path; verify the button is disabled
  for no selection or multiple selected items. Also stage a Move, remove
  or rename one source before Paste, and verify preflight reports an
  error, starts no transfer, and preserves the staged workflow. A change after
  preflight may still cause a late failure; multi-item Paste is not atomic and
  may leave already-transferred items in place.
13. Select exactly one item and click **Rename**. Verify the Shell inline editor
  opens, Enter commits a valid name, Escape cancels without changing it, and
  an existing-name collision is handled by the Shell. Verify Rename is disabled
  with no selection or multiple selected items.