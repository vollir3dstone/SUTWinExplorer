# File and Directory Context Menu Pair

## Scope and Intent

ContentView provides a Base Menu (Basismenü) and a Content Menu (Inhaltsmenü)
for a selection of existing files and/or directories and for the current
directory's background throughout the Pathview. The same menu pair is available
for filesystem directories in the **Active path and siblings** tree and the
**Sub directories** list in **Active path**. The Base Menu puts the
application's common file operations first and includes generally applicable
Shell commands. The Content Menu provides the remaining item-specific Shell
commands. Windows constructs and invokes the Shell portions of both menus; KIS
Explorer filters the resulting menus instead of reconstructing extension
handlers itself.

Design principle: The Content Menu for an eligible active-directory background
and the Content Menu for an eligible directory item should look and behave the
same. Their only intended difference is the target directory: the background
means the active directory, and the item means the clicked directory. This is a
design goal, not a claim that the current menus are identical: Windows supplies
different item and background Shell commands, and the current layouts below
describe those differences. Native Shift menus retain their own behavior.

The Base Menu may also be called the Generic menu or FileOp menu. The Content
Menu may also be called the Special menu. Older code and documentation used
generic and special as the menu names.

The distinction is loosely inspired by blackbox and whitebox actions. A
blackbox action treats the file as an object without needing to know its
contents, as with common file operations in the Base Menu. A whitebox action
depends on the file's contents or kind, as with content-specific actions in the
Content Menu. This is a useful mental model, not a strict classification: Shell
extensions in the Base Menu can include content-dependent actions, and actions
in the Content Menu may depend only on the file type rather than inspecting its
contents. The menus are not filtered by whether a command reads file contents.

This specification describes the implemented behavior, not a promise that every
installed extension or every Windows 11 compact-menu command is available. The
separate [diagnostic spike](CONTEXT_MENU_SPIKE.md) retains the investigations,
including unsuccessful approaches and machine-specific observations. The main
implementation is in [ContentView.xaml.cs](ContentView.xaml.cs),
[ExplorerTabView.xaml.cs](ExplorerTabView.xaml.cs),
[SutContextMenuController.cs](SutContextMenuController.cs) and
[SutContextMenuFactory.cs](SutContextMenuFactory.cs), with popup handling in
[SutContextMenu.cs](SutContextMenu.cs).

## Responsibilities and Lifetime

### View and Controller

ContentView owns a `SutContextMenuController<DirectoryRow>` for its item menus
and for the **active directory context-menu sequence** shared by all eligible
background surfaces in its Pathview. The **Active path and siblings** tree and
the **Sub directories** list each have a separate
`SutContextMenuController<TreeEntry>` for their directory items. Each Pathview
has its own controllers and sequence state; sidebar item series are not the
background series. The view constructs and calls the controller;
the controller is therefore the view's integration point, not an implementation
detail hidden from the view. The existing views do not call
`SutContextMenuFactory` or use `SutContextMenu` directly for the paired menus.
All three classes are `internal` to the application, not public APIs. The
factory and menu instance are separate internal collaborators, not nested or
private classes belonging exclusively to the controller.

The view supplies these callbacks when constructing the controller:

- Resolve a target to its filesystem path and return the current selected paths.
- Hit-test screen coordinates against the widget, distinguishing an item from
  its background, and select a target or clear the selection when requested.
- Supply the target-specific `ShellMenuAction` entries, each with a stable
  internal ID, independently localizable label, enabled state and application
  callback. The view owns their behavior. Native command IDs identify entries
  within a menu and are not derived from their displayed labels.
- Supply the current background directory and its application actions when no
  item is targeted.
- Show the native item or background menu when the controller requests a
  fallback. The ContentView item callback replaces Open file location for `.lnk`
  selections; it receives the target and current selected paths.

The view remains responsible for its own input events, initial selection and
navigation. It calls `Show(target, owner, alternate)` with the owner window
handle; `alternate` enables the mouse-driven Base/Content/no-menu sequence. It calls
`Reset()` when a selection or navigation change invalidates that sequence.
`IsDifferentTarget(target)` lets a view distinguish a new target from the
remembered Base Menu target when applying its selection rules. The controller
owns the sequence, rechecks selection after each menu closes, and requests
hit-testing, selection changes and fallbacks through the supplied callbacks.

### Factory and Menu Instance

`SutContextMenuFactory` creates menus and applies the Shell registration and
filtering rules. The controller supplies paths, owner, actions or a Base Menu
snapshot, and whether the context is the background. The factory chooses and
creates the appropriate item or background menu; the controller does not
classify files, directories, mixed selections or Shell commands. The factory
also creates native item and background
menus. Paths in a multiple selection must share a parent directory. For the
paired menus the controller calls the factory and owns the returned instances;
for native item and background menus, `SutShell` also calls the factory and
provides the display wrappers used by the views. Thus the factory is not solely
a helper for the controller, although paired-menu views need not know it.

Each returned `SutContextMenu` owns one native menu and its Shell resources.
It displays the popup, forwards native menu messages and selected commands, and
delegates application actions to callbacks supplied by the widget. It does not
define those actions or the factory's menu composition rules. A factory callback
applies the exclusion rules again when the Shell populates a submenu lazily.
The caller disposes each instance after showing it; creation and display run on
the UI STA thread. The view supplies action callbacks but does not manage the
paired menu's native resources.

`SutContextMenuController<T>` owns the three-step menu sequence and selection
validation separately for each participating widget and Pathview. The Base Menu
captures comparable commands after the popup closes and before a selected command
is invoked, including submenus populated during display. The controller retains
that managed snapshot, disposes the Base Menu and creates the Content Menu only
when needed. It never transfers native
handles or command IDs between menu instances. Native Shell view commands and
item renaming are handled separately from the factory.

For a mouse-driven series, `MenuSequenceMouseMonitor` installs a temporary
Windows low-level mouse hook at the Base Menu's opening cursor position. It
compares movement with half of each system double-click dimension; exceeding
either bound invalidates the series immediately, without consuming the event or
closing a popup. The hook remains active across the Content Menu and pending
no-menu step, and is removed on invalidation, reset, command completion, native
fallback, or view unload. Only one monitor is active at a time; starting another
invalidates the previous series. The controller tracks movement separately from
selection changes so a right-click received by an open popup after movement
starts a fresh series at the hit-tested item or background. `SutContextMenu`
records whether a command was selected before invoking it; the controller
resets the series after the popup returns. Failures also reset the controller.
Keyboard-invoked and native fallback menus do not start a mouse-driven series.

## Menu Map

The following describes the custom WPF Pathview, not an independently hosted
Windows Shell view. A menu pair is a Base Menu followed by a Content Menu, then
one right-click with no menu. The complete layouts and filters are specified
below; Shell and extension entries depend on the machine and target.

| Target or surface | Normal right-click | Shift-right-click | Keyboard |
| --- | --- | --- | --- |
| ContentView file or directory row | Item pair for the selected rows | Native item menu; `.lnk` Open file location is replaced | Apps or Shift+F10 uses the selected item; with no selection it uses the background target. Shift invokes the native menu. |
| Eligible Pathview background, including empty table space | Shared active directory context-menu sequence | Native Windows background menu | ContentView Apps with no selection opens the background Base Menu; Shift+F10 opens the native background menu. |
| **Active path and siblings** directory item | Directory item pair for the clicked directory | Native item menu | Uses the widget's applicable item behavior. |
| **Sub directories** directory item | Directory item pair for the clicked directory | Native item menu | Apps opens the item Base Menu; Shift+F10 opens its native item menu. |
| Empty tree or Sub directories area | No background menu | No background menu | Sub directories without a selected item opens no menu. |
| **Path** tree in **Active path** | No context menu, including its items | No context menu | No application item or background menu. |

### Common Base Menu Layout

From top to bottom the application inserts the following blocks; redundant
separators are removed when the Shell section is empty:

```text
Properties
---
Prepare copying
Prepare linking
Prepare moving
---
Copy name to clipboard
Copy path to clipboard
Copy item to clipboard
---
Abort transfer
Mark link item
Mark copy item
Mark move item
---
[filtered Shell commands, possibly none]
---
Rename
Relocate
---
Delete
```

These application entries stay visible when unavailable and are disabled.
`Abort transfer` is enabled only while a Link, Copy or Move is prepared;
marking another transfer is disabled while one is prepared. The Base Menu does
not include clipboard Paste or the transfer execute actions. Item actions use
the selected ContentView rows or the clicked sidebar directory; background
actions use the active directory, regardless of the previous table selection.
The exact Shell block varies by selection, registrations and extensions.
The three Prepare actions replace the global Shell clipboard with the selected
filesystem items, the clicked directory, or the active directory for a background.
Copy and Move use the Shell Copy and Cut verbs; Link requests the explicit Shell
Link effect. Preparing does not execute a transfer or change the application's
prepared transfers. External destinations must support the requested Link effect;
in Windows Explorer, `Paste shortcut` is available for this effect and creates a
shortcut to the source.
When an external destination reports a completed Link prepared by KIS Explorer,
the application clears the unchanged prepared clipboard object, causing the
clipboard actions to update. This intentionally makes that preparation one-shot,
even though the tested Explorer leaves Link data available for repeated shortcut
creation. A late report cannot clear a replacement clipboard; destinations that
do not report completion cannot trigger this update. The tested Explorer clears
its Shell Cut clipboard after Move. Details and limitations are in
[Completion of external operations](SHELL_EXPLORER_BEHAVIOR_SPEC.md#completion-of-external-operations).

`Prepare copying` and `Copy item to clipboard` deliberately appear as
two entries in different groups. Both invoke the same Shell Copy verb; the former
is presented as the start of an external transfer, while the latter is presented
with the clipboard actions and also has a toolbar button. Neither limits where
the resulting clipboard data can be pasted. For details and availability, see
[Clipboard actions and transfer functions](SHELL_EXPLORER_BEHAVIOR_SPEC.md#clipboard-actions-and-transfer-functions).

### Content Menu Layouts

The Content Menu starts with the normal Shell menu for its target, removes
the applicable excluded and uniquely matched Base Menu commands, and adds
application actions where appropriate:

| Context | Application additions and ordering |
| --- | --- |
| ContentView item selection | Shell `Open`, `Open in running app...`, Shell `Open with`, then remaining eligible Shell entries. Clipboard paste and prepared transfer actions for a directory precede this group when available. Missing Shell Open/Open with commands have disabled placeholders. The running-app submenu is built for the selection and available windows; it is disabled when no eligible window exists or a directory is selected. |
| Directory item | Supported clipboard data adds its Copy, Move or explicit Link action first; Move and Link are preceded by their clipboard Abort action. A separator follows. A prepared transfer adds `Abort transfer` and the matching execute command before the remaining menu. The clicked directory is the destination. This applies to directory rows and sidebar directory items. |
| Active directory background | The same clipboard paste and prepared transfer actions appear in the same order, targeting the active directory. The filtered Shell background commands include application-owned `New` in place of Windows New. |
| Selection containing a `.lnk` | Application `Open parent` replaces Shell Open file location, or is appended when Windows does not supply it; it is enabled only for one selected item. |

The execute command is `Insert link to marked item`, `Insert copy of marked
item`, or `Move marked item here`, according to the prepared workflow. The
Content Menu does not have a fixed complete list: Windows and installed Shell
extensions supply entries, including submenus that may be populated lazily.
The [running-app specification](OPEN_WITH_RUNNING_APP_SPEC.md) and
[ContentView New documentation](CONTENT_VIEW.md) describe their dynamic details.

## Selection and Menu Sequence

ContentView uses the following selection rules:

- On an initial right-click, an unselected row becomes the sole selection; a
  selected row preserves an existing multiple selection.
- A file, directory or mixed selection opens the Base Menu first. The clicked
  row's full path identifies the menu series, and the complete selection is
  retained.
- Repeated right-clicks on the same row cycle through Base Menu, Content Menu,
  and no menu for the same selection, then start again with the Base Menu.
  This also works while a popup is open and the pointer remains at its opening
  position: the third click closes the Content Menu without opening another.
- A right-click on another row while the Base Menu is open ends the series and
  makes that row the sole selection, even if it was already part of a multiple
  selection. A file or directory starts a new Base Menu.
- A selection or target change invalidates the remembered sequence, including a
  pending no-menu step, and its command snapshot. While the Base Menu popup is
  open, a selection change also prevents using a stale snapshot to open a
  Content Menu.
- Moving the pointer outside the system double-click rectangle around the
  opening point resets the sequence, even if it later returns to that area.
  The current popup stays open; the next right-click on an item or background
  starts a new Base Menu. This also applies while either popup is open or the
  no-menu step is pending. Executing a menu command resets the sequence as well.
- A right-click on the table background or other non-interactive Pathview
  background clears the ContentView selection and starts or advances the same
  Base/Content/no-menu series for the current directory. Labels and icons count
  as background; active controls, tree views and the Sub directories list do not.
  Switching between an item and the background starts a new series. List chrome
  such as headers and scrollbars is not treated as an item or background. Clicks
  outside the owner are not consumed as menu-series clicks.
- Shift-right-click on an item uses the Windows item menu, including
  on the same row while either popup is open. It preserves the current selection;
  on another row while the Base Menu is open it selects only that row. The
  modifier is taken from the mouse message, even if Shift is released before the
  new menu opens. Shift-right-click on the background uses the original Windows
  background menu, including its view commands.
  For `.lnk` selections, the item menu replaces Open file location with the
  application action described below.
  The keyboard context-menu key or Shift+F10 opens the applicable menu without
  starting a mouse-driven alternation series.

The two sidebar widgets use the same menu series for the clicked directory,
with independent controller state per widget and Pathview. Each has a single
target rather than ContentView's multiple selection. Selecting a different
tree target or navigating resets the corresponding series. The Sub directories
list has no persistent, user-managed selection like ContentView: hover highlights
the row under the pointer, and a right-click targets the clicked folder. A
temporary selection may be used for the menu or keyboard interaction; entering a
row clears it, and the item menu's selection is cleared after the menu closes.
An open menu retains its target even if the pointer moves. Prepared transfers
retain their own source paths and execute into the current directory, rather
than using the hovered folder as their source or destination. The list preserves
the menu series for a subsequent right-click on the same folder. Tree views and
the Sub directories list do not have background menus; the **Path** tree in the **Active path** tab has no
context menu. Virtual or unavailable sidebar targets fall back to the
native item menu. Shift-right-click uses that native menu; in the Sub directories
list the Apps key opens the applicable item menu and Shift+F10 the native menu.
With no selected sidebar item these keyboard commands open no menu.

Both popups are tracked using a thread-local Windows menu message filter. For a
right-button-down or right-button-double-click message, its screen coordinates
are hit-tested against the originating widget. A handled click closes the current
popup before another menu is opened, so each Shell menu and its COM objects have
separate lifetimes. Ordinarily a click on the popup itself remains a popup click.
A right-click within the system double-click rectangle around the opening point
is also accepted as a hit on the underlying list, even after the double-click
time has elapsed, provided the window is the active popup on the same thread.
This allows another click without moving the pointer when the popup covers the
original row. Menu commands in either popup can be invoked with the left mouse
button or the keyboard, but not with the right mouse button.

## Background Menus

### Background Scope and Routing

Background means an eligible non-interactive surface of the current Pathview,
not an item and not necessarily a blank part of the table. Empty ContentView
table space, free Pathview surfaces, labels and non-interactive icons all route
to the **same active directory context-menu sequence** owned by ContentView.
For example, opening the Base Menu on the location label and repeating the
right-click at another eligible background point advances the same series,
provided the normal pointer-movement and target rules have not reset it.
Different Pathviews have independent series and active directories.

The table's rows keep their item menus. Its column headers and scrollbars are
list chrome, not background. The two tree areas and the Sub directories list,
including their framed margins and empty space, are excluded; their directory
item menus are unchanged. Buttons, editors, other recognized controls and
widgets are excluded even when disabled. Thus clicking an excluded surface
does not itself request a background menu or clear the table selection.

Every accepted background request clears the ContentView table selection,
including a request outside the table, a native Shift fallback and a pending
no-menu step. The target is `CurrentPath`, not the old selection. Clearing the
table selection does not clear a prepared transfer: its stored source paths
remain available until execution or abort. Item menus keep their own selection
and target rules.

Pathview handles eligible right-clicks at its root and calls ContentView's
background entry point. The controller also asks Pathview to hit-test screen
coordinates when handling another right-click during an open menu, so the same
classification applies during a series. Pathview uses a visual hit test and
walks ancestors: this also detects disabled buttons, which an input hit test
could skip. It excludes the named tree/list frames and recognized control
types (`TreeView`, `ListView`, `ButtonBase`, `TextBoxBase`, `ComboBox`,
`TabItem`, `RangeBase`, `Thumb`, `MenuItem`, `SortOrderWidget` and
`CheckBoxWrapper`). Subclasses are covered, but this is an explicit type and
frame list, not automatic detection of every possible interactive control.
New custom widgets or unlisted interactive control types require checking this
classification and its tests. The transparent Sub directories frame makes its
padded margins hit-testable as part of the excluded area.

### Shell Construction

The background represents the current directory, not a selected directory item.
The factory obtains its `IContextMenu` from a Shell view's
`IShellView::GetItemObject(SVGIO_BACKGROUND)`. Windows decides which background
registrations and built-in commands participate, including registrations under
`Directory\Background`; that registry key is not added as a selected item or
used as an additional type filter. Commands in both menus are invoked through
the background `IContextMenu` that produced them.

To classify general commands, the factory first creates the classified Base
Menu for the current directory as an item and captures its comparable Shell
entries without displaying it. It then builds the actual background menu. A
background entry is kept in the background Base Menu only if its comparable
key occurs exactly once in both menus. This uses the existing verb/label and
submenu-tree comparison, including the unique-label fallback for entries without
a verb. Matching is conservative: different labels, empty or lazy submenus,
ambiguous commands and provider-specific differences can prevent a match; the
presence of a registration alone is not proof of an identical command.

The Base Menu includes the application's common actions. Requesting a background
menu clears the ContentView selection before the menu opens. Background actions
target the active directory. Directory
actions follow the normal transfer and drive-root restrictions; Abort transfer
remains available when a transfer is prepared. The background Content Menu starts with a
fresh native background menu and removes unique matches to the displayed Base
Menu snapshot. `New` is in the Content Menu, not the Base Menu, and opens the
same application-owned type and name dialog as the ContentView New button.
The factory replaces the native New submenu with the supplied application
action, or appends the action if the native submenu is not found. The action
always uses the application's localized label. It keeps the original Windows menu for Shift and the dialog's explicit
Windows fallback. Supported direct types and their limits are described in
[CONTENT_VIEW.md](CONTENT_VIEW.md). The background Content Menu excludes the
native Shell `paste` command; the original Shift menu is unchanged.

For an existing active directory, Properties, the three external Prepare actions
and the three clipboard-copy actions are enabled, except that external Move
requires a deletable source. Mark link and Mark copy additionally require that no
transfer is prepared; Mark move also requires an editable Shell name. Rename
requires an editable name and an available active-directory rename handler;
Relocate requires an editable name and an available relocate handler. Delete
requires a deletable directory and no prepared transfer. Drive roots have no
editable Shell name and cannot be deleted. A missing or virtual target can fall
back to the native background menu rather than the paired menus.

When supported filesystem data is available on the clipboard, the Content Menu
for a directory item or active directory background starts with `Copy clipboard
item here`, `Abort clipboard move` and `Move cut item here`, or `Abort clipboard
link` and `Link to externally selected item`, followed by a separator. Clipboard
Abort clears the global clipboard without changing the source items or reporting a
successful transfer. Both actions reject a clipboard changed since the menu was
built; the abort check and clear are performed while the clipboard is locked.
When a Link, Copy or Move is prepared, `Abort transfer`
and the matching execute action (`Insert link to marked item`, `Insert copy of
marked item`, or `Move marked item here`) follow, with their own separator. The
clicked directory is the destination for an item menu; the active directory is
the destination for a background menu. Clipboard paste and prepared transfers
are independent. Unsupported clipboard data, missing transfers and file items
do not offer their respective actions. Existing Shell and `New` commands retain
their behavior.

Both paired background menus exclude the Shell commands `refresh` and
`viewcustomwizard` (Refresh and Customize this folder). The original native
background menu, including these commands, remains available with Shift.

View, Sort by and Group by submenus are removed from both paired background
menus. The factory identifies their populated Shell commands by canonical view,
arrange, sort and group verbs, and also matches localized `shell32.dll` Sort by
and Group by labels for empty or lazy submenus. It uses a localized Shell label
to keep New out of the Base Menu. These resource IDs are not a documented Shell
API contract. Windows versions or extensions that expose different labels or
verbs, especially an initially empty View submenu, may not be recognized;
removing a matching submenu also removes all of its children. The original
Shift background menu is not filtered.

## Base Menu

The Base Menu contains `Properties`, a separator, `Copy name to clipboard`,
`Copy path to clipboard`, `Copy item to clipboard`, a separator, `Abort transfer`,
`Mark link item`, `Mark copy item`, `Mark move item`, a separator, the Shell
entries, a separator, `Rename`, `Relocate`, a separator, and `Delete`. Unavailable
application actions remain visible and disabled. Abort transfer clears any
prepared Link, Copy and Move workflows; the individual execute and clipboard
paste actions are available on the toolbar when its button group is shown. The
action-button groups are hidden by default; their visibility flags are described
in [Configuration](Configuration.md#pathview-action-groups) and do not disable
context-menu actions. In the sidebar, item-targeted
actions operate on the clicked directory rather than the ContentView selection.
Rename uses the sidebar inline editor. Relocate requires one file or directory and
offers either a destination parent or a full destination including the new name.
Its Shell operation updates tracked directory paths when moving a directory.
Properties invokes the Shell properties command for one or more loaded selected
items. Rename requires one loaded item with an editable Shell name; Name clipboard copy and Path
clipboard copy require one or more loaded items. Name clipboard copy copies their filesystem leaf names,
including any file extensions, while Path clipboard copy copies their full filesystem paths.
For multiple items both actions use text with one item per line. Link mark item, Copy mark item and
Move mark item require loaded selected items and no prepared transfer. Their respective execute and abort actions require
that workflow to be prepared. Link, Copy and Move use the application's mutually
exclusive prepared-operation workflows, not the Windows clipboard: mark item prepares
selected paths, execute operates in the current folder, and abort clears the
prepared operation. Item clipboard copy invokes the Shell Copy verb for its selection and
the clipboard action performs the requested Copy, Move or explicit Link into the
current directory or clicked directory. A Copy effect that also permits Link is
treated as Copy; other combined, missing or unsupported effects are rejected.
After a complete Move, the original source receives Shell completion feedback;
if it rejects feedback, the application reports that the move already occurred. These actions
and external clipboard operations do not change the internal workflows. Link execute
creates Shell shortcuts without changing the sources.
The application-owned New, Link execute, Copy execute and Move execute
toolbar actions use ContentView insertion completion: they
reset filters that hide inserted items, select the inserted items and scroll the
first into view. This includes items transferred before a later failure. Native
Windows menu and extension actions do not use that completion. Delete uses the
Shell file-operation API; it requires loaded,
deletable targets and is disabled during a prepared Link, Copy or Move. The Shell
controls confirmation and recycling, which depends on the location.

For files and mixed file/directory selections, the Shell section is produced by
`SHCreateDefaultContextMenu` using the `*` and `AllFilesystemObjects`
association keys and the complete selection. For directory-only selections, the Base
Menu starts from the actual Windows item menu and keeps uniquely matching entries
from an `AllFilesystemObjects` menu and the additional
registry-matched entries described below. The selected commands are invoked via
the Windows item menu that produced them, not by using file commands on a
directory. `CMF_CANRENAME` is supplied for single and multiple selections; on
the investigated installation this avoids Link Shell Extension presenting its
drag-and-drop-only menu instead of the appropriate selection menu.

The file Base Menu request can be interpreted as: "Build a context menu for
the selected files x, y and z, using the menu registrations directly associated
with the `*` and `AllFilesystemObjects` classes." These sources include
declarative verbs as well as classic handlers. This is an explanatory
interpretation of the call, not a guarantee about every resulting entry: the
Shell can also supply built-in commands, and the Shell and extensions determine
what to offer for the selection.

In the `DEFCONTEXTMENU` passed to `SHCreateDefaultContextMenu`, the selected
items and the two registry keys are separate inputs. The keys select
registration sources; they do not change the files' types or impose additional
type conditions on them. After the Shell returns the context menu object,
`QueryContextMenu` populates its entries for the selection, and KIS Explorer
applies the exclusions described below. File-type-specific association keys are
not explicitly supplied in this request. The Content Menu instead starts from
the normal Windows item menu for the complete selection.

For a mixed selection the same request and file-menu filters apply regardless of
the order of the selected items. The `*` class is normally a file association;
its extensions receive the mixed selection and decide what to offer. The
application does not establish that every offered command applies to every
item, or that the resulting menu is a subset of the normal Windows menu.
The directory-only registry and whitelist classification is not used. Rename
is disabled for multiple selections; Name clipboard copy and Path clipboard copy copy all selected
names or paths, Link mark item, Copy mark item and Move mark item stage all selected items, and Delete
requires each item to be deletable.

### Directory Classification: Three Alternative Criteria

For a directory-only selection, a Shell entry can qualify for the Base Menu
through any one of these criteria. They are alternatives, not three tests that
must all pass. The explicit command exclusions below are applied afterwards.

1. **`AllFilesystemObjects`:** the entry matches a command obtained by asking
  the Shell for a menu using this association class.
2. **`Directory` or `Folder` and `*`:** a directory registration also has a
  corresponding `*` registration, and a matching entry is found in the actual
  directory menu. `*` is the literal registry class name, not a search pattern.
3. **`Directory` or `Folder` and whitelist:** a directory registration matches
  a configured verb or CLSID, and a matching entry is found in the actual
  directory menu. A `*` registration is not required for this criterion.

The distinction between registry and Shell is important: the registry describes
registrations, not the final menu for the current selection. The Shell builds
menus and supplies command verbs and labels. KIS Explorer uses the registry to
identify candidates for criteria 2 and 3, then compares them to entries actually
supplied by the Shell. It does not simply display every registered verb or
execute a command taken from the file-only `*` class on a directory.

#### Order of Checks

1. KIS Explorer asks `SHCreateDefaultContextMenu` and `QueryContextMenu` for a
  menu for the selected directories with `AllFilesystemObjects` as the only
  association key. It records comparable entries and their occurrence counts.
  This is a separate probe, not the menu ultimately displayed.
2. It reads the merged `HKEY_CLASSES_ROOT` registrations for `*`, `Directory`
  and `Folder` and the embedded whitelist. It identifies eligible verbs and
  classic handlers as described below. Each eligible classic handler is also
  queried separately with the actual selection and the relevant directory
  class; its resulting menu provides additional comparison data.
3. KIS Explorer obtains the normal Windows item menu for the selected
  directories using `IShellFolder::GetUIObjectOf` and `QueryContextMenu`. For
  each top-level entry, it checks Properties and the three alternatives using
  the data collected above. Entries that do not match are removed.
4. The application's own actions are prepended and the explicit exclusions are
  applied. The remaining Shell commands are still invoked through the normal
  directory menu's own `IContextMenu`; the probe menus are not used to invoke
  them.

#### Criterion 1: AllFilesystemObjects

The application compares each entry in the actual directory menu with the
recorded `AllFilesystemObjects` probe. A comparable key must occur exactly once
in each menu. For a top-level command, the key consists of its Shell verb from
`IContextMenu::GetCommandString` and its exact visible label. Verb comparison is
case-insensitive; label comparison is case-sensitive. A command without a
usable verb is not recorded by this particular probe.

For a submenu, the key includes its exact label and the currently populated
submenu tree, including child order, labels and available verbs; separators are
ignored. An empty or otherwise non-comparable submenu cannot match this way.
Disabled entries can be considered here. The detailed comparability rules are
described under Content Menu and Duplicate Detection, except that this
classification allows disabled entries.

For example, if the probe and the actual menu each contain exactly one command
with verb `example` and label `Example`, that actual menu entry qualifies.
Merely finding a registry key under `AllFilesystemObjects` does not itself
establish that a particular actual menu entry matches.

#### Criterion 2: Directory or Folder Also Registered Under *

The `*` overlap is discovered during the registry scan, before the actual
directory menu is filtered. Two registration forms are checked independently:

- **Declarative verbs:** compare the subkey names under `*\shell` with those
  under `Directory\shell` and `Folder\shell`, ignoring case. For example,
  `*\shell\Example` and `Directory\shell\Example` make `Example` a shared
  verb. When an actual top-level directory-menu command reports that verb via
  `GetCommandString`, it qualifies, even if the verb appears more than once in
  that menu. This compares names, not implementations: matching names do not
  prove that the two registrations perform the same action.
- **Classic handlers:** read the enabled CLSIDs under
  `*\shellex\ContextMenuHandlers`, then compare them with the CLSIDs under the
  same path below `Directory` and `Folder`. A GUID can be the default value or,
  if that is not a GUID, the subkey name; entries whose default value starts
  with `-` are skipped. Handler subkey names need not match if the CLSIDs match.
  For example, a CLSID registered under both `*` and `Directory` identifies a
  shared handler, not a particular entry in the actual menu.

For each eligible classic handler, KIS Explorer instantiates the handler,
initializes `IShellExtInit` with the selected items and each directory class
under which it was found, and calls its `IContextMenu::QueryContextMenu`.
It records the resulting top-level labels and whether each is an item or a
submenu. An actual directory-menu entry with the same exact, readable label and
the same kind qualifies even when the label is duplicated, or the submenu is
empty or contains different children. The comparison does not establish that
the actual entry came from that handler. As a guard, a known declarative
directory-only verb is not admitted solely by this loose label match. Such an
entry can still qualify through another applicable criterion.

For example, if a shared handler independently produces `Hg &Workbench` as an
item and the actual directory menu has an item with that exact label, the item
can qualify even when the Shell supplies no usable verb. A submenu with that
label would not match an item. Labels must be readable, nonempty and fit the
comparison buffer; disabled entries can be considered. Handler initialization
or querying can fail, and handlers without the required classic interfaces
cannot be classified by this probe.

The handler probe also collects strict comparable keys, using verbs and labels
or populated submenu trees. A key that occurs exactly once across the eligible
handler results and once in the actual menu is another way to match an entry.
For a verb-less individual command, the exact label can be used as a strict key
only when it is unique among top-level labels in each relevant menu. When the
same handler is registered under both directory classes, its identical results
are counted at most once per handler; results from different handlers are added.

#### Criterion 3: Directory or Folder and Whitelist

For declarative directory verbs, a whitelist verb is compared case-insensitively
with the registry subkey name. Alternatively, the CLSID in that subkey's
`ExplorerCommandHandler` value can be whitelisted. The actual menu entry's
Shell verb must match the eligible registry verb and occur exactly once in the
actual directory menu, unless criterion 2 independently permits it.

For classic directory handlers, the whitelist CLSID is compared with the
registered handler CLSID. The handler is queried with the selection as above.
For a handler that is eligible only through the whitelist, the actual entry
must match a strict comparable key occurring exactly once in both the actual
menu and the combined handler results. The relaxed label-and-kind matching is
reserved for handlers also registered under `*`. Whitelisting a handler covers
its comparable commands, not only one named command.

The relaxed criterion 2 can admit an unrelated command that happens to share a
label, and ambiguous entries can also remain in the Content Menu because its
duplicate detection is stricter. Conversely, an entry that cannot be matched by
any available comparison stays out of the Base Menu. Neither registry overlap
nor a menu match proves that an action is content-independent or identifies its
provider with certainty.

The embedded [directory menu whitelist](Assets/directory-menu-whitelist.json)
is initially empty. Each `extensions` entry has `_type` set to `shellExtension`,
a descriptive `name`, and `verbs` and `clsids` arrays. For example:

```json
{
  "_type": "directoryMenuWhitelist",
  "extensions": [
    {
      "_type": "shellExtension",
      "name": "Example",
      "verbs": ["ExampleVerb"],
      "clsids": ["{11111111-2222-3333-4444-555555555555}"]
    }
  ]
}
```

Either array can be empty. Verbs are matched case-insensitively and CLSIDs are
parsed as GUIDs. A whitelisted verb or CLSID must still be registered under
`Folder` or `Directory`, and Windows must provide a matching command for the
selection. A classic handler whitelist entry covers its comparable commands,
not just one command. Explicit Shell command exclusions still apply. The file
is embedded at build time, so editing it requires a rebuild. A malformed
whitelist is reported to .NET trace output and the additional registry-based
classification is skipped; identifiable `AllFilesystemObjects` entries remain.

The application then filters the resulting Shell entries, removes redundant
separators and adds the application actions around the Shell section. The menu may include built-in commands and extension
commands; neither generic registration nor a command's visible label proves its
purpose or provider.

## Explicit Shell Command Rules

Matching uses Shell command verbs obtained from `IContextMenu::GetCommandString`,
case-insensitively. A menu command without a usable verb cannot be reliably
classified this way. These rules apply to the file, directory and mixed menu
pairs, not the Shift menus or the background pairs, except for the `.lnk`
Open file location rule below. In this table, "files"
includes mixed selections; "directories" means directory-only selections.

| Shell action and verb | Base Menu | Content Menu | Reason or application equivalent |
| --- | --- | --- | --- |
| Copy `copy` | Excluded | Excluded | Item clipboard copy copies the selected items to the clipboard. |
| Cut `cut` | Excluded | Excluded | Move mark item prepares the application workflow. |
| Paste `paste` | Excluded | Excluded | Item clipboard paste uses the Windows clipboard. |
| Copy as path `copyaspath` | Excluded | Excluded | Path clipboard copy copies the selected paths as text. |
| Rename `rename` | Excluded | Excluded | Rename starts the application's inline editor. |
| Delete `delete` | Excluded | Excluded | Delete uses the application's Shell-backed operation. |
| Create shortcut `link` | Files: excluded; directories: retained when matched | Files: excluded; directories: retained unless identified as a duplicate | There is no application replacement. |
| Properties `properties` | Top-level entry excluded when application actions are supplied | Excluded | Application Properties invokes the Shell command. |
| Open `open`, Edit `edit` | Files: top-level entries excluded; directories: retained when matched | Retained unless separately identified as a duplicate | File content-specific operations belong in the Content Menu. |
| Open With `openas` | Files: top-level entry excluded; directories: retained when matched | Retained unless separately identified as a duplicate | File content-specific operation belongs in the Content Menu. |
| Open file location `opencontaining` | Excluded for selections containing `.lnk` | Replaced by the application action for selections containing `.lnk` | Open the shortcut target's containing folder in KIS Explorer. |

For `.lnk` selections, the application also replaces `opencontaining` in the
Shift item menu. The replacement uses the action ID `opencontaining` and the
visible label **Open parent**, and is disabled for multiple selections. If the Shell does not supply the command,
the application adds its own entry. A single shortcut's file or directory target
is resolved when invoked; its parent directory opens in the browsable Pathview,
including when the target itself is a directory.
Unavailable, virtual or root targets report an error without invoking the Shell
command. Matching depends on the Shell exposing the canonical verb; commands
without an identifiable verb cannot be reliably classified.

The exclusions for `copy`, `cut`, `paste`, `copyaspath`, `rename` and `delete`
are applied recursively to currently populated submenus in both menus and again
after a submenu is initialized. The same applies to `link` for files and mixed
selections. `properties` is filtered recursively in the Content Menu and at the
top level in the Base Menu when application actions are supplied. Paired background
menus also remove the top-level Shell Properties entry; the Shift menu retains
Shell Properties. For files and mixed selections, the
Base Menu-only exclusions for `open`, `edit`, `openas` and the blacklist are
applied only to top-level commands when the Base Menu is prepared; they are not
recursive or reapplied to lazy submenus. Consequently a nested or subsequently
added entry can remain visible.

The file and mixed-selection Base Menu also removes the Shell Open With submenu when it is owner-drawn,
has a submenu handle, and its label exactly matches the localized `shell32.dll`
string resource 5376. This is needed because the observed submenu has no usable
verb. The resource ID is not a documented Shell API contract; if the resource
cannot be loaded or a Windows version represents the submenu differently, this
exception may not match.

The embedded [Shell extension blacklist](Assets/shell-extension-blacklist.json)
contains descriptive names and exact verbs, currently `ANotepad++64` for
Notepad++. Names are informational; verbs are matched case-insensitively. The
blacklist affects only top-level entries in file and mixed-selection Base Menus, not the directory-only
Base Menu. It is embedded at build time, so editing it requires a rebuild. The Content Menu does not apply
this blacklist, so those commands can appear there when Windows supplies them.
The separate
[diagnostic tool](tests/ContextMenuSpike.ps1) can help discover observed verbs;
its registry candidates are not proof that a particular command was supplied.

## Content Menu and Duplicate Detection

The Content Menu starts with the normal Shell item menu for the selected items,
again using `CMF_CANRENAME`. It first removes the common exclusions and
`properties`, then compares the remaining top-level entries against a snapshot
of comparable entries from the Base Menu. The snapshot is collected from the
Base Menu after its popup closes, including any submenu contents populated
while it was open. Application toolbar IDs are outside the Shell command-ID range
and do not participate in this comparison.

For ContentView item selections, the first three entries, after any prepared
transfer actions, are Shell **Open**, **Open in running app...**, and Shell
**Open with**. Shell entries are preserved
as native commands or submenus; unavailable entries have disabled placeholders.
The running-app submenu contains one application action
per matching running window, labeled `App name - Window title` and ordered by
app and window title, with an app or window icon when available. Multiple selected files must all have the app among their
Shell associations. A selection containing a directory, or one without matching
windows, has a disabled submenu. This action is not added to the background,
sidebar or Shift menus. Its command IDs belong to the application, not the Shell,
and coexist with the application-owned **Open parent** action.

Selecting a window attempts `Ctrl+O` and a guarded Open dialog first. On failure,
it may drop the remaining files at the center, unless an open dialog or changed
focus makes the target unsafe. The clipboard is not changed. A drop can modify
an existing document; a submitted dialog or accepted drop does not establish
that the target opened the files. No transfer result dialog is shown.
Details are in [Open with Running App](OPEN_WITH_RUNNING_APP_SPEC.md).

An individual top-level Shell command is comparable only if it is enabled, not
owner-drawn, has a readable nonempty, nontruncated label and has a Shell command
ID. Its key is normally the case-normalized verb and the exact label; labels are
case-sensitive. For directory commands without a usable verb, the exact label
alone is used only when it is unique among all top-level labels in each menu.
This is an indication, not proof, that the entries share a provider. A submenu is comparable when it has a readable
nonempty, nontruncated label and its currently populated tree can be described
recursively:

- Separators are ignored; the order, labels and hierarchy of all other entries
  are preserved in the comparison. Labels must be readable, nonempty and
  nontruncated, and all entries must be enabled.
- Every leaf must have a Shell command ID. Its label and case-normalized verb,
  if available, are included. Submenu labels are included as well.
- Empty or unreadable trees are not comparable. A tree with no usable verbs
  must contain at least two leaf commands.

For either kind, a matching entry is removed from the Content Menu only when its
comparison key occurs exactly once in the Base Menu snapshot and exactly once in
the Content Menu. Otherwise it remains. The application removes redundant
separators afterwards. This conservative policy favors preserving commands over
eliminating every duplicate: disabled, opaque, ambiguous and differing entries
remain, and identical labels and verbs do not prove a shared provider.

Only currently populated submenu trees participate in duplicate detection.
Providers can populate or change a submenu when it opens; duplicate detection is
not rerun then. The explicit recursive exclusions above are reapplied after
`WM_INITMENUPOPUP` forwarding, but the Base Menu blacklist and duplicate comparison
are not. Therefore duplicates and unclassifiable commands can remain visible.

## Native Lifetime and Limitations

Menus are created and shown on an STA thread. Shell messages for submenu
initialization, owner drawing, measurement and menu characters are forwarded to
`IContextMenu3` or `IContextMenu2` when supported. A selected Shell command is
invoked using its offset against the same `IContextMenu` that built the menu;
command IDs are not stable identities and are never reused across instances.
Popup hooks, window subclasses, menu handles, PIDLs and COM resources are
released after use. Application toolbar entries invoke their own button handlers.
Exceptions in native right-click and menu-message callbacks are reported through
.NET trace output and are not allowed to escape through the native callback;
normal Windows hook or subclass processing continues as the fallback.

Filtering happens after Windows and registered extensions have constructed the
menu. The directory classification also initializes and queries matching classic
handlers separately, which can run extension code and add latency. It is not a
sandbox and cannot prevent a filtered extension from loading or executing during
construction. Results depend on the selection, installed
extensions, architecture and Windows version. Modern packaged extensions and
the Windows 11 compact menu are not guaranteed to match these classic Shell
menus. The [spike results](CONTEXT_MENU_SPIKE.md) document investigated
alternatives and their limitations.

## Verification

[SutShell.Tests.ps1](tests/SutShell.Tests.ps1) exercises menu contents, filtering,
toolbar actions, Shell invocation, selection and menu switching for single,
multiple and mixed files and directories. It also checks the independent sidebar
menu series, target-specific actions and the absence of an Active path tree menu. It
exercises the shared background sequence, native Shift fallback, view filtering,
the shared New dialog, shared/background-only registry fixtures and background action states.
It includes native popup and mouse-input probes in WPF windows;
these tests display windows and move the pointer. Manual verification in the
actual application remains useful for installed extensions, Windows versions and
interaction timings not represented by the test environment.

[ItemClipboardActions.Tests.ps1](tests/ItemClipboardActions.Tests.ps1) also
checks movement-triggered sequence resets with both popups open and closed,
menu command execution, a fresh Base Menu after a right-click on the same item,
another item or the background, and ContentView unload.
Its native popup tests temporarily display a test window and move the pointer.

[Pathview.Tests.ps1](tests/Pathview.Tests.ps1) checks background classification,
including excluded controls, a disabled button and the Sub directories margin,
plus clearing the ContentView selection. [MultiPathview.Tests.ps1](tests/MultiPathview.Tests.ps1)
exercises the actual right-click sequence on a Pathview label and the independent
sidebar item series. [BaseMenuActions.Tests.ps1](tests/BaseMenuActions.Tests.ps1)
checks active-directory action states and targets, including drive roots and
prepared transfers. [ContentViewActionInteractions.Tests.ps1](tests/ContentViewActionInteractions.Tests.ps1)
checks background selection clearing and transfer-menu behavior. These native UI
tests can display windows and move the pointer.

## Follow-up

- [ ] Add deterministic tests for duplicate and submenu comparison, including
  disabled, owner-drawn, ambiguous, lazy and missing-verb entries. Keep native
  integration tests for real Shell message forwarding and invocation; installed
  extensions and Windows versions can differ from the test machine.
- [ ] Check callback diagnostics and menu behavior on representative Windows
  installations, display scaling configurations and extension combinations.