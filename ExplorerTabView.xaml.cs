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
using static SUTWinExplorer.ShellLocations;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

public partial class Pathview : UserControl
{
    public const double DirectoryTreeRowHeight = 24;

    public static readonly DependencyProperty PaneBackgroundProperty =
        DependencyProperty.Register(
            nameof(PaneBackground),
            typeof(Brush),
            typeof(Pathview),
            new FrameworkPropertyMetadata(new SolidColorBrush(Colors.White)));

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
    private string _historyCurrentPath = string.Empty;
    private readonly DispatcherTimer _fileSystemRefreshTimer;
    private bool _suppressTreeBringIntoView;
    private TreeEntry? _pendingTreeNavigationEntry;
    private TreeEntry? _editingTreeEntry;
    private bool _fileSystemStateDirty = true;
    private bool _contentViewNeedsRefresh = true;
    private readonly List<TreeEntry> _driveRoots = [];
    private readonly Action<string?>? _customNameChanged;
    private readonly Action<Color>? _tabColorChanged;
    private string? _customName;
    private Window? _inputWindow;
    private readonly SutContextMenuController<TreeEntry> _treeContextMenu;
    private readonly SutContextMenuController<TreeEntry> _subfolderContextMenu;
    private TreeEntry? _treeMenuTarget;
    private TreeEntry? _subfolderMenuTarget;

    public Pathview(string initialPath, bool isBrowsable, string? customName, Action<string?>? customNameChanged,
        Color? tabColor, Action<Color>? tabColorChanged)
    {
        InitializeComponent();
        _treeContextMenu = CreateDirectoryMenuController(ActivePathAndSiblingsTree, true);
        _subfolderContextMenu = CreateDirectoryMenuController(ActivePathSubfoldersList, false);
        ActivePathAndSiblingsTree.SelectedItemChanged += (_, args) =>
        {
            if (args.NewValue is not TreeEntry entry || _treeMenuTarget is null ||
                !string.Equals(entry.Path, _treeMenuTarget.Path, StringComparison.OrdinalIgnoreCase))
            {
                _treeContextMenu.Reset();
                _treeMenuTarget = args.NewValue as TreeEntry;
            }
        };
        _customName = customName;
        _customNameChanged = customNameChanged;
        _tabColorChanged = tabColorChanged;
        TabColor = tabColor;
        if (tabColor is Color color)
            PaneBackground = new SolidColorBrush(color);
        CustomNameEditor.Text = customName ?? string.Empty;
        var explorerPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        OpenInExplorerIcon.Source = ShellIconProvider.GetIconAtSize(explorerPath, 16, 16) ??
                                    ShellIconProvider.GetSmallIcons(explorerPath)?.BaseIcon;
        HideInternalSubfoldersCheckBox.GetCheckBox().Checked += HideInternalSubfoldersCheckBox_StateChanged;
        HideInternalSubfoldersCheckBox.GetCheckBox().Unchecked += HideInternalSubfoldersCheckBox_StateChanged;
        IsBrowsable = isBrowsable;
        ActivePathTab.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        ActivePathAndSiblingsTab.Visibility = IsBrowsable ? Visibility.Visible : Visibility.Collapsed;
        SidebarTabs.SelectedItem = IsBrowsable ? ActivePathAndSiblingsTab : ActivePathTab;
        FixedPathBadge.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
        CustomNameContainer.Visibility = IsBrowsable ? Visibility.Collapsed : Visibility.Visible;
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
        DirectoryContent.FolderOpenRequested += ContentView_FolderOpenRequested;
        DirectoryContent.FolderRenamed += (oldPath, newPath) => DirectoryRenamed?.Invoke(oldPath, newPath);
        DirectoryContent.FileSystemChanged += ContentView_FileSystemChanged;
        DirectoryContent.Initialize(IsBrowsable);
        InitializeActivePathAndSiblingsTree();
        Loaded += Pathview_Loaded;
        Unloaded += Pathview_Unloaded;
        IsVisibleChanged += Pathview_IsVisibleChanged;
        try
        {
            Navigate(initialPath, NavigationHistoryAction.None);
        }
        catch (Exception exception) when (!isBrowsable && exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    public bool IsBrowsable { get; }
    public Brush PaneBackground
    {
        get => (Brush)GetValue(PaneBackgroundProperty);
        set => SetValue(PaneBackgroundProperty, value);
    }

    public string CurrentPath { get; private set; } = string.Empty;
    internal string? CustomName => _customName;
    internal Color? TabColor { get; private set; }
    public event EventHandler<string>? LocationChanged;
    public event EventHandler? PinRequested;
    public event Action<Pathview, string, bool?, bool?, bool?, bool?>? BrowseLocationRequested;
    public event Action<string, string>? DirectoryRenamed;

    private void CustomNameEditor_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitCustomName();
            DirectoryContent.FocusContent();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            CustomNameEditor.Text = _customName ?? string.Empty;
            e.Handled = true;
        }
    }

    private void CustomNameEditor_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) =>
        CommitCustomName();

    private void InputWindow_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!CustomNameEditor.IsKeyboardFocusWithin || CustomNameEditor.IsMouseOver)
            return;

        CommitCustomName();
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            if (!CustomNameEditor.IsKeyboardFocusWithin)
                return;
            if (IsVisible)
                DirectoryContent.FocusContent();
            if (CustomNameEditor.IsKeyboardFocusWithin)
                Keyboard.ClearFocus();
        });
    }

    private void CommitCustomName()
    {
        var name = CustomNameEditor.Text.Length == 0 ? null : CustomNameEditor.Text;
        if (string.Equals(name, _customName, StringComparison.Ordinal))
            return;
        _customName = name;
        _customNameChanged?.Invoke(name);
    }

    /// <summary>Navigates this Pathview, optionally applying filter settings to the browsable view.</summary>
    /// <param name="path">The destination path.</param>
    /// <param name="hideSiblings">The browsable tree setting; null leaves its current value unchanged.</param>
    /// <param name="hideInternalDirectories">The browsable directory-tree filter; null leaves its current value unchanged.</param>
    /// <param name="hideInternalContentItems">The browsable content-item filter; null leaves its current value unchanged.</param>
    public void Navigate(
        string path,
        bool? hideSiblings = null,
        bool? hideInternalDirectories = null,
        bool? hideInternalContentItems = null) =>
        Navigate(path, NavigationHistoryAction.Normal, hideSiblings, hideInternalDirectories, hideInternalContentItems);

    internal string? BackHistoryPath => _backHistory.TryPeek(out var path) ? path : null;
    internal string? ForwardHistoryPath => _forwardHistory.TryPeek(out var path) ? path : null;

    internal void ActivateHistoryLocation(string path, bool isBack) =>
        UpdateHistory(path, isBack ? NavigationHistoryAction.Back : NavigationHistoryAction.Forward);

    internal void RecordVisitedLocation(string path)
    {
        if (!IsBrowsable || string.IsNullOrWhiteSpace(path) ||
            string.Equals(_historyCurrentPath, path, StringComparison.OrdinalIgnoreCase))
            return;

        UpdateHistory(path, NavigationHistoryAction.Normal);
    }

    internal void ApplyDirectoryRename(string oldPath, string newPath)
    {
        foreach (var drive in _driveRoots)
            drive.RefreshDisplayName();
        _fileSystemStateDirty = true;
        ScheduleFileSystemRefreshIfVisible();
        RemapHistory(_backHistory, oldPath, newPath);
        RemapHistory(_forwardHistory, oldPath, newPath);
        _historyCurrentPath = RemapPath(_historyCurrentPath, oldPath, newPath);
        var updatedPath = RemapPath(CurrentPath, oldPath, newPath);
        if (string.Equals(updatedPath, CurrentPath, StringComparison.Ordinal))
            return;

        if (string.Equals(updatedPath, CurrentPath, StringComparison.OrdinalIgnoreCase))
            CommitNavigation(updatedPath, NavigationHistoryAction.None);
        else
            Navigate(updatedPath, NavigationHistoryAction.None);
    }

    private static void RemapHistory(Stack<string> history, string oldPath, string newPath)
    {
        var paths = history.ToArray();
        history.Clear();
        for (var index = paths.Length - 1; index >= 0; index--)
            history.Push(RemapPath(paths[index], oldPath, newPath));
    }

    private static string RemapPath(string path, string oldPath, string newPath)
    {
        if (string.IsNullOrEmpty(path) || IsTopPath(path))
            return path;

        var relative = Path.GetRelativePath(oldPath, path);
        if (relative == ".")
            return newPath;
        if (Path.IsPathRooted(relative) || relative == ".." ||
            relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            return path;
        return Path.Combine(newPath, relative);
    }

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

    private void Navigate(
        string path,
        NavigationHistoryAction historyAction,
        bool? hideSiblings = null,
        bool? hideInternalDirectories = null,
        bool? hideInternalContentItems = null)
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

        if (!IsTopPath(fullPath) && !Directory.Exists(fullPath))
            throw new DirectoryNotFoundException($"The directory does not exist or is not accessible: {fullPath}");

        if (string.Equals(CurrentPath, fullPath, StringComparison.OrdinalIgnoreCase))
        {
            UpdateHistory(fullPath, historyAction);
            ApplyNavigationOptions(hideSiblings, hideInternalDirectories, hideInternalContentItems);
            return;
        }

        DirectoryContent.EnsureLocationAccessible(fullPath);
        CommitNavigation(fullPath, historyAction);
        ApplyNavigationOptions(hideSiblings, hideInternalDirectories, hideInternalContentItems);
        DirectoryContent.Refresh(true);
    }

    private void ApplyNavigationOptions(
        bool? hideSiblings,
        bool? hideInternalDirectories,
        bool? hideInternalContentItems)
    {
        if (!IsBrowsable)
            return;

        if (hideSiblings is { } hideSiblingsValue)
            HideSiblingsCheckBox.IsChecked = hideSiblingsValue;
        if (hideInternalDirectories is { } hideInternalDirectoriesValue)
            HideInternalCheckBox.IsChecked = hideInternalDirectoriesValue;
        if (hideInternalContentItems is { } hideInternalContentItemsValue)
            DirectoryContent.HideInternalItems = hideInternalContentItemsValue;
    }

    private void CommitNavigation(string path, NavigationHistoryAction historyAction)
    {
        _treeContextMenu.Reset();
        _subfolderContextMenu.Reset();
        _treeMenuTarget = null;
        _subfolderMenuTarget = null;
        if (_pendingTreeNavigationEntry is { } pendingEntry &&
            string.Equals(pendingEntry.Path, path, StringComparison.OrdinalIgnoreCase))
        {
            ClearPendingTreeNavigation();
        }

        UpdateHistory(path, historyAction);

        CurrentPath = path;
        DirectoryContent.SetCurrentPath(path);
        PinPathviewButton.IsEnabled = !IsTopPath(path);
        BrowsePathviewButton.IsEnabled = true;
        OpenInExplorerButton.IsEnabled = true;
        UpdateLocationIcon(path);
        LocationLabel.Text = ShellDisplayNameProvider.GetDisplayPath(path);
        RefreshActivePathAndSiblingsTree();
        RefreshActivePathTree();
        SynchronizeContentChangeNotifications();
        LocationChanged?.Invoke(this, CurrentPath);
    }

    private void UpdateHistory(string path, NavigationHistoryAction historyAction)
    {
        if (historyAction == NavigationHistoryAction.Normal &&
            string.Equals(_historyCurrentPath, path, StringComparison.OrdinalIgnoreCase))
            return;

        switch (historyAction)
        {
            case NavigationHistoryAction.Normal:
                if (!string.IsNullOrEmpty(_historyCurrentPath) &&
                    !string.Equals(_historyCurrentPath, path, StringComparison.OrdinalIgnoreCase))
                    _backHistory.Push(_historyCurrentPath);
                _forwardHistory.Clear();
                break;
            case NavigationHistoryAction.Back:
                if (_backHistory.Count > 0 && string.Equals(_backHistory.Peek(), path, StringComparison.OrdinalIgnoreCase))
                    _backHistory.Pop();
                if (!string.IsNullOrEmpty(_historyCurrentPath))
                    _forwardHistory.Push(_historyCurrentPath);
                break;
            case NavigationHistoryAction.Forward:
                if (_forwardHistory.Count > 0 && string.Equals(_forwardHistory.Peek(), path, StringComparison.OrdinalIgnoreCase))
                    _forwardHistory.Pop();
                if (!string.IsNullOrEmpty(_historyCurrentPath))
                    _backHistory.Push(_historyCurrentPath);
                break;
        }
        _historyCurrentPath = path;
    }

    private void PathviewActionButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        if (IsBrowsable)
            PinRequested?.Invoke(this, EventArgs.Empty);
        else
            RequestBrowseLocation(CurrentPath, preferFixedView: false);
    }

    private void PaneColorButton_Click(object sender, RoutedEventArgs e) =>
        PaneColorPopup.IsOpen = true;

    private void OpenInExplorerButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;

        try
        {
            var startInfo = new ProcessStartInfo("explorer.exe")
            {
                Arguments = $"/n, \"{CurrentPath}\"",
                UseShellExecute = true
            };
            Process.Start(startInfo);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open Windows Explorer", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void PaneColorSwatch_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SolidColorBrush selectedBrush })
            return;

        PaneBackground = selectedBrush;
        TabColor = selectedBrush.Color;
        _tabColorChanged?.Invoke(selectedBrush.Color);
        PaneColorPopup.IsOpen = false;
    }

    private void LocationHeaderPanel_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var fixedBadgeWidth = FixedPathBadge.Visibility == Visibility.Visible
            ? FixedPathBadge.ActualWidth + FixedPathBadge.Margin.Left + FixedPathBadge.Margin.Right
            : 0;
        var customNameWidth = CustomNameContainer.Visibility == Visibility.Visible
            ? CustomNameContainer.Width + CustomNameContainer.Margin.Left + CustomNameContainer.Margin.Right
            : 0;
        var locationIconWidth = LocationIconSlot.Visibility == Visibility.Visible
            ? LocationIconSlot.Width + LocationIconSlot.Margin.Left + LocationIconSlot.Margin.Right
            : 0;
        var actionButton = IsBrowsable ? PinPathviewButton : BrowsePathviewButton;
        var actionButtonWidth = actionButton.Visibility == Visibility.Visible
            ? actionButton.ActualWidth + actionButton.Margin.Left + actionButton.Margin.Right
            : 0;
        var titlePadding = LocationLabel.Padding.Left + LocationLabel.Padding.Right;
        LocationLabel.MaxWidth = Math.Max(0,
            LocationHeaderPanel.ActualWidth - fixedBadgeWidth - customNameWidth - locationIconWidth - actionButtonWidth - titlePadding);
    }

    private void UpdateLocationIcon(string path)
    {
        var icons = ShellIconProvider.GetSmallIcons(path);
        var dpi = VisualTreeHelper.GetDpi(LocationIconSlot);
        var iconWidth = Math.Max(1, (int)Math.Round(LocationIconSlot.Width * dpi.DpiScaleX));
        var iconHeight = Math.Max(1, (int)Math.Round(LocationIconSlot.Height * dpi.DpiScaleY));
        LocationBaseIcon.Source = ShellIconProvider.GetIconAtSize(path, iconWidth, iconHeight) ?? icons?.BaseIcon;
        LocationOverlayIcon.Source = icons?.OverlayIcon;
        LocationIconSlot.Opacity = icons?.Opacity ?? 1;
    }

    private void Pathview_Loaded(object sender, RoutedEventArgs e)
    {
        _inputWindow = Window.GetWindow(this);
        _inputWindow?.AddHandler(Mouse.PreviewMouseDownEvent, new MouseButtonEventHandler(InputWindow_PreviewMouseDown), true);
        _fileSystemStateDirty = true;
        _contentViewNeedsRefresh = true;
        SynchronizeContentChangeNotifications();
        ScheduleFileSystemRefreshIfVisible();
    }

    private void Pathview_Unloaded(object sender, RoutedEventArgs e)
    {
        _inputWindow?.RemoveHandler(Mouse.PreviewMouseDownEvent, new MouseButtonEventHandler(InputWindow_PreviewMouseDown));
        _inputWindow = null;
        _fileSystemRefreshTimer.Stop();
        _fileSystemStateDirty = true;
        _contentViewNeedsRefresh = true;
        DirectoryContent.ClearObservedDirectories();
    }

    private void Pathview_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible)
        {
            _fileSystemStateDirty = true;
            _contentViewNeedsRefresh = true;
            SynchronizeContentChangeNotifications();
            ScheduleFileSystemRefreshIfVisible();
            if (!IsBrowsable)
                Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
                {
                    if (IsVisible)
                        DirectoryContent.FocusContent();
                });
        }
    }

    private void RefreshCurrentFileSystemState(bool refreshContentView)
    {
        DirectoryContent.Refresh(refreshContentView);
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
        if (ActivePathAndSiblingsTree?.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        foreach (var root in roots)
            RefreshLoadedTree(root);
    }

    private void HideSiblingsCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (ActivePathAndSiblingsTree?.ItemsSource is not ObservableCollection<TreeEntry> roots)
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

    private void SynchronizeContentChangeNotifications()
    {
        if (!IsLoaded)
            return;

        var desiredPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddCurrentPathNotificationPaths(desiredPaths);

        DirectoryContent.SetObservedDirectories(desiredPaths);
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

    private void ContentView_FileSystemChanged(object? sender, EventArgs e)
    {
        _fileSystemStateDirty = true;
        _contentViewNeedsRefresh = false;
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
        if (!IsLoaded || !IsVisible || _editingTreeEntry is not null)
            return;

        var refreshContentView = _contentViewNeedsRefresh;
        _fileSystemStateDirty = false;
        _contentViewNeedsRefresh = false;
        RefreshCurrentFileSystemState(refreshContentView);
        SynchronizeContentChangeNotifications();
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
                SynchronizeContentChangeNotifications();
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

    private SutContextMenuController<TreeEntry> CreateDirectoryMenuController(ItemsControl control, bool tree)
    {
        return new SutContextMenuController<TreeEntry>(entry => entry.Path,
            () => (tree ? _treeMenuTarget : _subfolderMenuTarget) is { } target ? [target.Path] : [],
            (screenX, screenY) =>
            {
                var source = control.InputHitTest(control.PointFromScreen(new Point(screenX, screenY))) as DependencyObject;
                var entry = tree ? FindAncestor<TreeViewItem>(source)?.DataContext as TreeEntry :
                    FindAncestor<ListViewItem>(source)?.DataContext as TreeEntry;
                return (entry is { IsPlaceholder: false } ? entry : null,
                    !tree && source is not null && !IsListChrome(source));
            },
            entry => SelectDirectoryMenuTarget(entry, tree),
            CreateDirectoryMenuActions,
            (entry, _) => ShowNativeMenu(this, entry.Path, !entry.IsTop ? () => BeginTreeRename(entry) : null),
            () => { if (!tree) ShowNativeBackgroundMenu(this, CurrentPath); },
            () => CurrentPath, CreateBackgroundMenuActions,
            DirectoryContent.ShowNewItemDialog);
    }

    private void SelectDirectoryMenuTarget(TreeEntry? entry, bool tree)
    {
        var previous = tree ? _treeMenuTarget : _subfolderMenuTarget;
        if (previous is null || entry is null || !string.Equals(previous.Path, entry.Path, StringComparison.OrdinalIgnoreCase))
            (tree ? _treeContextMenu : _subfolderContextMenu).Reset();
        if (tree)
        {
            _treeMenuTarget = entry;
            if (entry is not null) entry.IsSelected = true;
        }
        else
        {
            _subfolderMenuTarget = entry;
            ActivePathSubfoldersList.SelectedItem = entry;
        }
    }

    private IReadOnlyList<ShellMenuAction> CreateDirectoryMenuActions(TreeEntry entry)
    {
        var copyPrepared = CopyWorkflowState.Shared.IsPrepared;
        var movePrepared = MoveWorkflowState.Shared.IsPrepared;
        var canStart = !copyPrepared && !movePrepared;
        var actions = new (string Name, bool Enabled)[]
        {
            ("Rename", !entry.IsTop && Directory.Exists(entry.Path)),
            ("PathGet", Directory.Exists(entry.Path)),
            ("CopyGet", canStart), ("CopyAbort", copyPrepared), ("CopyPaste", copyPrepared),
            ("MoveGet", canStart), ("MoveAbort", movePrepared), ("MovePaste", movePrepared),
            ("Delete", canStart && ShellFileOperations.CanDelete(entry.Path))
        };
        return actions.Select(action => new ShellMenuAction(
            action.Name,
            System.Windows.Automation.AutomationProperties.GetName((Button)DirectoryContent.FindName(action.Name + "Button")),
            action.Enabled, () => ExecuteDirectoryMenuAction(action.Name, entry),
            IsTransfer: action.Name.StartsWith("Copy", StringComparison.Ordinal) || action.Name.StartsWith("Move", StringComparison.Ordinal),
            SeparatorBefore: action.Name is "PathGet" or "Delete")).ToArray();
    }

    private IReadOnlyList<ShellMenuAction> CreateBackgroundMenuActions()
    {
        var copyPrepared = CopyWorkflowState.Shared.IsPrepared;
        var movePrepared = MoveWorkflowState.Shared.IsPrepared;
        var actions = new (string Name, bool Enabled)[]
        {
            ("Rename", false), ("PathGet", false), ("CopyGet", false),
            ("CopyAbort", copyPrepared), ("CopyPaste", copyPrepared), ("MoveGet", false),
            ("MoveAbort", movePrepared), ("MovePaste", movePrepared), ("Delete", false)
        };
        return actions.Select(action => new ShellMenuAction(
            action.Name,
            System.Windows.Automation.AutomationProperties.GetName((Button)DirectoryContent.FindName(action.Name + "Button")),
            action.Enabled, () => ExecuteDirectoryMenuAction(action.Name, null),
            IsTransfer: action.Name.StartsWith("Copy", StringComparison.Ordinal) || action.Name.StartsWith("Move", StringComparison.Ordinal),
            SeparatorBefore: action.Name is "PathGet" or "Delete")).ToArray();
    }

    private void ExecuteDirectoryMenuAction(string action, TreeEntry? entry)
    {
        try
        {
            var owner = new WindowInteropHelper(Window.GetWindow(this)!).Handle;
            switch (action)
            {
                case "Rename": BeginTreeRename(entry!); break;
                case "PathGet": Clipboard.SetText(entry!.Path); break;
                case "CopyGet":
                    if (MoveWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Move before starting a Copy.");
                    CopyWorkflowState.Shared.Prepare([entry!.Path]);
                    break;
                case "CopyAbort": CopyWorkflowState.Shared.Abort(); break;
                case "CopyPaste":
                    var copied = new List<string>();
                    try
                    {
                        SutShell.Copy(CopyWorkflowState.Shared.PreparedPaths, CurrentPath, owner, copied);
                        CopyWorkflowState.Shared.CompletePaste();
                    }
                    finally
                    {
                        DirectoryContent.RevealInsertedItems(copied);
                        RefreshActivePathTree();
                        RefreshCurrentRouteTree();
                    }
                    break;
                case "MoveGet":
                    if (CopyWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Copy before starting a Move.");
                    MoveWorkflowState.Shared.Prepare([entry!.Path]);
                    break;
                case "MoveAbort": MoveWorkflowState.Shared.Abort(); break;
                case "MovePaste":
                    var moved = new List<string>();
                    try
                    {
                        SutShell.Move(MoveWorkflowState.Shared.PreparedPaths, CurrentPath, owner, moved);
                        MoveWorkflowState.Shared.CompletePaste();
                    }
                    finally
                    {
                        DirectoryContent.RevealInsertedItems(moved);
                        RefreshActivePathTree();
                        RefreshCurrentRouteTree();
                    }
                    break;
                case "Delete":
                    try { SutShell.Delete([entry!.Path], owner); }
                    finally { RefreshCurrentFileSystemState(true); }
                    break;
            }
        }
        catch (OperationCanceledException) when (action == "Delete") { }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Operation failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ShowDirectoryMenu(TreeEntry entry, bool tree, bool alternate)
    {
        try
        {
            SelectDirectoryMenuTarget(entry, tree);
            (tree ? _treeContextMenu : _subfolderContextMenu).Show(entry,
                new WindowInteropHelper(Window.GetWindow(this)!).Handle, alternate);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
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
            ShowSubfolderMenu(entry, alternate: true);
            e.Handled = true;
            return;
        }

        if (IsListChrome(source))
            return;

        try
        {
            ActivePathSubfoldersList.SelectedItem = null;
            if (_subfolderMenuTarget is not null) SelectDirectoryMenuTarget(null, tree: false);
            _subfolderContextMenu.Show(null, new WindowInteropHelper(Window.GetWindow(this)!).Handle, alternate: true);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        e.Handled = true;
    }

    private void ActivePathSubfoldersList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key != Key.Apps && !(key == Key.F10 && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            return;

        if (ActivePathSubfoldersList.SelectedItem is TreeEntry entry && !entry.IsPlaceholder)
            ShowSubfolderMenu(entry, alternate: false);
        else
            ShowNativeBackgroundMenu(this, CurrentPath);

        e.Handled = true;
    }

    private void ShowSubfolderMenu(TreeEntry entry, bool alternate)
    {
        try
        {
            ShowDirectoryMenu(entry, tree: false, alternate);
        }
        finally
        {
            ActivePathSubfoldersList.SelectedItem = null;
        }
    }

    private void ActivePathSubfoldersList_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<TextBox>(e.OriginalSource as DependencyObject) is not null)
            return;

        if (FindAncestor<ListViewItem>(e.OriginalSource as DependencyObject) is
            { DataContext: TreeEntry { IsPlaceholder: false } entry })
        {
            _subfolderContextMenu.Reset();
            _subfolderMenuTarget = null;
            RequestBrowseLocation(entry.Path);
        }
    }

    private void Tree_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not TreeView || FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } || entry.IsPlaceholder)
            return;

        if (ReferenceEquals(sender, ActivePathAndSiblingsTree))
            ShowDirectoryMenu(entry, tree: true, alternate: true);
        else
        {
            entry.IsSelected = true;
            ShowNativeMenu(this, entry.Path, !entry.IsTop ? () => BeginTreeRename(entry) : null);
        }
        e.Handled = true;
    }

    private void Tree_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<TextBox>(e.OriginalSource as DependencyObject) is not null)
            return;

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
        if (FindAncestor<TextBox>(e.OriginalSource as DependencyObject) is not null)
            return;

        if (!IsBrowsable && ReferenceEquals(sender, ActivePathTree))
        {
            if (FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is
                { DataContext: TreeEntry { IsPlaceholder: false } fixedEntry })
                RequestBrowseLocation(fixedEntry.Path);
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
            RequestBrowseLocation(entry.Path);
        }
    }

    private void ContentView_FolderOpenRequested(object? sender, string path)
    {
        if (IsBrowsable)
            Navigate(path);
        else
            RequestBrowseLocation(path);
    }

    private void RequestBrowseLocation(string path, bool? preferFixedView = null) =>
        BrowseLocationRequested?.Invoke(
            this,
            path,
            true,
            HideInternalSubfoldersCheckBox.GetCheckBox().IsChecked,
            DirectoryContent.HideInternalItems,
            preferFixedView);

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

    private void BeginTreeRename(TreeEntry entry)
    {
        if (_editingTreeEntry is not null)
            EndTreeRename(commit: false);

        var editName = GetTreeEditName(entry.Path);
        _editingTreeEntry = entry;
        entry.EditName = editName;
        entry.IsEditing = true;
    }

    private static string GetTreeEditName(string path)
    {
        var root = Path.GetPathRoot(path);
        return root is not null && string.Equals(Path.TrimEndingDirectorySeparator(path),
            Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase)
            ? new DriveInfo(root).VolumeLabel
            : Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
    }

    private void TreeNameEditor_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is TextBox { IsVisible: true } editor)
        {
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
            {
                if (editor.IsVisible)
                {
                    editor.Focus();
                    editor.SelectAll();
                }
            }));
        }
    }

    private void TreeNameEditor_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter || e.Key == Key.Escape)
        {
            EndTreeRename(commit: e.Key == Key.Enter);
            e.Handled = true;
        }
    }

    private void TreeNameEditor_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (sender is TextBox { DataContext: TreeEntry entry } && ReferenceEquals(entry, _editingTreeEntry))
            EndTreeRename(commit: true);
    }

    private void EndTreeRename(bool commit)
    {
        if (_editingTreeEntry is not { } entry)
            return;

        _editingTreeEntry = null;
        entry.IsEditing = false;
        try
        {
            if (commit && !string.Equals(entry.EditName, GetTreeEditName(entry.Path), StringComparison.Ordinal))
            {
                if (string.IsNullOrWhiteSpace(entry.EditName) || entry.EditName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    entry.EditName is "." or "..")
                    throw new ArgumentException("Enter a valid folder name.");

                var owner = new WindowInteropHelper(Window.GetWindow(this)!).Handle;
                var newPath = ShellItemOperations.Rename(entry.Path, entry.EditName, owner);
                DirectoryRenamed?.Invoke(entry.Path, newPath);
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot rename folder", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _fileSystemStateDirty = true;
            ScheduleFileSystemRefreshIfVisible();
        }
    }

}

public sealed class TreeEntry : INotifyPropertyChanged
{
    private bool _isExpanded;
    private bool _isSelected;
    private bool _isNavigationPending;
    private bool _hasSubdirectories;
    private bool _isEditing;
    private string _editName = string.Empty;

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
    public bool IsEditing
    {
        get => _isEditing;
        set => SetField(ref _isEditing, value);
    }
    public string EditName
    {
        get => _editName;
        set
        {
            if (_editName == value)
                return;
            _editName = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EditName)));
        }
    }
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
    public static TreeEntry Top() => new(string.Empty, ShellLocations.TopPath, false, true);

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

public sealed record ShellIconSet(ImageSource? BaseIcon, ImageSource? OverlayIcon, double Opacity)
{
    internal int BaseIconIndex { get; init; }
    internal int OverlaySlot { get; init; }
}

internal static class ShellDisplayNameProvider
{
    private const uint ShellDisplayNameNormal = 0;
    private const uint ShellFileInfoDisplayName = 0x00000200;

    public static string GetDisplayPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return path;

        if (ShellLocations.IsTopPath(path))
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
        if (ShellLocations.IsTopPath(expandedInput) ||
            string.Equals(expandedInput, GetDisplayName(ShellLocations.TopPath), StringComparison.OrdinalIgnoreCase) ||
            string.Equals(expandedInput, "This PC", StringComparison.OrdinalIgnoreCase))
        {
            return ShellLocations.TopPath;
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
        var displayName = GetShellDisplayName(path);
        if (displayName is not null && displayName.StartsWith("::{", StringComparison.Ordinal) &&
            Guid.TryParse(displayName.AsSpan(2), out _))
        {
            if (Path.IsPathFullyQualified(path))
            {
                var fileInfo = new ShellFileInfo();
                if (SHGetFileInfo(path, 0, ref fileInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), ShellFileInfoDisplayName) != IntPtr.Zero &&
                    !string.IsNullOrEmpty(fileInfo.DisplayName))
                    return fileInfo.DisplayName;
            }

            return GetShellDisplayName(displayName) ?? displayName;
        }

        return displayName;
    }

    private static string? GetShellDisplayName(string path)
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

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);
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
    private const uint ShellItemImageIconOnly = 0x00000004;
    private const uint UseFileAttributes = 0x00000010;
    private const int SmallShellImageList = 1;

    public static ImageSource? GetTypeIcon(string extension, bool directory)
    {
        var info = new ShellFileInfo();
        var attributes = directory ? 0x10u : 0x80u;
        var path = directory ? "folder" : "file" + extension;
        if (SHGetFileInfo(path, attributes, ref info, (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | UseFileAttributes) == IntPtr.Zero ||
            info.IconHandle == IntPtr.Zero)
            return null;
        try
        {
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(info.IconHandle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(16, 16));
            bitmap.Freeze();
            return bitmap;
        }
        finally
        {
            _ = DestroyIcon(info.IconHandle);
        }
    }

    public static ImageSource? GetIconAtSize(string path, int width, int height)
    {
        IShellItemImageFactory? imageFactory = null;
        IntPtr bitmapHandle = IntPtr.Zero;
        try
        {
            var interfaceId = typeof(IShellItemImageFactory).GUID;
            if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref interfaceId, out imageFactory) < 0 || imageFactory is null)
                return null;

            if (imageFactory.GetImage(new ShellImageSize(width, height), ShellItemImageIconOnly, out bitmapHandle) < 0 ||
                bitmapHandle == IntPtr.Zero)
                return null;

            var bitmap = Imaging.CreateBitmapSourceFromHBitmap(
                bitmapHandle,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            bitmap.Freeze();
            return bitmap;
        }
        catch (ExternalException)
        {
            return null;
        }
        finally
        {
            if (bitmapHandle != IntPtr.Zero)
                _ = DeleteObject(bitmapHandle);
            if (imageFactory is not null && Marshal.IsComObject(imageFactory))
                _ = Marshal.FinalReleaseComObject(imageFactory);
        }
    }

    public static ShellIconSet? GetSmallIcons(string path)
    {
        var isTopPath = ShellLocations.IsTopPath(path);
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

            var interfaceId = typeof(IImageList).GUID;
            Marshal.ThrowExceptionForHR(SHGetImageList(SmallShellImageList, ref interfaceId, out var imageList));
            try
            {
                var baseIcon = GetImage(imageList, baseInfo.IconIndex);
                ImageSource? overlayIcon = null;
                if (overlaySlot > 0 && GetImageListMethod<GetOverlayImageDelegate>(imageList, 31)(imageList, overlaySlot, out var overlayImageIndex) >= 0)
                    overlayIcon = GetImage(imageList, overlayImageIndex);

                return new ShellIconSet(baseIcon, overlayIcon, GetOpacity(path))
                {
                    BaseIconIndex = baseInfo.IconIndex,
                    OverlaySlot = overlaySlot
                };
            }
            finally
            {
                _ = Marshal.Release(imageList);
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

    private static T GetImageListMethod<T>(IntPtr imageList, int index) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(imageList), index * IntPtr.Size));

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetImageListIconDelegate(IntPtr imageList, int index, uint flags, out IntPtr icon);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetOverlayImageDelegate(IntPtr imageList, int overlayIndex, out int imageIndex);

    private static ImageSource? GetImage(IntPtr imageList, int imageIndex)
    {
        if (GetImageListMethod<GetImageListIconDelegate>(imageList, 10)(imageList, imageIndex, DrawTransparent, out var iconHandle) < 0)
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

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(
        string path,
        IntPtr bindContext,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory? imageFactory);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr iconHandle);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool DeleteObject(IntPtr handle);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetImageList(int imageList, ref Guid interfaceId, out IntPtr result);

}

[StructLayout(LayoutKind.Sequential)]
internal readonly struct ShellImageSize(int cx, int cy)
{
    public readonly int Cx = cx;
    public readonly int Cy = cy;
}

[ComImport]
[Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellItemImageFactory
{
    [PreserveSig] int GetImage(ShellImageSize size, uint flags, out IntPtr bitmap);
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct ShellFileInfo
{
    public IntPtr IconHandle;
    public int IconIndex;
    public uint Attributes;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
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