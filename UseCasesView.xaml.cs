using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SUTWinExplorer;

public partial class UseCasesView : UserControl
{
    private sealed record UseCaseListEntry(string Name, bool IsDraft = false)
    {
        public override string ToString() => Name;
    }

    private UseCaseConfiguration? _displayedUseCase;
    private UseCaseConfiguration? _draftUseCase;
    private string? _selectionBeforeDraft;
    private bool _isEditing;
    private bool _isNewUseCase;
    private bool _refreshingUseCases;

    internal event Action<string>? UseCaseSelected;
    internal event Action<string>? UseCaseActivationRequested;
    internal event Func<UseCaseConfiguration, bool>? UseCaseCreateRequested;
    internal event Func<UseCaseConfiguration, string, bool>? UseCaseRenameRequested;
    internal event Func<string, bool>? UseCaseDeleteRequested;
    internal event Action<string?>? UseCasesRefreshRequested;
    internal bool IsEditing => _isEditing;

    public UseCasesView()
    {
        InitializeComponent();
        UpdateActionButtons();
    }

    internal void SetUseCases(IReadOnlyList<string> names, string activeUseCaseName)
    {
        var entries = names.Select(name => new UseCaseListEntry(name)).ToArray();
        _refreshingUseCases = true;
        try
        {
            UseCaseList.ItemsSource = entries;
            UseCaseList.SelectedItem = entries.FirstOrDefault(entry =>
                string.Equals(entry.Name, activeUseCaseName, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            _refreshingUseCases = false;
        }
        DisplaySelectedUseCase();
    }

    internal void DisplayUseCase(UseCaseConfiguration? useCase)
    {
        _displayedUseCase = useCase;
        UseCaseNameEditor.Text = useCase?.UseCaseName ?? string.Empty;
        PathviewsTable.ItemsSource = useCase?.Pathviews;
        UpdateActionButtons();
    }

    private void UseCaseList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_refreshingUseCases)
            DisplaySelectedUseCase();
    }

    private void DisplaySelectedUseCase()
    {
        if (UseCaseList.SelectedItem is UseCaseListEntry { IsDraft: true })
            DisplayUseCase(_draftUseCase);
        else if (UseCaseList.SelectedItem is UseCaseListEntry entry)
            UseCaseSelected?.Invoke(entry.Name);
        else
            DisplayUseCase(null);
        UpdateActionButtons();
    }

    private void UseCaseList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source &&
            ItemsControl.ContainerFromElement(UseCaseList, source) is ListBoxItem { DataContext: UseCaseListEntry { IsDraft: false } entry })
            UseCaseActivationRequested?.Invoke(entry.Name);
    }

    private void UseCaseList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && UseCaseList.SelectedItem is UseCaseListEntry { IsDraft: false } entry)
        {
            UseCaseActivationRequested?.Invoke(entry.Name);
            e.Handled = true;
        }
    }

    private void NewUseCaseButton_Click(object sender, RoutedEventArgs e)
    {
        _selectionBeforeDraft = (UseCaseList.SelectedItem as UseCaseListEntry)?.Name;
        _draftUseCase = new UseCaseConfiguration { Type = "KIS Explorer use case", UseCaseName = "new", Pathviews = [] };
        var entries = UseCaseList.Items.Cast<UseCaseListEntry>().ToList();
        var draft = new UseCaseListEntry("new", IsDraft: true);
        entries.Add(draft);
        UseCaseList.ItemsSource = entries;
        UseCaseList.SelectedItem = draft;
        BeginEditing(isNewUseCase: true);
    }

    private void EditUseCaseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_displayedUseCase is null || IsDefault(_displayedUseCase.UseCaseName))
            return;
        BeginEditing(isNewUseCase: false);
    }

    private void DeleteUseCaseButton_Click(object sender, RoutedEventArgs e)
    {
        if (UseCaseList.SelectedItem is not UseCaseListEntry { IsDraft: false } entry || IsDefault(entry.Name))
            return;
        if (MessageBox.Show(Window.GetWindow(this), $"Delete use case '{entry.Name}'?", "Delete use case",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;
        if (UseCaseDeleteRequested?.Invoke(entry.Name) == true)
            UseCasesRefreshRequested?.Invoke(null);
    }

    private void BeginEditing(bool isNewUseCase)
    {
        _isEditing = true;
        _isNewUseCase = isNewUseCase;
        UseCaseList.IsEnabled = false;
        UseCaseNameEditor.IsReadOnly = false;
        UpdateActionButtons();
        UseCaseNameEditor.Focus();
        UseCaseNameEditor.SelectAll();
    }

    private void UseCaseNameEditor_PreviewKeyDown(object sender, KeyEventArgs e)
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
            CommitUseCaseName();
            e.Handled = true;
        }
    }

    private void UseCaseNameEditor_TextChanged(object sender, TextChangedEventArgs e)
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

    private void CommitUseCaseName()
    {
        if (_displayedUseCase is null)
            return;
        var name = UseCaseNameEditor.Text.Trim();
        if (_isNewUseCase && string.Equals(name, "new", StringComparison.OrdinalIgnoreCase))
        {
            var result = MessageBox.Show(Window.GetWindow(this),
                "The use case name 'new' is reserved. Enter a different name, or cancel to discard the new use case.",
                "Invalid use case name", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (result == MessageBoxResult.Cancel)
                CancelPendingEdit();
            else
                UseCaseNameEditor.Focus();
            return;
        }
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0 ||
            string.Equals(name, "new", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show(Window.GetWindow(this), "Enter a valid use case name other than 'new'.",
                "Invalid use case name", MessageBoxButton.OK, MessageBoxImage.Warning);
            UseCaseNameEditor.Focus();
            return;
        }

        var success = _isNewUseCase
            ? UseCaseCreateRequested?.Invoke(new UseCaseConfiguration
            {
                Type = _displayedUseCase.Type,
                UseCaseName = name,
                Pathviews = _displayedUseCase.Pathviews,
                AdditionalProperties = _displayedUseCase.AdditionalProperties
            }) == true
            : UseCaseRenameRequested?.Invoke(_displayedUseCase, name) == true;
        if (!success)
        {
            UseCaseNameEditor.Focus();
            return;
        }
        var wasNew = _isNewUseCase;
        EndEditing();
        UseCasesRefreshRequested?.Invoke(name);
        if (wasNew)
            UseCaseActivationRequested?.Invoke(name);
        else
            UseCaseList.Focus();
    }

    internal void CancelPendingEdit()
    {
        if (!_isEditing)
            return;
        var wasNew = _isNewUseCase;
        var previousSelection = _selectionBeforeDraft;
        EndEditing();
        if (wasNew)
            UseCasesRefreshRequested?.Invoke(previousSelection);
        else
            DisplayUseCase(_displayedUseCase);
    }

    private void EndEditing()
    {
        _isEditing = false;
        _isNewUseCase = false;
        _draftUseCase = null;
        _selectionBeforeDraft = null;
        UseCaseNameEditor.IsReadOnly = true;
        UseCaseList.IsEnabled = true;
        UpdateActionButtons();
    }

    private void UpdateActionButtons()
    {
        var selectedName = (UseCaseList.SelectedItem as UseCaseListEntry)?.Name;
        NewUseCaseButton.IsEnabled = !_isEditing;
        EditUseCaseButton.IsEnabled = !_isEditing && _displayedUseCase is not null && !IsDefault(selectedName);
        DeleteUseCaseButton.IsEnabled = !_isEditing && selectedName is not null && !IsDefault(selectedName);
    }

    private static bool IsDefault(string? useCaseName) =>
        string.Equals(useCaseName, "default", StringComparison.OrdinalIgnoreCase);
}