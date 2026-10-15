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
state when the user switches tabs. For example, **Show directories** is
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
- [x] The browsable Pathview shows only the **Active path and siblings** tree
  tab. Each non-browsable Pathview shows only the **Active path** tree tab.
- [x] A non-browsable Pathview shows a bold **FIXED** badge before its path and
  a **Browse** button immediately after it. The browsable Pathview shows its
  path followed by **Pin**, with no badge. **Show directories** is below this
  title row.
- [x] Each Pathview retains its own location and **Show directories** setting
  when the user switches tabs. Sort parameters continue to follow the active
  folder's configured view.
- [x] The address field offers paths currently open in tabs. Selecting a
  dropdown entry selects its associated tab. Typing a path selects an existing
  Pathview at that location, or navigates the browsable Pathview if none exists.
- [x] Back, Forward, and Up always target the browsable Pathview and select its
  tab.
- [x] A non-browsable Pathview does not change location through its tree or
  folder activation in its Shell content pane. This blocks folder navigation
  only; other native Shell commands and file operations remain available.
- [x] Navigation in the browsable Pathview updates the address, tab title,
  custom directory tree, and its own content view.

### Directory trees

- [x] **Active path** shows only the route from the drive root to the active
  directory.
- [x] **Active path and siblings** shows the active route and each route node's
  immediate child directories. Off-route branches remain collapsed.
- [x] The active directory is highlighted, and the visible tree follows
  navigation initiated elsewhere in the application.
- [x] The browsable Pathview's default-off **Hide internal** checkbox filters
  its directory tree: names beginning with `.` or `$` are hidden, as are directories that
  have the Windows System attribute and deny directory listing access. Normal
  directories and junctions remain visible. The active route stays visible
  even when a route directory matches a filter rule; the setting does not
  affect the content view.
- [x] In the browsable Pathview, single-click navigation opens the clicked
  directory in the content view. A non-browsable Pathview's tree does not
  navigate its location.
- [x] Expanding a tree node does not trigger navigation during application
  startup or other programmatic tree updates.

### Content listing

- [x] The content view displays the active directory's files.
- [x] **Show directories** controls whether directories appear in the content
  view. It defaults to off; changing it updates the view without navigating.
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
- [x] Tree folders show their native Shell context menu.
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

- [x] Changing **Show directories** refreshes the current content view.
- [x] External changes made by Explorer or another application appear without
  restarting the application.
- [ ] Empty folders, unavailable drives, access failures, and long paths have
  clear and non-crashing user feedback.
- [ ] Long-running operations expose progress, cancellation, and useful
  per-item error reporting where the Shell operation provides them.

## P1: Expected Conveniences

- [ ] Rename follows Shell extension and name-collision behavior.
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

1. With **Show directories** off, ordinary folders and directory reparse points
   are absent from the content view; switching it on displays them, and
   switching it off hides them again without changing the active path.
2. Navigate the browsable Pathview using its tree, address field, Shell content
  view, and toolbar history. Verify its address, title, tree, and content stay
  synchronized. Verify folder navigation attempts from a non-browsable tree or
  Shell content view do not change that Pathview's location.
3. Use **Pin** repeatedly at one location and type that location into the
  address field. Verify the existing non-browsable tab is selected instead of
  creating a duplicate. Use a dropdown entry to select its associated tab.
4. Open fixed Pathviews at different locations and verify switching tabs
  restores each location and its **Show directories** setting.
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