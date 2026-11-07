using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace SUTWinExplorer;

internal sealed class DirectoryLocationDialog : Window
{
    private readonly TextBox _editor;
    private readonly RadioButton? _destinationAndName;

    internal DirectoryLocationDialog(bool relocate, string value, Window? owner, string? currentDirectoryName = null, bool isFile = false)
    {
        Title = LocalizedText.Get(relocate ? (isFile ? "DirectoryLocationDialog_Title_RelocateFile" : "DirectoryLocationDialog_Title_RelocateDirectory") : "DirectoryLocationDialog_Title_RenameDirectory");
        Owner = owner;
        Width = relocate ? Math.Max(480, (owner?.ActualWidth ?? 800) - 40) : 420;
        MaxWidth = SystemParameters.WorkArea.Width;
        MinWidth = 340;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.CanResize;
        ShowInTaskbar = false;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;

        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        if (relocate)
        {
            var choices = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) };
            var destinationParent = new RadioButton { Content = LocalizedText.Get("DirectoryLocationDialog_Choice_DestinationParent"), IsChecked = true, Margin = new Thickness(0, 0, 20, 0) };
            _destinationAndName = new RadioButton { Content = LocalizedText.Get("DirectoryLocationDialog_Choice_DestinationAndName") };
            choices.Children.Add(destinationParent);
            choices.Children.Add(_destinationAndName);
            root.Children.Add(choices);
        }
        else
            root.Children.Add(new TextBlock { Text = LocalizedText.Get("DirectoryLocationDialog_Label_DirectoryName"), Margin = new Thickness(0, 0, 0, 4) });

        _editor = new TextBox { Name = "DirectoryLocationEditor", Text = value, Height = 28, Padding = new Thickness(4, 1, 4, 1), Margin = new Thickness(0, 0, 0, 14) };
        AutomationProperties.SetName(_editor, LocalizedText.Get(relocate ? "DirectoryLocationDialog_Choice_DestinationParent" : "DirectoryLocationDialog_Label_DirectoryName"));
        if (_destinationAndName is not null)
        {
            _destinationAndName.Checked += (_, _) =>
            {
                AutomationProperties.SetName(_editor, LocalizedText.Get("DirectoryLocationDialog_Choice_DestinationAndName"));
                if (!string.IsNullOrEmpty(currentDirectoryName))
                    _editor.Text = Path.Combine(_editor.Text, currentDirectoryName);
            };
            _destinationAndName.Unchecked += (_, _) =>
            {
                AutomationProperties.SetName(_editor, LocalizedText.Get("DirectoryLocationDialog_Choice_DestinationParent"));
                try { _editor.Text = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(_editor.Text)) ?? _editor.Text; }
                catch (ArgumentException) { }
            };
        }
        Grid.SetRow(_editor, 1);
        root.Children.Add(_editor);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(new Button { Content = LocalizedText.Get("Common_Button_Cancel"), MinWidth = 76, Margin = new Thickness(0, 0, 8, 0), IsCancel = true });
        var apply = new Button { Content = SutContextMenuFactory.GetBaseActionLabel(relocate ? "Relocate" : "Rename"), MinWidth = 76, IsDefault = true };
        apply.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(apply);
        Grid.SetRow(buttons, 2);
        root.Children.Add(buttons);
        Content = root;
        Loaded += (_, _) => { _editor.Focus(); _editor.SelectAll(); };
    }

    internal string Value => _editor.Text;
    internal bool DestinationIncludesName => _destinationAndName?.IsChecked == true;
}