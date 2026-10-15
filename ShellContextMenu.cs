using System.Runtime.InteropServices;

namespace SUTWinExplorer;

internal static class ShellContextMenu
{
    private const uint FirstCommandId = 1;
    private const uint LastCommandId = 0x7FFF;
    private const uint PopupFlags = 0x0100 | 0x0002;
    private const uint MenuFlags = 0;
    private const uint InvokeUnicode = 0x00004000;
    internal const uint ShellViewBackground = 0;
    internal const uint ShellViewSelection = 1;

    internal static void InvokeViewCommand(IShellView shellView, uint selectionKind, IntPtr owner, string verb)
    {
        IntPtr contextMenuPointer = IntPtr.Zero;
        IntPtr menu = IntPtr.Zero;
        IntPtr ansiVerbPointer = IntPtr.Zero;
        IntPtr verbPointer = IntPtr.Zero;
        IContextMenu? contextMenu = null;
        try
        {
            var interfaceId = typeof(IContextMenu).GUID;
            Marshal.ThrowExceptionForHR(shellView.GetItemObject(selectionKind, ref interfaceId, out contextMenuPointer));
            if (contextMenuPointer == IntPtr.Zero)
                throw new InvalidOperationException("The Shell did not provide a context menu for this command.");

            contextMenu = (IContextMenu)Marshal.GetObjectForIUnknown(contextMenuPointer);
            menu = CreatePopupMenu();
            if (menu == IntPtr.Zero)
                throw new InvalidOperationException("CreatePopupMenu failed.");

            Marshal.ThrowExceptionForHR(contextMenu.QueryContextMenu(menu, 0, FirstCommandId, LastCommandId, MenuFlags));
            ansiVerbPointer = Marshal.StringToHGlobalAnsi(verb);
            verbPointer = Marshal.StringToHGlobalUni(verb);
            var commandInfo = new CMINVOKECOMMANDINFOEX
            {
                Size = (uint)Marshal.SizeOf<CMINVOKECOMMANDINFOEX>(),
                Mask = InvokeUnicode,
                Owner = owner,
                Verb = ansiVerbPointer,
                VerbW = verbPointer,
                Show = (int)ShowWindowCommand.Normal
            };
            Marshal.ThrowExceptionForHR(contextMenu.InvokeCommand(ref commandInfo));
        }
        finally
        {
            if (verbPointer != IntPtr.Zero)
                Marshal.FreeHGlobal(verbPointer);
            if (ansiVerbPointer != IntPtr.Zero)
                Marshal.FreeHGlobal(ansiVerbPointer);
            if (menu != IntPtr.Zero)
                _ = DestroyMenu(menu);
            if (contextMenu is not null && Marshal.IsComObject(contextMenu))
                _ = Marshal.ReleaseComObject(contextMenu);
            if (contextMenuPointer != IntPtr.Zero)
                _ = Marshal.Release(contextMenuPointer);
        }
    }

    public static void Show(string path, IntPtr owner) => ShowCore(path, owner, background: false);

    public static void ShowBackground(string folderPath, IntPtr owner) => ShowCore(folderPath, owner, background: true);

    private static void ShowCore(string path, IntPtr owner, bool background)
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("The Windows Shell context menu must be opened from an STA thread.");

        IntPtr absolutePidl = IntPtr.Zero;
        IntPtr childPidlArray = IntPtr.Zero;
        IntPtr menu = IntPtr.Zero;
        IShellFolder? desktopFolder = null;
        IShellFolder? parentFolder = null;
        IShellFolder? targetFolder = null;
        IShellView? shellView = null;
        IContextMenu? contextMenu = null;
        SubclassProc? subclassProc = null;
        var subclassInstalled = false;

        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktopFolder));
            uint attributes = 0;
            Marshal.ThrowExceptionForHR(desktopFolder.ParseDisplayName(owner, IntPtr.Zero, path, out _, out absolutePidl, ref attributes));
            var contextMenuId = typeof(IContextMenu).GUID;
            if (background)
            {
                var shellFolderId = typeof(IShellFolder).GUID;
                Marshal.ThrowExceptionForHR(desktopFolder.BindToObject(absolutePidl, IntPtr.Zero, ref shellFolderId, out targetFolder));
                var shellViewId = typeof(IShellView).GUID;
                Marshal.ThrowExceptionForHR(targetFolder.CreateViewObject(owner, ref shellViewId, out shellView));
                Marshal.ThrowExceptionForHR(shellView.GetItemObject(ShellViewBackground, ref contextMenuId, out var contextMenuPointer));
                contextMenu = (IContextMenu)Marshal.GetObjectForIUnknown(contextMenuPointer);
                _ = Marshal.Release(contextMenuPointer);
            }
            else
            {
                var shellFolderId = typeof(IShellFolder).GUID;
                Marshal.ThrowExceptionForHR(SHBindToParent(absolutePidl, ref shellFolderId, out parentFolder, out var childPidl));

                childPidlArray = Marshal.AllocCoTaskMem(IntPtr.Size);
                Marshal.WriteIntPtr(childPidlArray, childPidl);
                Marshal.ThrowExceptionForHR(parentFolder.GetUIObjectOf(owner, 1, childPidlArray, ref contextMenuId, IntPtr.Zero, out contextMenu));
            }

            menu = CreatePopupMenu();
            if (menu == IntPtr.Zero)
                throw new InvalidOperationException("CreatePopupMenu failed.");

            Marshal.ThrowExceptionForHR(contextMenu.QueryContextMenu(menu, 0, FirstCommandId, LastCommandId, MenuFlags));
            InstallMenuMessageForwarder(owner, contextMenu, out subclassProc);
            subclassInstalled = true;

            var point = GetCursorPosition();
            _ = SetForegroundWindow(owner);
            var commandId = TrackPopupMenuEx(menu, PopupFlags, point.X, point.Y, owner, IntPtr.Zero);
            _ = PostMessage(owner, 0, IntPtr.Zero, IntPtr.Zero);

            if (commandId != 0)
            {
                var invokeInfo = new CMINVOKECOMMANDINFOEX
                {
                    Size = (uint)Marshal.SizeOf<CMINVOKECOMMANDINFOEX>(),
                    Mask = InvokeUnicode,
                    Owner = owner,
                    Verb = new IntPtr(commandId - FirstCommandId),
                    VerbW = new IntPtr(commandId - FirstCommandId),
                    Show = (int)ShowWindowCommand.Normal
                };
                Marshal.ThrowExceptionForHR(contextMenu.InvokeCommand(ref invokeInfo));
            }
        }
        finally
        {
            if (subclassInstalled && subclassProc is not null)
                _ = RemoveWindowSubclass(owner, subclassProc, UIntPtr.Zero);
            if (menu != IntPtr.Zero)
                _ = DestroyMenu(menu);
            if (contextMenu is not null && Marshal.IsComObject(contextMenu))
                _ = Marshal.FinalReleaseComObject(contextMenu);
            if (parentFolder is not null && Marshal.IsComObject(parentFolder))
                _ = Marshal.FinalReleaseComObject(parentFolder);
            if (targetFolder is not null && Marshal.IsComObject(targetFolder))
                _ = Marshal.FinalReleaseComObject(targetFolder);
            if (shellView is not null && Marshal.IsComObject(shellView))
                _ = Marshal.FinalReleaseComObject(shellView);
            if (desktopFolder is not null && Marshal.IsComObject(desktopFolder))
                _ = Marshal.FinalReleaseComObject(desktopFolder);
            if (childPidlArray != IntPtr.Zero)
                Marshal.FreeCoTaskMem(childPidlArray);
            if (absolutePidl != IntPtr.Zero)
                Marshal.FreeCoTaskMem(absolutePidl);
        }
    }

    private static void InstallMenuMessageForwarder(IntPtr owner, IContextMenu contextMenu, out SubclassProc callback)
    {
        var menu3 = contextMenu as IContextMenu3;
        var menu2 = contextMenu as IContextMenu2;
        callback = (hwnd, message, wParam, lParam, subclassId, referenceData) =>
        {
            try
            {
                if (message is 0x0117 or 0x002B or 0x002C or 0x0120)
                {
                    if (menu3 is not null)
                    {
                        var result = menu3.HandleMenuMsg2(message, wParam, lParam, out var menuResult);
                        if (result >= 0)
                            return menuResult;
                    }
                    else if (menu2 is not null && menu2.HandleMenuMsg(message, wParam, lParam) >= 0)
                    {
                        return IntPtr.Zero;
                    }
                }
            }
            catch
            {
            }

            return DefSubclassProc(hwnd, message, wParam, lParam);
        };

        if (!SetWindowSubclass(owner, callback, UIntPtr.Zero, UIntPtr.Zero))
            throw new InvalidOperationException("Could not install the native menu message handler.");
    }

    private static NativePoint GetCursorPosition()
    {
        if (!GetCursorPos(out var point))
            throw new InvalidOperationException("Could not read the pointer position.");
        return point;
    }

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetDesktopFolder(out IShellFolder desktopFolder);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHBindToParent(IntPtr itemIdList, ref Guid interfaceId, out IShellFolder parent, out IntPtr childItemIdList);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool SetWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId, UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, UIntPtr referenceData);

    [StructLayout(LayoutKind.Sequential)]
    internal struct CMINVOKECOMMANDINFOEX
    {
        public uint Size;
        public uint Mask;
        public IntPtr Owner;
        public IntPtr Verb;
        public IntPtr Parameters;
        public IntPtr Directory;
        public int Show;
        public uint HotKey;
        public IntPtr Icon;
        public IntPtr Title;
        public IntPtr VerbW;
        public IntPtr ParametersW;
        public IntPtr DirectoryW;
        public IntPtr TitleW;
        public NativePoint InvokePoint;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativePoint
    {
        public int X;
        public int Y;
    }

    private enum ShowWindowCommand
    {
        Normal = 1
    }
}

[ComImport]
[Guid("000214E6-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellFolder
{
    [PreserveSig] int ParseDisplayName(IntPtr owner, IntPtr bindContext, [MarshalAs(UnmanagedType.LPWStr)] string displayName, out uint eaten, out IntPtr itemIdList, ref uint attributes);
    [PreserveSig] int EnumObjects(IntPtr owner, uint flags, IntPtr enumerator);
    [PreserveSig] int BindToObject(IntPtr itemIdList, IntPtr bindContext, ref Guid interfaceId, out IShellFolder result);
    [PreserveSig] int BindToStorage(IntPtr itemIdList, IntPtr bindContext, ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int CompareIDs(IntPtr parameter, IntPtr itemIdList1, IntPtr itemIdList2);
    [PreserveSig] int CreateViewObject(IntPtr owner, ref Guid interfaceId, out IShellView result);
    [PreserveSig] int GetAttributesOf(uint count, IntPtr itemIdLists, ref uint attributes);
    [PreserveSig] int GetUIObjectOf(IntPtr owner, uint count, IntPtr itemIdLists, ref Guid interfaceId, IntPtr reserved, out IContextMenu result);
    [PreserveSig] int GetDisplayNameOf(IntPtr itemIdList, uint flags, IntPtr name);
    [PreserveSig] int SetNameOf(IntPtr owner, IntPtr itemIdList, IntPtr name, uint flags, out IntPtr renamedItemIdList);
}

[ComImport]
[Guid("000214E3-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellView
{
    [PreserveSig] int GetWindow(out IntPtr window);
    [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enterMode);
    [PreserveSig] int TranslateAccelerator(IntPtr message);
    [PreserveSig] int EnableModeless([MarshalAs(UnmanagedType.Bool)] bool enable);
    [PreserveSig] int UIActivate(uint state);
    [PreserveSig] int Refresh();
    [PreserveSig] int CreateViewWindow(IntPtr previousView, IntPtr folderSettings, IntPtr shellBrowser, IntPtr rectangle, out IntPtr viewWindow);
    [PreserveSig] int DestroyViewWindow();
    [PreserveSig] int GetCurrentInfo(IntPtr folderSettings);
    [PreserveSig] int AddPropertySheetPages(uint reserved, IntPtr addPage, IntPtr parameter);
    [PreserveSig] int SaveViewState();
    [PreserveSig] int SelectItem(IntPtr itemIdList, uint flags);
    [PreserveSig] int GetItemObject(uint item, ref Guid interfaceId, out IntPtr result);
}

[ComImport]
[Guid("000214E4-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IContextMenu
{
    [PreserveSig] int QueryContextMenu(IntPtr menu, uint indexMenu, uint idCommandFirst, uint idCommandLast, uint flags);
    [PreserveSig] int InvokeCommand(ref ShellContextMenu.CMINVOKECOMMANDINFOEX commandInfo);
    [PreserveSig] int GetCommandString(UIntPtr commandOffset, uint flags, IntPtr reserved, IntPtr name, uint maximumLength);
}

[ComImport]
[Guid("000214F4-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IContextMenu2
{
    [PreserveSig] int QueryContextMenu(IntPtr menu, uint indexMenu, uint idCommandFirst, uint idCommandLast, uint flags);
    [PreserveSig] int InvokeCommand(ref ShellContextMenu.CMINVOKECOMMANDINFOEX commandInfo);
    [PreserveSig] int GetCommandString(UIntPtr commandOffset, uint flags, IntPtr reserved, IntPtr name, uint maximumLength);
    [PreserveSig] int HandleMenuMsg(uint message, IntPtr wParam, IntPtr lParam);
}

[ComImport]
[Guid("BCFCE0A0-EC17-11D0-8D10-00A0C90F2719")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IContextMenu3
{
    [PreserveSig] int QueryContextMenu(IntPtr menu, uint indexMenu, uint idCommandFirst, uint idCommandLast, uint flags);
    [PreserveSig] int InvokeCommand(ref ShellContextMenu.CMINVOKECOMMANDINFOEX commandInfo);
    [PreserveSig] int GetCommandString(UIntPtr commandOffset, uint flags, IntPtr reserved, IntPtr name, uint maximumLength);
    [PreserveSig] int HandleMenuMsg(uint message, IntPtr wParam, IntPtr lParam);
    [PreserveSig] int HandleMenuMsg2(uint message, IntPtr wParam, IntPtr lParam, out IntPtr result);
}