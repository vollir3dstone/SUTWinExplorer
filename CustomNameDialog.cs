using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace SUTWinExplorer;

internal sealed class CustomNameDialog : Window
{
    private readonly TextBox _nameEditor;

    internal CustomNameDialog(string? customName, TextBlock styleSource)
    {
        Title = "Custom Pathview name";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        MinWidth = 340;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var label = new TextBlock { Text = "Custom name", Margin = new Thickness(0, 0, 0, 4) };
        root.Children.Add(label);

        var editorContainer = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        _nameEditor = new TextBox
        {
            Name = "CustomNameEditor",
            Text = customName ?? string.Empty,
            Height = 28,
            Padding = new Thickness(4, 1, 4, 1),
            FontFamily = styleSource.FontFamily,
            FontSize = styleSource.FontSize,
            FontWeight = styleSource.FontWeight,
            FontStyle = styleSource.FontStyle,
            FontStretch = styleSource.FontStretch,
            Foreground = styleSource.Foreground
        };
        AutomationProperties.SetName(_nameEditor, "Custom Pathview name");
        editorContainer.Children.Add(_nameEditor);

        var placeholder = new TextBlock
        {
            Text = "(Undefined custom name)",
            Margin = new Thickness(5, 0, 5, 0),
            VerticalAlignment = VerticalAlignment.Center,
            FontFamily = _nameEditor.FontFamily,
            FontSize = _nameEditor.FontSize,
            FontWeight = _nameEditor.FontWeight,
            FontStyle = _nameEditor.FontStyle,
            FontStretch = _nameEditor.FontStretch,
            Foreground = new SolidColorBrush(Color.FromRgb(135, 145, 154)),
            IsHitTestVisible = false,
            Visibility = string.IsNullOrEmpty(_nameEditor.Text) ? Visibility.Visible : Visibility.Collapsed
        };
        _nameEditor.TextChanged += (_, _) =>
            placeholder.Visibility = string.IsNullOrEmpty(_nameEditor.Text) ? Visibility.Visible : Visibility.Collapsed;
        editorContainer.Children.Add(placeholder);
        Grid.SetRow(editorContainer, 1);
        root.Children.Add(editorContainer);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        var cancel = new Button
        {
            Content = "Cancel",
            MinWidth = 76,
            Margin = new Thickness(0, 0, 8, 0),
            IsCancel = true
        };
        buttons.Children.Add(cancel);
        var apply = new Button { Content = "Apply", MinWidth = 76, IsDefault = true };
        apply.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(apply);
        Grid.SetRow(buttons, 2);
        root.Children.Add(buttons);

        Content = root;
        Loaded += (_, _) =>
        {
            _nameEditor.Focus();
            _nameEditor.SelectAll();
        };
    }

    internal string? CustomName => _nameEditor.Text.Length == 0 ? null : _nameEditor.Text;
}
