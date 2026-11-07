using System.Windows;
using System.Windows.Controls;

namespace SUTWinExplorer;

internal sealed class ConfigurationDialog : Window
{
    private readonly CheckBox _directoryRowActions;
    private readonly CheckBox _directoryColumnActions;
    private readonly CheckBox _selectedItemsActions;
    private readonly CheckBox _internalItemTransfers;
    private readonly InterfaceConfiguration _original;

    internal ConfigurationDialog(InterfaceConfiguration configuration)
    {
        _original = configuration;
        Title = "Configuration";
        Width = 400;
        MinWidth = 340;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(new TextBlock { Text = "Interface", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10) });
        _directoryRowActions = new CheckBox { Name = "DirectoryRowActionButtonsCheckBox", Content = "Show directory row action buttons", IsChecked = configuration.ShowDirectoryRowActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _directoryColumnActions = new CheckBox { Name = "DirectoryColumnActionButtonsCheckBox", Content = "Show directory column action buttons", IsChecked = configuration.ShowDirectoryColumnActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _selectedItemsActions = new CheckBox { Name = "SelectedItemsActionButtonsCheckBox", Content = "Show selected items action buttons", IsChecked = configuration.ShowSelectedItemsActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _internalItemTransfers = new CheckBox { Name = "InternalItemTransfersCheckBox", Content = "Enable internal item transfers", IsChecked = configuration.EnableInternalItemTransfers };
        root.Children.Add(_directoryRowActions);
        root.Children.Add(_directoryColumnActions);
        root.Children.Add(_selectedItemsActions);
        root.Children.Add(_internalItemTransfers);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        buttons.Children.Add(new Button { Name = "CancelButton", Content = "Cancel", MinWidth = 76, Margin = new Thickness(0, 0, 8, 0), IsCancel = true });
        var apply = new Button { Name = "ApplyButton", Content = "Apply", MinWidth = 76, IsDefault = true };
        apply.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(apply);
        root.Children.Add(buttons);
        Content = root;
    }

    internal InterfaceConfiguration GetConfiguration() => new()
    {
        ShowDirectoryRowActionButtons = _directoryRowActions.IsChecked == true,
        ShowDirectoryColumnActionButtons = _directoryColumnActions.IsChecked == true,
        ShowSelectedItemsActionButtons = _selectedItemsActions.IsChecked == true,
        EnableInternalItemTransfers = _internalItemTransfers.IsChecked == true,
        AdditionalProperties = _original.AdditionalProperties
    };
}