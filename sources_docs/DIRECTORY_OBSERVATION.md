# Directory Observation

## Decision

Pathview keeps the `FileSystemWatcher` implementation as the default. The
`SHChangeNotifyRegister` implementation remains available for experiments; it
does not replace or serve as a fallback for the default observer.

The Shell alternative detects the direct operations tested so far, but it has
not met all of the existing Pathview tests or the strict isolation test. The
default observer passed the Pathview refresh lifecycle test and retains the
existing behavior for direct subdirectory metadata. Neither implementation
guarantees that every change will be delivered.

## Common Scope and Lifecycle

For a current path such as `C:\A\B`, Pathview registers the individual paths
`C:\`, `C:\A`, and `C:\A\B`. It does not register only the drive root and then
filter a recursive drive-wide stream. The ancestor paths support the path and
tree views, including directory renames. The current directory and each
ancestor are registered separately; files are not individually registered.

Pathview receives notifications on the WPF dispatcher. Identified item changes
are queued for incremental content updates; metadata is updated in the cache.
Dirty tree nodes are handled separately. A dirty view is updated on tab
activation, rather than immediately on every notification. Unidentified changes
and watcher errors require a full refresh. Observers remain
active when a tab is unloaded, and are replaced when the observed paths change
and disposed when the tab closes. Suspension and resumption are handled
separately by Pathview.

## FileSystemWatcher: Default

The existing implementation creates a nonrecursive `FileSystemWatcher` for
each registered path. The current path watches file and directory names,
attributes, last-write time, and size. Ancestors watch directory names and
attributes, with changed-file notifications filtered out.

It also creates a recursive, name-only watcher rooted at the current directory.
It receives creation, deletion and rename events from the subtree, but forwards
only changes immediately inside a direct child folder as metadata changes to
that child. This accommodates changes to the displayed child folder's date
without invalidating the current directory's enumeration. Events deeper in the
tree are discarded by the callback, although the recursive watcher can still
receive them.

Advantages:

- Delivers specific paths and change types, including old and new rename paths.
- The existing Pathview lifecycle test covers structural changes, direct folder
  dates, nested name changes, cache reuse, and tab activation.
- Watcher errors mark the view dirty rather than silently treating it as clean.

Limitations:

- The additional recursive watcher can receive many events in a busy subtree,
  even though deeper events are filtered out. Its cost has not been measured.
- Notifications can be lost, for example on buffer overflow; inaccessible paths,
  filesystem and network support, and changes while observation is suspended
  also limit completeness. Error handling does not guarantee full recovery.
- Filesystem events do not describe every Shell-level change, such as a changed
  file association or icon handler.

## Shell Notifications: Experimental

The alternative creates a nonrecursive `SHChangeNotifyRegister` registration
for each path, requesting `SHCNE_ALLEVENTS` from filesystem and Shell sources
with `SHCNRF_NewDelivery`. It receives notifications through an `HwndSource`
and checks the reported paths against the registered directory and its direct
children. It does not register individual items or use a recursive interrupt
registration.

Direct create, delete and rename events are translated into corresponding
filesystem-style notifications. Rename events preserve old and new paths when
both are direct children; moves across a watched boundary are represented as
deletion or creation. Direct item attribute and update events are treated as
metadata changes. A matching `SHCNE_UPDATEDIR` marks the directory for a full
refresh. Global events that cannot be attributed to a directory, including
association and system image-list changes, are not forwarded by this observer.

Advantages:

- Can receive Shell-originated events as well as filesystem-originated events.
- No additional recursive `FileSystemWatcher` is installed in this mode.
- In the local tests described below, direct file and folder operations were
  detected, including folder timestamp changes and renames.

Limitations:

- Notifications may be combined, and an event does not necessarily reveal the
  operation that caused it. Different Shell and filesystem providers may behave
  differently. The current callback does not record the original Shell event ID.
- Registrations can fail and there is no automatic filesystem-watcher fallback.
  The mode depends on the window message pump and has not been measured against
  the default for CPU usage, notification volume, or latency.
- A notification concerning a direct child can occur around a deeper change.
  The current tests cannot establish the original event type or prove the
  causal relationship; ignoring every child metadata notification would also
  risk missing a desired direct folder date change.
- As with the default, notification support and delivery are not guaranteed for
  every filesystem, network path, or period when observation is inactive.

Microsoft documents the event sources and possible notification coalescing in
[SHChangeNotifyRegister](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotifyregister)
and the event meanings in
[SHChangeNotify](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify).

## Test Results and Open Questions

The comparison in [tests/DirectoryObservers.Tests.ps1](../tests/DirectoryObservers.Tests.ps1)
used .NET operations on a local NTFS volume, one observed test directory per
scenario, and a two-second observation window. With all Shell event types
registered, the tested direct file creates, writes, date changes, renames and
deletes, and direct folder creates, renames, date changes and deletes, produced
notifications. Explicit parent `SHCNE_UPDATEDIR`, direct `SHCNE_CREATE`,
direct folder `SHCNE_UPDATEITEM` and file rename controls also arrived.

The strict no-notification assertions did not all pass: one run reported a
translated `Changed` notification for the direct child during a nested file
rename and another during an explicitly sent grandchild `SHCNE_UPDATEDIR`
control. The test did not capture the raw event ID or establish the cause of
either notification. Other tested nested operations produced no notification in
that run. These observations are not a guarantee for other Windows versions,
filesystems, providers, workloads, or timing.

[tests/PathviewRefresh.Tests.ps1](../tests/PathviewRefresh.Tests.ps1) passed with
the default observer. With the Shell observer, it failed at the folder metadata
check because the enumeration-dirty flag was already set; the cache generation
and displayed date had not yet changed. The reason for that flag was not
established. Tests have not demonstrated that the Shell alternative preserves
the default implementation's behavior across the full Pathview workflow.

Before reconsidering the default, capture raw Shell event IDs, affected paths,
and child timestamps; compare the two event sources separately; investigate the
Pathview failure; and repeat the tests on representative locations, including
network paths. A performance comparison also requires measurement.

## Selecting and Running Tests

To select the experimental observer for a new application process in
PowerShell:

```powershell
$env:KIS_DIRECTORY_OBSERVER = 'shell'
& '.\bin\Debug\net10.0-windows\KIS Explorer.exe'
```

Unset the variable to use the default in subsequently launched processes:

```powershell
Remove-Item Env:KIS_DIRECTORY_OBSERVER
```

Close an existing application instance before changing the observer for a new
instance. Run the production observer test and the separate experimental Shell
observer test with:

```powershell
pwsh -NoProfile -STA -File .\tests\DirectoryObservers.Tests.ps1
pwsh -NoProfile -STA -File .\tests\experimental\ShellDirectoryObserver.Tests.ps1
pwsh -NoProfile -STA -File .\tests\PathviewRefresh.Tests.ps1
```

The experimental test intentionally reports failures when its strict isolation
expectations are not met. It is not included in the standard test run. The
Pathview test uses the observer selected by the environment variable.