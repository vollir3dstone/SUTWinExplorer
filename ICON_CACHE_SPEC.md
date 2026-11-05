# Persistent Icon Cache

## Implementation and scope

The cache is implemented by `IconCache`, shared through `ShellIconProvider` and
initialized by `App`. It supplies Windows Shell item icons to application-owned
views, including ContentView, the directory tree and location controls. Files,
directories and drive roots are cacheable items. This PC uses a separate virtual
location key. The disconnected embedded Shell view is outside the scope.
Application-defined media-type icons and `GetTypeIcon` are not served by this
item-icon cache.

The cache is an optimization, not a source of filesystem contents. Directories
are still enumerated separately. Tree and location controls request icons as they
need them; ancestors are not prefetched merely because a path exists. SutShell
requests small icons for all enumerated items before filtering and sorting a
directory snapshot, including items excluded by the current filter. It attempts
to obtain missing icons and their Windows indices from the Shell and store them.
The first sorted snapshot waits for these requests; it is not produced in batches.
ContentView then requests complete rows in batches of up to eight, with visible
rows prioritized. The existing per-view `DirectoryDataCache` independently
retains directory items and their loaded metadata while that directory is cached.

## In-memory cache

At startup the saved JSON is read into an application-wide, partially populated
tree of dictionaries. Each component selects a child by its actual filesystem
name, not its Shell display name. `Path.GetFullPath` and `Path.GetPathRoot`
provide the absolute filesystem path and root; the root key has a `filesystem:`
prefix, while This PC has a separate `shell:` key. Components and roots use
`OrdinalIgnoreCase` comparison. Normalization does not resolve symbolic links,
junctions, mapped drives or other aliases to a common identity.

A node can have children without having an icon itself. A cached item references
icon IDs for the available requested sizes and retrieval variants. Each entry in
the shared icon table contains an image and a flag indicating whether the item had
an overlay when first resolved. The ID is the uppercase SHA-256 hash of the
encoded PNG bytes, followed by `-1` if an overlay was detected or `-0` otherwise.
Equal encoded images with the same flag share an ID; equal encoded images with
different flags have different IDs. Different requested sizes or retrieval
variants may reference the same ID when their image data and flag are identical.
Store image pixels, not Windows system-image-list handles. Each path node also
stores the Windows base-icon index obtained when its small icon was resolved; it
is used only as a sort key, never to retrieve an image. An ID is not a file type,
path, or Windows icon index.
The image table retains dimensions, Base64-encoded PNG data and `HasOverlay`;
another in-memory dictionary retains decoded, frozen WPF bitmaps by ID. The
tree, image table and decoded images are protected by one lock for lookup,
updates, loading and saving. PNG encoding happens before taking that lock.
Concurrent misses are not coalesced and can therefore perform duplicate Shell
lookups or PNG encodes before updating the shared cache.

## Lookup and display

`GetSmallIcons(path)` uses the `small:16x16` entry:

1. On a hit, it returns the frozen cached base bitmap and stored base index. If
  `HasOverlay` is true, it calls the Shell for the item's current overlay slot
  and image; otherwise it makes no overlay lookup and returns slot `0`.
2. On a miss, it calls `SHGetFileInfo` for the system-image-list base index and
  separately for the selected overlay slot. It reads the corresponding bitmaps
  from the small Shell image list. This PC is queried by PIDL.
3. If the base bitmap exists and the overlay query succeeded, the provider
  stores the base bitmap, overlay-presence flag and base index. A successful
  overlay query can report slot `0`; that is stored as `HasOverlay: false`.
  If the base bitmap or overlay-presence result is unavailable, the result is
  not added to the persistent cache. The existing display fallback remains in
  effect, and a later new item lookup can retry.

`GetIconAtSize(path, width, height)` uses the separate `sized:WIDTHxHEIGHT` key.
On a miss it asks `IShellItemImageFactory` for the requested image. It also
requests small icons to establish the overlay flag; when this succeeds, the
size-specific bitmap is cached using the original small-icon flag, if one is
already cached. Adding a size variant does not overwrite the node's base index.
If the small-icon/overlay lookup fails, the size-specific image can still be
returned for display, but is not cached. Small and size-specific images use
separate keys even when their requested dimensions coincide.

Overlay images and Windows overlay slots are not persisted. Opacity is derived
from current file attributes when small icons are requested: hidden items use
`0.55`, other items use `1`, and an attribute-read failure uses `1`. The
ContentView table displays the base and selected overlay in separate columns;
other controls can layer the same images.

### Pathview first-visit refresh

Pathview directory snapshots use a process-wide session shared by all tabs for
the same normalized, case-insensitive directory path. On the first visit in a
program run, the small icons of **all enumerated items**, including items hidden
by the current filters, are refreshed in two separate stages:

1. **Base icons:** Before filtering and sorting, each item's base icon and
  system-image-list index are requested from the Shell, even if an older base
  icon is already cached. This stage does not request an overlay. A successful
  result replaces the cached small base icon and index; the returned icon set
  has no overlay. Failed base lookups can be retried on a later visit. Newly
  encountered items are handled in the same way.
2. **Overlays:** Items whose base-icon lookup succeeded are queued for a
  separate overlay lookup on one lowest-priority STA background thread. A
  successful lookup updates the cache's overlay-presence flag and retains the
  current overlay bitmap and slot in memory. The bitmap and slot are not
  persisted. An unsuccessful lookup does not establish a reliable overlay
  presence; completion means that the queued attempts finished, not that every
  Shell lookup necessarily succeeded.

The cache format has only a Boolean `HasOverlay`, not an unknown state. A fresh
base-icon write temporarily records `HasOverlay: false` before the overlay
lookup; this value is not proof that the item has no overlay. The background
lookup replaces it when a result is available. If the application exits before
that work finishes, the first visit in the next run performs the lookups again.

The initial directory snapshot can be displayed as soon as its base icons and
other required sort data are ready; it does not wait for overlay lookups. The
MO cells therefore initially may be empty even when Windows has overlays for
those items. Once the directory's queued overlay attempts finish, each view
still displaying that snapshot updates only affected MO image bindings using the
in-memory overlay results. The table, rows, scroll position, selection and focus
are retained. Rows whose details are still loading receive the overlay when
their details arrive. A view that navigated away or was closed is not updated
for the old directory. If another snapshot is requested while overlay work is in progress,
it can already show the subset of overlays obtained so far; a partial result is
not itself the directory-completion refresh.

The worker processes the selected tab first, then tabs previously selected
during this run, then open tabs not yet selected. Work already started for a
directory that is no longer open continues after the open tabs. The worker does
not scan unvisited cached directories. A tab switch changes priority after the
current Shell call returns; an already-running Shell call is not interrupted.
Completed sessions are reused on later visits without another first-visit
lookup. Changes to cached icons observed during the run are detected on a
subsequent snapshot; cache revisions prevent an older background result from
replacing a newer cache entry.

This separation applies to the Pathview first-visit refresh, not to all icon
updates in the application. In particular, the general `GetSmallIcons` path
above can query an overlay during a cache lookup or miss, and the change
observer described below refreshes the base icon and overlay together on its
own worker. Directory-tree and other consumers of that general provider do not
necessarily follow the Pathview's delayed-display sequence.

## Icon change observation

At startup the application registers a recursive Shell change observer for each
filesystem root already in the cache. When a first item on a new root is stored,
the root is registered dynamically on the application's dispatcher, including
when the store came from a background thread. Registration failures are logged;
device-change messages trigger another registration attempt for missing roots.
Virtual Shell items are outside this observer's scope.

The icon observer uses a native `HwndSource` window to receive Shell change
notifications and `WM_DEVICECHANGE` messages. This is a hidden top-level window,
not an application UI window: its `WindowStyle` is explicitly set to `0` so it
does not acquire WPF's default visible window style and appear as a stray title
bar. Keep it invisible when changing its creation or lifetime. Do not replace it
with a message-only window without accounting for device-change broadcasts,
which message-only windows do not receive. The observer unregisters its Shell
notifications and disposes the window on shutdown.

For `SHCNE_UPDATEITEM`, only the named item is refreshed if it is in the cache.
The provider asks the Shell again for its small base icon, overlay state and
index, and for every cached size variant. Failed or unavailable variants are
removed so a later lookup can retry. In-memory variant revisions prevent an
older refresh from overwriting a newer store, even when their image IDs match.

### Association notification: deliberate deviation

Microsoft's [`SHChangeNotify` documentation](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify)
specifies that senders of `SHCNE_ASSOCCHANGED` must pass `NULL` for both item
parameters. We deliberately also interpret a non-null first item delivered to
the observer, based on an actual Windows test, even though its meaning is not
documented as a supported contract.

On Windows 11, build 26200, changing a temporary file extension's default app
through Windows Settings delivered `SHCNE_ASSOCCHANGED` with a non-null first
item and a null second item. Resolving the first item using
`SHGetNameFromIDList` with `SIGDN_DESKTOPABSOLUTEPARSING` produced a name like
`C:\*.kistesta31fa0f8`, containing the changed extension. The test did not send
the notification itself. A subsequent real Settings change exercised the
production observer and confirmed that matching cached file icons were refreshed
while an unrelated file and a directory with the same extension were not.

For this observed `*.extension` form, the observer extracts the extension and
requeries matching cached files and their variants across all filesystem roots,
ignoring case. The drive in the parsing name does not restrict the refresh to
that drive. A null first item triggers the previous global requery of all cached
filesystem items and their variants. A non-null item that cannot be resolved to
the recognized wildcard form is logged and ignored, not treated as a global
refresh. Consequently, its affected icons can remain stale.

This behavior is based on the tested Settings workflow, not a Windows guarantee.
Other Windows versions or notification producers may provide null, a different
item, or no notification. The optimization must not be assumed to cover every
association change or to identify all effects of a notification.

Repeated requests are coalesced and Shell lookups run serially on an STA
background thread. On normal shutdown, unfinished items are invalidated before
the cache is saved, and late results are discarded without waiting for a Shell
handler.

### Changes while the application is closed

Observation works only while the application is running, the relevant root is
successfully registered, and Windows delivers a supported notification. Shell
notifications are not replayed for the period when the application was closed.
At the next startup, the persisted cache is loaded without a global scan. The
first Pathview visit to each directory refreshes its small base icons and then
its overlays as described above. Unvisited directories and other icon sizes are
not globally revalidated by this mechanism. There is no offline change journal
or association snapshot comparison.

## Sorting and the Windows index

**Experimental:** icon sorting currently uses the persisted `BaseIconIndex` as
the numeric sort key. Its stability across Windows restarts has not been
validated and remains an open test. It can become stale or refer to a different
Windows icon; the stored PNG, not this index, is always used to display the base
icon. Equal cached images can have different per-path indices, because the index
is stored on the path node rather than in the deduplicated image table.

When a small icon is freshly resolved, the returned Windows index is recorded
with the path. The first Pathview visit refreshes that index; subsequent snapshots
reuse it unless the cache changes. A failed icon lookup has no icon sort value.
Sorting by overlay is not supported.

SutShell first groups directories before files, then applies the configured sort
criteria in order and finally uses name and full path as tie-breakers. The
ContentView default criteria include the base icon as a secondary key,
so these keys can be considered even when name is the primary criterion. The
cache does not remove other work needed before a snapshot, such as Shell display
names, filtering and the metadata required by the configured sort criteria.

## JSON persistence

The file is `%LOCALAPPDATA%\KIS Explorer\IconCache.json`. After acquiring the
application's single-instance mutex, startup creates the cache and loads this
file before opening the main window. On normal application exit, the complete
in-memory document is serialized while holding the cache lock, before the mutex
is released. Updates during normal use only change memory; they do not immediately
rewrite the file.

Save creates the parent directory if needed, writes a uniquely named temporary
file alongside the destination, then moves it over the previous file with
overwrite enabled. The temporary file is deleted in `finally` if possible. This
avoids intentionally writing partial JSON directly to the destination, but does
not promise recovery or durability after every interruption. A crash or forced
termination can lose changes since the last normal save.

The document has a format identifier and version, a map of root keys to tree
nodes, and an image table. Each node has a child-name map, an optional image
reference map and a nullable `BaseIconIndex`. Each image record contains its
actual bitmap dimensions, PNG bytes encoded as Base64, and the overlay flag.
Nodes without an icon can still have children; their `Images` and
`BaseIconIndex` can be `null`. The following illustrates the structure; the
image data and ID are abbreviated and are not usable image data:

```json
{
  "_type": "IconCache",
  "Version": 1,
  "Roots": {
    "filesystem:C:": {
      "Children": {
        "Example": {
          "Images": { "small:16x16": "icon-id" },
          "BaseIconIndex": 42,
          "Children": {}
        }
      }
    }
  },
  "Images": {
    "icon-id": { "Width": 16, "Height": 16, "Png": "...", "HasOverlay": false }
  }
}
```

Root keys distinguish filesystem roots, including UNC shares, from virtual Shell
locations. Variant keys distinguish small Shell icons from size-specific images;
their dimensions refer to the requested pixel size, which need not equal the
actual bitmap dimensions in the image table. Every image ID referenced by an
item must resolve to an image record. JSON serialization and deserialization use
a maximum nesting depth of 1024. There is no eviction policy or explicit limit on
the number of paths or images.

A missing file starts with an empty cache. On load, the type and version are
checked, every image is Base64-decoded and loaded as a frozen PNG bitmap, image
dimensions are checked, and tree references are validated. A handled read,
format, decode or validation failure discards the entire loaded document and
continues with an empty cache; it does not salvage individual valid entries.
Handled save and temporary-file cleanup failures do not prevent shutdown. These
failures are written to `Debug.WriteLine`, not reported in the application UI.
Shell or cache failures on an individual item retain the existing fallback
behavior; cache entries are not authoritative filesystem data.

## Known limitations and open decisions

- The cache grows without eviction or a size limit. Images and paths can consume
  substantial disk space and memory; paths in the per-user JSON reveal visited
  filesystem locations.
- The observer only handles `SHCNE_UPDATEITEM` and `SHCNE_ASSOCCHANGED` received
  while the application is running. Windows can coalesce item events into other
  event types, and association changes require the changing application to send
  the notification. Offline changes are refreshed on the first Pathview visit
  to each directory, not by a global scan. Renames, deletions and path reuse
  are not comprehensively tracked. UNC and removable roots and reconnection
  behavior have not been comprehensively validated. Existing UI objects do not
  necessarily replace already materialized icons immediately when the cache
  changes.
- A temporarily unavailable path can lose its cached variants on refresh and
  require a later lookup. Invalidation does not remove orphaned PNGs or path
  nodes; there is no image-table garbage collection or cache-clear UI.
- The extension-bearing association item is undocumented and was observed for a
  Windows 11 Settings change; other sources may use different or null items.
  Unrecognized non-null items leave affected icons unchanged.
- The cost of association refreshes has not been measured. The observer scans
  cached filesystem items and performs the selected Shell calls sequentially;
  a null item can require refreshing the entire cache.
- The persisted Windows sort index is experimental. Its stability across Windows
  restarts must still be validated; a stable result in a particular test does not
  establish a general Windows guarantee.
- Case-insensitive keys match current application behavior but cannot distinguish
  case-sensitive directory entries that differ only by case. Path aliases,
  junctions, symbolic links, removable drives and changing network mappings can
  produce duplicate or stale entries.
- No migration policy for future JSON versions is defined.
- Overlay queries can still be expensive even though Pathview performs them in
  the background; the benchmark below is specific to one machine and workload.
  Retained directory-tree icons are refreshed when their existing tree refresh
  path requests icons, not on every WPF repaint.
- Saving only at normal shutdown loses new entries after a crash or forced
  termination. Whether periodic checkpoints are needed remains open.
- Loading and saving a potentially large JSON file may affect startup, shutdown
  time and memory use. Limits, incremental persistence and recovery of valid
  entries from a partially damaged file remain open for future evaluation.

## Icon lookup benchmark

`tests/IconPerformance.Benchmark.ps1` measures the real production small-icon
lookup and in-memory cache operations using files and folders from a selected
directory. It does not write to the directory or save or modify the application's
real cache. Each pass uses a new in-memory application cache and randomizes the
order; the script reports per-item mean, median, p90, p95, p99 and maximum, plus
per-pass totals. Separate, subsequent `SHGetFileInfo` calls measure the base and
overlay flags individually; these are repeated lookups on a warmer Shell cache,
not instrumentation inside the production call, and must not be added to its
time. The isolated PNG/hash measurement also repeats work already included in
the measured `Store` time.

One run on Windows 11 build 26200, PowerShell 7.6.9 / .NET 10.0.14 and an Intel
Core i5-13500 used all 657 immediate Downloads entries (636 files, 21 directories,
35 distinct file extensions), seven passes, and 4,599 successful item samples:

| Measured operation | Mean ms/item | Median | p95 |
| --- | ---: | ---: | ---: |
| Production uncached lookup, including Shell and WPF conversion | 11.748 | 11.607 | 13.095 |
| In-memory cache `Store`, including PNG and hashing | 0.230 | 0.217 | 0.270 |
| PNG/hash preparation only, overlapping `Store` | 0.123 | 0.121 | 0.158 |
| Production cache hit, including overlay requery when applicable | 0.046 | 0.036 | 0.051 |
| Separate `SHGetFileInfo` base-index call | 0.899 | 0.877 | 1.079 |
| Separate `SHGetFileInfo` overlay call | 10.258 | 10.238 | 11.350 |

The paired production uncached lookup plus `Store` averaged 11.978 ms/item;
its seven pass means ranged from 11.765 to 12.992 ms/item. Only 14 of the 4,599
samples reported an overlay, so the pooled cache-hit result mostly describes
items without one. There were no failed lookups. The first pass was not a cold
Windows-cache measurement: other applications and earlier tests may already
have warmed it. Repeated observations of the same files are not independent; the
numbers describe this workload and machine, not a population-wide confidence
interval or a guarantee for other file types, networks, or installed handlers.

A separate three-pass run of all 657 entries compared `SHGetFileInfo` flags in
rotated order after the production lookup. A plain icon call averaged 1.059
ms/item; requesting the overlay index averaged 10.749 ms without
`SHGFI_ADDOVERLAYS` and 10.747 ms with it. Combining the base-index and overlay
request in one call averaged 10.779 ms. The latter two alternatives returned the
same base/overlay indices where compared in all 1,971 samples, including six
overlay-bearing samples. This is not sufficient to establish equivalence for all
handlers or Windows versions. Multiple third-party overlay handlers were
registered on the test machine; none were disabled, so the cause of the delay
cannot be attributed to an individual handler from these measurements.

## Tests and validation

`tests/IconCache.Tests.ps1` exercises cache misses and hits, per-path indices,
deduplication and overlay flags, case-insensitive paths, size variants, deep
trees, concurrent access, JSON save/load and malformed or unsupported files. It
also exercises Shell-backed small and sized icons, known-overlay requery,
preloading before sorting, real Windows indices and sorting using deliberately
distinct persisted indices. The test uses a temporary directory and cache.

`tests/IconChangeNotifications.Tests.ps1` exercises real shortcut and explicit
association notifications on a local drive, dynamically registered and loaded
roots, background-thread registration, item-only and global variant refreshes,
and interrupted refresh invalidation including save and reload. The association
test uses temporary per-user registry entries and explicitly sends the global
notification. It does not establish coverage for all Shell extensions, event
sources, network or removable drives.

`tests/ManualAssociationNotifications.ps1` observes a real Windows Settings
association change without sending a notification. It checks matching files,
case-insensitive extensions, icon variants, an unrelated file and a directory
whose name matches the extension. It requires a user to select an app for a
temporary extension and removes its test data afterwards.

These tests do not establish that Windows image-list indices remain stable across
Windows restarts or changes to installed software and icon associations. That
requires separate observation across actual restarts; record the Windows version,
test conditions and observed changes without assuming a successful run proves
the behavior for all systems.