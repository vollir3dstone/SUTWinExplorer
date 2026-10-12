using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class MainWindow : Window
{
    private bool _updatingPathChoices;

    public MainWindow()
    {
        InitializeComponent();
        AddTab(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    }

    private ExplorerTabView? CurrentTab => (ExplorerTabs.SelectedItem as TabItem)?.Content as ExplorerTabView;

    private void NewTab_Click(object sender, RoutedEventArgs e) => AddTab(CurrentTab?.CurrentPath ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    private void AddTab(string path)
    {
        var view = new ExplorerTabView(path);
        var title = new TextBlock { Text = GetTabTitle(view.CurrentPath), VerticalAlignment = VerticalAlignment.Center };
        view.LocationChanged += (_, currentPath) =>
        {
            title.Text = GetTabTitle(currentPath);
            RefreshPathChoices();
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
        ExplorerTabs.Items.Add(tab);
        ExplorerTabs.SelectedItem = tab;
        RefreshPathChoices();
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
            AddressBox.Text = CurrentTab?.CurrentPath ?? string.Empty;
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
            CurrentTab.Navigate(AddressBox.Text);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Cannot open location", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string GetTabTitle(string path)
    {
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        return string.IsNullOrEmpty(name) ? path : name;
    }

    private sealed record TabPathChoice(int TabIndex, string Path);
}