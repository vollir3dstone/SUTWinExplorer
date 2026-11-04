# ProfilesView

## Purpose and navigation

ProfilesView is a top-level alternative to TabsView. The profile icon at the
left of the application toolbar toggles between them. Opening ProfilesView
replaces the tabs in the main content area without closing or changing them;
clicking the icon again returns to the same tabs. The toolbar remains visible,
and its navigation and path controls are disabled while ProfilesView is shown.

The toolbar name always identifies the active profile, not merely the profile
selected for inspection. BROWSE remains the permanent first tab. The app starts
with the `default` profile active; activating another profile does not change
which profile is selected automatically at the next application startup.

## Layout

- The top row contains **Profiles**, **New**, the **FOR SELECTED:** badge,
  **Edit**, and **Delete**, in that order. The badge uses the same background,
   padding, text formatting, and fixed 24-DIP height as the badge in the content
   pane; its height matches the standard text buttons.
- Below it, the left pane contains a list of profile names. The right pane
   starts with the 24-DIP profile icon and an editor displaying the selected
   profile's name. The editor occupies roughly half the available width and
   is read-only except while creating or renaming a profile.
- A draggable vertical splitter separates the left and right panes.
- Beneath the editor is a read-only table with **Name** and **Path** columns,
  displaying the selected profile's Pathviews in profile order. An undefined
  Pathview name is displayed as an empty cell and remains `null` in memory and
  JSON; viewing a profile does not rewrite it.

## Selection and activation

The list is refreshed from files in the configuration directory when the view
opens and sorted by name, ignoring case. Profile filenames follow
[Configuration.md](Configuration.md). The active profile is initially
selected. Clicking a list row selects and displays that profile only; it does
not change the active profile or its tabs. The current in-memory state is used
when displaying the active profile.

Double-clicking a profile row, or pressing Enter on the selected row, activates
it and returns to TabsView. The application preserves BROWSE, closes the old
Fixed tabs without removing their profile entries, and opens the selected
profile's Pathviews as Fixed tabs with default settings. BROWSE is selected.
The toolbar name and subsequent Fixed-tab saves refer to the newly active
profile. Activating the already active profile likewise reloads its Fixed tabs
from its in-memory profile.

The selected profile is validated before changing the active profile or tabs.
An invalid, missing, or unreadable profile is reported and not overwritten;
its selection does not activate it. If changes to the active profile could not
be saved, the application retries the save before activation and does not
switch if saving still fails. Other profiles are never created merely by
selecting them.

## Profile management

**New** adds an empty in-memory draft named `new` and focuses its name editor.
The draft is not stored in a file until a valid name is confirmed.
Enter saves it under a unique final name, activates it, and returns to
TabsView with only BROWSE. The name `new` is reserved, regardless of case.
Entering that name opens a dialog to retry or cancel the draft. Escape also
discards the draft, without creating or deleting a file, and restores the
previous selection. If the previous active profile cannot be saved, activation
is stopped and the newly created profile remains available in ProfilesView.

**Edit** makes the selected profile name editable. Enter renames its file and
JSON name, retaining its Pathviews and additional JSON properties, then returns
keyboard focus to the profile list. Renaming the active profile also updates
the toolbar and the active profile store; its tabs are retained. Escape
restores the original name. A case-only rename is allowed. During either edit,
the profile list and actions are disabled, and the profile icon cannot switch
to TabsView until the edit is committed or canceled.

Characters that Windows forbids in filenames, including `\ / : * ? " < > |`
and control characters, are removed as they are typed or pasted. Leading and
trailing whitespace is trimmed on confirmation. Empty, reserved, duplicate,
or otherwise unusable names are rejected without overwriting an existing
profile, and the editor remains available. Names are compared ignoring case,
except that an existing profile may be renamed by changing only its case.

**Delete** asks for confirmation before removing the selected profile. When
the active profile is deleted, `default` is loaded or created first and then
activated; ProfilesView remains open with `default` selected. If preparing
`default` fails, the selected profile is not deleted. Deleting another profile
leaves the active profile unchanged and selects it. `default` cannot be
renamed or deleted. **Edit** requires a successfully loaded, non-default
selection; **Delete** requires a non-default selection.

## Acceptance checks

1. Click the profile icon and verify ProfilesView replaces TabsView, the
   heading, actions, badge, list, read-only name editor, splitter, and table
   appear, and the active profile is selected. Verify the badge matches the
   content-pane badge and precedes Edit and Delete. Click the icon again and
   verify the original tabs and selected tab remain unchanged.
2. With two valid profile files containing different Pathviews, single-click
   the other profile. Check its name and rows are displayed, its null names are
   blank, and the toolbar and existing tabs still belong to the active profile.
3. Double-click that profile. Check TabsView returns, BROWSE remains first and
   selected, previous Fixed tabs are gone, and the selected profile's Fixed
   tabs and toolbar name appear. Confirm neither profile was modified by the
   switch itself.
4. Pin and close a folder after switching. Check only the active profile is
   updated. Activate the previous profile and verify its original tabs return.
5. Drag the splitter. Verify the panes resize and the table remains usable.
   Check an invalid or unavailable profile produces an
   error without replacing the active tabs or overwriting its file.
6. Create a profile and check that `new` cannot be saved, Escape and the dialog
   Cancel discard the draft, and invalid filename characters are filtered when
   typed or pasted. Confirm an existing name cannot be overwritten. With a
   valid name, check the new profile is active and only BROWSE remains.
7. Rename an inactive and an active profile, including a case-only rename;
   check the filename, JSON, toolbar, Pathviews, extra fields, and list focus
   after Enter. Cancel an edit and confirm the original name remains. Check
   switching views is blocked while a name is being edited.
8. Cancel and confirm a deletion. Confirm deleting the active profile
   activates `default` and that `default` cannot be renamed or deleted.