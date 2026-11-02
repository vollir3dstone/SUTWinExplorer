# File Context Menu Pair

## Scope and Intent

ContentView provides a generic and a special context menu for a selection of
one or more existing files. The generic menu puts the application's common file
operations first and includes generally applicable Shell commands. The special
menu provides the remaining file-specific Shell commands. Windows constructs and
invokes the Shell portions of both menus; KIS Explorer filters the resulting
menus instead of reconstructing extension handlers itself.

This specification describes the implemented behavior, not a promise that every
installed extension or every Windows 11 compact-menu command is available. The
separate [diagnostic spike](CONTEXT_MENU_SPIKE.md) retains the investigations,
including unsuccessful approaches and machine-specific observations. The main
implementation is in [ContentView.xaml.cs](ContentView.xaml.cs) and
[ShellContextMenu.cs](ShellContextMenu.cs).

## Selection and Menu Sequence

- On an initial right-click, an unselected row becomes the sole selection; a
  selected row preserves an existing multiple selection.
- A file-only selection opens the generic menu first. The clicked row's full
  path identifies the menu series, and the complete selection is retained.
- A second right-click on the same row opens the special menu for that same
  selection, including while the generic popup is still open. After the special
  menu closes, a further right-click starts again with the generic menu.
- A right-click on another row ends the series and makes that row the sole
  selection, even if it was already part of a multiple selection. A file starts
  a new generic menu; a folder uses its ordinary Windows item menu.
- A selection change invalidates the remembered generic menu and its command
  snapshot. While the generic popup is open, a change to the selection also
  prevents using the stale snapshot to open a special menu.
- A right-click on the list background clears the selection and opens the
  Windows background menu. List chrome such as headers and scrollbars is not
  treated as an item or background. Clicks outside the owner are not consumed
  as menu-series clicks.
- Shift-right-click on an item uses the original Windows item menu, including
  when the generic popup is already open. On the same row it preserves the
  current selection; on another row it selects only that row. The modifier is
  taken from the second mouse message, even if Shift is released before the new
  menu opens. Folder and mixed file/folder selections also use the original item
  menu. The keyboard context-menu key or Shift+F10 opens the applicable menu
  without starting a mouse-driven alternation series.

The generic popup is tracked using a thread-local Windows menu message filter.
For a second right-button-down or right-button-double-click message, its screen
coordinates are hit-tested against the ContentView list. A handled click closes
the generic popup before another menu is opened, so each Shell menu and its COM
objects have separate lifetimes. Ordinarily a click on the popup itself remains
a popup click. For a quick double-click at the popup's opening point, the code
also accepts a native menu window on the same thread as a hit on the underlying
list. The interval is measured from the opening input message using the system
double-click time, and the click must fall within the system double-click
rectangle around the popup's opening point. The special popup does not install
this second-click filter; normal Windows menu tracking applies while it is open.

## Generic Menu

The first section is, in order, `Rename`, `Path get`, `Copy get`, `Copy abort`,
`Copy paste`, `Move get`, `Move abort`, `Move paste` and `Delete`. Each entry
uses the corresponding toolbar button's current label, enabled state and click
handler. Rename requires one loaded item with an editable Shell name; Path get
requires one loaded item. Copy get and Move get require loaded selected items
and no prepared Copy or Move. Their respective paste and abort actions require
that workflow to be prepared. Copy and Move use the application's mutually
exclusive prepared-operation workflows, not the Windows clipboard: get prepares
selected paths, paste operates in the current folder, and abort clears the
prepared operation. Delete uses the Shell file-operation API; it requires loaded,
deletable targets and is disabled during a prepared Copy or Move. The Shell
controls confirmation and recycling, which depends on the location.

The Shell section is produced by `SHCreateDefaultContextMenu` for the selection,
using only the `*` and `AllFilesystemObjects` association keys. These keys limit
association sources, not commands by semantic category. Windows still decides
which providers participate, and can execute extensions while constructing the
menu. `CMF_CANRENAME` is supplied for single and multiple file selections; on
the investigated installation this avoids Link Shell Extension presenting its
drag-and-drop-only menu instead of the appropriate selection menu.

The application then filters the resulting Shell entries, removes redundant
separators and prepends the toolbar section. Shell Properties remains available
when supplied by Windows. The menu may include built-in commands and extension
commands; neither generic registration nor a command's visible label proves its
purpose or provider.

## Explicit Shell Command Rules

Matching uses Shell command verbs obtained from `IContextMenu::GetCommandString`,
case-insensitively. A menu command without a usable verb cannot be reliably
classified this way. These rules apply to the file-menu pair, not the original
Shift, folder, mixed-selection or background menus.

| Shell action and verb | Generic menu | Special menu | Reason or application equivalent |
| --- | --- | --- | --- |
| Copy `copy` | Excluded | Excluded | Copy get prepares the application workflow. |
| Cut `cut` | Excluded | Excluded | Move get prepares the application workflow. |
| Paste `paste` | Excluded | Excluded | Copy paste or Move paste completes a prepared workflow. |
| Copy as path `copyaspath` | Excluded | Excluded | Path get copies the path for one selected file. |
| Rename `rename` | Excluded | Excluded | Rename starts the application's inline editor. |
| Delete `delete` | Excluded | Excluded | Delete uses the application's Shell-backed operation. |
| Create shortcut `link` | Excluded | Excluded | No application replacement. |
| Properties `properties` | Retained if provided | Excluded | Keep the Shell Properties command in one menu. |
| Open `open`, Edit `edit` | Top-level entries excluded | Retained unless separately identified as a duplicate | Content-specific operations belong in the special menu. |
| Open With `openas` | Top-level entry excluded | Retained unless separately identified as a duplicate | Content-specific operation belongs in the special menu. |

The first seven exclusions are applied recursively to currently populated
submenus in both menus and again after a submenu is initialized. `properties` is
filtered the same way in the special menu only. The generic-only exclusions for
`open`, `edit`, `openas` and the blacklist are applied only to top-level commands
when the generic menu is prepared; they are not recursive or reapplied to lazy
submenus. Consequently a nested or subsequently added entry can remain visible.

The generic menu also removes the Shell Open With submenu when it is owner-drawn,
has a submenu handle, and its label exactly matches the localized `shell32.dll`
string resource 5376. This is needed because the observed submenu has no usable
verb. The resource ID is not a documented Shell API contract; if the resource
cannot be loaded or a Windows version represents the submenu differently, this
exception may not match.

The embedded [Shell extension blacklist](Assets/shell-extension-blacklist.json)
contains descriptive names and exact verbs, currently `ANotepad++64` for
Notepad++. Names are informational; verbs are matched case-insensitively. The
blacklist affects only top-level entries in the generic menu. It is embedded at
build time, so editing it requires a rebuild. The special menu does not apply
this blacklist, so those commands can appear there when Windows supplies them.
The separate
[diagnostic tool](tests/ContextMenuSpike.ps1) can help discover observed verbs;
its registry candidates are not proof that a particular command was supplied.

## Special Menu and Duplicate Detection

The special menu starts with the normal Shell item menu for the selected files,
again using `CMF_CANRENAME`. It first removes the common exclusions and
`properties`, then compares the remaining top-level entries against a snapshot
of comparable entries from the generic menu. The snapshot is collected from the
generic menu after its popup closes, including any submenu contents populated
while it was open. Application toolbar IDs are outside the Shell command-ID range
and do not participate in this comparison.

An individual top-level Shell command is comparable only if it is enabled, not
owner-drawn, has a readable nonempty, nontruncated label, has a Shell command ID,
and exposes a nonblank verb. Its key is the case-normalized verb and the exact
label; labels are case-sensitive. A submenu is comparable when it has a readable
nonempty, nontruncated label and its currently populated tree can be described
recursively:

- Separators are ignored; the order, labels and hierarchy of all other entries
  are preserved in the comparison. Labels must be readable, nonempty and
  nontruncated, and all entries must be enabled.
- Every leaf must have a Shell command ID. Its label and case-normalized verb,
  if available, are included. Submenu labels are included as well.
- Empty or unreadable trees are not comparable. A tree with no usable verbs
  must contain at least two leaf commands.

For either kind, a matching entry is removed from the special menu only when its
comparison key occurs exactly once in the generic snapshot and exactly once in
the special menu. Otherwise it remains. The application removes redundant
separators afterwards. This conservative policy favors preserving commands over
eliminating every duplicate: disabled, opaque, ambiguous and differing entries
remain, and identical labels and verbs do not prove a shared provider.

Only currently populated submenu trees participate in duplicate detection.
Providers can populate or change a submenu when it opens; duplicate detection is
not rerun then. The explicit recursive exclusions above are reapplied after
`WM_INITMENUPOPUP` forwarding, but the generic blacklist and duplicate comparison
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
menu. It is not a sandbox and cannot prevent a filtered extension from loading or
executing during construction. Results depend on the selection, installed
extensions, architecture and Windows version. Modern packaged extensions and
the Windows 11 compact menu are not guaranteed to match these classic Shell
menus. The [spike results](CONTEXT_MENU_SPIKE.md) document investigated
alternatives and their limitations.

## Verification

[SutShell.Tests.ps1](tests/SutShell.Tests.ps1) exercises menu contents, filtering,
toolbar actions, Shell invocation, selection and menu switching for single and
multiple files. It includes native popup and mouse-input probes in WPF windows;
these tests display windows and move the pointer. Manual verification in the
actual application remains useful for installed extensions, Windows versions and
interaction timings not represented by the test environment.

## Follow-up

- [ ] Define the generic and special menu contents for folder selections,
  mixed file/folder selections, and list background separately. In particular,
  decide how background commands such as Paste and New relate to application
  operations; do not apply the file exclusion list automatically.
- [ ] When implementing those menus, make the target kind and filtering rules
  explicit while retaining the shared Shell menu creation, invocation and
  native-resource lifetime handling. Background menus use a Shell view rather
  than the selected-item association keys.
- [ ] Extract the menu-series state and transitions into a small reusable unit
  when the folder and background behavior is specified. Cover target changes,
  multiple selections, cancellation, Shift and background clicks.
- [ ] Add deterministic tests for duplicate and submenu comparison, including
  disabled, owner-drawn, ambiguous, lazy and missing-verb entries. Keep native
  integration tests for real Shell message forwarding and invocation; installed
  extensions and Windows versions can differ from the test machine.
- [ ] Check callback diagnostics and menu behavior on representative Windows
  installations, display scaling configurations and extension combinations.