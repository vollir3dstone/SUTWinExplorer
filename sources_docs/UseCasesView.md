# UseCasesView

## Purpose and navigation

UseCasesView is a top-level alternative to TabsView. The use case icon at the
left of the application toolbar toggles between them. Opening UseCasesView
replaces the tabs in the main content area without closing or changing them;
clicking the icon again returns to the same tabs. The toolbar remains visible,
and its navigation and path controls are disabled while UseCasesView is shown.

The toolbar name always identifies the active use case, not merely the use case
selected for inspection. BROWSE remains the permanent first tab. The app starts
with the `default` use case active; activating another use case does not change
which use case is selected automatically at the next application startup.

## Layout

- The top row contains **Use cases**, **New**, the **FOR SELECTED:** badge,
  **Edit**, and **Delete**, in that order. The badge uses the same background,
   padding, text formatting, and fixed 24-DIP height as the badge in the content
   pane; its height matches the standard text buttons.
- Below it, the left pane contains a list of use case names. The right pane
   starts with the 24-DIP use case icon and an editor displaying the selected
   use case's name. The editor occupies roughly half the available width and
   is read-only except while creating or renaming a use case.
- A draggable vertical splitter separates the left and right panes.
- Beneath the editor is a read-only table with **Name** and **Path** columns,
  displaying the selected use case's Pathviews in use case order. An undefined
  Pathview name is displayed as an empty cell and remains `null` in memory and
  JSON; viewing a use case does not rewrite it.

## Selection and activation

The list is refreshed from files in the configuration directory when the view
opens and sorted by name, ignoring case. Use case filenames follow
[Configuration.md](Configuration.md). The active use case is initially
selected. Clicking a list row selects and displays that use case only; it does
not change the active use case or its tabs. The current in-memory state is used
when displaying the active use case.

Double-clicking a use case row, or pressing Enter on the selected row, activates
it and returns to TabsView. The application preserves BROWSE, closes the old
Fixed tabs without removing their use case entries, and opens the selected
use case's Pathviews as Fixed tabs with default settings. BROWSE is selected.
The toolbar name and subsequent Fixed-tab saves refer to the newly active
use case. Activating the already active use case likewise reloads its Fixed tabs
from its in-memory use case.

The selected use case is validated before changing the active use case or tabs.
An invalid, missing, or unreadable use case is reported and not overwritten;
its selection does not activate it. If changes to the active use case could not
be saved, the application retries the save before activation and does not
switch if saving still fails. Other use cases are never created merely by
selecting them.

## Use case management

**New** adds an empty in-memory draft named `new` and focuses its name editor.
The draft is not stored in a file until a valid name is confirmed.
Enter saves it under a unique final name, activates it, and returns to
TabsView with only BROWSE. The name `new` is reserved, regardless of case.
Entering that name opens a dialog to retry or cancel the draft. Escape also
discards the draft, without creating or deleting a file, and restores the
previous selection. If the previous active use case cannot be saved, activation
is stopped and the newly created use case remains available in UseCasesView.

**Edit** makes the selected use case name editable. Enter renames its file and
JSON name, retaining its Pathviews and additional JSON properties, then returns
keyboard focus to the use case list. Renaming the active use case also updates
the toolbar and the active use case store; its tabs are retained. Escape
restores the original name. A case-only rename is allowed. During either edit,
the use case list and actions are disabled, and the use case icon cannot switch
to TabsView until the edit is committed or canceled.

Characters that Windows forbids in filenames, including `\ / : * ? " < > |`
and control characters, are removed as they are typed or pasted. Leading and
trailing whitespace is trimmed on confirmation. Empty, reserved, duplicate,
or otherwise unusable names are rejected without overwriting an existing
use case, and the editor remains available. Names are compared ignoring case,
except that an existing use case may be renamed by changing only its case.

**Delete** asks for confirmation before removing the selected use case. When
the active use case is deleted, `default` is loaded or created first and then
activated; UseCasesView remains open with `default` selected. If preparing
`default` fails, the selected use case is not deleted. Deleting another use case
leaves the active use case unchanged and selects it. `default` cannot be
renamed or deleted. **Edit** requires a successfully loaded, non-default
selection; **Delete** requires a non-default selection.

## Acceptance checks

1. Click the use case icon and verify UseCasesView replaces TabsView, the
   heading, actions, badge, list, read-only name editor, splitter, and table
   appear, and the active use case is selected. Verify the badge matches the
   content-pane badge and precedes Edit and Delete. Click the icon again and
   verify the original tabs and selected tab remain unchanged.
2. With two valid use case files containing different Pathviews, single-click
   the other use case. Check its name and rows are displayed, its null names are
   blank, and the toolbar and existing tabs still belong to the active use case.
3. Double-click that use case. Check TabsView returns, BROWSE remains first and
   selected, previous Fixed tabs are gone, and the selected use case's Fixed
   tabs and toolbar name appear. Confirm neither use case was modified by the
   switch itself.
4. Pin and close a folder after switching. Check only the active use case is
   updated. Activate the previous use case and verify its original tabs return.
5. Drag the splitter. Verify the panes resize and the table remains usable.
   Check an invalid or unavailable use case produces an
   error without replacing the active tabs or overwriting its file.
6. Create a use case and check that `new` cannot be saved, Escape and the dialog
   Cancel discard the draft, and invalid filename characters are filtered when
   typed or pasted. Confirm an existing name cannot be overwritten. With a
   valid name, check the new use case is active and only BROWSE remains.
7. Rename an inactive and an active use case, including a case-only rename;
   check the filename, JSON, toolbar, Pathviews, extra fields, and list focus
   after Enter. Cancel an edit and confirm the original name remains. Check
   switching views is blocked while a name is being edited.
8. Cancel and confirm a deletion. Confirm deleting the active use case
   activates `default` and that `default` cannot be renamed or deleted.