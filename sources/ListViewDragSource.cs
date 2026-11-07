using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;

namespace SUTWinExplorer;

internal sealed class ListViewDragSource<T> where T : class
{
    private readonly ListView _list;
    private readonly Func<T, IReadOnlyList<string>> _paths;
    private readonly Func<bool> _enabled;
    private readonly Action _starting;
    private Point _start;

    internal ListViewDragSource(ListView list, Func<T, IReadOnlyList<string>> paths, Func<bool> enabled, Action starting)
    {
        _list = list;
        _paths = paths;
        _enabled = enabled;
        _starting = starting;
        list.PreviewMouseMove += MouseMove;
        list.Unloaded += (_, _) => Cancel();
    }

    internal T? Item { get; private set; }

    internal void Begin(T item, Point position)
    {
        Item = item;
        _start = position;
    }

    internal void Cancel() => Item = null;

    private void MouseMove(object sender, MouseEventArgs e)
    {
        if (Item is not { } item || !_enabled() || e.LeftButton != MouseButtonState.Pressed)
            return;
        var position = e.GetPosition(_list);
        if (Math.Abs(position.X - _start.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(position.Y - _start.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;

        try
        {
            var paths = _paths(item);
            Cancel();
            _starting();
            var owner = new WindowInteropHelper(Window.GetWindow(_list)!).Handle;
            ShellDragDrop.Start(paths, owner);
        }
        catch (Exception exception)
        {
            MessageBox.Show(Window.GetWindow(_list), exception.Message, LocalizedText.Get("Shell_Error_DragFailed"), MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        e.Handled = true;
    }
}