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

- The top row is headed **Profiles**.
- Below it, the left pane contains a list of profile names. The right pane
   starts with the 24-DIP profile icon and a read-only editor displaying the
   selected profile's name. The editor occupies roughly half the available
   width and is read-only for every profile, including `default`.
- A draggable vertical splitter separates the left and right panes.
- Beneath the editor is a read-only table with **Name** and **Path** columns,
  displaying the selected profile's Pathviews in profile order. An undefined
  Pathview name is displayed as an empty cell and remains `null` in memory and
  JSON; viewing a profile does not rewrite it.

## Selection and activation

The list is refreshed from files in the configuration directory when the view
opens. Profile filenames follow [Configuration.md](Configuration.md). The
active profile is initially selected. Clicking a list row selects and displays
that profile only; it does not change the active profile or its tabs. The
current in-memory state is used when displaying the active profile.

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

## Acceptance checks

1. Click the profile icon and verify ProfilesView replaces TabsView, the
   heading, list, read-only name editor, splitter, and table appear, and the
   active profile is selected. Click the icon again and verify the original
   tabs and selected tab remain unchanged.
2. With two valid profile files containing different Pathviews, single-click
   the other profile. Check its name and rows are displayed, its null names are
   blank, and the toolbar and existing tabs still belong to the active profile.
3. Double-click that profile. Check TabsView returns, BROWSE remains first and
   selected, previous Fixed tabs are gone, and the selected profile's Fixed
   tabs and toolbar name appear. Confirm neither profile was modified by the
   switch itself.
4. Pin and close a folder after switching. Check only the active profile is
   updated. Activate the previous profile and verify its original tabs return.
5. Drag the splitter. Verify the panes resize, the table remains usable, and
   names cannot be edited. Check an invalid or unavailable profile produces an
   error without replacing the active tabs or overwriting its file.