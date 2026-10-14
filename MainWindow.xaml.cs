using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class MainWindow : Window
{
    private const int MaxDisplayedPathLength = 40;
    private const string DisplayEllipsis = "…";
    private static readonly string DisplayPathSeparator = Path.DirectorySeparatorChar.ToString();
    private static readonly string DefaultTabLabelPrefix = DisplayEllipsis + DisplayPathSeparator;
    private bool _updatingPathChoices;

    public MainWindow()
    {
        InitializeComponent();
        AddTab(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    }

    private ExplorerTabView? CurrentTab => (ExplorerTabs.SelectedItem as TabItem)?.Content as ExplorerTabView;

    private void NewTab_Click(object sender, RoutedEventArgs e)
    {
        var currentPath = CurrentTab?.CurrentPath;
        AddTab(string.IsNullOrWhiteSpace(currentPath)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : currentPath);
    }

    private void AddTab(string path)
    {
        var view = new ExplorerTabView(path);
        var hasCurrentPath = !string.IsNullOrWhiteSpace(view.CurrentPath);
        var title = new TextBlock
        {
            Text = hasCurrentPath ? GetTabLabelFromPath(view.CurrentPath) : "Loading...",
            VerticalAlignment = VerticalAlignment.Center
        };
        var tooltipText = new TextBlock
        {
            Text = hasCurrentPath ? ShellDisplayNameProvider.GetDisplayPath(view.CurrentPath) : string.Empty,
            TextWrapping = TextWrapping.NoWrap
        };

        var close = new Button
        {
            Content = "x",
            Padding = new Thickness(6, 0, 6, 0),
            Margin = new Thickness(8, 0, 0, 0),
            ToolTip = "Close tab",
            Tag = view
        };
        close.Click += CloseTab_Click;

        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(title);
        header.Children.Add(close);

        var tab = new TabItem { Header = header, Content = view };
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
            title.Text = GetTabLabelFromPath(currentPath);
            tooltipText.Text = ShellDisplayNameProvider.GetDisplayPath(currentPath);
            RefreshPathChoices();
        };
        view.NavigationFailed += (_, _) =>
        {
            if (ReferenceEquals(CurrentTab, view))
                RefreshPathChoices();
        };

        ExplorerTabs.Items.Add(tab);
        ExplorerTabs.SelectedItem = tab;
        RefreshPathChoices();
    }

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
        if (ExplorerTabs.Items.Count <= 1 || sender is not Button { Tag: ExplorerTabView view })
            return;

        var tab = ExplorerTabs.Items.Cast<TabItem>().FirstOrDefault(item => ReferenceEquals(item.Content, view));
        if (tab is not null)
        {
            ExplorerTabs.Items.Remove(tab);
            RefreshPathChoices();
        }
    }

    private void ExplorerTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
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
        choices.AddRange(ExplorerTabs.Items.Cast<TabItem>()
            .Select((item, index) => new TabPathChoice(index, ((ExplorerTabView)item.Content).CurrentPath))
            .OrderBy(choice => choice.Path, StringComparer.CurrentCultureIgnoreCase));

        _updatingPathChoices = true;
        try
        {
            AddressBox.ItemsSource = choices;
            AddressBox.SelectedValue = ExplorerTabs.SelectedIndex;
            AddressBox.Text = CurrentTab is null
                ? string.Empty
                : ShellDisplayNameProvider.GetDisplayPath(CurrentTab.CurrentPath);
        }
        finally
        {
            _updatingPathChoices = false;
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => CurrentTab?.GoBack();

    private void Forward_Click(object sender, RoutedEventArgs e) => CurrentTab?.GoForward();

    private void Up_Click(object sender, RoutedEventArgs e) => CurrentTab?.GoUp();

    private void Go_Click(object sender, RoutedEventArgs e) => NavigateAddress();

    private void AddressBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
            NavigateAddress();
    }

    private void NavigateAddress()
    {
        if (CurrentTab is null || string.IsNullOrWhiteSpace(AddressBox.Text))
            return;

        try
        {
            CurrentTab.Navigate(ShellDisplayNameProvider.ResolvePath(AddressBox.Text));
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
            : ShellDisplayNameProvider.GetDisplayName(rootPath) ?? rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
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
            return currentOnlyTitle[..MaxDisplayedPathLength];

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