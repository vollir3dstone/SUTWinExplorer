using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.Json;

namespace SUTWinExplorer;

internal static class ShellContextMenu
{
    private const uint FirstCommandId = 1;
    private const uint LastCommandId = 0x7FFF;
    private const uint PopupFlags = 0x0100 | 0x0002;
    private const uint MenuFlags = 0;
    private const uint MenuCanRename = 0x00000010;
    private const uint GetVerbUnicode = 0x00000004;
    private const uint InvokeUnicode = 0x00004000;
    private const uint MenuByPosition = 0x00000400;
    private const uint MenuDisabled = 0x00000003;
    private const uint MenuSeparator = 0x00000800;
    private const uint MenuOwnerDrawn = 0x00000100;
    private const uint GenericCommandFirst = 0x8000;
    private const uint ShellViewSelectEdit = 0x0003;
    private const string ShellIdListArrayFormat = "Shell IDList Array";
    private const string BlacklistResourceName = "SUTWinExplorer.ShellExtensionBlacklist.json";
    private static readonly Lazy<HashSet<string>> BlacklistedVerbs = new(LoadBlacklistedVerbs);
    internal const uint ShellViewBackground = 0;
    internal const uint ShellViewSelection = 1;

    internal static void InvokeViewCommand(IShellView shellView, uint selectionKind, IntPtr owner, string verb)
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
            var commandInfo = new CMINVOKECOMMANDINFOEX
            {
                Size = (uint)Marshal.SizeOf<CMINVOKECOMMANDINFOEX>(),
                Mask = InvokeUnicode,
                Owner = owner,
                Verb = ansiVerbPointer,
                VerbW = verbPointer,
                Show = (int)ShowWindowCommand.Normal
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
            Marshal.ThrowExceptionForHR(shellView.GetItemObject(
                ShellViewSelection, ref interfaceId, out dataObjectPointer));
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

            Marshal.ThrowExceptionForHR(shellView.SelectItem(
                IntPtr.Add(lockedData, childOffset), ShellViewSelectEdit));
        }
        finally
        {
            if (lockedData != IntPtr.Zero)
                _ = GlobalUnlock(storageMedium.unionmember);
            if (hasStorageMedium)
                ReleaseStgMedium(ref storageMedium);
            if (dataObject is not null && Marshal.IsComObject(dataObject))
                _ = Marshal.ReleaseComObject(dataObject);
            if (dataObjectPointer != IntPtr.Zero)
                _ = Marshal.Release(dataObjectPointer);
        }
    }

    public static void Show(string path, IntPtr owner, Action? rename = null) => ShowCore([path], owner, background: false, rename);

    internal static void ShowItems(IReadOnlyList<string> paths, IntPtr owner, Action? rename = null) =>
        ShowCore(paths, owner, background: false, rename);

    internal static void ShowGenericFile(string path, IntPtr owner, IReadOnlyList<ShellMenuAction> actions) =>
        ShowCore([path], owner, background: false, rename: null, actions);

    public static void ShowBackground(string folderPath, IntPtr owner) => ShowCore([folderPath], owner, background: true, rename: null);

    private static void ShowCore(IReadOnlyList<string> paths, IntPtr owner, bool background, Action? rename, IReadOnlyList<ShellMenuAction>? actions = null)
    {
        var generic = actions is not null;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("The Windows Shell context menu must be opened from an STA thread.");
        if (paths.Count == 0)
            throw new ArgumentException("At least one item is required.", nameof(paths));
        if (paths.Count > 1 && paths.Skip(1).Any(path => !string.Equals(Path.GetDirectoryName(path),
                Path.GetDirectoryName(paths[0]), StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Selected items must belong to the same directory.", nameof(paths));

        var absolutePidls = new List<IntPtr>();
        IntPtr childPidlArray = IntPtr.Zero;
        IntPtr menu = IntPtr.Zero;
        IntPtr keyArray = IntPtr.Zero;
        IntPtr parentPointer = IntPtr.Zero;
        IShellFolder? desktopFolder = null;
        IShellFolder? parentFolder = null;
        IShellFolder? targetFolder = null;
        IShellView? shellView = null;
        IContextMenu? contextMenu = null;
        SubclassProc? subclassProc = null;
        var subclassInstalled = false;
        using var fileClass = generic ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("*") : null;
        using var filesystemClass = generic ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("AllFilesystemObjects") : null;

        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktopFolder));
            foreach (var path in paths)
            {
                uint attributes = 0;
                Marshal.ThrowExceptionForHR(desktopFolder.ParseDisplayName(owner, IntPtr.Zero, path, out _, out var absolutePidl, ref attributes));
                absolutePidls.Add(absolutePidl);
            }
            var contextMenuId = typeof(IContextMenu).GUID;
            if (background)
            {
                var shellFolderId = typeof(IShellFolder).GUID;
                Marshal.ThrowExceptionForHR(desktopFolder.BindToObject(absolutePidls[0], IntPtr.Zero, ref shellFolderId, out targetFolder));
                var shellViewId = typeof(IShellView).GUID;
                Marshal.ThrowExceptionForHR(targetFolder.CreateViewObject(owner, ref shellViewId, out shellView));
                Marshal.ThrowExceptionForHR(shellView.GetItemObject(ShellViewBackground, ref contextMenuId, out var contextMenuPointer));
                contextMenu = (IContextMenu)Marshal.GetObjectForIUnknown(contextMenuPointer);
                _ = Marshal.Release(contextMenuPointer);
            }
            else
            {
                var shellFolderId = typeof(IShellFolder).GUID;
                Marshal.ThrowExceptionForHR(SHBindToParent(absolutePidls[0], ref shellFolderId, out parentFolder, out var childPidl));

                childPidlArray = Marshal.AllocCoTaskMem(IntPtr.Size * paths.Count);
                Marshal.WriteIntPtr(childPidlArray, childPidl);
                for (var index = 1; index < absolutePidls.Count; index++)
                    Marshal.WriteIntPtr(childPidlArray, index * IntPtr.Size, ILFindLastID(absolutePidls[index]));
                if (!generic)
                    Marshal.ThrowExceptionForHR(parentFolder.GetUIObjectOf(owner, (uint)paths.Count, childPidlArray, ref contextMenuId, IntPtr.Zero, out contextMenu));
                else
                {
                    if (fileClass is null || filesystemClass is null)
                        throw new InvalidOperationException("The generic Shell association classes are unavailable.");
                    keyArray = Marshal.AllocCoTaskMem(IntPtr.Size * 2);
                    Marshal.WriteIntPtr(keyArray, 0, fileClass.Handle.DangerousGetHandle());
                    Marshal.WriteIntPtr(keyArray, IntPtr.Size, filesystemClass.Handle.DangerousGetHandle());
                    parentPointer = Marshal.GetComInterfaceForObject(parentFolder, typeof(IShellFolder));
                    var definition = new DefaultContextMenu
                    {
                        Owner = owner,
                        Folder = parentPointer,
                        Count = (uint)paths.Count,
                        Children = childPidlArray,
                        KeyCount = 2,
                        Keys = keyArray
                    };
                    Marshal.ThrowExceptionForHR(SHCreateDefaultContextMenu(ref definition, ref contextMenuId, out var contextMenuPointer));
                    try { contextMenu = (IContextMenu)Marshal.GetObjectForIUnknown(contextMenuPointer); }
                    finally { _ = Marshal.Release(contextMenuPointer); }
                }
            }

            menu = CreatePopupMenu();
            if (menu == IntPtr.Zero)
                throw new InvalidOperationException("CreatePopupMenu failed.");

            Marshal.ThrowExceptionForHR(contextMenu.QueryContextMenu(menu, 0, FirstCommandId, LastCommandId,
                generic || rename is not null ? MenuFlags | MenuCanRename : MenuFlags));
            if (generic)
                PrepareGenericMenu(menu, contextMenu, actions!);
            InstallMenuMessageForwarder(owner, contextMenu, out subclassProc);
            subclassInstalled = true;

            var point = GetCursorPosition();
            _ = SetForegroundWindow(owner);
            var commandId = TrackPopupMenuEx(menu, PopupFlags, point.X, point.Y, owner, IntPtr.Zero);
            _ = PostMessage(owner, 0, IntPtr.Zero, IntPtr.Zero);

            if (commandId != 0)
            {
                if (actions is not null && commandId >= GenericCommandFirst)
                {
                    var index = commandId - GenericCommandFirst;
                    if (index < actions.Count && actions[(int)index].IsEnabled)
                        actions[(int)index].Invoke();
                    return;
                }
                if (rename is not null && IsRenameCommand(contextMenu, commandId - FirstCommandId))
                {
                    rename();
                    return;
                }

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
            if (parentPointer != IntPtr.Zero)
                _ = Marshal.Release(parentPointer);
            if (keyArray != IntPtr.Zero)
                Marshal.FreeCoTaskMem(keyArray);
            if (childPidlArray != IntPtr.Zero)
                Marshal.FreeCoTaskMem(childPidlArray);
            foreach (var absolutePidl in absolutePidls)
                if (absolutePidl != IntPtr.Zero)
                    Marshal.FreeCoTaskMem(absolutePidl);
        }
    }

    private static bool IsRenameCommand(IContextMenu contextMenu, uint commandOffset)
        => string.Equals(GetCommandVerb(contextMenu, commandOffset), "rename", StringComparison.OrdinalIgnoreCase);

    private static string? GetCommandVerb(IContextMenu contextMenu, uint commandOffset)
    {
        var buffer = Marshal.AllocHGlobal(256 * sizeof(char));
        try
        {
            Marshal.WriteInt16(buffer, 0);
            return contextMenu.GetCommandString((UIntPtr)commandOffset, GetVerbUnicode, IntPtr.Zero, buffer, 256) >= 0
                ? Marshal.PtrToStringUni(buffer) : null;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void PrepareGenericMenu(IntPtr menu, IContextMenu contextMenu, IReadOnlyList<ShellMenuAction> actions)
    {
        var standardVerbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "properties", "copy", "copyaspath", "paste", "rename", "delete", "cut", "link", "open", "openas", "edit" };
        var openWithLabel = new StringBuilder(256);
        var shellModule = GetModuleHandle("shell32.dll");
        var hasOpenWithLabel = shellModule != IntPtr.Zero && LoadString(shellModule, 5376, openWithLabel, openWithLabel.Capacity) > 0;
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            if (hasOpenWithLabel && GetSubMenu(menu, index) != IntPtr.Zero &&
                (GetMenuState(menu, (uint)index, MenuByPosition) & MenuOwnerDrawn) != 0)
            {
                var label = new StringBuilder(256);
                _ = GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition);
                if (string.Equals(label.ToString(), openWithLabel.ToString(), StringComparison.Ordinal))
                {
                    if (!DeleteMenu(menu, (uint)index, MenuByPosition))
                        throw new InvalidOperationException("Could not remove the Open With submenu.");
                    continue;
                }
            }
            var id = GetMenuItemID(menu, index);
            if (id < FirstCommandId || id > LastCommandId)
                continue;
            var verb = GetCommandVerb(contextMenu, id - FirstCommandId);
            if (verb is null || (!standardVerbs.Contains(verb) && !BlacklistedVerbs.Value.Contains(verb)))
                continue;
            if (!RemoveMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not rearrange the Shell menu.");
        }

        var previousSeparator = true;
        for (var index = 0; index < GetMenuItemCount(menu);)
        {
            var separator = (GetMenuState(menu, (uint)index, MenuByPosition) & MenuSeparator) != 0;
            if (separator && (previousSeparator || index == GetMenuItemCount(menu) - 1))
            {
                if (!RemoveMenu(menu, (uint)index, MenuByPosition))
                    throw new InvalidOperationException("Could not rearrange the Shell menu.");
                continue;
            }
            previousSeparator = separator;
            index++;
        }

        if (GetMenuItemCount(menu) > 0 && !InsertMenu(menu, 0, MenuByPosition | MenuSeparator, UIntPtr.Zero, null))
            throw new InvalidOperationException("Could not insert the menu separator.");

        for (var index = actions.Count - 1; index >= 0; index--)
        {
            var id = GenericCommandFirst + (uint)index;
            if (!InsertMenu(menu, 0, MenuByPosition | (actions[index].IsEnabled ? 0u : MenuDisabled), (UIntPtr)id, actions[index].Label))
                throw new InvalidOperationException("Could not insert a standard menu command.");
        }
    }

    private static HashSet<string> LoadBlacklistedVerbs()
    {
        using var stream = typeof(ShellContextMenu).Assembly.GetManifestResourceStream(BlacklistResourceName)
            ?? throw new InvalidOperationException($"Embedded Shell extension blacklist '{BlacklistResourceName}' is missing.");
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.GetProperty("_type").GetString() != "shellExtensionBlacklist")
            throw new InvalidDataException("Invalid Shell extension blacklist type.");
        var verbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var extension in document.RootElement.GetProperty("extensions").EnumerateArray())
        {
            if (extension.GetProperty("_type").GetString() != "shellExtension" ||
                string.IsNullOrWhiteSpace(extension.GetProperty("name").GetString()))
                throw new InvalidDataException("Invalid Shell extension blacklist entry.");
            foreach (var verbElement in extension.GetProperty("verbs").EnumerateArray())
            {
                var verb = verbElement.GetString();
                if (string.IsNullOrWhiteSpace(verb))
                    throw new InvalidDataException("A blacklisted Shell verb is missing or empty.");
                verbs.Add(verb);
            }
        }
        return verbs;
    }

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

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHCreateDefaultContextMenu(ref DefaultContextMenu definition, ref Guid interfaceId, out IntPtr result);

    [DllImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ILRemoveLastID(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    private static extern IntPtr ILFindLastID(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    private static extern IntPtr ILCombine(IntPtr parent, IntPtr child);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetNameFromIDList(IntPtr itemIdList, uint nameType, out IntPtr name);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string moduleName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int LoadString(IntPtr module, uint resourceId, StringBuilder text, int length);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetMenuString(IntPtr menu, uint position, StringBuilder text, int length, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetSubMenu(IntPtr menu, int position);

    [DllImport("user32.dll")]
    private static extern uint GetMenuItemID(IntPtr menu, int position);

    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint position, uint flags);

    [DllImport("user32.dll")]
    private static extern bool RemoveMenu(IntPtr menu, uint position, uint flags);

    [DllImport("user32.dll")]
    private static extern bool DeleteMenu(IntPtr menu, uint position, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool InsertMenu(IntPtr menu, uint position, uint flags, UIntPtr id, string? text);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterClipboardFormat(string format);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("ole32.dll")]
    private static extern void ReleaseStgMedium(ref STGMEDIUM medium);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool SetWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId, UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, UIntPtr referenceData);

    [StructLayout(LayoutKind.Sequential)]
    private struct DefaultContextMenu
    {
        public IntPtr Owner;
        public IntPtr Callback;
        public IntPtr FolderPidl;
        public IntPtr Folder;
        public uint Count;
        public IntPtr Children;
        public IntPtr Association;
        public uint KeyCount;
        public IntPtr Keys;
    }

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

internal sealed record ShellMenuAction(string Label, bool IsEnabled, Action Invoke);

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