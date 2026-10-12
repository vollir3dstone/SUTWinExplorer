using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SUTWinExplorer;

public partial class ExplorerTabView : UserControl
{
    private readonly Stack<string> _backHistory = new();
    private readonly Stack<string> _forwardHistory = new();

    public ExplorerTabView(string initialPath)
    {
        InitializeComponent();
        InitializeClassicTree();
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
        RefreshFiles();
        RefreshCurrentPathTree();
        LocationChanged?.Invoke(this, CurrentPath);
    }

    private void RefreshFiles()
    {
        var entries = new List<FileEntry>();
        try
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

            foreach (var file in Directory.EnumerateFiles(CurrentPath))
            {
                try
                {
                    var info = new FileInfo(file);
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

    private void InitializeClassicTree()
    {
        var drives = new ObservableCollection<TreeEntry>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            var root = new TreeEntry(drive.Name, drive.RootDirectory.FullName);
            AddPlaceholder(root);
            drives.Add(root);
        }

        ClassicTree.ItemsSource = drives;
    }

    private void RefreshCurrentPathTree()
    {
        var rootPath = Path.GetPathRoot(CurrentPath);
        if (string.IsNullOrEmpty(rootPath))
            return;

        var root = new TreeEntry(rootPath, rootPath);
        var segments = Path.GetRelativePath(rootPath, CurrentPath)
            .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        var parent = root;
        var currentPath = rootPath;

        foreach (var segment in segments)
        {
            currentPath = Path.Combine(currentPath, segment);
            var child = new TreeEntry(segment, currentPath);
            parent.Children.Add(child);
            parent = child;
        }

        parent.IsSelected = true;
        parent.IsExpanded = true;
        LoadChildren(parent);
        for (var ancestor = root; ancestor.Children.Count > 0; ancestor = ancestor.Children[0])
            ancestor.IsExpanded = true;

        CurrentPathTree.ItemsSource = new[] { root };
    }

    private void TreeItem_Expanded(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is TreeViewItem { DataContext: TreeEntry entry } && !entry.IsPlaceholder)
            LoadChildren(entry);
    }

    private static void LoadChildren(TreeEntry entry)
    {
        if (entry.IsLoaded || entry.IsPlaceholder)
            return;

        entry.IsLoaded = true;
        entry.Children.Clear();
        try
        {
            foreach (var directory in Directory.EnumerateDirectories(entry.Path)
                         .OrderBy(path => path, StringComparer.CurrentCultureIgnoreCase))
            {
                var child = new TreeEntry(Path.GetFileName(Path.TrimEndingDirectorySeparator(directory)), directory);
                AddPlaceholder(child);
                entry.Children.Add(child);
            }
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
        if (FindAncestor<ListViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: FileEntry entry })
            return;

        FileList.SelectedItem = entry;
        ShowNativeMenu(entry.FullPath);
        e.Handled = true;
    }

    private void Tree_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not TreeView || FindAncestor<TreeViewItem>(e.OriginalSource as DependencyObject) is not { DataContext: TreeEntry entry } || entry.IsPlaceholder)
            return;

        entry.IsSelected = true;
        ShowNativeMenu(entry.Path);
        e.Handled = true;
    }

    private void Tree_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is TreeView tree && tree.SelectedItem is TreeEntry { IsPlaceholder: false } entry)
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

public sealed class TreeEntry
{
    private TreeEntry(string name, string path, bool isPlaceholder)
    {
        Name = name;
        Path = path;
        IsPlaceholder = isPlaceholder;
        IsLoaded = isPlaceholder;
    }

    public TreeEntry(string name, string path) : this(name, path, false) { }

    public string Name { get; }
    public string Path { get; }
    public bool IsPlaceholder { get; }
    public bool IsLoaded { get; set; }
    public bool IsExpanded { get; set; }
    public bool IsSelected { get; set; }
    public ObservableCollection<TreeEntry> Children { get; } = new();

    public static TreeEntry Placeholder() => new("Loading", string.Empty, true);
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
        Icon = ShellIconProvider.GetSmallIcon(fullPath);
    }

    public string Name { get; }
    public string FullPath { get; }
    public bool IsDirectory { get; }
    public string Type { get; }
    public string SizeText { get; }
    public DateTime Modified { get; }
    public ImageSource? Icon { get; }
    public string ModifiedText => Modified.ToString("g");
}

internal static class ShellIconProvider
{
    private const uint Icon = 0x00000100;
    private const uint SmallIcon = 0x00000001;
    private const uint AddOverlays = 0x00000020;

    public static ImageSource? GetSmallIcon(string path)
    {
        var info = new ShellFileInfo();
        var result = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<ShellFileInfo>(), Icon | SmallIcon | AddOverlays);
        if (result == IntPtr.Zero || info.IconHandle == IntPtr.Zero)
            return null;

        try
        {
            var bitmap = Imaging.CreateBitmapSourceFromHIcon(
                info.IconHandle,
                Int32Rect.Empty,
                BitmapSizeOptions.FromWidthAndHeight(16, 16));
            bitmap.Freeze();
            return bitmap;
        }
        finally
        {
            _ = DestroyIcon(info.IconHandle);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SHGetFileInfo(string path, uint fileAttributes, ref ShellFileInfo fileInfo, uint fileInfoSize, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr iconHandle);

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