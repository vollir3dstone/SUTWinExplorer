using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace SUTWinExplorer;

public partial class MainWindow : Window
{
    private const int MaxDisplayedPathLength = 40;
    private const string DisplayEllipsis = "…";
    private static readonly string DisplayPathSeparator = Path.DirectorySeparatorChar.ToString();
    private static readonly string DefaultTabLabelPrefix = DisplayEllipsis + DisplayPathSeparator;
    private bool _updatingPathChoices;
    private bool _selectingHistoryTab;
    private Pathview? _browsablePathview;
    private TabItem? _browsableTab;
    private readonly Dictionary<string, Pathview> _fixedPathviewsByPath = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Pathview, string> _pathsByFixedPathview = new();
    private readonly Dictionary<Pathview, TabItem> _tabsByPathview = new();
    private ShellCopyIntegration? _shellCopyIntegration;

    public MainWindow()
    {
        InitializeComponent();
        SourceInitialized += MainWindow_SourceInitialized;
        Closed += MainWindow_Closed;
        AddPaneview(GetInitialDirectory(), isBrowsable: true);
    }

    private static string GetInitialDirectory()
    {
        var arguments = Environment.GetCommandLineArgs();
        if (arguments.Length == 2)
            return arguments[1].Trim().Trim('\"');

        return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private void MainWindow_SourceInitialized(object? sender, EventArgs e)
    {
        var windowHandle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        try
        {
            _shellCopyIntegration = new ShellCopyIntegration(windowHandle, HandleExternalShellCopy);
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"Optional Shell Copy integration unavailable: {exception}");
        }
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        _shellCopyIntegration?.Dispose();
        _shellCopyIntegration = null;
    }

    internal void InvokeToolbarShellCopy(ShellExplorerBrowserHost? shellHost)
    {
        if (shellHost is not null)
            _shellCopyIntegration?.InvokeToolbarCopy(shellHost.InvokeShellCopyCommand);
    }

    private void HandleExternalShellCopy(IReadOnlyList<string> copiedPaths)
    {
        if (MoveWorkflowState.Shared.IsPrepared)
            MoveWorkflowState.Shared.Abort();

        _ = CopyWorkflowState.Shared.TryPrepareFromShell(copiedPaths);
    }

    private Pathview? CurrentPathview => (ExplorerTabs.SelectedItem as TabItem)?.Content as Pathview;

    internal void SetPathviewTabBackground(Pathview view, Brush background)
    {
        if (_tabsByPathview.TryGetValue(view, out var tab))
        {
            tab.Background = background;
            TabItemChrome.SetSelectedBackground(tab, background);
        }
    }

    private void AddPaneview(string path, bool isBrowsable)
    {
        var pathKey = GetPathKey(path);
        if (!isBrowsable && _fixedPathviewsByPath.TryGetValue(pathKey, out var existingPathview))
        {
            SelectPathviewTab(existingPathview);
            return;
        }

        if (isBrowsable != (ExplorerTabs.Items.Count == 0))
            throw new InvalidOperationException("The browsable Pathview must be the first and only browsable tab.");

        var view = new Pathview(path, isBrowsable);
        var hasCurrentPath = !string.IsNullOrWhiteSpace(view.CurrentPath);
        var title = new TextBlock
        {
            Text = view.IsBrowsable
                ? "BROWSE"
                : hasCurrentPath ? GetTabLabelFromPath(view.CurrentPath) : "Loading...",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center
        };
        var tooltipText = new TextBlock
        {
            Text = hasCurrentPath ? ShellDisplayNameProvider.GetDisplayPath(view.CurrentPath) : string.Empty,
            TextWrapping = TextWrapping.NoWrap
        };

        var close = new Button
        {
            Content = "🗙",
            Style = (Style)FindResource("TabCloseButtonStyle"),
            FontSize = 12,
            Padding = new Thickness(0),
            Margin = new Thickness(2, 0, 0, 0),
            RenderTransform = new System.Windows.Media.TranslateTransform(2, -1),
            ToolTip = "Close tab",
            Tag = view,
            Visibility = view.IsBrowsable ? Visibility.Collapsed : Visibility.Visible
        };
        close.Click += CloseTab_Click;

        var headerContent = new Grid();
        headerContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.TextAlignment = TextAlignment.Center;
        Grid.SetColumn(title, 0);
        Grid.SetColumn(close, 1);
        headerContent.Children.Add(title);
        headerContent.Children.Add(close);
        var tab = new TabItem { Header = headerContent, Content = view };
        var pathToolTip = new ToolTip
        {
            Content = tooltipText,
            Placement = PlacementMode.Custom,
            PlacementTarget = tab,
            Padding = new Thickness(8, 5, 8, 5),
            BorderThickness = new Thickness(1)
        };
        pathToolTip.CustomPopupPlacementCallback = (popupSize, targetSize, offset) =>
        {
            var targetOrigin = tab.TranslatePoint(new Point(0, 0), this);
            var margin = 8d;
            var rightEdge = Math.Max(margin, ActualWidth - margin);
            var left = Math.Clamp(targetOrigin.X, margin, Math.Max(margin, rightEdge - popupSize.Width));
            return [new CustomPopupPlacement(
                new Point(left - targetOrigin.X, targetSize.Height + 2),
                PopupPrimaryAxis.Vertical)];
        };
        tab.ToolTip = pathToolTip;
        tab.ToolTipOpening += (_, _) => ConfigurePathToolTip(pathToolTip, tooltipText);
        view.LocationChanged += (_, currentPath) =>
        {
            if (!view.IsBrowsable)
                RegisterFixedPathview(view, currentPath);
            title.Text = view.IsBrowsable ? "BROWSE" : GetTabLabelFromPath(currentPath);
            tooltipText.Text = ShellDisplayNameProvider.GetDisplayPath(currentPath);
            if (view.IsBrowsable)
            {
                if (ReferenceEquals(CurrentPathview, view))
                    UpdateCurrentAddressText();
            }
            else
            {
                if (ReferenceEquals(CurrentPathview, view))
                    _browsablePathview?.RecordVisitedLocation(currentPath);
                RefreshPathChoices();
            }
        };
        view.NavigationFailed += (_, _) =>
        {
            if (!view.IsBrowsable && string.IsNullOrWhiteSpace(view.CurrentPath))
                RemoveFixedPathview(view);
            if (ReferenceEquals(CurrentPathview, view))
                RefreshPathChoices();
        };
        view.PinRequested += Pathview_PinRequested;
        view.BrowseLocationRequested += Pathview_BrowseLocationRequested;
        view.DirectoryRenamed += Pathview_DirectoryRenamed;

        if (view.IsBrowsable)
        {
            _browsablePathview = view;
            _browsableTab = tab;
        }
        else
        {
            RegisterFixedPathview(view, string.IsNullOrWhiteSpace(view.CurrentPath) ? path : view.CurrentPath);
        }
        _tabsByPathview.Add(view, tab);
        ExplorerTabs.Items.Insert(view.IsBrowsable ? 0 : ExplorerTabs.Items.Count, tab);
        tab.MinWidth = GetMinimumTabWidth(title);
        ExplorerTabs.SelectedItem = tab;
        RefreshPathChoices();
    }

    private double GetMinimumTabWidth(TextBlock title)
    {
        var typeface = new Typeface(title.FontFamily, title.FontStyle, title.FontWeight, title.FontStretch);
        var text = new FormattedText(
            new string('n', 16),
            CultureInfo.CurrentCulture,
            title.FlowDirection,
            typeface,
            title.FontSize,
            title.Foreground,
            VisualTreeHelper.GetDpi(title).PixelsPerDip);

        return text.WidthIncludingTrailingWhitespace;
    }

    private void Pathview_PinRequested(object? sender, EventArgs e)
    {
        if (sender is not Pathview { IsBrowsable: true } view || string.IsNullOrWhiteSpace(view.CurrentPath))
            return;

        AddPaneview(view.CurrentPath, isBrowsable: false);
    }

    private void Pathview_DirectoryRenamed(string oldPath, string newPath)
    {
        foreach (var view in _tabsByPathview.Keys.ToArray())
        {
            try
            {
                view.ApplyDirectoryRename(oldPath, newPath);
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, exception.Message, "Cannot update renamed location", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }

    private void Pathview_BrowseLocationRequested(
        Pathview source,
        string path,
        bool? hideSiblings = null,
        bool? hideInternalDirectories = null,
        bool? hideInternalContentItems = null,
        bool? preferFixedView = null)
    {
        if (source.IsBrowsable || string.IsNullOrWhiteSpace(path))
            return;

        ActivatePath(
            path,
            hideSiblings,
            hideInternalDirectories,
            hideInternalContentItems,
            preferFixedView);
    }

    /// <summary>Activates a path, optionally selecting an open fixed view and applying filter settings.</summary>
    /// <param name="path">The destination path to activate.</param>
    /// <param name="hideSiblings">The browsable tree setting; null leaves its current value unchanged.</param>
    /// <param name="hideInternalDirectories">The browsable directory-tree filter; null leaves its current value unchanged.</param>
    /// <param name="hideInternalContentItems">The browsable content-item filter; null leaves its current value unchanged.</param>
    /// <param name="preferFixedView">Null prefers a matching open fixed view; false always navigates the browsable view.</param>
    private void ActivatePath(
        string path,
        bool? hideSiblings = null,
        bool? hideInternalDirectories = null,
        bool? hideInternalContentItems = null,
        bool? preferFixedView = null)
    {
        if (string.IsNullOrWhiteSpace(path) || _browsablePathview is null || _browsableTab is null)
            return;

        try
        {
            if ((preferFixedView ?? true) && TrySelectFixedPathview(path))
                return;

            SelectTabForNavigation(_browsableTab);
            _browsablePathview.Navigate(
                path,
                hideSiblings,
                hideInternalDirectories,
                hideInternalContentItems);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Cannot open location", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private bool TrySelectFixedPathview(string path)
    {
        if (Pathview.IsTopPath(path))
            return false;

        var pathKey = GetPathKey(path);
        if (!_fixedPathviewsByPath.TryGetValue(pathKey, out var fixedView) ||
            string.IsNullOrWhiteSpace(fixedView.CurrentPath) ||
            !string.Equals(GetPathKey(fixedView.CurrentPath), pathKey, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        SelectPathviewTab(fixedView);
        return true;
    }

    private void RegisterFixedPathview(Pathview view, string path)
    {
        var pathKey = GetPathKey(path);
        if (_pathsByFixedPathview.TryGetValue(view, out var previousPathKey) &&
            !string.Equals(previousPathKey, pathKey, StringComparison.OrdinalIgnoreCase))
            _fixedPathviewsByPath.Remove(previousPathKey);

        if (_fixedPathviewsByPath.TryGetValue(pathKey, out var existingPathview) &&
            !ReferenceEquals(existingPathview, view))
            return;

        _fixedPathviewsByPath[pathKey] = view;
        _pathsByFixedPathview[view] = pathKey;
    }

    private void RemoveFixedPathview(Pathview view)
    {
        if (!_pathsByFixedPathview.Remove(view, out var pathKey))
            return;

        if (_fixedPathviewsByPath.TryGetValue(pathKey, out var existingPathview) &&
            ReferenceEquals(existingPathview, view))
            _fixedPathviewsByPath.Remove(pathKey);
    }

    private void SelectPathviewTab(Pathview view)
    {
        if (_tabsByPathview.TryGetValue(view, out var tab))
            ExplorerTabs.SelectedItem = tab;
    }

    private static string GetPathKey(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    private void ConfigurePathToolTip(ToolTip toolTip, TextBlock pathText)
    {
        var margin = 8d;
        var maxWidth = Math.Max(1, ActualWidth - margin * 2);
        var horizontalChrome = toolTip.Padding.Left + toolTip.Padding.Right +
                              toolTip.BorderThickness.Left + toolTip.BorderThickness.Right;

        pathText.TextWrapping = TextWrapping.NoWrap;
        pathText.MaxWidth = double.PositiveInfinity;
        pathText.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var needsWrapping = pathText.DesiredSize.Width + horizontalChrome > maxWidth;

        toolTip.MaxWidth = maxWidth;
        pathText.TextWrapping = needsWrapping ? TextWrapping.Wrap : TextWrapping.NoWrap;
        pathText.MaxWidth = needsWrapping ? Math.Max(1, maxWidth - horizontalChrome) : double.PositiveInfinity;
    }

    private void CloseTab_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerTabs.Items.Count <= 1 || sender is not Button { Tag: Pathview view } || view.IsBrowsable)
            return;

        var tab = ExplorerTabs.Items.Cast<TabItem>().FirstOrDefault(item => ReferenceEquals(item.Content, view));
        if (tab is not null)
        {
            ExplorerTabs.Items.Remove(tab);
            _tabsByPathview.Remove(view);
            RemoveFixedPathview(view);
            RefreshPathChoices();
        }
    }

    private void ExplorerTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_selectingHistoryTab && ReferenceEquals(e.Source, ExplorerTabs) && CurrentPathview is { } view)
            _browsablePathview?.RecordVisitedLocation(view.CurrentPath);
        RefreshPathChoices();
    }

    private void AddressBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingPathChoices || AddressBox.SelectedItem is not TabPathChoice choice)
            return;

        if (choice.TabIndex < 0)
        {
            AddressBox.IsDropDownOpen = false;
            RefreshPathChoices();
            return;
        }

        if (choice.TabIndex < ExplorerTabs.Items.Count)
            ExplorerTabs.SelectedIndex = choice.TabIndex;

        AddressBox.IsDropDownOpen = false;
        RefreshPathChoices();
    }

    private void RefreshPathChoices()
    {
        if (AddressBox is null)
            return;

        var choices = new List<TabPathChoice> { new(-1, string.Empty) };

        _updatingPathChoices = true;
        try
        {
            choices.AddRange(ExplorerTabs.Items.Cast<TabItem>()
                .Select((item, index) => new { View = (Pathview)item.Content, TabIndex = index })
                .Where(entry => !entry.View.IsBrowsable)
                .Select(entry => new TabPathChoice(entry.TabIndex, entry.View.CurrentPath))
                .OrderBy(choice => choice.DisplayPath, StringComparer.OrdinalIgnoreCase));
            AddressBox.ItemsSource = choices;
            AddressBox.SelectedValue = ExplorerTabs.SelectedIndex;
            UpdateCurrentAddressText();
        }
        finally
        {
            _updatingPathChoices = false;
        }
    }

    private void UpdateCurrentAddressText()
    {
        var wasUpdatingPathChoices = _updatingPathChoices;
        _updatingPathChoices = true;
        try
        {
            AddressBox.Text = CurrentPathview is null
                ? string.Empty
                : ShellDisplayNameProvider.GetDisplayPath(CurrentPathview.CurrentPath);
        }
        finally
        {
            _updatingPathChoices = wasUpdatingPathChoices;
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => NavigateHistory(isBack: true);

    private void Forward_Click(object sender, RoutedEventArgs e) => NavigateHistory(isBack: false);

    private void Up_Click(object sender, RoutedEventArgs e) => NavigateBrowsablePathview(pathview => pathview.GoUp());

    private void NavigateHistory(bool isBack)
    {
        if (_browsablePathview is null || _browsableTab is null)
            return;

        var path = isBack ? _browsablePathview.BackHistoryPath : _browsablePathview.ForwardHistoryPath;
        if (path is null)
            return;

        if (!Pathview.IsTopPath(path) &&
            _fixedPathviewsByPath.TryGetValue(GetPathKey(path), out var fixedView) &&
            !string.IsNullOrWhiteSpace(fixedView.CurrentPath) &&
            string.Equals(GetPathKey(fixedView.CurrentPath), GetPathKey(path), StringComparison.OrdinalIgnoreCase) &&
            _tabsByPathview.TryGetValue(fixedView, out var fixedTab))
        {
            _browsablePathview.ActivateHistoryLocation(path, isBack);
            SelectTabForNavigation(fixedTab);
            return;
        }

        SelectTabForNavigation(_browsableTab);
        if (isBack)
            _browsablePathview.GoBack();
        else
            _browsablePathview.GoForward();
    }

    private void SelectTabForNavigation(TabItem tab)
    {
        _selectingHistoryTab = true;
        try
        {
            ExplorerTabs.SelectedItem = tab;
        }
        finally
        {
            _selectingHistoryTab = false;
        }
    }

    private void NavigateBrowsablePathview(Action<Pathview> navigate)
    {
        if (_browsablePathview is null || _browsableTab is null)
            return;

        SelectTabForNavigation(_browsableTab);
        navigate(_browsablePathview);
    }

    private void Go_Click(object sender, RoutedEventArgs e) => NavigateAddress();

    private void AddressBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
            NavigateAddress();
    }

    private void NavigateAddress()
    {
        if (_browsablePathview is null || _browsableTab is null || string.IsNullOrWhiteSpace(AddressBox.Text))
            return;

        try
        {
            var path = ShellDisplayNameProvider.ResolvePath(AddressBox.Text);
            ActivatePath(path);
        }
        catch (Exception exception)
        {
            RefreshPathChoices();
            MessageBox.Show(this, exception.Message, "Cannot open location", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string GetTabLabelFromPath(string path)
    {
        var normalizedPath = Path.TrimEndingDirectorySeparator(path);
        var currentDir = ShellDisplayNameProvider.GetDisplayName(path);
        if (string.IsNullOrWhiteSpace(currentDir))
            currentDir = Path.GetFileName(normalizedPath);
        if (string.IsNullOrWhiteSpace(currentDir))
            currentDir = path;

        var rootPath = Path.GetPathRoot(path);
        var rootTerm = string.IsNullOrEmpty(rootPath)
            ? string.Empty
            : rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!string.IsNullOrEmpty(rootPath) &&
            string.Equals(Path.GetFullPath(normalizedPath), Path.GetFullPath(rootPath), StringComparison.OrdinalIgnoreCase))
            return rootTerm;

        var parent = Directory.GetParent(normalizedPath);
        var parentIsRoot = parent is not null && !string.IsNullOrEmpty(rootPath) &&
            string.Equals(Path.GetFullPath(parent.FullName), Path.GetFullPath(rootPath), StringComparison.OrdinalIgnoreCase);
        var parentDir = parent is null || parentIsRoot
            ? null
            : ShellDisplayNameProvider.GetDisplayName(parent.FullName) ?? parent.Name;
        var prefix = DefaultTabLabelPrefix;
        if (parentDir is null)
        {
            parentDir = rootTerm;
            prefix = string.Empty;
        }

        var currentOnlyTitle = prefix + currentDir;
        if (currentOnlyTitle.Length >= MaxDisplayedPathLength)
            return currentOnlyTitle[..(MaxDisplayedPathLength - DisplayEllipsis.Length)] + DisplayEllipsis;

        var currentDirUsedLength = currentDir.Length;
        var displayedCurrentDir = currentDir;

        // Shorten the parent first; only shorten the current name in five-character steps if needed.
        // Keep at least ten characters of the current name, even if that leaves the title over the limit.
        while (true)
        {
            var idealTitle = $"{prefix}{parentDir}{DisplayPathSeparator}{displayedCurrentDir}";
            if (idealTitle.Length <= MaxDisplayedPathLength)
                return idealTitle;

            var lengthToSubtract = idealTitle.Length - MaxDisplayedPathLength;
            if (parentDir.Length - 1 >= lengthToSubtract)
            {
                var parentDirUsedLength = parentDir.Length - 1 - lengthToSubtract;
                var displayedParentDir = parentDir[..parentDirUsedLength] + DisplayEllipsis;
                return $"{prefix}{displayedParentDir}{DisplayPathSeparator}{displayedCurrentDir}";
            }

            var newCurrentDirUsedLength = Math.Max(0, currentDirUsedLength - 5);
            if (newCurrentDirUsedLength < 10)
                return idealTitle;

            currentDirUsedLength = newCurrentDirUsedLength;
            displayedCurrentDir = currentDir[..currentDirUsedLength] + DisplayEllipsis;
        }
    }

    private sealed record TabPathChoice(int TabIndex, string Path)
    {
        public string DisplayPath => string.IsNullOrEmpty(Path)
            ? string.Empty
            : ShellDisplayNameProvider.GetDisplayPath(Path);
    }
}