# SutShell API

## Purpose and status

`SutShell` is the ContentView's boundary for filesystem access and operating-system
shell services. The first implementation is internal and Windows/WPF
specific. It is not yet a portable interface or a complete replacement for all
Windows Shell features. Other application components still use their existing
Shell helpers directly.

## Current operations

| Operation | Contract |
| --- | --- |
| `EnsureDirectoryAccessible(path)` | Checks that enumeration can start; recognizes the virtual This PC location. Throws on access or enumeration errors. It cannot guarantee that a later enumeration succeeds. |
| `OpenDirectoryAsync(path, showDirectories, hideInternal, namePattern, cancellationToken)` | Prepares a snapshot of immediate children and exposes its count. The filtered index is sorted directories first, then by Shell display name. This PC contains drive roots. Enumeration errors propagate; inaccessible individual items may be skipped. |
| `GetDirectoryRangeAsync(snapshot, start, count, cancellationToken)` | Returns complete entries for the requested zero-based range in snapshot order on a background STA thread. Invalid ranges throw. Unavailable details or icons can be empty; images returned across threads are frozen. |
| `GetFolderTarget(path)` | Returns a directory path for a directory or a directory shortcut, otherwise `null`. |
| `GetEditName(path)` / `Rename(path, name, owner)` | Obtain the filesystem leaf name for editing, or `null` for a drive root; validate and rename an item through the Windows Shell, returning its new filesystem path. Invalid names and existing targets fail; case-only changes are allowed. |
| `Open(path)` | Opens an item using the OS shell. |
| `Copy(paths, destination, owner)` / `Move(...)` | Run the existing native transfer operation; failures propagate and a transfer is not atomic. |
| `ShowItemMenu(paths, owner, rename)` / `ShowBackgroundMenu(path, owner)` | Show a native Windows context menu for one or more items from the same directory, or for a folder background. The optional single-item rename callback starts the caller's editor. |
| `ObserveDirectories(paths, changed)` | Observes immediate changes in the supplied directories and returns an `IDisposable` subscription. The callback may run on a background thread; callers must marshal UI work. Observation failures are logged and do not abort other subscriptions. |

The snapshot fixes item identities and ordering, not filesystem contents: items
can change or disappear before their range is loaded. A refresh creates a new
snapshot; results from an older snapshot must not be applied to it. Filtering and
sorting require Shell display names for all candidates before the count is known.

`GetDirectoryRangeAsync` accepts a zero-based start and count within the same
snapshot, including an empty range at its end. Results preserve the requested
index order and contain complete row records, rather than a metadata result
followed by a separate icon result. An unavailable item can still occupy its
snapshot position with missing details or icon. Cancellation is cooperative:
the operation checks between items and before returning, but cannot interrupt an
OS call already in progress; it does not return a partial package on cancellation.

The caller owns request scheduling and any row cache. SutShell does not preload
other ranges or know which rows are visible. ContentView's visible-first and
background loading policy, publication checks, and lifecycle are specified in
[ContentView](CONTENT_VIEW.md#range-scheduling).

An entry carries its display name, filesystem path, directory flag, type,
formatted size and date, Shell icon/overlay, and media-type icon and accessible
name. In the Windows implementation, the entry contains at most one classical
Shell overlay: it is the overlay selected by Windows, not a list of all applicable
overlay handlers. Explorer status-column icons are not necessarily overlays.
The asynchronous APIs check cancellation between items; an in-progress OS
call cannot be interrupted. Type names come from the Windows Shell, falling back to `Folder` or the
file extension if unavailable. File sizes are shown in KB (1024 bytes), rounded
up to whole KB; directories have no displayed size. Modification times use local
time in the culture-independent format `yyyy-MM-dd HH:mm`. Entry icons use WPF
types; the window owner is a Windows handle. A portable implementation would
first need platform-neutral models and capabilities, not just another class
with this name.

## Current limitations

ContentView creates fixed-height placeholders for the snapshot count and requests
complete entries in batches of up to eight. Realized visible rows take priority;
when these are loaded, remaining rows are fetched asynchronously in the background.
Loaded rows are retained for the snapshot. Scrolling cancels the current request
and prioritizes the new visible region. Loading pauses when the view is unloaded
and resumes when it is visible again.
A newer refresh cancels previous requests and cannot be overwritten by their
results. A slow OS call can still delay completion of its batch. ContentView
supports multiple selection and its own inline rename editor; Delete remains
disabled. Column sorting and Shell clipboard/drag-and-drop integration have not
been implemented for the table. Watchers are best-effort and
are not a complete replacement for all Shell namespace notifications.