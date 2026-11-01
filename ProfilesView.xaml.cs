using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class ProfilesView : UserControl
{
    private sealed record ProfileListEntry(string Name, bool IsDraft = false)
    {
        public override string ToString() => Name;
    }

    private ProfileConfiguration? _displayedProfile;
    private ProfileConfiguration? _draftProfile;
    private string? _selectionBeforeDraft;
    private bool _isEditing;
    private bool _isNewProfile;
    private bool _refreshingProfiles;

    internal event Action<string>? ProfileSelected;
    internal event Action<string>? ProfileActivationRequested;
    internal event Func<ProfileConfiguration, bool>? ProfileCreateRequested;
    internal event Func<ProfileConfiguration, string, bool>? ProfileRenameRequested;
    internal event Func<string, bool>? ProfileDeleteRequested;
    internal event Action<string?>? ProfilesRefreshRequested;
    internal bool IsEditing => _isEditing;

    public ProfilesView()
    {
        InitializeComponent();
        UpdateActionButtons();
    }

    internal void SetProfiles(IReadOnlyList<string> names, string activeProfileName)
    {
        var entries = names.Select(name => new ProfileListEntry(name)).ToArray();
        _refreshingProfiles = true;
        try
        {
            ProfileList.ItemsSource = entries;
            ProfileList.SelectedItem = entries.FirstOrDefault(entry =>
                string.Equals(entry.Name, activeProfileName, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            _refreshingProfiles = false;
        }
        DisplaySelectedProfile();
    }

    internal void DisplayProfile(ProfileConfiguration? profile)
    {
        _displayedProfile = profile;
        ProfileNameEditor.Text = profile?.ProfileName ?? string.Empty;
        PathviewsTable.ItemsSource = profile?.Pathviews;
        UpdateActionButtons();
    }

    private void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_refreshingProfiles)
            DisplaySelectedProfile();
    }

    private void DisplaySelectedProfile()
    {
        if (ProfileList.SelectedItem is ProfileListEntry { IsDraft: true })
            DisplayProfile(_draftProfile);
        else if (ProfileList.SelectedItem is ProfileListEntry entry)
            ProfileSelected?.Invoke(entry.Name);
        else
            DisplayProfile(null);
        UpdateActionButtons();
    }

    private void ProfileList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source &&
            ItemsControl.ContainerFromElement(ProfileList, source) is ListBoxItem { DataContext: ProfileListEntry { IsDraft: false } entry })
            ProfileActivationRequested?.Invoke(entry.Name);
    }

    private void ProfileList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && ProfileList.SelectedItem is ProfileListEntry { IsDraft: false } entry)
        {
            ProfileActivationRequested?.Invoke(entry.Name);
            e.Handled = true;
        }
    }

    private void NewProfileButton_Click(object sender, RoutedEventArgs e)
    {
        _selectionBeforeDraft = (ProfileList.SelectedItem as ProfileListEntry)?.Name;
        _draftProfile = new ProfileConfiguration { Type = "KIS Explorer profile", ProfileName = "new", Pathviews = [] };
        var entries = ProfileList.Items.Cast<ProfileListEntry>().ToList();
        var draft = new ProfileListEntry("new", IsDraft: true);
        entries.Add(draft);
        ProfileList.ItemsSource = entries;
        ProfileList.SelectedItem = draft;
        BeginEditing(isNewProfile: true);
    }

    private void EditProfileButton_Click(object sender, RoutedEventArgs e)
    {
        if (_displayedProfile is null || IsDefault(_displayedProfile.ProfileName))
            return;
        BeginEditing(isNewProfile: false);
    }

    private void DeleteProfileButton_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is not ProfileListEntry { IsDraft: false } entry || IsDefault(entry.Name))
            return;
        if (MessageBox.Show(Window.GetWindow(this), $"Delete profile '{entry.Name}'?", "Delete profile",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;
        if (ProfileDeleteRequested?.Invoke(entry.Name) == true)
            ProfilesRefreshRequested?.Invoke(null);
    }

    private void BeginEditing(bool isNewProfile)
    {
        _isEditing = true;
        _isNewProfile = isNewProfile;
        ProfileList.IsEnabled = false;
        ProfileNameEditor.IsReadOnly = false;
        UpdateActionButtons();
        ProfileNameEditor.Focus();
        ProfileNameEditor.SelectAll();
    }

    private void ProfileNameEditor_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_isEditing)
            return;
        if (e.Key == Key.Escape)
        {
            CancelPendingEdit();
            e.Handled = true;
        }
        else if (e.Key == Key.Enter)
        {
            CommitProfileName();
            e.Handled = true;
        }
    }

    private void ProfileNameEditor_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_isEditing || sender is not TextBox editor)
            return;
        var invalidCharacters = System.IO.Path.GetInvalidFileNameChars();
        var text = editor.Text;
        if (text.IndexOfAny(invalidCharacters) < 0)
            return;
        var caret = editor.CaretIndex;
        var validBeforeCaret = text[..caret].Count(character => !invalidCharacters.Contains(character));
        editor.Text = new string(text.Where(character => !invalidCharacters.Contains(character)).ToArray());
        editor.CaretIndex = validBeforeCaret;
    }

    private void CommitProfileName()
    {
        if (_displayedProfile is null)
            return;
        var name = ProfileNameEditor.Text.Trim();
        if (_isNewProfile && string.Equals(name, "new", StringComparison.OrdinalIgnoreCase))
        {
            var result = MessageBox.Show(Window.GetWindow(this),
                "The profile name 'new' is reserved. Enter a different name, or cancel to discard the new profile.",
                "Invalid profile name", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (result == MessageBoxResult.Cancel)
                CancelPendingEdit();
            else
                ProfileNameEditor.Focus();
            return;
        }
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0 ||
            string.Equals(name, "new", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show(Window.GetWindow(this), "Enter a valid profile name other than 'new'.",
                "Invalid profile name", MessageBoxButton.OK, MessageBoxImage.Warning);
            ProfileNameEditor.Focus();
            return;
        }

        var success = _isNewProfile
            ? ProfileCreateRequested?.Invoke(new ProfileConfiguration
            {
                Type = _displayedProfile.Type,
                ProfileName = name,
                Pathviews = _displayedProfile.Pathviews,
                AdditionalProperties = _displayedProfile.AdditionalProperties
            }) == true
            : ProfileRenameRequested?.Invoke(_displayedProfile, name) == true;
        if (!success)
        {
            ProfileNameEditor.Focus();
            return;
        }
        var wasNew = _isNewProfile;
        EndEditing();
        ProfilesRefreshRequested?.Invoke(name);
        if (wasNew)
            ProfileActivationRequested?.Invoke(name);
        else
            ProfileList.Focus();
    }

    internal void CancelPendingEdit()
    {
        if (!_isEditing)
            return;
        var wasNew = _isNewProfile;
        var previousSelection = _selectionBeforeDraft;
        EndEditing();
        if (wasNew)
            ProfilesRefreshRequested?.Invoke(previousSelection);
        else
            DisplayProfile(_displayedProfile);
    }

    private void EndEditing()
    {
        _isEditing = false;
        _isNewProfile = false;
        _draftProfile = null;
        _selectionBeforeDraft = null;
        ProfileNameEditor.IsReadOnly = true;
        ProfileList.IsEnabled = true;
        UpdateActionButtons();
    }

    private void UpdateActionButtons()
    {
        var selectedName = (ProfileList.SelectedItem as ProfileListEntry)?.Name;
        NewProfileButton.IsEnabled = !_isEditing;
        EditProfileButton.IsEnabled = !_isEditing && _displayedProfile is not null && !IsDefault(selectedName);
        DeleteProfileButton.IsEnabled = !_isEditing && selectedName is not null && !IsDefault(selectedName);
    }

    private static bool IsDefault(string? profileName) =>
        string.Equals(profileName, "default", StringComparison.OrdinalIgnoreCase);
}