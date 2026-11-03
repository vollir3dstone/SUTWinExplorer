# SutShell Windows Implementation

## Scope

The initial implementation is [SutShell.cs](SutShell.cs). ContentView calls it
instead of directly calling the Windows Shell or enumerating the filesystem.
The embedded `ShellExplorerBrowserHost` is no longer connected to ContentView;
its source remains in the project for reference. It is not a switchable runtime
fallback without reconnecting the removed integration.

## Directory data

`System.IO.Directory.EnumerateFileSystemEntries` enumerates filesystem
children. This PC is represented by `ShellLocations.TopPath` and enumerated as
drive roots. `InternalItemFilter` supplies internal-item and name-pattern rules;
the pattern uses the Shell display name with a filesystem-name fallback.
Directory attributes determine folder classification, including directory
reparse points. A background STA thread builds a per-view, unfiltered cache of
the current directory and resolves Shell display names. Sort and filter changes
reuse the cache and its loaded metadata and images; a filesystem notification,
explicit refresh or navigation invalidates the whole cache. Missing sort keys
are read before ordering, including icons when sorting the icon columns.
ContentView
creates fixed-height placeholders from its count, then requests complete rows
in batches of up to eight. The visible region has priority; once it is loaded,
remaining rows are fetched asynchronously in the background. Each completed row
replaces its placeholder data through property notification and is retained for
the directory cache. Scrolling cancels the current request, and a newer refresh prevents
older results from replacing newer data. Loading pauses when the view is unloaded
and resumes when visible again. Individual Shell calls cannot be interrupted, and
an item can change after the snapshot is created.

The prefetch loop and priority decisions belong to ContentView, not SutShell.
SutShell starts a background STA thread for each requested snapshot or range,
materializes the requested range in order, and returns it as a single result.
Cancellation is checked between items and before completion; a native Shell call
already underway cannot be interrupted. For the complete calling sequence and
stale-result checks, see [ContentView](CONTENT_VIEW.md#range-scheduling).

`ShellDisplayNameProvider` and `ShellIconProvider` provide Windows display
names and icons/overlays. With the classical Shell overlay-handler mechanism,
Windows selects an overlay when multiple handlers request one for the same item,
using internal rules and handler priority to resolve conflicts. SutShell uses
`SHGetFileInfo` with `SHGFI_OVERLAYINDEX`, which returns one selected overlay
index, and does not enumerate all applicable handlers. ContentView displays that
overlay in its own column, separate from the base icon. Explorer status-column
icons are not necessarily classical icon overlays. See Microsoft's documentation
on [overlay handler priority](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-implement-icon-overlay-handlers)
and [`SHGetFileInfo`](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shgetfileinfow).
The shared system image list is accessed through native
COM references so that ending one STA thread cannot invalidate a .NET COM wrapper
in use by another thread. `SHGetFileInfo` with `SHGFI_TYPENAME` provides the
localized type description; on failure the directory label or file extension
is used. File sizes use whole KB (1024 bytes), rounded up, with an empty value
for directories. `MediaTypeMap` and `MediaTypeIconMap` provide the
application's media-type classification and icon, including the stock Windows
folder icon. The JSON mapping remains manually maintained and embedded.
The WPF table renders the media type in the same row as the other fields.

## Operations and notifications

`ShellFileOperations` handles link resolution and native copy/move;
`ShellContextMenu` displays item and background menus, including menus for
multiple items from the same parent. The ContentView-owned inline editor calls
SutShell, which validates the name and delegates to `IShellFolder::SetNameOf`
through `ShellContextMenu`. Opening uses shell execution. These are separate
from the application-owned staged transfer state.

Copy and Move queue individual items with an `IFileOperationProgressSink`.
Successful Shell callbacks provide the actual resulting filesystem paths,
including names chosen by the Shell during conflict resolution. Only direct
children of the destination are collected, not nested callbacks from copied
folders. The caller retains reported paths even if a later operation fails and
passes them to ContentView's shared insertion completion. Native menu and
extension operations do not pass through this completion.

`FileSystemWatcher` subscriptions cover the directory paths supplied by
Pathview, without recursive monitoring. The caller marshals callbacks to the
WPF dispatcher; Pathview coalesces updates with its existing refresh timer.
An observer is disposed when its paths change or the view unloads. A watcher
error requests a refresh, but notification loss and inaccessible paths are not
fully recoverable guarantees. Observation failures are written to debug output.

## Follow-up work

The table does not yet reproduce all behavior in the Shell-oriented behavior
specification. Drag/drop and clipboard shortcuts are not implemented. Navigation
access checks and tree loading still run
synchronously and can block the UI. The access check precedes committing
navigation but cannot prevent later filesystem changes or enumeration failures.
Virtual Shell namespace locations beyond the drive listing are not supported.