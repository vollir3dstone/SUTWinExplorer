# Configuration

## Location and instance

KIS Explorer stores user configuration under `%APPDATA%\KIS Explorer`, using
the Windows roaming application-data directory. The directory is created when
needed. A machine-wide named mutex permits only one KIS Explorer instance at a
time, including across Windows user sessions. A second launch reports that the
application is already running and exits; its command-line path is not forwarded.

## Profiles

The application always has one active profile during normal operation. The
internal model allows multiple profiles later, but this version loads only
`default`, activates it automatically, and provides no profile selection or
profile-name display. Its file is:

```text
%APPDATA%\KIS Explorer\Profile „default“.kisexplorer.json
```

The filename consists of `Profile `, the profile name enclosed in `„` and
`“`, and `.kisexplorer.json`. The default profile is created with an empty
`Pathviews` array if its file does not exist. Its JSON format is:

```json
{
  "_type": "KIS Explorer profile",
  "ProfileName": "default",
  "Pathviews": [
    {
      "_type": "Pathview",
      "Name": null,
      "Path": "C:\\Example\\Folder",
      "ActionOnProfileActivation": "open"
    }
  ]
}
```

`Name` is the optional Pathview name; JSON `null` means undefined. This version
does not display or edit it. `Path` is an absolute Windows filesystem path,
not a localized display name. The only supported activation action is `open`.
Required properties must be present, types and values must match the example,
and normalized paths must not be duplicated case-insensitively. Additional
JSON properties are retained when the profile is saved. Invalid or unreadable
profiles are reported and left untouched; the application does not replace
them with an empty profile.

## Activation and synchronization

- Start BROWSE as the first and selected tab, preserving its existing startup
  path and command-line behavior. Restore the profile's Pathviews in array
  order as non-browsable Fixed tabs with the usual default view settings.
- Shell views initialize when their tab is displayed. A path that cannot be
  reached is marked in the tab; its profile entry remains until explicitly
  closed. A failure from the Shell is likewise marked, without deleting it.
- A newly pinned filesystem location is added after its navigation succeeds.
  Pinning an already open location selects its tab and does not add a duplicate.
  Closing a Fixed tab removes its associated entry immediately. Closing the
  application does not remove its tabs from the profile.
- Internal folder renames update associated profile paths after successful
  location updates, including affected descendants. As with existing history
  behavior, external renames are not tracked as internal renames.
- The virtual Shell location **This PC** cannot be pinned as a Fixed tab.
  BROWSE is never stored. Colors, filter settings, sort settings, selected tab,
  and navigation history are not profile fields.
- Changes are serialized to a temporary file in the same directory and then
  replace the profile file. Save errors are reported; the in-memory change
  remains available for a later save, while the previous file is not
  intentionally replaced with incomplete JSON.

## Acceptance checks

1. On a clean configuration, start the app and check the empty `default` file,
   BROWSE selection, filename, and valid JSON.
2. Pin two folders, confirm their entries and `Name: null`, restart, and
   confirm both Fixed tabs return in order with default settings and BROWSE
   selected. Pin an existing path again and confirm no duplicate is added.
3. Close a Fixed tab, check its entry is removed immediately, and restart to
   confirm it stays closed. Closing the application must not remove other tabs.
4. Rename a pinned folder or one of its ancestors using the application's
   tree/list rename command and check the corresponding saved path after the
   new location opens successfully.
5. Add an unavailable path to the profile, restart, and check its tab is marked
   and its entry remains, including after selecting it and restarting again.
   Close the marked tab and confirm that its entry is removed.
6. Navigate to **This PC** and verify **Pin** is disabled. Navigate to a
  filesystem folder and verify **Pin** becomes available again. Start a second
  app instance and verify it reports the existing instance and exits.
7. Test malformed JSON, invalid or duplicate entries, an unreadable profile,
   and a failed save. Check the error is visible and the existing file is not
   silently overwritten. Confirm unknown JSON fields survive a successful save.

`tests/ProfileConfiguration.Tests.ps1` exercises the profile store in an
isolated temporary directory; the tab, Shell, and instance checks above still
require a Windows GUI session.