# Open with Running App Specification

## Purpose and scope

Identify applications registered to open a file type, find their visible running
windows, and transfer files to a chosen window without starting another instance.
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
- Selecting a window invokes the resourceful Open dialog and drop fallback
  operation for that window. It does not change the clipboard.
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
- Only a newly created foreground standard Win32 dialog owned directly by the
  selected window in the same process is considered. The method looks for the
  standard file name edit control and an enabled Open button; the supported
  button names are currently `Open` and `Öffnen`. It enters the full Unicode
  path, verifies it, and posts the button click. Other dialogs are left alone.
- Success means the click was posted, not that the file opened or that an
  existing document was unaffected. Opening may replace existing content,
  display additional prompts, or create another window. Unsupported dialogs,
  shortcuts, languages and foreground restrictions cause failure. The caller
  must handle any dialog left open on failure.
- The Content Menu's resourceful operation uses `Ctrl+O` by default. It uses
  the bare `O` variant only when explicitly configured for the application.

### Combined operation

- The embedded [running-app-open-methods.json](Assets/running-app-open-methods.json)
  selects a single method for known applications. The selected window's process
  is matched case-insensitively by executable filename and Windows file-version
  company name, independently of installation path and version. These metadata
  are not a security identity; renamed executables or changed/missing company
  names do not match. Supported names are `LetOpenByDialog`,
  `LetOpenByDialogUsingO`, and `DropToAppWindow`. An invalid method or duplicate
  executable/company pair is an error. Word and Acrobat Reader currently use
  `LetOpenByDialog` as an unverified placeholder, not a proven working method.
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
- The result reports each attempted dialog, the optional drop, and any error.
  It does not change the clipboard or use paste. A
  delayed dialog can still appear after the timeout, and neither a posted click
  nor an accepted drop proves the file was opened. The fallback uses the center
  of the client area and can import or insert into an existing document.

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

- The accessor tests cover association and window discovery, clipboard
  validation and key delivery, and drops to a test window, including explicit
  and invalid positions.
- Integration tests exercise paste and drop with Audacity and IrfanView. In the
  observed tests, Audacity opened the generated WAV by either method; IrfanView
  opened the generated JPEG by drop but did not open a clipboard file list via
  paste. These observations are application-specific, not universal promises.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application
  Audacity -Transfer OpenDialog` tests the Open dialog using a generated WAV
  with a Unicode name. In the observed environment Audacity opened the file;
  IrfanView did not present a supported dialog in response to `Ctrl+O`.
- `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application
  IrfanView -Transfer OpenDialogO` tests the `O` variant with a generated JPEG.
  In the observed environment IrfanView opened the file.
- Resourceful integration tests check dialog submission without a drop in
  Audacity and a fallback drop in IrfanView. `ResourcefulOpen.Tests.ps1` checks
  multi-file fallback and suppression when an unsupported dialog remains open.
- The same integration script supports `Word` (DOCX), `VLC` (MP4), and
  `AcrobatReader` (PDF), for example:
  `pwsh -NoProfile -STA -File tests/AudacityPaste.Integration.ps1 -Application VLC -Transfer Resourceful`.
  It generates the DOCX and PDF and copies the bundled MP4 test video. The
  applications must be installed and recommended for the corresponding file
  type. Word's test also checks the document text and rejects blocking dialogs.
- In the observed environment VLC opened the MP4 through the resourceful
  action. Direct drops opened the DOCX in Word and the PDF in Acrobat Reader.
  Before application-specific routing was added, Word's Ctrl+O attempt was
  followed by a drop that apparently clicked a recent document and opened a
  conversion dialog. Reader's Open dialog belongs to a helper process and was
  not recognized; its fallback was suppressed while the dialog remained open.
  The current Word and Reader entries are placeholders and do not fall back to
  drop when their configured method fails.
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
- [CompareOpenWithApps.ps1](tests/CompareOpenWithApps.ps1)
- [OpenInRunningAppInteraction.Tests.ps1](tests/OpenInRunningAppInteraction.Tests.ps1)
- [AudacityPaste.Integration.ps1](tests/AudacityPaste.Integration.ps1)