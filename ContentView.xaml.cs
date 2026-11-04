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
    private ClipboardChangeMonitor? _clipboardMonitor;
    private CancellationTokenSource? _refreshCancellation;
    private CancellationTokenSource? _rangeCancellation;
    private DirectorySnapshot? _snapshot;
    private DirectoryRow[]? _rows;
    private readonly DirectorySortState _sorting = new();
    private readonly DirectoryDataCache _directoryCache = new();
    private readonly HashSet<string> _selectedPaths = new(StringComparer.OrdinalIgnoreCase);
    private bool _restoringSelection;
    private bool _suppressFilterRefresh;
    private string? _revealedPath;
    private DirectoryRow? _editingRow;
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
        DirectorySortColumn.TypeApp2Name, DirectorySortColumn.DateModified, DirectorySortColumn.Size,
        DirectorySortColumn.Overlay
    ];

    public ContentView()
    {
        InitializeComponent();
        SortOrderEditor.Configure(["Name", "MT", "TA1", "TA2", "Date", "Size", "MO"]);
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
            ShowNewItemDialog, CreateOpenLocationAction);
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
        new[] { PropertiesButton, NameClipboardCopyButton, PathClipboardCopyButton, ItemClipboardCopyButton, ItemClipboardPasteButton, LinkMarkItemButton, LinkAbortButton, LinkExecuteButton, CopyMarkItemButton, CopyAbortButton, CopyExecuteButton,
            MoveMarkItemButton, MoveAbortButton, MoveExecuteButton, RenameButton, DeleteButton }.Select(button => new ShellMenuAction(
                (string)button.Tag, System.Windows.Automation.AutomationProperties.GetName(button), button.IsEnabled,
                () => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)),
                IsTransfer: button.Tag is string action && (action.StartsWith("Link", StringComparison.Ordinal) || action.StartsWith("Copy", StringComparison.Ordinal) || action.StartsWith("Move", StringComparison.Ordinal)),
                SeparatorBefore: button == NameClipboardCopyButton || button == ItemClipboardPasteButton || button == DeleteButton) { IconSource = button }).ToArray();

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
                    throw new InvalidOperationException("The shortcut target does not have a containing folder.");
                FolderOpenRequested?.Invoke(this, directory);
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
        _revealedPath = null;
        CurrentPath = path;
        ClearRows();
        DirectoryCountLabel.Text = "-";
        FileCountLabel.Text = "-";
        StatusLabel.Text = string.Empty;
        StatusLabel.ToolTip = null;
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
                FileList.ItemsSource = _rows;
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
        RefreshCore(invalidate: false);
    }

    private void UpdateSortDisplay()
    {
        var pairs = _sorting.Pairs;
        var primary = pairs[0];
        foreach (var (indicator, indicatorColumn) in new[]
        {
            (NameSortIndicator, DirectorySortColumn.Name), (TypeApp2NameSortIndicator, DirectorySortColumn.TypeApp2Name),
            (SizeSortIndicator, DirectorySortColumn.Size), (DateSortIndicator, DirectorySortColumn.DateModified),
            (MediaTypeIconSortIndicator, DirectorySortColumn.MediaTypeIcon), (TypeApp1IconSortIndicator, DirectorySortColumn.TypeApp1Icon),
            (OverlaySortIndicator, DirectorySortColumn.Overlay)
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
                    SutShell.PasteFromClipboard(CurrentPath, owner);
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
                    try
                    {
                        SutShell.Move(MoveWorkflowState.Shared.PreparedPaths, CurrentPath, owner, moved);
                        MoveWorkflowState.Shared.CompleteExecute();
                    }
                    finally { RevealInsertedItems(moved); }
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
            (!ReferenceEquals(header.Column, NameColumn) || _rightColumnsHidden || e.ClickCount > 1))
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