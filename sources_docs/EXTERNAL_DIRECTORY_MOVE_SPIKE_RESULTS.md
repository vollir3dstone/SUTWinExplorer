# External Directory Move Spike Results

> **Scope:** Historical research and isolated observations about tracking an
> externally renamed or moved directory used by a Pathview. This is not an
> implementation decision or a claim that the current application handles all
> of these cases. The internal-operation follow-up is described below; the
> external-move research remains historical.

## Goal

A Pathview should continue to refer to the same directory when that directory,
or one of its ancestors, is renamed or moved externally. When the destination
is known reliably, update the Pathview's path, tree, address, tab label, and
saved Use Case as appropriate. A custom tab name must remain intact.

A change to the directory's own name or location is not, by itself, a change
to its contents. It must not be treated as evidence that the directory's
contents need to be enumerated again. Real content changes and notification
loss still need separate handling.

The hard cases considered here are:

- An external rename within the same parent directory.
- An external move to a different parent on the same volume.
- An external move to another volume, often implemented as copy and delete.
- A rename or move of an ancestor of a directory currently observed by a
  Pathview, possibly while the Pathview is hidden.
- A move while the application is not running or while observation is
  temporarily interrupted.

## Current Context

The application has path-remapping logic for directory changes whose old and
new paths are available. Internal Shell moves can report their source and
actual destination; external rename notifications can also carry both paths.
Those paths can be propagated without invalidating the directory's existing
content cache solely because its path changed.

This does not solve all external moves. Separate removal and creation
notifications do not, on their own, establish that the two paths refer to the
same object. The application also currently has directory observers, and those
observers can themselves prevent an ancestor from being renamed or moved.

For application-owned directory renames and prepared moves, Pathview observers
are temporarily released across the window and restored after success, failure,
or cancellation. The application remaps known actual paths before restoring
observers and compares observed directory modification times across the gap.
This detects some intervening directory changes, but is not a complete journal:
file metadata changes and other changes that do not alter a directory timestamp
can be missed. Native Shell drag/drop, clipboard operations and Shell extension
commands are not covered by this coordination. It does not solve externally
initiated operations: the application cannot assume it knows when another
process is about to rename.

## Observed: Watchers Can Block Ancestor Renames

An isolated local Windows test created `old\child`, enabled a
`FileSystemWatcher` on `old\child`, and attempted `Directory.Move(old, new)`.
The move failed with access denied. Renaming the watched directory itself
worked in a separate test. These are observations on the tested machine and
filesystem, not a guarantee about every filesystem or network provider.

The [.NET runtime issue on this exact scenario](https://github.com/dotnet/runtime/issues/103383)
describes a watcher on a subdirectory blocking rename of its parent. A
maintainer attributes this to Windows directory handles; the issue was closed
as not planned. The suggested workarounds, moving watched directories first or
copying, do not provide transparent external rename tracking for our Pathviews.

The [fsnotify discussion about the same parent-rename problem](https://github.com/fsnotify/fsnotify/issues/356)
contains another reproduction on Windows: the watched directory itself could
be moved, but moving its parent failed. The maintainer later suspected a fix
and closed the issue; a later commenter reported that they still encountered a
similar problem. The discussion does not establish a universal fix.

Important distinction: allowing delete sharing on a handle and avoiding all
ancestor-rename restrictions are not established to be equivalent. A different
handle configuration must be tested rather than assumed not to block.

## Observed: Shell Change Notifications

The isolated experiment used a temporary directory fixture and a WPF window
receiving `SHChangeNotifyRegister` messages. Registrations included a recursive
common root, nonrecursive root/source/destination registrations, and a
registration on the folder itself. The recursive root was also tested with
Shell-only and interrupt-only event sources. PIDLs were converted to paths for
the observations below. The temporary probe was removed afterwards; no product
code was added for it.

| Operation | Observed notifications | Implication for this test |
| --- | --- | --- |
| External `cmd` rename within the same parent | Recursive root and interrupt-only root received `SHCNE_RENAMEFOLDER` with old and new paths; the direct source and folder registrations also received it. The Shell-only root did not. | A common recursive ancestor can provide both paths for this rename, but Shell-only events did not cover this external operation. |
| External `cmd` move to another parent | Recursive root and interrupt-only root received `SHCNE_RMDIR` with the old path, followed by `SHCNE_MKDIR` with the new path. Direct source and destination registrations saw their respective events. | In this configuration there was no paired `SHCNE_RENAMEFOLDER`; the two single-path events alone do not prove identity. |
| Rename through `Shell.Application` | Recursive root, Shell-only root, and direct source received `SHCNE_RENAMEFOLDER` with both paths. | Shell-originated renames can provide an explicit pair. |
| Move through `Shell.Application.MoveHere` to another parent | Recursive root and Shell-only root received separate `SHCNE_RMDIR` and `SHCNE_MKDIR`; direct parents saw their respective events. | Even a Shell-originated move did not produce an old/new pair in this test. |

The nonrecursive common-root registration did not see the rename of a deeper
descendant. A recursive common ancestor did, so registering every parent was
not necessary in this fixture. This does not imply that every external move
will be reported, that its destination will be inside the observed subtree, or
that Shell events cannot be lost or coalesced under other conditions.

In a fresh process, a Shell-only registration on a descendant also prevented
an external `cmd` rename of its ancestor with access denied. Thus, replacing a
descendant `FileSystemWatcher` with this particular Shell registration did not
remove the blocking problem in the tested configuration.

References: [SHChangeNotifyRegister](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotifyregister)
and [Shell change event definitions](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify).

## What Ordinary Watcher Events Can Establish

`FileSystemWatcher` can provide a `Renamed` event with old and new names for
some operations. Microsoft notes that the new name may be unavailable when
matching operating-system notifications are unavailable. For separate source
and destination watches, a move can appear as `Deleted` at the source and
`Created` at the destination. See Microsoft's documentation for
[Renamed](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher.renamed?view=net-10.0)
and [Deleted](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher.deleted?view=net-10.0).

The underlying [ReadDirectoryChangesW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw)
observes changes within a directory or its subtree; it does not report a
change to the watched directory itself. A removal record containing an old
name is not, by itself, a destination lookup. It is therefore too strong to
say that Windows provides no additional information: Shell notifications,
file identities, and the change journal are distinct mechanisms with different
capabilities.

The [Stack Overflow question on move notifications](https://stackoverflow.com/questions/11747726/readdirectorychangesw-file-moved-workaround)
asks about the same deleted/created ambiguity and proposes content hashes as a
possible workaround; it has no answer. Hashes, matching names, timestamps, or
event timing alone are not proof that two directories are the same object.
Scanning directory contents to construct such a fingerprint would also conflict
with the intended no-unnecessary-enumeration behavior.

The [fsnotify rename discussion](https://github.com/fsnotify/fsnotify/issues/26)
likewise warns that an unrelated creation can occur between removal and
creation. It discusses retaining object information for identity comparison.
Some later comments concern Linux-specific APIs and should not be read as a
Windows solution.

## Candidate Approaches

These are alternatives or building blocks, not tested end-to-end solutions.
No approach below should silently guess a destination and overwrite a saved
Use Case when identity is uncertain.

### 1. Observe a common ancestor recursively

Use fewer, higher-level observers so that relevant events beneath an anchor can
be received without keeping a separate watcher open on every Pathview
descendant. Filter notifications to the directories actually needed by the
application. Explicit old/new rename notifications can feed the existing path
remapping logic.

- The Shell spike demonstrated a recursive common ancestor for the tested
  same-parent rename. Existing descendant observers would have to be removed
  or redesigned for this to address their blocking effect.
- A move outside the observed subtree can lose the destination. A root-level
  watcher can see many unrelated changes, incur processing and buffer pressure,
  and require handling overflow or interrupted observation. Access, mounted
  volumes, and network shares need separate evaluation.
- In the tested cross-parent moves, Shell still supplied separate removal and
  creation events. A common watcher alone did not correlate their identity.
- This approach does not automatically detect changes made while the
  application is stopped.

### 2. Store directory identity and resolve its current path

On a supported filesystem, record the volume identity and directory file ID
while the directory is accessible. When a relevant notification or other
reconciliation trigger indicates that the old path may have changed, attempt
to open the directory by ID using `OpenFileById`, obtain its current path with
`GetFinalPathNameByHandleW`, and promptly close the temporary handle. The
returned path could then be fed to the existing remapping logic without
enumerating the directory's contents.

This combines the file-ID advice in [Stack Overflow's unique identifier discussion](https://stackoverflow.com/questions/1866454/unique-file-identifier-in-windows)
with Microsoft's documented [OpenFileById](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-openfilebyid)
and [GetFinalPathNameByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew).
The latter accepts a directory handle; the former requires directory-opening
flags and a handle identifying the volume or share.

- **Not yet tested here:** whether reopening a moved directory by ID and
  resolving its path works for our actual Windows versions, access rights,
  directories, mount points, and rename sequences. A file ID by itself does
  not deliver a change event; a trigger or reconciliation policy is still
  needed. Existing descendant observers can still prevent the move before
  resolution ever happens.
- For an NTFS object that remains on the same volume, the ID is useful across
  rename and move. IDs are filesystem-specific, can be reused after deletion,
  and may change when an object is replaced or recreated. They are not a
  permanent global identity. See also the [NTFS file ID versus object ID discussion](https://stackoverflow.com/questions/3892592/unique-file-identifiers-on-ntfs-and-object-id).
- Microsoft's `OpenFileById` documentation lists SMB 3.0 as unsupported. Other
  filesystems, offline volumes, permissions, volume identification, reparse
  points, and path normalization need explicit treatment. Resolving a final
  path through a link may not preserve the path spelling the user originally
  chose.
- A cross-volume copy/delete creates a different object, so the original ID
  cannot generally identify the new copy. A deleted object can no longer be
  reopened in the usual way. File-ID reuse also makes an old persisted ID
  insufficient proof after a long interruption.
- Persisting identity in a Use Case would change its stored format and require
  an explicit compatibility and migration decision; no such decision has been
  made.

An alternative is retaining a directory handle and querying it later. That
could avoid reopening by ID but risks recreating the ancestor-lock problem;
whether a particular handle and sharing mode blocks the operation requires an
isolated test. Neither version is currently a proven fix for the application.

### 3. Read the volume change journal

The Windows [USN change journal](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journals)
records filesystem changes. Microsoft documents that a rename or move creates
old-parent and new-parent records, and `USN_RECORD_V2` includes a file
reference number, parent reference number, name, and reason flags. See
[USN_RECORD_V2](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_record_v2).
These records offer a basis for correlating same-volume changes by identity,
including an ancestor's move, rather than guessing from notification timing.

- This is volume-level observation, not a drop-in `FileSystemWatcher`
  replacement. Records contain names and parent IDs rather than ready-made
  full paths, so path resolution and ancestor relationships need design.
- Filesystem and volume support, journal existence, access rights, event
  latency, record versions, volume reconnection, retention, journal resets,
  and recovery after lost history must be investigated. Do not assume it is
  available to a normal user or on network shares.
- A journal may help cover gaps or application downtime only while the needed
  records remain available and a valid checkpoint is retained. It does not
  inherently correlate a cross-volume copy and delete.
- It does not remove any blocking descendant watchers unless their design also
  changes.

### 4. Extended directory notifications

[ReadDirectoryChangesExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesexw)
can provide [extended notification information](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-file_notify_extended_information),
including file and parent IDs. Microsoft documents NTFS support for this
extended mechanism. Combining IDs from source and destination notifications
may be worth investigating when both sides are observed.

This is a research candidate, not an established move solution: it observes a
bounded scope, destination events may be absent or lost, and an event's ID does
not automatically supply a full destination path. Its behavior for our exact
directory moves, observer placement, and lock constraints has not been tested.

### 5. Polling or reconciliation

Some applications compare current state with a previously recorded snapshot
instead of relying exclusively on notifications. In a [Reddit discussion](https://www.reddit.com/r/dotnet/comments/7ccksa/can_filesystemwatcher_objects_detect_offline/),
a developer chose a background full scan on startup to account for changes
while their application was down. This is a different use case and does not
solve our external-move identity problem by itself.

Polling could be a fallback for unsupported providers or missed events, but a
path-existence check only says that the old path is missing; it does not reveal
the destination. Full scans cost I/O, may still leave ambiguous identities,
and should not be confused with the requirement to avoid re-enumerating clean
Pathview contents. Any fallback and its user-visible behavior remain undecided.

## Suggested Follow-Up Experiments

The following are proposed only; none was run as part of this report.

1. In a disposable local NTFS fixture, obtain the volume and directory ID,
   close the directory handle, externally rename and move the directory within
   the volume, then reopen by ID and resolve its current path. Repeat with an
   ancestor move and with appropriate permissions, checking that the resolved
   path corresponds to the original object.
2. Separately test which watcher or handle placements and sharing flags allow
   external ancestor renames. In particular, test a higher-level recursive
   observer without any descendant observers. Do not infer this result merely
   from the ID lookup experiment.
3. Check how a trigger reaches a hidden Pathview when the destination is inside
   and outside the observed subtree, and how lost events or temporarily
   unavailable paths are represented without guessing.
4. Evaluate a journal prototype only after checking filesystem support,
   ordinary-user access, checkpoint and retention behavior, and overhead.
5. Test explicit fallbacks for network shares, unsupported filesystems,
   cross-volume copy/delete, deletion and recreation, volume disconnects,
   application restart, and notification overflow.

For a successful identity-based case, verify that the Pathview, tree, visible
path, tab label, and Use Case all follow the correct directory while preserving
custom tab names and the existing content cache. Verify actual content changes
independently, including changes during any observer interruption. Do not treat
an unverified destination as a confirmed move.