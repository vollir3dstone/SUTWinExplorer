using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace SUTWinExplorer;

public partial class Pathview : UserControl
{
    public const double DirectoryTreeRowHeight = 24;
    internal const string TopPath = "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}";
    internal static bool IsTopPath(string? path) =>
        string.Equals(path, TopPath, StringComparison.OrdinalIgnoreCase);

    public static readonly DependencyProperty PaneBackgroundProperty =
        DependencyProperty.Register(
            nameof(PaneBackground),
            typeof(Brush),
            typeof(Pathview),
            new FrameworkPropertyMetadata(new SolidColorBrush(Colors.White)));

    // Set true to reactivate the retained WPF ListView; false selects the Shell-hosted production view.
    private const bool UseLegacyWpfFileList = false;
    private static bool IsLegacyWpfFileList => UseLegacyWpfFileList;

    private enum TreeNavigationMode
    {
        DoubleClick,
        SingleClick
    }

    private enum NavigationHistoryAction
    {
        Normal,
        Back,
        Forward,
        None
    }

    private const TreeNavigationMode ActiveTreeNavigationMode = TreeNavigationMode.SingleClick;
    private readonly Stack<string> _backHistory = new();
    private readonly Stack<string> _forwardHistory = new();
    private readonly DispatcherTimer _fileSystemRefreshTimer;
    private ShellExplorerBrowserHost? _shellBrowserHost;
    private bool _suppressTreeBringIntoView;
    private TreeEntry? _pendingTreeNavigationEntry;
    private string? _pendingNavigationPath;
    private NavigationHistoryAction _pendingNavigationHistoryAction;
    private bool _fileSystemStateDirty = true;
    private bool _shellViewNeedsRefresh = true;
    private readonly List<TreeEntry> _driveRoots = [];

    public Pathview(string initialPath, bool isBrowsable)
    {
        InitializeComponent();
        HideDirectoriesCheckBox.GetCheckBox().Checked += HideDirectoriesCheckBox_StateChanged;
        HideDirectoriesCheckBox.GetCheckBox().Unchecked += HideDirectoriesCheckBox_StateChanged;
        HideInternalContentCheckBox.GetCheckBox().Checked += HideInternalContentCheckBox_StateChanged;
        HideInternalContentCheckBox.GetCheckBox().Unchecked += HideInternalContentCheckBox_StateChanged;
        HideInternalSubfoldersCheckBox.GetCheckBox().Checked += HideInternalSubfoldersCheckBox_StateChanged;
        HideInternalSubfoldersCheckBox.GetCheckBox().Unchecked += HideInternalSubfoldersCheckBox_StateChanged;
        IsBrowsable = isBrowsable;
        ActivePathTab.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        ActivePathAndSiblingsTab.Visibility = IsBrowsable ? Visibility.Visible : Visibility.Collapsed;
        SidebarTabs.SelectedItem = IsBrowsable ? ActivePathAndSiblingsTab : ActivePathTab;
        FixedPathBadge.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        BrowsePathviewButton.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        PinPathviewButton.Visibility = IsBrowsable ? Visibility.Visible : Visibility.Collapsed;
        PaneColorButton.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        BrowsePathviewButton.ToolTip = "Open this location in the browsable Pathview";
        PinPathviewButton.ToolTip = "Keep this location open in a non-browsable Pathview";
        _fileSystemRefreshTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(200)
        };
        _fileSystemRefreshTimer.Tick += FileSystemRefreshTimer_Tick;
        Loaded += Pathview_Loaded;
        Unloaded += Pathview_Unloaded;
        IsVisibleChanged += Pathview_IsVisibleChanged;
        FileList.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        ShellBrowserSlot.Visibility = IsLegacyWpfFileList ? Visibility.Collapsed : Visibility.Visible;
        StatusLabel.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        InitializeActivePathAndSiblingsTree();
        if (!IsLegacyWpfFileList)
        {
            _shellBrowserHost = new ShellExplorerBrowserHost(IsBrowsable);
            _shellBrowserHost.NavigationCompleted += ShellBrowserHost_NavigationCompleted;
            _shellBrowserHost.NavigationFailed += ShellBrowserHost_NavigationFailed;
            _shellBrowserHost.FolderOpenRequested += ShellBrowserHost_FolderOpenRequested;
            _shellBrowserHost.FileSystemChanged += ShellBrowserHost_FileSystemChanged;
            _shellBrowserHost.SetShowDirectories(HideDirectoriesCheckBox.GetCheckBox().IsChecked != true);
            _shellBrowserHost.SetHideInternal(HideInternalContentCheckBox.GetCheckBox().IsChecked == true);
            _shellBrowserHost.SetNamePattern(NamePatternTextBox.Text);
            ShellBrowserSlot.Content = _shellBrowserHost;
        }
        Navigate(initialPath, NavigationHistoryAction.None);
    }

    public bool IsBrowsable { get; }
    public Brush PaneBackground
    {
        get => (Brush)GetValue(PaneBackgroundProperty);
        set => SetValue(PaneBackgroundProperty, value);
    }

    public string CurrentPath { get; private set; } = string.Empty;
    public event EventHandler<string>? LocationChanged;
    public event EventHandler? NavigationFailed;
    public event EventHandler? PinRequested;
    public event EventHandler? BrowseRequested;
    public event EventHandler<string>? BrowseLocationRequested;

    public void Navigate(string path) => Navigate(path, NavigationHistoryAction.Normal);

    public void GoBack()
    {
        if (_backHistory.Count == 0)
            return;

        Navigate(_backHistory.Peek(), NavigationHistoryAction.Back);
    }

    public void GoForward()
    {
        if (_forwardHistory.Count == 0)
            return;

        Navigate(_forwardHistory.Peek(), NavigationHistoryAction.Forward);
    }

    public void GoUp()
    {
        if (IsTopPath(CurrentPath))
            return;

        var parent = Directory.GetParent(CurrentPath)?.FullName;
        if (parent is not null)
            Navigate(parent);
    }

    private void Navigate(string path, NavigationHistoryAction historyAction)
    {
        if (!IsBrowsable && historyAction != NavigationHistoryAction.None)
            return;

        var trimmedPath = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        var fullPath = IsTopPath(trimmedPath) ? TopPath : Path.GetFullPath(trimmedPath);
        if (_pendingTreeNavigationEntry is { } pendingEntry &&
            !string.Equals(pendingEntry.Path, fullPath, StringComparison.OrdinalIgnoreCase))
        {
            ClearPendingTreeNavigation();
        }

        if (IsLegacyWpfFileList && !Directory.Exists(fullPath))
            throw new DirectoryNotFoundException($"The directory does not exist or is not accessible: {fullPath}");

        if (string.Equals(CurrentPath, fullPath, StringComparison.OrdinalIgnoreCase))
            return;

        if (IsLegacyWpfFileList)
        {
            CommitNavigation(fullPath, historyAction);
            RefreshFiles();
            return;
        }

        _pendingNavigationPath = fullPath;
        _pendingNavigationHistoryAction = historyAction;
        try
        {
            _shellBrowserHost?.NavigateTo(fullPath);
        }
        catch
        {
            _pendingNavigationPath = null;
            throw;
        }
    }

    private void CommitNavigation(string path, NavigationHistoryAction historyAction)
    {
        if (_pendingTreeNavigationEntry is { } pendingEntry &&
            string.Equals(pendingEntry.Path, path, StringComparison.OrdinalIgnoreCase))
        {
            ClearPendingTreeNavigation();
        }

        switch (historyAction)
        {
            case NavigationHistoryAction.Normal:
                if (!string.IsNullOrEmpty(CurrentPath))
                    _backHistory.Push(CurrentPath);
                _forwardHistory.Clear();
                break;
            case NavigationHistoryAction.Back:
                if (_backHistory.Count > 0 && string.Equals(_backHistory.Peek(), path, StringComparison.OrdinalIgnoreCase))
                    _backHistory.Pop();
                if (!string.IsNullOrEmpty(CurrentPath))
                    _forwardHistory.Push(CurrentPath);
                break;
            case NavigationHistoryAction.Forward:
                if (_forwardHistory.Count > 0 && string.Equals(_forwardHistory.Peek(), path, StringComparison.OrdinalIgnoreCase))
                    _forwardHistory.Pop();
                if (!string.IsNullOrEmpty(CurrentPath))
                    _backHistory.Push(CurrentPath);
                break;
        }

        CurrentPath = path;
        PinPathviewButton.IsEnabled = true;
        BrowsePathviewButton.IsEnabled = true;
        LocationLabel.Text = ShellDisplayNameProvider.GetDisplayPath(path);
        RefreshActivePathAndSiblingsTree();
        RefreshActivePathTree();
        SynchronizeShellChangeNotifications();
        LocationChanged?.Invoke(this, CurrentPath);
        if (!IsLegacyWpfFileList)
            RefreshShellStatusCount();
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
                    (Window.GetWindow(this) as MainWindow)?.InvokeToolbarShellCopy(_shellBrowserHost);
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

    private void PathviewActionButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsBrowsable)
            PinRequested?.Invoke(this, EventArgs.Empty);
        else
            BrowseRequested?.Invoke(this, EventArgs.Empty);
    }

    private void PaneColorButton_Click(object sender, RoutedEventArgs e) =>
        PaneColorPopup.IsOpen = true;

    private void PaneColorSwatch_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SolidColorBrush selectedBrush })
            return;

        PaneBackground = selectedBrush;
        if (Window.GetWindow(this) is MainWindow mainWindow)
            mainWindow.SetPathviewTabBackground(this, selectedBrush);
        PaneColorPopup.IsOpen = false;
    }

    private void LocationHeaderPanel_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var fixedBadgeWidth = FixedPathBadge.Visibility == Visibility.Visible
            ? FixedPathBadge.ActualWidth + FixedPathBadge.Margin.Left + FixedPathBadge.Margin.Right
            : 0;
        var actionButton = IsBrowsable ? PinPathviewButton : BrowsePathviewButton;
        var actionButtonWidth = actionButton.Visibility == Visibility.Visible
            ? actionButton.ActualWidth + actionButton.Margin.Left + actionButton.Margin.Right
            : 0;
        var titlePadding = LocationLabel.Padding.Left + LocationLabel.Padding.Right;
        LocationLabel.MaxWidth = Math.Max(0,
            LocationHeaderPanel.ActualWidth - fixedBadgeWidth - actionButtonWidth - titlePadding);
    }

    private void ShellBrowserSlot_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var dpi = VisualTreeHelper.GetDpi(ShellBrowserSlot);
        _shellBrowserHost?.SetViewSize(
            (int)Math.Round(e.NewSize.Width * dpi.DpiScaleX),
            (int)Math.Round(e.NewSize.Height * dpi.DpiScaleY));
    }

    private void Pathview_Loaded(object sender, RoutedEventArgs e)
    {
        ShellExplorerBrowserHost.ToolbarOperationStateChanged += ShellExplorerBrowserHost_ToolbarOperationStateChanged;
        CopyWorkflowState.Shared.Changed += CopyWorkflowState_Changed;
        MoveWorkflowState.Shared.Changed += MoveWorkflowState_Changed;
        _shellBrowserHost?.RefreshSelectionState();
        UpdateToolbarOperationButtons();
        _fileSystemStateDirty = true;
        _shellViewNeedsRefresh = true;
        SynchronizeShellChangeNotifications();
        ScheduleFileSystemRefreshIfVisible();
    }

    private void Pathview_Unloaded(object sender, RoutedEventArgs e)
    {
        ShellExplorerBrowserHost.ToolbarOperationStateChanged -= ShellExplorerBrowserHost_ToolbarOperationStateChanged;
        CopyWorkflowState.Shared.Changed -= CopyWorkflowState_Changed;
        MoveWorkflowState.Shared.Changed -= MoveWorkflowState_Changed;
        _fileSystemRefreshTimer.Stop();
        _fileSystemStateDirty = true;
        _shellViewNeedsRefresh = true;
        _shellBrowserHost?.ClearChangeNotifications();
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

    private void Pathview_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible)
        {
            _fileSystemStateDirty = true;
            _shellViewNeedsRefresh = true;
            SynchronizeShellChangeNotifications();
            ScheduleFileSystemRefreshIfVisible();
        }
    }

    private void RefreshCurrentFileSystemState(bool refreshShellView)
    {
        if (IsLegacyWpfFileList)
            RefreshFiles();
        else if (refreshShellView)
            _shellBrowserHost?.RefreshContents();

        RefreshShellStatusCount();
        RefreshActivePathTree();
        RefreshCurrentRouteTree();
    }

    private void RefreshCurrentRouteTree()
    {
        if (ActivePathAndSiblingsTree.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        if (IsTopPath(CurrentPath))
        {
            RefreshActivePathAndSiblingsTree();
            return;
        }

        var top = roots.FirstOrDefault(root => root.IsTop);
        if (top is null)
            return;

        var rootPath = Path.GetPathRoot(CurrentPath);
        var active = top.Children.FirstOrDefault(root => string.Equals(root.Path, rootPath, StringComparison.OrdinalIgnoreCase));
        if (active is null)
            return;

        RefreshTreeChildren(active);
        var segments = Path.GetRelativePath(rootPath!, CurrentPath)
            .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        foreach (var segment in segments)
        {
            var childPath = Path.Combine(active.Path, segment);
            var child = active.Children.FirstOrDefault(candidate =>
                !candidate.IsPlaceholder && string.Equals(candidate.Path, childPath, StringComparison.OrdinalIgnoreCase));
            if (child is null)
            {
                RefreshTreeChildren(active);
                child = active.Children.FirstOrDefault(candidate =>
                    !candidate.IsPlaceholder && string.Equals(candidate.Path, childPath, StringComparison.OrdinalIgnoreCase));
            }

            if (child is null)
                return;

            active = child;
            RefreshTreeChildren(active);
        }
    }

    private void HideInternalCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (ActivePathAndSiblingsTree.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        foreach (var root in roots)
            RefreshLoadedTree(root);
    }

    private void HideSiblingsCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (ActivePathAndSiblingsTree.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        RefreshActivePathAndSiblingsTree();
        foreach (var root in roots)
            RefreshLoadedTree(root);
        RefreshActivePathAndSiblingsTree();
    }

    private void HideInternalSubfoldersCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (!IsBrowsable)
            RefreshActivePathTree();
    }

    private void RefreshLoadedTree(TreeEntry entry)
    {
        if (entry.IsPlaceholder)
            return;

        if (!entry.IsTop && entry.IsLoaded)
            RefreshTreeChildren(entry);

        foreach (var child in entry.Children.Where(child => !child.IsPlaceholder).ToArray())
            RefreshLoadedTree(child);
    }

    private void SynchronizeShellChangeNotifications()
    {
        if (!IsLoaded)
            return;

        var desiredPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddCurrentPathNotificationPaths(desiredPaths);

        _shellBrowserHost?.SynchronizeChangeNotifications(desiredPaths);
    }

    private void AddCurrentPathNotificationPaths(HashSet<string> paths)
    {
        var rootPath = Path.GetPathRoot(CurrentPath);
        if (string.IsNullOrEmpty(rootPath))
            return;

        var currentPath = rootPath;
        AddNotificationPath(paths, currentPath);
        var segments = GetPathSegments(rootPath, CurrentPath);
        foreach (var segment in segments)
        {
            currentPath = Path.Combine(currentPath, segment);
            AddNotificationPath(paths, currentPath);
        }
    }

    private static void AddNotificationPath(HashSet<string> paths, string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return;

        try
        {
            paths.Add(Path.GetFullPath(path));
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
        }
    }

    private void ShellBrowserHost_FileSystemChanged(object? sender, EventArgs e)
    {
        _fileSystemStateDirty = true;
        _shellViewNeedsRefresh = false;
        ScheduleFileSystemRefreshIfVisible();
    }

    private void ScheduleFileSystemRefreshIfVisible()
    {
        if (!_fileSystemStateDirty || !IsLoaded || !IsVisible ||
            Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
            return;

        _fileSystemRefreshTimer.Stop();
        _fileSystemRefreshTimer.Start();
    }

    private void FileSystemRefreshTimer_Tick(object? sender, EventArgs e)
    {
        _fileSystemRefreshTimer.Stop();
        if (!IsLoaded || !IsVisible)
            return;

        var refreshShellView = _shellViewNeedsRefresh;
        _fileSystemStateDirty = false;
        _shellViewNeedsRefresh = false;
        RefreshCurrentFileSystemState(refreshShellView);
        SynchronizeShellChangeNotifications();
    }

    private void RefreshShellStatusCount()
    {
        if (IsTopPath(CurrentPath))
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

    private void ShellBrowserHost_NavigationCompleted(object? sender, string path)
    {
        var fullPath = IsTopPath(path) ? TopPath : Path.GetFullPath(path);
        if (_pendingTreeNavigationEntry is { } pendingEntry &&
            string.Equals(pendingEntry.Path, fullPath, StringComparison.OrdinalIgnoreCase))
        {
            ClearPendingTreeNavigation();
        }
        else if (_pendingTreeNavigationEntry is { } supersededEntry &&
                 string.Equals(_pendingNavigationPath, supersededEntry.Path, StringComparison.OrdinalIgnoreCase))
        {
            ClearPendingTreeNavigation();
        }

        var isPendingNavigation = string.Equals(_pendingNavigationPath, fullPath, StringComparison.OrdinalIgnoreCase);
        var historyAction = isPendingNavigation ? _pendingNavigationHistoryAction : NavigationHistoryAction.Normal;
        if (isPendingNavigation)
            _pendingNavigationPath = null;

        if (string.Equals(CurrentPath, fullPath, StringComparison.OrdinalIgnoreCase))
            return;

        CommitNavigation(fullPath, historyAction);
    }

    private void ShellBrowserHost_NavigationFailed(object? sender, string path)
    {
        var isCurrentFailure = string.IsNullOrEmpty(path) ||
            string.Equals(_pendingNavigationPath, path, StringComparison.OrdinalIgnoreCase);
        if (isCurrentFailure)
            _pendingNavigationPath = null;

        if (_pendingTreeNavigationEntry is { } pendingEntry &&
            (string.IsNullOrEmpty(path) || string.Equals(pendingEntry.Path, path, StringComparison.OrdinalIgnoreCase)))
        {
            ClearPendingTreeNavigation();
        }

        RefreshActivePathAndSiblingsTree();
        RefreshActivePathTree();
        if (isCurrentFailure)
            NavigationFailed?.Invoke(this, EventArgs.Empty);
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

    private static T? FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match)
                return match;

            if (FindVisualChild<T>(child) is { } descendant)
                return descendant;
        }

        return null;
    }

    private void InitializeActivePathAndSiblingsTree()
    {
        var top = TreeEntry.Top();
        top.IsExpanded = true;
        foreach (var drive in DriveInfo.GetDrives())
        {
            var root = new TreeEntry(drive.Name, drive.RootDirectory.FullName);
            AddPlaceholder(root);
            top.Children.Add(root);
            _driveRoots.Add(root);
        }

        top.HasSubdirectories = top.Children.Count > 0;
        ActivePathAndSiblingsTree.ItemsSource = new ObservableCollection<TreeEntry> { top };
    }

    private void RefreshActivePathTree()
    {
        var rootPath = Path.GetPathRoot(CurrentPath);
        if (string.IsNullOrEmpty(rootPath))
            return;

        var root = new TreeEntry(rootPath, rootPath);
        root.IsLoaded = true;
        var segments = GetPathSegments(rootPath, CurrentPath);
        var parent = root;
        var currentPath = rootPath;

        foreach (var segment in segments)
        {
            currentPath = Path.Combine(currentPath, segment);
            parent.IsExpanded = true;
            var child = new TreeEntry(segment, currentPath) { IsLoaded = true };
            parent.Children.Add(child);
            parent = child;
        }

        RefreshTreeChildren(parent, useSubfolderFilter: true);
        parent.HasSubdirectories = false;
        parent.IsSelected = true;
        ActivePathTree.Height = (segments.Length + 1) * DirectoryTreeRowHeight;
        ActivePathTree.ItemsSource = new[] { root };
        ActivePathSubfoldersList.ItemsSource = parent.Children;
    }

    private void RefreshActivePathAndSiblingsTree()
    {
        if (ActivePathAndSiblingsTree.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        var top = roots.FirstOrDefault(root => root.IsTop);
        if (top is null)
            return;

        var isTopPath = IsTopPath(CurrentPath);
        var rootPath = isTopPath ? null : Path.GetPathRoot(CurrentPath);
        if (!isTopPath && string.IsNullOrEmpty(rootPath))
            return;

        foreach (var driveRoot in _driveRoots)
            CollapseLoadedNodes(driveRoot);

        var visibleRoots = _driveRoots.Where(root =>
            isTopPath || HideSiblingsCheckBox.IsChecked != true ||
            string.Equals(root.Path, rootPath, StringComparison.OrdinalIgnoreCase)).ToArray();
        for (var index = 0; index < visibleRoots.Length; index++)
        {
            var root = visibleRoots[index];
            var currentIndex = top.Children.IndexOf(root);
            if (currentIndex < 0)
                top.Children.Insert(index, root);
            else if (currentIndex != index)
                top.Children.Move(currentIndex, index);
        }

        while (top.Children.Count > visibleRoots.Length)
            top.Children.RemoveAt(top.Children.Count - 1);
        top.HasSubdirectories = top.Children.Count > 0;
        top.IsExpanded = true;
        top.IsSelected = isTopPath;

        if (isTopPath)
            return;

        var active = top.Children.FirstOrDefault(root => string.Equals(root.Path, rootPath, StringComparison.OrdinalIgnoreCase));
        if (active is null)
            return;

        var segments = GetPathSegments(rootPath!, CurrentPath);
        var route = new List<TreeEntry> { top, active };

        foreach (var segment in segments)
        {
            RefreshTreeChildren(active);
            var childPath = Path.Combine(active.Path, segment);
            var child = active.Children.FirstOrDefault(candidate =>
                !candidate.IsPlaceholder && string.Equals(candidate.Path, childPath, StringComparison.OrdinalIgnoreCase));
            if (child is null)
                return;
            active = child;
            route.Add(active);
        }

        RefreshTreeChildren(active);
        active.IsSelected = true;
        foreach (var routeEntry in route)
            routeEntry.IsExpanded = true;

        if (IsBrowsable)
        {
            var activeEntry = active;
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
            {
                if (string.Equals(CurrentPath, activeEntry.Path, StringComparison.OrdinalIgnoreCase))
                {
                    ActivePathAndSiblingsTree.UpdateLayout();
                    CenterTreeItemInView(ActivePathAndSiblingsTree, activeEntry);
                }
            }));
        }
    }

    private static void CenterTreeItemInView(TreeView tree, TreeEntry entry)
    {
        var item = FindTreeViewItem(tree, entry);
        var scrollViewer = FindVisualChild<ScrollViewer>(tree);
        if (item is null || scrollViewer is null || scrollViewer.ViewportHeight <= 0 ||
            item.Template.FindName("PART_Header", item) is not FrameworkElement header ||
            header.ActualHeight <= 0)
        {
            return;
        }

        var headerCenterY = header.TranslatePoint(new Point(0, header.ActualHeight / 2), scrollViewer).Y;
        scrollViewer.ScrollToVerticalOffset(
            scrollViewer.VerticalOffset + headerCenterY - scrollViewer.ViewportHeight / 2);
    }

    private static TreeViewItem? FindTreeViewItem(DependencyObject parent, TreeEntry entry)
    {
        if (parent is TreeViewItem item && ReferenceEquals(item.DataContext, entry))
            return item;

        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            if (FindTreeViewItem(VisualTreeHelper.GetChild(parent, index), entry) is { } descendant)
                return descendant;
        }

        return null;
    }

    private static string[] GetPathSegments(string rootPath, string path)
    {
        var relativePath = Path.GetRelativePath(rootPath, path);
        return relativePath == "."
            ? []
            : relativePath.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
    }

    private static void CollapseLoadedNodes(TreeEntry entry)
    {
        entry.IsExpanded = false;
        entry.IsSelected = false;
        foreach (var child in entry.Children)
            CollapseLoadedNodes(child);
    }

    private void TreeItem_Expanded(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is TreeViewItem { DataContext: TreeEntry entry } && !entry.IsPlaceholder)
        {
            var tree = FindAncestor<TreeView>(sender as DependencyObject);
            if (!ReferenceEquals(tree, ActivePathTree))
            {
                LoadChildren(entry);
                SynchronizeShellChangeNotifications();
            }
        }
    }

    private void LoadChildren(TreeEntry entry)
    {
        if (entry.IsLoaded || entry.IsPlaceholder)
            return;

        RefreshTreeChildren(entry);
    }

    private void RefreshTreeChildren(TreeEntry entry, bool useSubfolderFilter = false)
    {
        if (entry.IsPlaceholder || entry.IsTop)
            return;

        try
        {
            var directories = Directory.EnumerateDirectories(entry.Path).ToArray();
            entry.HasSubdirectories = directories.Length > 0;
            directories = directories
                .Where(directory =>
                    !(useSubfolderFilter
                        ? ShouldHideSubfolderDirectory(directory)
                        : ShouldHideTreeDirectory(directory)) &&
                    (useSubfolderFilter || !ShouldHideSiblingDirectory(entry, directory)))
                .ToArray();
            var existingChildren = entry.Children
                .Where(child => !child.IsPlaceholder)
                .ToDictionary(child => child.Path, StringComparer.OrdinalIgnoreCase);
            var refreshedChildren = new List<TreeEntry>(directories.Length);

            foreach (var directory in directories)
            {
                if (!existingChildren.TryGetValue(directory, out var child))
                {
                    child = new TreeEntry(Path.GetFileName(Path.TrimEndingDirectorySeparator(directory)), directory);
                    AddPlaceholder(child);
                }
                else
                {
                    child.RefreshDisplayName();
                    child.RefreshIcons();
                }

                refreshedChildren.Add(child);
            }

            refreshedChildren = refreshedChildren
                .OrderBy(child => child.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(child => child.Path, StringComparer.OrdinalIgnoreCase)
                .ToList();

            for (var index = 0; index < refreshedChildren.Count; index++)
            {
                var child = refreshedChildren[index];
                var currentIndex = entry.Children.IndexOf(child);
                if (currentIndex < 0)
                    entry.Children.Insert(index, child);
                else if (currentIndex != index)
                    entry.Children.Move(currentIndex, index);
            }

            while (entry.Children.Count > refreshedChildren.Count)
                entry.Children.RemoveAt(entry.Children.Count - 1);

            entry.IsLoaded = true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private bool ShouldHideTreeDirectory(string directoryPath)
    {
        return HideInternalCheckBox.IsChecked == true &&
               !IsOnCurrentPath(directoryPath) &&
               InternalItemFilter.IsInternal(directoryPath, true);
    }

    private bool ShouldHideSiblingDirectory(TreeEntry parent, string directoryPath)
    {
        return HideSiblingsCheckBox.IsChecked == true &&
               !string.Equals(parent.Path, CurrentPath, StringComparison.OrdinalIgnoreCase) &&
               !IsActivePathChild(parent.Path, directoryPath);
    }

    private bool IsActivePathChild(string parentPath, string directoryPath)
    {
        try
        {
            var relativePath = Path.GetRelativePath(parentPath, directoryPath);
            return !Path.IsPathRooted(relativePath) &&
                   relativePath != "." &&
                   !relativePath.Contains(Path.DirectorySeparatorChar) &&
                   IsOnCurrentPath(directoryPath);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            return false;
        }
    }

    private bool ShouldHideSubfolderDirectory(string directoryPath)
    {
        return HideInternalSubfoldersCheckBox.GetCheckBox().IsChecked == true &&
               InternalItemFilter.IsInternal(directoryPath, true);
    }

    private bool IsOnCurrentPath(string directoryPath)
    {
        try
        {
            var relativePath = Path.GetRelativePath(directoryPath, CurrentPath);
            return relativePath == "." ||
                   (!Path.IsPathRooted(relativePath) && relativePath != ".." &&
                    !relativePath.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal));
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            return false;
        }
    }

    private static void AddPlaceholder(TreeEntry entry) => entry.Children.Add(TreeEntry.Placeholder());

    private void FileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FileList.SelectedItem is not FileEntry entry)
            return;

        try
        {
            if (entry.IsDirectory && IsBrowsable)
                Navigate(entry.FullPath);
            else if (entry.IsDirectory)
                BrowseLocationRequested?.Invoke(this, entry.FullPath);
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
            ShowNativeMenu(entry.FullPath);
            e.Handled = true;
            return;
        }

        if (IsListChrome(source))
            return;

        FileList.SelectedItem = null;
        ShowNativeBackgroundMenu();
        e.Handled = true;
    }

    private void ActivePathSubfoldersListItem_MouseEnter(object sender, MouseEventArgs e)
    {
        ActivePathSubfoldersList.SelectedItem = null;
    }

    private void ActivePathSubfoldersList_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        if (FindAncestor<ListViewItem>(source) is { DataContext: TreeEntry entry } && !entry.IsPlaceholder)
        {
            ActivePathSubfoldersList.SelectedItem = entry;
            ShowNativeMenu(entry.Path);
            e.Handled = true;
            return;
        }

        if (IsListChrome(source))
            return;

        ActivePathSubfoldersList.SelectedItem = null;
        ShowNativeBackgroundMenu();
        e.Handled = true;
    }

    private void ActivePathSubfoldersList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Apps && !(e.Key == Key.F10 && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            return;

        if (ActivePathSubfoldersList.SelectedItem is TreeEntry entry && !entry.IsPlaceholder)
            ShowNativeMenu(entry.Path);
        else
            ShowNativeBackgroundMenu();

        e.Handled = true;
    }

    private void ActivePathSubfoldersList_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<ListViewItem>(e.OriginalSource as DependencyObject) is
            { DataContext: TreeEntry { IsPlaceholder: false } entry })
            BrowseLocationRequested?.Invoke(this, entry.Path);
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
            ShowNativeMenu(entry.FullPath);
        else
            ShowNativeBackgroundMenu();

        e.Handled = true;
    }

    private static bool IsListChrome(DependencyObject? source) =>
        FindAncestor<GridViewColumnHeader>(source) is not null || FindAncestor<ScrollBar>(source) is not null;

    private void Tree_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not TreeView || FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } || entry.IsPlaceholder)
            return;

        entry.IsSelected = true;
        ShowNativeMenu(entry.Path);
        e.Handled = true;
    }

    private void Tree_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!IsBrowsable || sender is not TreeView tree ||
            FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } ||
            entry.IsPlaceholder || FindAncestor<ToggleButton>(e.OriginalSource as DependencyObject) is not null)
        {
            return;
        }

        FocusTreeWithoutScrolling(tree);
        e.Handled = true;
    }

    // TreeView.Focus() focuses the selected item, whose BringIntoView would scroll the tree between
    // mouse down and mouse up, so the release would hit a different row than the one clicked.
    private void FocusTreeWithoutScrolling(TreeView tree)
    {
        _suppressTreeBringIntoView = true;
        try
        {
            tree.Focus();
        }
        finally
        {
            _suppressTreeBringIntoView = false;
        }
    }

    private void Tree_RequestBringIntoView(object sender, RequestBringIntoViewEventArgs e)
    {
        if (_suppressTreeBringIntoView)
            e.Handled = true;
    }

    private void Tree_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!IsBrowsable && ReferenceEquals(sender, ActivePathTree))
        {
            if (FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is
                { DataContext: TreeEntry { IsPlaceholder: false } fixedEntry })
                BrowseLocationRequested?.Invoke(this, fixedEntry.Path);
            return;
        }

        if (!IsBrowsable || ActiveTreeNavigationMode != TreeNavigationMode.SingleClick ||
            FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } item ||
            entry.IsPlaceholder)
        {
            return;
        }

        var isDisclosureClick = FindAncestor<ToggleButton>(e.OriginalSource as DependencyObject) is not null;
        if (isDisclosureClick && IsBrowsable && item.IsExpanded &&
            string.Equals(CurrentPath, entry.Path, StringComparison.OrdinalIgnoreCase) &&
            ItemsControl.ItemsControlFromItemContainer(item) is TreeViewItem { DataContext: TreeEntry parentEntry })
        {
            QueueTreeNavigation(parentEntry);
            return;
        }

        if (!isDisclosureClick && string.Equals(CurrentPath, entry.Path, StringComparison.OrdinalIgnoreCase))
            item.IsExpanded = true;

        QueueTreeNavigation(entry);
    }

    private void Tree_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not
            { DataContext: TreeEntry { IsPlaceholder: false } entry })
        {
            return;
        }

        if (!IsBrowsable)
        {
            BrowseLocationRequested?.Invoke(this, entry.Path);
        }
    }

    private void ShellBrowserHost_FolderOpenRequested(object? sender, string path) =>
        BrowseLocationRequested?.Invoke(this, path);

    private void NavigateFromTree(TreeEntry entry)
    {
        try
        {
            Navigate(entry.Path);
        }
        catch (Exception exception)
        {
            if (ReferenceEquals(_pendingTreeNavigationEntry, entry))
                ClearPendingTreeNavigation();
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open folder", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void QueueTreeNavigation(TreeEntry entry)
    {
        if (string.Equals(CurrentPath, entry.Path, StringComparison.OrdinalIgnoreCase))
            return;

        if (IsBrowsable)
        {
            ClearPendingTreeNavigation();
            _pendingTreeNavigationEntry = entry;
            entry.IsNavigationPending = true;
        }

        if (ActivePathAndSiblingsTree.ItemsSource is ObservableCollection<TreeEntry> roots)
        {
            foreach (var root in roots)
                RestoreTreeSelection(root);
        }
        RefreshActivePathTree();
        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => NavigateFromTree(entry)));
    }

    private void ClearPendingTreeNavigation()
    {
        if (_pendingTreeNavigationEntry is not { } entry)
            return;

        entry.IsNavigationPending = false;
        _pendingTreeNavigationEntry = null;
    }

    private void RestoreTreeSelection(TreeEntry entry)
    {
        entry.IsSelected = string.Equals(entry.Path, CurrentPath, StringComparison.OrdinalIgnoreCase);
        foreach (var child in entry.Children)
            RestoreTreeSelection(child);
    }

    private void ShowNativeMenu(string path)
    {
        try
        {
            var owner = new WindowInteropHelper(Window.GetWindow(this)!).Handle;
            ShellContextMenu.Show(path, owner);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Shell context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ShowNativeBackgroundMenu()
    {
        try
        {
            var owner = new WindowInteropHelper(Window.GetWindow(this)!).Handle;
            ShellContextMenu.ShowBackground(CurrentPath, owner);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Shell context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null)
        {
            if (current is T match)
                return match;
            current = VisualTreeHelper.GetParent(current);
        }

        return null;
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

public sealed class TreeEntry : INotifyPropertyChanged
{
    private bool _isExpanded;
    private bool _isSelected;
    private bool _isNavigationPending;
    private bool _hasSubdirectories;

    private TreeEntry(string name, string path, bool isPlaceholder, bool isTop = false)
    {
        Name = isPlaceholder ? name : ShellDisplayNameProvider.GetDisplayName(path) ?? name;
        Path = path;
        IsPlaceholder = isPlaceholder;
        IsTop = isTop;
        IsLoaded = isPlaceholder || isTop;
        _hasSubdirectories = isTop || (!isPlaceholder && ContainsSubdirectories(path));
        Icons = isPlaceholder ? null : ShellIconProvider.GetSmallIcons(path);
    }

    public TreeEntry(string name, string path) : this(name, path, false) { }

    public string Name { get; private set; }
    public string Path { get; }
    public bool IsPlaceholder { get; }
    public bool IsTop { get; }
    public bool IsLoaded { get; set; }
    public bool HasSubdirectories
    {
        get => _hasSubdirectories;
        set => SetField(ref _hasSubdirectories, value);
    }
    public bool IsExpanded
    {
        get => _isExpanded;
        set => SetField(ref _isExpanded, value);
    }
    public bool IsSelected
    {
        get => _isSelected;
        set => SetField(ref _isSelected, value);
    }
    public bool IsNavigationPending
    {
        get => _isNavigationPending;
        set => SetField(ref _isNavigationPending, value);
    }
    public ShellIconSet? Icons { get; private set; }
    public ObservableCollection<TreeEntry> Children { get; } = new();
    public event PropertyChangedEventHandler? PropertyChanged;

    public static TreeEntry Placeholder() => new("Loading", string.Empty, true);
    public static TreeEntry Top() => new(string.Empty, Pathview.TopPath, false, true);

    private static bool ContainsSubdirectories(string path)
    {
        try
        {
            return Directory.EnumerateDirectories(path).Any();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void RefreshIcons()
    {
        if (IsPlaceholder)
            return;

        Icons = ShellIconProvider.GetSmallIcons(Path);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Icons)));
    }

    public void RefreshDisplayName()
    {
        if (IsPlaceholder)
            return;

        var displayName = ShellDisplayNameProvider.GetDisplayName(Path);
        if (displayName is null || string.Equals(Name, displayName, StringComparison.Ordinal))
            return;

        Name = displayName;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Name)));
    }

    private void SetField(ref bool field, bool value, [System.Runtime.CompilerServices.CallerMemberName] string? propertyName = null)
    {
        if (field == value)
            return;

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
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

public sealed record ShellIconSet(ImageSource? BaseIcon, ImageSource? OverlayIcon, double Opacity);

internal static class ShellDisplayNameProvider
{
    private const uint ShellDisplayNameNormal = 0;

    public static string GetDisplayPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return path;

        if (Pathview.IsTopPath(path))
            return GetDisplayName(path) ?? "This PC";

        var fullPath = Path.GetFullPath(path);
        var rootPath = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(rootPath))
            return path;

        if (string.Equals(fullPath, rootPath, StringComparison.OrdinalIgnoreCase))
            return rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        var displayPath = rootPath;
        var currentPath = rootPath;
        var relativePath = Path.GetRelativePath(rootPath, fullPath);
        foreach (var segment in relativePath.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            currentPath = Path.Combine(currentPath, segment);
            displayPath = Path.Combine(displayPath, GetDisplayName(currentPath) ?? segment);
        }

        return displayPath;
    }

    public static string ResolvePath(string input)
    {
        var expandedInput = Environment.ExpandEnvironmentVariables(input.Trim().Trim('"'));
        if (Pathview.IsTopPath(expandedInput) ||
            string.Equals(expandedInput, GetDisplayName(Pathview.TopPath), StringComparison.OrdinalIgnoreCase) ||
            string.Equals(expandedInput, "This PC", StringComparison.OrdinalIgnoreCase))
        {
            return Pathview.TopPath;
        }

        var fullPath = Path.GetFullPath(expandedInput);
        if (Directory.Exists(fullPath))
            return fullPath;

        var rootPath = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(rootPath))
            return fullPath;

        var currentPath = rootPath;
        var relativePath = Path.GetRelativePath(rootPath, fullPath);
        foreach (var segment in relativePath.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            var childPath = Path.Combine(currentPath, segment);
            if (Directory.Exists(childPath))
            {
                currentPath = childPath;
                continue;
            }

            try
            {
                currentPath = Directory.EnumerateDirectories(currentPath)
                    .FirstOrDefault(directory => string.Equals(GetDisplayName(directory), segment, StringComparison.OrdinalIgnoreCase))
                    ?? childPath;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                currentPath = childPath;
            }
        }

        return Path.GetFullPath(currentPath);
    }

    public static string? GetDisplayName(string path)
    {
        if (string.IsNullOrEmpty(path) || SHParseDisplayName(path, IntPtr.Zero, out var itemIdList, 0, out _) < 0 || itemIdList == IntPtr.Zero)
            return null;

        try
        {
            if (SHGetNameFromIDList(itemIdList, ShellDisplayNameNormal, out var name) < 0 || name == IntPtr.Zero)
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
        finally
        {
            Marshal.FreeCoTaskMem(itemIdList);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr itemIdList, uint attributesIn, out uint attributesOut);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetNameFromIDList(IntPtr itemIdList, uint sigdnName, out IntPtr name);
}

internal static class ShellIconProvider
{
    private const uint Icon = 0x00000100;
    private const uint SmallIcon = 0x00000001;
    private const uint SystemImageList = 0x00004000;
    private const uint Pidl = 0x00000008;
    private const uint OverlayIndex = 0x00000040;
    private const uint AddOverlays = 0x00000020;
    private const uint DrawTransparent = 0x00000001;
    private const int SmallShellImageList = 1;

    public static ShellIconSet? GetSmallIcons(string path)
    {
        var isTopPath = Pathview.IsTopPath(path);
        IntPtr itemIdList = IntPtr.Zero;
        if (isTopPath &&
            (SHParseDisplayName(path, IntPtr.Zero, out itemIdList, 0, out _) < 0 || itemIdList == IntPtr.Zero))
        {
            return null;
        }

        try
        {
            var baseInfo = new ShellFileInfo();
            var baseInfoResult = isTopPath
                ? SHGetFileInfo(itemIdList, 0, ref baseInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), SystemImageList | SmallIcon | Pidl)
                : SHGetFileInfo(path, 0, ref baseInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), SystemImageList | SmallIcon);
            if (baseInfoResult == IntPtr.Zero)
                return null;

            var overlayInfo = new ShellFileInfo();
            if (isTopPath)
                _ = SHGetFileInfo(itemIdList, 0, ref overlayInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | OverlayIndex | AddOverlays | Pidl);
            else
                _ = SHGetFileInfo(path, 0, ref overlayInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | OverlayIndex | AddOverlays);
            var overlaySlot = (int)(unchecked((uint)overlayInfo.IconIndex) >> 24);
            if (overlayInfo.IconHandle != IntPtr.Zero)
                _ = DestroyIcon(overlayInfo.IconHandle);

            IImageList? imageList = null;
            try
            {
                var interfaceId = typeof(IImageList).GUID;
                Marshal.ThrowExceptionForHR(SHGetImageList(SmallShellImageList, ref interfaceId, out imageList));
                var baseIcon = GetImage(imageList, baseInfo.IconIndex);
                ImageSource? overlayIcon = null;
                if (overlaySlot > 0 && imageList.GetOverlayImage(overlaySlot, out var overlayImageIndex) >= 0)
                    overlayIcon = GetImage(imageList, overlayImageIndex);

                return new ShellIconSet(baseIcon, overlayIcon, GetOpacity(path));
            }
            finally
            {
                if (imageList is not null && Marshal.IsComObject(imageList))
                    _ = Marshal.FinalReleaseComObject(imageList);
            }
        }
        finally
        {
            if (itemIdList != IntPtr.Zero)
                Marshal.FreeCoTaskMem(itemIdList);
        }
    }

    private static double GetOpacity(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.Hidden) != 0 ? 0.55 : 1;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return 1;
        }
    }

    private static ImageSource? GetImage(IImageList imageList, int imageIndex)
    {
        if (imageList.GetIcon(imageIndex, DrawTransparent, out var iconHandle) < 0)
            return null;
        if (iconHandle == IntPtr.Zero)
            return null;

        try
        {
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(iconHandle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(16, 16));
            bitmap.Freeze();
            return bitmap;
        }
        finally
        {
            _ = DestroyIcon(iconHandle);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);

    [DllImport("shell32.dll", EntryPoint = "SHGetFileInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SHGetFileInfo(IntPtr itemIdList, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr itemIdList, uint attributesIn, out uint attributesOut);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr iconHandle);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetImageList(int imageList, ref Guid interfaceId, out IImageList result);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public IntPtr IconHandle;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }
}

[ComImport]
[Guid("46EB5926-582E-4017-9FDF-E8998DAA0950")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IImageList
{
    [PreserveSig] int Add(IntPtr image, IntPtr mask, out int index);
    [PreserveSig] int ReplaceIcon(int index, IntPtr icon, out int newIndex);
    [PreserveSig] int SetOverlayImage(int imageIndex, int overlayIndex);
    [PreserveSig] int Replace(int index, IntPtr image, IntPtr mask);
    [PreserveSig] int AddMasked(IntPtr image, uint maskColor, out int index);
    [PreserveSig] int Draw(IntPtr drawParameters);
    [PreserveSig] int Remove(int index);
    [PreserveSig] int GetIcon(int index, uint flags, out IntPtr icon);
    [PreserveSig] int GetImageInfo(int index, IntPtr imageInfo);
    [PreserveSig] int Copy(int destinationIndex, IntPtr source, int sourceIndex, uint flags);
    [PreserveSig] int Merge(int firstIndex, IntPtr secondList, int secondIndex, int x, int y, ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int Clone(ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int GetImageRect(int index, IntPtr rectangle);
    [PreserveSig] int GetIconSize(out int width, out int height);
    [PreserveSig] int SetIconSize(int width, int height);
    [PreserveSig] int GetImageCount(out int count);
    [PreserveSig] int SetImageCount(uint count);
    [PreserveSig] int SetBkColor(uint color, out uint previousColor);
    [PreserveSig] int GetBkColor(out uint color);
    [PreserveSig] int BeginDrag(int trackIndex, int hotSpotX, int hotSpotY);
    [PreserveSig] int EndDrag();
    [PreserveSig] int DragEnter(IntPtr window, int x, int y);
    [PreserveSig] int DragLeave(IntPtr window);
    [PreserveSig] int DragMove(int x, int y);
    [PreserveSig] int SetDragCursorImage(IntPtr imageList, int dragIndex, int hotSpotX, int hotSpotY);
    [PreserveSig] int DragShowNoLock([MarshalAs(UnmanagedType.Bool)] bool show);
    [PreserveSig] int GetDragImage(IntPtr point, IntPtr hotSpot, ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int GetItemFlags(int index, out uint flags);
    [PreserveSig] int GetOverlayImage(int overlayIndex, out int imageIndex);
}