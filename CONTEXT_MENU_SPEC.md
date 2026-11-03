# File and Directory Context Menu Pair

## Scope and Intent

ContentView provides a Base Menu (Basismenü) and a Content Menu (Inhaltsmenü)
for a selection of existing files and/or directories and for the current
directory's background. The same menu pair is available for filesystem
directories in the **Active path and siblings** tree, and for directories and
the background of the **Sub directories** list in **Active path**. The Base Menu puts the
application's common file operations first and includes generally applicable
Shell commands. The Content Menu provides the remaining item-specific Shell
commands. Windows constructs and invokes the Shell portions of both menus; KIS
Explorer filters the resulting menus instead of reconstructing extension
handlers itself.

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

Each participating widget owns a `SutContextMenuController<T>` for its own
target type and menu-series state. The view constructs and calls the controller;
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
- Supply the target-specific `ShellMenuAction` entries, each with a label,
  enabled state and application callback. The view owns their behavior.
- Supply the current background directory and its application actions when no
  item is targeted.
- Show the original native item or background menu when the controller requests
  a fallback. The item callback receives the target and current selected paths.

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
- A right-click on the list background clears the selection and starts or
  advances its own Base/Content/no-menu series for the current directory.
  Switching between an item and the background starts a new series. List chrome
  such as headers and scrollbars is not treated as an item or background. Clicks
  outside the owner are not consumed as menu-series clicks.
- Shift-right-click on an item uses the original Windows item menu, including
  on the same row while either popup is open. It preserves the current selection;
  on another row while the Base Menu is open it selects only that row. The
  modifier is taken from the mouse message, even if Shift is released before the
  new menu opens. Shift-right-click on the background uses the original Windows
  background menu, including its view commands.
  The keyboard context-menu key or Shift+F10 opens the applicable menu without
  starting a mouse-driven alternation series.

The two sidebar widgets use the same menu series for the clicked directory,
with independent controller state per widget and Pathview. Each has a single
target rather than ContentView's multiple selection. Selecting a different
tree target or navigating resets the corresponding series. The Sub directories
list clears its visual selection after its menu closes, while preserving the
series for a subsequent right-click on the same folder. Its background has its
own three-step sequence; the tree in the **Active path** tab retains its
native item menu. Virtual or unavailable sidebar targets fall back to the
native item menu. Shift-right-click uses that native menu; in the Sub directories
list the Apps key opens the applicable item menu and Shift+F10 the native menu.
With no selected sidebar item these keyboard commands retain the native
background menu.

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

The Base Menu prepends the application's nine common actions. With no selected
item, Rename, Path get, Copy get, Move get and Delete are disabled; prepared
Copy/Move abort and paste actions remain available according to workflow state.
Paste targets the current directory. The background Content Menu starts with a
fresh native background menu and removes unique matches to the displayed Base
Menu snapshot. `New` is in the Content Menu, not the Base Menu, and opens the
same application-owned type and name dialog as the ContentView New button.
The factory replaces the native New submenu with the supplied application
action; it keeps the original Windows menu for Shift and the dialog's explicit
Windows fallback. Supported direct types and their limits are described in
[CONTENT_VIEW.md](CONTENT_VIEW.md). Background
commands such as Windows clipboard Paste are not subjected to the selected-item
file-verb exclusion list; they are distinct from the application's prepared
Copy/Move workflows.

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

The first section is, in order, `Rename`, `Path get`, `Copy get`, `Copy abort`,
`Copy paste`, `Move get`, `Move abort`, `Move paste` and `Delete`. Each entry
uses the corresponding toolbar button's current label, enabled state and click
handler in ContentView. In the sidebar, the same labels are used but the
actions operate on the clicked directory rather than the ContentView selection;
Rename uses the sidebar inline editor. Copy paste and Move paste use the current
Pathview directory as their destination, not necessarily the clicked directory.
Rename requires one loaded item with an editable Shell name; Path get
requires one loaded item. Copy get and Move get require loaded selected items
and no prepared Copy or Move. Their respective paste and abort actions require
that workflow to be prepared. Copy and Move use the application's mutually
exclusive prepared-operation workflows, not the Windows clipboard: get prepares
selected paths, paste operates in the current folder, and abort clears the
prepared operation. The application-owned New, Copy paste and Move paste
actions use the same ContentView insertion completion as the toolbar: they
reset filters that hide inserted items, select the inserted items and scroll the
first into view. This includes items transferred before a later failure. Native
Windows menu and extension actions do not use that completion. Delete uses the
Shell file-operation API; it requires loaded,
deletable targets and is disabled during a prepared Copy or Move. The Shell
controls confirmation and recycling, which depends on the location.

For files and mixed file/directory selections, the Shell section is produced by
`SHCreateDefaultContextMenu` using the `*` and `AllFilesystemObjects`
association keys and the complete selection. For directory-only selections, the Base
Menu starts from the actual Windows item menu and keeps Properties, uniquely
matching entries from an `AllFilesystemObjects` menu, and the additional
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
and Path get are disabled for multiple selections; Copy get and Move get stage
all selected items, and Delete requires each item to be deletable.

### Directory Classification: Three Alternative Criteria

For a directory-only selection, a Shell entry can qualify for the Base Menu
through any one of these criteria. They are alternatives, not three tests that
must all pass. Properties is retained separately when Windows provides it;
the explicit command exclusions below are applied afterwards.

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
separators and prepends the toolbar section. Shell Properties remains available
when supplied by Windows. The menu may include built-in commands and extension
commands; neither generic registration nor a command's visible label proves its
purpose or provider.

## Explicit Shell Command Rules

Matching uses Shell command verbs obtained from `IContextMenu::GetCommandString`,
case-insensitively. A menu command without a usable verb cannot be reliably
classified this way. These rules apply to the file, directory and mixed menu
pairs, not the original Shift menus or the background pairs. In this table, "files"
includes mixed selections; "directories" means directory-only selections.

| Shell action and verb | Base Menu | Content Menu | Reason or application equivalent |
| --- | --- | --- | --- |
| Copy `copy` | Excluded | Excluded | Copy get prepares the application workflow. |
| Cut `cut` | Excluded | Excluded | Move get prepares the application workflow. |
| Paste `paste` | Excluded | Excluded | Copy paste or Move paste completes a prepared workflow. |
| Copy as path `copyaspath` | Excluded | Excluded | Path get copies the path for one selected file. |
| Rename `rename` | Excluded | Excluded | Rename starts the application's inline editor. |
| Delete `delete` | Excluded | Excluded | Delete uses the application's Shell-backed operation. |
| Create shortcut `link` | Files: excluded; directories: retained when matched | Files: excluded; directories: retained unless identified as a duplicate | There is no application replacement. |
| Properties `properties` | Retained if provided | Excluded | Keep the Shell Properties command in one menu. |
| Open `open`, Edit `edit` | Files: top-level entries excluded; directories: retained when matched | Retained unless separately identified as a duplicate | File content-specific operations belong in the Content Menu. |
| Open With `openas` | Files: top-level entry excluded; directories: retained when matched | Retained unless separately identified as a duplicate | File content-specific operation belongs in the Content Menu. |

The exclusions for `copy`, `cut`, `paste`, `copyaspath`, `rename` and `delete`
are applied recursively to currently populated submenus in both menus and again
after a submenu is initialized. The same applies to `link` for files and mixed
selections. `properties` is filtered the same way in the Content Menu only. For files and mixed selections, the
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
menu series, target-specific actions and unchanged native Active path tree. It
exercises both background sequences, native Shift fallback, view filtering,
the shared New dialog, shared/background-only registry fixtures and background action states.
It includes native popup and mouse-input probes in WPF windows;
these tests display windows and move the pointer. Manual verification in the
actual application remains useful for installed extensions, Windows versions and
interaction timings not represented by the test environment.

## Follow-up

- [ ] Add deterministic tests for duplicate and submenu comparison, including
  disabled, owner-drawn, ambiguous, lazy and missing-verb entries. Keep native
  integration tests for real Shell message forwarding and invocation; installed
  extensions and Windows versions can differ from the test machine.
- [ ] Check callback diagnostics and menu behavior on representative Windows
  installations, display scaling configurations and extension combinations.