# Open with Running App Specification

## Purpose and scope

Identify applications registered to open a file type, find their visible running
windows, and transfer files using a method appropriate for the selected application.
The target application decides whether the transfer opens the file, imports its
contents, or performs another action. This specification describes the current
ContentView action, accessor and observed behavior; it does not claim that every
application supports opening files this way.

## Content menu

- The item Content Menu starts with Shell **Open**, **Open in running app...**,
  and Shell **Open with**, in that order. Unavailable Shell commands have a
  disabled placeholder. The running-app submenu lists each discovered window as `App name - Window title`, sorted
  by application and then window title. Each entry shows the app icon when
  available, falling back to the window icon. Untitled windows use `Untitled window`.
- For a multiple-file selection, show applications registered for every selected
  file type. Windows may include generic handlers in its association results.
  Selections containing a directory and selections with no matching running
  windows have a disabled submenu. The action is not added to the background,
  sidebar or Shift menus.
- Selecting a window invokes the resourceful operation for that application and
  window. It does not change the clipboard.
- Do not show a transfer result dialog, including on failure. Technical errors
  can be written to the diagnostic trace. A submitted dialog or accepted drop is not
  a guarantee that the target opened the files.

## Applications and windows

- Discover registered applications from the Windows Shell associations for the
  file's extension. A path without an extension has no matching applications.
- `GetRegisteredApps` uses `SHAssocEnumHandlers` with `ASSOC_FILTER_NONE` and
  returns all handlers. `GetRecommendedApps` uses the same Shell API
  with `ASSOC_FILTER_RECOMMENDED`, returning the handlers Windows marks as
  recommended for the type. `GetAppsToChooseFrom` currently delegates to
  `GetRecommendedApps`; the GUI and running-app lookup use this wrapper for
  every selected file type, allowing the selection strategy to be changed.
- The Shell's Open With registration sources include `OpenWithProgids` and
  application `SupportedTypes`; recommendations may also change after user
  choices. The Shell can show additional non-recommended applications. The
  recommended filter is a comparison candidate, not a guarantee of matching
  every entry or the ordering of a particular Windows Open With menu or dialog.
  The Shell's owner-drawn Open With submenu is populated dynamically. On the
  development machine, the initialized `.txt` submenu contained the same six
  distinct app names as the recommended query, plus a duplicate LibreOffice
  entry. This observation does not establish equivalence for other file types.
- Compare the methods without changing the GUI using
  `pwsh -NoProfile -STA -File tests/CompareOpenWithApps.ps1 -Path .wav`.
- Microsoft documents [handler enumeration and filters](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-shassocenumhandlers),
  [recommendation status](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-iassochandler-isrecommended),
  [OpenWithProgids](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-include-an-application-on-the-open-with-dialog-box),
  and [SupportedTypes](https://learn.microsoft.com/en-us/windows/win32/shell/app-registration#using-the-applications-subkey).
- Return an application identifier and display name for each association. An
  identifier is used for matching and is not necessarily an executable path.
- When the association handler exposes `IObjectWithAppUserModelID`, retain its
  AppUserModelID separately from the handler identifier. For an
  `ApplicationFrameWindow`, match a visible `Windows.UI.Core.CoreWindow`
  descendant by its process AppUserModelID; do not identify it by window title
  or by the shared host process alone.
- LibreOffice launcher executables are matched to `soffice.bin` in the same
  installation directory when its company is The Document Foundation.
- For each registered application, identify its visible, uncloaked top-level
  windows, excluding tool windows. Return each window's handle and title.
- Return running applications only when at least one such window is found.
  An application may have multiple windows; the caller selects the target.
- Window handles and the set of running applications are transient. Validate
  the selected window again when transferring; a previously listed window may
  have disappeared or become unavailable.

## Transfer methods

The caller can choose clipboard paste, programmatic drag and drop, the Open
dialog method, or the combined operation below. No method guarantees that the target will open
the file as a separate document.

### Open dialog

- `LetOpenByDialog` accepts a target window and one existing file.
  It activates the window and sends `Ctrl+O`, without changing the clipboard.
- `LetOpenByDialogUsingO` uses the same dialog handling but sends `O` without
  modifiers. It is intended for applications whose Open shortcut is `O`.
  In an application with an editable focused control, the key can instead
  change existing content; callers must select this method with care.
- `LetOpenByDialogUsingCtrlF12` uses the same dialog handling with `Ctrl+F12`.
  This is an alternative for Word, noted in its configuration entry.
- Only a newly created foreground standard Win32 dialog is considered. It may
  belong to another process when it is directly owned by the selected window,
  which was visible and enabled before the shortcut and remains visible but
  disabled while the dialog is open. The dialog process identity is checked
  again before entering the path and submitting it. Within the selected
  window's process, a different existing owner is also accepted when it and the
  target were the only visible process windows before the shortcut, were both
  enabled then and remain visible but disabled while the dialog is open. Tool
  windows owned by the target are excluded from this count. Other independent
  windows appearing later make the match ambiguous. The owner and window state
  are checked again before entering the path and submitting the dialog. The method
  looks for the standard file name edit control and an enabled Open button; the supported
  button names are currently `Open` and `Öffnen`. It enters the full Unicode
  path, verifies it, and posts the button click. Other dialogs are left alone.
- Success means the click was posted, not that the file opened or that an
  existing document was unaffected. Opening may replace existing content,
  display additional prompts, or create another window. Unsupported dialogs,
  shortcuts, languages and foreground restrictions cause failure. The caller
  must handle any dialog left open on failure.
- The Content Menu's resourceful operation uses `Ctrl+O` by default. It uses
  the bare `O` variant only when explicitly configured for the application.
- The search for a supported dialog times out after 0.7 seconds. This timeout
  applies to each of the dialog shortcuts above.

### Shell open

- `OpenByShellOpen` accepts a registered application and one existing file.
  It invokes the matching Windows Shell association handler for that file type,
  as in Open With, independently of the default application. A missing handler
  is an error; it never falls back to another application. It may start a
  process, reuse one, or show additional UI. `Dispatched` means that the
  selected handler accepted the request, not that the file opened or that an
  existing application instance was reused. Subsequent application dialogs
  are left to the application and its user.
- The resourceful operation can select this method through per-app
  configuration. It cannot guarantee delivery to a particular window selected
  in the running-app menu.

### Combined operation

- The embedded [running-app-open-methods.json](Assets/running-app-open-methods.json)
  selects a single method for known applications. The selected window's process
  is matched case-insensitively by executable filename and Windows file-version
  company name, independently of installation path and version. These metadata
  are not a security identity; renamed executables or changed/missing company
  names do not match. A packaged application can instead be configured by its
  AppUserModelID; the selected window must match that ID directly or through
  its hosted application window. Executable/company configuration takes
  precedence when both match. Supported names are `LetOpenByDialog`,
  `LetOpenByDialogUsingO`, `LetOpenByDialogUsingCtrlF12`, `DropToAppWindow`,
  and `OpenByShellOpen`. An invalid method or duplicate identity is an error.
  Microsoft Office, LibreOffice, Acrobat Reader and Windows Photos currently
  use `OpenByShellOpen` for their configured identities. IrfanView uses
  `DropToAppWindow`; `LetOpenByDialogUsingO` is a slightly slower alternative
  recorded in its JSON entry.
- Configured Shell Open requires a registered application matching the selected
  window's process. It invokes that application's handler on the original STA
  for each file, stops at the first failure, and does not attempt another method.
  Application dialogs shown after dispatch are left alone.
- For a configured application only the configured method is attempted; a
  failed dialog attempt is reported without a fallback drop. For an unknown
  application the default asynchronously attempts `Ctrl+O` for each file.
  After a dialog click is posted, that file is not sent by drop, even though
  submission does not prove that the file opened. Before the next file, it
  waits for the selected window to become ready again; otherwise it stops.
- If a default dialog attempt fails, drop only that file and the remaining files, and
  only if the original target is still foreground, visible, enabled and owned
  by the same process, with no blocking owned dialog or new owned window.
  The state is checked again on the original STA thread before dropping.
  Otherwise leave the dialog alone and report that the drop was skipped.
- The result reports each attempted dialog, the optional drop, any error, and
  for Shell Open each attempted dispatch, including partial results on failure.
  It does not change the clipboard or use paste. A
  delayed dialog can still appear after the timeout, and neither a posted click
  nor an accepted drop proves the file was opened. The fallback uses the center
  of the client area and can import or insert into an existing document.

### Dialog and IrfanView timing measurements

For each application known to support `Ctrl+O`, five measurements were made
on this machine with the application already started and ready. Time was
measured from shortcut injection until a new visible foreground dialog with
the expected owner and process was observed, polling every 2 ms. The dialog's
file name edit and Open button were verified afterwards; the dialog was then
cancelled without submitting a file. Times are rounded to milliseconds.

| Application | Samples | Minimum | Mean | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Audacity | 5 | 174 ms | 180 ms | 196 ms |
| VLC | 5 | 350 ms | 358 ms | 364 ms |
| Resonic | 5 | 412 ms | 431 ms | 456 ms |
| Windows Media Player Legacy | 5 | 352 ms | 385 ms | 432 ms |
| Windows Media Player | 5 | 464 ms | 480 ms | 499 ms |

The measurement observes dialog visibility, not necessarily when all controls
are usable. The longest observation leaves about 201 ms within the 0.7-second
timeout; production polling is every 100 ms. Busy or slower systems can exceed
the timeout, and a late dialog may appear during or after the guarded fallback.

IrfanView was compared separately with an initial image already loaded and a
different image sent to the same window. Five runs per method measured from
invoking the method until its completion and observation of the new filename,
using the integration harness's polling; the visible red marker of the second
image was verified afterwards. Direct center drop took 470-488 ms, averaging
480 ms; the `O` dialog took 509-525 ms, averaging 515 ms. The configured direct
drop was faster in every run on this machine; these are not universal timings.

### Paste by interaction

- `PasteByInteractionToAppWindow` sends `Ctrl+V` to the selected window.
- The caller supplies an existing, nonempty Windows clipboard file list. The
  accessor checks that all listed paths are existing files; it does not prepare
  or restore the clipboard.
- Restore a minimized target window if necessary, bring it to the foreground,
  and send `Ctrl+V`. Report failure if the window cannot be activated or the
  keystroke cannot be sent.
- **Do not click anywhere in the target application and do not choose a mouse
  position for paste.** A click could activate an existing document or another
  control. For example, in Microsoft Word it could cause a subsequent paste to
  insert the file into that document instead of opening the file.
- Avoiding a click does not eliminate that risk: activating a window may leave
  an existing document or control focused, and the target decides what
  `Ctrl+V` means. Foreground activation alone does not ensure the desired
  control has focus or that a file will be opened. No generic guarantee of a
  non-destructive open is made.
- A successful result means the keystroke was sent, not that the target
  accepted the clipboard data or opened a file. Some applications do not open
  clipboard file lists with `Ctrl+V` at all.

### Programmatic drag and drop

- Accept a nonempty list of existing files and a selected target window. Use a
  programmatically initiated Windows drag and drop, independent of the explorer
  GUI or an existing user drag.
- The default drop position is the center of the target window's client area.
  The caller may instead provide explicit client-area coordinates; positions
  outside the client area are rejected.
- A drop is inherently position-dependent and moves the pointer. The target
  control at that position determines how the files are handled. A drop into an
  existing document may import or embed content rather than open a document.
- A successful drop result indicates that the target accepted the drag-and-drop
  operation; it does not prove that the intended document was opened.

## Preconditions and limits

- Clipboard and drag-and-drop operations require an STA thread. Targets must
  be valid, visible, enabled top-level windows. Held mouse buttons or modifier
  keys can prevent the corresponding operation.
- Windows foreground restrictions, inaccessible drop positions, application
  dialogs, application-specific behavior, and security or integrity boundaries
  can prevent a transfer. Report the failure instead of claiming success.
- An enabled target can still have an unsuitable focused control. Do not
  dismiss dialogs, change documents, or close the target application as part of
  the transfer.
- Registered associations and window matching are best-effort discovery, not a
  guarantee that an application can accept either transfer method.

## Verification

The minimum regression gate for changes to opening files in running
applications consists of all eight resourceful integration tests, run
sequentially:

```powershell
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application Audacity -Transfer Resourceful
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application IrfanView -Transfer Resourceful
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application VLC -Transfer Resourceful
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application Resonic -Transfer Resourceful
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application Word -Transfer Resourceful
pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application WindowsMediaPlayerLegacy -Transfer Resourceful
pwsh -NoProfile -STA -File tests/WindowsMediaPlayer.Integration.ps1
pwsh -NoProfile -STA -File tests/WindowsPhotos.Integration.ps1
```

All eight must pass; do not skip a test because its target application is
already running. Close the blocking application before the test, normally if
possible and forcibly if necessary. Forced termination can discard unsaved work.
A blocked or skipped test leaves the minimum gate incomplete.

- The accessor tests cover association and window discovery, clipboard
  validation and key delivery, and drops to a test window, including explicit
  and invalid positions.
- Integration tests exercise paste and drop with Audacity and IrfanView. In the
  observed tests, Audacity opened the test WAV by either method; IrfanView
  opened the test JPEG by drop but did not open a clipboard file list via
  paste. These observations are application-specific, not universal promises.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application
  Audacity -Transfer OpenDialog` tests the Open dialog using a copy of the test WAV
  with a Unicode name. In the observed environment Audacity opened the file;
  IrfanView did not present a supported dialog in response to `Ctrl+O`.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application
  IrfanView -Transfer OpenDialogO` tests the `O` variant with a copy of the test JPEG.
  In the observed environment IrfanView opened the file.
- Resourceful integration tests check dialog submission without a drop in
  Audacity and the configured direct drop in IrfanView. `ResourcefulOpen.Tests.ps1` checks
  multi-file fallback, suppression when an unsupported dialog remains open,
  direct and shared dialog owners, ambiguous or changed window states,
  configured application identities and Shell Open failure handling.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application IrfanView -Transfer Menu -StartWithImage`
  starts IrfanView with the first JPEG and selects the running-app native
  submenu entry for a visually distinct second JPEG from another foreground
  window. It checks both the second filename and the red marker in the visible
  image area. It does not exercise opening the parent context menu.
- The `Resonic` integration test checks both `OpenDialog` and `Resourceful`
  with a test WAV file. In the observed environment, Resonic opened the
  file through its application-owned standard dialog without a fallback drop.
- The Legacy player test submits a silent WAV through the Open
  dialog and observes its process transition to an active audio session. It
  does not independently inspect the current track's filename.
- The modern Windows Media Player test checks discovery of its packaged,
  hosted window before transferring a WAV and checking the displayed track.
  In the observed environment the window is discovered by its handler's
  AppUserModelID, and the WAV is opened through its cross-process standard
  Open dialog without a fallback drop.
- The Windows Photos test matches the registered JPEG handler and its window,
  dispatches the image through the configured Shell handler, and checks that
  the uniquely named image appears. Shell Open can display a different window;
  the test does not require the selected window to be reused. Complete any
  first-run setup manually before running the test.
- The WAV, JPEG and MP4 media fixtures live in `tests/resources`. Each test
  copies the fixture to a temporary path with a unique filename before use
  and removes its copy during cleanup, including when the test fails. A file
  still locked by an application can cause cleanup to fail.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application LibreOffice -Transfer Resourceful`
  starts a test-owned Writer instance and passes two generated DOCX files in
  one resourceful operation. In the observed environment, both selected
  LibreOffice Shell handler requests were dispatched without dialog or drop
  fallback, and both documents appeared in Writer windows. The test does not
  alter the Windows default application.
- The same script supports `Excel`, `PowerPoint`, `Access`, `Calc`, `Impress`,
  `Draw`, `Math` and `Base` with `-Transfer Resourceful`. In the observed
  environment each opened its test document; Excel, PowerPoint, Calc, Impress,
  Draw and Math each opened two. Base uses temporary copies of LibreOffice's
  bundled example database. Access can open a document in another process.
  The tests cover these particular files and handlers, not every file format.
- Integration tests start or explicitly select the target application first,
  wait at least five seconds after window discovery, and check that the process
  and window are still ready immediately before transferring files. They do not
  require Shell Open to reuse the selected process or window.
- Visio could not be tested because its first-start privacy dialog blocked the
  test; no privacy choice was made. Outlook and OneNote were not tested because
  isolated test profiles were not available. Publisher, Project and InfoPath
  were not installed in the observed environment.
- The same integration script supports `Word` (DOCX), `VLC` (MP4), and
  `AcrobatReader` (PDF), for example:
  `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application VLC -Transfer Resourceful`.
  It generates the DOCX and PDF and copies the bundled MP4 test video. The
  applications must be installed and recommended for the corresponding file
  type. Word's test also checks the document text and rejects blocking dialogs.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application Word -Transfer OpenDialogCtrlF12`
  tests `LetOpenByDialogUsingCtrlF12` with a Unicode DOCX filename. In the
  observed Word version, the document opened with the expected content. The
  resourceful Word and Acrobat Reader tests also opened their documents using
  the configured Shell Open method without a drop.
- Shell-open integration tests for `Word` and `AcrobatReader` start a test
  instance, open two distinct test documents, check both remain open, and
  compare application process IDs before and after the second request. In the
  observed environment, both applications displayed the second document in
  their existing main process. Word used separate document windows; Reader used
  separate tabs. No additional application process remained after three seconds.
  Brief launcher processes can occur and snapshots cannot capture every one.
  These results depend on the registered handler and application configuration
  and are not guarantees for other installations. An additional Word test uses
  an HTML association where Firefox is the default and confirms that the Word
  handler is selected; an application conversion dialog does not invalidate
  the dispatch.
- In the observed environment VLC opened the MP4 through the resourceful
  action. Direct drops opened the DOCX in Word and the PDF in Acrobat Reader.
  Before application-specific routing was added, Word's Ctrl+O attempt was
  followed by a drop that apparently clicked a recent document and opened a
  conversion dialog. Reader's Open dialog belongs to a helper process and was
  not recognized; its fallback was suppressed while the dialog remained open.
  Configured methods do not fall back to drop when they fail.
- Content-menu tests cover window discovery, submenu placement, disabled state,
  and command routing. An IrfanView integration test invokes the content-menu
  action and verifies that the generated JPEG appears in the target window.
- Integration tests refuse to close existing instances; `-UseExisting` must be
  explicitly requested and leaves the application open. Test-started instances
  are closed normally. Only a confirmed test-generated project in a test-started
  Audacity instance may be dismissed without saving. A test-started Word
  conversion dialog or Reader Open dialog may be closed during cleanup.

## References

- [RunningAppsAccessor.cs](RunningAppsAccessor.cs)
- [RunningAppsAccessor.Tests.ps1](tests/RunningAppsAccessor.Tests.ps1)
- [RunningAppsAssociations.Tests.ps1](tests/RunningAppsAssociations.Tests.ps1)
- [ResourcefulOpen.Tests.ps1](tests/ResourcefulOpen.Tests.ps1)
- [CompareOpenWithApps.ps1](tests/CompareOpenWithApps.ps1)
- [OpenInRunningAppInteraction.Tests.ps1](tests/OpenInRunningAppInteraction.Tests.ps1)
- [AudacityPaste.Integration.ps1](tests/AudacityPaste.Integration.ps1)