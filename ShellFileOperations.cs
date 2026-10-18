using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace SUTWinExplorer;

internal static class ShellFileOperations
{
    private const short ClipboardFormatHdrop = 15;
    private const uint DropFileCount = uint.MaxValue;
    private const uint ClsctxInprocServer = 1;
    private const uint FileOperationAllowUndo = 0x40;
    private static readonly Guid FileOperationClassId = new("3AD05575-8857-4850-9277-11B85BDB8E09");
    private static readonly Guid ShellLinkClassId = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid ShellLinkInterfaceId = new("000214F9-0000-0000-C000-000000000046");

    public static string? GetFolderTarget(string path)
    {
        if (Directory.Exists(path))
            return Path.GetFullPath(path);
        if (!string.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase))
            return null;

        IShellLinkNative shellLink = null!;
        try
        {
            var classId = ShellLinkClassId;
            var interfaceId = ShellLinkInterfaceId;
            Marshal.ThrowExceptionForHR(CoCreateShellLink(
                ref classId,
                IntPtr.Zero,
                ClsctxInprocServer,
                ref interfaceId,
                out shellLink));
            var persistFile = (IPersistFileNative)shellLink;
            Marshal.ThrowExceptionForHR(persistFile.Load(path, 0));
            Marshal.ThrowExceptionForHR(shellLink.Resolve(IntPtr.Zero, 0x19));

            var targetBuffer = new StringBuilder(32768);
            Marshal.ThrowExceptionForHR(shellLink.GetPath(targetBuffer, targetBuffer.Capacity, IntPtr.Zero, 0));
            var targetPath = targetBuffer.ToString();
            return Directory.Exists(targetPath) ? Path.GetFullPath(targetPath) : null;
        }
        catch (COMException)
        {
            return null;
        }
        finally
        {
            if (Marshal.IsComObject(shellLink))
                _ = Marshal.ReleaseComObject(shellLink);
        }
    }

    private const uint ShellViewAllItems = 2;

    public static List<string> GetSelectedFileSystemPaths(IShellView shellView) =>
        GetFileSystemPaths(shellView, ShellContextMenu.ShellViewSelection);

    public static List<string> GetDisplayedFileSystemPaths(IShellView shellView) =>
        GetFileSystemPaths(shellView, ShellViewAllItems);

    private static List<string> GetFileSystemPaths(IShellView shellView, uint selectionKind)
    {
        IntPtr dataObjectPointer = IntPtr.Zero;
        IDataObject? dataObject = null;
        STGMEDIUM storageMedium = default;
        var hasStorageMedium = false;
        try
        {
            var interfaceId = typeof(IDataObject).GUID;
            var result = shellView.GetItemObject(
                selectionKind,
                ref interfaceId,
                out dataObjectPointer);
            if (result < 0 || dataObjectPointer == IntPtr.Zero)
                return [];

            dataObject = (IDataObject)Marshal.GetObjectForIUnknown(dataObjectPointer);
            var format = new FORMATETC
            {
                cfFormat = ClipboardFormatHdrop,
                ptd = IntPtr.Zero,
                dwAspect = DVASPECT.DVASPECT_CONTENT,
                lindex = -1,
                tymed = TYMED.TYMED_HGLOBAL
            };
            dataObject.GetData(ref format, out storageMedium);
            hasStorageMedium = true;
            return ReadDropPaths(storageMedium.unionmember);
        }
        finally
        {
            if (hasStorageMedium)
                ReleaseStgMedium(ref storageMedium);
            if (dataObject is not null && Marshal.IsComObject(dataObject))
                _ = Marshal.ReleaseComObject(dataObject);
            if (dataObjectPointer != IntPtr.Zero)
                _ = Marshal.Release(dataObjectPointer);
        }
    }

    public static void Copy(IReadOnlyList<string> sourcePaths, string destinationPath, IntPtr ownerWindow) =>
        Transfer(sourcePaths, destinationPath, ownerWindow, "copy",
            (operation, source, destination) => operation.CopyItem(source, destination, null, IntPtr.Zero));

    public static void Move(IReadOnlyList<string> sourcePaths, string destinationPath, IntPtr ownerWindow) =>
        Transfer(sourcePaths, destinationPath, ownerWindow, "move",
            (operation, source, destination) => operation.MoveItem(source, destination, null, IntPtr.Zero));

    private static void Transfer(
        IReadOnlyList<string> sourcePaths,
        string destinationPath,
        IntPtr ownerWindow,
        string operationName,
        Func<IFileOperationNative, IShellItemNative, IShellItemNative, int> queueOperation)
    {
        if (sourcePaths.Count == 0)
            throw new InvalidOperationException($"Select one or more items to {operationName}.");

        ValidateTransferPaths(sourcePaths, destinationPath, operationName);

        IFileOperationNative? operation = null;
        IShellItemNative? destination = null;
        var sources = new List<IShellItemNative>(sourcePaths.Count);
        try
        {
            var operationInterfaceId = typeof(IFileOperationNative).GUID;
            var classId = FileOperationClassId;
            Marshal.ThrowExceptionForHR(CoCreateInstance(
                ref classId,
                IntPtr.Zero,
                ClsctxInprocServer,
                ref operationInterfaceId,
                out operation));
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(
                destinationPath,
                IntPtr.Zero,
                ref ShellItemInterfaceId,
                out destination));
            Marshal.ThrowExceptionForHR(operation.SetOperationFlags(FileOperationAllowUndo));
            Marshal.ThrowExceptionForHR(operation.SetOwnerWindow(ownerWindow));

            foreach (var sourcePath in sourcePaths)
            {
                Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(
                    sourcePath,
                    IntPtr.Zero,
                    ref ShellItemInterfaceId,
                    out var source));
                sources.Add(source);
            }

            foreach (var source in sources)
            {
                Marshal.ThrowExceptionForHR(queueOperation(operation, source, destination));
            }

            Marshal.ThrowExceptionForHR(operation.PerformOperations());
            Marshal.ThrowExceptionForHR(operation.GetAnyOperationsAborted(out var operationsAborted));
            if (operationsAborted)
                throw new OperationCanceledException("The Shell move operation was canceled.");
        }
        finally
        {
            foreach (var source in sources)
            {
                if (Marshal.IsComObject(source))
                    _ = Marshal.ReleaseComObject(source);
            }
            if (destination is not null && Marshal.IsComObject(destination))
                _ = Marshal.ReleaseComObject(destination);
            if (operation is not null && Marshal.IsComObject(operation))
                _ = Marshal.ReleaseComObject(operation);
        }
    }

    private static void ValidateTransferPaths(
        IReadOnlyList<string> sourcePaths,
        string destinationPath,
        string operationName)
    {
        try
        {
            if ((File.GetAttributes(destinationPath) & FileAttributes.Directory) == 0)
                throw new InvalidOperationException($"The destination is not a folder: {destinationPath}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new InvalidOperationException(
                $"The destination folder no longer exists or cannot be accessed: {destinationPath}", exception);
        }

        foreach (var sourcePath in sourcePaths)
        {
            try
            {
                _ = File.GetAttributes(sourcePath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                throw new InvalidOperationException(
                    $"Cannot {operationName} because this source no longer exists or cannot be accessed: {sourcePath}",
                    exception);
            }
        }
    }

    private static List<string> ReadDropPaths(IntPtr fileDrop)
    {
        var count = DragQueryFile(fileDrop, DropFileCount, null, 0);
        var paths = new List<string>(checked((int)count));
        var uniquePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (uint index = 0; index < count; index++)
        {
            var length = DragQueryFile(fileDrop, index, null, 0);
            if (length == 0)
                continue;

            var buffer = new StringBuilder(checked((int)length + 1));
            if (DragQueryFile(fileDrop, index, buffer, (uint)buffer.Capacity) == 0)
                continue;

            var path = Path.GetFullPath(buffer.ToString());
            if (uniquePaths.Add(path))
                paths.Add(path);
        }

        return paths;
    }

    private static Guid ShellItemInterfaceId = new("43826D1E-E718-42EE-BC55-A1E261C37BFE");

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int CoCreateInstance(
        ref Guid classId,
        IntPtr outer,
        uint context,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IFileOperationNative operation);

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int CoCreateShellLink(
        ref Guid classId,
        IntPtr outer,
        uint context,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellLinkNative shellLink);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(
        string path,
        IntPtr bindContext,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemNative item);

    [DllImport("shell32.dll", EntryPoint = "DragQueryFileW", CharSet = CharSet.Unicode)]
    private static extern uint DragQueryFile(IntPtr drop, uint file, StringBuilder? fileName, uint bufferSize);

    [DllImport("ole32.dll")]
    private static extern void ReleaseStgMedium(ref STGMEDIUM medium);

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemNative
    {
    }

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkNative
    {
        [PreserveSig] int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int pathLength, IntPtr findData, uint flags);
        [PreserveSig] int GetIDList(out IntPtr itemIdList);
        [PreserveSig] int SetIDList(IntPtr itemIdList);
        [PreserveSig] int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int nameLength);
        [PreserveSig] int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int directoryLength);
        [PreserveSig] int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        [PreserveSig] int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int argumentsLength);
        [PreserveSig] int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        [PreserveSig] int GetHotkey(out short hotkey);
        [PreserveSig] int SetHotkey(short hotkey);
        [PreserveSig] int GetShowCmd(out int showCommand);
        [PreserveSig] int SetShowCmd(int showCommand);
        [PreserveSig] int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int iconPathLength, out int iconIndex);
        [PreserveSig] int SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        [PreserveSig] int SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        [PreserveSig] int Resolve(IntPtr window, uint flags);
        [PreserveSig] int SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport]
    [Guid("0000010B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFileNative
    {
        [PreserveSig] int GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    [ComImport]
    [Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperationNative
    {
        [PreserveSig] int Advise(IntPtr progressSink, out uint cookie);
        [PreserveSig] int Unadvise(uint cookie);
        [PreserveSig] int SetOperationFlags(uint flags);
        [PreserveSig] int SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        [PreserveSig] int SetProgressDialog(IntPtr progressDialog);
        [PreserveSig] int SetProperties(IntPtr properties);
        [PreserveSig] int SetOwnerWindow(IntPtr ownerWindow);
        [PreserveSig] int ApplyPropertiesToItem(IShellItemNative item, IntPtr progressSink);
        [PreserveSig] int ApplyPropertiesToItems(IntPtr items);
        [PreserveSig] int RenameItem(IShellItemNative item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr progressSink);
        [PreserveSig] int RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int MoveItem(IShellItemNative source, IShellItemNative destination, [MarshalAs(UnmanagedType.LPWStr)] string? newName, IntPtr progressSink);
        [PreserveSig] int MoveItems(IntPtr sources, IShellItemNative destination);
        [PreserveSig] int CopyItem(IShellItemNative source, IShellItemNative destination, [MarshalAs(UnmanagedType.LPWStr)] string? newName, IntPtr progressSink);
        [PreserveSig] int CopyItems(IntPtr sources, IShellItemNative destination);
        [PreserveSig] int DeleteItem(IShellItemNative item, IntPtr progressSink);
        [PreserveSig] int DeleteItems(IntPtr items);
        [PreserveSig] int NewItem(IShellItemNative destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string? templateName, IntPtr progressSink);
        [PreserveSig] int PerformOperations();
        [PreserveSig] int GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
}