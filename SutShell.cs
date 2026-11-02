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
        RunOnShellThread(token =>
        {
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
                    if ((!showDirectories && isDirectory) ||
                        (hideInternal && !isTop && InternalItemFilter.IsInternal(itemPath, isDirectory)))
                        continue;

                    var fallbackName = isTop ? itemPath.TrimEnd(Path.DirectorySeparatorChar) : Path.GetFileName(itemPath);
                    var name = ShellDisplayNameProvider.GetDisplayName(itemPath) ?? fallbackName;
                    if (InternalItemFilter.MatchesName(name, namePattern))
                        items.Add(new DirectoryItem(name, itemPath, isDirectory, isTop));
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                }
            }

            token.ThrowIfCancellationRequested();
            return new DirectorySnapshot(items.OrderByDescending(item => item.IsDirectory)
                .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray());
        }, cancellationToken);

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
                string size = string.Empty;
                DateTime? modified = null;
                ShellIconSet? icons = null;
                try
                {
                    if (!item.IsDrive)
                    {
                        if (!item.IsDirectory)
                            size = FormatSize(new FileInfo(item.FullPath).Length);
                        modified = File.GetLastWriteTime(item.FullPath);
                    }
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    Debug.WriteLine($"Could not load details for '{item.FullPath}': {exception.Message}");
                }
                try
                {
                    icons = ShellIconProvider.GetSmallIcons(item.FullPath);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException)
                {
                    Debug.WriteLine($"Could not load icon for '{item.FullPath}': {exception.Message}");
                }
                var mediaType = MediaTypeMap.GetMediaType(item.FullPath, item.IsDirectory);
                entries.Add(new FileEntry(item.Name, item.FullPath, item.IsDirectory,
                    GetTypeName(item.FullPath, item.IsDirectory), size, modified, icons,
                    MediaTypeIconMap.GetIcon(mediaType), MediaTypeMap.GetName(mediaType)));
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

    private static string GetTypeName(string path, bool isDirectory)
    {
        const uint shellFileInfoTypeName = 0x00000400;
        var fileInfo = new ShellFileInfo();
        return SHGetFileInfo(path, 0, ref fileInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), shellFileInfoTypeName) != IntPtr.Zero &&
               !string.IsNullOrEmpty(fileInfo.TypeName)
            ? fileInfo.TypeName
            : isDirectory ? "Folder" : Path.GetExtension(path);
    }

    private static string FormatSize(long bytes) =>
        $"{(bytes / 1024 + (bytes % 1024 == 0 ? 0 : 1)):N0} KB";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);
}

internal sealed record DirectoryItem(string Name, string FullPath, bool IsDirectory, bool IsDrive);

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