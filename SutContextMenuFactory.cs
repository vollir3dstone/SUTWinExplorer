using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.Json;

namespace SUTWinExplorer;

internal static class SutContextMenuFactory
{
    private const uint FirstCommandId = 1;
    private const uint LastCommandId = 0x7FFF;
    private const uint MenuFlags = 0;
    private const uint MenuCanRename = 0x00000010;
    private const uint GetVerbUnicode = 0x00000004;
    private const uint MenuByPosition = 0x00000400;
    private const uint MenuDisabled = 0x00000003;
    private const uint MenuSeparator = 0x00000800;
    private const uint MenuOwnerDrawn = 0x00000100;
    private const uint BaseMenuCommandFirst = 0x8000;
    private const string BlacklistResourceName = "SUTWinExplorer.ShellExtensionBlacklist.json";
    private const string DirectoryWhitelistResourceName = "SUTWinExplorer.DirectoryMenuWhitelist.json";
    private static readonly Lazy<HashSet<string>> BlacklistedVerbs = new(LoadBlacklistedVerbs);
    private static readonly Lazy<DirectoryMenuWhitelist> DirectoryWhitelist = new(LoadDirectoryWhitelist);
    private static readonly Lazy<HashSet<string>> BackgroundViewLabels = new(() => LoadShellMenuLabels(37460, 37462));
    private static readonly Lazy<HashSet<string>> BackgroundNewLabels = new(() => LoadShellMenuLabels(30315));
    private static readonly HashSet<string> ExcludedBackgroundVerbs = new(StringComparer.OrdinalIgnoreCase)
        { "refresh", "viewcustomwizard" };
    private static readonly HashSet<string> ExcludedFileVerbs = new(StringComparer.OrdinalIgnoreCase)
        { "copy", "cut", "paste", "copyaspath", "link", "delete", "rename" };
    internal static SutContextMenu GetItemMenu(IReadOnlyList<string> paths, IntPtr owner, Action? rename = null) =>
        CreateCore(paths, owner, background: false, rename);

    internal static SutContextMenu GetItemMenuWithOpenLocation(IReadOnlyList<string> paths, IntPtr owner, Action? rename, ShellMenuAction? openLocation) =>
        CreateCore(paths, owner, background: false, rename, openLocationAction: openLocation);

    internal static SutContextMenu GetBackgroundMenu(string directoryPath, IntPtr owner) =>
        CreateCore([directoryPath], owner, background: true, rename: null);

    internal static SutContextMenu GetBackgroundBaseMenu(string directoryPath, IntPtr owner, IReadOnlyList<ShellMenuAction> actions)
    {
        using var directoryMenu = GetBaseMenu([directoryPath], owner, []);
        return CreateCore([directoryPath], owner, background: true, rename: null, actions,
            backgroundBaseCommands: directoryMenu.CaptureSnapshot());
    }

    internal static SutContextMenu GetBackgroundContentMenu(string directoryPath, IntPtr owner, IReadOnlyDictionary<string, int> baseCommands, ShellMenuAction? newAction) =>
        CreateCore([directoryPath], owner, background: true, rename: null, excludedCommands: baseCommands, backgroundNewAction: newAction);

    internal static SutContextMenu GetBaseMenu(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyList<ShellMenuAction> actions) =>
        CreateCore(paths, owner, background: false, rename: null, actions);

    internal static SutContextMenu GetContentMenu(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyDictionary<string, int> baseCommands) =>
        CreateCore(paths, owner, background: false, rename: null, excludedCommands: baseCommands);

    internal static SutContextMenu GetBaseMenuForContext(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyList<ShellMenuAction> actions, bool background) =>
        background ? GetBackgroundBaseMenu(paths[0], owner, actions) : GetBaseMenu(paths, owner, actions);

    internal static SutContextMenu GetContentMenuForContext(IReadOnlyList<string> paths, IntPtr owner, IReadOnlyDictionary<string, int> baseCommands, bool background, ShellMenuAction? newAction, ShellMenuAction? openLocation) =>
        background ? GetBackgroundContentMenu(paths[0], owner, baseCommands, newAction) :
            CreateCore(paths, owner, background: false, rename: null, excludedCommands: baseCommands, openLocationAction: openLocation);

    private static SutContextMenu CreateCore(IReadOnlyList<string> paths, IntPtr owner, bool background, Action? rename,
        IReadOnlyList<ShellMenuAction>? actions = null, IReadOnlyDictionary<string, int>? excludedCommands = null,
        IReadOnlyDictionary<string, int>? backgroundBaseCommands = null, ShellMenuAction? backgroundNewAction = null,
        ShellMenuAction? openLocationAction = null)
    {
        var isBaseMenu = actions is not null;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("The Windows Shell context menu must be opened from an STA thread.");
        if (paths.Count == 0)
            throw new ArgumentException("At least one item is required.", nameof(paths));
        if (paths.Count > 1 && paths.Skip(1).Any(path => !string.Equals(Path.GetDirectoryName(path),
                Path.GetDirectoryName(paths[0]), StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Selected items must belong to the same directory.", nameof(paths));

        var directorySelection = !background && paths.All(Directory.Exists);
        var shortcutSelection = !background && paths.Any(path => string.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase));
        var absolutePidls = new List<IntPtr>();
        var menuBitmaps = new List<IntPtr>();
        IntPtr childPidlArray = IntPtr.Zero;
        IntPtr menu = IntPtr.Zero;
        IntPtr keyArray = IntPtr.Zero;
        IntPtr parentPointer = IntPtr.Zero;
        IShellFolder? desktopFolder = null;
        IShellFolder? parentFolder = null;
        IShellFolder? targetFolder = null;
        IShellView? shellView = null;
        IContextMenu? contextMenu = null;
        Microsoft.Win32.RegistryKey? fileClass = null;
        Microsoft.Win32.RegistryKey? filesystemClass = null;

        void Release()
        {
            if (menu != IntPtr.Zero) _ = DestroyMenu(menu);
            foreach (var bitmap in menuBitmaps) ShellMenuIcons.Release(bitmap);
            if (contextMenu is not null && Marshal.IsComObject(contextMenu)) _ = Marshal.FinalReleaseComObject(contextMenu);
            if (parentFolder is not null && Marshal.IsComObject(parentFolder)) _ = Marshal.FinalReleaseComObject(parentFolder);
            if (targetFolder is not null && Marshal.IsComObject(targetFolder)) _ = Marshal.FinalReleaseComObject(targetFolder);
            if (shellView is not null && Marshal.IsComObject(shellView)) _ = Marshal.FinalReleaseComObject(shellView);
            if (desktopFolder is not null && Marshal.IsComObject(desktopFolder)) _ = Marshal.FinalReleaseComObject(desktopFolder);
            if (parentPointer != IntPtr.Zero) _ = Marshal.Release(parentPointer);
            if (keyArray != IntPtr.Zero) Marshal.FreeCoTaskMem(keyArray);
            if (childPidlArray != IntPtr.Zero) Marshal.FreeCoTaskMem(childPidlArray);
            foreach (var absolutePidl in absolutePidls) Marshal.FreeCoTaskMem(absolutePidl);
            fileClass?.Dispose();
            filesystemClass?.Dispose();
        }

        try
        {
            fileClass = isBaseMenu && !background && !directorySelection ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("*") : null;
            filesystemClass = isBaseMenu && !background ? Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("AllFilesystemObjects") : null;
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
                Marshal.ThrowExceptionForHR(shellView.GetItemObject(ShellViewOperations.Background, ref contextMenuId, out var contextMenuPointer));
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
            if (background && (isBaseMenu || excludedCommands is not null))
                RemoveBackgroundViewMenus(menu, contextMenu);
            if (isBaseMenu)
            {
                if (background)
                {
                    FilterBackgroundBaseMenu(menu, contextMenu, backgroundBaseCommands!);
                    if (actions!.Count > 0) RemoveShellProperties(menu, contextMenu);
                }
                else if (directorySelection)
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
                if (!background)
                {
                    PrepareBaseMenu(menu, contextMenu, directorySelection, actions!.Count > 0);
                    RemoveExcludedFileCommands(menu, contextMenu, directorySelection);
                    if (shortcutSelection) RemoveOpenContaining(menu, contextMenu);
                }
                if (actions!.Count > 0)
                {
                    InsertActions(menu, actions);
                    ShellMenuIcons.Apply(menu, actions, BaseMenuCommandFirst, menuBitmaps);
                }
            }
            else if (excludedCommands is not null)
            {
                PrepareContentMenu(menu, contextMenu, excludedCommands, directorySelection, background);
                if (background) RemoveShellProperties(menu, contextMenu);
            }
            if (background && excludedCommands is not null && backgroundNewAction is not null)
            {
                ReplaceBackgroundNew(menu, backgroundNewAction);
                actions = [backgroundNewAction];
            }
            if (openLocationAction is not null)
            {
                if (!ReplaceOpenContaining(menu, contextMenu, openLocationAction))
                {
                    if (!InsertMenu(menu, (uint)GetMenuItemCount(menu), MenuByPosition | (openLocationAction.IsEnabled ? 0u : MenuDisabled),
                        (UIntPtr)BaseMenuCommandFirst, openLocationAction.Label))
                        throw new InvalidOperationException("Could not insert the Open file location action.");
                }
                actions = [openLocationAction];
            }
            return new SutContextMenu(owner, menu, contextMenu, actions, rename,
                offset => IsRenameCommand(contextMenu, offset),
                isBaseMenu ? () => CollectComparableCommands(menu, contextMenu, allowVerbless: directorySelection || background) : null,
                background && (isBaseMenu || excludedCommands is not null)
                    ? submenu => RemoveBackgroundViewMenus(submenu, contextMenu)
                    : isBaseMenu || excludedCommands is not null || openLocationAction is not null
                        ? submenu =>
                        {
                            if (isBaseMenu || excludedCommands is not null)
                                RemoveExcludedFileCommands(submenu, contextMenu, directorySelection, excludedCommands is not null);
                            if (isBaseMenu && shortcutSelection) RemoveOpenContaining(submenu, contextMenu);
                            if (openLocationAction is not null) ReplaceOpenContaining(submenu, contextMenu, openLocationAction);
                        } : null,
                    allowRightButton: !isBaseMenu && excludedCommands is null,
                Release);
        }
        catch
        {
            Release();
            throw;
        }
    }

    private static bool IsRenameCommand(IContextMenu contextMenu, uint commandOffset)
        => string.Equals(GetCommandVerb(contextMenu, commandOffset), "rename", StringComparison.OrdinalIgnoreCase);

    internal static string? GetCommandVerb(IContextMenu contextMenu, uint commandOffset)
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

    private static void PrepareBaseMenu(IntPtr menu, IContextMenu contextMenu, bool directorySelection, bool replaceProperties)
    {
        var standardVerbs = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "copy", "copyaspath", "paste", "rename", "delete", "cut" };
        if (replaceProperties)
            standardVerbs.Add("properties");
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
    }

    private static void RemoveOpenContaining(IntPtr menu, IContextMenu contextMenu)
    {
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero) RemoveOpenContaining(submenu, contextMenu);
            var id = GetMenuItemID(menu, index);
            if (id >= FirstCommandId && id <= LastCommandId &&
                string.Equals(GetCommandVerb(contextMenu, id - FirstCommandId), "opencontaining", StringComparison.OrdinalIgnoreCase) &&
                !RemoveMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not remove the Shell Open file location command.");
        }
        RemoveRedundantSeparators(menu);
    }

    private static bool ReplaceOpenContaining(IntPtr menu, IContextMenu contextMenu, ShellMenuAction action)
    {
        var replaced = false;
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero) replaced |= ReplaceOpenContaining(submenu, contextMenu, action);
            var id = GetMenuItemID(menu, index);
            if (id < FirstCommandId || id > LastCommandId ||
                !string.Equals(GetCommandVerb(contextMenu, id - FirstCommandId), "opencontaining", StringComparison.OrdinalIgnoreCase))
                continue;
            if (!RemoveMenu(menu, (uint)index, MenuByPosition) ||
                !InsertMenu(menu, (uint)index, MenuByPosition | (action.IsEnabled ? 0u : MenuDisabled), (UIntPtr)BaseMenuCommandFirst, action.Label))
                throw new InvalidOperationException("Could not replace the Shell Open file location command.");
            replaced = true;
        }
        return replaced;
    }

    private static void RemoveShellProperties(IntPtr menu, IContextMenu contextMenu)
    {
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var id = GetMenuItemID(menu, index);
            if (id >= FirstCommandId && id <= LastCommandId &&
                string.Equals(GetCommandVerb(contextMenu, id - FirstCommandId), "properties", StringComparison.OrdinalIgnoreCase) &&
                !RemoveMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not remove the Shell properties command.");
        }
        RemoveRedundantSeparators(menu);
    }

    private static void InsertActions(IntPtr menu, IReadOnlyList<ShellMenuAction> actions)
    {
        var position = 0u;
        var insertedTransfer = false;
        for (var index = 0; index < actions.Count; index++)
        {
            var action = actions[index];
            if (action.Id is "Rename" or "Delete" || (action.IsTransfer && !action.IsEnabled))
                continue;
            var separator = action.SeparatorBefore || (action.IsTransfer && !insertedTransfer);
            if (action.IsTransfer) insertedTransfer = true;
            if (separator && !InsertMenu(menu, position++, MenuByPosition | MenuSeparator, UIntPtr.Zero, null))
                throw new InvalidOperationException("Could not insert the menu separator.");
            if (!InsertMenu(menu, position++, MenuByPosition | (action.IsEnabled ? 0u : MenuDisabled),
                    (UIntPtr)(BaseMenuCommandFirst + (uint)index), action.Label))
                throw new InvalidOperationException("Could not insert a standard menu command.");
        }
        if (position < GetMenuItemCount(menu) && !InsertMenu(menu, position, MenuByPosition | MenuSeparator, UIntPtr.Zero, null))
            throw new InvalidOperationException("Could not insert the menu separator.");
        for (var index = 0; index < actions.Count; index++)
        {
            var action = actions[index];
            if (action.Id is not ("Rename" or "Delete"))
                continue;
            if (!InsertMenu(menu, (uint)GetMenuItemCount(menu), MenuByPosition | MenuSeparator, UIntPtr.Zero, null) ||
                !InsertMenu(menu, (uint)GetMenuItemCount(menu), MenuByPosition | (action.IsEnabled ? 0u : MenuDisabled),
                    (UIntPtr)(BaseMenuCommandFirst + (uint)index), action.Label))
                throw new InvalidOperationException("Could not insert the menu separator.");
        }
        RemoveRedundantSeparators(menu);
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

    private static void PrepareContentMenu(IntPtr menu, IContextMenu contextMenu, IReadOnlyDictionary<string, int> baseCommands, bool directorySelection, bool background)
    {
        if (!background)
            RemoveExcludedFileCommands(menu, contextMenu, directorySelection, isContentMenu: true);
        var contentCommands = CollectComparableCommands(menu, contextMenu, allowVerbless: directorySelection || background);
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var command = ComparableCommand(menu, contextMenu, index, allowVerbless: directorySelection || background);
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

    private static void FilterBackgroundBaseMenu(IntPtr menu, IContextMenu contextMenu, IReadOnlyDictionary<string, int> directoryCommands)
    {
        var backgroundCommands = CollectComparableCommands(menu, contextMenu, includeDisabled: true, allowVerbless: true);
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var command = ComparableCommand(menu, contextMenu, index, includeDisabled: true, allowVerbless: true);
            if (!HasShellMenuLabel(menu, index, BackgroundNewLabels.Value) &&
                command is not null && directoryCommands.TryGetValue(command, out var directoryCount) && directoryCount == 1 &&
                backgroundCommands.TryGetValue(command, out var backgroundCount) && backgroundCount == 1)
                continue;
            var removed = GetSubMenu(menu, index) != IntPtr.Zero
                ? DeleteMenu(menu, (uint)index, MenuByPosition)
                : RemoveMenu(menu, (uint)index, MenuByPosition);
            if (!removed)
                throw new InvalidOperationException("Could not filter the Shell background Base Menu.");
        }
        RemoveRedundantSeparators(menu);
    }

    private static void RemoveBackgroundViewMenus(IntPtr menu, IContextMenu contextMenu)
    {
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero && (HasShellMenuLabel(menu, index, BackgroundViewLabels.Value) ||
                ContainsBackgroundViewCommand(submenu, contextMenu)) &&
                !DeleteMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not remove a Shell background view menu.");
            if (submenu == IntPtr.Zero)
            {
                var id = GetMenuItemID(menu, index);
                if (id >= FirstCommandId && id <= LastCommandId &&
                    GetCommandVerb(contextMenu, id - FirstCommandId) is { } verb && ExcludedBackgroundVerbs.Contains(verb) &&
                    !RemoveMenu(menu, (uint)index, MenuByPosition))
                    throw new InvalidOperationException("Could not remove a Shell background command.");
            }
        }
        RemoveRedundantSeparators(menu);
    }

    private static HashSet<string> LoadShellMenuLabels(params uint[] resourceIds)
    {
        var labels = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var module = GetModuleHandle("shell32.dll");
        if (module == IntPtr.Zero)
            return labels;
        foreach (var resourceId in resourceIds)
        {
            var label = new StringBuilder(512);
            if (LoadString(module, resourceId, label, label.Capacity) > 0)
                labels.Add(label.ToString().Replace("&", "", StringComparison.Ordinal));
        }
        return labels;
    }

    private static bool HasShellMenuLabel(IntPtr menu, int index, HashSet<string> labels)
    {
        var label = new StringBuilder(512);
        return GetMenuString(menu, (uint)index, label, label.Capacity, MenuByPosition) > 0 &&
            labels.Contains(label.ToString().Replace("&", "", StringComparison.Ordinal));
    }

    internal static IntPtr FindBackgroundNewSubmenu(IntPtr menu)
    {
        var result = IntPtr.Zero;
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu == IntPtr.Zero || !HasShellMenuLabel(menu, index, BackgroundNewLabels.Value))
                continue;
            if (result != IntPtr.Zero)
                throw new InvalidOperationException("The Shell provided more than one New menu.");
            result = submenu;
        }
        return result != IntPtr.Zero ? result : throw new InvalidOperationException("The Shell did not provide a New menu.");
    }

    private static void ReplaceBackgroundNew(IntPtr menu, ShellMenuAction action)
    {
        var position = GetMenuItemCount(menu);
        var label = action.Label;
        for (var index = GetMenuItemCount(menu) - 1; index >= 0; index--)
        {
            if (GetSubMenu(menu, index) == IntPtr.Zero || !HasShellMenuLabel(menu, index, BackgroundNewLabels.Value)) continue;
            var shellLabel = new StringBuilder(512);
            if (GetMenuString(menu, (uint)index, shellLabel, shellLabel.Capacity, MenuByPosition) > 0)
                label = shellLabel.ToString();
            if (!DeleteMenu(menu, (uint)index, MenuByPosition))
                throw new InvalidOperationException("Could not replace the Shell New menu.");
            position = index;
        }
        if (!InsertMenu(menu, (uint)position, MenuByPosition | (action.IsEnabled ? 0u : MenuDisabled), (UIntPtr)BaseMenuCommandFirst, label))
            throw new InvalidOperationException("Could not insert the New action.");
        RemoveRedundantSeparators(menu);
    }

    private static bool ContainsBackgroundViewCommand(IntPtr menu, IContextMenu contextMenu)
    {
        for (var index = 0; index < GetMenuItemCount(menu); index++)
        {
            var submenu = GetSubMenu(menu, index);
            if (submenu != IntPtr.Zero && ContainsBackgroundViewCommand(submenu, contextMenu))
                return true;
            var id = GetMenuItemID(menu, index);
            if (id < FirstCommandId || id > LastCommandId)
                continue;
            var verb = GetCommandVerb(contextMenu, id - FirstCommandId);
            if (verb is not null && (verb.StartsWith("viewlogical", StringComparison.OrdinalIgnoreCase) ||
                verb.StartsWith("arrange", StringComparison.OrdinalIgnoreCase) ||
                verb.StartsWith("sortascending", StringComparison.OrdinalIgnoreCase) ||
                verb.StartsWith("sortdescending", StringComparison.OrdinalIgnoreCase) ||
                verb.StartsWith("groupascending", StringComparison.OrdinalIgnoreCase) ||
                verb.StartsWith("groupdescending", StringComparison.OrdinalIgnoreCase)))
                return true;
        }
        return false;
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
        using var stream = typeof(SutContextMenuFactory).Assembly.GetManifestResourceStream(BlacklistResourceName)
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
        using var stream = typeof(SutContextMenuFactory).Assembly.GetManifestResourceStream(DirectoryWhitelistResourceName)
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

}

internal sealed record ShellMenuAction(string Id, string Label, bool IsEnabled, Action Invoke, bool IsTransfer = false, bool SeparatorBefore = false)
{
    public System.Windows.Controls.Button? IconSource { get; init; }
}

[StructLayout(LayoutKind.Sequential)]
internal struct ShellCommandInvokeInfo
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
    public ShellInvokePoint InvokePoint;
}

[StructLayout(LayoutKind.Sequential)]
internal struct ShellInvokePoint
{
    public int X;
    public int Y;
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
    [PreserveSig] int InvokeCommand(ref ShellCommandInvokeInfo commandInfo);
    [PreserveSig] int GetCommandString(UIntPtr commandOffset, uint flags, IntPtr reserved, IntPtr name, uint maximumLength);
}

[ComImport]
[Guid("000214F4-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IContextMenu2
{
    [PreserveSig] int QueryContextMenu(IntPtr menu, uint indexMenu, uint idCommandFirst, uint idCommandLast, uint flags);
    [PreserveSig] int InvokeCommand(ref ShellCommandInvokeInfo commandInfo);
    [PreserveSig] int GetCommandString(UIntPtr commandOffset, uint flags, IntPtr reserved, IntPtr name, uint maximumLength);
    [PreserveSig] int HandleMenuMsg(uint message, IntPtr wParam, IntPtr lParam);
}

[ComImport]
[Guid("BCFCE0A0-EC17-11D0-8D10-00A0C90F2719")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IContextMenu3
{
    [PreserveSig] int QueryContextMenu(IntPtr menu, uint indexMenu, uint idCommandFirst, uint idCommandLast, uint flags);
    [PreserveSig] int InvokeCommand(ref ShellCommandInvokeInfo commandInfo);
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