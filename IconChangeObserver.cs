using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;

namespace SUTWinExplorer;

internal sealed class IconChangeObserver : IDisposable
{
    private const int UpdateItem = 0x00002000;
    private const int AssociationChanged = 0x08000000;
    private const int NotificationMessage = 0x8000 + 0x273;
    private const int DeviceChangeMessage = 0x0219;
    private readonly IconCache _cache;
    private readonly Dispatcher _dispatcher;
    private readonly HwndSource _window;
    private readonly Dictionary<string, uint> _registrations = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();
    private readonly Queue<string> _pending = new();
    private readonly HashSet<string> _pendingPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _pendingExtensions = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string>? _remainingGlobalPaths;
    private string? _activePath;
    private bool _refreshAll;
    private bool _disposed;

    internal IconChangeObserver(IconCache cache, Dispatcher dispatcher)
    {
        _cache = cache;
        _dispatcher = dispatcher;
        _window = new HwndSource(new HwndSourceParameters("KIS icon change observer"));
        _window.AddHook(WindowProcedure);
        _cache.FileSystemRootAdded += OnFileSystemRootAdded;
        foreach (var root in _cache.GetFileSystemRoots())
            RegisterRoot(root);
        var worker = new Thread(ProcessChanges) { IsBackground = true, Name = "KIS icon refresh" };
        worker.SetApartmentState(ApartmentState.STA);
        worker.Start();
    }

    private void OnFileSystemRootAdded(string root)
    {
        if (_dispatcher.CheckAccess())
            RegisterRoot(root);
        else if (!_dispatcher.HasShutdownStarted && !_dispatcher.HasShutdownFinished)
            _ = _dispatcher.BeginInvoke(() => RegisterRoot(root));
    }

    private void RegisterRoot(string root)
    {
        if (_disposed || _registrations.ContainsKey(root))
            return;
        IntPtr itemIdList = IntPtr.Zero;
        try
        {
            if (SHParseDisplayName(root, IntPtr.Zero, out itemIdList, 0, out _) < 0 || itemIdList == IntPtr.Zero)
            {
                Debug.WriteLine($"Could not resolve icon observation root '{root}'.");
                return;
            }
            var entry = new ShellChangeNotifyEntry { ItemIdList = itemIdList, Recursive = true };
            var registration = SHChangeNotifyRegister(_window.Handle, 0x0001 | 0x0002 | 0x1000 | 0x8000,
                UpdateItem | AssociationChanged, NotificationMessage, 1, ref entry);
            if (registration == 0)
                Debug.WriteLine($"Could not observe icon changes on '{root}'.");
            else
                _registrations.Add(root, registration);
        }
        finally
        {
            if (itemIdList != IntPtr.Zero)
                Marshal.FreeCoTaskMem(itemIdList);
        }
    }

    private IntPtr WindowProcedure(IntPtr window, int message, IntPtr changeHandle, IntPtr processId, ref bool handled)
    {
        if (message == DeviceChangeMessage)
        {
            foreach (var root in _cache.GetFileSystemRoots())
                RegisterRoot(root);
            return IntPtr.Zero;
        }
        if (message != NotificationMessage)
            return IntPtr.Zero;
        handled = true;
        var notification = SHChangeNotificationLock(changeHandle, unchecked((uint)processId.ToInt64()),
            out var itemIdLists, out var eventId);
        if (notification == IntPtr.Zero)
            return IntPtr.Zero;
        try
        {
            if ((eventId & AssociationChanged) != 0)
                QueueAssociationChange(itemIdLists);
            if ((eventId & UpdateItem) == 0 || itemIdLists == IntPtr.Zero)
                return IntPtr.Zero;
            var itemIdList = Marshal.ReadIntPtr(itemIdLists);
            if (itemIdList == IntPtr.Zero || SHGetNameFromIDList(itemIdList, 0x80058000, out var name) < 0)
                return IntPtr.Zero;
            try
            {
                var path = Marshal.PtrToStringUni(name);
                if (!string.IsNullOrEmpty(path))
                    QueueItem(path);
            }
            finally { Marshal.FreeCoTaskMem(name); }
        }
        finally { _ = SHChangeNotificationUnlock(notification); }
        return IntPtr.Zero;
    }

    private void QueueAssociationChange(IntPtr itemIdLists)
    {
        var itemIdList = itemIdLists == IntPtr.Zero ? IntPtr.Zero : Marshal.ReadIntPtr(itemIdLists);
        if (itemIdList == IntPtr.Zero)
        {
            QueueRefreshAll();
            return;
        }
        if (SHGetNameFromIDList(itemIdList, 0x80028000, out var name) < 0)
        {
            Debug.WriteLine("Could not resolve association change item.");
            return;
        }
        try
        {
            var path = Marshal.PtrToStringUni(name);
            var fileName = Path.GetFileName(path);
            var extension = Path.GetExtension(fileName);
            if (string.IsNullOrEmpty(extension) || fileName != "*" + extension || extension.IndexOfAny(['*', '?']) >= 0)
            {
                Debug.WriteLine($"Could not identify association extension from '{path}'.");
                return;
            }
            lock (_sync)
            {
                if (_disposed || !_pendingExtensions.Add(extension))
                    return;
                Monitor.Pulse(_sync);
            }
        }
        finally { Marshal.FreeCoTaskMem(name); }
    }

    private void QueueItem(string path)
    {
        if (_cache.GetFileSystemItem(path) is null)
            return;
        lock (_sync)
        {
            if (_disposed || !_pendingPaths.Add(path))
                return;
            _pending.Enqueue(path);
            Monitor.Pulse(_sync);
        }
    }

    private void QueueRefreshAll()
    {
        lock (_sync)
        {
            if (_disposed)
                return;
            _refreshAll = true;
            Monitor.Pulse(_sync);
        }
    }

    private void ProcessChanges()
    {
        while (true)
        {
            string? path;
            bool refreshAll;
            string[]? globalPaths;
            lock (_sync)
            {
                while (!_disposed && !_refreshAll && _pendingExtensions.Count == 0 && _pending.Count == 0)
                    Monitor.Wait(_sync);
                if (_disposed)
                    return;
                refreshAll = _refreshAll;
                _refreshAll = false;
                var extension = !refreshAll && _pendingExtensions.Count > 0 ? _pendingExtensions.First() : null;
                if (extension is not null)
                    _pendingExtensions.Remove(extension);
                path = refreshAll || extension is not null ? null : _pending.Dequeue();
                if (path is not null)
                {
                    _pendingPaths.Remove(path);
                    _activePath = path;
                }
                globalPaths = refreshAll || extension is not null
                    ? _cache.GetFileSystemItems().Select(item => item.Path)
                        .Where(itemPath => extension is null || string.Equals(Path.GetExtension(itemPath), extension, StringComparison.OrdinalIgnoreCase))
                        .ToArray()
                    : null;
                if (globalPaths is not null)
                    _remainingGlobalPaths = new HashSet<string>(globalPaths, StringComparer.OrdinalIgnoreCase);
            }
            if (globalPaths is not null)
            {
                foreach (var globalPath in globalPaths)
                {
                    lock (_sync)
                        if (_disposed)
                            return;
                    if (refreshAll || !Directory.Exists(globalPath))
                        RefreshItem(globalPath);
                    lock (_sync)
                        _remainingGlobalPaths?.Remove(globalPath);
                }
                lock (_sync)
                    _remainingGlobalPaths = null;
            }
            else if (path is not null)
            {
                RefreshItem(path);
                lock (_sync)
                    _activePath = null;
            }
        }
    }

    private void RefreshItem(string path)
    {
        try
        {
            var refresh = ShellIconProvider.PrepareCachedItemRefresh(_cache, path);
            if (refresh is null)
                return;
            lock (_sync)
                if (!_disposed)
                    refresh();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException or
                                          InvalidOperationException or ArgumentException or NotSupportedException)
        { Debug.WriteLine($"Could not update cached icon for '{path}': {exception.Message}"); }
    }

    public void Dispose()
    {
        _cache.FileSystemRootAdded -= OnFileSystemRootAdded;
        lock (_sync)
        {
            if (_disposed)
                return;
            _disposed = true;
            if (_refreshAll)
                _cache.InvalidateAllFileSystemItems();
            else
            {
                var stalePaths = new HashSet<string>(_pendingPaths, StringComparer.OrdinalIgnoreCase);
                if (_activePath is not null)
                    stalePaths.Add(_activePath);
                if (_remainingGlobalPaths is not null)
                    stalePaths.UnionWith(_remainingGlobalPaths);
                if (_pendingExtensions.Count > 0)
                    stalePaths.UnionWith(_cache.GetFileSystemItems().Select(item => item.Path)
                        .Where(path => _pendingExtensions.Contains(Path.GetExtension(path))));
                _cache.InvalidateFileSystemItems(stalePaths);
            }
            _pending.Clear();
            _pendingPaths.Clear();
            _pendingExtensions.Clear();
            Monitor.Pulse(_sync);
        }
        foreach (var registration in _registrations.Values)
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
    private static extern bool SHChangeNotificationUnlock(IntPtr notification);

    [StructLayout(LayoutKind.Sequential)]
    private struct ShellChangeNotifyEntry
    {
        internal IntPtr ItemIdList;
        [MarshalAs(UnmanagedType.Bool)] internal bool Recursive;
    }
}