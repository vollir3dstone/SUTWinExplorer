using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace SUTWinExplorer;

internal sealed class DirectoryLocationDialog : Window
{
    private readonly TextBox _editor;

    internal DirectoryLocationDialog(bool relocate, string value, Window? owner)
    {
        Title = relocate ? "Relocate directory" : "Rename directory";
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
        root.Children.Add(new TextBlock { Text = relocate ? "Destination directory" : "Directory name", Margin = new Thickness(0, 0, 0, 4) });

        _editor = new TextBox { Name = "DirectoryLocationEditor", Text = value, Height = 28, Padding = new Thickness(4, 1, 4, 1), Margin = new Thickness(0, 0, 0, 14) };
        AutomationProperties.SetName(_editor, relocate ? "Destination directory" : "Directory name");
        Grid.SetRow(_editor, 1);
        root.Children.Add(_editor);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(new Button { Content = "Cancel", MinWidth = 76, Margin = new Thickness(0, 0, 8, 0), IsCancel = true });
        var apply = new Button { Content = relocate ? "Relocate" : "Rename", MinWidth = 76, IsDefault = true };
        apply.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(apply);
        Grid.SetRow(buttons, 2);
        root.Children.Add(buttons);
        Content = root;
        Loaded += (_, _) => { _editor.Focus(); _editor.SelectAll(); };
    }

    internal string Value => _editor.Text;
}