using System.Diagnostics;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Media;

namespace SUTWinExplorer;

internal static class SutShell
{
    private static readonly ConcurrentDictionary<string, DirectoryIconSession> DirectoryIcons = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object OverlayScheduleLock = new();
    private static readonly AutoResetEvent OverlayScheduleChanged = new(false);
    private static string[]? _openOverlayDirectories;
    private static string? _activeOverlayDirectory;
    private static readonly HashSet<string> FailedOverlayDirectories = new(StringComparer.OrdinalIgnoreCase);
    private static bool _overlayWorkerStarted;
    private static long _overlayScheduleVersion;

    private static string DirectoryKey(string path) => ShellLocations.IsTopPath(path)
        ? ShellLocations.TopPath : Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    internal static void SetOverlayDirectories(IEnumerable<string> directories, string? activeDirectory)
    {
        var paths = directories.Where(path => !string.IsNullOrWhiteSpace(path)).Select(DirectoryKey)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var active = string.IsNullOrWhiteSpace(activeDirectory) ? null : DirectoryKey(activeDirectory);
        lock (OverlayScheduleLock)
        {
            if (!string.Equals(_activeOverlayDirectory, active, StringComparison.OrdinalIgnoreCase))
                FailedOverlayDirectories.Clear();
            _openOverlayDirectories = paths;
            _activeOverlayDirectory = active;
            _overlayScheduleVersion++;
        }
        OverlayScheduleChanged.Set();
    }

    private static void ScheduleOverlays()
    {
        lock (OverlayScheduleLock)
        {
            if (!_overlayWorkerStarted)
            {
                _overlayWorkerStarted = true;
                var thread = new Thread(ProcessOverlays) { IsBackground = true, Priority = ThreadPriority.Lowest, Name = "KIS overlay refresh" };
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
            }
        }
        OverlayScheduleChanged.Set();
    }

    private static void ProcessOverlays()
    {
        while (true)
        {
            string[]? paths;
            string? active;
            bool activeFailed;
            long scheduleVersion;
            lock (OverlayScheduleLock)
            {
                paths = _openOverlayDirectories;
                active = _activeOverlayDirectory;
                activeFailed = active is not null && FailedOverlayDirectories.Contains(active);
                scheduleVersion = _overlayScheduleVersion;
            }
            DirectoryIconSession? selected = null;
            if (paths is null)
                selected = DirectoryIcons.Values.FirstOrDefault(session => session.HasPending);
            else if (active is null)
            {
                OverlayScheduleChanged.WaitOne();
                continue;
            }
            else if (active is not null && !activeFailed &&
                     (!DirectoryIcons.TryGetValue(active, out var activeSession) || !activeSession.IsPrepared))
            {
                OverlayScheduleChanged.WaitOne();
                continue;
            }
            else
            {
                if (active is not null && DirectoryIcons.TryGetValue(active, out var current) && current.HasPending)
                    selected = current;
                selected ??= paths.Select(path => DirectoryIcons.GetValueOrDefault(path))
                    .FirstOrDefault(session => session is not null && session.HasPending);
                selected ??= DirectoryIcons.Values.FirstOrDefault(session => session.HasPending);
            }
            if (selected is null)
                OverlayScheduleChanged.WaitOne();
            else
            {
                lock (OverlayScheduleLock)
                    if (scheduleVersion != _overlayScheduleVersion)
                        continue;
                selected.ProcessNextOverlay();
            }
        }
    }
    internal static void EnsureDirectoryAccessible(string path)
    {
        if (ShellLocations.IsTopPath(path))
            return;

        using var entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
        _ = entries.MoveNext();
    }

    internal static Task<DirectorySnapshot> OpenDirectoryAsync(
        string path, bool showDirectories, bool hideInternal, string namePattern, CancellationToken cancellationToken) =>
        OpenSortedDirectoryAsync(path, showDirectories, hideInternal, namePattern, new DirectorySortState(), cancellationToken);

    internal static Task<DirectorySnapshot> OpenSortedDirectoryAsync(
        string path, bool showDirectories, bool hideInternal, string namePattern,
        DirectorySortState sorting, CancellationToken cancellationToken) =>
        OpenCachedDirectoryAsync(path, showDirectories, hideInternal, namePattern, sorting, new DirectoryDataCache(), cancellationToken);

    internal static Task<DirectorySnapshot> OpenCachedDirectoryAsync(
        string path, bool showDirectories, bool hideInternal, string namePattern,
        DirectorySortState sorting, DirectoryDataCache cache, CancellationToken cancellationToken)
    {
        var sortPairs = sorting.Pairs;
        return
        RunOnShellThread(token =>
        {
            var key = DirectoryKey(path);
            DirectoryItem[] source;
            try { source = cache.GetDirectory(path, token); }
            catch
            {
                lock (OverlayScheduleLock) FailedOverlayDirectories.Add(key);
                OverlayScheduleChanged.Set();
                throw;
            }
            lock (OverlayScheduleLock) FailedOverlayDirectories.Remove(key);
            var overlayCompletion = DirectoryIcons.GetOrAdd(key, _ => new DirectoryIconSession()).Prepare(source);
            ScheduleOverlays();
            var items = new List<DirectoryItem>();
            var directoryCount = 0;
            foreach (var item in source)
            {
                token.ThrowIfCancellationRequested();
                if (item.IsDirectory) directoryCount++;
                try
                {
                    if ((!showDirectories && item.IsDirectory) || (hideInternal && !item.IsDrive && item.IsInternal))
                        continue;
                    if (InternalItemFilter.MatchesName(item.Name, namePattern))
                        items.Add(item);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                }
            }

            var sortColumns = sortPairs.Select(pair => pair.Column).ToHashSet();
            var values = new List<DirectorySortValues>(items.Count);
            foreach (var item in items)
            {
                token.ThrowIfCancellationRequested();
                var icons = sortColumns.Contains(DirectorySortColumn.TypeApp1Icon) ? item.Icons : null;
                values.Add(new DirectorySortValues(item,
                    sortColumns.Contains(DirectorySortColumn.Size) ? item.Size : null,
                    sortColumns.Contains(DirectorySortColumn.DateModified) ? item.Modified : null,
                    sortColumns.Contains(DirectorySortColumn.TypeApp2Name) ? item.Type : string.Empty,
                    item.MediaType, icons?.BaseIconIndex));
            }

            IOrderedEnumerable<DirectorySortValues> ordered = values.OrderByDescending(value => value.Item.IsDirectory);
            foreach (var pair in sortPairs)
            {
                var ascending = pair.Criterion == DirectorySortCriterion.Ascending;
                ordered = pair.Column switch
                {
                    DirectorySortColumn.Name => ascending
                        ? ordered.ThenBy(value => value.Item.Name, StringComparer.CurrentCultureIgnoreCase)
                        : ordered.ThenByDescending(value => value.Item.Name, StringComparer.CurrentCultureIgnoreCase),
                    DirectorySortColumn.TypeApp2Name => ascending
                        ? ordered.ThenBy(value => value.Type, StringComparer.CurrentCultureIgnoreCase)
                        : ordered.ThenByDescending(value => value.Type, StringComparer.CurrentCultureIgnoreCase),
                    DirectorySortColumn.MediaTypeIcon => ascending
                        ? ordered.ThenBy(value => value.MediaType == MediaType.None).ThenBy(value => value.MediaType)
                        : ordered.ThenBy(value => value.MediaType == MediaType.None).ThenByDescending(value => value.MediaType),
                    DirectorySortColumn.Size => ascending
                        ? ordered.ThenBy(value => value.Size) : ordered.ThenByDescending(value => value.Size),
                    DirectorySortColumn.DateModified => ascending
                        ? ordered.ThenBy(value => value.Modified) : ordered.ThenByDescending(value => value.Modified),
                    DirectorySortColumn.TypeApp1Icon => ascending
                        ? ordered.ThenBy(value => value.BaseIconIndex) : ordered.ThenByDescending(value => value.BaseIconIndex),
                    _ => throw new ArgumentOutOfRangeException(nameof(sorting))
                };
            }
            var result = ordered.ThenBy(value => value.Item.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(value => value.Item.FullPath, StringComparer.OrdinalIgnoreCase)
                .Select(value => value.Item).ToArray();
            token.ThrowIfCancellationRequested();
            return new DirectorySnapshot(result, directoryCount, source.Length - directoryCount, overlayCompletion);
        }, cancellationToken);
    }

    internal static Task<IReadOnlyList<FileEntry>> GetDirectoryRangeAsync(
        DirectorySnapshot snapshot, int start, int count, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(start);
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        if (start > snapshot.Count || count > snapshot.Count - start)
            throw new ArgumentOutOfRangeException(nameof(count));

        return RunOnShellThread<IReadOnlyList<FileEntry>>(token =>
        {
            var entries = new List<FileEntry>(count);
            foreach (var item in snapshot.Items.Skip(start).Take(count))
            {
                token.ThrowIfCancellationRequested();
                entries.Add(item.Entry);
            }
            token.ThrowIfCancellationRequested();
            return entries;
        }, cancellationToken);
    }

    internal static Task<bool> RefreshCachedItemMetadataAsync(
        DirectoryDataCache cache, string directoryPath, string itemPath) =>
        RunOnShellThread(_ => cache.RefreshItemMetadata(directoryPath, itemPath), CancellationToken.None);

    private static Task<T> RunOnShellThread<T>(Func<CancellationToken, T> operation, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                completion.TrySetResult(operation(cancellationToken));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                completion.TrySetCanceled(cancellationToken);
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }

    internal static string? GetDirectoryTarget(string path) => ShellFileOperations.GetDirectoryTarget(path);

    internal static string? GetLinkTarget(string path) => ShellFileOperations.GetLinkTarget(path);

    internal static string GetFileSystemName(string path)
    {
        var trimmedPath = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var name = Path.GetFileName(trimmedPath);
        return name.Length > 0 ? name : trimmedPath[(trimmedPath.LastIndexOfAny([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]) + 1)..];
    }

    internal static string? GetEditName(string path)
    {
        var root = Path.GetPathRoot(path);
        return root is not null && string.Equals(Path.TrimEndingDirectorySeparator(path),
            Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase)
            ? null
            : Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
    }

    internal static string Rename(string path, string name, IntPtr owner)
    {
        if (GetEditName(path) is null || string.IsNullOrWhiteSpace(name) || name is "." or ".." ||
            name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("Enter a valid file or directory name.", nameof(name));
        var target = Path.Combine(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path))!, name);
        if (!string.Equals(path, target, StringComparison.OrdinalIgnoreCase) &&
            (File.Exists(target) || Directory.Exists(target)))
            throw new IOException("An item with that name already exists.");
        return ShellItemOperations.Rename(path, name, owner);
    }

    internal static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    internal static void Link(IReadOnlyList<string> paths, string destination, IList<string> insertedPaths) =>
        ShellFileOperations.Link(paths, destination, insertedPaths);

    internal static void Copy(IReadOnlyList<string> paths, string destination, IntPtr owner, IList<string> insertedPaths) =>
        ShellFileOperations.Copy(paths, destination, owner, insertedPaths);

    internal static void CopyToClipboard(IReadOnlyList<string> paths, IntPtr owner)
    {
        using var menu = SutContextMenuFactory.GetItemMenu(paths, owner);
        menu.InvokeVerb("copy");
    }

    internal static bool ClipboardContainsItems()
    {
        return TryGetClipboardCopyPaths(out _);
    }

    internal static void PasteFromClipboard(string path, IntPtr owner)
    {
        if (!TryGetClipboardCopyPaths(out var paths))
            throw new InvalidOperationException("The clipboard does not contain a supported copy operation.");
        ShellFileOperations.Copy(paths, path, owner, new List<string>());
    }

    private static bool TryGetClipboardCopyPaths(out string[] paths)
    {
        paths = [];
        try
        {
            var data = System.Windows.Clipboard.GetDataObject();
            if (data is null || !data.GetDataPresent(System.Windows.DataFormats.FileDrop, false) ||
                data.GetData(System.Windows.DataFormats.FileDrop, false) is not string[] items || items.Length == 0 ||
                data.GetData("Preferred DropEffect", false) is not MemoryStream effect)
                return false;
            var bytes = effect.ToArray();
            if (bytes.Length < sizeof(uint) || (BitConverter.ToUInt32(bytes, 0) is not (1 or 5)))
                return false;
            paths = items;
            return true;
        }
        catch (ExternalException) { return false; }
    }

    internal static void Move(IReadOnlyList<string> paths, string destination, IntPtr owner, IList<string> insertedPaths) =>
        ShellFileOperations.Move(paths, destination, owner, insertedPaths);

    internal static void MoveWithDirectoryChanges(IReadOnlyList<string> paths, string destination, IntPtr owner, IList<string> insertedPaths,
        IList<(string OldPath, string NewPath)> movedDirectories) =>
        ShellFileOperations.Move(paths, destination, owner, insertedPaths, movedDirectories);

    internal static void MoveDirectoryWithName(string path, string destination, string newName, IntPtr owner, IList<string> insertedPaths,
        IList<(string OldPath, string NewPath)> movedDirectories) =>
        ShellFileOperations.MoveDirectoryWithName(path, destination, newName, owner, insertedPaths, movedDirectories);

    internal static void Delete(IReadOnlyList<string> paths, IntPtr owner) =>
        ShellFileOperations.Delete(paths, owner);

    internal static void ShowItemMenu(IReadOnlyList<string> paths, IntPtr owner, Action? rename = null)
    {
        using var menu = SutContextMenuFactory.GetItemMenu(paths, owner, rename);
        menu.Show();
    }

    internal static void ShowItemMenuWithOpenLocation(IReadOnlyList<string> paths, IntPtr owner, Action? rename, ShellMenuAction? openLocation)
    {
        using var menu = SutContextMenuFactory.GetItemMenuWithOpenLocation(paths, owner, rename, openLocation);
        menu.Show();
    }

    internal static void ShowBackgroundMenu(string path, IntPtr owner)
    {
        using var menu = SutContextMenuFactory.GetBackgroundMenu(path, owner);
        menu.Show();
    }

    internal static void ShowNewMenu(string path, IntPtr owner, int x, int y)
    {
        using var menu = SutContextMenuFactory.GetBackgroundMenu(path, owner);
        menu.ShowSubmenu(SutContextMenuFactory.FindBackgroundNewSubmenu, x, y);
    }

    internal static void ShowProperties(IReadOnlyList<string> paths, IntPtr owner)
    {
        using var menu = SutContextMenuFactory.GetItemMenu(paths, owner);
        menu.InvokeVerb("properties");
    }

    internal static IDisposable ObserveDirectories(IEnumerable<string> paths, Action changed) =>
        new DirectoryObserver(paths, _ => changed(), null);

    internal static IDisposable ObservePathviewDirectories(IEnumerable<string> paths, string currentPath, Action<DirectoryNotification> changed) =>
        string.Equals(Environment.GetEnvironmentVariable("KIS_DIRECTORY_OBSERVER"), "shell", StringComparison.OrdinalIgnoreCase)
            ? new ShellDirectoryObserver(paths, changed)
            : new DirectoryObserver(paths, changed, currentPath);

    private sealed class ShellDirectoryObserver : IDisposable
    {
        private const int RenameItem = 0x00000001;
        private const int CreateItem = 0x00000002;
        private const int DeleteItem = 0x00000004;
        private const int CreateDirectory = 0x00000008;
        private const int DeleteDirectory = 0x00000010;
        private const int Attributes = 0x00000800;
        private const int UpdateDirectory = 0x00001000;
        private const int UpdateItem = 0x00002000;
        private const int UpdateImage = 0x00008000;
        private const int RenameDirectory = 0x00020000;
        private const int ExtendedEvent = 0x04000000;
        private const int AssociationChanged = 0x08000000;
        private const int AllEvents = 0x7fffffff;
        private const int NotificationMessage = 0x8000 + 0x272;
        private readonly HwndSource _window;
        private readonly HashSet<string> _paths = new(StringComparer.OrdinalIgnoreCase);
        private readonly List<uint> _registrations = [];
        private readonly Action<DirectoryNotification> _changed;

        internal ShellDirectoryObserver(IEnumerable<string> paths, Action<DirectoryNotification> changed)
        {
            _changed = changed;
            _window = new HwndSource(new HwndSourceParameters("KIS directory observer") { WindowStyle = 0 });
            _window.AddHook(WindowProcedure);
            foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (SHParseDisplayName(path, IntPtr.Zero, out var itemIdList, 0, out _) < 0 || itemIdList == IntPtr.Zero)
                    continue;
                try
                {
                    var entry = new ShellChangeNotifyEntry { ItemIdList = itemIdList, Recursive = false };
                    var registration = SHChangeNotifyRegister(_window.Handle, 0x0001 | 0x0002 | 0x8000,
                        AllEvents, NotificationMessage, 1, ref entry);
                    if (registration == 0)
                    {
                        Debug.WriteLine($"Could not observe '{path}' using Shell notifications.");
                        continue;
                    }
                    _paths.Add(Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)));
                    _registrations.Add(registration);
                }
                finally
                {
                    Marshal.FreeCoTaskMem(itemIdList);
                }
            }
        }

        private IntPtr WindowProcedure(IntPtr window, int message, IntPtr changeHandle, IntPtr processId, ref bool handled)
        {
            if (message != NotificationMessage)
                return IntPtr.Zero;
            handled = true;
            var notificationLock = SHChangeNotificationLock(changeHandle, unchecked((uint)processId.ToInt64()),
                out var itemIdLists, out var eventId);
            if (notificationLock == IntPtr.Zero)
                return IntPtr.Zero;
            try
            {
                if ((eventId & (UpdateImage | ExtendedEvent | AssociationChanged)) != 0 || itemIdLists == IntPtr.Zero)
                    return IntPtr.Zero;
                var oldPath = GetShellPath(Marshal.ReadIntPtr(itemIdLists));
                if (oldPath is null)
                    return IntPtr.Zero;
                var isRename = (eventId & (RenameItem | RenameDirectory)) != 0;
                var newPath = isRename ? GetShellPath(Marshal.ReadIntPtr(itemIdLists, IntPtr.Size)) : null;
                foreach (var directory in _paths)
                {
                    var oldIsChild = IsDirectChild(directory, oldPath);
                    var newIsChild = newPath is not null && IsDirectChild(directory, newPath);
                    if (isRename && oldIsChild && newIsChild)
                        _changed(new(directory, new RenamedEventArgs(WatcherChangeTypes.Renamed, directory,
                            Path.GetFileName(newPath!), Path.GetFileName(oldPath))));
                    else if (isRename && (oldIsChild || newIsChild))
                        _changed(new(directory, new FileSystemEventArgs(oldIsChild ? WatcherChangeTypes.Deleted : WatcherChangeTypes.Created,
                            directory, Path.GetFileName(oldIsChild ? oldPath : newPath!))));
                    else if ((eventId & UpdateDirectory) != 0)
                    {
                        if (string.Equals(directory, Path.TrimEndingDirectorySeparator(oldPath), StringComparison.OrdinalIgnoreCase))
                            _changed(new(directory, null));
                    }
                    else if (oldIsChild)
                    {
                        var changeType = (eventId & (CreateItem | CreateDirectory)) != 0 ? WatcherChangeTypes.Created
                            : (eventId & (DeleteItem | DeleteDirectory)) != 0 ? WatcherChangeTypes.Deleted
                            : (eventId & (Attributes | UpdateItem)) != 0 ? WatcherChangeTypes.Changed
                            : (WatcherChangeTypes?)null;
                        _changed(new(directory, changeType is null ? null : new FileSystemEventArgs(changeType.Value, directory, Path.GetFileName(oldPath))));
                    }
                    else if (string.Equals(directory, Path.TrimEndingDirectorySeparator(oldPath), StringComparison.OrdinalIgnoreCase))
                        _changed(new(directory, null));
                }
            }
            finally
            {
                _ = SHChangeNotificationUnlock(notificationLock);
            }
            return IntPtr.Zero;
        }

        private static bool IsDirectChild(string directory, string path)
        {
            var parent = Path.GetDirectoryName(path);
            return parent is not null && string.Equals(Path.TrimEndingDirectorySeparator(parent), directory, StringComparison.OrdinalIgnoreCase);
        }

        private static string? GetShellPath(IntPtr itemIdList)
        {
            if (itemIdList == IntPtr.Zero || SHGetNameFromIDList(itemIdList, 0x80058000, out var name) < 0)
                return null;
            try
            {
                return Marshal.PtrToStringUni(name);
            }
            finally
            {
                Marshal.FreeCoTaskMem(name);
            }
        }

        public void Dispose()
        {
            foreach (var registration in _registrations)
                _ = SHChangeNotifyDeregister(registration);
            _registrations.Clear();
            _window.RemoveHook(WindowProcedure);
            _window.Dispose();
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr itemIdList, uint attributesIn, out uint attributesOut);

        [DllImport("shell32.dll")]
        private static extern int SHGetNameFromIDList(IntPtr itemIdList, uint nameType, out IntPtr name);

        [DllImport("shell32.dll")]
        private static extern uint SHChangeNotifyRegister(IntPtr window, int sources, int events, int message, int entryCount, ref ShellChangeNotifyEntry entry);

        [DllImport("shell32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SHChangeNotifyDeregister(uint registration);

        [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Lock")]
        private static extern IntPtr SHChangeNotificationLock(IntPtr changeHandle, uint processId, out IntPtr itemIdLists, out int eventId);

        [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Unlock")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SHChangeNotificationUnlock(IntPtr notificationLock);

        [StructLayout(LayoutKind.Sequential)]
        private struct ShellChangeNotifyEntry
        {
            internal IntPtr ItemIdList;
            [MarshalAs(UnmanagedType.Bool)] internal bool Recursive;
        }
    }

    private sealed class DirectoryObserver : IDisposable
    {
        private readonly List<FileSystemWatcher> _watchers = [];

        internal DirectoryObserver(IEnumerable<string> paths, Action<DirectoryNotification> changed, string? currentPath)
        {
            foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                FileSystemWatcher? watcher = null;
                try
                {
                    var isCurrentPath = currentPath is null ||
                        string.Equals(Path.TrimEndingDirectorySeparator(path), Path.TrimEndingDirectorySeparator(currentPath), StringComparison.OrdinalIgnoreCase);
                    watcher = new FileSystemWatcher(path)
                    {
                        NotifyFilter = isCurrentPath
                            ? NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Attributes | NotifyFilters.LastWrite | NotifyFilters.Size
                            : NotifyFilters.DirectoryName | NotifyFilters.Attributes
                    };
                    watcher.Changed += (_, args) => { if (isCurrentPath || Directory.Exists(args.FullPath)) changed(new(path, args)); };
                    watcher.Created += (_, args) => changed(new(path, args));
                    watcher.Deleted += (_, args) => changed(new(path, args));
                    watcher.Renamed += (_, args) => changed(new(path, args));
                    watcher.Error += (_, _) => changed(new(path, null));
                    watcher.EnableRaisingEvents = true;
                    _watchers.Add(watcher);
                    if (currentPath is not null && isCurrentPath)
                        ObserveChildDirectoryChanges(path, changed);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
                {
                    watcher?.Dispose();
                    Debug.WriteLine($"Could not observe '{path}': {exception.Message}");
                }
            }
        }

        private void ObserveChildDirectoryChanges(string path, Action<DirectoryNotification> changed)
        {
            FileSystemWatcher? watcher = null;
            try
            {
                watcher = new FileSystemWatcher(path)
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName
                };
                void NotifyChild(string itemPath)
                {
                    var childPath = Path.GetDirectoryName(itemPath);
                    if (childPath is null || !string.Equals(Path.GetDirectoryName(childPath),
                            Path.TrimEndingDirectorySeparator(path), StringComparison.OrdinalIgnoreCase))
                        return;
                    changed(new(path, new FileSystemEventArgs(WatcherChangeTypes.Changed, path, Path.GetFileName(childPath))));
                }
                watcher.Created += (_, args) => NotifyChild(args.FullPath);
                watcher.Deleted += (_, args) => NotifyChild(args.FullPath);
                watcher.Renamed += (_, args) => { NotifyChild(args.OldFullPath); NotifyChild(args.FullPath); };
                watcher.Error += (_, _) => changed(new(path, null));
                watcher.EnableRaisingEvents = true;
                _watchers.Add(watcher);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                watcher?.Dispose();
                Debug.WriteLine($"Could not observe child directory changes in '{path}': {exception.Message}");
            }
        }

        public void Dispose()
        {
            foreach (var watcher in _watchers)
                watcher.Dispose();
            _watchers.Clear();
        }
    }

    internal static string GetTypeName(string path, bool isDirectory)
    {
        const uint shellFileInfoTypeName = 0x00000400;
        var fileInfo = new ShellFileInfo();
        return SHGetFileInfo(path, 0, ref fileInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), shellFileInfoTypeName) != IntPtr.Zero &&
               !string.IsNullOrEmpty(fileInfo.TypeName)
            ? fileInfo.TypeName
            : isDirectory ? "Directory" : Path.GetExtension(path);
    }

    internal static string FormatSize(long bytes) =>
        $"{(bytes / 1024 + (bytes % 1024 == 0 ? 0 : 1)):N0} KB";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);
}

internal sealed record DirectoryNotification(string DirectoryPath, FileSystemEventArgs? Change);

internal sealed class DirectoryIconSession
{
    private readonly object _sync = new();
    private readonly Dictionary<string, ShellIconSet?> _icons = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IconCache.IconVariant?> _versions = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _pending = new();
    private readonly HashSet<string> _queued = new(StringComparer.OrdinalIgnoreCase);
    private TaskCompletionSource? _completion;
    private bool _prepared;

    internal bool HasPending { get { lock (_sync) return _pending.Count > 0; } }
    internal bool IsPrepared { get { lock (_sync) return _prepared; } }

    internal Task? Prepare(DirectoryItem[] items)
    {
        lock (_sync)
        {
            foreach (var item in items)
            {
                if (!_icons.TryGetValue(item.FullPath, out var icons))
                {
                    try { icons = ShellIconProvider.RefreshSmallBaseIcon(item.FullPath); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException or InvalidOperationException or ArgumentException or NotSupportedException)
                    { Debug.WriteLine($"Could not refresh base icon for '{item.FullPath}': {exception.Message}"); }
                    if (icons is not null)
                    {
                        var (cached, version) = ShellIconProvider.GetCachedSmallBase(item.FullPath);
                        icons = cached ?? icons;
                        _icons[item.FullPath] = icons;
                        _versions[item.FullPath] = version;
                        _pending.Enqueue(item.FullPath);
                        _queued.Add(item.FullPath);
                    }
                }
                else
                {
                    var (cached, version) = ShellIconProvider.GetCachedSmallBase(item.FullPath);
                    if (version is null && _versions.GetValueOrDefault(item.FullPath) is not null)
                    {
                        cached = ShellIconProvider.RefreshSmallBaseIcon(item.FullPath);
                        (var current, version) = ShellIconProvider.GetCachedSmallBase(item.FullPath);
                        cached = current ?? cached;
                    }
                    if (version is not null && !Equals(_versions.GetValueOrDefault(item.FullPath), version))
                    {
                        icons = cached;
                        _icons[item.FullPath] = icons;
                        _versions[item.FullPath] = version;
                        if (_queued.Add(item.FullPath))
                            _pending.Enqueue(item.FullPath);
                    }
                }
                item.SetIcons(icons);
            }
            if (_pending.Count > 0 && _completion is null)
                _completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _prepared = true;
            return _completion?.Task;
        }
    }

    internal void ProcessNextOverlay()
    {
        string path;
        ShellIconSet icons;
        lock (_sync)
        {
            if (!_pending.TryDequeue(out path!))
                return;
            icons = _icons[path]!;
        }
        try
        {
            var (refreshed, version) = ShellIconProvider.RefreshSmallOverlay(path, icons);
            lock (_sync)
            {
                _queued.Remove(path);
                if (ReferenceEquals(_icons[path], icons))
                {
                    if (refreshed is not null)
                    {
                        _icons[path] = refreshed;
                        _versions[path] = version;
                    }
                    else
                    {
                        var (cached, currentVersion) = ShellIconProvider.GetCachedSmallBase(path);
                        if (cached is not null)
                        {
                            _icons[path] = cached;
                            _versions[path] = currentVersion;
                            if (_queued.Add(path)) _pending.Enqueue(path);
                        }
                        else
                        {
                            _icons.Remove(path);
                            _versions.Remove(path);
                        }
                    }
                }
                else if (_queued.Add(path))
                    _pending.Enqueue(path);
            }
        }
        catch (Exception exception)
        {
            lock (_sync) _queued.Remove(path);
            Debug.WriteLine($"Could not refresh overlay for '{path}': {exception.Message}");
        }
        lock (_sync)
        {
            if (_pending.Count == 0)
            {
                var completion = _completion;
                _completion = null;
                completion?.TrySetResult();
            }
        }
    }
}

internal sealed class DirectoryDataCache
{
    private readonly object _sync = new();
    private readonly SemaphoreSlim _enumeration = new(1, 1);
    private string? _path;
    private DirectoryItem[]? _items;
    private int _generation;
    private readonly List<(string OldPath, string NewPath)> _pathRemaps = [];

    internal void Invalidate()
    {
        lock (_sync)
        {
            _generation++;
            _path = null;
            _items = null;
            _pathRemaps.Clear();
        }
    }

    internal void RemapPaths(string oldPath, string newPath)
    {
        lock (_sync)
        {
            _pathRemaps.Add((oldPath, newPath));
            if (_path is not null)
                _path = ShellLocations.RemapPath(_path, oldPath, newPath);
            if (_items is not null)
                foreach (var item in _items)
                    item.RemapPath(oldPath, newPath);
        }
    }

    internal bool RefreshItemMetadata(string directoryPath, string itemPath)
    {
        DirectoryItem? item;
        lock (_sync)
        {
            foreach (var (oldPath, newPath) in _pathRemaps)
            {
                directoryPath = ShellLocations.RemapPath(directoryPath, oldPath, newPath);
                itemPath = ShellLocations.RemapPath(itemPath, oldPath, newPath);
            }
            if (!string.Equals(_path, directoryPath, StringComparison.OrdinalIgnoreCase))
                return false;
            item = _items?.FirstOrDefault(candidate =>
                string.Equals(candidate.FullPath, itemPath, StringComparison.OrdinalIgnoreCase));
        }
        if (item is null)
            return false;
        item.RefreshMetadata();
        return true;
    }

    internal DirectoryItem[] GetDirectory(string path, CancellationToken token)
    {
        _enumeration.Wait(token);
        try
        {
            int generation;
            lock (_sync)
            {
                if (_items is not null && string.Equals(_path, path, StringComparison.OrdinalIgnoreCase))
                    return _items;
                generation = _generation;
            }
            var isTop = ShellLocations.IsTopPath(path);
            IEnumerable<string> paths = isTop
                ? DriveInfo.GetDrives().Select(drive => drive.Name)
                : Directory.EnumerateFileSystemEntries(path);
            var items = new List<DirectoryItem>();
            foreach (var itemPath in paths)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var attributes = isTop ? FileAttributes.Directory : File.GetAttributes(itemPath);
                    var isDirectory = (attributes & FileAttributes.Directory) != 0;
                    var fallbackName = isTop ? itemPath.TrimEnd(Path.DirectorySeparatorChar) : Path.GetFileName(itemPath);
                    var name = ShellDisplayNameProvider.GetDisplayName(itemPath) ?? fallbackName;
                    items.Add(new DirectoryItem(name, itemPath, isDirectory, isTop));
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                }
            }
            token.ThrowIfCancellationRequested();
            var result = items.ToArray();
            lock (_sync)
            {
                if (_generation == generation)
                {
                    _path = path;
                    _items = result;
                }
            }
            return result;
        }
        finally
        {
            _enumeration.Release();
        }
    }
}

internal sealed class DirectoryItem(string name, string fullPath, bool isDirectory, bool isDrive)
{
    private readonly object _sync = new();
    private bool? _internal;
    private bool _sizeLoaded, _modifiedLoaded, _typeLoaded, _iconsLoaded;
    private long? _size;
    private DateTime? _modified;
    private string? _type;
    private ShellIconSet? _icons;
    private FileEntry? _entry;
    internal string Name { get; } = name;
    internal string FullPath { get; private set; } = fullPath;
    internal bool IsDirectory { get; } = isDirectory;
    internal bool IsDrive { get; } = isDrive;
    internal MediaType MediaType { get; } = MediaTypeMap.GetMediaType(fullPath, isDirectory);

    internal void SetIcons(ShellIconSet? icons)
    {
        lock (_sync)
        {
            if (_iconsLoaded && ReferenceEquals(_icons, icons))
                return;
            _icons = icons;
            _iconsLoaded = true;
            if (_entry is not null)
                _entry = _entry with { Icons = icons };
        }
    }

    internal void RemapPath(string oldPath, string newPath)
    {
        lock (_sync)
        {
            FullPath = ShellLocations.RemapPath(FullPath, oldPath, newPath);
            if (_entry is not null)
                _entry = _entry with { FullPath = FullPath };
        }
    }

    internal void RefreshMetadata()
    {
        lock (_sync)
        {
            _internal = null;
            _sizeLoaded = false;
            _modifiedLoaded = false;
            _typeLoaded = false;
            _size = null;
            _modified = null;
            _type = null;
            _entry = null;
            _ = IsInternal;
            _ = Entry;
        }
    }

    internal bool IsInternal
    {
        get { lock (_sync) return _internal ??= InternalItemFilter.IsInternal(FullPath, IsDirectory); }
    }

    internal long? Size
    {
        get
        {
            lock (_sync)
            {
                if (!_sizeLoaded)
                {
                    try { if (!IsDrive && !IsDirectory) _size = new FileInfo(FullPath).Length; }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                    { Debug.WriteLine($"Could not load size for '{FullPath}': {exception.Message}"); }
                    _sizeLoaded = true;
                }
                return _size;
            }
        }
    }

    internal DateTime? Modified
    {
        get
        {
            lock (_sync)
            {
                if (!_modifiedLoaded)
                {
                    try { if (!IsDrive) _modified = File.GetLastWriteTime(FullPath); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                    { Debug.WriteLine($"Could not load date for '{FullPath}': {exception.Message}"); }
                    _modifiedLoaded = true;
                }
                return _modified;
            }
        }
    }

    internal string Type
    {
        get
        {
            lock (_sync)
            {
                if (!_typeLoaded)
                {
                    _type = SutShell.GetTypeName(FullPath, IsDirectory);
                    _typeLoaded = true;
                }
                return _type!;
            }
        }
    }

    internal ShellIconSet? Icons
    {
        get
        {
            lock (_sync)
            {
                if (!_iconsLoaded)
                {
                    try { _icons = ShellIconProvider.GetSmallIcons(FullPath); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException)
                    { Debug.WriteLine($"Could not load icon for '{FullPath}': {exception.Message}"); }
                    _iconsLoaded = true;
                }
                return _icons;
            }
        }
    }

    internal FileEntry Entry
    {
        get
        {
            lock (_sync)
            {
                if (_entry is null)
                    return _entry = new FileEntry(Name, FullPath, IsDirectory, Type,
                        Size is { } size ? SutShell.FormatSize(size) : string.Empty, Modified, Icons,
                        MediaTypeIconMap.GetIcon(MediaType), MediaTypeMap.GetName(MediaType));
                return _entry;
            }
        }
    }
}

internal enum DirectorySortColumn { Name, TypeApp2Name, Size, DateModified, MediaTypeIcon, TypeApp1Icon, Overlay }

internal enum DirectorySortCriterion { Ascending, Descending }

internal readonly record struct DirectorySortPair(DirectorySortColumn Column, DirectorySortCriterion Criterion);

internal sealed class DirectorySortState
{
    private readonly List<DirectorySortPair> _pairs = [];

    internal IReadOnlyList<DirectorySortPair> Pairs => _pairs.ToArray();

    internal void Update(IReadOnlyList<DirectorySortPair> pairs)
    {
        Validate(pairs);
        var columns = pairs.Select(pair => pair.Column).ToHashSet();
        _pairs.RemoveAll(pair => columns.Contains(pair.Column));
        _pairs.InsertRange(0, pairs);
    }

    internal static void Validate(IReadOnlyList<DirectorySortPair> pairs)
    {
        if (pairs.Any(pair => !Enum.IsDefined(pair.Column) || pair.Column == DirectorySortColumn.Overlay || !Enum.IsDefined(pair.Criterion)) ||
            pairs.Select(pair => pair.Column).Distinct().Count() != pairs.Count)
            throw new ArgumentException("Sort columns and criteria must be valid, with no duplicate columns.", nameof(pairs));
    }
}

internal sealed record DirectorySortValues(DirectoryItem Item, long? Size, DateTime? Modified, string Type,
    MediaType MediaType, int? BaseIconIndex);

internal sealed class DirectorySnapshot(DirectoryItem[] items, int directoryCount, int fileCount, Task? overlayCompletion)
{
    internal IReadOnlyList<DirectoryItem> Items { get; } = items;
    internal Task? OverlayCompletion { get; } = overlayCompletion;
    public int Count => Items.Count;
    public int DirectoryCount { get; } = directoryCount;
    public int FileCount { get; } = fileCount;
}

internal sealed record FileEntry(
    string Name,
    string FullPath,
    bool IsDirectory,
    string Type,
    string SizeText,
    DateTime? Modified,
    ShellIconSet? Icons,
    ImageSource? MediaTypeIcon,
    string MediaTypeName)
{
    internal const string DateFormat = "yyyy-MM-dd HH:mm";
    public string ModifiedText => Modified?.ToString(DateFormat, CultureInfo.InvariantCulture) ?? string.Empty;
}