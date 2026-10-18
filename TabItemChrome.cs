using System.Windows;
using System.Windows.Media;

namespace SUTWinExplorer;

public static class TabItemChrome
{
    public static readonly DependencyProperty SelectedBackgroundProperty =
        DependencyProperty.RegisterAttached(
            "SelectedBackground",
            typeof(Brush),
            typeof(TabItemChrome),
            new PropertyMetadata(new SolidColorBrush(Colors.White)));

    public static readonly DependencyProperty CornerRadiusProperty =
        DependencyProperty.RegisterAttached(
            "CornerRadius",
            typeof(CornerRadius),
            typeof(TabItemChrome),
            new PropertyMetadata(new CornerRadius(5, 5, 0, 0)));

    public static Brush GetSelectedBackground(DependencyObject element) =>
        (Brush)element.GetValue(SelectedBackgroundProperty);

    public static void SetSelectedBackground(DependencyObject element, Brush value) =>
        element.SetValue(SelectedBackgroundProperty, value);

    public static CornerRadius GetCornerRadius(DependencyObject element) =>
        (CornerRadius)element.GetValue(CornerRadiusProperty);

    public static void SetCornerRadius(DependencyObject element, CornerRadius value) =>
        element.SetValue(CornerRadiusProperty, value);
}