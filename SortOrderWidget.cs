using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

public enum SortOrderDirection { Ascending, Descending }

public readonly record struct SortOrderItem(int Index, SortOrderDirection Direction);

public sealed class SortOrderWidget : Border
{
    public static readonly DependencyProperty ForegroundProperty =
        TextElement.ForegroundProperty.AddOwner(typeof(SortOrderWidget));

    private const string DragFormat = "SUTWinExplorer.SortOrderWidget.Item";
    private readonly StackPanel _boxes = new() { Orientation = Orientation.Horizontal };
    private string[] _names = [];
    private readonly List<SortOrderItem> _items = [];
    private Point _dragStart;
    private int? _pressedIndex;
    private int? _draggedIndex;
    private bool _dragCompleted;

    public SortOrderWidget()
    {
        Height = 24;
        Padding = new Thickness(1);
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(3);
        SetResourceReference(BackgroundProperty, SystemColors.WindowBrushKey);
        SetResourceReference(BorderBrushProperty, "Input.Border");
        Child = _boxes;
        AllowDrop = true;
        LayoutUpdated += UpdateBaseline;
        DragOver += OnDragOver;
        DragLeave += OnDragLeave;
        Drop += OnDrop;
    }

    public event EventHandler? Changed;

    public Brush Foreground
    {
        get => (Brush)GetValue(ForegroundProperty);
        set => SetValue(ForegroundProperty, value);
    }

    public IReadOnlyList<SortOrderItem> Items => _items.ToArray();

    public void Configure(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        var copy = names.Select(name => name ?? throw new ArgumentException("Names cannot contain null.", nameof(names))).ToArray();
        _names = copy;
        _items.Clear();
        _items.AddRange(Enumerable.Range(0, copy.Length).Select(index => new SortOrderItem(index, SortOrderDirection.Ascending)));
        NotifyChanged();
    }

    public void Select(int index)
    {
        var position = _items.FindIndex(item => item.Index == index);
        if (position < 0) throw new ArgumentOutOfRangeException(nameof(index));
        var item = _items[position];
        if (position == 0) item = item with { Direction = Reverse(item.Direction) };
        _items.RemoveAt(position);
        _items.Insert(0, item);
        NotifyChanged();
    }

    private static SortOrderDirection Reverse(SortOrderDirection direction) =>
        direction == SortOrderDirection.Ascending ? SortOrderDirection.Descending : SortOrderDirection.Ascending;

    private void NotifyChanged()
    {
        RenderItems();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void RenderItems()
    {
        var focusedIndex = _boxes.Children.OfType<Button>().FirstOrDefault(button => button.IsKeyboardFocusWithin)?.Tag;
        _boxes.Children.Clear();
        foreach (var item in _items)
        {
            var name = _names[item.Index];
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new TextBlock { Text = name });
            content.Children.Add(new TextBlock
            {
                Text = item.Direction == SortOrderDirection.Ascending ? "\u25B2" : "\u25BC",
                FontSize = 9
            });
            var button = new Button
            {
                Tag = item.Index,
                Content = content,
                Height = 20,
                MinHeight = 20,
                BorderThickness = new Thickness(1, 0, 0, 0),
                Padding = new Thickness(4, 0, 4, 0),
                Margin = new Thickness(0, 0, 1, 0),
                ToolTip = "Click to reverse; drag or use Alt+Left/Right to reorder"
            };
            if (TryFindResource("ContentPaneButtonStyle") is Style style) button.Style = style;
            InputChrome.SetCornerRadius(button, new CornerRadius(0));
            button.SetBinding(Control.BackgroundProperty, new Binding(nameof(Background)) { Source = this });
            button.SetBinding(Control.ForegroundProperty, new Binding(nameof(Foreground)) { Source = this });
            System.Windows.Automation.AutomationProperties.SetName(button, $"{name}, {item.Direction}, priority {_boxes.Children.Count + 1}");
            button.Click += OnItemClick;
            button.PreviewMouseLeftButtonDown += OnItemMouseDown;
            button.PreviewMouseLeftButtonUp += OnItemMouseUp;
            button.PreviewMouseMove += OnItemMouseMove;
            button.PreviewKeyDown += OnItemKeyDown;
            _boxes.Children.Add(button);
            if (Equals(focusedIndex, item.Index)) button.Focus();
        }
    }

    private void UpdateBaseline(object? sender, EventArgs e)
    {
        if (!IsArrangeValid || _boxes.Children.Count == 0 ||
            FindVisualChild<TextBlock>(_boxes.Children[0]) is not { IsArrangeValid: true } text)
            return;
        var baseline = text.TransformToAncestor(this).Transform(new Point(0, text.BaselineOffset)).Y;
        var current = TextBlock.GetBaselineOffset(this);
        if (!double.IsFinite(current) || Math.Abs(current - baseline) > 0.01)
            TextBlock.SetBaselineOffset(this, baseline);
    }

    private void OnItemClick(object sender, RoutedEventArgs e)
    {
        if (_dragCompleted)
        {
            _dragCompleted = false;
            return;
        }
        var index = (int)((Button)sender).Tag;
        var position = _items.FindIndex(item => item.Index == index);
        _items[position] = _items[position] with { Direction = Reverse(_items[position].Direction) };
        NotifyChanged();
    }

    private void OnItemMouseDown(object sender, MouseButtonEventArgs e)
    {
        _dragCompleted = false;
        _pressedIndex = (int)((Button)sender).Tag;
        _dragStart = e.GetPosition(this);
    }

    private void OnItemMouseUp(object sender, MouseButtonEventArgs e) => _pressedIndex = null;

    private void OnItemMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _draggedIndex is not null ||
            _pressedIndex != (int)((Button)sender).Tag)
            return;
        var position = e.GetPosition(this);
        if (Math.Abs(position.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(position.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;
        var button = (Button)sender;
        _draggedIndex = (int)button.Tag;
        _dragCompleted = true;
        try { DragDrop.DoDragDrop(button, new DataObject(DragFormat, _draggedIndex.Value), DragDropEffects.Move); }
        finally
        {
            _pressedIndex = null;
            _draggedIndex = null;
            ClearDropMarker();
        }
    }

    private void OnItemKeyDown(object sender, KeyEventArgs e)
    {
        _dragCompleted = false;
        if ((Keyboard.Modifiers & ModifierKeys.Alt) == 0 || (e.SystemKey != Key.Left && e.SystemKey != Key.Right))
            return;
        var index = (int)((Button)sender).Tag;
        var position = _items.FindIndex(item => item.Index == index);
        MoveItem(index, e.SystemKey == Key.Left ? position - 1 : position + 2);
        e.Handled = true;
    }

    private int DropIndex(DragEventArgs e)
    {
        for (var index = 0; index < _boxes.Children.Count; index++)
        {
            var button = (Button)_boxes.Children[index];
            if (e.GetPosition(button).X < button.ActualWidth / 2) return index;
        }
        return _boxes.Children.Count;
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (_draggedIndex is null || !e.Data.GetDataPresent(DragFormat))
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        ClearDropMarker();
        var index = DropIndex(e);
        var last = index == _boxes.Children.Count;
        var button = (Button)_boxes.Children[last ? index - 1 : index];
        button.BorderBrush = TryFindResource("Input.FocusBorder") as Brush ?? SystemColors.HighlightBrush;
        button.BorderThickness = last ? new Thickness(1, 0, 3, 0) : new Thickness(3, 0, 0, 0);
        e.Effects = DragDropEffects.Move;
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => ClearDropMarker();

    private void ClearDropMarker()
    {
        foreach (Button button in _boxes.Children)
        {
            button.ClearValue(BorderBrushProperty);
            button.BorderThickness = new Thickness(1, 0, 0, 0);
        }
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (_draggedIndex is { } index && e.Data.GetDataPresent(DragFormat))
        {
            var insertionIndex = DropIndex(e);
            ClearDropMarker();
            MoveItem(index, insertionIndex);
            e.Effects = DragDropEffects.Move;
        }
        else e.Effects = DragDropEffects.None;
        e.Handled = true;
    }

    internal void MoveItem(int index, int insertionIndex)
    {
        var position = _items.FindIndex(item => item.Index == index);
        insertionIndex = Math.Clamp(insertionIndex, 0, _items.Count);
        if (position < 0 || insertionIndex == position || insertionIndex == position + 1) return;
        var item = _items[position];
        _items.RemoveAt(position);
        if (insertionIndex > position) insertionIndex--;
        _items.Insert(insertionIndex, item);
        NotifyChanged();
    }
}