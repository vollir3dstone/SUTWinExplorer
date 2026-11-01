using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class ProfilesView : UserControl
{
    internal event Action<string>? ProfileSelected;
    internal event Action<string>? ProfileActivationRequested;

    public ProfilesView()
    {
        InitializeComponent();
    }

    internal void SetProfiles(IReadOnlyList<string> names, string activeProfileName)
    {
        ProfileList.ItemsSource = names;
        ProfileList.SelectedItem = names.FirstOrDefault(name =>
            string.Equals(name, activeProfileName, StringComparison.OrdinalIgnoreCase));
    }

    internal void DisplayProfile(ProfileConfiguration? profile)
    {
        ProfileNameEditor.Text = profile?.ProfileName ?? string.Empty;
        PathviewsTable.ItemsSource = profile?.Pathviews;
    }

    private void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is string name)
            ProfileSelected?.Invoke(name);
        else
            DisplayProfile(null);
    }

    private void ProfileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source &&
            ItemsControl.ContainerFromElement(ProfileList, source) is ListBoxItem { DataContext: string name })
            ProfileActivationRequested?.Invoke(name);
    }

    private void ProfileList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && ProfileList.SelectedItem is string name)
        {
            ProfileActivationRequested?.Invoke(name);
            e.Handled = true;
        }
    }
}