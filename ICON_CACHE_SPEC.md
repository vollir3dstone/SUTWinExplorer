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

An item initially recorded without an overlay is not queried for overlays on
cache hits. Consequently, an overlay that appears later is not detected by this
policy. A previously recorded overlay can disappear or change and is then
requeried; this does not change the stored presence flag. Per-item changes to
base icons, renames, deletions, and changes of an item at the same path do not
invalidate or move persistent entries in this initial version. Stale icons and
orphaned entries are accepted until the cache is cleared. `DirectoryItem` also
retains its first icon result in the current directory-data cache, including a
failed result, until its metadata or directory cache is invalidated. When a
previously materialized entry with a known overlay is requested again, the
provider is called again and the current overlay is obtained.

## Sorting and the Windows index

**Experimental:** icon sorting currently uses the persisted `BaseIconIndex` as
the numeric sort key. Its stability across Windows restarts has not been
validated and remains an open test. It can become stale or refer to a different
Windows icon; the stored PNG, not this index, is always used to display the base
icon. Equal cached images can have different per-path indices, because the index
is stored on the path node rather than in the deduplicated image table.

When a small icon is freshly resolved, the returned Windows index is recorded
with the path. On a cache hit that index is reused without querying Windows again
for the base icon. A cached entry lacking an index uses `0`; the provider does
not query Windows solely to populate that missing key. Overlay sorting uses the
current overlay slot from the small-icon request when the item was recorded as
having an overlay, or `0` otherwise. A failed icon lookup has no icon sort value.

SutShell first groups directories before files, then applies the configured sort
criteria in order and finally uses name and full path as tie-breakers. The
ContentView default criteria include icon and overlay columns as secondary keys,
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
- Stale base icons and newly appearing overlays are not refreshed automatically.
  A future invalidation strategy must address changed icons, renames, deletions,
  path reuse, file associations and removable or network locations. A cache-clear
  mechanism is desirable, but its user interface is not specified.
- The persisted Windows sort index is experimental. Its stability across Windows
  restarts must still be validated; a stable result in a particular test does not
  establish a general Windows guarantee.
- Case-insensitive keys match current application behavior but cannot distinguish
  case-sensitive directory entries that differ only by case. Path aliases,
  junctions, symbolic links, removable drives and changing network mappings can
  produce duplicate or stale entries.
- No migration policy for future JSON versions is defined.
- Requerying an overlay for each display preparation may still require an
  expensive Shell call; the performance benefit needs measurement. Reusing an
  already loaded ContentView item for a new range request refreshes known
  overlays. Retained directory-tree icons are refreshed when their existing tree
  refresh path requests icons, not on every WPF repaint.
- Saving only at normal shutdown loses new entries after a crash or forced
  termination. Whether periodic checkpoints are needed remains open.
- Loading and saving a potentially large JSON file may affect startup, shutdown
  time and memory use. Limits, incremental persistence and recovery of valid
  entries from a partially damaged file remain open for future evaluation.

## Tests and validation

`tests/IconCache.Tests.ps1` exercises cache misses and hits, per-path indices,
deduplication and overlay flags, case-insensitive paths, size variants, deep
trees, concurrent access, JSON save/load and malformed or unsupported files. It
also exercises Shell-backed small and sized icons, known-overlay requery,
preloading before sorting, real Windows indices and sorting using deliberately
distinct persisted indices. The test uses a temporary directory and cache.

These tests do not establish that Windows image-list indices remain stable across
Windows restarts or changes to installed software and icon associations. That
requires separate observation across actual restarts; record the Windows version,
test conditions and observed changes without assuming a successful run proves
the behavior for all systems.