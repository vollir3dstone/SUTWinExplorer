using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

internal sealed class ListViewDropTarget
{
    private readonly ListView _list;
    private readonly Func<object?, string?> _itemPath;
    private readonly Func<string> _currentPath;
    private readonly Func<bool> _enabled;
    private ShellDropTarget? _target;
    private string? _targetPath;

    internal ListViewDropTarget(ListView list, Func<object?, string?> itemPath, Func<string> currentPath, Func<bool> enabled)
    {
        _list = list;
        _itemPath = itemPath;
        _currentPath = currentPath;
        _enabled = enabled;
        list.AllowDrop = true;
        list.PreviewDragEnter += DragOver;
        list.PreviewDragOver += DragOver;
        list.PreviewDragLeave += DragLeave;
        list.PreviewDrop += Drop;
        list.Unloaded += (_, _) => ClearTarget();
    }

    private void DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        try
        {
            if (!_enabled() || e.KeyStates.HasFlag(DragDropKeyStates.RightMouseButton) ||
                e.Data is not System.Runtime.InteropServices.ComTypes.IDataObject data ||
                e.Data.GetData(DataFormats.FileDrop, false) is not string[] paths || paths.Length == 0 ||
                paths.Any(path => !Path.IsPathFullyQualified(path) || (!File.Exists(path) && !Directory.Exists(path))))
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var source = _list.InputHitTest(e.GetPosition(_list)) as DependencyObject;
            if (IsListChrome(source))
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var itemPath = _itemPath(FindAncestor<ListViewItem>(source)?.DataContext);
            var destination = itemPath is not null && Directory.Exists(itemPath) ? itemPath : _currentPath();
            if (!Directory.Exists(destination))
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var point = _list.PointToScreen(e.GetPosition(_list));
            var allowed = (uint)(e.AllowedEffects & (DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link));
            uint effect;
            if (_target is null || !string.Equals(_targetPath, destination, StringComparison.OrdinalIgnoreCase))
            {
                ClearTarget();
                _target = ShellDragDrop.CreateTarget(destination, new WindowInteropHelper(Window.GetWindow(_list)!).Handle);
                _targetPath = destination;
                effect = _target.Enter(data, (uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
            }
            else effect = _target.Over((uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
            e.Effects = (DragDropEffects)effect;
        }
        catch (Exception exception)
        {
            Trace.TraceError("Drag-over failed: {0}", exception);
            ClearTarget();
            e.Effects = DragDropEffects.None;
        }
    }

    private void DragLeave(object sender, DragEventArgs e) => ClearTarget();

    private void Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        try
        {
            if (_target is null || e.Data is not System.Runtime.InteropServices.ComTypes.IDataObject data)
            {
                e.Effects = DragDropEffects.None;
                return;
            }
            var point = _list.PointToScreen(e.GetPosition(_list));
            var allowed = (uint)(e.AllowedEffects & (DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link));
            e.Effects = (DragDropEffects)_target.Drop(data, (uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
        }
        catch (Exception exception)
        {
            e.Effects = DragDropEffects.None;
            MessageBox.Show(Window.GetWindow(_list), exception.Message, "Drop failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { ClearTarget(); }
    }

    private void ClearTarget()
    {
        _target?.Dispose();
        _target = null;
        _targetPath = null;
    }
}