using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using static SUTWinExplorer.ViewUtilities;

namespace SUTWinExplorer;

internal sealed class ListViewDropTarget
{
    private readonly FrameworkElement _surface;
    private readonly ItemsControl? _items;
    private readonly Func<object?, string?>? _itemPath;
    private readonly Func<Point, bool>? _backgroundHitTest;
    private readonly Func<string> _currentPath;
    private readonly Func<bool> _enabled;
    private ShellDropTarget? _target;
    private string? _targetPath;
    private IDropTargetHelperNative? _dragImage;
    private bool _dragImageUnavailable;

    internal ListViewDropTarget(ListView list, Func<object?, string?> itemPath, Func<string> currentPath, Func<bool> enabled)
    {
        _surface = list;
        _items = list;
        _itemPath = itemPath;
        _currentPath = currentPath;
        _enabled = enabled;
        Attach();
    }

    internal ListViewDropTarget(TreeView tree, Func<object?, string?> itemPath, Func<string> currentPath, Func<bool> enabled)
    {
        _surface = tree;
        _items = tree;
        _itemPath = itemPath;
        _currentPath = currentPath;
        _enabled = enabled;
        Attach();
    }

    internal ListViewDropTarget(FrameworkElement surface, Func<Point, bool> backgroundHitTest, Func<string> currentPath, Func<bool> enabled)
    {
        _surface = surface;
        _backgroundHitTest = backgroundHitTest;
        _currentPath = currentPath;
        _enabled = enabled;
        Attach();
    }

    private void Attach()
    {
        _surface.AllowDrop = true;
        _surface.PreviewDragEnter += DragOver;
        _surface.PreviewDragOver += DragOver;
        _surface.PreviewDragLeave += DragLeave;
        _surface.PreviewDrop += Drop;
        _surface.Unloaded += (_, _) => { ClearTarget(); ClearDragImage(); };
    }

    private void DragOver(object sender, DragEventArgs e)
    {
        var position = e.GetPosition(_surface);
        if (_backgroundHitTest is not null && !_backgroundHitTest(position))
        {
            ClearTarget();
            ClearDragImage();
            return;
        }
        e.Handled = true;
        var rejectedMove = false;
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
            var source = _items?.InputHitTest(position) as DependencyObject;
            if (_items is not null && IsListChrome(source))
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var row = _items is TreeView ? (FrameworkElement?)FindAncestor<TreeViewItem>(source) : FindAncestor<ListViewItem>(source);
            var itemPath = _itemPath?.Invoke(row?.DataContext);
            var directoryTarget = itemPath is not null && Directory.Exists(itemPath);
            if (row is not null && !directoryTarget)
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var destination = directoryTarget ? itemPath! : _currentPath();
            if (!Directory.Exists(destination))
            {
                ClearTarget();
                e.Effects = DragDropEffects.None;
                return;
            }
            var point = _surface.PointToScreen(position);
            var allowed = (uint)(e.AllowedEffects & (DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link));
            uint effect;
            if (_target is null || !string.Equals(_targetPath, destination, StringComparison.OrdinalIgnoreCase))
            {
                ClearTarget();
                _target = ShellDragDrop.CreateTarget(destination, new WindowInteropHelper(Window.GetWindow(_surface)!).Handle);
                _targetPath = destination;
                effect = _target.Enter(data, (uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
            }
            else effect = _target.Over((uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
            rejectedMove = effect == (uint)DragDropEffects.Move;
            e.Effects = effect == (uint)DragDropEffects.Copy ? DragDropEffects.Copy : DragDropEffects.None;
        }
        catch (Exception exception)
        {
            Trace.TraceError("Drag-over failed: {0}", exception);
            ClearTarget();
            e.Effects = DragDropEffects.None;
        }
        finally { UpdateDragImage(e, position, rejectedMove); }
    }

    private void DragLeave(object sender, DragEventArgs e)
    {
        ClearTarget();
        ClearDragImage();
    }

    private void Drop(object sender, DragEventArgs e)
    {
        var position = e.GetPosition(_surface);
        if (_backgroundHitTest is not null && !_backgroundHitTest(position))
        {
            ClearTarget();
            ClearDragImage();
            return;
        }
        e.Handled = true;
        try
        {
            if (!_enabled() || e.KeyStates.HasFlag(DragDropKeyStates.RightMouseButton) ||
                _target is null || e.Data is not System.Runtime.InteropServices.ComTypes.IDataObject data)
            {
                e.Effects = DragDropEffects.None;
                return;
            }
            var source = _items?.InputHitTest(position) as DependencyObject;
            var row = _items is TreeView ? (FrameworkElement?)FindAncestor<TreeViewItem>(source) : FindAncestor<ListViewItem>(source);
            var itemPath = _itemPath?.Invoke(row?.DataContext);
            var directoryTarget = itemPath is not null && Directory.Exists(itemPath);
            var destination = directoryTarget ? itemPath! : _currentPath();
            if ((row is not null && !directoryTarget) || (_items is not null && IsListChrome(source)) ||
                !string.Equals(_targetPath, destination, StringComparison.OrdinalIgnoreCase))
            {
                e.Effects = DragDropEffects.None;
                return;
            }
            var point = _surface.PointToScreen(position);
            var allowed = (uint)(e.AllowedEffects & (DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link));
            if (_target.Over((uint)e.KeyStates, (int)point.X, (int)point.Y, allowed) != (uint)DragDropEffects.Copy)
            {
                e.Effects = DragDropEffects.None;
                return;
            }
            allowed &= (uint)DragDropEffects.Copy;
            e.Effects = (DragDropEffects)_target.Drop(data, (uint)e.KeyStates, (int)point.X, (int)point.Y, allowed);
        }
        catch (Exception exception)
        {
            e.Effects = DragDropEffects.None;
            MessageBox.Show(Window.GetWindow(_surface), exception.Message, "Drop failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            try
            {
                if (_dragImage is not null && e.Data is System.Runtime.InteropServices.ComTypes.IDataObject data)
                {
                    var screen = _surface.PointToScreen(position);
                    var point = new DropPoint((int)screen.X, (int)screen.Y);
                    _ = _dragImage.Drop(data, ref point, (uint)e.Effects);
                }
            }
            catch (Exception exception) { Trace.TraceError("Drag image drop failed: {0}", exception); }
            finally { ClearDragImage(false); ClearTarget(); }
        }
    }

    private void UpdateDragImage(DragEventArgs e, Point position, bool rejectedMove)
    {
        if (_dragImageUnavailable || e.Data is not System.Runtime.InteropServices.ComTypes.IDataObject data)
            return;
        try
        {
            ShellDragDrop.SetDropDescription(data, e.Effects, rejectedMove);
            var screen = _surface.PointToScreen(position);
            var point = new DropPoint((int)screen.X, (int)screen.Y);
            if (_dragImage is null)
            {
                var type = Type.GetTypeFromCLSID(new Guid("4657278A-411B-11D2-839A-00C04FD918D0"), true)!;
                _dragImage = (IDropTargetHelperNative)Activator.CreateInstance(type)!;
                Marshal.ThrowExceptionForHR(_dragImage.DragEnter(new WindowInteropHelper(Window.GetWindow(_surface)!).Handle, data, ref point, (uint)e.Effects));
            }
            else Marshal.ThrowExceptionForHR(_dragImage.DragOver(ref point, (uint)e.Effects));
        }
        catch (COMException exception) when (exception.HResult == unchecked((int)0x80040064))
        {
            ClearDragImage();
            _dragImageUnavailable = true;
        }
        catch (Exception exception)
        {
            Trace.TraceError("Drag image update failed: {0}", exception);
            ClearDragImage();
        }
    }

    private void ClearDragImage(bool leave = true)
    {
        _dragImageUnavailable = false;
        if (_dragImage is null)
            return;
        try { if (leave) _ = _dragImage.DragLeave(); }
        catch (Exception exception) { Trace.TraceError("Drag image cleanup failed: {0}", exception); }
        finally { _ = Marshal.ReleaseComObject(_dragImage); _dragImage = null; }
    }

    private void ClearTarget()
    {
        _target?.Dispose();
        _target = null;
        _targetPath = null;
    }
}