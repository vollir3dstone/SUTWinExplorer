using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace SUTWinExplorer;

/// <summary>
/// Renders a checkbox with a single-line label and reports the label line's baseline
/// when this element is embedded in another <see cref="TextBlock"/>.
/// </summary>
public sealed class CheckBoxWrapper : TextBlock
{
    private readonly CheckBox _checkBox;
    private readonly Run _label;

    public CheckBoxWrapper()
    {
        TextWrapping = TextWrapping.NoWrap;
        _checkBox = new CheckBox
        {
            IsChecked = true,
            Height = 16,
            Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 0, 4, 0),
            RenderTransform = new TranslateTransform(0, 4)
        };
        _label = new Run();

        Inlines.Add(new InlineUIContainer(_checkBox)
        {
            BaselineAlignment = BaselineAlignment.Baseline
        });
        Inlines.Add(_label);
        Loaded += (_, _) => UpdateReportedBaseline();
        SizeChanged += (_, _) => UpdateReportedBaseline();
    }

    /// <summary>Gets or sets the text rendered beside the checkbox.</summary>
    public string Label
    {
        get => _label.Text;
        set => _label.Text = value ?? string.Empty;
    }

    /// <summary>Returns the contained WPF checkbox for state access and event wiring.</summary>
    public CheckBox GetCheckBox() => _checkBox;

    private void UpdateReportedBaseline()
    {
        if (!IsMeasureValid || !IsArrangeValid)
        {
            return;
        }

        var baseline = BaselineOffset;
        var reportedBaseline = TextBlock.GetBaselineOffset(this);
        if (!double.IsFinite(reportedBaseline) || Math.Abs(reportedBaseline - baseline) > 0.01)
        {
            TextBlock.SetBaselineOffset(this, baseline);
        }
    }
}