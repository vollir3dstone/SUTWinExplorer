using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
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
    private const uint FolderFlagNoGrouping = 0x00100000;
    private const uint FolderViewOptionCustomPosition = 2;
    private const uint ShellDisplayNameFileSystemPath = 0x80058000;
    private const uint ColumnEnumVisible = 2;
    private const uint ColumnMaskWidth = 1;
    private const uint ColumnMaskState = 0x10;
    private const uint ColumnStateVisible = 1;
    private const int MinimumNameColumnWidth = 80;
    private const int ShellColumnTrailingInset = 11;
    private const int HResultAbort = unchecked((int)0x80004004);
    private const int ShellChangeNotifyMessage = 0x8000 + 0x271;
    private const int ShellChangeNotifySources = 0x0001 | 0x0002 | 0x8000;
    private const int ShellChangeDiskEvents = 0x0002381F;
    private static readonly ShellPropertyKey ItemNameDisplayPropertyKey = new()
    {
        FormatId = new Guid("B725F130-47EF-101A-A5F1-02608C9EEBAC"),
        PropertyId = 10
    };
    private static readonly ShellPropertyKey[] StandardColumns =
    [
        ItemNameDisplayPropertyKey,
        new() { FormatId = new Guid("B725F130-47EF-101A-A5F1-02608C9EEBAC"), PropertyId = 4 },
        new() { FormatId = new Guid("B725F130-47EF-101A-A5F1-02608C9EEBAC"), PropertyId = 12 },
        new() { FormatId = new Guid("B725F130-47EF-101A-A5F1-02608C9EEBAC"), PropertyId = 14 }
    ];
    private static readonly string ColumnSizingTracePath = Path.Combine(
        Path.GetTempPath(), $"SUTWinExplorer-column-sizing-{Environment.ProcessId}.log");
    private static readonly string KeyboardTracePath = Path.Combine(
        Path.GetTempPath(), $"SUTWinExplorer-keyboard-{Environment.ProcessId}.log");
    private IExplorerBrowserNative? _browser;
    private IObjectWithSiteNative? _browserSite;
    private ShellBrowserSite? _site;
    private ExplorerBrowserEventsSink? _eventsSink;
    private uint _eventsCookie;
    private IntPtr _hostWindow;
    private bool _initialized;
    private bool _showDirectories;
    private bool _hideInternal;
    private string _namePattern = string.Empty;
    private NativeRect _viewBounds;
    private bool _hasViewBounds;
    private string? _currentPath;
    private readonly HashSet<string> _desiredChangeNotificationPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, uint> _changeNotificationRegistrations = new(StringComparer.OrdinalIgnoreCase);
    private readonly bool _isBrowsable;
    private string? _programmaticNavigationPath;
    private string? _pendingPath;

    public event EventHandler<string>? NavigationCompleted;
    public event EventHandler<string>? NavigationFailed;
    public event EventHandler? FileSystemChanged;
    public static event EventHandler? ToolbarOperationStateChanged;

    public bool HasSelection { get; private set; }
    public bool HasSingleSelection { get; private set; }

    public ShellExplorerBrowserHost(bool isBrowsable)
    {
        _isBrowsable = isBrowsable;
    }

    public void NavigateTo(string path)
    {
        _programmaticNavigationPath = Path.GetFullPath(path);
        _pendingPath = _programmaticNavigationPath;
        if (_initialized)
        {
            try
            {
                BrowseToPendingPath();
            }
            catch
            {
                _programmaticNavigationPath = null;
                _pendingPath = _currentPath;
                throw;
            }
        }
    }

    public void SetShowDirectories(bool showDirectories)
    {
        _showDirectories = showDirectories;
        _site?.SetShowDirectories(showDirectories);
        RefreshAfterFilterChange($"Show directories refresh settled: {showDirectories}");
    }

    public void SetHideInternal(bool hideInternal)
    {
        _hideInternal = hideInternal;
        _site?.SetHideInternal(hideInternal);
        RefreshAfterFilterChange($"Hide internal refresh settled: {hideInternal}");
    }

    public void SetNamePattern(string namePattern)
    {
        _namePattern = namePattern;
        _site?.SetNamePattern(namePattern);
        RefreshAfterFilterChange("Name pattern refresh settled");
    }

    private void RefreshAfterFilterChange(string traceMessage)
    {
        RefreshCurrentView();
        var refreshTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(250)
        };
        refreshTimer.Tick += (_, _) =>
        {
            refreshTimer.Stop();
            TraceColumnSizing(traceMessage);
            ApplyViewBounds();
        };
        refreshTimer.Start();
    }

    public void RefreshContents() => RefreshCurrentView();

    public void DeleteSelection()
    {
        InvokeCurrentViewCommand(ShellContextMenu.ShellViewSelection, "delete");
    }

    public void RenameSelection()
    {
        _ = Focus();
        InvokeCurrentView(ShellContextMenu.RenameSelection);
    }

    public void InvokeShellCopyCommand() =>
        InvokeCurrentViewCommand(ShellContextMenu.ShellViewSelection, "copy");

    public List<string> GetSelectedFileSystemPaths()
    {
        if (_browser is null || !_initialized)
            throw new InvalidOperationException("The Shell content view is not ready.");

        IntPtr viewPointer = IntPtr.Zero;
        IShellView? view = null;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            Marshal.ThrowExceptionForHR(_browser.GetCurrentView(ref interfaceId, out viewPointer));
            if (viewPointer == IntPtr.Zero)
                throw new InvalidOperationException("The Shell content view is unavailable.");

            view = (IShellView)Marshal.GetObjectForIUnknown(viewPointer);
            return ShellFileOperations.GetSelectedFileSystemPaths(view);
        }
        finally
        {
            if (view is not null && Marshal.IsComObject(view))
                _ = Marshal.ReleaseComObject(view);
            if (viewPointer != IntPtr.Zero)
                _ = Marshal.Release(viewPointer);
        }
    }

    public void RefreshSelectionState()
    {
        var selectedCount = 0;
        try
        {
            selectedCount = GetSelectedFileSystemPaths().Count;
        }
        catch (COMException)
        {
        }
        catch (InvalidOperationException)
        {
        }

        var hasSelection = selectedCount > 0;
        var hasSingleSelection = selectedCount == 1;
        if (HasSelection == hasSelection && HasSingleSelection == hasSingleSelection)
            return;

        HasSelection = hasSelection;
        HasSingleSelection = hasSingleSelection;
        ToolbarOperationStateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ScheduleSelectionStateRefresh() =>
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(RefreshSelectionState));

    private void InvokeCurrentViewCommand(uint selectionKind, string verb) =>
        InvokeCurrentView(view => ShellContextMenu.InvokeViewCommand(view, selectionKind, _hostWindow, verb));

    private void InvokeCurrentView(Action<IShellView> command)
    {
        if (_browser is null || !_initialized)
            throw new InvalidOperationException("The Shell content view is not ready.");

        IntPtr viewPointer = IntPtr.Zero;
        IShellView? view = null;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            Marshal.ThrowExceptionForHR(_browser.GetCurrentView(ref interfaceId, out viewPointer));
            if (viewPointer == IntPtr.Zero)
                throw new InvalidOperationException("The Shell content view is unavailable.");

            view = (IShellView)Marshal.GetObjectForIUnknown(viewPointer);
            command(view);
        }
        finally
        {
            if (view is not null && Marshal.IsComObject(view))
                _ = Marshal.ReleaseComObject(view);
            if (viewPointer != IntPtr.Zero)
                _ = Marshal.Release(viewPointer);
        }
    }

    public void SynchronizeChangeNotifications(IEnumerable<string> directories)
    {
        _desiredChangeNotificationPaths.Clear();
        foreach (var directory in directories)
        {
            if (!string.IsNullOrWhiteSpace(directory))
                _desiredChangeNotificationPaths.Add(Path.GetFullPath(directory));
        }

        UpdateChangeNotificationRegistrations();
    }

    public void ClearChangeNotifications()
    {
        foreach (var registrationId in _changeNotificationRegistrations.Values)
            _ = SHChangeNotifyDeregister(registrationId);

        _changeNotificationRegistrations.Clear();
        _desiredChangeNotificationPaths.Clear();
    }

    private void UpdateChangeNotificationRegistrations()
    {
        if (_hostWindow == IntPtr.Zero)
            return;

        foreach (var path in _changeNotificationRegistrations.Keys
                     .Where(path => !_desiredChangeNotificationPaths.Contains(path)).ToArray())
        {
            _ = SHChangeNotifyDeregister(_changeNotificationRegistrations[path]);
            _changeNotificationRegistrations.Remove(path);
        }

        foreach (var path in _desiredChangeNotificationPaths)
        {
            if (_changeNotificationRegistrations.ContainsKey(path) || !Directory.Exists(path))
                continue;

            IntPtr itemIdList = IntPtr.Zero;
            try
            {
                if (SHParseDisplayName(path, IntPtr.Zero, out itemIdList, 0, out _) < 0 || itemIdList == IntPtr.Zero)
                    continue;

                var entry = new ShellChangeNotifyEntry { ItemIdList = itemIdList, Recursive = false };
                var registrationId = SHChangeNotifyRegister(
                    _hostWindow,
                    ShellChangeNotifySources,
                    ShellChangeDiskEvents,
                    ShellChangeNotifyMessage,
                    1,
                    ref entry);
                if (registrationId != 0)
                    _changeNotificationRegistrations.Add(path, registrationId);
            }
            finally
            {
                if (itemIdList != IntPtr.Zero)
                    Marshal.FreeCoTaskMem(itemIdList);
            }
        }
    }

    private void HandleShellChangeNotification(IntPtr changeHandle, IntPtr processId)
    {
        var notificationLock = SHChangeNotificationLock(
            changeHandle,
            unchecked((uint)processId.ToInt64()),
            out _,
            out _);
        if (notificationLock != IntPtr.Zero)
            _ = SHChangeNotificationUnlock(notificationLock);

        FileSystemChanged?.Invoke(this, EventArgs.Empty);
    }

    protected override IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == ShellChangeNotifyMessage)
        {
            HandleShellChangeNotification(wParam, lParam);
            handled = true;
            return IntPtr.Zero;
        }

        return base.WndProc(hwnd, message, wParam, lParam, ref handled);
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

            _site = new ShellBrowserSite(
                () => _showDirectories,
                () => _hideInternal,
                () => _namePattern,
                () => _pendingPath,
                ScheduleSelectionStateRefresh);
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
            ApplyViewBounds();

            _eventsSink = new ExplorerBrowserEventsSink(HandleNavigationPending, HandleNavigationCompleted, HandleNavigationFailed);
            Marshal.ThrowExceptionForHR(_browser.Advise(_eventsSink, out _eventsCookie));
            UpdateChangeNotificationRegistrations();

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
        if (_hostWindow == IntPtr.Zero || !GetClientRect(_hostWindow, out var bounds))
            return;

        TraceColumnSizing($"HwndHost position changed: client={bounds.Right - bounds.Left}x{bounds.Bottom - bounds.Top}");
        SetViewSize(bounds.Right - bounds.Left, bounds.Bottom - bounds.Top);
    }

    protected override bool TranslateAcceleratorCore(ref MSG msg, ModifierKeys modifiers)
    {
        var isKeyMessage = msg.message is 0x0100 or 0x0101 or 0x0102 or 0x0104 or 0x0105 or 0x0106;
        if (isKeyMessage)
            TraceKeyboard($"WPF accelerator msg=0x{msg.message:X4}, key=0x{msg.wParam.ToInt64():X}, modifiers={modifiers}");

        if (TryTranslateShellViewMessage(ref msg, isKeyMessage))
            return true;

        return base.TranslateAcceleratorCore(ref msg, modifiers);
    }

    private bool TryTranslateShellViewMessage(ref MSG msg, bool trace)
    {
        if (_browser is null || !_initialized)
            return false;

        IntPtr viewPointer = IntPtr.Zero;
        IShellView? view = null;
        IInputObjectNative? inputObject = null;
        IntPtr messagePointer = IntPtr.Zero;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            var viewResult = _browser.GetCurrentView(ref interfaceId, out viewPointer);
            if (trace)
                TraceKeyboard($"GetCurrentView=0x{viewResult:X8}, pointer=0x{viewPointer.ToInt64():X}");
            if (viewResult < 0 || viewPointer == IntPtr.Zero)
                return false;

            view = (IShellView)Marshal.GetObjectForIUnknown(viewPointer);
            messagePointer = Marshal.AllocHGlobal(Marshal.SizeOf<MSG>());
            Marshal.StructureToPtr(msg, messagePointer, false);

            try
            {
                inputObject = (IInputObjectNative)view;
                var inputResult = inputObject.TranslateAcceleratorIO(messagePointer);
                if (trace)
                    TraceKeyboard($"IInputObject.TranslateAcceleratorIO=0x{inputResult:X8}");
                if (inputResult == 0)
                    return true;
            }
            catch (InvalidCastException)
            {
                if (trace)
                    TraceKeyboard("Current Shell view does not expose IInputObject.");
            }

            var result = view.TranslateAccelerator(messagePointer);
            if (trace)
                TraceKeyboard($"IShellView.TranslateAccelerator=0x{result:X8}");
            return result == 0;
        }
        catch (COMException exception)
        {
            if (trace)
                TraceKeyboard($"Accelerator COM exception: 0x{exception.HResult:X8} {exception.Message}");
            return false;
        }
        finally
        {
            if (messagePointer != IntPtr.Zero)
                Marshal.FreeHGlobal(messagePointer);
            if (view is not null && Marshal.IsComObject(view))
                _ = Marshal.ReleaseComObject(view);
            if (viewPointer != IntPtr.Zero)
                _ = Marshal.Release(viewPointer);
        }
    }

    public void SetViewSize(int width, int height)
    {
        TraceColumnSizing($"WPF view size: {width}x{height}");
        if (width <= 0 || height <= 0)
            return;

        _viewBounds = new NativeRect { Right = width, Bottom = height };
        _hasViewBounds = true;
        ApplyViewBounds();
    }

    private void ApplyViewBounds()
    {
        if (_browser is null || !_initialized || !_hasViewBounds)
            return;

        var result = _browser.SetRect(IntPtr.Zero, _viewBounds);
        TraceColumnSizing($"SetRect({_viewBounds.Right}x{_viewBounds.Bottom})=0x{result:X8}");
        if (result >= 0)
            UpdateNameColumnWidth(_viewBounds.Right - _viewBounds.Left);
    }

    private void BrowseToPendingPath()
    {
        if (_browser is null || !_initialized || string.IsNullOrEmpty(_pendingPath))
            return;

        IntPtr itemIdList = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(SHParseDisplayName(_pendingPath, IntPtr.Zero, out itemIdList, 0, out _));
            var result = _browser.BrowseToIDList(itemIdList, 0);
            if (result < 0)
            {
                var failedPath = _pendingPath;
                _pendingPath = _currentPath;
                NavigationFailed?.Invoke(this, failedPath);
            }
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

        IntPtr viewPointer = IntPtr.Zero;
        IShellView? view = null;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            if (_browser.GetCurrentView(ref interfaceId, out viewPointer) >= 0 && viewPointer != IntPtr.Zero)
            {
                view = (IShellView)Marshal.GetObjectForIUnknown(viewPointer);
                _ = view.Refresh();
            }
        }
        finally
        {
            if (view is not null && Marshal.IsComObject(view))
                _ = Marshal.ReleaseComObject(view);
            if (viewPointer != IntPtr.Zero)
                _ = Marshal.Release(viewPointer);
        }
    }

    private void HandleNavigationCompleted(IntPtr itemIdList)
    {
        var path = TryGetFileSystemPath(itemIdList);
        if (path is null)
            return;

        _currentPath = path;
        _pendingPath = path;
        _programmaticNavigationPath = null;
        ApplyStandardFolderView();
        _ = Dispatcher.BeginInvoke(DispatcherPriority.DataBind, new Action(() =>
        {
            NavigationCompleted?.Invoke(this, path);
            ApplyViewBounds();
        }));
    }

    private void HandleNavigationFailed(IntPtr itemIdList)
    {
        var path = TryGetFileSystemPath(itemIdList);
        if (path is null || string.Equals(_programmaticNavigationPath, path, StringComparison.OrdinalIgnoreCase))
            _programmaticNavigationPath = null;
        if (path is null || string.Equals(_pendingPath, path, StringComparison.OrdinalIgnoreCase))
            _pendingPath = _currentPath;

        var failedPath = path ?? string.Empty;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.DataBind, new Action(() =>
            NavigationFailed?.Invoke(this, failedPath)));
    }

    private void ApplyStandardFolderView()
    {
        if (_browser is null || !_initialized)
            return;

        IntPtr folderViewPointer = IntPtr.Zero;
        IntPtr columnManagerPointer = IntPtr.Zero;
        IFolderView2Native? folderView = null;
        IColumnManagerNative? columnManager = null;
        try
        {
            var folderViewInterfaceId = typeof(IFolderView2Native).GUID;
            var folderViewResult = _browser.GetCurrentView(ref folderViewInterfaceId, out folderViewPointer);
            if (folderViewResult < 0 || folderViewPointer == IntPtr.Zero)
            {
                TraceColumnSizing($"Could not get IFolderView2 for view normalization: 0x{folderViewResult:X8}");
                return;
            }

            folderView = (IFolderView2Native)Marshal.GetObjectForIUnknown(folderViewPointer);
            ShellSortColumn[]? sortColumns = null;
            var sortCountResult = folderView.GetSortColumnCount(out var sortColumnCount);
            if (sortCountResult >= 0 && sortColumnCount > 0 && sortColumnCount <= 16)
            {
                sortColumns = new ShellSortColumn[sortColumnCount];
                var getSortResult = folderView.GetSortColumns(sortColumns, sortColumns.Length);
                if (getSortResult < 0)
                {
                    TraceColumnSizing($"GetSortColumns failed: 0x{getSortResult:X8}");
                    sortColumns = null;
                }
            }

            IntPtr viewOptionsPointer = IntPtr.Zero;
            IFolderViewOptionsNative? viewOptions = null;
            try
            {
                var viewOptionsInterfaceId = typeof(IFolderViewOptionsNative).GUID;
                var viewOptionsResult = _browser.GetCurrentView(ref viewOptionsInterfaceId, out viewOptionsPointer);
                if (viewOptionsResult >= 0 && viewOptionsPointer != IntPtr.Zero)
                {
                    viewOptions = (IFolderViewOptionsNative)Marshal.GetObjectForIUnknown(viewOptionsPointer);
                    var customPositionResult = viewOptions.SetFolderViewOptions(
                        FolderViewOptionCustomPosition,
                        FolderViewOptionCustomPosition);
                    TraceColumnSizing($"Enable required custom-position option=0x{customPositionResult:X8}");
                }
                else
                {
                    TraceColumnSizing($"Could not get IFolderViewOptions: 0x{viewOptionsResult:X8}");
                }
            }
            finally
            {
                if (viewOptions is not null && Marshal.IsComObject(viewOptions))
                    _ = Marshal.ReleaseComObject(viewOptions);
                if (viewOptionsPointer != IntPtr.Zero)
                    _ = Marshal.Release(viewOptionsPointer);
            }

            var groupingResult = folderView.SetCurrentFolderFlags(FolderFlagNoGrouping, FolderFlagNoGrouping);
            TraceColumnSizing($"Disable grouping=0x{groupingResult:X8}");

            var viewModeResult = folderView.SetCurrentViewMode(FolderViewDetails);
            TraceColumnSizing($"Set Details view=0x{viewModeResult:X8}");

            var columnManagerInterfaceId = typeof(IColumnManagerNative).GUID;
            var columnManagerResult = _browser.GetCurrentView(ref columnManagerInterfaceId, out columnManagerPointer);
            if (columnManagerResult >= 0 && columnManagerPointer != IntPtr.Zero)
            {
                columnManager = (IColumnManagerNative)Marshal.GetObjectForIUnknown(columnManagerPointer);
                var setColumnsResult = columnManager.SetColumns(StandardColumns, (uint)StandardColumns.Length);
                TraceColumnSizing($"Set standard columns=0x{setColumnsResult:X8}");
                if (setColumnsResult >= 0)
                {
                    foreach (var column in StandardColumns)
                    {
                        var columnInfo = ShellColumnInfo.Create(ColumnMaskState);
                        columnInfo.State = ColumnStateVisible;
                        var columnKey = column;
                        var columnStateResult = columnManager.SetColumnInfo(ref columnKey, ref columnInfo);
                        TraceColumnSizing($"Set visible column {column.PropertyId}=0x{columnStateResult:X8}");
                    }
                }
            }
            else
            {
                TraceColumnSizing($"Could not get IColumnManager for view normalization: 0x{columnManagerResult:X8}");
            }

            if (sortColumns is not null)
            {
                var restoreSortResult = folderView.SetSortColumns(sortColumns, sortColumns.Length);
                TraceColumnSizing($"Restore {sortColumns.Length} sort column(s)=0x{restoreSortResult:X8}");
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException)
        {
            TraceColumnSizing($"View normalization exception: {exception.GetType().Name}: {exception.Message}");
        }
        finally
        {
            if (columnManager is not null && Marshal.IsComObject(columnManager))
                _ = Marshal.ReleaseComObject(columnManager);
            if (columnManagerPointer != IntPtr.Zero)
                _ = Marshal.Release(columnManagerPointer);
            if (folderView is not null && Marshal.IsComObject(folderView))
                _ = Marshal.ReleaseComObject(folderView);
            if (folderViewPointer != IntPtr.Zero)
                _ = Marshal.Release(folderViewPointer);
        }
    }

    private void UpdateNameColumnWidth(int availableWidth)
    {
        if (_browser is null || !_initialized || availableWidth <= 0)
            return;

        availableWidth = GetShellViewClientWidth(availableWidth);

        IntPtr columnManagerPointer = IntPtr.Zero;
        IColumnManagerNative? columnManager = null;
        try
        {
            var interfaceId = typeof(IColumnManagerNative).GUID;
            var viewResult = _browser.GetCurrentView(ref interfaceId, out columnManagerPointer);
            TraceColumnSizing($"GetCurrentView(IColumnManager) result=0x{viewResult:X8}, pointer=0x{columnManagerPointer.ToInt64():X}");
            if (viewResult < 0 || columnManagerPointer == IntPtr.Zero)
                return;
            columnManager = (IColumnManagerNative)Marshal.GetObjectForIUnknown(columnManagerPointer);

            var countResult = columnManager.GetColumnCount(ColumnEnumVisible, out var columnCount);
            TraceColumnSizing($"GetColumnCount result=0x{countResult:X8}, count={columnCount}");
            if (countResult < 0 || columnCount == 0)
                return;

            var columns = new ShellPropertyKey[columnCount];
            var columnsResult = columnManager.GetColumns(ColumnEnumVisible, columns, columnCount);
            TraceColumnSizing($"GetColumns result=0x{columnsResult:X8}");
            if (columnsResult < 0)
                return;

            var nameColumnIndex = Array.FindIndex(columns, column =>
                column.FormatId == ItemNameDisplayPropertyKey.FormatId &&
                column.PropertyId == ItemNameDisplayPropertyKey.PropertyId);
            if (nameColumnIndex < 0)
            {
                TraceColumnSizing("Visible columns do not include PKEY_ItemNameDisplay.");
                return;
            }

            var otherColumnWidth = 0;
            for (var index = 0; index < columns.Length; index++)
            {
                if (index == nameColumnIndex)
                    continue;

                var columnInfo = ShellColumnInfo.Create(ColumnMaskWidth);
                var infoResult = columnManager.GetColumnInfo(ref columns[index], ref columnInfo);
                TraceColumnSizing($"GetColumnInfo {columns[index].FormatId:B}/{columns[index].PropertyId} result=0x{infoResult:X8}, width={columnInfo.Width}");
                if (infoResult < 0)
                    return;

                otherColumnWidth += (int)columnInfo.Width;
            }

            var nameColumnInfo = ShellColumnInfo.Create(ColumnMaskWidth);
            nameColumnInfo.Width = (uint)Math.Max(MinimumNameColumnWidth, availableWidth - otherColumnWidth - ShellColumnTrailingInset);
            var setResult = columnManager.SetColumnInfo(ref columns[nameColumnIndex], ref nameColumnInfo);
            TraceColumnSizing($"Set Name width={nameColumnInfo.Width} (view={availableWidth}, other={otherColumnWidth}) result=0x{setResult:X8}");
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException)
        {
            TraceColumnSizing($"Column sizing exception: {exception.GetType().Name}: {exception.Message}");
        }
        finally
        {
            if (columnManager is not null && Marshal.IsComObject(columnManager))
                _ = Marshal.ReleaseComObject(columnManager);
            if (columnManagerPointer != IntPtr.Zero)
                _ = Marshal.Release(columnManagerPointer);
        }
    }

    private int GetShellViewClientWidth(int fallbackWidth)
    {
        IntPtr viewPointer = IntPtr.Zero;
        IShellView? shellView = null;
        try
        {
            var interfaceId = typeof(IShellView).GUID;
            var result = _browser!.GetCurrentView(ref interfaceId, out viewPointer);
            if (result < 0 || viewPointer == IntPtr.Zero)
                return fallbackWidth;

            shellView = (IShellView)Marshal.GetObjectForIUnknown(viewPointer);
            if (shellView.GetWindow(out var viewWindow) < 0 || viewWindow == IntPtr.Zero || !GetClientRect(viewWindow, out var viewBounds))
                return fallbackWidth;

            var viewWidth = viewBounds.Right - viewBounds.Left;
            var viewClassName = new System.Text.StringBuilder(64);
            _ = GetClassName(viewWindow, viewClassName, viewClassName.Capacity);
            var verticalScrollBarWidth = GetVisibleVerticalScrollBarWidth(viewWindow);
            var usableWidth = viewWidth - verticalScrollBarWidth;
            TraceColumnSizing($"Shell view HWND=0x{viewWindow.ToInt64():X} class={viewClassName} client width={viewWidth}, vertical scrollbar={verticalScrollBarWidth}, usable width={usableWidth}, host width={fallbackWidth}");
            return usableWidth > 0 ? usableWidth : fallbackWidth;
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException)
        {
            TraceColumnSizing($"Could not read Shell view client width: {exception.GetType().Name}: {exception.Message}");
            return fallbackWidth;
        }
        finally
        {
            if (shellView is not null && Marshal.IsComObject(shellView))
                _ = Marshal.ReleaseComObject(shellView);
            if (viewPointer != IntPtr.Zero)
                _ = Marshal.Release(viewPointer);
        }
    }

    private static int GetVisibleVerticalScrollBarWidth(IntPtr viewWindow)
    {
        var scrollbarWidth = 0;
        var scrollbarCount = 0;
        EnumChildWindows(viewWindow, (childWindow, _) =>
        {
            var className = new System.Text.StringBuilder(64);
            if (GetClassName(childWindow, className, className.Capacity) == 0 || className.ToString() != "ScrollBar")
                return true;

            if (!GetClientRect(childWindow, out var bounds))
                return true;

            var width = bounds.Right - bounds.Left;
            var height = bounds.Bottom - bounds.Top;
            var visible = IsWindowVisible(childWindow);
            TraceColumnSizing($"Shell child scrollbar HWND=0x{childWindow.ToInt64():X} visible={visible} size={width}x{height}");
            if (visible)
            {
                scrollbarCount++;
                if (width > 0 && height > width)
                    scrollbarWidth += width;
            }

            return true;
        }, IntPtr.Zero);
        TraceColumnSizing($"Visible scrollbar scan found {scrollbarCount} bars, vertical width={scrollbarWidth}");
        return scrollbarWidth;
    }

    private static void TraceColumnSizing(string message)
    {
        if (Environment.GetEnvironmentVariable("SUTWINEXPLORER_TRACE_COLUMNS") != "1")
            return;

        try
        {
            File.AppendAllText(ColumnSizingTracePath, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch (IOException)
        {
        }
    }

    private static void TraceKeyboard(string message)
    {
        if (Environment.GetEnvironmentVariable("SUTWINEXPLORER_TRACE_KEYS") != "1")
            return;

        try
        {
            File.AppendAllText(KeyboardTracePath, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch (IOException)
        {
        }
    }

    private int HandleNavigationPending(IntPtr itemIdList)
    {
        var path = TryGetFileSystemPath(itemIdList);
        if (!_isBrowsable &&
            (path is null || !string.Equals(_programmaticNavigationPath, path, StringComparison.OrdinalIgnoreCase)))
            return HResultAbort;

        if (!_isBrowsable)
            _programmaticNavigationPath = null;
        if (path is not null)
            _pendingPath = path;

        return 0;
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
        ClearChangeNotifications();
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

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern uint SHChangeNotifyRegister(IntPtr window, int sources, int events, uint message, int entryCount, ref ShellChangeNotifyEntry entry);

    [DllImport("shell32.dll", PreserveSig = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SHChangeNotifyDeregister(uint registrationId);

    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Lock", PreserveSig = true)]
    private static extern IntPtr SHChangeNotificationLock(IntPtr changeHandle, uint processId, out IntPtr itemIdLists, out int eventId);

    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Unlock", PreserveSig = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SHChangeNotificationUnlock(IntPtr notificationLock);

    [StructLayout(LayoutKind.Sequential)]
    private struct ShellChangeNotifyEntry
    {
        public IntPtr ItemIdList;
        [MarshalAs(UnmanagedType.Bool)] public bool Recursive;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, System.Text.StringBuilder className, int maximum);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
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
    [PreserveSig] int GetCurrentView(ref Guid interfaceId, out IntPtr view);
}

[ComImport]
[Guid("D8EC27BB-3F3B-4042-B10A-4ACFD924D453")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IColumnManagerNative
{
    [PreserveSig] int SetColumnInfo(ref ShellPropertyKey propertyKey, ref ShellColumnInfo columnInfo);
    [PreserveSig] int GetColumnInfo(ref ShellPropertyKey propertyKey, ref ShellColumnInfo columnInfo);
    [PreserveSig] int GetColumnCount(uint flags, out uint columnCount);
    [PreserveSig] int GetColumns(uint flags, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] ShellPropertyKey[] columns, uint columnCount);
    [PreserveSig] int SetColumns([In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ShellPropertyKey[] columns, uint columnCount);
}

[ComImport]
[Guid("1AF3A467-214F-4298-908E-06B03E0B39F9")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IFolderView2Native
{
    [PreserveSig] int GetCurrentViewMode();
    [PreserveSig] int SetCurrentViewMode(uint viewMode);
    [PreserveSig] int UnusedSlot02();
    [PreserveSig] int UnusedSlot03();
    [PreserveSig] int UnusedSlot04();
    [PreserveSig] int UnusedSlot05();
    [PreserveSig] int UnusedSlot06();
    [PreserveSig] int UnusedSlot07();
    [PreserveSig] int UnusedSlot08();
    [PreserveSig] int UnusedSlot09();
    [PreserveSig] int UnusedSlot10();
    [PreserveSig] int UnusedSlot11();
    [PreserveSig] int UnusedSlot12();
    [PreserveSig] int UnusedSlot13();
    [PreserveSig] int UnusedSlot14();
    [PreserveSig] int UnusedSlot15();
    [PreserveSig] int UnusedSlot16();
    [PreserveSig] int UnusedSlot17();
    [PreserveSig] int UnusedSlot18();
    [PreserveSig] int UnusedSlot19();
    [PreserveSig] int UnusedSlot20();
    [PreserveSig] int SetCurrentFolderFlags(uint mask, uint flags);
    [PreserveSig] int UnusedSlot22();
    [PreserveSig] int GetSortColumnCount(out int columnCount);
    [PreserveSig] int SetSortColumns([In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ShellSortColumn[] columns, int columnCount);
    [PreserveSig] int GetSortColumns([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ShellSortColumn[] columns, int columnCount);
}

[ComImport]
[Guid("3CC974D2-B302-4D36-AD3E-06D93F695D3F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IFolderViewOptionsNative
{
    [PreserveSig] int SetFolderViewOptions(uint mask, uint options);
    [PreserveSig] int GetFolderViewOptions(out uint options);
}

[StructLayout(LayoutKind.Sequential)]
internal struct ShellSortColumn
{
    public ShellPropertyKey PropertyKey;
    public int Direction;
}

[StructLayout(LayoutKind.Sequential)]
internal struct ShellPropertyKey
{
    public Guid FormatId;
    public uint PropertyId;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct ShellColumnInfo
{
    public uint Size;
    public uint Mask;
    public uint State;
    public uint Width;
    public uint DefaultWidth;
    public uint IdealWidth;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string Name;

    public static ShellColumnInfo Create(uint mask) => new()
    {
        Size = (uint)Marshal.SizeOf<ShellColumnInfo>(),
        Mask = mask,
        Name = string.Empty
    };
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
internal sealed class ExplorerBrowserEventsSink(
    Func<IntPtr, int> navigationPending,
    Action<IntPtr> navigationCompleted,
    Action<IntPtr> navigationFailed) : IExplorerBrowserEventsNative
{
    public int OnNavigationPending(IntPtr itemIdList)
    {
        try
        {
            return navigationPending(itemIdList);
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

    public int OnNavigationFailed(IntPtr itemIdList)
    {
        try
        {
            navigationFailed(itemIdList);
            return 0;
        }
        catch
        {
            return unchecked((int)0x80004005);
        }
    }
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
public sealed class ShellBrowserSite(
    Func<bool> showDirectories,
    Func<bool> hideInternal,
    Func<string?> namePattern,
    Func<string?> currentPath,
    Action selectionChanged) : IServiceProviderNative, ICommDlgBrowserNative, IDisposable
{
    private static readonly Guid CommDlgBrowserServiceId = new("000214F1-0000-0000-C000-000000000046");
    private static readonly Guid CommDlgBrowserInterfaceId = new("000214F1-0000-0000-C000-000000000046");
    private const uint ShellViewBackground = 0;
    private const uint ShellAttributeFolder = 0x20000000;
    private const uint ShellDisplayNameInFolderForParsing = 0x8001;
    private const uint ShellDisplayNameInFolder = 0x0001;
    private const int ShellStringReturnSize = 272;
    private const uint CommDlgBrowserSelectionChanged = 2;
    private const int S_OK = 0;
    private const int S_FALSE = 1;
    private const int E_NOINTERFACE = unchecked((int)0x80004002);
    private readonly Func<string?> _currentPath = currentPath;
    private readonly Action _selectionChanged = selectionChanged;
    private string? _cachedFolderPath;
    private IShellFolder? _cachedFolder;

    public void SetShowDirectories(bool value) => _showDirectories = value;
    public void SetHideInternal(bool value) => _hideInternal = value;
    public void SetNamePattern(string value) => _namePattern = value;

    private bool _showDirectories = showDirectories();
    private bool _hideInternal = hideInternal();
    private string _namePattern = namePattern() ?? string.Empty;

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

    public int OnDefaultCommand(IShellView shellView) => S_FALSE;
    public int OnStateChange(IShellView shellView, uint change)
    {
        if (change == CommDlgBrowserSelectionChanged)
            _selectionChanged();
        return S_OK;
    }

    public void Dispose()
    {
        ReleaseCachedFolder();
    }

    public int IncludeObject(IShellViewForFiltering shellView, IntPtr childItemIdList)
    {
        if (_showDirectories && !_hideInternal && string.IsNullOrEmpty(_namePattern))
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

            var isDirectory = (attributes & ShellAttributeFolder) != 0;
            if (!_showDirectories && isDirectory)
                return S_FALSE;

            if (_hideInternal || !string.IsNullOrEmpty(_namePattern))
            {
                var itemPath = GetChildPath(folder, childItemIdList);
                if (!string.IsNullOrEmpty(_namePattern))
                {
                    var itemName = GetChildName(folder, childItemIdList, ShellDisplayNameInFolder);
                    if (string.IsNullOrEmpty(itemName) && itemPath is not null)
                        itemName = Path.GetFileName(Path.TrimEndingDirectorySeparator(itemPath));

                    if (itemName is not null && !InternalItemFilter.MatchesName(itemName, _namePattern))
                        return S_FALSE;
                }

                if (_hideInternal && itemPath is not null &&
                    InternalItemFilter.ShouldHide(itemPath, isDirectory))
                    return S_FALSE;
            }

            return S_OK;
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

    private string? GetChildPath(IShellFolder folder, IntPtr childItemIdList)
    {
        var currentPath = _currentPath();
        if (string.IsNullOrWhiteSpace(currentPath))
            return null;

        var childName = GetChildName(folder, childItemIdList, ShellDisplayNameInFolderForParsing);
        return string.IsNullOrEmpty(childName) ? null : Path.Combine(currentPath, childName);
    }

    private static string? GetChildName(IShellFolder folder, IntPtr childItemIdList, uint displayNameFlags)
    {
        var shellStringReturn = Marshal.AllocCoTaskMem(ShellStringReturnSize);
        try
        {
            Marshal.WriteInt32(shellStringReturn, 0);
            var result = folder.GetDisplayNameOf(childItemIdList, displayNameFlags, shellStringReturn);
            if (result < 0)
                return null;

            var unionOffset = IntPtr.Size == 8 ? 8 : 4;
            var childName = Marshal.ReadInt32(shellStringReturn) switch
            {
                0 => Marshal.PtrToStringUni(Marshal.ReadIntPtr(shellStringReturn, unionOffset)),
                1 => Marshal.PtrToStringAnsi(IntPtr.Add(childItemIdList, Marshal.ReadInt32(shellStringReturn, unionOffset))),
                2 => Marshal.PtrToStringAnsi(IntPtr.Add(shellStringReturn, unionOffset)),
                _ => null
            };
            return childName;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (Marshal.ReadInt32(shellStringReturn) == 0)
            {
                var stringPointerOffset = IntPtr.Size == 8 ? 8 : 4;
                var shellString = Marshal.ReadIntPtr(shellStringReturn, stringPointerOffset);
                if (shellString != IntPtr.Zero)
                    Marshal.FreeCoTaskMem(shellString);
            }

            Marshal.FreeCoTaskMem(shellStringReturn);
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

[ComImport]
[Guid("68284FAA-6A48-11D0-8C78-00C04FD918B4")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IInputObjectNative
{
    [PreserveSig] int UIActivateIO([MarshalAs(UnmanagedType.Bool)] bool activate, IntPtr message);
    [PreserveSig] int HasFocusIO();
    [PreserveSig] int TranslateAcceleratorIO(IntPtr message);
}