using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SUTWinExplorer;

internal sealed class MoveConfirmationDialog : Window
{
    public MoveConfirmationDialog(IReadOnlyList<string> itemNames)
    {
        Title = "Confirm move";
        Width = 440;
        Height = 400;
        MinWidth = 340;
        MinHeight = 250;
        ResizeMode = ResizeMode.CanResizeWithGrip;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var prompt = new TextBlock
        {
            Text = "Move these selected items?",
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Color.FromRgb(38, 52, 67)),
            Margin = new Thickness(0, 0, 0, 12)
        };
        root.Children.Add(prompt);

        var itemList = new ListBox
        {
            ItemsSource = itemNames.Select(name => new TextBlock
            {
                Text = name,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(5, 3, 5, 3)
            }).ToArray(),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            BorderBrush = new SolidColorBrush(Color.FromRgb(216, 221, 227)),
            BorderThickness = new Thickness(1)
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(itemList, ScrollBarVisibility.Disabled);
        Grid.SetRow(itemList, 1);
        root.Children.Add(itemList);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0)
        };
        var cancelButton = new Button
        {
            Content = "Cancel",
            MinWidth = 84,
            Margin = new Thickness(0, 0, 8, 0),
            IsCancel = true,
            IsDefault = true
        };
        var moveButton = new Button { Content = "Move", MinWidth = 84 };
        moveButton.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(moveButton);
        Grid.SetRow(buttons, 2);
        root.Children.Add(buttons);

        Content = root;
    }
}