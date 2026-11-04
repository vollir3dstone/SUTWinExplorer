using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace SUTWinExplorer;

internal static class ShellDragDrop
{
    internal static IDataObject CreateDataObject(IReadOnlyList<string> paths, IntPtr owner)
    {
        if (paths.Count == 0)
            throw new InvalidOperationException("Select one or more items to drag.");
        var parentPath = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(paths[0]));
        if (paths.Any(path => !string.Equals(
            Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path)), parentPath, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Dragged items must belong to the same directory.");

        IShellFolder? desktop = null;
        IShellFolder? parent = null;
        var pidls = new List<IntPtr>();
        var children = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktop));
            foreach (var path in paths)
            {
                uint attributes = 0;
                Marshal.ThrowExceptionForHR(desktop.ParseDisplayName(owner, IntPtr.Zero, path, out _, out var pidl, ref attributes));
                pidls.Add(pidl);
            }
            var folderId = typeof(IShellFolder).GUID;
            Marshal.ThrowExceptionForHR(SHBindToParent(pidls[0], ref folderId, out parent, out var firstChild));
            children = Marshal.AllocCoTaskMem(IntPtr.Size * pidls.Count);
            Marshal.WriteIntPtr(children, firstChild);
            for (var index = 1; index < pidls.Count; index++)
                Marshal.WriteIntPtr(children, index * IntPtr.Size, ILFindLastID(pidls[index]));
            var dataId = typeof(IDataObject).GUID;
            Marshal.ThrowExceptionForHR(parent.GetUIObjectOf(owner, (uint)pidls.Count, children, ref dataId, IntPtr.Zero, out var pointer));
            try { return (IDataObject)Marshal.GetObjectForIUnknown(pointer); }
            finally { _ = Marshal.Release(pointer); }
        }
        finally
        {
            if (children != IntPtr.Zero) Marshal.FreeCoTaskMem(children);
            foreach (var pidl in pidls) Marshal.FreeCoTaskMem(pidl);
            if (parent is not null && Marshal.IsComObject(parent)) _ = Marshal.ReleaseComObject(parent);
            if (desktop is not null && Marshal.IsComObject(desktop)) _ = Marshal.ReleaseComObject(desktop);
        }
    }

    internal static void Start(IReadOnlyList<string> paths, IntPtr owner)
    {
        var data = CreateDataObject(paths, owner);
        try { Marshal.ThrowExceptionForHR(SHDoDragDrop(owner, data, IntPtr.Zero, 7, out _)); }
        finally { if (Marshal.IsComObject(data)) _ = Marshal.ReleaseComObject(data); }
    }

    internal static ShellDropTarget CreateTarget(string path, IntPtr owner)
    {
        IShellFolder? desktop = null;
        IShellFolder? parent = null;
        var pidl = IntPtr.Zero;
        var children = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktop));
            uint attributes = 0;
            Marshal.ThrowExceptionForHR(desktop.ParseDisplayName(owner, IntPtr.Zero, path, out _, out pidl, ref attributes));
            var folderId = typeof(IShellFolder).GUID;
            Marshal.ThrowExceptionForHR(SHBindToParent(pidl, ref folderId, out parent, out var child));
            children = Marshal.AllocCoTaskMem(IntPtr.Size);
            Marshal.WriteIntPtr(children, child);
            var targetId = typeof(IDropTargetNative).GUID;
            Marshal.ThrowExceptionForHR(parent.GetUIObjectOf(owner, 1, children, ref targetId, IntPtr.Zero, out var pointer));
            try { return new ShellDropTarget((IDropTargetNative)Marshal.GetObjectForIUnknown(pointer)); }
            finally { _ = Marshal.Release(pointer); }
        }
        finally
        {
            if (children != IntPtr.Zero) Marshal.FreeCoTaskMem(children);
            if (pidl != IntPtr.Zero) Marshal.FreeCoTaskMem(pidl);
            if (parent is not null && Marshal.IsComObject(parent)) _ = Marshal.ReleaseComObject(parent);
            if (desktop is not null && Marshal.IsComObject(desktop)) _ = Marshal.ReleaseComObject(desktop);
        }
    }

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetDesktopFolder(out IShellFolder desktop);
    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHBindToParent(IntPtr pidl, ref Guid interfaceId, out IShellFolder parent, out IntPtr child);
    [DllImport("shell32.dll")]
    private static extern IntPtr ILFindLastID(IntPtr pidl);
    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHDoDragDrop(IntPtr owner, IDataObject data, IntPtr source, uint allowedEffects, out uint effect);
}

internal sealed class ShellDropTarget(IDropTargetNative target) : IDisposable
{
    private bool _entered;

    internal uint Enter(IDataObject data, uint keys, int x, int y, uint allowed)
    {
        Marshal.ThrowExceptionForHR(target.DragEnter(data, keys, new DropPoint(x, y), ref allowed));
        _entered = true;
        return allowed;
    }

    internal uint Over(uint keys, int x, int y, uint allowed)
    {
        Marshal.ThrowExceptionForHR(target.DragOver(keys, new DropPoint(x, y), ref allowed));
        return allowed;
    }

    internal uint Drop(IDataObject data, uint keys, int x, int y, uint allowed)
    {
        _entered = false;
        Marshal.ThrowExceptionForHR(target.Drop(data, keys, new DropPoint(x, y), ref allowed));
        return allowed;
    }

    public void Dispose()
    {
        if (_entered) _ = target.DragLeave();
        _entered = false;
        if (Marshal.IsComObject(target)) _ = Marshal.ReleaseComObject(target);
    }
}

[StructLayout(LayoutKind.Sequential)]
internal readonly struct DropPoint(int x, int y)
{
    internal readonly int X = x;
    internal readonly int Y = y;
}

[ComImport]
[Guid("00000122-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDropTargetNative
{
    [PreserveSig] int DragEnter(IDataObject data, uint keys, DropPoint point, ref uint effect);
    [PreserveSig] int DragOver(uint keys, DropPoint point, ref uint effect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop(IDataObject data, uint keys, DropPoint point, ref uint effect);
}