using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace SUTWinExplorer;

internal static class ShellViewOperations
{
    internal const uint Background = 0;
    internal const uint Selection = 1;
    private const uint FirstCommandId = 1;
    private const uint LastCommandId = 0x7FFF;
    private const uint MenuFlags = 0;
    private const uint InvokeUnicode = 0x00004000;
    private const uint ShellViewSelectEdit = 0x0003;
    private const string ShellIdListArrayFormat = "Shell IDList Array";

    internal static void InvokeCommand(IShellView shellView, uint selectionKind, IntPtr owner, string verb)
    {
        IntPtr contextMenuPointer = IntPtr.Zero;
        IntPtr menu = IntPtr.Zero;
        IntPtr ansiVerbPointer = IntPtr.Zero;
        IntPtr verbPointer = IntPtr.Zero;
        IContextMenu? contextMenu = null;
        var operationStage = "getting the selection context menu";
        try
        {
            var interfaceId = typeof(IContextMenu).GUID;
            Marshal.ThrowExceptionForHR(shellView.GetItemObject(selectionKind, ref interfaceId, out contextMenuPointer));
            if (contextMenuPointer == IntPtr.Zero)
                throw new InvalidOperationException("The Shell did not provide a context menu for this command.");
            contextMenu = (IContextMenu)Marshal.GetObjectForIUnknown(contextMenuPointer);
            operationStage = "creating the context menu";
            menu = CreatePopupMenu();
            if (menu == IntPtr.Zero)
                throw new InvalidOperationException("CreatePopupMenu failed.");
            operationStage = "querying the context menu";
            Marshal.ThrowExceptionForHR(contextMenu.QueryContextMenu(menu, 0, FirstCommandId, LastCommandId, MenuFlags));
            ansiVerbPointer = Marshal.StringToHGlobalAnsi(verb);
            verbPointer = Marshal.StringToHGlobalUni(verb);
            var commandInfo = new ShellCommandInvokeInfo
            {
                Size = (uint)Marshal.SizeOf<ShellCommandInvokeInfo>(),
                Mask = InvokeUnicode,
                Owner = owner,
                Verb = ansiVerbPointer,
                VerbW = verbPointer,
                Show = 1
            };
            operationStage = $"invoking the '{verb}' verb";
            Marshal.ThrowExceptionForHR(contextMenu.InvokeCommand(ref commandInfo));
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                $"The Shell failed while {operationStage} ({exception.GetType().Name}, HRESULT 0x{exception.HResult:X8}): {exception.Message}",
                exception);
        }
        finally
        {
            if (verbPointer != IntPtr.Zero) Marshal.FreeHGlobal(verbPointer);
            if (ansiVerbPointer != IntPtr.Zero) Marshal.FreeHGlobal(ansiVerbPointer);
            if (menu != IntPtr.Zero) _ = DestroyMenu(menu);
            if (contextMenu is not null && Marshal.IsComObject(contextMenu)) _ = Marshal.ReleaseComObject(contextMenu);
            if (contextMenuPointer != IntPtr.Zero) _ = Marshal.Release(contextMenuPointer);
        }
    }

    internal static void RenameSelection(IShellView shellView)
    {
        IntPtr dataObjectPointer = IntPtr.Zero;
        IDataObject? dataObject = null;
        STGMEDIUM storageMedium = default;
        var hasStorageMedium = false;
        IntPtr lockedData = IntPtr.Zero;
        try
        {
            var interfaceId = typeof(IDataObject).GUID;
            Marshal.ThrowExceptionForHR(shellView.GetItemObject(Selection, ref interfaceId, out dataObjectPointer));
            if (dataObjectPointer == IntPtr.Zero)
                throw new InvalidOperationException("The Shell did not provide the selected items for Rename.");
            dataObject = (IDataObject)Marshal.GetObjectForIUnknown(dataObjectPointer);
            var formatId = RegisterClipboardFormat(ShellIdListArrayFormat);
            if (formatId == 0)
                throw new InvalidOperationException("Could not register the Shell item list format.");
            var format = new FORMATETC
            {
                cfFormat = unchecked((short)formatId),
                ptd = IntPtr.Zero,
                dwAspect = DVASPECT.DVASPECT_CONTENT,
                lindex = -1,
                tymed = TYMED.TYMED_HGLOBAL
            };
            dataObject.GetData(ref format, out storageMedium);
            hasStorageMedium = true;
            lockedData = GlobalLock(storageMedium.unionmember);
            if (lockedData == IntPtr.Zero)
                throw new InvalidOperationException("Could not access the selected Shell item list.");
            var itemCount = Marshal.ReadInt32(lockedData);
            if (itemCount != 1)
                throw new InvalidOperationException("Select exactly one item to rename it.");
            var childOffset = Marshal.ReadInt32(lockedData, sizeof(int) * 2);
            var headerSize = sizeof(int) * (itemCount + 2);
            if (childOffset < headerSize)
                throw new InvalidOperationException("The Shell returned an invalid selected item list.");
            Marshal.ThrowExceptionForHR(shellView.SelectItem(IntPtr.Add(lockedData, childOffset), ShellViewSelectEdit));
        }
        finally
        {
            if (lockedData != IntPtr.Zero) _ = GlobalUnlock(storageMedium.unionmember);
            if (hasStorageMedium) ReleaseStgMedium(ref storageMedium);
            if (dataObject is not null && Marshal.IsComObject(dataObject)) _ = Marshal.ReleaseComObject(dataObject);
            if (dataObjectPointer != IntPtr.Zero) _ = Marshal.Release(dataObjectPointer);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterClipboardFormat(string format);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("ole32.dll")]
    private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
}