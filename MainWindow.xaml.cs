using System.Globalization;
using System.IO;
using System.Reflection;
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
    private readonly Dictionary<Pathview, UseCasePathview> _useCaseEntriesByPathview = new();
    private UseCaseConfiguration _activeUseCase;
    private UseCaseStore _useCaseStore;
    private bool _activeUseCaseDirty;
    private int _directoryOperationDepth;

    public MainWindow()
    {
        InitializeComponent();
        var version = typeof(MainWindow).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrEmpty(version))
            Title = $"{Title} v{version}";
        var application = (App)Application.Current;
        _activeUseCase = application.ActiveUseCase;
        _useCaseStore = application.UseCaseStore;
        UseCaseNameLabel.Text = _activeUseCase.UseCaseName;
        UseCasesPane.UseCaseSelected += UseCasesPane_UseCaseSelected;
        UseCasesPane.UseCaseActivationRequested += UseCasesPane_UseCaseActivationRequested;
        UseCasesPane.UseCaseCreateRequested += UseCasesPane_UseCaseCreateRequested;
        UseCasesPane.UseCaseRenameRequested += UseCasesPane_UseCaseRenameRequested;
        UseCasesPane.UseCaseDeleteRequested += UseCasesPane_UseCaseDeleteRequested;
        UseCasesPane.UseCasesRefreshRequested += UseCasesPane_UseCasesRefreshRequested;
        ContentRendered += MainWindow_ContentRendered;
        Closed += (_, _) =>
        {
            foreach (var view in _tabsByPathview.Keys)
                view.Close();
        };
    }

    private void MainWindow_ContentRendered(object? sender, EventArgs e)
    {
        ContentRendered -= MainWindow_ContentRendered;
        try
        {
            AddPaneview(GetInitialDirectory(), isBrowsable: true);
            foreach (var entry in _activeUseCase.Pathviews.ToArray())
                AddPaneview(entry.Path, isBrowsable: false, useCaseEntry: entry, select: false);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot start KIS Explorer: {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            Application.Current.Shutdown(1);
        }
    }

    private void UseCasesButton_Click(object sender, RoutedEventArgs e)
    {
        if (UseCasesPane.Visibility == Visibility.Visible)
        {
            if (UseCasesPane.IsEditing)
            {
                MessageBox.Show(this, "Finish editing the use case name or press Escape to cancel.",
                    "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            ShowTabsView();
            return;
        }

        try
        {
            UseCasesPane.SetUseCases(_useCaseStore.GetUseCaseNames(), _activeUseCase.UseCaseName);
            ExplorerTabs.Visibility = Visibility.Collapsed;
            UseCasesPane.Visibility = Visibility.Visible;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot list use cases: {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ShowTabsView()
    {
        UseCasesPane.Visibility = Visibility.Collapsed;
        ExplorerTabs.Visibility = Visibility.Visible;
    }

    private void UseCasesPane_UseCaseSelected(string useCaseName)
    {
        try
        {
            var useCase = string.Equals(useCaseName, _activeUseCase.UseCaseName, StringComparison.OrdinalIgnoreCase)
                ? _activeUseCase
                : _useCaseStore.ForUseCase(useCaseName).Load();
            UseCasesPane.DisplayUseCase(useCase);
        }
        catch (Exception exception)
        {
            UseCasesPane.DisplayUseCase(null);
            MessageBox.Show(this, $"Cannot open use case '{useCaseName}': {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void UseCasesPane_UseCaseActivationRequested(string useCaseName)
    {
        if (_activeUseCaseDirty && !SaveActiveUseCase())
            return;

        UseCaseStore targetStore;
        UseCaseConfiguration targetUseCase;
        try
        {
            targetStore = _useCaseStore.ForUseCase(useCaseName);
            targetUseCase = string.Equals(useCaseName, _activeUseCase.UseCaseName, StringComparison.OrdinalIgnoreCase)
                ? _activeUseCase
                : targetStore.Load();
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot activate use case '{useCaseName}': {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        SwitchActiveUseCase(targetStore, targetUseCase);
        ShowTabsView();
    }

    private void SwitchActiveUseCase(UseCaseStore targetStore, UseCaseConfiguration targetUseCase)
    {
        if (_browsableTab is not null)
            SelectTabForNavigation(_browsableTab);
        foreach (var view in _tabsByPathview.Keys.Where(view => !view.IsBrowsable).ToArray())
        {
            var tab = _tabsByPathview[view];
            _tabsByPathview.Remove(view);
            _useCaseEntriesByPathview.Remove(view);
            RemoveFixedPathview(view);
            view.Close();
            ExplorerTabs.Items.Remove(tab);
        }

        _useCaseStore = targetStore;
        _activeUseCase = targetUseCase;
        _activeUseCaseDirty = false;
        ((App)Application.Current).SetActiveUseCase(targetStore, targetUseCase);
        UseCaseNameLabel.Text = targetUseCase.UseCaseName;
        foreach (var entry in targetUseCase.Pathviews.ToArray())
            AddPaneview(entry.Path, isBrowsable: false, useCaseEntry: entry, select: false);
        RefreshPathChoices();
    }

    private bool UseCasesPane_UseCaseCreateRequested(UseCaseConfiguration useCase)
    {
        try
        {
            _useCaseStore.ForUseCase(useCase.UseCaseName).Create(useCase);
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot create use case '{useCase.UseCaseName}': {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private bool UseCasesPane_UseCaseRenameRequested(UseCaseConfiguration useCase, string newName)
    {
        try
        {
            var oldName = useCase.UseCaseName;
            var isActive = string.Equals(oldName, _activeUseCase.UseCaseName, StringComparison.OrdinalIgnoreCase);
            var renamedUseCase = isActive ? _activeUseCase : useCase;
            var renamedStore = _useCaseStore.ForUseCase(oldName).Rename(renamedUseCase, newName);
            if (isActive)
            {
                _useCaseStore = renamedStore;
                if (!string.Equals(oldName, newName, StringComparison.Ordinal))
                    _activeUseCaseDirty = false;
                ((App)Application.Current).SetActiveUseCase(renamedStore, renamedUseCase);
                UseCaseNameLabel.Text = renamedUseCase.UseCaseName;
            }
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot rename use case: {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private bool UseCasesPane_UseCaseDeleteRequested(string useCaseName)
    {
        try
        {
            var deletingActive = string.Equals(useCaseName, _activeUseCase.UseCaseName, StringComparison.OrdinalIgnoreCase);
            var targetStore = deletingActive ? _useCaseStore.ForUseCase("default") : null;
            var targetUseCase = targetStore?.LoadOrCreate();
            _useCaseStore.ForUseCase(useCaseName).Delete();
            if (targetStore is not null && targetUseCase is not null)
                SwitchActiveUseCase(targetStore, targetUseCase);
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot delete use case '{useCaseName}': {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private void UseCasesPane_UseCasesRefreshRequested(string? selectedName)
    {
        try
        {
            UseCasesPane.SetUseCases(_useCaseStore.GetUseCaseNames(), selectedName ?? _activeUseCase.UseCaseName);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot list use cases: {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static string GetInitialDirectory()
    {
        var arguments = Environment.GetCommandLineArgs();
        if (arguments.Length == 2)
            return arguments[1].Trim().Trim('\"');

        return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private Pathview? CurrentPathview => (ExplorerTabs.SelectedItem as TabItem)?.Content as Pathview;

    private void SetPathviewTabBackground(Pathview view, Brush background)
    {
        if (_tabsByPathview.TryGetValue(view, out var tab))
        {
            tab.Background = background;
            TabItemChrome.SetSelectedBackground(tab, background);
        }
    }

    private void AddPaneview(string path, bool isBrowsable, UseCasePathview? useCaseEntry = null, bool select = true)
    {
        if (!isBrowsable && ShellLocations.IsTopPath(path))
            throw new InvalidOperationException("This PC cannot be opened as a fixed Pathview.");

        var pathKey = GetPathKey(path);
        if (!isBrowsable && _fixedPathviewsByPath.TryGetValue(pathKey, out var existingPathview))
        {
            SelectPathviewTab(existingPathview);
            return;
        }

        if (isBrowsable != (ExplorerTabs.Items.Count == 0))
            throw new InvalidOperationException("The browsable Pathview must be the first and only browsable tab.");

        Pathview? view = null;
        Action? updateTabTitle = null;
        var tabColor = useCaseEntry?.TabColor is string savedColor
            ? (Color?)ColorConverter.ConvertFromString(savedColor)
            : null;
        view = new Pathview(path, isBrowsable, useCaseEntry?.Name, isBrowsable ? null : name =>
        {
            updateTabTitle?.Invoke();
            if (view is not null)
                Pathview_CustomNameChanged(view, name);
        }, tabColor, isBrowsable ? null : color =>
        {
            if (view is not null)
                Pathview_TabColorChanged(view, color);
        });
        if (useCaseEntry is not null)
            _useCaseEntriesByPathview.Add(view, useCaseEntry);
        var hasCurrentPath = !string.IsNullOrWhiteSpace(view.CurrentPath);
        var navigationFailed = useCaseEntry is not null && !hasCurrentPath;
        var title = new TextBlock
        {
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center
        };
        updateTabTitle = () =>
        {
            var label = view.IsBrowsable ? "BROWSE" :
                string.IsNullOrEmpty(view.CustomName)
                    ? GetTabLabelFromPath(string.IsNullOrWhiteSpace(view.CurrentPath) ? path : view.CurrentPath)
                    : view.CustomName;
            title.Text = navigationFailed ? "! " + label : label;
        };
        updateTabTitle();
        var tooltipText = new TextBlock
        {
            Text = ShellDisplayNameProvider.GetDisplayPath(hasCurrentPath ? view.CurrentPath : path),
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
            if (!_tabsByPathview.ContainsKey(view))
                return;
            if (!view.IsBrowsable)
            {
                RegisterFixedPathview(view, currentPath);
                UpdateUseCasePathview(view, currentPath);
            }
            navigationFailed = false;
            updateTabTitle();
            title.ClearValue(TextBlock.ForegroundProperty);
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
        view.PinRequested += Pathview_PinRequested;
        view.BrowseLocationRequested += Pathview_BrowseLocationRequested;
        view.DirectoryRenamed += Pathview_DirectoryRenamed;
        view.DirectoryOperation = RunDirectoryOperation;
        if (_directoryOperationDepth > 0)
            view.SuspendObservers();

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
        if (view.TabColor is not null)
            SetPathviewTabBackground(view, view.PaneBackground);
        ExplorerTabs.Items.Insert(view.IsBrowsable ? 0 : ExplorerTabs.Items.Count, tab);
        tab.MinWidth = GetMinimumTabWidth(title);
        if (navigationFailed)
        {
            title.Foreground = Brushes.Firebrick;
            tooltipText.Text = $"Cannot open location: {path}";
        }
        if (!view.IsBrowsable && hasCurrentPath)
            UpdateUseCasePathview(view, view.CurrentPath);
        if (select)
            ExplorerTabs.SelectedItem = tab;
        RefreshPathChoices();
    }

    private void UpdateUseCasePathview(Pathview view, string path)
    {
        if (!_tabsByPathview.ContainsKey(view))
            return;

        if (_useCaseEntriesByPathview.TryGetValue(view, out var entry))
        {
            if (string.Equals(entry.Path, path, StringComparison.Ordinal))
                return;
            entry.Path = path;
        }
        else
        {
            entry = new UseCasePathview
            {
                Type = "Pathview",
                Name = view.CustomName,
                TabColor = view.TabColor?.ToString(),
                Path = path,
                ActionOnUseCaseActivation = "open"
            };
            _activeUseCase.Pathviews.Add(entry);
            _useCaseEntriesByPathview.Add(view, entry);
        }
        _activeUseCaseDirty = true;
        SaveActiveUseCase();
    }

    private void Pathview_CustomNameChanged(Pathview view, string? name)
    {
        if (!_useCaseEntriesByPathview.TryGetValue(view, out var entry) ||
            string.Equals(entry.Name, name, StringComparison.Ordinal))
            return;
        entry.Name = name;
        _activeUseCaseDirty = true;
        SaveActiveUseCase();
    }

    private void Pathview_TabColorChanged(Pathview view, Color color)
    {
        SetPathviewTabBackground(view, view.PaneBackground);
        var tabColor = color.ToString();
        if (!_useCaseEntriesByPathview.TryGetValue(view, out var entry) ||
            string.Equals(entry.TabColor, tabColor, StringComparison.Ordinal))
            return;
        entry.TabColor = tabColor;
        _activeUseCaseDirty = true;
        SaveActiveUseCase();
    }

    private bool SaveActiveUseCase()
    {
        try
        {
            _useCaseStore.Save(_activeUseCase);
            _activeUseCaseDirty = false;
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"Cannot save the active use case: {exception.Message}",
                "KIS Explorer", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
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
        if (sender is not Pathview { IsBrowsable: true } view || string.IsNullOrWhiteSpace(view.CurrentPath) ||
            ShellLocations.IsTopPath(view.CurrentPath))
            return;

        AddPaneview(view.CurrentPath, isBrowsable: false);
        if (TryGetFixedPathview(view.CurrentPath, out var fixedView))
            fixedView.CopySettingsFromBrowsable(view);
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

    private void RunDirectoryOperation(Action operation)
    {
        if (_directoryOperationDepth++ > 0)
        {
            try { operation(); }
            finally { _directoryOperationDepth--; }
            return;
        }

        try
        {
            foreach (var view in _tabsByPathview.Keys.ToArray())
                view.SuspendObservers();
            operation();
        }
        finally
        {
            _directoryOperationDepth--;
            foreach (var view in _tabsByPathview.Keys.ToArray())
                view.ResumeObservers();
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

        NavigateWithHistory(
            path,
            hideSiblings,
            hideInternalDirectories,
            hideInternalContentItems,
            preferFixedView,
            source);
    }

    /// <summary>Navigates to a path and records the activation in shared history.</summary>
    /// <param name="path">The destination path to activate.</param>
    /// <param name="hideSiblings">The browsable tree setting; null leaves its current value unchanged.</param>
    /// <param name="hideInternalDirectories">The browsable directory-tree filter; null leaves its current value unchanged.</param>
    /// <param name="hideInternalContentItems">The browsable content-item filter; null leaves its current value unchanged.</param>
    /// <param name="preferFixedView">Null prefers a matching open fixed view; false always navigates the browsable view.</param>
    private void NavigateWithHistory(
        string path,
        bool? hideSiblings = null,
        bool? hideInternalDirectories = null,
        bool? hideInternalContentItems = null,
        bool? preferFixedView = null,
        Pathview? settingsSource = null)
    {
        if (string.IsNullOrWhiteSpace(path) || _browsablePathview is null || _browsableTab is null)
            return;

        try
        {
            var selectedFixedView = DisplayPathHistoryAgnostic(
                path,
                view =>
                {
                    view.Navigate(path, hideSiblings, hideInternalDirectories, hideInternalContentItems);
                    if (settingsSource is not null)
                        view.CopyContentViewSettingsFrom(settingsSource);
                },
                preferFixedView);
            if (selectedFixedView is not null)
                _browsablePathview.RecordVisitedLocation(path);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Cannot open location", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private Pathview? DisplayPathHistoryAgnostic(
        string path,
        Action<Pathview> displayInBrowsableView,
        bool? preferFixedView = null)
    {
        if (string.IsNullOrWhiteSpace(path) || _browsablePathview is null || _browsableTab is null)
            return null;

        if ((preferFixedView ?? true) && TryGetFixedPathview(path, out var fixedView))
        {
            SelectTabForNavigation(_tabsByPathview[fixedView]);
            return fixedView;
        }

        SelectTabForNavigation(_browsableTab);
        displayInBrowsableView(_browsablePathview);
        return null;
    }

    private bool TryGetFixedPathview(string path, out Pathview fixedView)
    {
        fixedView = null!;
        var pathKey = GetPathKey(path);
        if (!_fixedPathviewsByPath.TryGetValue(pathKey, out var candidate) ||
            string.IsNullOrWhiteSpace(candidate.CurrentPath) ||
            !string.Equals(GetPathKey(candidate.CurrentPath), pathKey, StringComparison.OrdinalIgnoreCase))
            return false;

        fixedView = candidate;
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
        ShellLocations.IsTopPath(path) ? ShellLocations.TopPath : Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

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
            view.Close();
            ExplorerTabs.Items.Remove(tab);
            _tabsByPathview.Remove(view);
            RemoveFixedPathview(view);
            if (_useCaseEntriesByPathview.Remove(view, out var entry))
            {
                _activeUseCase.Pathviews.Remove(entry);
                _activeUseCaseDirty = true;
                SaveActiveUseCase();
            }
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
                .Where(entry => !entry.View.IsBrowsable && !string.IsNullOrWhiteSpace(entry.View.CurrentPath))
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

    private void Up_Click(object sender, RoutedEventArgs e)
    {
        if (_browsablePathview is null ||
            string.IsNullOrWhiteSpace(_browsablePathview.CurrentPath) ||
            ShellLocations.IsTopPath(_browsablePathview.CurrentPath))
        {
            return;
        }

        var parentPath = Directory.GetParent(_browsablePathview.CurrentPath)?.FullName;
        if (parentPath is not null)
            NavigateWithHistory(parentPath, preferFixedView: false);
    }

    private void NavigateHistory(bool isBack)
    {
        if (_browsablePathview is null || _browsableTab is null)
            return;

        var path = isBack ? _browsablePathview.BackHistoryPath : _browsablePathview.ForwardHistoryPath;
        if (path is null)
            return;

        var selectedFixedView = DisplayPathHistoryAgnostic(
            path,
            view =>
            {
                if (isBack)
                    view.GoBack();
                else
                    view.GoForward();
            });
        if (selectedFixedView is not null)
        {
            _browsablePathview.ActivateHistoryLocation(path, isBack);
            return;
        }
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

    private void AddressClipboardPaste_Click(object sender, RoutedEventArgs e)
    {
        string text;
        try { text = Clipboard.ContainsText() ? Clipboard.GetText() : string.Empty; }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Clipboard paste failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (string.IsNullOrWhiteSpace(text))
            return;

        AddressBox.Text = text;
        NavigateAddress();
    }

    private void AddressClipboardCopy_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(AddressBox.Text))
            return;

        try { Clipboard.SetText(AddressBox.Text); }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Clipboard copy failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

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
            NavigateWithHistory(path);
        }
        catch (Exception exception)
        {
            RefreshPathChoices();
            MessageBox.Show(this, exception.Message, "Cannot open location", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string GetTabLabelFromPath(string path)
    {
        if (ShellLocations.IsTopPath(path))
            return ShellDisplayNameProvider.GetDisplayName(path) ?? "This PC";

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