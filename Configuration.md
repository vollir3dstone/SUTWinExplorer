# Configuration

## Location and instance

KIS Explorer stores user configuration under `%APPDATA%\KIS Explorer`, using
the Windows roaming application-data directory. The directory is created when
needed. A machine-wide named mutex permits only one KIS Explorer instance at a
time, including across Windows user sessions. A second launch reports that the
application is already running and exits; its command-line path is not forwarded.

## Opening in running applications

The per-application opening methods are defined in
[running-app-open-methods.json](Assets/running-app-open-methods.json). This JSON
is embedded in the application at build time, not stored in the user
configuration directory or reloaded at runtime. Changing it requires rebuilding
the application. Matching, supported methods, fallback behavior, and limitations
are described in [OPEN_WITH_RUNNING_APP_SPEC.md](OPEN_WITH_RUNNING_APP_SPEC.md).

## Interface strings

The application's neutral English strings are in [Assets/Strings/Strings.resx](Assets/Strings/Strings.resx).
Resource IDs describe the interface area and control or action; menu action IDs
are generally used as the final part of `BaseMenu_Action_<id>` or
`ContentMenu_Action_<id>`. The Shell-compatible `opencontaining` action uses
the descriptive resource ID `ContentMenu_Action_OpenContainingDirectory`.
A localized resource file,
such as `Assets/Strings/Strings.de.resx`, can provide values for the same IDs. .NET selects
resources using `CurrentUICulture` and falls back to the neutral file for
missing translations. English and German resource files are supplied. The
Interface setting `LanguageSelection` selects English or the system UI language;
a changed selection takes effect when the application is restarted.

There is no live language switching. XAML strings are
resolved when controls are created; menu and dialog strings are resolved when
those are created. Windows Shell labels and operating-system error messages
come from Windows. Some lower-level technical error messages remain in English.
Resource files are compiled into the application; changing them requires a
rebuild.

## Pathview action groups

The gear button at the far left of the top toolbar opens the Configuration
dialog. Its checkboxes change independent settings for all Pathviews.
Apply saves the settings and immediately updates open Pathviews; newly opened
Pathviews use the same settings. Cancel or closing the dialog makes no changes.

The settings are stored in `%APPDATA%\KIS Explorer\KIS Explorer Configuration.kisexplorer.json`.
On first startup the file is created with all flags set to `false`:

```json
{
  "_type": "KIS Explorer Configuration",
  "_version": "1.01",
  "Interface": {
    "ShowDirectoryRowActionButtons": false,
    "ShowDirectoryColumnActionButtons": false,
    "ShowSelectedItemsActionButtons": false,
    "EnableInternalItemTransfers": false,
    "LanguageSelection": "English"
  }
}
```

The three action-group flags, the type, version and Interface object are required.
An existing configuration without `EnableInternalItemTransfers` loads with it
set to `false`; the next save writes the flag. When present it must be a Boolean.
An absent `LanguageSelection` defaults to `English` and is written on the next
save. The permitted values are `English` and `System default`.
Invalid,
unreadable or unsupported configuration is reported at startup and left
untouched. Unknown properties are retained when saving. Saving uses a temporary
file followed by replacement; on failure the previous settings remain active
and an error is reported. The file is loaded at startup, not monitored for
external changes during a session.

| Property | When `true` |
| --- | --- |
| `ShowDirectoryRowActionButtons` | Shows Move mark item, Rename and Relocate on the right of the path header. Other header controls, including the color picker, retain their normal visibility. |
| `ShowDirectoryColumnActionButtons` | Shows the New, clipboard paste and transfer buttons under DIRECTORY. The sidebar, heading, counts and status remain visible when false. |
| `ShowSelectedItemsActionButtons` | Shows the FOR SELECTED row above the content table. When false, the row and its spacing are collapsed. Internal transfer buttons in the row also require `EnableInternalItemTransfers`. |
| `EnableInternalItemTransfers` | Offers internal Link, Copy and Move actions in context menus and action-button groups. When false, those actions are hidden; Shell clipboard transfers and other actions remain available. |

The Language radio buttons select `English` or `System default`; the selection
is saved on Apply and takes effect on the next application start.

The action-group checkboxes do not affect one another or context-menu actions.
Disabling internal transfers preserves a prepared internal transfer; it becomes
available again when the setting is re-enabled. While disabled, that hidden
preparation does not block Delete. The flag applies independently of the three
action-group visibility settings.

## Use cases

The application always has one active use case during normal operation. It
loads and activates `default` at startup. The active use case icon and name
appear after the configuration button and before the navigation buttons. The icon
opens [UseCasesView](UseCasesView.md), where use cases can be created,
renamed, deleted, inspected, and activated. The default use case file is:

```text
%APPDATA%\KIS Explorer\Use case „default“.kisexplorer.json
```

The filename consists of `Use case `, the use case name enclosed in `„` and
`“`, and `.kisexplorer.json`. The default use case is created with an empty
`Pathviews` array if its file does not exist. Its JSON format is:

```json
{
  "_type": "KIS Explorer use case",
  "UseCaseName": "default",
  "Pathviews": [
    {
      "_type": "Pathview",
      "Name": null,
      "TabColor": "#FF85ADE9",
      "Path": "C:\\Example\\Folder",
      "ActionOnUseCaseActivation": "open"
    }
  ]
}
```

`TabColor` is the Fixed Pathview header and tab background color in
`#AARRGGBB` hexadecimal format. `null` or an absent property uses the default
appearance, so existing use cases remain compatible. Selecting a color saves it
to the active use case; it is restored when the use case is activated, including
for unavailable paths. A color chosen before initial navigation completes is
included when the Pathview entry is created. Invalid color values make the
use case invalid and are not overwritten.

`Name` is the optional custom Pathview name; JSON `null` means undefined.
UseCasesView displays undefined names as empty cells without changing them.
The Fixed Pathview header displays `(Undefined custom name)` as a placeholder
when undefined. Enter, focus loss, or a click outside the editor commits the
name to the active use case. Enter moves keyboard focus to the Shell content
when available; an outside click preserves the target's focus and action, or
focuses Shell content when the target does not take focus. On
opening a Fixed tab, the name editor is not initially focused; focus is moved
to the Shell content when available. An empty editor stores `null`, while
Escape restores the last committed name. Non-empty names are not trimmed.
BROWSE has no custom-name editor. `Path` is an absolute Windows filesystem
path, not a localized display name. The only supported activation action is `open`.
Required properties must be present, types and values must match the example,
and normalized paths must not be duplicated case-insensitively. Additional
JSON properties are retained when the use case is saved. Invalid or unreadable
use cases are reported and left untouched; the application does not replace
them with an empty use case.

Use case names cannot contain Windows-invalid filename characters. The name
`new` is reserved for an unsaved draft, and names must be unique without regard
to case; changing only the case of an existing use case name is allowed. The
editor trims surrounding whitespace on confirmation. The `default` use case
cannot be renamed or deleted. Renaming updates the filename and JSON name
without discarding Pathviews or additional fields; deleting the active use case
activates `default`. Creating a use case activates it with only BROWSE, provided
the previous active use case can be saved.

## Activation and synchronization

- Start BROWSE as the first and selected tab, preserving its existing startup
  path and command-line behavior. Restore the use case's Pathviews in array
  order as non-browsable Fixed tabs with the usual default view settings.
- Activating another use case replaces only the Fixed tabs, preserves BROWSE,
  selects it, and does not remove entries from the previous use case. Use case
  selection and activation are specified in [UseCasesView.md](UseCasesView.md).
- Shell views initialize when their tab is displayed. A path that cannot be
  reached is marked in the tab; its use case entry remains until explicitly
  closed. A failure from the Shell is likewise marked, without deleting it.
- A newly pinned filesystem location is added after its navigation succeeds.
  Pinning an already open location selects its tab and does not add a duplicate.
  Closing a Fixed tab removes its associated entry immediately. Closing the
  application does not remove its tabs from the use case.
- Committing a Fixed Pathview's custom name updates its associated entry in
  the active use case and immediately updates the tab title without changing
  its path. A name entered before the initial navigation completes is included
  when the entry is created. If the name is undefined, the tab title falls
  back to the shortened path.
- Identified folder renames and internal Shell moves update associated use case
  paths after successful location updates, including affected descendants.
  External moves reported only as separate deletion and creation events cannot
  be identified reliably.
- The virtual Shell location **This PC** cannot be pinned as a Fixed tab.
  BROWSE is never stored. Filter settings, sort settings, selected tab,
  and navigation history are not use case fields.
- Changes are serialized to a temporary file in the same directory and then
  replace the use case file. Save errors are reported; the in-memory change
  remains available for a later save, while the previous file is not
  intentionally replaced with incomplete JSON.

## Acceptance checks

1. On a clean configuration, start the app and check the empty `default` file,
  BROWSE selection, filename, valid JSON, and the active use case name before
  the path editor.
2. Pin two folders, confirm their entries and `Name: null`, restart, and
   confirm both Fixed tabs return in order with default settings and BROWSE
   selected. Pin an existing path again and confirm no duplicate is added.
3. Close a Fixed tab, check its entry is removed immediately, and restart to
   confirm it stays closed. Closing the application must not remove other tabs.
4. Rename a pinned folder or one of its ancestors using the application's
   tree/list rename command and check the corresponding saved path after the
   new location opens successfully.
5. Add an unavailable path to the use case, restart, and check its tab is marked
   and its entry remains, including after selecting it and restarting again.
   Close the marked tab and confirm that its entry is removed.
6. Navigate to **This PC** and verify **Pin** is disabled. Navigate to a
  filesystem folder and verify **Pin** becomes available again. Start a second
  app instance and verify it reports the existing instance and exits.
7. Test malformed JSON, invalid or duplicate entries, an unreadable use case,
   and a failed save. Check the error is visible and the existing file is not
   silently overwritten. Confirm unknown JSON fields survive a successful save.
8. For a Fixed tab, verify the gray undefined-name placeholder, an unfocused
  editor on opening, and Shell-content focus when available. Enter a long
  custom name and press Enter; confirm the entire name labels the tab, the
  use case stores it, and Shell content receives focus. Verify Escape cancels
  an uncommitted edit, clicking another control commits without stealing its
  focus, and clicking a non-focusable area commits and leaves the editor.
9. Clear the name and confirm JSON `null`, the placeholder, and the shortened
  path label return. Switch use cases and reactivate the original use case to
  verify saved names and nulls are restored. Confirm UseCasesView shows null
  names as empty cells, BROWSE has no name editor, and an unavailable path
  retains its `!` marker before either a custom-name or path label.
10. Set different colors on Fixed tabs and confirm `TabColor` is saved for each.
  Switch use cases and reactivate the original, then restart; the header and
  selected and unselected tab backgrounds retain their colors. Check that an
  unavailable path retains its color and that a legacy entry without
  `TabColor` keeps the default appearance.

`tests/UseCaseConfiguration.Tests.ps1` exercises the use case store in an
isolated temporary directory; the tab, Shell, and instance checks above still
require a Windows GUI session.