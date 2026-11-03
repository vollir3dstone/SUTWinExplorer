using System.Runtime.InteropServices;

namespace SUTWinExplorer;

internal static class ShellItemOperations
{
    internal static string Rename(string path, string name, IntPtr owner)
    {
        IntPtr absolutePidl = IntPtr.Zero;
        IntPtr renamedPidl = IntPtr.Zero;
        IntPtr renamedAbsolutePidl = IntPtr.Zero;
        IntPtr namePointer = IntPtr.Zero;
        IntPtr resultPointer = IntPtr.Zero;
        IShellFolder? desktop = null;
        IShellFolder? parent = null;
        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktop));
            uint attributes = 0;
            Marshal.ThrowExceptionForHR(desktop.ParseDisplayName(owner, IntPtr.Zero, path, out _, out absolutePidl, ref attributes));
            var folderId = typeof(IShellFolder).GUID;
            Marshal.ThrowExceptionForHR(SHBindToParent(absolutePidl, ref folderId, out parent, out var childPidl));
            namePointer = Marshal.StringToCoTaskMemUni(name);
            Marshal.ThrowExceptionForHR(parent.SetNameOf(owner, childPidl, namePointer, 1, out renamedPidl));
            if (renamedPidl == IntPtr.Zero)
                throw new InvalidOperationException("The Shell did not return the renamed folder.");
            if (!ILRemoveLastID(absolutePidl))
                throw new InvalidOperationException("Could not resolve the renamed folder's parent.");
            renamedAbsolutePidl = ILCombine(absolutePidl, renamedPidl);
            if (renamedAbsolutePidl == IntPtr.Zero)
                throw new InvalidOperationException("Could not resolve the renamed folder.");
            Marshal.ThrowExceptionForHR(SHGetNameFromIDList(renamedAbsolutePidl, 0x80058000, out resultPointer));
            return Marshal.PtrToStringUni(resultPointer) ?? throw new InvalidOperationException("The renamed folder has no filesystem path.");
        }
        finally
        {
            if (resultPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(resultPointer);
            if (namePointer != IntPtr.Zero) Marshal.FreeCoTaskMem(namePointer);
            if (renamedAbsolutePidl != IntPtr.Zero) Marshal.FreeCoTaskMem(renamedAbsolutePidl);
            if (renamedPidl != IntPtr.Zero) Marshal.FreeCoTaskMem(renamedPidl);
            if (absolutePidl != IntPtr.Zero) Marshal.FreeCoTaskMem(absolutePidl);
            if (parent is not null && Marshal.IsComObject(parent)) _ = Marshal.ReleaseComObject(parent);
            if (desktop is not null && Marshal.IsComObject(desktop)) _ = Marshal.ReleaseComObject(desktop);
        }
    }

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetDesktopFolder(out IShellFolder desktopFolder);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHBindToParent(IntPtr itemIdList, ref Guid interfaceId, out IShellFolder parent, out IntPtr childItemIdList);

    [DllImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ILRemoveLastID(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    private static extern IntPtr ILCombine(IntPtr parent, IntPtr child);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetNameFromIDList(IntPtr itemIdList, uint nameType, out IntPtr name);
}