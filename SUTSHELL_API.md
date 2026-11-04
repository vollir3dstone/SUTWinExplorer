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
| `OpenCachedDirectoryAsync(path, showDirectories, hideInternal, namePattern, sorting, cache, cancellationToken)` | Reuses the cache's unfiltered current-directory records and their loaded data, then prepares a filtered, sorted snapshot. Its `DirectoryCount` and `FileCount` describe unfiltered records; `Count` describes filtered items. |
| `OpenSortedDirectoryAsync(path, showDirectories, hideInternal, namePattern, sorting, cancellationToken)` | Prepares a filtered snapshot using the ordered pairs in a `DirectorySortState`. Directories always precede files; criteria apply within both groups. This PC contains drive roots. Enumeration errors propagate; inaccessible individual items may be skipped. |
| `OpenDirectoryAsync(path, showDirectories, hideInternal, namePattern, cancellationToken)` | Opens a snapshot with no explicit sort pairs, using the default name order. |
| `GetDirectoryRangeAsync(snapshot, start, count, cancellationToken)` | Returns complete entries for the requested zero-based range in snapshot order on a background STA thread. Invalid ranges throw. Unavailable details or icons can be empty; images returned across threads are frozen. |
| `GetFolderTarget(path)` | Returns a directory path for a directory or a directory shortcut, otherwise `null`. |
| `GetLinkTarget(path)` | Resolves a `.lnk` to an existing filesystem file or directory; returns `null` for unavailable or non-filesystem targets. |
| `GetEditName(path)` / `Rename(path, name, owner)` | Obtain the filesystem leaf name for editing, or `null` for a drive root; validate and rename an item through the Windows Shell, returning its new filesystem path. Invalid names and existing targets fail; case-only changes are allowed. |
| `Open(path)` | Opens an item using the OS shell. |
| `Link(paths, destination, insertedPaths)` | Create Shell shortcuts for the selected paths in the destination, without overwriting existing items. Appends created paths; a later failure can leave earlier shortcuts in place. |
| `Copy(paths, destination, owner, insertedPaths)` / `Move(...)` | Run the native transfer operation and append actual destination paths reported by the Shell to the caller's mutable list. Only direct children of the destination are collected. Failures propagate and a transfer is not atomic; the list can contain items completed before a failure. |
| `CopyToClipboard(paths, owner)` / `ClipboardContainsItems()` / `PasteFromClipboard(path, owner)` | Copy items to the Shell clipboard, check for supported filesystem Copy data, or copy its captured paths to the destination. Paste rechecks the clipboard and rejects Cut, Link-only, missing and ambiguous effects; it never invokes the Shell Paste verb. |
| `Delete(paths, owner)` | Delete selected filesystem items using `IFileOperation`, requesting recycling and undo. Rejects drive/share roots; the Shell controls confirmation and may not support recycling for every location. Failures and cancellation propagate, and deletion is not atomic. |
| `ShowItemMenu(paths, owner, rename)` / `ShowBackgroundMenu(path, owner)` | Show a native Windows context menu for one or more items from the same directory, or for a folder background. The optional single-item rename callback starts the caller's editor. |
| `ShowNewMenu(path, owner, x, y)` / `ShowProperties(paths, owner)` | Show the native background New submenu as the explicit Windows fallback, or invoke the Shell properties command for one or more selected items in the same directory. The normal New action uses the application dialog and `NewItemOperations`. |
| `ObserveDirectories(paths, changed)` | Observes immediate changes in the supplied directories and returns an `IDisposable` subscription. The callback may run on a background thread; callers must marshal UI work. Observation failures are logged and do not abort other subscriptions. |

The paired menus are created directly by `SutContextMenuFactory`, not by
`SutShell`: `GetBaseMenu(paths, owner, actions)` creates the Base Menu and
`GetContentMenu(paths, owner, baseCommands)` creates the filtered Content Menu.
The factory's background variants use the current directory and Shell view;
the controller delegates menu composition and filtering to the factory.
Each returns a disposable `SutContextMenu`; its `Show(secondRightClick)` displays
the popup and, for the Base Menu, returns a snapshot after the popup closes.
The optional callback receives subsequent right-click coordinates, owner-window
hit state and Shift state. The snapshot can outlive its menu and is used to
create the Content Menu. `CommandInvoked` records whether a command was selected
before it is invoked, allowing the controller to discard the sequence after
`Show` returns. The controller also monitors pointer movement for mouse-driven
sequences; leaving the system double-click area invalidates the sequence without
closing an open popup. The [file context menu specification](CONTEXT_MENU_SPEC.md)
defines the sequence, hook lifetime, filtering, comparison rules and Shell integration limitations.

The snapshot fixes item identities and ordering, not filesystem contents: items
can change or disappear before their range is loaded. A refresh creates a new
snapshot; results from an older snapshot must not be applied to it. Filtering and
sorting require Shell display names for all candidates before the count is known.

`DirectorySortColumn` identifies Name, TypeApp2Name, Size, DateModified,
MediaTypeIcon, TypeApp1Icon and Overlay;
`DirectorySortCriterion` currently offers Ascending and Descending. A
`DirectorySortPair` combines them. Each view holds a `DirectorySortState`;
`Update` prepends the supplied list in its given priority order and removes
older pairs for those columns. Invalid enum values and duplicate columns in one
update are rejected. The state itself starts empty; ContentView initializes it
with all seven columns and retains it across refresh and navigation, but does not
persist it across sessions. The snapshot operation
copies the current ordered pairs before starting its background work.

TypeApp2Name uses the localized Shell type name, MediaTypeIcon the declared `MediaType` enum
order with `None` after known types in both directions, Size the numeric byte
count, and DateModified the local modification time. TypeApp1Icon uses the Windows
system-image-list index; Overlay uses the classical overlay slot (zero means no
overlay). These Windows icon keys are not
stable identifiers across sessions. Text comparison is culture-aware and
case-insensitive. Directory sizes and drive sizes/dates have no value. Missing
numeric/date/icon values sort before present values ascending and after them
descending. Remaining ties use ascending display name and then path. An empty
list therefore defaults to ascending display name. A new sort criterion may
require fetching missing keys for every matching item before the snapshot is
ready, including Shell icons for an icon sort.

## Directory Cache

### Scope and ownership

Each ContentView owns one `DirectoryDataCache` instance and passes it to
`OpenCachedDirectoryAsync`. The cache holds at most one directory's unfiltered
records at a time; it is not shared across tabs, persisted, or a cache of
previously visited directories. Navigation invalidates it, so returning to a
previous location requires a new enumeration. `OpenDirectoryAsync` and
`OpenSortedDirectoryAsync` instead create a fresh cache for each call and do not
provide reuse across calls.

There is no time-to-live, size limit, per-entry eviction, or global deduplication.
The number of records and retained images can grow with the size of the current
directory. Invalidating the cache drops its reference to the record array;
snapshots or in-flight operations may still reference old records until they
finish and are no longer reachable. Memory is reclaimed by the runtime.

### Population and reuse

On a cache miss, SutShell enumerates every immediate filesystem child, or drive
roots for This PC. For each accessible candidate it reads attributes, resolves
the Shell display name with a filesystem-name fallback, and creates a
`DirectoryItem` containing path, name, directory/drive flags and media type.
This happens before applying the view filters, so currently hidden records are
also available for later filter changes. Per-item I/O or access failures during
enumeration skip that item; a directory-level enumeration failure is reported
to the caller. A successfully completed enumeration is stored as a whole; a
cancelled or failed enumeration does not install a partial directory array.

For each snapshot SutShell applies `showDirectories`, `hideInternal` and the
case-insensitive name pattern to those records, then orders the matches using
the captured sort pairs. The name pattern uses the cached Shell display name.
The internal-item predicate is calculated only when needed and its successful
boolean result is retained per item. An I/O or access exception escaping this
predicate skips that item for the snapshot and is not stored as a successful
result, so a later filter request can try again.

Each record loads and retains the following on demand:

| Data | First requested when |
| --- | --- |
| Size in bytes | Sorting by Size or requesting a complete row. Directories and drives have no size. |
| Local modification time | Sorting by DateModified or requesting a complete row. Drives have no date. |
| Localized Shell type name | Sorting by Type or requesting a complete row; the type helper has a fallback. |
| Shell base icon, overlay, opacity and sort keys | Sorting by ShellIcon or Overlay, or requesting a complete row. Both icon sort keys are obtained with the same icon set. |
| Complete `FileEntry`, including MT image and formatted values | `GetDirectoryRangeAsync` requests the item. Subsequent ranges reuse the same entry object. |

The requested sort keys are obtained for **all matching items before** the
snapshot is returned. Therefore the first sort by an unloaded key can still
perform filesystem or Shell work, even outside the viewport. An icon sort may
load icons for all matches. Later sort/filter snapshots reuse keys and entries
already loaded, including for records hidden and then shown again; previously
unloaded data still requires a lookup. ContentView continues to request rows in
visible-first batches, but those requests can be served from cached entries.

For example, after loading a row for `report.txt`, filtering it out and then
clearing the filter reuses its record and completed entry. Reversing the sort
also reuses it. If the file changes in between without an invalidation, cached
values can remain stale; sorting alone is not a request for fresh OS data.

### Invalidation and freshness

`DirectoryDataCache.Invalidate` discards the **whole** cached directory, not
just changed records. In the current ContentView/Pathview integration:

| Event | Cache behavior |
| --- | --- |
| Change name pattern, Hide directories, Hide internal or a sort column/direction | Keep cache; create a new filtered/sorted snapshot. |
| Navigate or invoke ContentView `Refresh` | Invalidate; the next snapshot enumerates again. The current `Refresh(bool)` implementation invalidates regardless of the boolean argument. |
| Filesystem notification | Pathview coalesces notifications and invokes `Refresh`, invalidating the entire cache. |
| Successful inline rename, New, or Link/Copy/Move with reported inserted items | Refresh and invalidate; insertion completion also handles items reported before a later transfer failure. |
| Pathview becomes visible or loads | Pathview schedules a filesystem refresh, which can invalidate even without a known change. |
| Filter or refresh while inline rename is active | Defer rebuilding the view until editing ends; a requested invalidation occurs before deferral. Successful rename also invalidates. |

`FileSystemWatcher` is best-effort, and the cache is not an atomic filesystem
snapshot. Items can change between enumeration and lazy loading, or after a
field is cached; notifications can be missed. Shell icon and overlay changes
in particular may not produce a filesystem notification. Cached values remain
in use until invalidation, so an explicit refresh is the recovery path for
changes that are not observed. No cross-tab cache synchronization is provided.

Size, modification time and icon lookups handle their expected I/O/access
errors and retain the resulting missing value until invalidation; a subsequent
sort or range request does not retry those handled failures. A Shell type lookup
can retain its fallback value. Other unexpected exceptions can fail the request;
an item filtered out by a failed internal check is a separate case described
above. Existing snapshots retain item references even after invalidation, so
invalidating alone does not make an old snapshot fresh or unusable.

### Concurrency and cancellation

Snapshot and range operations run on background STA threads. A cache-level
semaphore serializes directory enumeration; the short cache-state lock protects
the stored path, records and generation. Each `DirectoryItem` has its own lock
around lazy values and entry creation, preventing competing range/sort requests
from loading the same field simultaneously. Different items may be loaded by
different operations concurrently. A waiter or a slow Shell/OS call can delay a
request; an in-progress native call cannot be interrupted.

Invalidation increments a generation and clears the cached path and array. If an
enumeration started under an older generation finishes later, it cannot install
its array into the cache. It may still return its result to its own caller;
invalidation is not a substitute for cancelling and rejecting stale requests.
ContentView cancels superseded work, checks the current refresh token before
publishing a snapshot, and checks snapshot and row-array identity before
publishing a range. A cancellation discards the partial returned snapshot or
range, but already completed per-item lookups can remain cached for reuse.

The focused [SutShell tests](tests/SutShell.Tests.ps1) cover cache reuse across
filter and sort changes, cache invalidation after filesystem changes, icon
loading during sort, GUI reuse, cancellation and rapid navigation. These checks
do not make filesystem notifications or Shell state changes infallible.

## Range Requests

`GetDirectoryRangeAsync` accepts a zero-based start and count within the same
snapshot, including an empty range at its end. Results preserve the requested
index order and contain complete row records, rather than a metadata result
followed by a separate icon result. An unavailable item can still occupy its
snapshot position with missing details or icon. Cancellation is cooperative:
the operation checks between items and before returning, but cannot interrupt an
OS call already in progress; it does not return a partial package on cancellation.

The caller owns request scheduling and the current snapshot's row placeholders;
SutShell owns the cached directory data. SutShell does not preload other ranges
or know which rows are visible. ContentView's visible-first and
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
Loaded data is retained in the current-directory cache across filter and sort
snapshots. Scrolling cancels the current request
and prioritizes the new visible region. Loading pauses when the view is unloaded
and resumes when it is visible again.
A newer refresh cancels previous requests and cannot be overwritten by their
results. A slow OS call can still delay completion of its batch. ContentView
supports multiple selection, its own inline rename editor, Shell-backed Delete,
clipboard Copy and copy-only Paste, and left-button filesystem drag-and-drop.
The Sub directories list also supports drag-and-drop, using the clicked folder
as its source rather than a persistent selection. Its menu or keyboard selection
is temporary; tree views do not support drag-and-drop. `ShellDragDrop` creates Shell data objects and
forwards WPF drag events to the target directory's native `IDropTarget`. Watchers are best-effort and
are not a complete replacement for all Shell namespace notifications.