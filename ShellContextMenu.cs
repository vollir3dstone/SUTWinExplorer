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
    private const uint BaseMenuCommandFirst = 0x8000;
    private const uint ShellViewSelectEdit = 0x0003;
    private const string ShellIdListArrayFormat = "Shell IDList Array";
    private const string BlacklistResourceName = "SUTWinExplorer.ShellExtensionBlacklist.json";
    private const string DirectoryWhitelistResourceName = "SUTWinExplorer.DirectoryMenuWhitelist.json";
    private static readonly Lazy<HashSet<string>> BlacklistedVerbs = new(LoadBlacklistedVerbs);
    private static readonly Lazy<DirectoryMenuWhitelist> DirectoryWhitelist = new(LoadDirectoryWhitelist);
    private static readonly HashSet<string> ExcludedFileVerbs = new(StringComparer.OrdinalIgnoreCase)
        { "copy", "cut", "paste", "copyaspath", "link", "delete", "rename" };
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

    internal static IReadOnlyDictionary<string, int> ShowBase(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyList<ShellMenuAction> actions, Func<int, int, bool, bool, bool>? secondRightClick) =>
        ShowCore(paths, owner, background: false, rename: null, actions, secondRightClick: secondRightClick)!;

    internal static void ShowContent(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyDictionary<string, int> baseCommands, Func<int, int, bool, bool, bool>? secondRightClick = null) =>
        ShowCore(paths, owner, background: false, rename: null, excludedCommands: baseCommands, secondRightClick: secondRightClick);

    public static void ShowBackground(string folderPath, IntPtr owner) => ShowCore([folderPath], owner, background: true, rename: null);

    private static IReadOnlyDictionary<string, int>? ShowCore(IReadOnlyList<string> paths, IntPtr owner, bool background, Action? rename,
        IReadOnlyList<ShellMenuAction>? actions = null, IReadOnlyDictionary<string, int>? excludedCommands = null, Func<int, int, bool, bool, bool>? secondRightClick = null)
    {
        var isBaseMenu = actions is not null;
        IReadOnlyDictionary<string, int>? baseCommands = null;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("The Windows Shell context menu must be opened from an STA thread.");
        if (paths.Count == 0)
            throw new ArgumentException("At least one item is required.", nameof(paths));
        if (paths.Count > 1 && paths.Skip(1).Any(path => !string.Equals(Path.GetDirectoryName(path),
                Path.GetDirectoryName(paths[0]), StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Selected items must belong to the same directory.", nameof(paths));

        var directorySelection = !background && paths.All(Directory.Exists);
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
        MenuMessageFilter? menuFilter = null;
        IntPtr menuHook = IntPtr.Zero;
        var subclassInstalled = false;
        using var fileClass = isBaseMenu && !directorySelection ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("*") : null;
        using var filesystemClass = isBaseMenu ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("AllFilesystemObjects") : null;

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
                if (!isBaseMenu)
                    contextMenu = GetItemContextMenu(parentFolder, owner, paths.Count, childPidlArray);
                else
                {
                    if (filesystemClass is null || (!directorySelection && fileClass is null))
                        throw new InvalidOperationException("The generic Shell association classes are unavailable.");
                    var keyCount = fileClass is null ? 1 : 2;
                    keyArray = Marshal.AllocCoTaskMem(IntPtr.Size * keyCount);
                    if (fileClass is not null)
                        Marshal.WriteIntPtr(keyArray, 0, fileClass.Handle.DangerousGetHandle());
                    Marshal.WriteIntPtr(keyArray, IntPtr.Size * (keyCount - 1), filesystemClass.Handle.DangerousGetHandle());
                    parentPointer = Marshal.GetComInterfaceForObject(parentFolder, typeof(IShellFolder));
                    var definition = new DefaultContextMenu
                    {
                        Owner = owner,
                        Folder = parentPointer,
                        Count = (uint)paths.Count,
                        Children = childPidlArray,
                        KeyCount = (uint)keyCount,
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
                isBaseMenu || rename is not null || excludedCommands is not null
                    ? MenuFlags | MenuCanRename : MenuFlags));
            if (isBaseMenu)
            {
                if (directorySelection)
                {
                    var filesystemCommands = CollectComparableCommands(menu, contextMenu, includeDisabled: true);
                    (HashSet<string> Verbs, HashSet<string> WildcardVerbs, HashSet<string> DirectoryOnlyVerbs, Dictionary<string, int> Commands, HashSet<string> WildcardLabels) sharedCommands =
                        (new HashSet<string>(StringComparer.OrdinalIgnoreCase), new HashSet<string>(StringComparer.OrdinalIgnoreCase),
                            new HashSet<string>(StringComparer.OrdinalIgnoreCase), new Dictionary<string, int>(StringComparer.Ordinal),
                            new HashSet<string>(StringComparer.Ordinal));
                    try { sharedCommands = CollectSharedDirectoryCommands(parentFolder!, owner, paths.Count, childPidlArray, absolutePidls[0]); }
                    catch (Exception exception) { System.Diagnostics.Trace.TraceError("Could not read directory context menu registrations: {0}", exception); }
                    _ = DestroyMenu(menu);
                    menu = IntPtr.Zero;
                    _ = Marshal.ReleaseComObject(contextMenu);
                    contextMenu = null;
                    contextMenu = GetItemContextMenu(parentFolder!, owner, paths.Count, childPidlArray);
                    menu = CreatePopupMenu();
                    if (menu == IntPtr.Zero)
                        throw new InvalidOperationException("CreatePopupMenu failed.");
                    Marshal.ThrowExceptionForHR(contextMenu.QueryContextMenu(menu, 0, FirstCommandId, LastCommandId, MenuFlags | MenuCanRename));
                    FilterDirectoryBaseMenu(menu, contextMenu, filesystemCommands, sharedCommands);
                }
                PrepareBaseMenu(menu, contextMenu, actions!, directorySelection);
                RemoveExcludedFileCommands(menu, contextMenu, directorySelection);
            }
            else if (excludedCommands is not null)
                PrepareContentMenu(menu, contextMenu, excludedCommands, directorySelection);
            InstallMenuMessageForwarder(owner, contextMenu, isBaseMenu || excludedCommands is not null, excludedCommands is not null, directorySelection, out subclassProc);
            subclassInstalled = true;
            var point = GetCursorPosition();
            if (secondRightClick is not null)
            {
                menuFilter = (code, wParam, lParam) =>
                {
                    if (code == 2 && lParam != IntPtr.Zero && Marshal.PtrToStructure<MenuMessage>(lParam) is { Message: 0x0204 or 0x0206 } message)
                    {
                        try
                        {
                            var clickPoint = message.Point;
                            var targetWindow = WindowFromPoint(clickPoint);
                            var overOwner = targetWindow == owner || IsChild(owner, targetWindow);
                            if (!overOwner &&
                                Math.Abs(clickPoint.X - point.X) <= GetSystemMetrics(36) / 2 &&
                                Math.Abs(clickPoint.Y - point.Y) <= GetSystemMetrics(37) / 2 &&
                                GetWindowThreadProcessId(targetWindow, out _) == GetCurrentThreadId())
                            {
                                var className = new StringBuilder(32);
                                _ = GetClassName(targetWindow, className, className.Capacity);
                                overOwner = className.ToString() == "#32768" &&
                                    SendMessage(targetWindow, 0x01E1, IntPtr.Zero, IntPtr.Zero) == menu;
                            }
                            if (secondRightClick(clickPoint.X, clickPoint.Y, overOwner, (message.WParam.ToInt64() & 0x0004) != 0))
                            {
                                _ = PostMessage(owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
                                return new IntPtr(1);
                            }
                        }
                        catch (Exception exception)
                        {
                            System.Diagnostics.Trace.TraceError("Context menu right-click handling failed: {0}", exception);
                        }
                    }
                    return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
                };
                menuHook = SetWindowsHookEx(-1, menuFilter, IntPtr.Zero, GetCurrentThreadId());
                if (menuHook == IntPtr.Zero)
                    throw new InvalidOperationException("Could not monitor the native menu for a second right-click.");
            }

            _ = SetForegroundWindow(owner);
            var commandId = TrackPopupMenuEx(menu, isBaseMenu || excludedCommands is not null ? PopupFlags & ~0x0002u : PopupFlags, point.X, point.Y, owner, IntPtr.Zero);
            if (isBaseMenu)
                baseCommands = CollectComparableCommands(menu, contextMenu, allowVerbless: directorySelection);
            _ = PostMessage(owner, 0, IntPtr.Zero, IntPtr.Zero);

            if (commandId != 0)
            {
                if (actions is not null && commandId >= BaseMenuCommandFirst)
                {
                    var index = commandId - BaseMenuCommandFirst;
                    if (index < actions.Count && actions[(int)index].IsEnabled)
                        actions[(int)index].Invoke();
                    return baseCommands;
                }
                if (rename is not null && IsRenameCommand(contextMenu, commandId - FirstCommandId))
                {
                    rename();
                    return baseCommands;
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
            return baseCommands;
        }
        finally
        {
            if (menuHook != IntPtr.Zero)
                _ = UnhookWindowsHookEx(menuHook);
            GC.KeepAlive(menuFilter);
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

    private static IContextMenu GetItemContextMenu(IShellFolder parent, IntPtr owner, int count, IntPtr children)
    {
        var interfaceId = typeof(IContextMenu).GUID;
        Marshal.ThrowExceptionForHR(parent.GetUIObjectOf(owner, (uint)count, children, ref interfaceId, IntPtr.Zero, out var pointer));
        try { return (IContextMenu)Marshal.GetObjectForIUnknown(pointer); }
        finally { _ = Marshal.Release(pointer); }
    }

    private static (HashSet<string> Verbs, HashSet<string> WildcardVerbs, HashSet<string> DirectoryOnlyVerbs, Dictionary<string, int> Commands, HashSet<string> WildcardLabels) CollectSharedDirectoryCommands(
        IShellFolder parent, IntPtr owner, int count, IntPtr children, IntPtr itemPidl)
    {
        var verbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var wildcardVerbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var directoryOnlyVerbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var wildcardLabels = new HashSet<string>(StringComparer.Ordinal);
        var handlers = new Dictionary<Guid, List<string>>();
        var whitelist = DirectoryWhitelist.Value;
        using var fileVerbs = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(@"*\shell");
        using var fileHandlers = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(@"*\shellex\ContextMenuHandlers");
        var fileVerbNames = new HashSet<string>(fileVerbs?.GetSubKeyNames() ?? [], StringComparer.OrdinalIgnoreCase);
        var fileHandlerIds = GetHandlerIds(fileHandlers);
        foreach (var className in new[] { "Directory", "Folder" })
        {
            using var directoryVerbs = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(className + @"\shell");
            verbs.UnionWith(GetEligibleDirectoryVerbs(directoryVerbs, fileVerbNames, whitelist));
            if (directoryVerbs is not null)
            {
                directoryOnlyVerbs.UnionWith(directoryVerbs.GetSubKeyNames());
                wildcardVerbs.UnionWith(directoryVerbs.GetSubKeyNames().Where(fileVerbNames.Contains));
            }
            using var directoryHandlers = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(className + @"\shellex\ContextMenuHandlers");
            foreach (var handler in GetHandlerIds(directoryHandlers))
                if (IsEligibleDirectoryHandler(handler, fileHandlerIds, whitelist.HandlerIds))
                {
                    if (!handlers.TryGetValue(handler, out var classes))
                        handlers[handler] = classes = [];
                    classes.Add(className);
                }
        }

        directoryOnlyVerbs.ExceptWith(verbs);
        var commands = new Dictionary<string, int>(StringComparer.Ordinal);
        if (handlers.Count == 0)
            return (verbs, wildcardVerbs, directoryOnlyVerbs, commands, wildcardLabels);
        IntPtr dataPointer = IntPtr.Zero;
        IntPtr folderPidl = IntPtr.Zero;
        try
        {
            var dataId = typeof(IDataObject).GUID;
            Marshal.ThrowExceptionForHR(parent.GetUIObjectOf(owner, (uint)count, children, ref dataId, IntPtr.Zero, out dataPointer));
            folderPidl = ILClone(itemPidl);
            if (folderPidl == IntPtr.Zero || !ILRemoveLastID(folderPidl))
                throw new InvalidOperationException("Could not obtain the parent PIDL.");
            foreach (var (handlerId, classNames) in handlers)
            {
                var handlerCommands = new Dictionary<string, int>(StringComparer.Ordinal);
                foreach (var className in classNames)
                {
                    object? instance = null;
                    IntPtr pointer = IntPtr.Zero;
                    IntPtr handlerMenu = IntPtr.Zero;
                    try
                    {
                        using var classKey = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(className);
                        if (classKey is null)
                            continue;
                        var classId = handlerId;
                        var initId = typeof(IShellExtInit).GUID;
                        Marshal.ThrowExceptionForHR(CoCreateInstance(ref classId, IntPtr.Zero, 1, ref initId, out pointer));
                        instance = Marshal.GetObjectForIUnknown(pointer);
                        Marshal.ThrowExceptionForHR(((IShellExtInit)instance).Initialize(folderPidl, dataPointer, classKey.Handle.DangerousGetHandle()));
                        var handlerMenuContext = (IContextMenu)instance;
                        handlerMenu = CreatePopupMenu();
                        if (handlerMenu == IntPtr.Zero)
                            throw new InvalidOperationException("CreatePopupMenu failed.");
                        Marshal.ThrowExceptionForHR(handlerMenuContext.QueryContextMenu(handlerMenu, 0, FirstCommandId, LastCommandId, MenuFlags | MenuCanRename));
                        if (fileHandlerIds.Contains(handlerId))
                            wildcardLabels.UnionWith(CollectMenuLabels(handlerMenu));
                        foreach (var (command, occurrences) in CollectComparableCommands(handlerMenu, handlerMenuContext, includeDisabled: true, allowVerbless: true))
                            handlerCommands[command] = Math.Max(handlerCommands.GetValueOrDefault(command), occurrences);
                    }
                    catch (Exception exception)
                    {
                        System.Diagnostics.Trace.TraceError("Could not inspect directory context menu handler {0}: {1}", handlerId, exception);
                    }
                    finally
                    {
                        if (handlerMenu != IntPtr.Zero) _ = DestroyMenu(handlerMenu);
                        if (instance is not null && Marshal.IsComObject(instance)) _ = Marshal.ReleaseComObject(instance);
                        if (pointer != IntPtr.Zero) _ = Marshal.Release(pointer);
                    }
                }
                foreach (var (command, occurrences) in handlerCommands)
                    commands[command] = commands.GetValueOrDefault(command) + occurrences;
            }
        }
        catch (Exception exception)
        {
            System.Diagnostics.Trace.TraceError("Could not inspect directory context menu handlers: {0}", exception);
        }
        finally
        {
            if (folderPidl != IntPtr.Zero) Marshal.FreeCoTaskMem(folderPidl);
            if (dataPointer != IntPtr.Zero) _ = Marshal.Release(dataPointer);
        }
        return (verbs, wildcardVerbs, directoryOnlyVerbs, commands, wildcardLabels);
    }

    private static HashSet<string> CollectMenuLabels(IntPtr menu)
    {
        var labels = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            var label = MenuLabelKey(menu, index);
            if (label is not null)
                labels.Add(label);
        }
        return labels;
    }

    private static string? MenuLabelKey(IntPtr menu, int index)
    {
        var state = GetMenuState(menu, (uint)index, MenuByPosition);
        if (state == uint.MaxValue || (state & MenuSeparator) != 0)
            return null;
        var label = new StringBuilder(512);
        var length = GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition);
        return length > 0 && length < label.Capacity - 1
            ? (GetSubMenu(menu, index) != IntPtr.Zero ? "submenu\0" : "item\0") + label : null;
    }

    private static bool IsWildcardDirectoryMatch(string? verb, string? label, HashSet<string> wildcardVerbs,
        HashSet<string> directoryOnlyVerbs, HashSet<string> wildcardLabels) =>
        (verb is not null && wildcardVerbs.Contains(verb)) ||
        ((verb is null || !directoryOnlyVerbs.Contains(verb)) && label is not null && wildcardLabels.Contains(label));

    private static bool IsEligibleDirectoryHandler(Guid handler, HashSet<Guid> fileHandlerIds, HashSet<Guid> whitelistedHandlerIds) =>
        fileHandlerIds.Contains(handler) || whitelistedHandlerIds.Contains(handler);

    private static HashSet<string> GetEligibleDirectoryVerbs(Microsoft.Win32.RegistryKey? directoryVerbs,
        HashSet<string> fileVerbNames, DirectoryMenuWhitelist whitelist)
    {
        var verbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (directoryVerbs is null)
            return verbs;
        foreach (var name in directoryVerbs.GetSubKeyNames())
        {
            if (fileVerbNames.Contains(name) || whitelist.Verbs.Contains(name))
            {
                verbs.Add(name);
                continue;
            }
            using var entry = directoryVerbs.OpenSubKey(name);
            if (Guid.TryParse(entry?.GetValue("ExplorerCommandHandler") as string, out var handlerId) &&
                whitelist.HandlerIds.Contains(handlerId))
                verbs.Add(name);
        }
        return verbs;
    }

    private static HashSet<Guid> GetHandlerIds(Microsoft.Win32.RegistryKey? key)
    {
        var handlers = new HashSet<Guid>();
        if (key is null)
            return handlers;
        foreach (var name in key.GetSubKeyNames())
        {
            using var entry = key.OpenSubKey(name);
            var value = entry?.GetValue(null) as string;
            if (value is not null && value.StartsWith('-'))
                continue;
            if (Guid.TryParse(value, out var handler) || Guid.TryParse(name, out handler))
                handlers.Add(handler);
        }
        return handlers;
    }

    private static void FilterDirectoryBaseMenu(IntPtr menu, IContextMenu contextMenu,
        IReadOnlyDictionary<string, int> filesystemCommands,
        (HashSet<string> Verbs, HashSet<string> WildcardVerbs, HashSet<string> DirectoryOnlyVerbs, Dictionary<string, int> Commands, HashSet<string> WildcardLabels) shared)
    {
        var nativeCommands = CollectComparableCommands(menu, contextMenu, includeDisabled: true, allowVerbless: true);
        var nativeVerbs = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            var id = GetMenuItemID(menu, index);
            if (id >= FirstCommandId && id <= LastCommandId && GetCommandVerb(contextMenu, id - FirstCommandId) is { Length: > 0 } verb)
                nativeVerbs[verb] = nativeVerbs.GetValueOrDefault(verb) + 1;
        }
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var id = GetMenuItemID(menu, index);
            var verb = id >= FirstCommandId && id <= LastCommandId ? GetCommandVerb(contextMenu, id - FirstCommandId) : null;
            var command = ComparableCommand(menu, contextMenu, index, includeDisabled: true, allowVerbless: true);
            var label = MenuLabelKey(menu, index);
            if (string.Equals(verb, "properties", StringComparison.OrdinalIgnoreCase) ||
                IsWildcardDirectoryMatch(verb, label, shared.WildcardVerbs, shared.DirectoryOnlyVerbs, shared.WildcardLabels) ||
                (verb is not null && shared.Verbs.Contains(verb) && nativeVerbs[verb] == 1) ||
                (command is not null && nativeCommands.TryGetValue(command, out var nativeCount) && nativeCount == 1 &&
                    ((filesystemCommands.TryGetValue(command, out var filesystemCount) && filesystemCount == 1) ||
                     (shared.Commands.TryGetValue(command, out var sharedCount) && sharedCount == 1))))
                continue;
            var removed = GetSubMenu(menu, index) != IntPtr.Zero
                ? DeleteMenu(menu, (uint)index, MenuByPosition)
                : RemoveMenu(menu, (uint)index, MenuByPosition);
            if (!removed)
                throw new InvalidOperationException("Could not filter the directory Base Menu.");
        }
    }

    private static void PrepareBaseMenu(IntPtr menu, IContextMenu contextMenu, IReadOnlyList<ShellMenuAction> actions, bool directorySelection)
    {
        var standardVerbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "copy", "copyaspath", "paste", "rename", "delete", "cut" };
        if (!directorySelection)
            standardVerbs.UnionWith(["link", "open", "openas", "edit"]);
        var openWithLabel = new StringBuilder(256);
        var shellModule = GetModuleHandle("shell32.dll");
        var hasOpenWithLabel = shellModule != IntPtr.Zero && LoadString(shellModule, 5376, openWithLabel, openWithLabel.Capacity) > 0;
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            if (!directorySelection && hasOpenWithLabel && GetSubMenu(menu, index) != IntPtr.Zero &&
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
            if (verb is null || (!standardVerbs.Contains(verb) && (directorySelection || !BlacklistedVerbs.Value.Contains(verb))))
                continue;
            if (!RemoveMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not rearrange the Shell menu.");
        }

        RemoveRedundantSeparators(menu);

        if (GetMenuItemCount(menu) > 0 && !InsertMenu(menu, 0, MenuByPosition | MenuSeparator, UIntPtr.Zero, null))
            throw new InvalidOperationException("Could not insert the menu separator.");

        for (var index = actions.Count - 1; index >= 0; index--)
        {
            var id = BaseMenuCommandFirst + (uint)index;
            if (!InsertMenu(menu, 0, MenuByPosition | (actions[index].IsEnabled ? 0u : MenuDisabled), (UIntPtr)id, actions[index].Label))
                throw new InvalidOperationException("Could not insert a standard menu command.");
        }
    }

    private static string? ComparableCommand(IntPtr menu, IContextMenu contextMenu, int index, bool includeDisabled = false, bool allowVerbless = false)
    {
        var state = GetMenuState(menu, (uint)index, MenuByPosition);
        if (state == uint.MaxValue || (state & MenuSeparator) != 0 || (!includeDisabled && (state & MenuDisabled) != 0))
            return null;
        var label = new StringBuilder(512);
        var labelLength = GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition);
        if (labelLength == 0 || labelLength >= label.Capacity - 1)
            return null;
        var submenu = GetSubMenu(menu, index);
        if (submenu != IntPtr.Zero)
        {
            var leafCount = 0;
            var verbCount = 0;
            var contents = ComparableSubmenu(submenu, contextMenu, ref leafCount, ref verbCount, includeDisabled);
            return contents is not null && (verbCount > 0 || leafCount > 1)
                ? "submenu\0" + JsonSerializer.Serialize(new[] { label.ToString(), contents }) : null;
        }
        var id = GetMenuItemID(menu, index);
        if ((state & MenuOwnerDrawn) != 0 || id < FirstCommandId || id > LastCommandId)
            return null;
        var verb = GetCommandVerb(contextMenu, id - FirstCommandId);
        if (string.IsNullOrWhiteSpace(verb))
            return allowVerbless ? "label\0" + label : null;
        return verb.ToUpperInvariant() + "\0" + label;
    }

    private static string? ComparableSubmenu(IntPtr menu, IContextMenu contextMenu, ref int leafCount, ref int verbCount, bool includeDisabled)
    {
        var entries = new List<string>();
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            var state = GetMenuState(menu, (uint)index, MenuByPosition);
            if (state == uint.MaxValue)
                return null;
            if ((state & MenuSeparator) != 0)
                continue;
            if (!includeDisabled && (state & MenuDisabled) != 0)
                return null;
            var label = new StringBuilder(512);
            var labelLength = GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition);
            if (labelLength == 0 || labelLength >= label.Capacity - 1)
                return null;
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero)
            {
                var contents = ComparableSubmenu(submenu, contextMenu, ref leafCount, ref verbCount, includeDisabled);
                if (contents is null)
                    return null;
                entries.Add(JsonSerializer.Serialize(new[] { "submenu", label.ToString(), contents }));
            }
            else
            {
                var id = GetMenuItemID(menu, index);
                if (id < FirstCommandId || id > LastCommandId)
                    return null;
                var verb = GetCommandVerb(contextMenu, id - FirstCommandId);
                leafCount++;
                if (!string.IsNullOrWhiteSpace(verb))
                    verbCount++;
                entries.Add(JsonSerializer.Serialize(new[] { "command", label.ToString(), verb?.ToUpperInvariant() ?? "" }));
            }
        }
        return entries.Count > 0 ? JsonSerializer.Serialize(entries) : null;
    }

    private static Dictionary<string, int> CollectComparableCommands(IntPtr menu, IContextMenu contextMenu, bool includeDisabled = false, bool allowVerbless = false)
    {
        var commands = new Dictionary<string, int>(StringComparer.Ordinal);
        var labels = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            if (allowVerbless)
            {
                var label = new StringBuilder(512);
                var length = GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition);
                if (length > 0 && length < label.Capacity - 1)
                    labels[label.ToString()] = labels.GetValueOrDefault(label.ToString()) + 1;
            }
            var command = ComparableCommand(menu, contextMenu, index, includeDisabled, allowVerbless);
            if (command is not null)
                commands[command] = commands.GetValueOrDefault(command) + 1;
        }
        foreach (var (label, occurrences) in labels)
            if (occurrences != 1)
                commands.Remove("label\0" + label);
        return commands;
    }

    private static void PrepareContentMenu(IntPtr menu, IContextMenu contextMenu, IReadOnlyDictionary<string, int> baseCommands, bool directorySelection)
    {
        RemoveExcludedFileCommands(menu, contextMenu, directorySelection, isContentMenu: true);
        var contentCommands = CollectComparableCommands(menu, contextMenu, allowVerbless: directorySelection);
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var command = ComparableCommand(menu, contextMenu, index, allowVerbless: directorySelection);
            if (command is not null && baseCommands.TryGetValue(command, out var baseCount) && baseCount == 1 &&
                contentCommands.TryGetValue(command, out var contentCount) && contentCount == 1)
            {
                var removed = GetSubMenu(menu, index) != IntPtr.Zero
                    ? DeleteMenu(menu, (uint)index, MenuByPosition)
                    : RemoveMenu(menu, (uint)index, MenuByPosition);
                if (!removed)
                    throw new InvalidOperationException("Could not rearrange the Shell menu.");
            }
        }
        RemoveRedundantSeparators(menu);
    }

    private static void RemoveExcludedFileCommands(IntPtr menu, IContextMenu contextMenu, bool directorySelection, bool isContentMenu = false)
    {
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero)
                RemoveExcludedFileCommands(submenu, contextMenu, directorySelection, isContentMenu);
            var id = GetMenuItemID(menu, index);
            if (id >= FirstCommandId && id <= LastCommandId &&
                GetCommandVerb(contextMenu, id - FirstCommandId) is { } verb &&
                ((ExcludedFileVerbs.Contains(verb) && (!directorySelection || !string.Equals(verb, "link", StringComparison.OrdinalIgnoreCase))) ||
                 (isContentMenu && string.Equals(verb, "properties", StringComparison.OrdinalIgnoreCase))) &&
                !RemoveMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not remove a Shell file command.");
        }
        RemoveRedundantSeparators(menu);
    }

    private static void RemoveRedundantSeparators(IntPtr menu)
    {
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

    private static DirectoryMenuWhitelist LoadDirectoryWhitelist()
    {
        using var stream = typeof(ShellContextMenu).Assembly.GetManifestResourceStream(DirectoryWhitelistResourceName)
            ?? throw new InvalidOperationException($"Embedded directory menu whitelist '{DirectoryWhitelistResourceName}' is missing.");
        using var document = JsonDocument.Parse(stream);
        return ParseDirectoryWhitelist(document);
    }

    private static DirectoryMenuWhitelist ParseDirectoryWhitelist(JsonDocument document)
    {
        if (document.RootElement.GetProperty("_type").GetString() != "directoryMenuWhitelist")
            throw new InvalidDataException("Invalid directory menu whitelist type.");
        var verbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var handlerIds = new HashSet<Guid>();
        foreach (var extension in document.RootElement.GetProperty("extensions").EnumerateArray())
        {
            if (extension.GetProperty("_type").GetString() != "shellExtension" ||
                string.IsNullOrWhiteSpace(extension.GetProperty("name").GetString()))
                throw new InvalidDataException("Invalid directory menu whitelist entry.");
            foreach (var element in extension.GetProperty("verbs").EnumerateArray())
            {
                var verb = element.GetString();
                if (string.IsNullOrWhiteSpace(verb))
                    throw new InvalidDataException("A whitelisted Shell verb is missing or empty.");
                verbs.Add(verb);
            }
            foreach (var element in extension.GetProperty("clsids").EnumerateArray())
            {
                if (!Guid.TryParse(element.GetString(), out var handlerId) || handlerId == Guid.Empty)
                    throw new InvalidDataException("A whitelisted Shell handler CLSID is invalid.");
                handlerIds.Add(handlerId);
            }
        }
        return new DirectoryMenuWhitelist(verbs, handlerIds);
    }

    private sealed record DirectoryMenuWhitelist(HashSet<string> Verbs, HashSet<Guid> HandlerIds);

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

    private static void InstallMenuMessageForwarder(IntPtr owner, IContextMenu contextMenu, bool excludeFileCommands, bool isContentMenu, bool directorySelection, out SubclassProc callback)
    {
        var menu3 = contextMenu as IContextMenu3;
        var menu2 = contextMenu as IContextMenu2;
        callback = (hwnd, message, wParam, lParam, subclassId, referenceData) =>
        {
            try
            {
                if (message is 0x0117 or 0x002B or 0x002C or 0x0120)
                {
                    var handled = false;
                    var menuResult = IntPtr.Zero;
                    if (menu3 is not null)
                    {
                        handled = menu3.HandleMenuMsg2(message, wParam, lParam, out menuResult) >= 0;
                    }
                    else if (menu2 is not null && menu2.HandleMenuMsg(message, wParam, lParam) >= 0)
                    {
                        handled = true;
                    }
                    if (excludeFileCommands && message == 0x0117 && wParam != IntPtr.Zero)
                        RemoveExcludedFileCommands(wParam, contextMenu, directorySelection, isContentMenu);
                    if (handled)
                        return menuResult;
                }
            }
            catch (Exception exception)
            {
                System.Diagnostics.Trace.TraceError("Context menu message forwarding failed: {0}", exception);
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
    private static extern IntPtr ILClone(IntPtr itemIdList);

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(ref Guid classId, IntPtr outer, uint context, ref Guid interfaceId, out IntPtr result);

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
    private static extern IntPtr WindowFromPoint(NativePoint point);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maximum);

    [DllImport("user32.dll")]
    private static extern bool IsChild(IntPtr parent, IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hook, MenuMessageFilter callback, IntPtr module, uint threadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

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

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr MenuMessageFilter(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MenuMessage
    {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public NativePoint Point;
    }

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
    [PreserveSig] int GetUIObjectOf(IntPtr owner, uint count, IntPtr itemIdLists, ref Guid interfaceId, IntPtr reserved, out IntPtr result);
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

[ComImport]
[Guid("000214E8-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellExtInit
{
    [PreserveSig] int Initialize(IntPtr folder, IntPtr dataObject, IntPtr key);
}