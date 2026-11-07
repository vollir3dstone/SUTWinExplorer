using System.Windows;
using System.Windows.Controls;

namespace SUTWinExplorer;

internal sealed class ConfigurationDialog : Window
{
    private readonly CheckBox _directoryRowActions;
    private readonly CheckBox _directoryColumnActions;
    private readonly CheckBox _selectedItemsActions;
    private readonly CheckBox _internalItemTransfers;
    private readonly RadioButton _englishLanguage;
    private readonly RadioButton _systemLanguage;
    private readonly InterfaceConfiguration _original;

    internal ConfigurationDialog(InterfaceConfiguration configuration)
    {
        _original = configuration;
        Title = LocalizedText.Get("ConfigurationDialog_Title");
        Width = 400;
        MinWidth = 340;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(new TextBlock { Text = LocalizedText.Get("ConfigurationDialog_Label_Interface"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10) });
        _directoryRowActions = new CheckBox { Name = "DirectoryRowActionButtonsCheckBox", Content = LocalizedText.Get("ConfigurationDialog_CheckBox_DirectoryRowActions"), IsChecked = configuration.ShowDirectoryRowActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _directoryColumnActions = new CheckBox { Name = "DirectoryColumnActionButtonsCheckBox", Content = LocalizedText.Get("ConfigurationDialog_CheckBox_DirectoryColumnActions"), IsChecked = configuration.ShowDirectoryColumnActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _selectedItemsActions = new CheckBox { Name = "SelectedItemsActionButtonsCheckBox", Content = LocalizedText.Get("ConfigurationDialog_CheckBox_SelectedItemsActions"), IsChecked = configuration.ShowSelectedItemsActionButtons, Margin = new Thickness(0, 0, 0, 8) };
        _internalItemTransfers = new CheckBox { Name = "InternalItemTransfersCheckBox", Content = LocalizedText.Get("ConfigurationDialog_CheckBox_InternalItemTransfers"), IsChecked = configuration.EnableInternalItemTransfers };
        root.Children.Add(_directoryRowActions);
        root.Children.Add(_directoryColumnActions);
        root.Children.Add(_selectedItemsActions);
        root.Children.Add(_internalItemTransfers);

        var languageChoices = new StackPanel { Name = "LanguageSelectionPanel", Orientation = Orientation.Horizontal, Margin = new Thickness(0, 16, 0, 0) };
        languageChoices.Children.Add(new TextBlock { Text = LocalizedText.Get("ConfigurationDialog_Label_LanguageSelection"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) });
        _englishLanguage = new RadioButton { Name = "EnglishLanguageRadioButton", GroupName = "LanguageSelection", Content = LocalizedText.Get("ConfigurationDialog_Language_English"), IsChecked = configuration.LanguageSelection == LanguageSelection.English, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        _systemLanguage = new RadioButton { Name = "SystemLanguageRadioButton", GroupName = "LanguageSelection", Content = LocalizedText.Get("ConfigurationDialog_Language_SystemDefault"), IsChecked = configuration.LanguageSelection == LanguageSelection.SystemDefault, VerticalAlignment = VerticalAlignment.Center };
        languageChoices.Children.Add(_englishLanguage);
        languageChoices.Children.Add(_systemLanguage);
        root.Children.Add(languageChoices);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        buttons.Children.Add(new Button { Name = "CancelButton", Content = LocalizedText.Get("Common_Button_Cancel"), MinWidth = 76, Margin = new Thickness(0, 0, 8, 0), IsCancel = true });
        var apply = new Button { Name = "ApplyButton", Content = LocalizedText.Get("Common_Button_Apply"), MinWidth = 76, IsDefault = true };
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
        LanguageSelection = _systemLanguage.IsChecked == true ? LanguageSelection.SystemDefault : LanguageSelection.English,
        AdditionalProperties = _original.AdditionalProperties
    };
}