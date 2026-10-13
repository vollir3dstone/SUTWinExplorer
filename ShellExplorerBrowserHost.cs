using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace SUTWinExplorer;

internal sealed class ShellExplorerBrowserHost : HwndHost
{
    private static readonly Guid ExplorerBrowserClassId = new("71F96385-DDD6-48D3-A0C1-AE06E8B055FB");
    private const uint ClsctxInprocServer = 1;
    private const uint WindowStyle = 0x40000000 | 0x10000000 | 0x02000000 | 0x04000000;
    private const uint FolderViewDetails = 4;
    private const uint FolderFlagAutoArrange = 1;
    private const uint ShellDisplayNameFileSystemPath = 0x80058000;

    private IExplorerBrowserNative? _browser;
    private IObjectWithSiteNative? _browserSite;
    private ShellBrowserSite? _site;
    private ExplorerBrowserEventsSink? _eventsSink;
    private uint _eventsCookie;
    private IntPtr _hostWindow;
    private bool _initialized;
    private bool _showDirectories;
    private string? _pendingPath;

    public event EventHandler<string>? NavigationCompleted;

    public void NavigateTo(string path)
    {
        _pendingPath = Path.GetFullPath(path);
        if (_initialized)
            BrowseToPendingPath();
    }

    public void SetShowDirectories(bool showDirectories)
    {
        _showDirectories = showDirectories;
        _site?.SetShowDirectories(showDirectories);
        RefreshCurrentView();
    }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        _hostWindow = CreateWindowEx(
            0,
            "STATIC",
            string.Empty,
            WindowStyle,
            0,
            0,
            1,
            1,
            hwndParent.Handle,
            IntPtr.Zero,
            IntPtr.Zero,
            IntPtr.Zero);

        if (_hostWindow == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the Shell view host window.");

        try
        {
            var classId = ExplorerBrowserClassId;
            var interfaceId = typeof(IExplorerBrowserNative).GUID;
            Marshal.ThrowExceptionForHR(CoCreateInstance(ref classId, IntPtr.Zero, ClsctxInprocServer, ref interfaceId, out _browser));

            _site = new ShellBrowserSite(() => _showDirectories, () => _pendingPath);
            _browserSite = (IObjectWithSiteNative)_browser;
            _browserSite.SetSite(_site);

            if (!GetClientRect(_hostWindow, out var bounds))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not get the Shell view host size.");

            var settings = new FolderSettings
            {
                ViewMode = FolderViewDetails,
                Flags = FolderFlagAutoArrange
            };
            Marshal.ThrowExceptionForHR(_browser.Initialize(_hostWindow, ref bounds, ref settings));
            _initialized = true;

            _eventsSink = new ExplorerBrowserEventsSink(HandleNavigationPending, HandleNavigationCompleted);
            Marshal.ThrowExceptionForHR(_browser.Advise(_eventsSink, out _eventsCookie));

            if (!string.IsNullOrEmpty(_pendingPath))
                _ = Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(BrowseToPendingPath));
        }
        catch
        {
            ReleaseBrowser();
            _ = DestroyWindow(_hostWindow);
            _hostWindow = IntPtr.Zero;
            throw;
        }

        return new HandleRef(this, _hostWindow);
    }

    protected override void DestroyWindowCore(HandleRef hwnd)
    {
        ReleaseBrowser();
        if (hwnd.Handle != IntPtr.Zero)
            _ = DestroyWindow(hwnd.Handle);
        _hostWindow = IntPtr.Zero;
    }

    protected override void OnWindowPositionChanged(Rect rcBoundingBox)
    {
        base.OnWindowPositionChanged(rcBoundingBox);
        if (_browser is null || !_initialized || _hostWindow == IntPtr.Zero || !GetClientRect(_hostWindow, out var bounds))
            return;

        _ = _browser.SetRect(IntPtr.Zero, bounds);
    }

    private void BrowseToPendingPath()
    {
        if (_browser is null || !_initialized || string.IsNullOrEmpty(_pendingPath))
            return;

        IntPtr itemIdList = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(SHParseDisplayName(_pendingPath, IntPtr.Zero, out itemIdList, 0, out _));
            Marshal.ThrowExceptionForHR(_browser.BrowseToIDList(itemIdList, 0));
        }
        finally
        {
            if (itemIdList != IntPtr.Zero)
                Marshal.FreeCoTaskMem(itemIdList);
        }
    }

    private void RefreshCurrentView()
    {
        if (_browser is null || !_initialized)
            return;

        IShellView? view = null;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            if (_browser.GetCurrentView(ref interfaceId, out view) >= 0)
                _ = view.Refresh();
        }
        finally
        {
            if (view is not null && Marshal.IsComObject(view))
                _ = Marshal.ReleaseComObject(view);
        }
    }

    private void HandleNavigationCompleted(IntPtr itemIdList)
    {
        var path = TryGetFileSystemPath(itemIdList);
        if (path is null)
            return;

        _pendingPath = path;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.DataBind, new Action(() => NavigationCompleted?.Invoke(this, path)));
    }

    private void HandleNavigationPending(IntPtr itemIdList)
    {
        var path = TryGetFileSystemPath(itemIdList);
        if (path is not null)
            _pendingPath = path;
    }

    private static string? TryGetFileSystemPath(IntPtr itemIdList)
    {
        if (SHGetNameFromIDList(itemIdList, ShellDisplayNameFileSystemPath, out var name) < 0 || name == IntPtr.Zero)
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

    private void ReleaseBrowser()
    {
        if (_browser is not null)
        {
            if (_eventsCookie != 0)
            {
                _ = _browser.Unadvise(_eventsCookie);
                _eventsCookie = 0;
            }

            if (_initialized)
            {
                _ = _browser.Destroy();
                _initialized = false;
            }

            try
            {
                _browserSite?.SetSite(null);
            }
            catch (COMException)
            {
            }

            _browserSite = null;
            if (Marshal.IsComObject(_browser))
                _ = Marshal.FinalReleaseComObject(_browser);
            _browser = null;
        }

        _eventsSink = null;
        _site?.Dispose();
        _site = null;
    }

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int CoCreateInstance(ref Guid classId, IntPtr outer, uint context, ref Guid interfaceId, out IExplorerBrowserNative result);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr itemIdList, uint attributesIn, out uint attributesOut);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetNameFromIDList(IntPtr itemIdList, uint sigdnName, out IntPtr name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateWindowExW")]
    private static extern IntPtr CreateWindowEx(uint extendedStyle, string className, string windowName, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(IntPtr window, out NativeRect rectangle);
}

[ComImport]
[Guid("dfd3b6b5-c10c-4be9-85f6-a66969f402f6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IExplorerBrowserNative
{
    [PreserveSig] int Initialize(IntPtr parent, ref NativeRect rectangle, ref FolderSettings settings);
    [PreserveSig] int Destroy();
    [PreserveSig] int SetRect(IntPtr deferWindowPosition, NativeRect rectangle);
    [PreserveSig] int SetPropertyBag([MarshalAs(UnmanagedType.LPWStr)] string propertyBag);
    [PreserveSig] int SetEmptyText([MarshalAs(UnmanagedType.LPWStr)] string emptyText);
    [PreserveSig] int SetFolderSettings(ref FolderSettings settings);
    [PreserveSig] int Advise(IExplorerBrowserEventsNative sink, out uint cookie);
    [PreserveSig] int Unadvise(uint cookie);
    [PreserveSig] int SetOptions(uint options);
    [PreserveSig] int GetOptions(out uint options);
    [PreserveSig] int BrowseToIDList(IntPtr itemIdList, uint flags);
    [PreserveSig] int BrowseToObject(IntPtr unknown, uint flags);
    [PreserveSig] int FillFromObject(IntPtr unknown, uint flags);
    [PreserveSig] int RemoveAll();
    [PreserveSig] int GetCurrentView(ref Guid interfaceId, out IShellView view);
}

[ComVisible(true)]
[Guid("361bbdc7-e6ee-4e13-be58-58e2240c810f")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IExplorerBrowserEventsNative
{
    [PreserveSig] int OnNavigationPending(IntPtr itemIdList);
    [PreserveSig] int OnViewCreated(IntPtr shellView);
    [PreserveSig] int OnNavigationComplete(IntPtr itemIdList);
    [PreserveSig] int OnNavigationFailed(IntPtr itemIdList);
}

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
internal sealed class ExplorerBrowserEventsSink(Action<IntPtr> navigationPending, Action<IntPtr> navigationCompleted) : IExplorerBrowserEventsNative
{
    public int OnNavigationPending(IntPtr itemIdList)
    {
        try
        {
            navigationPending(itemIdList);
            return 0;
        }
        catch
        {
            return unchecked((int)0x80004005);
        }
    }
    public int OnViewCreated(IntPtr shellView) => 0;

    public int OnNavigationComplete(IntPtr itemIdList)
    {
        try
        {
            navigationCompleted(itemIdList);
            return 0;
        }
        catch
        {
            return unchecked((int)0x80004005);
        }
    }

    public int OnNavigationFailed(IntPtr itemIdList) => 0;
}

[ComVisible(true)]
[Guid("6D5140C1-7436-11CE-8034-00AA006009FA")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IServiceProviderNative
{
    [PreserveSig] int QueryService(ref Guid serviceId, ref Guid interfaceId, out IntPtr result);
}

[ComImport]
[Guid("FC4801A3-2BA9-11CF-A229-00AA003D7352")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IObjectWithSiteNative
{
    [PreserveSig] int SetSite([MarshalAs(UnmanagedType.IUnknown)] object? site);
    [PreserveSig] int GetSite(ref Guid interfaceId, out IntPtr site);
}

[ComVisible(true)]
[Guid("000214F1-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICommDlgBrowserNative
{
    [PreserveSig] int OnDefaultCommand(IShellView shellView);
    [PreserveSig] int OnStateChange(IShellView shellView, uint change);
    [PreserveSig] int IncludeObject(IShellViewForFiltering shellView, IntPtr childItemIdList);
}

[ComVisible(true)]
[Guid("000214E3-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellViewForFiltering
{
    [PreserveSig] int GetWindow(out IntPtr window);
    [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enterMode);
    [PreserveSig] int TranslateAccelerator(IntPtr message);
    [PreserveSig] int EnableModeless([MarshalAs(UnmanagedType.Bool)] bool enable);
    [PreserveSig] int UIActivate(uint state);
    [PreserveSig] int Refresh();
    [PreserveSig] int CreateViewWindow(IntPtr previousView, IntPtr folderSettings, IntPtr shellBrowser, IntPtr rectangle, out IntPtr viewWindow);
    [PreserveSig] int DestroyViewWindow();
    [PreserveSig] int GetCurrentInfo(IntPtr folderSettings);
    [PreserveSig] int AddPropertySheetPages(uint reserved, IntPtr addPage, IntPtr parameter);
    [PreserveSig] int SaveViewState();
    [PreserveSig] int SelectItem(IntPtr itemIdList, uint flags);
    [PreserveSig] int GetItemObject(uint item, ref Guid interfaceId, out IntPtr result);
}

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
public sealed class ShellBrowserSite(Func<bool> showDirectories, Func<string?> currentPath) : IServiceProviderNative, ICommDlgBrowserNative, IDisposable
{
    private static readonly Guid CommDlgBrowserServiceId = new("000214F1-0000-0000-C000-000000000046");
    private static readonly Guid CommDlgBrowserInterfaceId = new("000214F1-0000-0000-C000-000000000046");
    private const uint ShellViewBackground = 0;
    private const uint ShellAttributeFolder = 0x20000000;
    private const int S_OK = 0;
    private const int S_FALSE = 1;
    private const int E_NOINTERFACE = unchecked((int)0x80004002);
    private readonly Func<string?> _currentPath = currentPath;
    private string? _cachedFolderPath;
    private IShellFolder? _cachedFolder;

    public void SetShowDirectories(bool value) => _showDirectories = value;

    private bool _showDirectories = showDirectories();

    public int QueryService(ref Guid serviceId, ref Guid interfaceId, out IntPtr result)
    {
        if (serviceId == CommDlgBrowserServiceId && interfaceId == CommDlgBrowserInterfaceId)
        {
            result = Marshal.GetComInterfaceForObject(this, typeof(ICommDlgBrowserNative));
            return S_OK;
        }

        result = IntPtr.Zero;
        return E_NOINTERFACE;
    }

    public int OnDefaultCommand(IShellView shellView) => S_OK;
    public int OnStateChange(IShellView shellView, uint change) => S_OK;

    public void Dispose()
    {
        ReleaseCachedFolder();
    }

    public int IncludeObject(IShellViewForFiltering shellView, IntPtr childItemIdList)
    {
        if (_showDirectories)
            return S_OK;

        IntPtr childArray = IntPtr.Zero;
        try
        {
            var folder = GetCurrentFolder();
            if (folder is null)
                return S_OK;

            childArray = Marshal.AllocCoTaskMem(IntPtr.Size);
            Marshal.WriteIntPtr(childArray, childItemIdList);
            var attributes = ShellAttributeFolder;
            var attributeResult = folder.GetAttributesOf(1, childArray, ref attributes);
            if (attributeResult < 0)
                return S_OK;

            return (attributes & ShellAttributeFolder) != 0 ? S_FALSE : S_OK;
        }
        catch
        {
            return S_OK;
        }
        finally
        {
            if (childArray != IntPtr.Zero)
                Marshal.FreeCoTaskMem(childArray);
        }
    }

    private IShellFolder? GetCurrentFolder()
    {
        var path = _currentPath();
        if (string.IsNullOrWhiteSpace(path))
            return null;

        if (_cachedFolder is not null && string.Equals(path, _cachedFolderPath, StringComparison.OrdinalIgnoreCase))
            return _cachedFolder;

        ReleaseCachedFolder();
        IntPtr absoluteItemIdList = IntPtr.Zero;
        IntPtr childItemIdList = IntPtr.Zero;
        IShellFolder? parentFolder = null;
        IShellFolder? childFolder = null;
        try
        {
            Marshal.ThrowExceptionForHR(SHParseDisplayName(path, IntPtr.Zero, out absoluteItemIdList, 0, out _));
            var folderInterfaceId = typeof(IShellFolder).GUID;
            Marshal.ThrowExceptionForHR(SHBindToParent(absoluteItemIdList, ref folderInterfaceId, out parentFolder, out childItemIdList));
            Marshal.ThrowExceptionForHR(parentFolder.BindToObject(childItemIdList, IntPtr.Zero, ref folderInterfaceId, out childFolder));
            _cachedFolder = childFolder;
            childFolder = null;
            _cachedFolderPath = path;
            return _cachedFolder;
        }
        catch (COMException)
        {
            ReleaseCachedFolder();
            return null;
        }
        finally
        {
            if (childFolder is not null && Marshal.IsComObject(childFolder))
                _ = Marshal.ReleaseComObject(childFolder);
            if (parentFolder is not null && Marshal.IsComObject(parentFolder))
                _ = Marshal.ReleaseComObject(parentFolder);
            if (absoluteItemIdList != IntPtr.Zero)
                Marshal.FreeCoTaskMem(absoluteItemIdList);
        }
    }

    private void ReleaseCachedFolder()
    {
        if (_cachedFolder is not null && Marshal.IsComObject(_cachedFolder))
            _ = Marshal.ReleaseComObject(_cachedFolder);
        _cachedFolder = null;
        _cachedFolderPath = null;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr itemIdList, uint attributesIn, out uint attributesOut);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHBindToParent(IntPtr itemIdList, ref Guid interfaceId, out IShellFolder parent, out IntPtr childItemIdList);
}

[StructLayout(LayoutKind.Sequential)]
internal struct FolderSettings
{
    public uint ViewMode;
    public uint Flags;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeRect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}