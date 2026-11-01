using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

internal sealed record PrivateTableItem(string Path, MediaType MediaType, ImageSource? Icon)
{
    public string AccessibleName => MediaTypeMap.GetName(MediaType);
    public override string ToString() => AccessibleName;
}

public partial class ContentView : UserControl
{
    public static readonly DependencyProperty PrivateTableTopGapOffsetProperty =
        DependencyProperty.Register(
            nameof(PrivateTableTopGapOffset),
            typeof(double),
            typeof(ContentView),
            new PropertyMetadata(PrivateTableTopGap));

    // Set true to reactivate the retained WPF ListView.
    private const bool UseLegacyWpfFileList = false;
    private static bool IsLegacyWpfFileList => UseLegacyWpfFileList;
    private const double PrivateTableTopGap = 6;

    private readonly DispatcherTimer _scrollSyncTimer;
    private bool _privateTableRefreshQueued;
    private string? _privateTablePendingNavigation;
    private ScrollViewer? _privateTableScrollViewer;
    private double? _lastShellScrollOffset;
    private double _privateTableRowPitch;
    private ShellExplorerBrowserHost? _shellBrowserHost;
    private bool _initialized;

    public ContentView()
    {
        InitializeComponent();
        HideDirectoriesCheckBox.GetCheckBox().Checked += HideDirectoriesCheckBox_StateChanged;
        HideDirectoriesCheckBox.GetCheckBox().Unchecked += HideDirectoriesCheckBox_StateChanged;
        HideInternalContentCheckBox.GetCheckBox().Checked += HideInternalContentCheckBox_StateChanged;
        HideInternalContentCheckBox.GetCheckBox().Unchecked += HideInternalContentCheckBox_StateChanged;
        _scrollSyncTimer = new DispatcherTimer(DispatcherPriority.Render, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(30)
        };
        _scrollSyncTimer.Tick += ScrollSyncTimer_Tick;
        Loaded += ContentView_Loaded;
        Unloaded += ContentView_Unloaded;
    }

    public double PrivateTableTopGapOffset
    {
        get => (double)GetValue(PrivateTableTopGapOffsetProperty);
        private set => SetValue(PrivateTableTopGapOffsetProperty, value);
    }

    internal bool UsesSynchronousNavigation => IsLegacyWpfFileList;
    internal bool FocusContent() => IsLegacyWpfFileList ? FileList.Focus() : _shellBrowserHost?.FocusContents() == true;
    internal bool? HideInternalItems
    {
        get => HideInternalContentCheckBox.GetCheckBox().IsChecked;
        set => HideInternalContentCheckBox.GetCheckBox().IsChecked = value;
    }

    private string CurrentPath { get; set; } = string.Empty;
    internal event EventHandler<string>? NavigationCompleted;
    internal event EventHandler<string>? NavigationFailed;
    internal event EventHandler<string>? FolderOpenRequested;
    internal event EventHandler? FileSystemChanged;

    internal void Initialize(bool isBrowsable)
    {
        if (_initialized)
            throw new InvalidOperationException("The content view is already initialized.");
        _initialized = true;
        FileList.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        ShellBrowserSlot.Visibility = IsLegacyWpfFileList ? Visibility.Collapsed : Visibility.Visible;
        PrivateFileTable.Visibility = ShellBrowserSlot.Visibility;
        StatusLabel.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        if (!IsLegacyWpfFileList)
        {
            _shellBrowserHost = new ShellExplorerBrowserHost(isBrowsable);
            _shellBrowserHost.NavigationStarting += (_, path) => BeginPrivateTableNavigation(path);
            _shellBrowserHost.NavigationCompleted += (_, path) =>
            {
                EndPrivateTableNavigation(path);
                NavigationCompleted?.Invoke(this, path);
            };
            _shellBrowserHost.NavigationFailed += (_, path) =>
            {
                EndPrivateTableNavigation(path);
                NavigationFailed?.Invoke(this, path);
            };
            _shellBrowserHost.FolderOpenRequested += (_, path) => FolderOpenRequested?.Invoke(this, path);
            _shellBrowserHost.FileSystemChanged += (_, _) => FileSystemChanged?.Invoke(this, EventArgs.Empty);
            _shellBrowserHost.DisplayedItemsChanged += (_, _) => SchedulePrivateTableRefresh();
            _shellBrowserHost.SetShowDirectories(HideDirectoriesCheckBox.GetCheckBox().IsChecked != true);
            _shellBrowserHost.SetHideInternal(HideInternalContentCheckBox.GetCheckBox().IsChecked == true);
            _shellBrowserHost.SetNamePattern(NamePatternTextBox.Text);
            ShellBrowserSlot.Content = _shellBrowserHost;
        }
    }

    internal void NavigateTo(string path)
    {
        if (_shellBrowserHost is null)
            throw new InvalidOperationException("Asynchronous content navigation is unavailable.");
        BeginPrivateTableNavigation(path);
        try
        {
            _shellBrowserHost.NavigateTo(path);
        }
        catch
        {
            EndPrivateTableNavigation(path);
            throw;
        }
    }

    internal void SetCurrentPath(string path) => CurrentPath = path;

    internal void Refresh(bool refreshView)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsLegacyWpfFileList)
            RefreshFiles();
        else if (refreshView)
            _shellBrowserHost?.RefreshContents();
        RefreshShellStatusCount();
    }

    internal void RefreshStatus() => RefreshShellStatusCount();

    internal void SetObservedDirectories(IEnumerable<string> directories) =>
        _shellBrowserHost?.SynchronizeChangeNotifications(directories);

    internal void ClearObservedDirectories() => _shellBrowserHost?.ClearChangeNotifications();

    private void ContentView_Loaded(object sender, RoutedEventArgs e)
    {
        ShellExplorerBrowserHost.ToolbarOperationStateChanged += ShellExplorerBrowserHost_ToolbarOperationStateChanged;
        _scrollSyncTimer.Start();
        CopyWorkflowState.Shared.Changed += CopyWorkflowState_Changed;
        MoveWorkflowState.Shared.Changed += MoveWorkflowState_Changed;
        _shellBrowserHost?.RefreshSelectionState();
        if (!IsLegacyWpfFileList)
            SchedulePrivateTableRefresh();
        UpdateToolbarOperationButtons();
    }

    private void ContentView_Unloaded(object sender, RoutedEventArgs e)
    {
        _scrollSyncTimer.Stop();
        ShellExplorerBrowserHost.ToolbarOperationStateChanged -= ShellExplorerBrowserHost_ToolbarOperationStateChanged;
        CopyWorkflowState.Shared.Changed -= CopyWorkflowState_Changed;
        MoveWorkflowState.Shared.Changed -= MoveWorkflowState_Changed;
    }

    private void RefreshFiles()
    {
        var entries = new List<FileEntry>();
        var showDirectories = HideDirectoriesCheckBox.GetCheckBox().IsChecked != true;
        try
        {
            if (showDirectories)
            {
                foreach (var directory in Directory.EnumerateDirectories(CurrentPath))
                {
                    if (!InternalItemFilter.MatchesNamePattern(directory, NamePatternTextBox.Text))
                        continue;

                    if (HideInternalContentCheckBox.GetCheckBox().IsChecked == true && InternalItemFilter.IsInternal(directory, true))
                        continue;

                    try
                    {
                        var info = new DirectoryInfo(directory);
                        var displayName = ShellDisplayNameProvider.GetDisplayName(directory) ?? info.Name;
                        entries.Add(new FileEntry(displayName, directory, true, "Folder", "", info.LastWriteTime));
                    }
                    catch (UnauthorizedAccessException)
                    {
                    }
                }
            }

            foreach (var file in Directory.EnumerateFiles(CurrentPath))
            {
                try
                {
                    var info = new FileInfo(file);
                    var isDirectory = (info.Attributes & FileAttributes.Directory) != 0;
                    if (!InternalItemFilter.MatchesNamePattern(file, NamePatternTextBox.Text))
                        continue;

                    if (HideInternalContentCheckBox.GetCheckBox().IsChecked == true && InternalItemFilter.IsInternal(file, isDirectory))
                        continue;

                    if (isDirectory)
                    {
                        if (showDirectories)
                        {
                            var displayName = ShellDisplayNameProvider.GetDisplayName(file) ?? info.Name;
                            entries.Add(new FileEntry(displayName, file, true, "Folder", "", info.LastWriteTime));
                        }
                        continue;
                    }

                    var fileDisplayName = ShellDisplayNameProvider.GetDisplayName(file) ?? info.Name;
                    entries.Add(new FileEntry(fileDisplayName, file, false, info.Extension, FormatSize(info.Length), info.LastWriteTime));
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            StatusLabel.Text = exception.Message;
        }

        FileList.ItemsSource = entries.OrderByDescending(entry => entry.IsDirectory)
            .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        StatusLabel.Text = $"{entries.Count} items";
    }

    private void HideDirectoriesCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsLegacyWpfFileList)
        {
            RefreshFiles();
            return;
        }

        _shellBrowserHost?.SetShowDirectories(HideDirectoriesCheckBox.GetCheckBox().IsChecked != true);
        RefreshShellStatusCount();
    }

    private void HideInternalContentCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsLegacyWpfFileList)
            RefreshFiles();
        else
            _shellBrowserHost?.SetHideInternal(HideInternalContentCheckBox.GetCheckBox().IsChecked == true);

        RefreshShellStatusCount();
    }

    private void NamePatternTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsLegacyWpfFileList)
            RefreshFiles();
        else
            _shellBrowserHost?.SetNamePattern(NamePatternTextBox.Text);

        RefreshShellStatusCount();
    }

    private void ClearNamePatternButton_Click(object sender, RoutedEventArgs e)
    {
        NamePatternTextBox.Clear();
    }

    private void ContentOperationButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string action })
            return;

        try
        {
            switch (action)
            {
                case "CopyGet":
                    if (MoveWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Move before starting a Copy.");

                    var copyPaths = IsLegacyWpfFileList
                        ? FileList.SelectedItems.OfType<FileEntry>().Select(entry => entry.FullPath).ToList()
                        : _shellBrowserHost?.GetSelectedFileSystemPaths() ?? [];
                    CopyWorkflowState.Shared.Prepare(copyPaths);
                    if (_shellBrowserHost is not null)
                        (Window.GetWindow(this) as MainWindow)?.InvokeToolbarShellCopy(InvokeShellCopyCommand);
                    break;
                case "CopyPaste":
                    var preparedPaths = CopyWorkflowState.Shared.PreparedPaths;
                    if (string.IsNullOrWhiteSpace(CurrentPath))
                        throw new InvalidOperationException("The destination folder is not ready.");

                    var owner = Window.GetWindow(this) is { } window
                        ? new System.Windows.Interop.WindowInteropHelper(window).Handle
                        : IntPtr.Zero;
                    ShellFileOperations.Copy(preparedPaths, CurrentPath, owner);
                    CopyWorkflowState.Shared.CompletePaste();
                    _shellBrowserHost?.RefreshContents();
                    break;
                case "CopyAbort":
                    CopyWorkflowState.Shared.Abort();
                    break;
                case "MoveGet":
                    if (CopyWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Copy before starting a Move.");

                    var movePaths = IsLegacyWpfFileList
                        ? FileList.SelectedItems.OfType<FileEntry>().Select(entry => entry.FullPath).ToList()
                        : _shellBrowserHost?.GetSelectedFileSystemPaths() ?? [];
                    MoveWorkflowState.Shared.Prepare(movePaths);
                    break;
                case "MovePaste":
                    var preparedMovePaths = MoveWorkflowState.Shared.PreparedPaths;
                    if (string.IsNullOrWhiteSpace(CurrentPath))
                        throw new InvalidOperationException("The destination folder is not ready.");

                    var moveOwner = Window.GetWindow(this) is { } moveWindow
                        ? new System.Windows.Interop.WindowInteropHelper(moveWindow).Handle
                        : IntPtr.Zero;
                    ShellFileOperations.Move(preparedMovePaths, CurrentPath, moveOwner);
                    MoveWorkflowState.Shared.CompletePaste();
                    _shellBrowserHost?.RefreshContents();
                    _shellBrowserHost?.RefreshSelectionState();
                    break;
                case "MoveAbort":
                    MoveWorkflowState.Shared.Abort();
                    break;
                case "Rename":
                    if (_shellBrowserHost is null)
                        throw new InvalidOperationException("Rename requires the Shell content view.");

                    _shellBrowserHost.RenameSelection();
                    break;
                case "PathGet":
                    var selectedPaths = IsLegacyWpfFileList
                        ? FileList.SelectedItems.OfType<FileEntry>().Select(entry => entry.FullPath).ToList()
                        : _shellBrowserHost?.GetSelectedFileSystemPaths() ?? [];
                    if (selectedPaths.Count != 1)
                        throw new InvalidOperationException("Select exactly one item before using Path get.");

                    Clipboard.SetText(selectedPaths[0]);
                    break;
                case "Delete":
                    _shellBrowserHost?.DeleteSelection();
                    break;
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Shell operation failed",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void FileList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateToolbarOperationButtons();

    private void InvokeShellCopyCommand() => _shellBrowserHost?.InvokeShellCopyCommand();

    private void ShellBrowserSlot_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var dpi = VisualTreeHelper.GetDpi(ShellBrowserSlot);
        _shellBrowserHost?.SetViewSize(
            (int)Math.Round(e.NewSize.Width * dpi.DpiScaleX),
            (int)Math.Round(e.NewSize.Height * dpi.DpiScaleY));
    }

    private void ShellExplorerBrowserHost_ToolbarOperationStateChanged(object? sender, EventArgs e) =>
        UpdateToolbarOperationButtons();

    private void CopyWorkflowState_Changed(object? sender, EventArgs e) =>
        UpdateToolbarOperationButtons();

    private void MoveWorkflowState_Changed(object? sender, EventArgs e) =>
        UpdateToolbarOperationButtons();

    private void UpdateToolbarOperationButtons()
    {
        var hasSelection = IsLegacyWpfFileList
            ? FileList.SelectedItems.Count > 0
            : _shellBrowserHost?.HasSelection == true;
        var hasSingleSelection = IsLegacyWpfFileList
            ? FileList.SelectedItems.Count == 1
            : _shellBrowserHost?.HasSingleSelection == true;
        RenameButton.IsEnabled = hasSingleSelection;
        PathGetButton.IsEnabled = hasSingleSelection;
        DeleteButton.IsEnabled = hasSelection;
        var copyPrepared = CopyWorkflowState.Shared.IsPrepared;
        var movePrepared = MoveWorkflowState.Shared.IsPrepared;
        var canStartOperation = !copyPrepared && !movePrepared;
        CopyGetButton.IsEnabled = hasSelection && canStartOperation;
        CopyPasteButton.IsEnabled = copyPrepared;
        CopyAbortButton.IsEnabled = copyPrepared;
        MoveGetButton.IsEnabled = hasSelection && canStartOperation;
        MovePasteButton.IsEnabled = movePrepared;
        MoveAbortButton.IsEnabled = movePrepared;
    }

    private void RefreshShellStatusCount()
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
        {
            StatusLabel.Text = string.Empty;
            return;
        }

        if (!IsLegacyWpfFileList)
            SchedulePrivateTableRefresh();

        if (ShellLocations.IsTopPath(CurrentPath))
        {
            var count = HideDirectoriesCheckBox.GetCheckBox().IsChecked == true
                ? 0
                : DriveInfo.GetDrives().Count(drive =>
                    InternalItemFilter.MatchesName(drive.Name.TrimEnd(Path.DirectorySeparatorChar), NamePatternTextBox.Text) &&
                    (HideInternalContentCheckBox.GetCheckBox().IsChecked != true ||
                     !InternalItemFilter.IsInternal(drive.RootDirectory.FullName, true)));
            StatusLabel.Text = $"{count} items";
            return;
        }

        try
        {
            var count = Directory.EnumerateFiles(CurrentPath)
                .Count(path => (File.GetAttributes(path) & FileAttributes.Directory) == 0 &&
                               InternalItemFilter.MatchesNamePattern(path, NamePatternTextBox.Text) &&
                               (HideInternalContentCheckBox.GetCheckBox().IsChecked != true || !InternalItemFilter.IsInternal(path, false)));
            if (HideDirectoriesCheckBox.GetCheckBox().IsChecked != true)
                count += Directory.EnumerateDirectories(CurrentPath)
                    .Count(path => InternalItemFilter.MatchesNamePattern(path, NamePatternTextBox.Text) &&
                                   (HideInternalContentCheckBox.GetCheckBox().IsChecked != true || !InternalItemFilter.IsInternal(path, true)));
            StatusLabel.Text = $"{count} items";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            StatusLabel.Text = exception.Message;
        }
    }

    private void SchedulePrivateTableRefresh()
    {
        if (_privateTableRefreshQueued || Dispatcher.HasShutdownStarted)
            return;
        _privateTableRefreshQueued = true;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(RefreshPrivateTable));
    }

    private void RefreshPrivateTable()
    {
        _privateTableRefreshQueued = false;
        if (!IsLoaded || _privateTablePendingNavigation is not null)
            return;
        try
        {
            var items = _shellBrowserHost?.GetDisplayedFileSystemItems() ?? [];
            var rows = items.Select(item =>
            {
                var mediaType = MediaTypeMap.GetMediaType(item.Path, item.IsDirectory);
                return new PrivateTableItem(item.Path, mediaType, MediaTypeIconMap.GetIcon(mediaType));
            }).ToList();
            if (PrivateFileTable.ItemsSource is IEnumerable<PrivateTableItem> currentRows &&
                currentRows.SequenceEqual(rows))
                return;

            PrivateFileTable.ItemsSource = rows;
            _lastShellScrollOffset = null;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            Debug.WriteLine($"Private table refresh failed: {exception}");
        }
    }

    private void BeginPrivateTableNavigation(string path)
    {
        _privateTablePendingNavigation = path;
        PrivateFileTable.ItemsSource = null;
        _lastShellScrollOffset = null;
        PrivateTableTopGapOffset = PrivateTableTopGap;
    }

    private void EndPrivateTableNavigation(string path)
    {
        if (_privateTablePendingNavigation is not null &&
            (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(_privateTablePendingNavigation) ||
             string.Equals(_privateTablePendingNavigation, path, StringComparison.OrdinalIgnoreCase)))
        {
            _privateTablePendingNavigation = null;
            SchedulePrivateTableRefresh();
        }
    }

    private void PrivateFileTable_PreviewMouseWheel(object sender, MouseWheelEventArgs e) =>
        e.Handled = true;

    private void PrivateFileTable_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is Key.Up or Key.Down or Key.Left or Key.Right or Key.PageUp or Key.PageDown or Key.Home or Key.End)
            e.Handled = true;
    }

    private void PrivateFileTable_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ReferenceEquals(e.Source, PrivateFileTable) && PrivateFileTable.SelectedIndex >= 0)
            PrivateFileTable.UnselectAll();
    }

    private void PrivateFileTable_RequestBringIntoView(object sender, RequestBringIntoViewEventArgs e) =>
        e.Handled = true;

    private void PrivateFileTable_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.OriginalSource is not ScrollViewer scrollViewer ||
            !ReferenceEquals(scrollViewer, _privateTableScrollViewer) ||
            _lastShellScrollOffset is not double shellOffset ||
            _privateTablePendingNavigation is not null)
            return;

        var target = Math.Clamp(shellOffset, 0, scrollViewer.ScrollableHeight);
        if (Math.Abs(scrollViewer.VerticalOffset - target) > 0.5)
            scrollViewer.ScrollToVerticalOffset(target);
    }

    private void ScrollSyncTimer_Tick(object? sender, EventArgs e)
    {
        if (_shellBrowserHost is null || !_shellBrowserHost.TryGetVerticalScrollRange(out var position, out var total))
            return;

        var itemCount = PrivateFileTable.Items.Count;
        if (itemCount == 0)
            return;

        var rowsScrolled = total > 0 ? (double)position * itemCount / total : 0;
        // The Shell consumes its top gap over the first row; only the rendering moves,
        // leaving the virtualized panel's uniform item sizes and scroll extent unchanged.
        PrivateTableTopGapOffset = PrivateTableTopGap * Math.Max(0, 1 - rowsScrolled);

        // Row pitch, not ActualHeight: item containers have a margin/border that adds to the spacing.
        // Measured once from the first two realized rows, since virtualization recycles them while scrolling.
        if (_privateTableRowPitch == 0 &&
            itemCount > 1 &&
            PrivateFileTable.ItemContainerGenerator.ContainerFromIndex(1) is FrameworkElement secondRow &&
            PrivateFileTable.ItemContainerGenerator.ContainerFromIndex(0) is FrameworkElement firstRow)
        {
            _privateTableRowPitch = secondRow.TranslatePoint(new Point(), firstRow).Y;
        }

        var rowPitch = _privateTableRowPitch;
        if (rowPitch == 0 && itemCount == 1 &&
            PrivateFileTable.ItemContainerGenerator.ContainerFromIndex(0) is FrameworkElement singleRow)
            rowPitch = singleRow.ActualHeight;
        if (rowPitch == 0)
            return;

        _privateTableScrollViewer ??= FindVisualChild<ScrollViewer>(PrivateFileTable);
        if (_privateTableScrollViewer is null)
            return;

        var offset = rowsScrolled * rowPitch;
        if (_lastShellScrollOffset == offset)
            return;

        _lastShellScrollOffset = offset;
        _privateTableScrollViewer.ScrollToVerticalOffset(offset);
    }

    private void FileList_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (FileList.View is not GridView gridView || gridView.Columns.Count < 5)
            return;

        const double iconColumnWidth = 34;
        const double typeColumnWidth = 130;
        const double sizeColumnWidth = 110;
        const double modifiedColumnWidth = 170;
        const double minimumNameWidth = 80;

        var scrollViewer = FindVisualChild<ScrollViewer>(FileList);
        var scrollbarWidth = scrollViewer?.ComputedVerticalScrollBarVisibility == Visibility.Visible
            ? SystemParameters.VerticalScrollBarWidth
            : 0;
        var fixedColumnWidths = iconColumnWidth + typeColumnWidth + sizeColumnWidth + modifiedColumnWidth;
        var availableNameWidth = FileList.ActualWidth - fixedColumnWidths - scrollbarWidth - 8;
        gridView.Columns[1].Width = Math.Max(minimumNameWidth, availableNameWidth);
    }

    private void FileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FileList.SelectedItem is not FileEntry entry)
            return;

        try
        {
            if (entry.IsDirectory)
                FolderOpenRequested?.Invoke(this, entry.FullPath);
            else
                Process.Start(new ProcessStartInfo(entry.FullPath) { UseShellExecute = true });
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open item", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void FileList_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        if (FindAncestor<ListViewItem>(source) is { DataContext: FileEntry entry })
        {
            FileList.SelectedItem = entry;
            ShowNativeMenu(this, entry.FullPath);
            e.Handled = true;
            return;
        }

        if (IsListChrome(source))
            return;

        FileList.SelectedItem = null;
        ShowNativeBackgroundMenu(this, CurrentPath);
        e.Handled = true;
    }

    private void FileList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        if (FindAncestor<ListViewItem>(source) is null && !IsListChrome(source))
            FileList.SelectedItem = null;
    }

    private void FileList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Apps && !(e.Key == Key.F10 && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            return;

        if (FileList.SelectedItem is FileEntry entry)
            ShowNativeMenu(this, entry.FullPath);
        else
            ShowNativeBackgroundMenu(this, CurrentPath);

        e.Handled = true;
    }

    private static string FormatSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        return $"{value:0.#} {units[unit]}";
    }
}

public sealed class FileEntry
{
    public FileEntry(string name, string fullPath, bool isDirectory, string type, string sizeText, DateTime modified)
    {
        Name = name;
        FullPath = fullPath;
        IsDirectory = isDirectory;
        Type = type;
        SizeText = sizeText;
        Modified = modified;
        Icons = ShellIconProvider.GetSmallIcons(fullPath);
    }

    public string Name { get; }
    public string FullPath { get; }
    public bool IsDirectory { get; }
    public string Type { get; }
    public string SizeText { get; }
    public DateTime Modified { get; }
    public ShellIconSet? Icons { get; }
    public string ModifiedText => Modified.ToString("g");
}
