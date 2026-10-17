using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace SUTWinExplorer;

public static class InputChrome
{
    public static readonly DependencyProperty BaselineSourceProperty =
        DependencyProperty.RegisterAttached(
            "BaselineSource",
            typeof(TextBox),
            typeof(InputChrome),
            new PropertyMetadata(null, OnBaselineSourceChanged));

    public static readonly DependencyProperty CornerRadiusProperty =
        DependencyProperty.RegisterAttached(
            "CornerRadius",
            typeof(CornerRadius),
            typeof(InputChrome),
            new PropertyMetadata(new CornerRadius(3)));

    public static TextBox? GetBaselineSource(DependencyObject element) =>
        (TextBox?)element.GetValue(BaselineSourceProperty);

    public static void SetBaselineSource(DependencyObject element, TextBox? value) =>
        element.SetValue(BaselineSourceProperty, value);

    public static CornerRadius GetCornerRadius(DependencyObject element) =>
        (CornerRadius)element.GetValue(CornerRadiusProperty);

    public static void SetCornerRadius(DependencyObject element, CornerRadius value) =>
        element.SetValue(CornerRadiusProperty, value);

    private static void OnBaselineSourceChanged(DependencyObject element, DependencyPropertyChangedEventArgs args)
    {
        if (element is not FrameworkElement target)
        {
            return;
        }

        target.Loaded -= OnBaselineTargetLoaded;
        target.SizeChanged -= OnBaselineTargetSizeChanged;
        target.Loaded += OnBaselineTargetLoaded;
        target.SizeChanged += OnBaselineTargetSizeChanged;

        if (target.IsLoaded)
        {
            target.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => UpdateBaseline(target)));
        }
    }

    private static void OnBaselineTargetLoaded(object sender, RoutedEventArgs args) =>
        UpdateBaseline((FrameworkElement)sender);

    private static void OnBaselineTargetSizeChanged(object sender, SizeChangedEventArgs args) =>
        UpdateBaseline((FrameworkElement)sender);

    private static void UpdateBaseline(FrameworkElement target)
    {
        var textBox = GetBaselineSource(target);
        if (textBox is null || !textBox.IsLoaded || !textBox.IsMeasureValid || !textBox.IsArrangeValid)
        {
            return;
        }

        var formattedText = new FormattedText(
            "Hg",
            CultureInfo.CurrentCulture,
            textBox.FlowDirection,
            new Typeface(textBox.FontFamily, textBox.FontStyle, textBox.FontWeight, textBox.FontStretch),
            textBox.FontSize,
            textBox.Foreground,
            VisualTreeHelper.GetDpi(textBox).PixelsPerDip);
        var caret = textBox.GetRectFromCharacterIndex(0);
        var baselineInTextBox = caret.IsEmpty
            ? textBox.BorderThickness.Top + textBox.Padding.Top
                + (textBox.ActualHeight - textBox.BorderThickness.Top - textBox.BorderThickness.Bottom
                    - textBox.Padding.Top - textBox.Padding.Bottom - formattedText.Height) / 2
                + formattedText.Baseline
            : caret.Top + formattedText.Baseline;
        var baselinePoint = textBox.TransformToAncestor(target).Transform(new Point(0, baselineInTextBox));

        TextBlock.SetBaselineOffset(target, baselinePoint.Y);
    }
}