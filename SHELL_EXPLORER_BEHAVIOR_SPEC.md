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
view.

## P0: Core Behavior

### Navigation and tabs
- [x] Each application tab retains its own active folder.
- [x] Switching tabs restores that tab's location.
- [x] Exactly one tab contains a browsable Pathview; it is always first. Every
  other tab contains a non-browsable Pathview.
- [x] **Fix** on the browsable Pathview creates and selects a non-browsable
  Pathview at the same location.
- [x] **Browse** on a non-browsable Pathview navigates the browsable Pathview to
  that location and selects the first tab.
- [x] A non-browsable Pathview does not change location from its tree or from
  folder activation in its Shell content pane. This blocks folder navigation
  only; other native Shell commands and operations remain available.
- [x] Typed address navigation and Back, Forward, and Up target the browsable
  Pathview; choosing a path from the address dropdown selects that path's tab.
- [x] The address field accepts typed filesystem paths and offers the paths
  currently open in tabs.
- [x] Back, Forward, and Up navigate within the active tab.
- [x] The user can create and close tabs; at least one tab remains open.
- [x] Opening a folder from the content view navigates within the active tab.
- [x] Navigation initiated from the content view updates the address, tab title,
  and custom directory trees.

### Directory trees

- [x] **Active path** shows only the route from the drive root to the active
  directory.
- [x] **Active path and siblings** shows the active route and each route node's
  immediate child directories. Off-route branches remain collapsed.
- [x] The active directory is highlighted, and both trees follow navigation
  initiated elsewhere in the application.
- [x] Single-click navigation opens the clicked directory in the content view.
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

- [x] Users can select items and open folders or files with the expected
  Windows Shell behavior.
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
2. Navigate using either custom tree, the address field, the Shell content
   view, and the tab-path dropdown; all paths, titles, and trees stay in sync.
3. Open two tabs at different paths and verify switching tabs restores each
   location independently.
4. Use item and folder-background menus for Properties, New Text Document,
   Copy/Paste, Paste shortcut, and drag/drop with Windows Explorer.
5. Verify cancellation, name collisions, access denied, and disconnected
  destinations do not crash the application. If folder navigation fails, the
  active path, address, tab title, trees, and history remain on the last
  successfully displayed folder.
6. Navigate between folders with different saved view modes, groups, columns,
  and sort choices. Verify the content view always uses the standard ungrouped
  Details layout and column order, while retaining each folder's selected
  sort column and direction.