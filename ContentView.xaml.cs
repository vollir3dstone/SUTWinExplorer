using System.Diagnostics;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

public partial class ContentView : UserControl
{
    private bool _initialized;
    private IDisposable? _directoryObserver;
    private ClipboardChangeMonitor? _clipboardMonitor;
    private CancellationTokenSource? _refreshCancellation;
    private CancellationTokenSource? _rangeCancellation;
    private CancellationTokenSource? _overlayWaitCancellation;
    private Task _snapshotReady = Task.CompletedTask;
    private readonly HashSet<Task> _metadataUpdates = [];
    private readonly List<FileSystemEventArgs> _pendingFileSystemChanges = [];
    private bool _applyingFileSystemChanges;
    private bool _closed;
    private readonly List<(string OldPath, string NewPath)> _pathRemaps = [];
    private DirectorySnapshot? _snapshot;
    private DirectoryRow[]? _rows;
    private ObservableCollection<DirectoryRow>? _displayRows;
    private readonly DirectorySortState _sorting = new();
    private readonly DirectoryDataCache _directoryCache = new();
    private readonly HashSet<string> _selectedPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _observedDirectories = new(StringComparer.OrdinalIgnoreCase);
    private bool _restoringSelection;
    private bool _suppressFilterRefresh;
    private string? _revealedPath;
    private DirectoryRow? _editingRow;
    private readonly ListViewDragSource<DirectoryRow> _dragSource;
    private bool _preserveDragSelection;
    private bool _toggleDragSelection;
    private bool _endingRename;
    private bool _deferredRefresh;
    private int _nextBackgroundIndex;
    private bool _loadingRange;
    private bool _loadScheduled;
    private bool _updatingColumnWidths;
    private bool _rightColumnsHidden;
    private bool _automaticallyHideRightColumns;
    private bool _manuallyHideRightColumns;
    private bool _showRightColumnsDespiteNarrowViewport;
    private double _lastColumnViewportWidth;
    private double _nameTypeWidth;
    private double _preferredTypeWidth = 130;
    private const double MinimumNameColumnWidth = 80;
    private readonly SutContextMenuController<DirectoryRow> _contextMenu;
    private static readonly DirectorySortColumn[] SortColumns =
    [
        DirectorySortColumn.Name, DirectorySortColumn.MediaTypeIcon, DirectorySortColumn.TypeApp1Icon,
        DirectorySortColumn.TypeApp2Name, DirectorySortColumn.DateModified, DirectorySortColumn.Size
    ];

    public ContentView()
    {
        InitializeComponent();
        ResetViewButton.LayoutUpdated += ResetViewButton_LayoutUpdated;
        SortOrderEditor.Configure(["Name", "MT", "TA1", "TA2", "Date", "Size"]);
        _sorting.Update(GetWidgetSortPairs());
        SortOrderEditor.Changed += SortOrderChanged;
        UpdateSortDisplay();
        _contextMenu = new SutContextMenuController<DirectoryRow>(
            row => row.FullPath,
            () => FileList.SelectedItems.OfType<DirectoryRow>().Select(row => row.FullPath).ToArray(),
            (screenX, screenY) =>
            {
                var source = FileList.InputHitTest(FileList.PointFromScreen(new Point(screenX, screenY))) as DependencyObject;
                return (FindAncestor<ListViewItem>(source)?.DataContext as DirectoryRow, source is not null && !IsListChrome(source));
            },
            row =>
            {
                FileList.SelectedItems.Clear();
                if (row is not null) FileList.SelectedItems.Add(row);
            },
            row => CreateContextMenuActions(),
            (row, paths) => SutShell.ShowItemMenuWithOpenLocation(paths, new WindowInteropHelper(Window.GetWindow(this)!).Handle,
                paths.Count == 1 && row.Entry is not null && SutShell.GetEditName(row.FullPath) is not null ? BeginRename : null,
                CreateOpenLocationAction(paths)),
            () => SutShell.ShowBackgroundMenu(CurrentPath, new WindowInteropHelper(Window.GetWindow(this)!).Handle),
            () => CurrentPath, CreateContextMenuActions,
            ShowNewItemDialog, CreateOpenLocationAction, CreateRunningAppActions);
        HideDirectoriesCheckBox.GetCheckBox().Checked += FiltersChanged;
        HideDirectoriesCheckBox.GetCheckBox().Unchecked += FiltersChanged;
        HideInternalContentCheckBox.GetCheckBox().Checked += FiltersChanged;
        HideInternalContentCheckBox.GetCheckBox().Unchecked += FiltersChanged;
        FileList.LayoutUpdated += FileList_LayoutUpdated;
        FileList.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(FileList_ScrollChanged));
        _ = new ListViewDropTarget(FileList, item => (item as DirectoryRow)?.FullPath, () => CurrentPath, () => _editingRow is null);
        _dragSource = new ListViewDragSource<DirectoryRow>(FileList, row =>
        {
            if (!FileList.SelectedItems.Contains(row))
            {
                FileList.SelectedItems.Clear();
                FileList.SelectedItems.Add(row);
            }
            return FileList.SelectedItems.OfType<DirectoryRow>().Select(item => item.FullPath).ToArray();
        }, () => _editingRow is null, () => { ClearDragStart(); _contextMenu.Reset(); });
        Loaded += ContentView_Loaded;
        Unloaded += ContentView_Unloaded;
    }

    private IReadOnlyList<ShellMenuAction> CreateContextMenuActions() =>
        new[] { PropertiesButton, NameClipboardCopyButton, PathClipboardCopyButton, ItemClipboardCopyButton, ItemClipboardPasteButton, LinkMarkItemButton, LinkAbortButton, LinkExecuteButton, CopyMarkItemButton, CopyAbortButton, CopyExecuteButton,
            MoveMarkItemButton, MoveAbortButton, MoveExecuteButton, RenameButton, DeleteButton }.Select(button => new ShellMenuAction(
                (string)button.Tag, System.Windows.Automation.AutomationProperties.GetName(button), button.IsEnabled,
                () => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)),
                IsTransfer: button.Tag is string action && (action.StartsWith("Link", StringComparison.Ordinal) || action.StartsWith("Copy", StringComparison.Ordinal) || action.StartsWith("Move", StringComparison.Ordinal)),
                SeparatorBefore: button == NameClipboardCopyButton || button == ItemClipboardPasteButton || button == DeleteButton) { IconSource = button }).ToArray();

    private IReadOnlyList<ShellMenuAction> CreateRunningAppActions(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0 || paths.Any(path => !File.Exists(path)))
            return [];

        try
        {
            var apps = RunningAppsAccessor.GetRunningApps(paths[0]);
            foreach (var path in paths.Skip(1).DistinctBy(Path.GetExtension, StringComparer.OrdinalIgnoreCase))
            {
                var registered = RunningAppsAccessor.GetRegisteredApps(path).Select(app => app.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
                apps = apps.Where(app => registered.Contains(app.App.Id)).ToArray();
            }
            var selectedPaths = paths.ToArray();
            return apps.OrderBy(app => app.App.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(app => app.App.Id, StringComparer.OrdinalIgnoreCase)
                .SelectMany(app => app.Windows.OrderBy(window => window.Title, StringComparer.CurrentCultureIgnoreCase)
                    .ThenBy(window => window.Handle.ToInt64())
                    .Select(window => new ShellMenuAction("open-running-app", $"{app.App.Name} - {(string.IsNullOrWhiteSpace(window.Title) ? "Untitled window" : window.Title)}".Replace("&", "&&"), true,
                        () => OpenInRunningApp(window, selectedPaths))))
                .ToArray();
        }
        catch (Exception exception)
        {
            Trace.TraceError("Could not list running applications: {0}", exception);
            return [];
        }
    }

    private void OpenInRunningApp(AppWindow window, IReadOnlyList<string> paths)
    {
        try
        {
            string? clipboardError = null;
            try
            {
                var files = new StringCollection();
                files.AddRange(paths.ToArray());
                Clipboard.SetFileDropList(files);
            }
            catch (System.Runtime.InteropServices.ExternalException exception)
            {
                clipboardError = exception.Message;
            }
            var result = RunningAppsAccessor.OpenInRunningAppResourcefully(window, paths);
            if (clipboardError is not null || !result.Paste.Sent || !result.Drop.Dropped)
                MessageBox.Show(Window.GetWindow(this), $"{(clipboardError is null ? "" : $"Clipboard: {clipboardError}\n")}Paste: {result.Paste.Error ?? "sent (not confirmed)"}\nDrop: {result.Drop.Error ?? "accepted"}",
                    "Open in running app", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Open in running app", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private ShellMenuAction? CreateOpenLocationAction(IReadOnlyList<string> paths)
    {
        if (!paths.Any(path => string.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase)))
            return null;

        var shortcutPath = paths[0];
        return new ShellMenuAction("opencontaining", "Open parent", paths.Count == 1, () =>
        {
            try
            {
                var target = SutShell.GetLinkTarget(shortcutPath) ??
                    throw new InvalidOperationException("The shortcut target is unavailable or is not a filesystem item.");
                var directory = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(target)) ??
                    throw new InvalidOperationException("The shortcut target does not have a containing directory.");
                DirectoryOpenRequested?.Invoke(this, directory);
            }
            catch (Exception exception)
            {
                MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open parent",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        });
    }

    internal void ShowNewItemDialog(string path)
    {
        var created = NewItemDialog.ShowForDirectory(path, Window.GetWindow(this)!);
        if (created is not { } item || !string.Equals(path, CurrentPath, StringComparison.OrdinalIgnoreCase))
            return;

        RevealInsertedItems([item.Path]);
    }

    internal void RevealInsertedItems(IEnumerable<string> paths)
    {
        var currentDirectory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(CurrentPath));
        var insertedPaths = paths.Where(path =>
            string.Equals(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(Path.GetFullPath(path))),
                currentDirectory, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (insertedPaths.Length == 0)
            return;

        _suppressFilterRefresh = true;
        try
        {
            if (insertedPaths.Any(Directory.Exists))
                HideDirectoriesCheckBox.GetCheckBox().IsChecked = false;
            if (insertedPaths.Any(path => InternalItemFilter.IsInternal(path, Directory.Exists(path))))
                HideInternalContentCheckBox.GetCheckBox().IsChecked = false;
            if (insertedPaths.Any(path => !InternalItemFilter.MatchesNamePattern(path, NamePatternTextBox.Text)))
                NamePatternTextBox.Clear();
        }
        finally
        {
            _suppressFilterRefresh = false;
        }
        _selectedPaths.Clear();
        _selectedPaths.UnionWith(insertedPaths);
        _revealedPath = insertedPaths[0];
        RefreshCore(invalidate: true);
    }

    internal bool FocusContent() => FileList.Focus();
    internal bool? HideInternalItems
    {
        get => HideInternalContentCheckBox.GetCheckBox().IsChecked;
        set => HideInternalContentCheckBox.GetCheckBox().IsChecked = value;
    }

    internal void CopyViewSettingsFrom(ContentView source)
    {
        _suppressFilterRefresh = true;
        try
        {
            HideDirectoriesCheckBox.GetCheckBox().IsChecked = source.HideDirectoriesCheckBox.GetCheckBox().IsChecked;
            HideInternalContentCheckBox.GetCheckBox().IsChecked = source.HideInternalContentCheckBox.GetCheckBox().IsChecked;
            NamePatternTextBox.Text = source.NamePatternTextBox.Text;
            SortOrderEditor.SetItems(source.SortOrderEditor.Items);
        }
        finally
        {
            _suppressFilterRefresh = false;
        }
        RefreshCore(invalidate: false);
    }

    private string CurrentPath { get; set; } = string.Empty;
    internal event EventHandler<string>? DirectoryOpenRequested;
    internal event Action<string, string>? DirectoryRenamed;
    internal event EventHandler<DirectoryNotification>? FileSystemChanged;
    internal Action<Action>? DirectoryOperation { get; set; }

    private void RunDirectoryOperation(Action operation)
    {
        if (DirectoryOperation is { } coordinator)
            coordinator(operation);
        else
            operation();
    }

    internal void Initialize(bool isBrowsable)
    {
        if (_initialized)
            throw new InvalidOperationException("The content view is already initialized.");
        _initialized = true;
    }

    internal void SetCurrentPath(string path)
    {
        EndRename(commit: false);
        CancelOverlayWait();
        _directoryCache.Invalidate();
        _deferredRefresh = false;
        _refreshCancellation?.Cancel();
        _rangeCancellation?.Cancel();
        _snapshot = null;
        _rows = null;
        _selectedPaths.Clear();
        _revealedPath = null;
        _pathRemaps.Clear();
        _pendingFileSystemChanges.Clear();
        CurrentPath = path;
        ClearRows();
        DirectoryCountLabel.Text = "-";
        FileCountLabel.Text = "-";
        StatusLabel.Text = string.Empty;
        StatusLabel.ToolTip = null;
    }

    internal void EnsureLocationAccessible(string path) => SutShell.EnsureDirectoryAccessible(path);

    internal void RemapPaths(string oldPath, string newPath)
    {
        _pathRemaps.Add((oldPath, newPath));
        var refreshPending = _snapshot is null && _refreshCancellation is not null;
        if (refreshPending)
            _refreshCancellation?.Cancel();
        _rangeCancellation?.Cancel();
        _directoryCache.RemapPaths(oldPath, newPath);
        CurrentPath = ShellLocations.RemapPath(CurrentPath, oldPath, newPath);
        var selectedPaths = _selectedPaths.Select(path => ShellLocations.RemapPath(path, oldPath, newPath)).ToArray();
        _selectedPaths.Clear();
        _selectedPaths.UnionWith(selectedPaths);
        if (_revealedPath is not null)
            _revealedPath = ShellLocations.RemapPath(_revealedPath, oldPath, newPath);
        if (_rows is not null)
            foreach (var row in _rows)
                row.RemapPath(oldPath, newPath);
        if (refreshPending)
            RefreshCore(invalidate: false);
        else
            ScheduleRangeLoad();
    }

    internal void Refresh(bool refreshView)
    {
        if (refreshView)
            RefreshCore(invalidate: true);
    }

    private async void RefreshCore(bool invalidate)
    {
        if (string.IsNullOrWhiteSpace(CurrentPath))
            return;
        if (invalidate)
            _directoryCache.Invalidate();
        if (_editingRow is not null)
        {
            _deferredRefresh = true;
            return;
        }

        _refreshCancellation?.Cancel();
        _rangeCancellation?.Cancel();
        CancelOverlayWait();
        _snapshot = null;
        _rows = null;
        ClearRows();
        var cancellation = new CancellationTokenSource();
        _refreshCancellation = cancellation;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _snapshotReady = completion.Task;
        var path = CurrentPath;
        var showDirectories = HideDirectoriesCheckBox.GetCheckBox().IsChecked != true;
        var hideInternal = HideInternalContentCheckBox.GetCheckBox().IsChecked == true;
        var namePattern = NamePatternTextBox.Text;
        DirectoryCountLabel.Text = "-";
        FileCountLabel.Text = "-";
        StatusLabel.Text = string.Empty;
        StatusLabel.ToolTip = null;
        try
        {
            var snapshot = await SutShell.OpenCachedDirectoryAsync(path, showDirectories, hideInternal, namePattern, _sorting, _directoryCache, cancellation.Token);
            if (cancellation.IsCancellationRequested || !ReferenceEquals(_refreshCancellation, cancellation))
                return;

            _snapshot = snapshot;
            _rows = snapshot.Items.Select(item => new DirectoryRow(item.FullPath)).ToArray();
            _nextBackgroundIndex = 0;
            _restoringSelection = true;
            try
            {
                _displayRows = new ObservableCollection<DirectoryRow>(_rows);
                FileList.ItemsSource = _displayRows;
                foreach (var row in _rows)
                    if (_selectedPaths.Contains(row.FullPath))
                        FileList.SelectedItems.Add(row);
                if (_revealedPath is { } revealedPath &&
                    _rows.FirstOrDefault(row => string.Equals(row.FullPath, revealedPath, StringComparison.OrdinalIgnoreCase)) is { } revealedRow)
                    FileList.ScrollIntoView(revealedRow);
                _selectedPaths.IntersectWith(_rows.Select(row => row.FullPath));
            }
            finally
            {
                _restoringSelection = false;
            }
            UpdateToolbarOperationButtons();
            DirectoryCountLabel.Text = snapshot.DirectoryCount.ToString(CultureInfo.CurrentCulture);
            FileCountLabel.Text = snapshot.FileCount.ToString(CultureInfo.CurrentCulture);
            ScheduleRangeLoad();
            if (snapshot.OverlayCompletion is { } overlayCompletion)
            {
                var overlayWait = new CancellationTokenSource();
                _overlayWaitCancellation = overlayWait;
                _ = RefreshAfterOverlaysAsync(snapshot, path, overlayCompletion, overlayWait);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (ReferenceEquals(_refreshCancellation, cancellation))
            {
                FileList.ItemsSource = null;
                StatusLabel.Text = "!";
                StatusLabel.ToolTip = exception.Message;
            }
        }
        finally
        {
            completion.TrySetResult();
            if (ReferenceEquals(_refreshCancellation, cancellation))
                _refreshCancellation = null;
            cancellation.Dispose();
        }
    }

    internal void UpdateCachedItemMetadata(string itemPath)
    {
        var update = UpdateCachedItemMetadataAsync(CurrentPath, itemPath);
        _metadataUpdates.Add(update);
        _ = RemoveCompletedMetadataUpdateAsync(update);
    }

    private async Task UpdateCachedItemMetadataAsync(string directoryPath, string itemPath)
    {
        Task ready;
        do
        {
            ready = _snapshotReady;
            await ready;
        }
        while (!ReferenceEquals(ready, _snapshotReady));

        foreach (var (oldPath, newPath) in _pathRemaps)
        {
            directoryPath = ShellLocations.RemapPath(directoryPath, oldPath, newPath);
            itemPath = ShellLocations.RemapPath(itemPath, oldPath, newPath);
        }
        if (string.Equals(CurrentPath, directoryPath, StringComparison.OrdinalIgnoreCase))
            await SutShell.RefreshCachedItemMetadataAsync(_directoryCache, directoryPath, itemPath);
    }

    private async Task RemoveCompletedMetadataUpdateAsync(Task update)
    {
        try { await update; }
        catch (Exception exception) { Debug.WriteLine($"Could not update cached metadata: {exception}"); }
        finally { _metadataUpdates.Remove(update); }
    }

    internal async Task WaitForMetadataUpdatesAsync()
    {
        while (_metadataUpdates.Count > 0)
        {
            var updates = _metadataUpdates.ToArray();
            try { await Task.WhenAll(updates); }
            catch (Exception exception) { Debug.WriteLine($"Could not update cached metadata: {exception}"); }
            finally
            {
                foreach (var update in updates)
                    _metadataUpdates.Remove(update);
            }
        }
    }

    internal void RefreshDisplay() => RefreshCore(invalidate: false);

    internal void ApplyFileSystemChanges(IEnumerable<FileSystemEventArgs> changes)
    {
        if (_closed)
            return;
        _pendingFileSystemChanges.AddRange(changes);
        _ = ProcessFileSystemChangesAsync();
    }

    private async Task ProcessFileSystemChangesAsync()
    {
        if (_applyingFileSystemChanges || _editingRow is not null || _closed)
            return;
        _applyingFileSystemChanges = true;
        try
        {
            while (_pendingFileSystemChanges.Count > 0 && _editingRow is null && !_closed)
            {
                var changes = _pendingFileSystemChanges.ToArray();
                _pendingFileSystemChanges.Clear();
                var path = CurrentPath;
                try
                {
                    Task ready;
                    do
                    {
                        ready = _snapshotReady;
                        await ready;
                    }
                    while (!ReferenceEquals(ready, _snapshotReady));
                    await WaitForMetadataUpdatesAsync();
                    foreach (var (oldDirectory, newDirectory) in _pathRemaps)
                        path = ShellLocations.RemapPath(path, oldDirectory, newDirectory);
                    if (_closed || !string.Equals(path, CurrentPath, StringComparison.OrdinalIgnoreCase))
                        continue;
                    changes = changes.Select(RemapFileSystemChange).ToArray();
                    var previousSnapshot = _snapshot;
                    var previousRows = _displayRows;
                    if (previousSnapshot is null || previousRows is null ||
                        !await SutShell.ApplyCachedItemChangesAsync(_directoryCache, path, changes))
                    {
                        RefreshCore(invalidate: true);
                        continue;
                    }
                    var snapshot = await SutShell.OpenCachedDirectoryAsync(path,
                        HideDirectoriesCheckBox.GetCheckBox().IsChecked != true,
                        HideInternalContentCheckBox.GetCheckBox().IsChecked == true,
                        NamePatternTextBox.Text, _sorting, _directoryCache, CancellationToken.None);
                    var changedPaths = changes.Select(change => change.FullPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
                    changedPaths.UnionWith(changes.OfType<RenamedEventArgs>().Select(change => change.OldFullPath));
                    var entries = await SutShell.GetChangedEntriesAsync(snapshot, changedPaths);
                    if (_closed)
                        continue;
                    if (!string.Equals(path, CurrentPath, StringComparison.OrdinalIgnoreCase))
                    {
                        foreach (var (oldDirectory, newDirectory) in _pathRemaps)
                            path = ShellLocations.RemapPath(path, oldDirectory, newDirectory);
                        if (string.Equals(path, CurrentPath, StringComparison.OrdinalIgnoreCase))
                            _pendingFileSystemChanges.InsertRange(0, changes);
                        continue;
                    }
                    if (!ReferenceEquals(previousSnapshot, _snapshot) || !ReferenceEquals(previousRows, _displayRows) || _editingRow is not null)
                    {
                        _pendingFileSystemChanges.InsertRange(0, changes);
                        continue;
                    }
                    ApplyFileSystemSnapshot(snapshot, changes, changedPaths, entries);
                }
                catch (Exception exception)
                {
                    Debug.WriteLine($"Could not apply directory changes: {exception}");
                    foreach (var (oldDirectory, newDirectory) in _pathRemaps)
                        path = ShellLocations.RemapPath(path, oldDirectory, newDirectory);
                    if (!_closed && string.Equals(path, CurrentPath, StringComparison.OrdinalIgnoreCase))
                        RefreshCore(invalidate: true);
                }
            }
        }
        finally
        {
            _applyingFileSystemChanges = false;
        }
    }

    private FileSystemEventArgs RemapFileSystemChange(FileSystemEventArgs change)
    {
        var path = change.FullPath;
        var oldPath = (change as RenamedEventArgs)?.OldFullPath;
        foreach (var (oldDirectory, newDirectory) in _pathRemaps)
        {
            path = ShellLocations.RemapPath(path, oldDirectory, newDirectory);
            if (oldPath is not null)
                oldPath = ShellLocations.RemapPath(oldPath, oldDirectory, newDirectory);
        }
        var directory = Path.GetDirectoryName(path)!;
        return oldPath is null
            ? new FileSystemEventArgs(change.ChangeType, directory, Path.GetFileName(path))
            : new RenamedEventArgs(change.ChangeType, directory, Path.GetFileName(path), Path.GetFileName(oldPath));
    }

    private void ApplyFileSystemSnapshot(DirectorySnapshot snapshot, IReadOnlyList<FileSystemEventArgs> changes,
        HashSet<string> changedPaths, IReadOnlyDictionary<string, FileEntry> entries)
    {
        var rows = _displayRows!;
        var oldRows = rows.ToArray();
        var scroll = FindVisualChild<ScrollViewer>(FileList);
        var oldOffset = scroll?.VerticalOffset ?? 0;
        var firstVisible = Math.Clamp((int)Math.Floor(oldOffset), 0, oldRows.Length);
        _rangeCancellation?.Cancel();
        CancelOverlayWait();
        _restoringSelection = true;
        try
        {
            foreach (var rename in changes.OfType<RenamedEventArgs>())
            {
                var row = rows.FirstOrDefault(candidate => string.Equals(candidate.FullPath, rename.OldFullPath, StringComparison.OrdinalIgnoreCase));
                if (row is null)
                    continue;
                var replaced = rows.FirstOrDefault(candidate => !ReferenceEquals(candidate, row) &&
                    string.Equals(candidate.FullPath, rename.FullPath, StringComparison.OrdinalIgnoreCase));
                if (replaced is not null)
                    rows.Remove(replaced);
                entries.TryGetValue(rename.FullPath, out var renamedEntry);
                row.ApplyRename(rename.OldFullPath, rename.FullPath, renamedEntry);
                if (_selectedPaths.Remove(rename.OldFullPath))
                    _selectedPaths.Add(rename.FullPath);
                if (_revealedPath is not null && string.Equals(_revealedPath, rename.OldFullPath, StringComparison.OrdinalIgnoreCase))
                    _revealedPath = rename.FullPath;
            }

            var desiredPaths = snapshot.Items.Select(item => item.FullPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
            for (var index = rows.Count - 1; index >= 0; index--)
                if (!desiredPaths.Contains(rows[index].FullPath))
                    rows.RemoveAt(index);
            var existing = rows.ToDictionary(row => row.FullPath, StringComparer.OrdinalIgnoreCase);
            var desired = snapshot.Items.Select(item => existing.GetValueOrDefault(item.FullPath) ?? new DirectoryRow(item.FullPath)).ToArray();
            for (var index = 0; index < desired.Length; index++)
                if (!existing.ContainsKey(desired[index].FullPath))
                    rows.Insert(index, desired[index]);

            for (var index = 0; index < desired.Length; index++)
            {
                if (ReferenceEquals(rows[index], desired[index]))
                    continue;
                var current = rows[index];
                if (changedPaths.Contains(current.FullPath) && !changedPaths.Contains(desired[index].FullPath))
                {
                    rows.Move(index, Array.IndexOf(desired, current));
                    index--;
                }
                else
                    rows.Move(rows.IndexOf(desired[index]), index);
            }

            foreach (var row in rows)
                if (row.Entry is not null && entries.TryGetValue(row.FullPath, out var entry))
                    row.Entry = entry;
            _selectedPaths.IntersectWith(desiredPaths);
            foreach (var row in rows)
                if (_selectedPaths.Contains(row.FullPath) && !FileList.SelectedItems.Contains(row))
                    FileList.SelectedItems.Add(row);
        }
        finally
        {
            _restoringSelection = false;
        }
        _snapshot = snapshot;
        _rows = rows.ToArray();
        if (scroll is not null && scroll.CanContentScroll && firstVisible < oldRows.Length)
        {
            var anchor = oldRows.Skip(firstVisible).FirstOrDefault(row => !changedPaths.Contains(row.FullPath) && rows.Contains(row));
            if (anchor is not null)
            {
                var adjustment = rows.IndexOf(anchor) - Array.IndexOf(oldRows, anchor);
                if (adjustment != 0)
                {
                    FileList.UpdateLayout();
                    scroll.ScrollToVerticalOffset(oldOffset + adjustment);
                }
            }
        }
        _nextBackgroundIndex = 0;
        DirectoryCountLabel.Text = snapshot.DirectoryCount.ToString(CultureInfo.CurrentCulture);
        FileCountLabel.Text = snapshot.FileCount.ToString(CultureInfo.CurrentCulture);
        UpdateToolbarOperationButtons();
        ScheduleRangeLoad();
        if (snapshot.OverlayCompletion is { } overlayCompletion)
        {
            var overlayWait = new CancellationTokenSource();
            _overlayWaitCancellation = overlayWait;
            _ = RefreshAfterOverlaysAsync(snapshot, CurrentPath, overlayCompletion, overlayWait);
        }
    }

    internal void CancelOverlayWait() => _overlayWaitCancellation?.Cancel();

    internal void Close()
    {
        _closed = true;
        _pendingFileSystemChanges.Clear();
        _refreshCancellation?.Cancel();
        _rangeCancellation?.Cancel();
        CancelOverlayWait();
    }

    private async Task RefreshAfterOverlaysAsync(DirectorySnapshot snapshot, string path, Task overlayCompletion, CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Yield();
            await overlayCompletion.WaitAsync(cancellation.Token);
            var rows = _rows;
            if (cancellation.IsCancellationRequested || !ReferenceEquals(_snapshot, snapshot) || rows is null ||
                !string.Equals(CurrentPath, path, StringComparison.OrdinalIgnoreCase))
                return;
            var paths = rows.Select(row => row.FullPath).ToArray();
            var icons = await Task.Run(() => snapshot.IconSession.GetIcons(paths), cancellation.Token);
            if (cancellation.IsCancellationRequested || !ReferenceEquals(_snapshot, snapshot) || !ReferenceEquals(_rows, rows) ||
                !string.Equals(CurrentPath, path, StringComparison.OrdinalIgnoreCase))
                return;
            for (var index = 0; index < rows.Length; index++)
                if (icons[index] is { } icon)
                    rows[index].UpdateOverlay(icon);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(_overlayWaitCancellation, cancellation))
                _overlayWaitCancellation = null;
            cancellation.Dispose();
        }
    }

    private void ClearRows()
    {
        _restoringSelection = true;
        try
        {
            _displayRows = null;
            FileList.ItemsSource = null;
        }
        finally
        {
            _restoringSelection = false;
        }
        UpdateToolbarOperationButtons();
    }

    internal void SetObservedDirectories(IEnumerable<string> directories, bool force = false)
    {
        var paths = directories.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!force && _observedDirectories.SetEquals(paths))
            return;
        ClearObservedDirectories();
        _observedDirectories.UnionWith(paths);
        _directoryObserver = SutShell.ObservePathviewDirectories(paths, CurrentPath, notification =>
        {
            if (!Dispatcher.HasShutdownStarted)
            _ = Dispatcher.BeginInvoke(() => FileSystemChanged?.Invoke(this, notification));
        });
    }

    internal void ClearObservedDirectories()
    {
        _directoryObserver?.Dispose();
        _directoryObserver = null;
        _observedDirectories.Clear();
    }

    private void ContentView_Loaded(object sender, RoutedEventArgs e)
    {
        DependencyPropertyDescriptor.FromProperty(GridViewColumn.WidthProperty, typeof(GridViewColumn))
            .AddValueChanged(NameColumn, NameColumn_WidthChanged);
        var culture = CultureInfo.CurrentCulture;
        var typeface = new Typeface(FileList.FontFamily, FileList.FontStyle, FileList.FontWeight, FileList.FontStretch);
        var pixelsPerDip = VisualTreeHelper.GetDpi(FileList).PixelsPerDip;
        double Measure(string text) => new FormattedText(text, culture, FileList.FlowDirection,
            typeface, FileList.FontSize, Brushes.Black, pixelsPerDip).WidthIncludingTrailingWhitespace;
        var widestDigit = Enumerable.Range(0, 10).Select(value => (char)('0' + value))
            .MaxBy(digit => Measure(digit.ToString()));
        var sampleDate = new DateTime(2026, 12, 28, 23, 58, 0).ToString(FileEntry.DateFormat, CultureInfo.InvariantCulture);
        sampleDate = string.Concat(sampleDate.Select(character => char.IsAsciiDigit(character) ? widestDigit : character));
        DateColumn.Width = Math.Ceiling(Math.Max(Measure("Date modified") + 10, Measure(sampleDate)) + 16);
        FileList_SizeChanged(FileList, null!);
        ScheduleRangeLoad();
        LinkWorkflowState.Shared.Changed += WorkflowState_Changed;
        CopyWorkflowState.Shared.Changed += WorkflowState_Changed;
        MoveWorkflowState.Shared.Changed += WorkflowState_Changed;
        _clipboardMonitor = new ClipboardChangeMonitor(UpdateClipboardButton);
        UpdateToolbarOperationButtons();
    }

    private void ContentView_Unloaded(object sender, RoutedEventArgs e)
    {
        _contextMenu.Reset();
        ClearDragStart();
        DependencyPropertyDescriptor.FromProperty(GridViewColumn.WidthProperty, typeof(GridViewColumn))
            .RemoveValueChanged(NameColumn, NameColumn_WidthChanged);
        _rangeCancellation?.Cancel();
        LinkWorkflowState.Shared.Changed -= WorkflowState_Changed;
        CopyWorkflowState.Shared.Changed -= WorkflowState_Changed;
        MoveWorkflowState.Shared.Changed -= WorkflowState_Changed;
        _clipboardMonitor?.Dispose();
        _clipboardMonitor = null;
    }

    private void FiltersChanged(object sender, RoutedEventArgs e)
    {
        if (!_suppressFilterRefresh) RefreshCore(invalidate: false);
    }

    private void ResetViewButton_LayoutUpdated(object? sender, EventArgs e)
    {
        if (!ResetViewButton.IsArrangeValid || !ResetViewLabel.IsArrangeValid)
            return;
        var baseline = ResetViewLabel.TransformToAncestor(ResetViewButton)
            .Transform(new Point(0, ResetViewLabel.BaselineOffset)).Y;
        var current = TextBlock.GetBaselineOffset(ResetViewButton);
        if (!double.IsFinite(current) || Math.Abs(current - baseline) > 0.01)
            TextBlock.SetBaselineOffset(ResetViewButton, baseline);
    }

    private void ResetViewButton_Click(object sender, RoutedEventArgs e)
    {
        _suppressFilterRefresh = true;
        try
        {
            HideDirectoriesCheckBox.GetCheckBox().IsChecked = true;
            HideInternalContentCheckBox.GetCheckBox().IsChecked = true;
            NamePatternTextBox.Clear();
            SortOrderEditor.Reset();
        }
        finally
        {
            _suppressFilterRefresh = false;
        }
        RefreshCore(invalidate: false);
    }

    private void FileList_ColumnHeaderClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not GridViewColumnHeader { Tag: string tag } ||
            !Enum.TryParse<DirectorySortColumn>(tag, out var column))
            return;

        var index = Array.IndexOf(SortColumns, column);
        if (index >= 0) SortOrderEditor.Select(index);
    }

    private DirectorySortPair[] GetWidgetSortPairs() => SortOrderEditor.Items.Select(item => new DirectorySortPair(
        SortColumns[item.Index], item.Direction == SortOrderDirection.Ascending
            ? DirectorySortCriterion.Ascending : DirectorySortCriterion.Descending)).ToArray();

    private void SortOrderChanged(object? sender, EventArgs e)
    {
        _sorting.Update(GetWidgetSortPairs());
        UpdateSortDisplay();
        if (!_suppressFilterRefresh) RefreshCore(invalidate: false);
    }

    private void UpdateSortDisplay()
    {
        var pairs = _sorting.Pairs;
        var primary = pairs[0];
        foreach (var (indicator, indicatorColumn) in new[]
        {
            (NameSortIndicator, DirectorySortColumn.Name), (TypeApp2NameSortIndicator, DirectorySortColumn.TypeApp2Name),
            (SizeSortIndicator, DirectorySortColumn.Size), (DateSortIndicator, DirectorySortColumn.DateModified),
            (MediaTypeIconSortIndicator, DirectorySortColumn.MediaTypeIcon), (TypeApp1IconSortIndicator, DirectorySortColumn.TypeApp1Icon)
        })
        {
            indicator.Visibility = indicatorColumn == primary.Column ? Visibility.Visible : Visibility.Collapsed;
            indicator.Text = primary.Criterion == DirectorySortCriterion.Ascending ? "\u25B2" : "\u25BC";
        }

    }

    private void FileList_LayoutUpdated(object? sender, EventArgs e) => ScheduleRangeLoad();

    private void FileList_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.VerticalChange != 0)
            _rangeCancellation?.Cancel();
        if (e.ViewportWidthChange != 0)
            UpdateColumnWidths();
        ScheduleRangeLoad();
    }

    private void ScheduleRangeLoad()
    {
        if (_loadScheduled || _loadingRange || _snapshot is null || _rows is null || !FileList.IsVisible)
            return;
        _loadScheduled = true;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            _loadScheduled = false;
            LoadNextRange();
        }));
    }

    private async void LoadNextRange()
    {
        var snapshot = _snapshot;
        var rows = _rows;
        if (_loadingRange || snapshot is null || rows is null || !FileList.IsVisible)
            return;

        var panel = FindVisualChild<VirtualizingStackPanel>(FileList);
        if (panel is null)
            return;
        var start = panel.Children.OfType<ListViewItem>()
            .Where(item => item.IsVisible && item.TransformToAncestor(panel).TransformBounds(new Rect(item.RenderSize))
                .IntersectsWith(new Rect(panel.RenderSize)))
            .Select(item => FileList.ItemContainerGenerator.IndexFromContainer(item))
            .Where(index => index >= 0 && index < rows.Length && rows[index].Entry is null && !rows[index].Failed)
            .DefaultIfEmpty(-1).Min();
        if (start < 0)
        {
            while (_nextBackgroundIndex < rows.Length &&
                   (rows[_nextBackgroundIndex].Entry is not null || rows[_nextBackgroundIndex].Failed))
                _nextBackgroundIndex++;
            if (_nextBackgroundIndex == rows.Length)
                return;
            start = _nextBackgroundIndex;
        }

        const int batchSize = 8;
        var count = 0;
        while (start + count < rows.Length && count < batchSize && rows[start + count].Entry is null && !rows[start + count].Failed)
            count++;

        var cancellation = new CancellationTokenSource();
        _rangeCancellation = cancellation;
        _loadingRange = true;
        try
        {
            var entries = await SutShell.GetDirectoryRangeAsync(snapshot, start, count, cancellation.Token);
            if (cancellation.IsCancellationRequested || !ReferenceEquals(_snapshot, snapshot) || !ReferenceEquals(_rows, rows))
                return;
            for (var index = 0; index < entries.Count; index++)
                rows[start + index].Entry = entries[index];
            UpdateToolbarOperationButtons();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Debug.WriteLine($"Could not load content range: {exception}");
            if (ReferenceEquals(_rows, rows) && !cancellation.IsCancellationRequested)
            {
                for (var index = 0; index < count; index++)
                    rows[start + index].Failed = true;
                StatusLabel.Text = "!";
                StatusLabel.ToolTip = "Some item details could not be loaded.";
            }
        }
        finally
        {
            if (ReferenceEquals(_rangeCancellation, cancellation))
                _rangeCancellation = null;
            _loadingRange = false;
            cancellation.Dispose();
            ScheduleRangeLoad();
        }
    }

    private void NamePatternTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_suppressFilterRefresh) RefreshCore(invalidate: false);
    }

    private void ClearNamePatternButton_Click(object sender, RoutedEventArgs e) => NamePatternTextBox.Clear();

    private void ContentOperationButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string action })
            return;

        try
        {
            var selectedPaths = FileList.SelectedItems.OfType<DirectoryRow>().Select(row => row.Entry)
                .OfType<FileEntry>().Select(entry => entry.FullPath).ToList();
            var owner = Window.GetWindow(this) is { } window ? new WindowInteropHelper(window).Handle : IntPtr.Zero;
            switch (action)
            {
                case "New":
                    ShowNewItemDialog(CurrentPath);
                    break;
                case "Properties":
                    if (selectedPaths.Count == 0)
                        throw new InvalidOperationException("Select one or more items before using Properties.");
                    SutShell.ShowProperties(selectedPaths, owner);
                    break;
                case "Rename":
                    BeginRename();
                    break;
                case "ItemClipboardCopy":
                    if (selectedPaths.Count == 0)
                        throw new InvalidOperationException("Select one or more items before using Item clipboard copy.");
                    SutShell.CopyToClipboard(selectedPaths, owner);
                    break;
                case "ItemClipboardPaste":
                    try { SutShell.PasteFromClipboard(CurrentPath, owner); }
                    finally { Refresh(true); }
                    break;
                case "LinkMarkItem":
                    if (CopyWorkflowState.Shared.IsPrepared || MoveWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared transfer before starting a Link.");
                    LinkWorkflowState.Shared.Prepare(selectedPaths);
                    break;
                case "LinkExecute":
                    var linked = new List<string>();
                    try
                    {
                        SutShell.Link(LinkWorkflowState.Shared.PreparedPaths, CurrentPath, linked);
                        LinkWorkflowState.Shared.CompleteExecute();
                    }
                    finally { RevealInsertedItems(linked); }
                    break;
                case "LinkAbort":
                    LinkWorkflowState.Shared.Abort();
                    break;
                case "CopyMarkItem":
                    if (LinkWorkflowState.Shared.IsPrepared || MoveWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared transfer before starting a Copy.");
                    CopyWorkflowState.Shared.Prepare(selectedPaths);
                    break;
                case "CopyExecute":
                    var copied = new List<string>();
                    try
                    {
                        SutShell.Copy(CopyWorkflowState.Shared.PreparedPaths, CurrentPath, owner, copied);
                        CopyWorkflowState.Shared.CompleteExecute();
                    }
                    finally { RevealInsertedItems(copied); }
                    break;
                case "CopyAbort":
                    CopyWorkflowState.Shared.Abort();
                    break;
                case "MoveMarkItem":
                    if (LinkWorkflowState.Shared.IsPrepared || CopyWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared transfer before starting a Move.");
                    MoveWorkflowState.Shared.Prepare(selectedPaths);
                    break;
                case "MoveExecute":
                    var moved = new List<string>();
                    var movedDirectories = new List<(string OldPath, string NewPath)>();
                    try
                    {
                        RunDirectoryOperation(() =>
                        {
                            try
                            {
                                SutShell.MoveWithDirectoryChanges(MoveWorkflowState.Shared.PreparedPaths, CurrentPath, owner, moved, movedDirectories);
                                MoveWorkflowState.Shared.CompleteExecute();
                            }
                            finally
                            {
                                foreach (var (oldPath, newPath) in movedDirectories)
                                    DirectoryRenamed?.Invoke(oldPath, newPath);
                            }
                        });
                    }
                    finally
                    {
                        RevealInsertedItems(moved);
                    }
                    break;
                case "MoveAbort":
                    MoveWorkflowState.Shared.Abort();
                    break;
                case "NameClipboardCopy":
                    if (selectedPaths.Count == 0)
                        throw new InvalidOperationException("Select one or more items before using Name clipboard copy.");
                    Clipboard.SetText(string.Join(Environment.NewLine, selectedPaths.Select(SutShell.GetFileSystemName)));
                    break;
                case "PathClipboardCopy":
                    if (selectedPaths.Count == 0)
                        throw new InvalidOperationException("Select one or more items before using Path clipboard copy.");
                    Clipboard.SetText(string.Join(Environment.NewLine, selectedPaths));
                    break;
                case "Delete":
                    try { SutShell.Delete(selectedPaths, owner); }
                    finally { Refresh(true); }
                    break;
            }
        }
        catch (OperationCanceledException) when (action == "Delete")
        {
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Operation failed",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void FileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _contextMenu.Reset();
        if (!_restoringSelection)
        {
            _revealedPath = null;
            _selectedPaths.Clear();
            _selectedPaths.UnionWith(FileList.SelectedItems.OfType<DirectoryRow>().Select(row => row.FullPath));
        }
        UpdateToolbarOperationButtons();
    }

    private void WorkflowState_Changed(object? sender, EventArgs e) => UpdateToolbarOperationButtons();

    private void UpdateToolbarOperationButtons()
    {
        var selectedRows = FileList.SelectedItems.OfType<DirectoryRow>().ToArray();
        var hasSelection = selectedRows.Length > 0 && selectedRows.All(row => row.Entry is not null);
        NewButton.IsEnabled = Directory.Exists(CurrentPath);
        PropertiesButton.IsEnabled = hasSelection;
        RenameButton.IsEnabled = hasSelection && selectedRows.Length == 1 &&
                     SutShell.GetEditName(selectedRows[0].FullPath) is not null;
        NameClipboardCopyButton.IsEnabled = PathClipboardCopyButton.IsEnabled = hasSelection;
        ItemClipboardCopyButton.IsEnabled = hasSelection;
        UpdateClipboardButton();
        var linkPrepared = LinkWorkflowState.Shared.IsPrepared;
        var copyPrepared = CopyWorkflowState.Shared.IsPrepared;
        var movePrepared = MoveWorkflowState.Shared.IsPrepared;
        var canStartOperation = !linkPrepared && !copyPrepared && !movePrepared;
        DeleteButton.IsEnabled = hasSelection && canStartOperation && selectedRows.All(row => ShellFileOperations.CanDelete(row.FullPath));
        LinkMarkItemButton.IsEnabled = hasSelection && canStartOperation;
        LinkExecuteButton.IsEnabled = linkPrepared;
        LinkAbortButton.IsEnabled = linkPrepared;
        CopyMarkItemButton.IsEnabled = hasSelection && canStartOperation;
        CopyExecuteButton.IsEnabled = copyPrepared;
        CopyAbortButton.IsEnabled = copyPrepared;
        MoveMarkItemButton.IsEnabled = hasSelection && canStartOperation;
        MoveExecuteButton.IsEnabled = movePrepared;
        MoveAbortButton.IsEnabled = movePrepared;
    }

    private void UpdateClipboardButton() =>
        ItemClipboardPasteButton.IsEnabled = Directory.Exists(CurrentPath) && SutShell.ClipboardContainsItems();

    private void FileList_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateColumnWidths();
    }

    private void RowToolTip_Opening(object sender, ToolTipEventArgs e)
    {
        if (sender is not Grid { ToolTip: ToolTip tooltip } row ||
            FindVisualChild<GridViewRowPresenter>(row) is not { } presenter ||
            FileList.View is not GridView gridView)
            return;

        var index = gridView.Columns.IndexOf(NameColumn);
        if (index < 0 || index >= VisualTreeHelper.GetChildrenCount(presenter) ||
            FindVisualChild<TextBlock>(VisualTreeHelper.GetChild(presenter, index)) is not { } name)
            return;

        ToolTipService.SetPlacementTarget(row, name);
        UpdateRowToolTipPlacement(row, tooltip);
    }

    private void RowToolTip_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is Grid { ToolTip: ToolTip { IsOpen: true } tooltip } row)
            UpdateRowToolTipPlacement(row, tooltip);
    }

    private static void UpdateRowToolTipPlacement(Grid row, ToolTip tooltip)
    {
        if (ToolTipService.GetPlacementTarget(row) is not FrameworkElement name ||
            FindAncestor<ScrollContentPresenter>(row) is not { } viewport)
            return;

        var nameInViewport = name.TranslatePoint(new Point(), viewport);
        var nameInRow = name.TranslatePoint(new Point(), row);
        tooltip.MaxWidth = Math.Max(1, viewport.ActualWidth - nameInViewport.X);
        tooltip.VerticalOffset = row.ActualHeight - nameInRow.Y - name.ActualHeight;
    }

    private void UpdateColumnWidths()
    {
        if (_updatingColumnWidths || FileList.View is not GridView gridView)
            return;
        var scrollViewer = FindVisualChild<ScrollViewer>(FileList);
        _updatingColumnWidths = true;
        try
        {
            if (scrollViewer is { ViewportWidth: > 0 })
            {
                if (Math.Abs(scrollViewer.ViewportWidth - _lastColumnViewportWidth) > 0.01)
                {
                    _showRightColumnsDespiteNarrowViewport = false;
                    _lastColumnViewportWidth = scrollViewer.ViewportWidth;
                }
                var leftWidth = gridView.Columns.Where(column => column != NameColumn && column != TypeApp2Name &&
                    column != SizeColumn && column != DateColumn).Sum(column => column.Width);
                var normalPairWidth = Math.Max(0, scrollViewer.ViewportWidth - leftWidth - SizeColumn.Width - DateColumn.Width);
                var minimumType = Math.Min(40, normalPairWidth / 2);
                var normalTypeWidth = Math.Clamp(_preferredTypeWidth, minimumType, normalPairWidth - minimumType);
                _automaticallyHideRightColumns = normalPairWidth - normalTypeWidth < MinimumNameColumnWidth;
            }
            SetRightColumnsHidden(gridView, _manuallyHideRightColumns ||
                (_automaticallyHideRightColumns && !_showRightColumnsDespiteNarrowViewport));
            if (scrollViewer is null || scrollViewer.ViewportWidth <= 0)
                return;

            var fixedColumnWidths = gridView.Columns.Where(column => column != NameColumn && column != TypeApp2Name).Sum(column => column.Width);
            _nameTypeWidth = Math.Max(0, scrollViewer.ViewportWidth - fixedColumnWidths);
            var minimum = Math.Min(40, _nameTypeWidth / 2);
            var typeWidth = _rightColumnsHidden ? 0 : Math.Clamp(_preferredTypeWidth, minimum, _nameTypeWidth - minimum);
            NameColumn.Width = _nameTypeWidth - typeWidth;
            if (!_rightColumnsHidden) TypeApp2Name.Width = typeWidth;
        }
        finally { _updatingColumnWidths = false; }
    }

    private void NameColumn_WidthChanged(object? sender, EventArgs e)
    {
        if (_updatingColumnWidths || _nameTypeWidth <= 0 || !double.IsFinite(NameColumn.Width))
            return;
        if (_rightColumnsHidden)
        {
            UpdateColumnWidths();
            return;
        }
        var minimumType = Math.Min(40, _nameTypeWidth / 2);
        var minimumName = Math.Min(MinimumNameColumnWidth, _nameTypeWidth - minimumType);
        var nameWidth = Math.Clamp(NameColumn.Width, minimumName, _nameTypeWidth - minimumType);
        _preferredTypeWidth = _nameTypeWidth - nameWidth;
        _updatingColumnWidths = true;
        try
        {
            NameColumn.Width = nameWidth;
            TypeApp2Name.Width = _preferredTypeWidth;
        }
        finally { _updatingColumnWidths = false; }
    }

    private void FileList_HeaderLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is GridViewColumnHeader header &&
            header.Template.FindName("PART_HeaderGripper", header) is Thumb gripper)
        {
            gripper.IsEnabled = ReferenceEquals(header.Column, NameColumn) && !_rightColumnsHidden;
            gripper.IsHitTestVisible = ReferenceEquals(header.Column, NameColumn);
            if (ReferenceEquals(header.Column, NameColumn))
                gripper.RenderTransform = new TranslateTransform(-8, 0);
        }
    }

    private void RightColumnsToggle_Click(object sender, RoutedEventArgs e)
    {
        _manuallyHideRightColumns = !_rightColumnsHidden;
        _showRightColumnsDespiteNarrowViewport = _rightColumnsHidden && _automaticallyHideRightColumns;
        UpdateColumnWidths();
        e.Handled = true;
    }

    private void SetRightColumnsHidden(GridView gridView, bool hidden)
    {
        if (_rightColumnsHidden == hidden)
            return;
        _rightColumnsHidden = hidden;
        RightColumnsToggleSymbol.Text = hidden ? "\u2026" : "\u25B8";
        RightColumnsToggleHeader.ToolTip = hidden ? "Show right columns" : "Hide right columns";
        System.Windows.Automation.AutomationProperties.SetName(RightColumnsToggleHeader,
            hidden ? "Show right columns" : "Hide right columns");
        if (hidden)
        {
            gridView.Columns.Remove(TypeApp2Name);
            gridView.Columns.Remove(SizeColumn);
            gridView.Columns.Remove(DateColumn);
        }
        else
        {
            gridView.Columns.Add(TypeApp2Name);
            gridView.Columns.Add(SizeColumn);
            gridView.Columns.Add(DateColumn);
        }
        if (NameColumn.Header is GridViewColumnHeader header &&
            header.Template?.FindName("PART_HeaderGripper", header) is Thumb gripper)
            gripper.IsEnabled = !hidden;
    }

    private void FileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_editingRow is not null || FileList.SelectedItem is not DirectoryRow { Entry: { } entry })
            return;

        try
        {
            var directoryTarget = SutShell.GetDirectoryTarget(entry.FullPath);
            if (directoryTarget is not null)
                DirectoryOpenRequested?.Invoke(this, directoryTarget);
            else
                SutShell.Open(entry.FullPath);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot open item", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ShowMenu(DirectoryRow? row) => ShowMenuCore(row, alternate: false);

    private void ShowMenuCore(DirectoryRow? row, bool alternate)
    {
        try
        {
            _contextMenu.Show(row, new WindowInteropHelper(Window.GetWindow(this)!).Handle, alternate);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Context menu failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void FileList_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        if (FindAncestor<ListViewItem>(source) is { DataContext: DirectoryRow row })
        {
            if (!FileList.SelectedItems.Contains(row) || _contextMenu.IsDifferentTarget(row))
            {
                FileList.SelectedItems.Clear();
                FileList.SelectedItems.Add(row);
            }
            ShowMenuCore(row, alternate: true);
            e.Handled = true;
            return;
        }

        if (IsListChrome(source))
            return;

        FileList.SelectedItems.Clear();
        ShowMenuCore(null, alternate: true);
        e.Handled = true;
    }

    private void FileList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        if (FindAncestor<Thumb>(source) is not null &&
            FindAncestor<GridViewColumnHeader>(source) is { } header &&
            (!ReferenceEquals(header.Column, NameColumn) || _rightColumnsHidden || e.ClickCount > 1))
        {
            e.Handled = true;
            return;
        }

        if (FindAncestor<ListViewItem>(source) is { DataContext: DirectoryRow row } && _editingRow is null)
        {
            _dragSource.Begin(row, e.GetPosition(FileList));
            _preserveDragSelection = false;
            _toggleDragSelection = false;
            if (FileList.SelectedItems.Count > 1 && FileList.SelectedItems.Contains(row) &&
                (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
            {
                _preserveDragSelection = true;
                _toggleDragSelection = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
                e.Handled = true;
            }
        }
        else if (FindAncestor<ListViewItem>(source) is null && !IsListChrome(source))
            FileList.SelectedItems.Clear();
    }

    private void ClearDragStart()
    {
        _dragSource.Cancel();
        _preserveDragSelection = false;
        _toggleDragSelection = false;
    }

    private void FileList_PreviewMouseButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_dragSource.Item is not { } row) return;
        var preserveSelection = _preserveDragSelection;
        var toggleSelection = _toggleDragSelection;
        ClearDragStart();
        if (preserveSelection)
        {
            if (toggleSelection) FileList.SelectedItems.Remove(row);
            else
            {
                FileList.SelectedItems.Clear();
                FileList.SelectedItems.Add(row);
            }
            e.Handled = true;
        }
    }

    private void FileList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.F2 && _editingRow is null)
        {
            BeginRename();
            e.Handled = true;
            return;
        }
        if (e.Key != Key.Apps && !(e.Key == Key.F10 && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            return;

        ShowMenu(FileList.SelectedItem as DirectoryRow);
        e.Handled = true;
    }

    private void BeginRename()
    {
        if (_editingRow is not null || FileList.SelectedItems.Count != 1 ||
            FileList.SelectedItem is not DirectoryRow { Entry: not null } row ||
            SutShell.GetEditName(row.FullPath) is not { } name)
            return;

        _editingRow = row;
        row.EditName = name;
        row.IsEditing = true;
        FileList.ScrollIntoView(row);
    }

    private void ItemNameEditor_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is not TextBox { IsVisible: true, DataContext: DirectoryRow row } editor)
            return;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
        {
            if (!editor.IsVisible || !ReferenceEquals(row, _editingRow))
                return;
            editor.Focus();
            var extension = row.Entry?.IsDirectory == false ? Path.GetExtension(row.EditName) : string.Empty;
            var selectionLength = row.EditName.Length - extension.Length;
            editor.Select(0, selectionLength > 0 ? selectionLength : row.EditName.Length);
        }));
    }

    private void ItemNameEditor_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is Key.Enter or Key.Escape)
        {
            EndRename(commit: e.Key == Key.Enter);
            e.Handled = true;
        }
    }

    private void ItemNameEditor_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (sender is TextBox { DataContext: DirectoryRow row } && ReferenceEquals(row, _editingRow))
            EndRename(commit: true);
    }

    private void EndRename(bool commit)
    {
        if (_editingRow is not { Entry: { } entry } row || _endingRename)
            return;

        _endingRename = true;
        var renamed = false;
        try
        {
            if (commit && !string.Equals(row.EditName, SutShell.GetEditName(row.FullPath), StringComparison.Ordinal))
            {
                var owner = Window.GetWindow(this) is { } window ? new WindowInteropHelper(window).Handle : IntPtr.Zero;
                void RenameItem()
                {
                    var oldPath = row.FullPath;
                    var newPath = SutShell.Rename(oldPath, row.EditName, owner);
                    _selectedPaths.Remove(oldPath);
                    _selectedPaths.Add(newPath);
                    renamed = true;
                    if (entry.IsDirectory)
                        DirectoryRenamed?.Invoke(oldPath, newPath);
                }
                if (entry.IsDirectory)
                    RunDirectoryOperation(RenameItem);
                else
                    RenameItem();
            }
            _editingRow = null;
            row.IsEditing = false;
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(this), exception.Message, "Cannot rename item", MessageBoxButton.OK, MessageBoxImage.Error);
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
            {
                if (FileList.ItemContainerGenerator.ContainerFromItem(row) is DependencyObject container &&
                    FindVisualChild<TextBox>(container) is { } editor)
                    editor.Focus();
            }));
            return;
        }
        finally
        {
            _endingRename = false;
        }

        if (renamed || _deferredRefresh)
        {
            _deferredRefresh = false;
            RefreshCore(invalidate: renamed);
        }
        _ = ProcessFileSystemChangesAsync();
    }
}

internal sealed class DirectoryRow : INotifyPropertyChanged
{
    public DirectoryRow() : this(string.Empty) { }
    internal DirectoryRow(string fullPath) => FullPath = fullPath;
    public string FullPath { get; private set; }
    public string DisplayName => Entry?.Name ?? Path.GetFileName(FullPath);
    private FileEntry? _entry;
    private ShellIconSet? _overlayIcons;
    private bool _isEditing;
    private string _editName = string.Empty;
    public FileEntry? Entry
    {
        get => _entry;
        set
        {
            _entry = WithOverlay(value, _overlayIcons);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Entry)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayName)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(OverlayIcon)));
        }
    }
    public ImageSource? OverlayIcon => _overlayIcons is null ? _entry?.Icons?.OverlayIcon : _overlayIcons.OverlayIcon;

    internal void UpdateOverlay(ShellIconSet icons)
    {
        var oldOverlay = OverlayIcon;
        _overlayIcons = icons;
        _entry = WithOverlay(_entry, icons);
        if (!ReferenceEquals(oldOverlay, OverlayIcon))
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(OverlayIcon)));
    }

    private static FileEntry? WithOverlay(FileEntry? entry, ShellIconSet? overlay)
    {
        if (entry?.Icons is not { } icons || overlay is null ||
            (ReferenceEquals(icons.OverlayIcon, overlay.OverlayIcon) && icons.OverlaySlot == overlay.OverlaySlot &&
             icons.OverlayKnown == overlay.OverlayKnown && icons.MayHaveOverlay == overlay.MayHaveOverlay))
            return entry;
        return entry with { Icons = icons with { OverlayIcon = overlay.OverlayIcon, OverlaySlot = overlay.OverlaySlot,
            OverlayKnown = overlay.OverlayKnown, MayHaveOverlay = overlay.MayHaveOverlay } };
    }
    internal bool Failed { get; set; }
    public bool IsEditing
    {
        get => _isEditing;
        set
        {
            _isEditing = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEditing)));
        }
    }
    public string EditName
    {
        get => _editName;
        set
        {
            _editName = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EditName)));
        }
    }
    public event PropertyChangedEventHandler? PropertyChanged;

    internal void ApplyRename(string oldPath, string newPath, FileEntry? entry)
    {
        FullPath = ShellLocations.RemapPath(FullPath, oldPath, newPath);
        _overlayIcons = null;
        Failed = false;
        Entry = entry;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullPath)));
    }

    internal void RemapPath(string oldPath, string newPath)
    {
        FullPath = ShellLocations.RemapPath(FullPath, oldPath, newPath);
        if (Entry is not null)
            Entry = Entry with { FullPath = FullPath };
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullPath)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayName)));
    }
}