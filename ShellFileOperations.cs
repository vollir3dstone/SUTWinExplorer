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
    private const uint FileOperationRecycleOnDelete = 0x00080000;
    private const int CopyEngineUserCancelled = unchecked((int)0x80270000);
    private static readonly Guid FileOperationClassId = new("3AD05575-8857-4850-9277-11B85BDB8E09");
    private static readonly Guid ShellLinkClassId = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid ShellLinkInterfaceId = new("000214F9-0000-0000-C000-000000000046");

    public static string? GetDirectoryTarget(string path)
    {
        if (Directory.Exists(path))
            return Path.GetFullPath(path);
        var target = GetLinkTarget(path);
        return target is not null && Directory.Exists(target) ? target : null;
    }

    public static string? GetLinkTarget(string path)
    {
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
            return targetPath.Length > 0 && (File.Exists(targetPath) || Directory.Exists(targetPath))
                ? Path.GetFullPath(targetPath) : null;
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

    public static List<string> GetSelectedFileSystemPaths(IShellView shellView) =>
        GetFileSystemPaths(shellView, ShellViewOperations.Selection);

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

    public static void Copy(IReadOnlyList<string> sourcePaths, string destinationPath, IntPtr ownerWindow, IList<string> insertedPaths) =>
        Transfer(sourcePaths, destinationPath, ownerWindow, "copy", insertedPaths,
            (operation, source, destination, sink) => operation.CopyItem(source, destination, null, sink));

    public static void Move(IReadOnlyList<string> sourcePaths, string destinationPath, IntPtr ownerWindow, IList<string> insertedPaths,
        IList<(string OldPath, string NewPath)>? movedDirectories = null, bool requireComplete = false) =>
        Transfer(sourcePaths, destinationPath, ownerWindow, "move", insertedPaths,
            (operation, source, destination, sink) => operation.MoveItem(source, destination, null, sink), movedDirectories, requireComplete);

    internal static void MoveDirectoryWithName(string sourcePath, string destinationPath, string newName, IntPtr ownerWindow,
        IList<string> insertedPaths, IList<(string OldPath, string NewPath)> movedDirectories) =>
        Transfer([sourcePath], destinationPath, ownerWindow, "move", insertedPaths,
            (operation, source, destination, sink) => operation.MoveItem(source, destination, newName, sink), movedDirectories);

    public static void Link(IReadOnlyList<string> sourcePaths, string destinationPath, IList<string> insertedPaths)
    {
        if (sourcePaths.Count == 0)
            throw new InvalidOperationException("Select one or more items to link.");

        ValidateTransferPaths(sourcePaths, destinationPath, "link");
        foreach (var sourcePath in sourcePaths)
        {
            var name = SutShell.GetFileSystemName(sourcePath);
            name = string.Concat(name.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));
            var baseName = $"{name} - Shortcut";
            var temporaryPath = Path.Combine(destinationPath, $"{Guid.NewGuid():N}.tmp");
            using (new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            IShellLinkNative? shellLink = null;
            try
            {
                var classId = ShellLinkClassId;
                var interfaceId = ShellLinkInterfaceId;
                Marshal.ThrowExceptionForHR(CoCreateShellLink(ref classId, IntPtr.Zero, ClsctxInprocServer, ref interfaceId, out shellLink));
                Marshal.ThrowExceptionForHR(shellLink.SetPath(Path.GetFullPath(sourcePath)));
                Marshal.ThrowExceptionForHR(((IPersistFileNative)shellLink).Save(temporaryPath, true));
                for (var number = 1; ; number++)
                {
                    var linkPath = Path.Combine(destinationPath, number == 1 ? $"{baseName}.lnk" : $"{baseName} ({number}).lnk");
                    try
                    {
                        File.Move(temporaryPath, linkPath);
                    }
                    catch (IOException) when (File.Exists(linkPath) || Directory.Exists(linkPath)) { continue; }
                    insertedPaths.Add(linkPath);
                    break;
                }
            }
            finally
            {
                if (shellLink is not null && Marshal.IsComObject(shellLink))
                    _ = Marshal.ReleaseComObject(shellLink);
                File.Delete(temporaryPath);
            }
        }
    }

    internal static bool CanDelete(string path)
    {
        try
        {
            if (!Path.IsPathFullyQualified(path))
                return false;
            var fullPath = Path.GetFullPath(path);
            var root = Path.GetPathRoot(fullPath);
            return root is not null && !string.Equals(Path.TrimEndingDirectorySeparator(fullPath),
                Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    public static void Delete(IReadOnlyList<string> sourcePaths, IntPtr ownerWindow)
    {
        if (sourcePaths.Count == 0)
            throw new InvalidOperationException("Select one or more items to delete.");

        foreach (var sourcePath in sourcePaths)
        {
            if (!CanDelete(sourcePath))
                throw new InvalidOperationException($"Cannot delete this location: {sourcePath}");
            try { _ = File.GetAttributes(sourcePath); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                throw new InvalidOperationException($"Cannot delete because this source no longer exists or cannot be accessed: {sourcePath}", exception);
            }
        }

        IFileOperationNative? operation = null;
        var sources = new List<IShellItemNative>(sourcePaths.Count);
        try
        {
            var operationInterfaceId = typeof(IFileOperationNative).GUID;
            var classId = FileOperationClassId;
            Marshal.ThrowExceptionForHR(CoCreateInstance(ref classId, IntPtr.Zero, ClsctxInprocServer, ref operationInterfaceId, out operation));
            Marshal.ThrowExceptionForHR(operation.SetOperationFlags(FileOperationAllowUndo | FileOperationRecycleOnDelete));
            Marshal.ThrowExceptionForHR(operation.SetOwnerWindow(ownerWindow));
            foreach (var sourcePath in sourcePaths)
            {
                Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(sourcePath, IntPtr.Zero, ref ShellItemInterfaceId, out var source));
                sources.Add(source);
            }
            foreach (var source in sources)
                Marshal.ThrowExceptionForHR(operation.DeleteItem(source, IntPtr.Zero));
            var result = operation.PerformOperations();
            if (result == CopyEngineUserCancelled)
                throw new OperationCanceledException("The Shell delete operation was canceled.");
            Marshal.ThrowExceptionForHR(result);
            Marshal.ThrowExceptionForHR(operation.GetAnyOperationsAborted(out var operationsAborted));
            if (operationsAborted)
                throw new OperationCanceledException("The Shell delete operation was canceled.");
        }
        finally
        {
            foreach (var source in sources)
                if (Marshal.IsComObject(source))
                    _ = Marshal.ReleaseComObject(source);
            if (operation is not null && Marshal.IsComObject(operation))
                _ = Marshal.ReleaseComObject(operation);
        }
    }

    private static void Transfer(
        IReadOnlyList<string> sourcePaths,
        string destinationPath,
        IntPtr ownerWindow,
        string operationName,
        IList<string> insertedPaths,
        Func<IFileOperationNative, IShellItemNative, IShellItemNative, IntPtr, int> queueOperation,
        IList<(string OldPath, string NewPath)>? movedDirectories = null,
        bool requireComplete = false)
    {
        if (sourcePaths.Count == 0)
            throw new InvalidOperationException($"Select one or more items to {operationName}.");

        ValidateTransferPaths(sourcePaths, destinationPath, operationName);

        IFileOperationNative? operation = null;
        IShellItemNative? destination = null;
        var sources = new List<IShellItemNative>(sourcePaths.Count);
        var initialInsertedCount = insertedPaths.Count;
        var sink = new TransferProgressSink(destinationPath, insertedPaths, movedDirectories);
        var sinkPointer = IntPtr.Zero;
        try
        {
            sinkPointer = Marshal.GetComInterfaceForObject(sink, typeof(IFileOperationProgressSink));
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
                Marshal.ThrowExceptionForHR(queueOperation(operation, source, destination, sinkPointer));
            }

            Marshal.ThrowExceptionForHR(operation.PerformOperations());
            Marshal.ThrowExceptionForHR(operation.GetAnyOperationsAborted(out var operationsAborted));
            if (operationsAborted)
                throw new OperationCanceledException("The Shell move operation was canceled.");
            if (requireComplete && (insertedPaths.Count - initialInsertedCount != sourcePaths.Count ||
                sourcePaths.Any(path => File.Exists(path) || Directory.Exists(path))))
                throw new InvalidOperationException("The Shell move operation did not complete for every item.");
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
            if (sinkPointer != IntPtr.Zero)
                _ = Marshal.Release(sinkPointer);
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
                throw new InvalidOperationException($"The destination is not a directory: {destinationPath}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new InvalidOperationException(
                $"The destination directory no longer exists or cannot be accessed: {destinationPath}", exception);
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

    [DllImport("ole32.dll", EntryPoint = "CoCreateInstance", PreserveSig = true)]
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
        [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
        [PreserveSig] int GetParent(out IntPtr parent);
        [PreserveSig] int GetDisplayName(uint displayNameType, out IntPtr name);
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class TransferProgressSink(string destinationPath, IList<string> insertedPaths,
        IList<(string OldPath, string NewPath)>? movedDirectories) : IFileOperationProgressSink
    {
        private readonly Dictionary<IntPtr, string> _movingDirectories = [];
        public int StartOperations() => 0;
        public int FinishOperations(int result) => 0;
        public int PreRenameItem(uint flags, IntPtr item, IntPtr newName) => 0;
        public int PostRenameItem(uint flags, IntPtr item, IntPtr newName, int result, IntPtr newItem) => 0;
        public int PreMoveItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName)
        {
            if (movedDirectories is not null && GetPath(item) is { } path && Directory.Exists(path))
                _movingDirectories[item] = path;
            return 0;
        }
        public int PostMoveItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName, int result, IntPtr newItem)
        {
            if (result >= 0 && _movingDirectories.Remove(item, out var oldPath) && GetPath(newItem) is { } newPath)
                movedDirectories?.Add((oldPath, newPath));
            return Record(result, newItem);
        }
        public int PreCopyItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName) => 0;
        public int PostCopyItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName, int result, IntPtr newItem) => Record(result, newItem);
        public int PreDeleteItem(uint flags, IntPtr item) => 0;
        public int PostDeleteItem(uint flags, IntPtr item, int result, IntPtr newItem) => 0;
        public int PreNewItem(uint flags, IntPtr destination, IntPtr newName) => 0;
        public int PostNewItem(uint flags, IntPtr destination, IntPtr newName, IntPtr templateName, uint attributes, int result, IntPtr newItem) => 0;
        public int UpdateProgress(uint totalWork, uint workSoFar) => 0;
        public int ResetTimer() => 0;
        public int PauseTimer() => 0;
        public int ResumeTimer() => 0;

        private static string? GetPath(IntPtr item)
        {
            if (item == IntPtr.Zero || ((IShellViewItemNative)Marshal.GetObjectForIUnknown(item)).GetDisplayName(0x80058000, out var name) < 0)
                return null;
            try { return Marshal.PtrToStringUni(name); }
            finally { Marshal.FreeCoTaskMem(name); }
        }

        private int Record(int result, IntPtr newItem)
        {
            if (result < 0 || newItem == IntPtr.Zero ||
                ((IShellViewItemNative)Marshal.GetObjectForIUnknown(newItem)).GetDisplayName(0x80058000, out var name) < 0)
                return 0;
            try
            {
                if (Marshal.PtrToStringUni(name) is { } path &&
                    string.Equals(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path)),
                        Path.TrimEndingDirectorySeparator(Path.GetFullPath(destinationPath)), StringComparison.OrdinalIgnoreCase))
                    insertedPaths.Add(path);
            }
            finally { Marshal.FreeCoTaskMem(name); }
            return 0;
        }
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

[ComVisible(true)]
[Guid("04B0F1A7-9490-44BC-96E1-4296A31252E2")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFileOperationProgressSink
{
    [PreserveSig] int StartOperations();
    [PreserveSig] int FinishOperations(int result);
    [PreserveSig] int PreRenameItem(uint flags, IntPtr item, IntPtr newName);
    [PreserveSig] int PostRenameItem(uint flags, IntPtr item, IntPtr newName, int result, IntPtr newItem);
    [PreserveSig] int PreMoveItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName);
    [PreserveSig] int PostMoveItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName, int result, IntPtr newItem);
    [PreserveSig] int PreCopyItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName);
    [PreserveSig] int PostCopyItem(uint flags, IntPtr item, IntPtr destination, IntPtr newName, int result, IntPtr newItem);
    [PreserveSig] int PreDeleteItem(uint flags, IntPtr item);
    [PreserveSig] int PostDeleteItem(uint flags, IntPtr item, int result, IntPtr newItem);
    [PreserveSig] int PreNewItem(uint flags, IntPtr destination, IntPtr newName);
    [PreserveSig] int PostNewItem(uint flags, IntPtr destination, IntPtr newName, IntPtr templateName, uint attributes, int result, IntPtr newItem);
    [PreserveSig] int UpdateProgress(uint totalWork, uint workSoFar);
    [PreserveSig] int ResetTimer();
    [PreserveSig] int PauseTimer();
    [PreserveSig] int ResumeTimer();
}