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
            foreach (var item in source)
            {
                token.ThrowIfCancellationRequested();
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
                var icons = sortColumns.Contains(DirectorySortColumn.ShellIcon) || sortColumns.Contains(DirectorySortColumn.Overlay)
                    ? item.Icons : null;
                values.Add(new DirectorySortValues(item,
                    sortColumns.Contains(DirectorySortColumn.Size) ? item.Size : null,
                    sortColumns.Contains(DirectorySortColumn.DateModified) ? item.Modified : null,
                    sortColumns.Contains(DirectorySortColumn.Type) ? item.Type : string.Empty,
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
                    DirectorySortColumn.Type => ascending
                        ? ordered.ThenBy(value => value.Type, StringComparer.CurrentCultureIgnoreCase)
                        : ordered.ThenByDescending(value => value.Type, StringComparer.CurrentCultureIgnoreCase),
                    DirectorySortColumn.MediaType => ascending
                        ? ordered.ThenBy(value => value.MediaType == MediaType.None).ThenBy(value => value.MediaType)
                        : ordered.ThenBy(value => value.MediaType == MediaType.None).ThenByDescending(value => value.MediaType),
                    DirectorySortColumn.Size => ascending
                        ? ordered.ThenBy(value => value.Size) : ordered.ThenByDescending(value => value.Size),
                    DirectorySortColumn.DateModified => ascending
                        ? ordered.ThenBy(value => value.Modified) : ordered.ThenByDescending(value => value.Modified),
                    DirectorySortColumn.ShellIcon => ascending
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
            return new DirectorySnapshot(result);
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
        return ShellContextMenu.Rename(path, name, owner);
    }

    internal static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    internal static void Copy(IReadOnlyList<string> paths, string destination, IntPtr owner) =>
        ShellFileOperations.Copy(paths, destination, owner);

    internal static void Move(IReadOnlyList<string> paths, string destination, IntPtr owner) =>
        ShellFileOperations.Move(paths, destination, owner);

    internal static void Delete(IReadOnlyList<string> paths, IntPtr owner) =>
        ShellFileOperations.Delete(paths, owner);

    internal static IReadOnlyDictionary<string, int> ShowGenericFileMenu(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyList<ShellMenuAction> actions, Func<int, int, bool, bool>? secondRightClick) =>
        ShellContextMenu.ShowGenericFile(paths, owner, actions, secondRightClick);

    internal static void ShowSpecialFileMenu(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyDictionary<string, int> genericCommands) =>
        ShellContextMenu.ShowSpecialFile(paths, owner, genericCommands);

    internal static void ShowItemMenu(IReadOnlyList<string> paths, IntPtr owner, Action? rename = null) =>
        ShellContextMenu.ShowItems(paths, owner, rename);

    internal static void ShowBackgroundMenu(string path, IntPtr owner) => ShellContextMenu.ShowBackground(path, owner);

    internal static IDisposable ObserveDirectories(IEnumerable<string> paths, Action changed) =>
        new DirectoryObserver(paths, changed);

    private sealed class DirectoryObserver : IDisposable
    {
        private readonly List<FileSystemWatcher> _watchers = [];

        internal DirectoryObserver(IEnumerable<string> paths, Action changed)
        {
            foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                FileSystemWatcher? watcher = null;
                try
                {
                    watcher = new FileSystemWatcher(path)
                    {
                        NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                                       NotifyFilters.Attributes | NotifyFilters.LastWrite | NotifyFilters.Size
                    };
                    watcher.Changed += (_, _) => changed();
                    watcher.Created += (_, _) => changed();
                    watcher.Deleted += (_, _) => changed();
                    watcher.Renamed += (_, _) => changed();
                    watcher.Error += (_, _) => changed();
                    watcher.EnableRaisingEvents = true;
                    _watchers.Add(watcher);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
                {
                    watcher?.Dispose();
                    Debug.WriteLine($"Could not observe '{path}': {exception.Message}");
                }
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

internal sealed class DirectoryDataCache
{
    private readonly object _sync = new();
    private readonly SemaphoreSlim _enumeration = new(1, 1);
    private string? _path;
    private DirectoryItem[]? _items;
    private int _generation;

    internal void Invalidate()
    {
        lock (_sync)
        {
            _generation++;
            _path = null;
            _items = null;
        }
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
    internal string FullPath { get; } = fullPath;
    internal bool IsDirectory { get; } = isDirectory;
    internal bool IsDrive { get; } = isDrive;
    internal MediaType MediaType { get; } = MediaTypeMap.GetMediaType(fullPath, isDirectory);

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

internal enum DirectorySortColumn { Name, Type, Size, DateModified, MediaType, ShellIcon, Overlay }

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

internal sealed class DirectorySnapshot(DirectoryItem[] items)
{
    internal IReadOnlyList<DirectoryItem> Items { get; } = items;
    public int Count => Items.Count;
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