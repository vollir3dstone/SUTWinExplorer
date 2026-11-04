using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;

namespace SUTWinExplorer;

internal static class SutShell
{
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
            var source = cache.GetDirectory(path, token);
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
                var icons = sortColumns.Contains(DirectorySortColumn.TypeApp1Icon) || sortColumns.Contains(DirectorySortColumn.Overlay)
                    ? item.Icons : null;
                values.Add(new DirectorySortValues(item,
                    sortColumns.Contains(DirectorySortColumn.Size) ? item.Size : null,
                    sortColumns.Contains(DirectorySortColumn.DateModified) ? item.Modified : null,
                    sortColumns.Contains(DirectorySortColumn.TypeApp2Name) ? item.Type : string.Empty,
                    item.MediaType, icons?.BaseIconIndex, icons?.OverlaySlot));
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
                    DirectorySortColumn.Overlay => ascending
                        ? ordered.ThenBy(value => value.OverlaySlot) : ordered.ThenByDescending(value => value.OverlaySlot),
                    _ => throw new ArgumentOutOfRangeException(nameof(sorting))
                };
            }
            var result = ordered.ThenBy(value => value.Item.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(value => value.Item.FullPath, StringComparer.OrdinalIgnoreCase)
                .Select(value => value.Item).ToArray();
            token.ThrowIfCancellationRequested();
            return new DirectorySnapshot(result, directoryCount, source.Length - directoryCount);
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

    internal static string? GetFolderTarget(string path) => ShellFileOperations.GetFolderTarget(path);

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
            throw new ArgumentException("Enter a valid file or folder name.", nameof(name));
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
        new DirectoryObserver(paths, changed, currentPath);

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
            : isDirectory ? "Folder" : Path.GetExtension(path);
    }

    internal static string FormatSize(long bytes) =>
        $"{(bytes / 1024 + (bytes % 1024 == 0 ? 0 : 1)):N0} KB";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);
}

internal sealed record DirectoryNotification(string DirectoryPath, FileSystemEventArgs? Change);

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
            _iconsLoaded = false;
            _size = null;
            _modified = null;
            _type = null;
            _icons = null;
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
                return _entry ??= new FileEntry(Name, FullPath, IsDirectory, Type,
                    Size is { } size ? SutShell.FormatSize(size) : string.Empty, Modified, Icons,
                    MediaTypeIconMap.GetIcon(MediaType), MediaTypeMap.GetName(MediaType));
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
        if (pairs.Any(pair => !Enum.IsDefined(pair.Column) || !Enum.IsDefined(pair.Criterion)) ||
            pairs.Select(pair => pair.Column).Distinct().Count() != pairs.Count)
            throw new ArgumentException("Sort columns and criteria must be valid, with no duplicate columns.", nameof(pairs));
    }
}

internal sealed record DirectorySortValues(DirectoryItem Item, long? Size, DateTime? Modified, string Type,
    MediaType MediaType, int? BaseIconIndex, int? OverlaySlot);

internal sealed class DirectorySnapshot(DirectoryItem[] items, int directoryCount, int fileCount)
{
    internal IReadOnlyList<DirectoryItem> Items { get; } = items;
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