# Scroll Sync Handoff

## Goal

Keep the native `IExplorerBrowser` Shell view as the real file list and mirror its first visible item index in the adjacent WPF `ListView` prototype. The earlier index-based version moved the WPF list along with the Shell view, with roughly a +/-1 item mismatch. Percentage-based `ScrollPattern` synchronization was rejected because the two lists advanced at different rates.

## Current Source State

- `ExplorerTabView.xaml` contains the adjacent WPF file table and native Shell host.
- The WPF table is populated from the Shell view's displayed filesystem items, in Shell view order; it does not enumerate the active directory independently. `ShellExplorerBrowserHost.GetDisplayedFileSystemPaths()` obtains `SVGIO_ALLVIEW` through `IShellView.GetItemObject`, reads the Shell IDList Array, and resolves its PIDLs to filesystem paths.
- `ExplorerTabView.xaml.cs` uses a 20-DIP prototype row height. Its 100-ms timer currently calls `SyncPrototypeScroll()`, which asks the host for the Shell index and scrolls only the WPF `ScrollViewer`.
- `SyncPrototypeScroll(int)` currently passes the item index directly as the WPF vertical offset. This is the pre-adjustment behavior associated with the earlier approximate sync; do not multiply by row height unless intentionally retesting that change.
- `ShellExplorerBrowserHost.cs` gets the Shell item count from CIDA and gets displayed item paths from the same CIDA data. It gets the visible index with `IFolderView2::GetVisibleItem(0, false)`, then walks backward to the first visible index. `ReportViewMetrics` also calls the count helper.
- The later experimental header-gap margin, index-times-row-height mapping, COM-only timer and COM method substitutions have been rolled back. The redundant-`SetViewSize` guard was also removed.
- `dotnet build -c Debug` succeeded after that targeted rollback. No runtime scroll test was performed after it.
- Changes in these files are part of broader uncommitted work. Do not revert whole files or use a broad checkout/reset.

## Timeline

1. Added the WPF index probe; populated its rows from the Shell CIDA item count.
2. Tried percentage-based Shell/WPF scrolling. Both moved, but row progression drifted (about two Shell items for one WPF item).
3. Replaced percentage mapping with an index from `IFolderView2::GetVisibleItem`; the WPF probe then followed approximately, with a +/-1 mismatch. This is the baseline the user wants to retry.
4. Later changed index-to-DIP scaling and header geometry, then investigated a Shell scroll reset. Those changes did not solve it and were rolled back.
5. A diagnostic build that polled only the index left the WPF table intentionally unchanged. That diagnostic handler was subsequently restored to `SyncPrototypeScroll()`.

## Evidence and Caveats

- Microsoft documents `GetVisibleItem` as returning a visible item relative to a start index and direction. The docs do not describe changing the Shell scroll position.
- In one controlled test, disabling the 100-ms polling timer kept UIA Shell scroll percent at 100%. A timer that only read CIDA count also kept it at 100%; a timer making one `GetVisibleItem` call was followed by a change from 100% to 23.41%. This implicates the COM call path, but the behavior is undocumented and should be reproduced before treating causality as settled.
- A separate test toggled `Hide directories` while setting up the long list. That causes a filter refresh and `SetRect`, so scroll observations overlapping that refresh are contaminated. Let the refresh finish before testing; do not toggle filters during the scroll measurements.
- Always identify the tested process by its full executable path under this workspace. An older comparison instance was previously mistaken for the current build.

## Suggested Next Steps

1. Inspect the current diff and preserve unrelated/uncommitted changes.
2. Build and launch `bin/Debug/net10.0-windows/SUTWinExplorer.exe`; verify its PID and executable path.
3. Prepare a long list, let any filter refresh finish, then leave filters and window size unchanged.
4. Reproduce the earlier approximate sync with short scrolls, then separately test the scroll-end reset. Record Shell percent, visible Shell item names/index, WPF visible index, and process-specific trace timestamps.
5. If the reset reproduces, isolate the timer, CIDA count, and `GetVisibleItem` call without changing filters. Keep the WPF update enabled in the final candidate; a diagnosis that disables `SyncPrototypeScroll` does not meet the goal.
6. Preserve the known +/-1 mismatch as the baseline while investigating the reset. Do not reintroduce percentage mapping or index-times-20 scaling without a focused comparison.

## Restart (2026-10-18): minimal table, no scroll sync yet

The source was reset to the committed state, so the "Current Source State" section above no longer applies. A fresh minimal version now exists: `PrivateFileTable` (a one-column `ListView`) sits left of `ShellBrowserSlot` in `ExplorerTabView.xaml`. `ShellFileOperations.GetDisplayedFileSystemPaths` reads `SVGIO_ALLVIEW` through the same `IDataObject`/`CF_HDROP` path as the selection query, exposed as `ShellExplorerBrowserHost.GetDisplayedFileSystemPaths()`. `Pathview.RefreshShellStatusCount` (called after navigation, filter changes and filesystem refreshes) restarts a 300-ms debounce timer that repopulates the table. Runtime-checked: item list and order match the Shell view, and the table follows filter toggles and navigation. There is no scroll synchronization or `GetVisibleItem` call yet.

### Scroll sync (2026-10-18)

The hosted Shell view is DirectUI, not `SysListView32`, so `LVM_*` messages (`LVM_GETTOPINDEX`, `LVM_GETITEMRECT`) are unavailable. The sync reads the vertical `ScrollBar` child HWND under the host window with `GetScrollInfo(SB_CTL)`. No COM call is involved, so the `GetVisibleItem` side effect does not apply. Observed: the range is exactly *item count × 100* (4616 items gave max 461599) and `nPos / 100` is the fractional first visible row. `Pathview.ScrollSyncTimer_Tick` polls every 30 ms and scrolls the table's `ScrollViewer` to `position * itemCount / total * rowPitch` (pixel scrolling through a virtualized `ListView` with `VirtualizingPanel.ScrollUnit="Pixel"`). Row pitch is measured once between containers 0 and 1 and cached, because `ActualHeight` is 1 px smaller than the real spacing and caused drift, and virtualization recycles the first rows while scrolling. Runtime-checked in `C:\Windows\System32` (4616 files): wheel scrolling to a middle position, the end and back to the top keeps both lists on the same items. Known residual offset: about 10 px at scroll position 0 (the Shell has top padding) and 2–3 px elsewhere.

### Findings along the way

- **Table must be virtualized.** The first version used `CanContentScroll="False"` (no virtualization). With 4616 items each table refresh blocked the UI for about 2.2 s (335 ms item query, the rest layout); virtualization cut it to about 0.39 s. The remaining cost is the COM query for the displayed items.
- **Tree click bug (unrelated to the spike, fixed on `main` in `87ee3d8`).** `Tree_PreviewMouseLeftButtonDown` called `tree.Focus()`, which focuses the selected item and scrolls it into view on mouse down. If the selection was scrolled out of view, the tree jumped before the button release and the release hit another row. Fix: suppress `RequestBringIntoView` on the tree items only while focusing. It was not caught earlier because short scrolls keep the selection visible.
- Remaining ideas: align the table's half-row offset, block the mouse wheel on the table, move the displayed-items query off the UI thread or make it lazy.

### Geometry alignment (2026-10-18, measured at 96 DPI)

- **Widget bounds are identical.** UIA reports the Shell host (`ExplorerBrowserControl`) and the table `ListView` both at the same top and 553 DIP height. The Shell draws a 1 px `#646464` frame inside its rect; the table now has the same frame (`BorderThickness="1,1,0,1"`, `BorderBrush="#646464"`), sharing the vertical edge with the Shell's left frame. Pixel check: frame rows y=196 and y=748 for both, columns x=286 (table left), 486 (Shell left), 1167 (Shell right).
- **Header.** The Shell header is 25 px (26 with the frame line), and its first row starts 30 px below the list top. The table uses a minimal `GridViewColumnHeader` template: white background, no border, separators or gripper, text centered in the top 22 DIP, total height 30 DIP. At scroll position 0 the header text rows (205–213) and the first rows (234–242, 255, 276, 297) are pixel-identical to the Shell's. Header metrics are DIP values measured at 96 DPI; the Shell may not scale linearly at other DPIs, which is untested.
- **Not aligned yet while scrolled.** Earlier measurements (before the header change) showed the table about 3 px above the Shell right after scrolling began and about 2 px below at the end of a 4616-item list. Relative to position 0 that is a step of roughly 7 px as soon as the Shell scrolls, plus a slow drift of about 5 px over the whole list. Hypothesis: the Shell's scroll position excludes the gap between header and first row, or its row pitch differs slightly from `position / 100` rows. Re-measure at positions 0, small, middle and end with the new header before changing the mapping. Do not change `ScrollSyncTimer_Tick` without a new measurement.

### Scrolling top gap (2026-10-28, measured at 96 DPI)

- After rebasing onto `main`, UI Automation measurements in `C:\Windows\System32` showed matching row positions at the top, but the private table was 6 px lower at 1% and 50%, and 7 px lower at the end. Small scroll increments showed the difference increasing gradually over the first row.
- The private header is now 24 DIP high instead of 30. A 6-DIP render-only translation of the table's rows supplies the initial gap; it decreases linearly to zero over the first Shell row. This is an empirical approximation of the observed Shell behavior, not a documented Shell metric. The scroll-offset mapping and virtualized row sizes are unchanged.
- Adding a margin to the first item was tried and discarded: it disturbed virtualized scrolling and did not reliably restore the gap after returning to the top. A single-row height is used only temporarily and is not cached as the pitch for later multi-row lists.
- On the same machine at 96 DPI, UI Automation measured equal row positions at the top, several small scroll increments, 1%, and 50%; at 100% the table was 1 px lower. Returning to the top restored alignment. A single-result filter, an empty-result filter, and clearing the filter were also checked. Other DPI settings and Windows versions remain untested.

## Earlier file-table implementation (rolled back)

- The left WPF table now mirrors the actual filesystem items returned by the Shell view, rather than displaying generated numeric rows.
- The Shell view remains authoritative. The table follows its current item order and filtering; it is refreshed after navigation, filter changes, and filesystem notifications.
- The existing first-visible-index scroll synchronization is unchanged. The approximate alignment and the possible `GetVisibleItem` side effect described above still need a runtime check.
