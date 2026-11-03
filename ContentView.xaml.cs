using System.Diagnostics;
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
    private CancellationTokenSource? _refreshCancellation;
    private CancellationTokenSource? _rangeCancellation;
    private DirectorySnapshot? _snapshot;
    private DirectoryRow[]? _rows;
    private readonly DirectorySortState _sorting = new();
    private readonly DirectoryDataCache _directoryCache = new();
    private readonly HashSet<string> _selectedPaths = new(StringComparer.OrdinalIgnoreCase);
    private bool _restoringSelection;
    private DirectoryRow? _editingRow;
    private bool _endingRename;
    private bool _deferredRefresh;
    private int _nextBackgroundIndex;
    private bool _loadingRange;
    private bool _loadScheduled;
    private readonly SutContextMenuController<DirectoryRow> _contextMenu;

    public ContentView()
    {
        InitializeComponent();
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
            (row, paths) => SutShell.ShowItemMenu(paths, new WindowInteropHelper(Window.GetWindow(this)!).Handle,
                paths.Count == 1 && row.Entry is not null && SutShell.GetEditName(row.FullPath) is not null ? BeginRename : null),
            () => SutShell.ShowBackgroundMenu(CurrentPath, new WindowInteropHelper(Window.GetWindow(this)!).Handle),
            () => CurrentPath, CreateContextMenuActions);
        HideDirectoriesCheckBox.GetCheckBox().Checked += FiltersChanged;
        HideDirectoriesCheckBox.GetCheckBox().Unchecked += FiltersChanged;
        HideInternalContentCheckBox.GetCheckBox().Checked += FiltersChanged;
        HideInternalContentCheckBox.GetCheckBox().Unchecked += FiltersChanged;
        FileList.LayoutUpdated += FileList_LayoutUpdated;
        FileList.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(FileList_ScrollChanged));
        Loaded += ContentView_Loaded;
        Unloaded += ContentView_Unloaded;
    }

    private IReadOnlyList<ShellMenuAction> CreateContextMenuActions() =>
        new[] { RenameButton, PathGetButton, CopyGetButton, CopyAbortButton, CopyPasteButton,
            MoveGetButton, MoveAbortButton, MovePasteButton, DeleteButton }.Select(button => new ShellMenuAction(
                System.Windows.Automation.AutomationProperties.GetName(button), button.IsEnabled,
                () => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)))).ToArray();

    internal bool FocusContent() => FileList.Focus();
    internal bool? HideInternalItems
    {
        get => HideInternalContentCheckBox.GetCheckBox().IsChecked;
        set => HideInternalContentCheckBox.GetCheckBox().IsChecked = value;
    }

    private string CurrentPath { get; set; } = string.Empty;
    internal event EventHandler<string>? FolderOpenRequested;
    internal event Action<string, string>? FolderRenamed;
    internal event EventHandler? FileSystemChanged;

    internal void Initialize(bool isBrowsable)
    {
        if (_initialized)
            throw new InvalidOperationException("The content view is already initialized.");
        _initialized = true;
    }

    internal void SetCurrentPath(string path)
    {
        EndRename(commit: false);
        _directoryCache.Invalidate();
        _deferredRefresh = false;
        _refreshCancellation?.Cancel();
        _rangeCancellation?.Cancel();
        _snapshot = null;
        _rows = null;
        _selectedPaths.Clear();
        CurrentPath = path;
        ClearRows();
        StatusLabel.Text = string.Empty;
    }

    internal void EnsureLocationAccessible(string path) => SutShell.EnsureDirectoryAccessible(path);

    internal void Refresh(bool refreshView) => RefreshCore(invalidate: true);

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
        _snapshot = null;
        _rows = null;
        ClearRows();
        var cancellation = new CancellationTokenSource();
        _refreshCancellation = cancellation;
        var path = CurrentPath;
        var showDirectories = HideDirectoriesCheckBox.GetCheckBox().IsChecked != true;
        var hideInternal = HideInternalContentCheckBox.GetCheckBox().IsChecked == true;
        var namePattern = NamePatternTextBox.Text;
        StatusLabel.Text = "Loading...";
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
                FileList.ItemsSource = _rows;
                foreach (var row in _rows)
                    if (_selectedPaths.Contains(row.FullPath))
                        FileList.SelectedItems.Add(row);
                _selectedPaths.IntersectWith(_rows.Select(row => row.FullPath));
            }
            finally
            {
                _restoringSelection = false;
            }
            UpdateToolbarOperationButtons();
            StatusLabel.Text = $"{snapshot.Count} items";
            ScheduleRangeLoad();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (ReferenceEquals(_refreshCancellation, cancellation))
            {
                FileList.ItemsSource = null;
                StatusLabel.Text = exception.Message;
            }
        }
        finally
        {
            if (ReferenceEquals(_refreshCancellation, cancellation))
                _refreshCancellation = null;
            cancellation.Dispose();
        }
    }

    private void ClearRows()
    {
        _restoringSelection = true;
        try
        {
            FileList.ItemsSource = null;
        }
        finally
        {
            _restoringSelection = false;
        }
        UpdateToolbarOperationButtons();
    }

    internal void SetObservedDirectories(IEnumerable<string> directories)
    {
        ClearObservedDirectories();
        _directoryObserver = SutShell.ObserveDirectories(directories, () =>
        {
            if (!Dispatcher.HasShutdownStarted)
                _ = Dispatcher.BeginInvoke(() => FileSystemChanged?.Invoke(this, EventArgs.Empty));
        });
    }

    internal void ClearObservedDirectories()
    {
        _directoryObserver?.Dispose();
        _directoryObserver = null;
    }

    private void ContentView_Loaded(object sender, RoutedEventArgs e)
    {
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
        CopyWorkflowState.Shared.Changed += WorkflowState_Changed;
        MoveWorkflowState.Shared.Changed += WorkflowState_Changed;
        UpdateToolbarOperationButtons();
    }

    private void ContentView_Unloaded(object sender, RoutedEventArgs e)
    {
        _rangeCancellation?.Cancel();
        CopyWorkflowState.Shared.Changed -= WorkflowState_Changed;
        MoveWorkflowState.Shared.Changed -= WorkflowState_Changed;
    }

    private void FiltersChanged(object sender, RoutedEventArgs e) => RefreshCore(invalidate: false);

    private void FileList_ColumnHeaderClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not GridViewColumnHeader { Tag: string tag } ||
            !Enum.TryParse<DirectorySortColumn>(tag, out var column))
            return;

        var current = _sorting.Pairs.FirstOrDefault();
        var criterion = _sorting.Pairs.Count > 0 && current.Column == column && current.Criterion == DirectorySortCriterion.Ascending
            ? DirectorySortCriterion.Descending : DirectorySortCriterion.Ascending;
        _sorting.Update([new DirectorySortPair(column, criterion)]);
        foreach (var (indicator, indicatorColumn) in new[]
        {
            (NameSortIndicator, DirectorySortColumn.Name), (TypeSortIndicator, DirectorySortColumn.Type),
            (SizeSortIndicator, DirectorySortColumn.Size), (DateSortIndicator, DirectorySortColumn.DateModified),
            (MediaTypeSortIndicator, DirectorySortColumn.MediaType), (IconSortIndicator, DirectorySortColumn.ShellIcon),
            (OverlaySortIndicator, DirectorySortColumn.Overlay)
        })
        {
            indicator.Visibility = indicatorColumn == column ? Visibility.Visible : Visibility.Collapsed;
            indicator.Text = criterion == DirectorySortCriterion.Ascending ? "\u25B2" : "\u25BC";
        }
        RefreshCore(invalidate: false);
    }

    private void FileList_LayoutUpdated(object? sender, EventArgs e) => ScheduleRangeLoad();

    private void FileList_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.VerticalChange != 0)
            _rangeCancellation?.Cancel();
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
                StatusLabel.Text = $"{snapshot.Count} items (some could not be loaded)";
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

    private void NamePatternTextBox_TextChanged(object sender, TextChangedEventArgs e) => RefreshCore(invalidate: false);

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
                    var point = NewButton.PointToScreen(new Point(0, NewButton.ActualHeight));
                    SutShell.ShowNewMenu(CurrentPath, owner, (int)point.X, (int)point.Y);
                    break;
                case "Properties":
                    if (selectedPaths.Count != 1)
                        throw new InvalidOperationException("Select exactly one item before using Properties.");
                    SutShell.ShowProperties(selectedPaths[0], owner);
                    break;
                case "Rename":
                    BeginRename();
                    break;
                case "CopyGet":
                    if (MoveWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Move before starting a Copy.");
                    CopyWorkflowState.Shared.Prepare(selectedPaths);
                    break;
                case "CopyPaste":
                    SutShell.Copy(CopyWorkflowState.Shared.PreparedPaths, CurrentPath, owner);
                    CopyWorkflowState.Shared.CompletePaste();
                    Refresh(true);
                    break;
                case "CopyAbort":
                    CopyWorkflowState.Shared.Abort();
                    break;
                case "MoveGet":
                    if (CopyWorkflowState.Shared.IsPrepared)
                        throw new InvalidOperationException("Abort or complete the prepared Copy before starting a Move.");
                    MoveWorkflowState.Shared.Prepare(selectedPaths);
                    break;
                case "MovePaste":
                    SutShell.Move(MoveWorkflowState.Shared.PreparedPaths, CurrentPath, owner);
                    MoveWorkflowState.Shared.CompletePaste();
                    Refresh(true);
                    break;
                case "MoveAbort":
                    MoveWorkflowState.Shared.Abort();
                    break;
                case "PathGet":
                    if (selectedPaths.Count != 1)
                        throw new InvalidOperationException("Select exactly one item before using Path get.");
                    Clipboard.SetText(selectedPaths[0]);
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
        PropertiesButton.IsEnabled = hasSelection && selectedRows.Length == 1;
        RenameButton.IsEnabled = hasSelection && selectedRows.Length == 1 &&
                     SutShell.GetEditName(selectedRows[0].FullPath) is not null;
        PathGetButton.IsEnabled = hasSelection && FileList.SelectedItems.Count == 1;
        var copyPrepared = CopyWorkflowState.Shared.IsPrepared;
        var movePrepared = MoveWorkflowState.Shared.IsPrepared;
        var canStartOperation = !copyPrepared && !movePrepared;
        DeleteButton.IsEnabled = hasSelection && canStartOperation && selectedRows.All(row => ShellFileOperations.CanDelete(row.FullPath));
        CopyGetButton.IsEnabled = hasSelection && canStartOperation;
        CopyPasteButton.IsEnabled = copyPrepared;
        CopyAbortButton.IsEnabled = copyPrepared;
        MoveGetButton.IsEnabled = hasSelection && canStartOperation;
        MovePasteButton.IsEnabled = movePrepared;
        MoveAbortButton.IsEnabled = movePrepared;
    }

    private void FileList_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (FileList.View is not GridView gridView || gridView.Columns.Count < 7)
            return;

        var fixedColumnWidths = 42 + 34 + 26 + 130 + SizeColumn.Width + DateColumn.Width;
        const double minimumNameWidth = 80;
        var scrollViewer = FindVisualChild<ScrollViewer>(FileList);
        var scrollbarWidth = scrollViewer?.ComputedVerticalScrollBarVisibility == Visibility.Visible
            ? SystemParameters.VerticalScrollBarWidth : 0;
        var availableNameWidth = FileList.ActualWidth - fixedColumnWidths - scrollbarWidth - 8;
        gridView.Columns[3].Width = Math.Max(minimumNameWidth, availableNameWidth);
    }

    private void FileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_editingRow is not null || FileList.SelectedItem is not DirectoryRow { Entry: { } entry })
            return;

        try
        {
            var folderTarget = SutShell.GetFolderTarget(entry.FullPath);
            if (folderTarget is not null)
                FolderOpenRequested?.Invoke(this, folderTarget);
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
            (ReferenceEquals(header.Column, SizeColumn) || ReferenceEquals(header.Column, DateColumn)))
        {
            e.Handled = true;
            return;
        }

        if (FindAncestor<ListViewItem>(source) is null && !IsListChrome(source))
            FileList.SelectedItems.Clear();
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
                var newPath = SutShell.Rename(row.FullPath, row.EditName, owner);
                _selectedPaths.Remove(row.FullPath);
                _selectedPaths.Add(newPath);
                renamed = true;
                if (entry.IsDirectory)
                    FolderRenamed?.Invoke(row.FullPath, newPath);
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
    }
}

internal sealed class DirectoryRow : INotifyPropertyChanged
{
    public DirectoryRow() : this(string.Empty) { }
    internal DirectoryRow(string fullPath) => FullPath = fullPath;
    internal string FullPath { get; }
    private FileEntry? _entry;
    private bool _isEditing;
    private string _editName = string.Empty;
    public FileEntry? Entry
    {
        get => _entry;
        set
        {
            _entry = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Entry)));
        }
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
}