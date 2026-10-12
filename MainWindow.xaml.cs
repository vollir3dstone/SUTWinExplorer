using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class MainWindow : Window
{
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
            if (ReferenceEquals(CurrentTab, view))
                AddressBox.Text = currentPath;
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
        AddressBox.Text = view.CurrentPath;
    }

    private void CloseTab_Click(object sender, RoutedEventArgs e)
    {
        if (ExplorerTabs.Items.Count <= 1 || sender is not Button { Tag: ExplorerTabView view })
            return;

        var tab = ExplorerTabs.Items.Cast<TabItem>().FirstOrDefault(item => ReferenceEquals(item.Content, view));
        if (tab is not null)
            ExplorerTabs.Items.Remove(tab);
    }

    private void ExplorerTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CurrentTab is { } tab)
            AddressBox.Text = tab.CurrentPath;
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
}