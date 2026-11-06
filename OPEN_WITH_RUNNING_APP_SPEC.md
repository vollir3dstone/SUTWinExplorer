# Open with Running App Specification

## Purpose and scope

Identify applications registered to open a file type, find their visible running
windows, and transfer files to a chosen window without starting another instance.
The target application decides whether the transfer opens the file, imports its
contents, or performs another action. This specification describes the current
accessor and its observed behavior; it does not prescribe a user interface or
claim that every application supports opening files this way.

## Applications and windows

- Discover registered applications from the Windows Shell associations for the
  file's extension. A path without an extension has no matching applications.
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

The caller can choose clipboard paste, programmatic drag and drop, or the
combined operation below. Neither method guarantees that the target will open
the file as a separate document.

### Combined operation

- `OpenInRunningAppResourcefully` attempts paste first and then attempts drop,
  regardless of whether paste reports success or failure. This is not a
  fallback based on detecting whether a file was opened.
- The caller supplies the target window and file paths. Paste is attempted only
  when the clipboard contains the same existing file paths in the same order
  (case-insensitive comparison). A mismatch or clipboard read failure skips
  paste but does not prevent the drop attempt. The operation does not change or
  restore the clipboard.
- The result reports the paste and drop outcomes separately. Paste success
  means the keystroke was sent; drop success means the drop was accepted.
  Neither result proves that a file was opened. Sending the keystroke before
  starting the drop does not guarantee when the target processes it.
- Both transfers may be acted on. The target can open or import the same file
  twice, or insert it into an existing document. The drop uses the center of
  the target window's client area and can affect a different control than paste.

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
- The combined mode is also exercised with IrfanView; it verifies that the
  paste was sent, the drop was accepted, and the JPEG appeared in the target.
- Integration tests close their target applications normally. They must not
  force-close an application or automatically discard existing user work;
  only a confirmed test-generated project in a test-started Audacity instance
  may be dismissed without saving.

## References

- [RunningAppsAccessor.cs](RunningAppsAccessor.cs)
- [RunningAppsAccessor.Tests.ps1](tests/RunningAppsAccessor.Tests.ps1)
- [AudacityPaste.Integration.ps1](tests/AudacityPaste.Integration.ps1)