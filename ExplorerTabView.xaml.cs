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

public partial class ExplorerTabView : UserControl
{
    // Set true to reactivate the retained WPF ListView; false selects the Shell-hosted production view.
    private const bool UseLegacyWpfFileList = false;
    private static bool IsLegacyWpfFileList => UseLegacyWpfFileList;

    private enum TreeNavigationMode
    {
        DoubleClick,
        SingleClick
    }

    private const TreeNavigationMode ActiveTreeNavigationMode = TreeNavigationMode.SingleClick;
    private readonly Stack<string> _backHistory = new();
    private readonly Stack<string> _forwardHistory = new();
    private readonly DispatcherTimer _fileSystemRefreshTimer;
    private ShellExplorerBrowserHost? _shellBrowserHost;
    private bool _fileSystemStateDirty = true;
    private bool _shellViewNeedsRefresh = true;

    public ExplorerTabView(string initialPath)
    {
        InitializeComponent();
        _fileSystemRefreshTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(200)
        };
        _fileSystemRefreshTimer.Tick += FileSystemRefreshTimer_Tick;
        Loaded += ExplorerTabView_Loaded;
        Unloaded += ExplorerTabView_Unloaded;
        IsVisibleChanged += ExplorerTabView_IsVisibleChanged;
        FileList.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        ShellBrowserSlot.Visibility = IsLegacyWpfFileList ? Visibility.Collapsed : Visibility.Visible;
        StatusLabel.Visibility = IsLegacyWpfFileList ? Visibility.Visible : Visibility.Collapsed;
        InitializeActivePathAndSiblingsTree();
        if (!IsLegacyWpfFileList)
        {
            _shellBrowserHost = new ShellExplorerBrowserHost();
            _shellBrowserHost.NavigationCompleted += ShellBrowserHost_NavigationCompleted;
            _shellBrowserHost.FileSystemChanged += ShellBrowserHost_FileSystemChanged;
            _shellBrowserHost.SetShowDirectories(ShowDirectoriesCheckBox.IsChecked == true);
            ShellBrowserSlot.Content = _shellBrowserHost;
        }
        Navigate(initialPath, recordHistory: false);
    }

    public string CurrentPath { get; private set; } = string.Empty;
    public event EventHandler<string>? LocationChanged;

    public void Navigate(string path) => Navigate(path, recordHistory: true);

    public void GoBack()
    {
        if (_backHistory.Count == 0)
            return;

        _forwardHistory.Push(CurrentPath);
        Navigate(_backHistory.Pop(), recordHistory: false);
    }

    public void GoForward()
    {
        if (_forwardHistory.Count == 0)
            return;

        _backHistory.Push(CurrentPath);
        Navigate(_forwardHistory.Pop(), recordHistory: false);
    }

    public void GoUp()
    {
        var parent = Directory.GetParent(CurrentPath)?.FullName;
        if (parent is not null)
            Navigate(parent);
    }

    private void Navigate(string path, bool recordHistory)
    {
        var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')));
        if (!Directory.Exists(fullPath))
            throw new DirectoryNotFoundException($"The directory does not exist or is not accessible: {fullPath}");

        if (recordHistory && !string.Equals(CurrentPath, fullPath, StringComparison.OrdinalIgnoreCase))
        {
            if (!string.IsNullOrEmpty(CurrentPath))
                _backHistory.Push(CurrentPath);
            _forwardHistory.Clear();
        }

        CurrentPath = fullPath;
        LocationLabel.Text = fullPath;
        if (IsLegacyWpfFileList)
        {
            RefreshFiles();
        }
        else
        {
            _shellBrowserHost?.NavigateTo(fullPath);
            RefreshShellStatusCount();
        }
        RefreshActivePathAndSiblingsTree();
        RefreshActivePathTree();
        SynchronizeShellChangeNotifications();
        LocationChanged?.Invoke(this, CurrentPath);
    }

    private void RefreshFiles()
    {
        var entries = new List<FileEntry>();
        var showDirectories = ShowDirectoriesCheckBox.IsChecked == true;
        try
        {
            if (showDirectories)
            {
                foreach (var directory in Directory.EnumerateDirectories(CurrentPath))
                {
                    try
                    {
                        var info = new DirectoryInfo(directory);
                        entries.Add(new FileEntry(info.Name, directory, true, "Folder", "", info.LastWriteTime));
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
                    if ((info.Attributes & FileAttributes.Directory) != 0)
                    {
                        if (showDirectories)
                            entries.Add(new FileEntry(info.Name, file, true, "Folder", "", info.LastWriteTime));
                        continue;
                    }

                    entries.Add(new FileEntry(info.Name, file, false, info.Extension, FormatSize(info.Length), info.LastWriteTime));
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

    private void ShowDirectoriesCheckBox_StateChanged(object sender, RoutedEventArgs e)
    {
        if (IsLegacyWpfFileList)
        {
            RefreshFiles();
            return;
        }

        _shellBrowserHost?.SetShowDirectories(ShowDirectoriesCheckBox.IsChecked == true);
        RefreshShellStatusCount();
    }

    private void ShellBrowserSlot_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var dpi = VisualTreeHelper.GetDpi(ShellBrowserSlot);
        _shellBrowserHost?.SetViewSize(
            (int)Math.Round(e.NewSize.Width * dpi.DpiScaleX),
            (int)Math.Round(e.NewSize.Height * dpi.DpiScaleY));
    }

    private void ExplorerTabView_Loaded(object sender, RoutedEventArgs e)
    {
        _fileSystemStateDirty = true;
        _shellViewNeedsRefresh = true;
        SynchronizeShellChangeNotifications();
        ScheduleFileSystemRefreshIfVisible();
    }

    private void ExplorerTabView_Unloaded(object sender, RoutedEventArgs e)
    {
        _fileSystemRefreshTimer.Stop();
        _fileSystemStateDirty = true;
        _shellViewNeedsRefresh = true;
        _shellBrowserHost?.ClearChangeNotifications();
    }

    private void ExplorerTabView_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
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
        if (ActivePathAndSiblingsTree.ItemsSource is ObservableCollection<TreeEntry> roots)
        {
            foreach (var root in roots)
                RefreshLoadedTreeChildren(root);
        }
    }

    private void SynchronizeShellChangeNotifications()
    {
        if (!IsLoaded)
            return;

        var desiredPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddNotificationPath(desiredPaths, CurrentPath);
        if (ActivePathAndSiblingsTree.ItemsSource is ObservableCollection<TreeEntry> roots)
        {
            foreach (var root in roots)
                AddLoadedTreeNotificationPaths(root, desiredPaths);
        }

        _shellBrowserHost?.SynchronizeChangeNotifications(desiredPaths);
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

    private static void AddLoadedTreeNotificationPaths(TreeEntry entry, HashSet<string> paths)
    {
        if (entry.IsPlaceholder)
            return;

        if (entry.IsLoaded)
            AddNotificationPath(paths, entry.Path);

        foreach (var child in entry.Children)
            AddLoadedTreeNotificationPaths(child, paths);
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

    private static void RefreshLoadedTreeChildren(TreeEntry entry)
    {
        if (entry.IsPlaceholder)
            return;

        entry.RefreshIcons();
        if (entry.IsLoaded)
            RefreshTreeChildren(entry);

        foreach (var child in entry.Children)
            RefreshLoadedTreeChildren(child);
    }

    private void RefreshShellStatusCount()
    {
        try
        {
            var count = Directory.EnumerateFiles(CurrentPath)
                .Count(path => (File.GetAttributes(path) & FileAttributes.Directory) == 0);
            if (ShowDirectoriesCheckBox.IsChecked == true)
                count += Directory.EnumerateDirectories(CurrentPath).Count();
            StatusLabel.Text = $"{count} items";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            StatusLabel.Text = exception.Message;
        }
    }

    private void ShellBrowserHost_NavigationCompleted(object? sender, string path)
    {
        if (!Directory.Exists(path))
            return;

        var fullPath = Path.GetFullPath(path);
        if (string.Equals(CurrentPath, fullPath, StringComparison.OrdinalIgnoreCase))
            return;

        if (!string.IsNullOrEmpty(CurrentPath))
            _backHistory.Push(CurrentPath);
        _forwardHistory.Clear();
        CurrentPath = fullPath;
        LocationLabel.Text = fullPath;
        RefreshActivePathAndSiblingsTree();
        RefreshActivePathTree();
        SynchronizeShellChangeNotifications();
        RefreshShellStatusCount();
        LocationChanged?.Invoke(this, CurrentPath);
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
        var drives = new ObservableCollection<TreeEntry>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            var root = new TreeEntry(drive.Name, drive.RootDirectory.FullName);
            AddPlaceholder(root);
            drives.Add(root);
        }

        ActivePathAndSiblingsTree.ItemsSource = drives;
    }

    private void RefreshActivePathTree()
    {
        var rootPath = Path.GetPathRoot(CurrentPath);
        if (string.IsNullOrEmpty(rootPath))
            return;

        var root = new TreeEntry(rootPath, rootPath);
        root.IsLoaded = true;
        var segments = Path.GetRelativePath(rootPath, CurrentPath)
            .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
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

        parent.IsSelected = true;
        ActivePathTree.ItemsSource = new[] { root };
    }

    private void RefreshActivePathAndSiblingsTree()
    {
        if (ActivePathAndSiblingsTree.ItemsSource is not ObservableCollection<TreeEntry> roots)
            return;

        foreach (var root in roots)
            CollapseLoadedNodes(root);

        var rootPath = Path.GetPathRoot(CurrentPath);
        var active = roots.FirstOrDefault(root => string.Equals(root.Path, rootPath, StringComparison.OrdinalIgnoreCase));
        if (active is null)
            return;

        var segments = Path.GetRelativePath(rootPath!, CurrentPath)
            .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);

        foreach (var segment in segments)
        {
            LoadChildren(active);
            active.IsExpanded = true;
            var childPath = Path.Combine(active.Path, segment);
            var child = active.Children.FirstOrDefault(candidate =>
                !candidate.IsPlaceholder && string.Equals(candidate.Path, childPath, StringComparison.OrdinalIgnoreCase));
            if (child is null)
                return;
            active = child;
        }

        LoadChildren(active);
        active.IsExpanded = true;
        active.IsSelected = true;
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

    private static void LoadChildren(TreeEntry entry)
    {
        if (entry.IsLoaded || entry.IsPlaceholder)
            return;

        RefreshTreeChildren(entry);
    }

    private static void RefreshTreeChildren(TreeEntry entry)
    {
        if (entry.IsPlaceholder)
            return;

        try
        {
            var directories = Directory.EnumerateDirectories(entry.Path)
                .OrderBy(path => path, StringComparer.CurrentCultureIgnoreCase)
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

                refreshedChildren.Add(child);
            }

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

    private static void AddPlaceholder(TreeEntry entry) => entry.Children.Add(TreeEntry.Placeholder());

    private void FileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FileList.SelectedItem is not FileEntry entry)
            return;

        try
        {
            if (entry.IsDirectory)
                Navigate(entry.FullPath);
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

    private void Tree_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (ActiveTreeNavigationMode != TreeNavigationMode.SingleClick ||
            FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } item ||
            entry.IsPlaceholder)
        {
            return;
        }

        if (FindAncestor<ToggleButton>(e.OriginalSource as DependencyObject) is not null)
        {
            if (ReferenceEquals(sender, ActivePathTree))
            {
                item.IsSelected = true;
                item.IsExpanded = true;
                e.Handled = true;
            }
            QueueTreeNavigation(entry);
            return;
        }

        // Clicking a folder name selects and expands it; expansion shows its contents in the right pane.
        item.IsSelected = true;
        item.IsExpanded = true;
        QueueTreeNavigation(entry);
    }

    private void Tree_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ActiveTreeNavigationMode == TreeNavigationMode.DoubleClick &&
            sender is TreeView tree && tree.SelectedItem is TreeEntry { IsPlaceholder: false } entry)
        {
            NavigateFromTree(entry);
        }
    }

    private void NavigateFromTree(TreeEntry entry)
    {
        try
        {
            Navigate(entry.Path);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open folder", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void QueueTreeNavigation(TreeEntry entry)
    {
        if (string.Equals(CurrentPath, entry.Path, StringComparison.OrdinalIgnoreCase))
            return;

        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => NavigateFromTree(entry)));
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

    private TreeEntry(string name, string path, bool isPlaceholder)
    {
        Name = name;
        Path = path;
        IsPlaceholder = isPlaceholder;
        IsLoaded = isPlaceholder;
        Icons = isPlaceholder ? null : ShellIconProvider.GetSmallIcons(path);
    }

    public TreeEntry(string name, string path) : this(name, path, false) { }

    public string Name { get; }
    public string Path { get; }
    public bool IsPlaceholder { get; }
    public bool IsLoaded { get; set; }
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
    public ShellIconSet? Icons { get; private set; }
    public ObservableCollection<TreeEntry> Children { get; } = new();
    public event PropertyChangedEventHandler? PropertyChanged;

    public static TreeEntry Placeholder() => new("Loading", string.Empty, true);

    public void RefreshIcons()
    {
        if (IsPlaceholder)
            return;

        Icons = ShellIconProvider.GetSmallIcons(Path);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Icons)));
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

public sealed record ShellIconSet(ImageSource? BaseIcon, ImageSource? OverlayIcon);

internal static class ShellIconProvider
{
    private const uint Icon = 0x00000100;
    private const uint SmallIcon = 0x00000001;
    private const uint SystemImageList = 0x00004000;
    private const uint OverlayIndex = 0x00000040;
    private const uint AddOverlays = 0x00000020;
    private const uint DrawTransparent = 0x00000001;
    private const int SmallShellImageList = 1;

    public static ShellIconSet? GetSmallIcons(string path)
    {
        var baseInfo = new ShellFileInfo();
        if (SHGetFileInfo(path, 0, ref baseInfo, (uint)Marshal.SizeOf<ShellFileInfo>(), SystemImageList | SmallIcon) == IntPtr.Zero)
            return null;

        var overlayInfo = new ShellFileInfo();
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

            return new ShellIconSet(baseIcon, overlayIcon);
        }
        finally
        {
            if (imageList is not null && Marshal.IsComObject(imageList))
                _ = Marshal.FinalReleaseComObject(imageList);
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