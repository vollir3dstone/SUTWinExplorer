param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Path,
    [switch] $Background,
    [switch] $Generic,
    [switch] $NoCanRename
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Run this script in an STA process, for example: pwsh -NoProfile -STA -File tests/ContextMenuSpike.ps1 -Path <path>'
}

$paths = @($Path | ForEach-Object { (Get-Item -LiteralPath $_ -Force).FullName })
if ($Background -and ($paths.Count -ne 1 -or -not [IO.Directory]::Exists($paths[0]))) {
    throw 'Background requires exactly one directory.'
}
if ($Generic -and ($Background -or $paths.Count -ne 1 -or -not [IO.File]::Exists($paths[0]))) {
    throw 'Generic requires exactly one file.'
}
if (-not $Background -and $paths.Count -gt 1) {
    $parent = [IO.Path]::GetDirectoryName($paths[0])
    if (@($paths | Where-Object { -not [string]::Equals([IO.Path]::GetDirectoryName($_), $parent, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw 'Selected items must have the same parent directory.'
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ContextMenuSpike
{
    [ComImport, Guid("000214E6-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellFolder
    {
        [PreserveSig] int ParseDisplayName(IntPtr owner, IntPtr bind, [MarshalAs(UnmanagedType.LPWStr)] string name, out uint eaten, out IntPtr pidl, ref uint attributes);
        [PreserveSig] int EnumObjects(IntPtr owner, uint flags, IntPtr enumerator);
        [PreserveSig] int BindToObject(IntPtr pidl, IntPtr bind, ref Guid iid, out IShellFolder result);
        [PreserveSig] int BindToStorage(IntPtr pidl, IntPtr bind, ref Guid iid, out IntPtr result);
        [PreserveSig] int CompareIDs(IntPtr parameter, IntPtr first, IntPtr second);
        [PreserveSig] int CreateViewObject(IntPtr owner, ref Guid iid, out IShellView result);
        [PreserveSig] int GetAttributesOf(uint count, IntPtr pidls, ref uint attributes);
        [PreserveSig] int GetUIObjectOf(IntPtr owner, uint count, IntPtr pidls, ref Guid iid, IntPtr reserved, out IContextMenu result);
        [PreserveSig] int GetDisplayNameOf(IntPtr pidl, uint flags, IntPtr name);
        [PreserveSig] int SetNameOf(IntPtr owner, IntPtr pidl, IntPtr name, uint flags, out IntPtr result);
    }

    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellView
    {
        [PreserveSig] int GetWindow(out IntPtr window);
        [PreserveSig] int ContextSensitiveHelp(bool enter);
        [PreserveSig] int TranslateAccelerator(IntPtr message);
        [PreserveSig] int EnableModeless(bool enable);
        [PreserveSig] int UIActivate(uint state);
        [PreserveSig] int Refresh();
        [PreserveSig] int CreateViewWindow(IntPtr previous, IntPtr settings, IntPtr browser, IntPtr rectangle, out IntPtr window);
        [PreserveSig] int DestroyViewWindow();
        [PreserveSig] int GetCurrentInfo(IntPtr settings);
        [PreserveSig] int AddPropertySheetPages(uint reserved, IntPtr addPage, IntPtr parameter);
        [PreserveSig] int SaveViewState();
        [PreserveSig] int SelectItem(IntPtr pidl, uint flags);
        [PreserveSig] int GetItemObject(uint item, ref Guid iid, out IntPtr result);
    }

    [ComImport, Guid("000214E4-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IContextMenu
    {
        [PreserveSig] int QueryContextMenu(IntPtr menu, uint index, uint first, uint last, uint flags);
        [PreserveSig] int InvokeCommand(IntPtr command);
        [PreserveSig] int GetCommandString(UIntPtr offset, uint flags, IntPtr reserved, IntPtr text, uint length);
    }

    [DllImport("shell32.dll")] private static extern int SHGetDesktopFolder(out IShellFolder folder);
    [DllImport("shell32.dll")] private static extern int SHBindToParent(IntPtr pidl, ref Guid iid, out IShellFolder folder, out IntPtr child);
    [DllImport("shell32.dll")] private static extern IntPtr ILFindLastID(IntPtr pidl);
    [DllImport("shell32.dll")] private static extern int SHCreateDefaultContextMenu(ref DefaultContextMenu definition, ref Guid iid, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] private static extern uint GetMenuItemID(IntPtr menu, int position);
    [DllImport("user32.dll")] private static extern uint GetMenuState(IntPtr menu, uint position, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetMenuString(IntPtr menu, uint position, StringBuilder text, int length, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct DefaultContextMenu
    {
        public IntPtr Owner, Callback, FolderPidl, Folder;
        public uint Count;
        public IntPtr Children, Association;
        public uint KeyCount;
        public IntPtr Keys;
    }

    public sealed class MenuEntry
    {
        public string Position { get; set; }
        public string Text { get; set; }
        public uint? CommandId { get; set; }
        public string Verb { get; set; }
        public bool Separator { get; set; }
        public bool OwnerDrawn { get; set; }
        public bool Disabled { get; set; }
        public bool HasSubmenu { get; set; }
    }

    public static MenuEntry[] Inspect(string[] paths, bool background, IntPtr[] keys, bool canRename)
    {
        var pidls = new List<IntPtr>();
        IntPtr children = IntPtr.Zero, menu = IntPtr.Zero, keyArray = IntPtr.Zero, parentPointer = IntPtr.Zero;
        IShellFolder desktop = null, parent = null, target = null;
        IShellView view = null;
        IContextMenu context = null;
        try
        {
            Marshal.ThrowExceptionForHR(SHGetDesktopFolder(out desktop));
            foreach (var path in paths)
            {
                uint attributes = 0;
                IntPtr pidl;
                uint eaten;
                Marshal.ThrowExceptionForHR(desktop.ParseDisplayName(IntPtr.Zero, IntPtr.Zero, path, out eaten, out pidl, ref attributes));
                pidls.Add(pidl);
            }
            var contextId = typeof(IContextMenu).GUID;
            if (background)
            {
                var folderId = typeof(IShellFolder).GUID;
                Marshal.ThrowExceptionForHR(desktop.BindToObject(pidls[0], IntPtr.Zero, ref folderId, out target));
                var viewId = typeof(IShellView).GUID;
                Marshal.ThrowExceptionForHR(target.CreateViewObject(IntPtr.Zero, ref viewId, out view));
                IntPtr pointer;
                Marshal.ThrowExceptionForHR(view.GetItemObject(0, ref contextId, out pointer));
                try { context = (IContextMenu)Marshal.GetObjectForIUnknown(pointer); }
                finally { Marshal.Release(pointer); }
            }
            else
            {
                var folderId = typeof(IShellFolder).GUID;
                IntPtr firstChild;
                Marshal.ThrowExceptionForHR(SHBindToParent(pidls[0], ref folderId, out parent, out firstChild));
                children = Marshal.AllocCoTaskMem(IntPtr.Size * paths.Length);
                Marshal.WriteIntPtr(children, 0, firstChild);
                for (var index = 1; index < pidls.Count; index++)
                    Marshal.WriteIntPtr(children, index * IntPtr.Size, ILFindLastID(pidls[index]));
                if (keys.Length == 0)
                    Marshal.ThrowExceptionForHR(parent.GetUIObjectOf(IntPtr.Zero, (uint)paths.Length, children, ref contextId, IntPtr.Zero, out context));
                else
                {
                    keyArray = Marshal.AllocCoTaskMem(IntPtr.Size * keys.Length);
                    Marshal.Copy(keys, 0, keyArray, keys.Length);
                    parentPointer = Marshal.GetComInterfaceForObject(parent, typeof(IShellFolder));
                    var definition = new DefaultContextMenu { Folder = parentPointer, Count = (uint)paths.Length,
                        Children = children, KeyCount = (uint)keys.Length, Keys = keyArray };
                    IntPtr pointer;
                    Marshal.ThrowExceptionForHR(SHCreateDefaultContextMenu(ref definition, ref contextId, out pointer));
                    try { context = (IContextMenu)Marshal.GetObjectForIUnknown(pointer); }
                    finally { Marshal.Release(pointer); }
                }
            }
            menu = CreatePopupMenu();
            if (menu == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            Marshal.ThrowExceptionForHR(context.QueryContextMenu(menu, 0, 1, 0x7fff, !background && paths.Length == 1 && canRename ? 0x10u : 0u));
            var entries = new List<MenuEntry>();
            ReadMenu(menu, context, "", entries);
            return entries.ToArray();
        }
        finally
        {
            if (menu != IntPtr.Zero) DestroyMenu(menu);
            if (context != null) Marshal.ReleaseComObject(context);
            if (view != null) Marshal.ReleaseComObject(view);
            if (target != null) Marshal.ReleaseComObject(target);
            if (parent != null) Marshal.ReleaseComObject(parent);
            if (desktop != null) Marshal.ReleaseComObject(desktop);
            if (parentPointer != IntPtr.Zero) Marshal.Release(parentPointer);
            if (keyArray != IntPtr.Zero) Marshal.FreeCoTaskMem(keyArray);
            if (children != IntPtr.Zero) Marshal.FreeCoTaskMem(children);
            foreach (var pidl in pidls) Marshal.FreeCoTaskMem(pidl);
        }
    }

    private static void ReadMenu(IntPtr menu, IContextMenu context, string prefix, List<MenuEntry> entries)
    {
        var count = GetMenuItemCount(menu);
        if (count < 0) throw new InvalidOperationException("Could not inspect Shell menu.");
        for (var index = 0; index < count; index++)
        {
            var position = prefix == "" ? index.ToString() : prefix + "." + index;
            var state = GetMenuState(menu, (uint)index, 0x400);
            var submenu = GetSubMenu(menu, index);
            var id = GetMenuItemID(menu, index);
            var text = new StringBuilder(1024);
            GetMenuString(menu, (uint)index, text, text.Capacity, 0x400);
            string verb = null;
            if (id >= 1 && id <= 0x7fff && submenu == IntPtr.Zero && (state & 0x800) == 0)
            {
                var buffer = Marshal.AllocHGlobal(1024 * sizeof(char));
                try
                {
                    Marshal.WriteInt16(buffer, 0);
                    if (context.GetCommandString((UIntPtr)(id - 1), 4, IntPtr.Zero, buffer, 1024) >= 0)
                        verb = Marshal.PtrToStringUni(buffer);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            entries.Add(new MenuEntry { Position = position, Text = text.ToString(), CommandId = id == uint.MaxValue ? (uint?)null : id,
                Verb = verb, Separator = (state & 0x800) != 0, OwnerDrawn = (state & 0x100) != 0,
                Disabled = (state & 3) != 0, HasSubmenu = submenu != IntPtr.Zero });
            if (submenu != IntPtr.Zero) ReadMenu(submenu, context, position, entries);
        }
    }
}
'@

function Get-CategoryHints([string] $text) {
    $hints = @()
    if ($text -match '(?i)7.?zip|zip|archive|archiv|(?<![a-z])rar(?![a-z])|compress') { $hints += 'Archive' }
    if ($text -match '(?i)tortoise|git|svn|mercurial|version|source.?control') { $hints += 'VersionControl' }
    if ($text -match '(?i)hard.?link|symlink|symbolic.?link|junction|verkn.pf') { $hints += 'Links' }
    if ($text -match '(?i)norton|defender|virus|antivirus|malware|hash|checksum|pr.fsum|sha256|sha1|md5|crc') { $hints += 'Verification' }
    return ,$hints
}

$genericKeys = @()
try {
    if ($Generic) {
        $genericKeys = @([Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('*'),
            [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('AllFilesystemObjects'))
        if (@($genericKeys | Where-Object { $null -eq $_ }).Count -gt 0) { throw 'Generic Shell classes not found.' }
    }
    [IntPtr[]] $keyHandles = @($genericKeys | ForEach-Object { $_.Handle.DangerousGetHandle() })
    $menu = @([ContextMenuSpike]::Inspect($paths, [bool] $Background, $keyHandles, -not $NoCanRename) | ForEach-Object {
    [PSCustomObject]@{ Position = $_.Position; Text = $_.Text; CommandId = $_.CommandId; Verb = $_.Verb;
        Separator = $_.Separator; OwnerDrawn = $_.OwnerDrawn; Disabled = $_.Disabled; HasSubmenu = $_.HasSubmenu;
        CategoryHints = Get-CategoryHints ($_.Text + ' ' + $_.Verb) }
    })
} finally {
    foreach ($key in $genericKeys) { if ($null -ne $key) { $key.Dispose() } }
}

$scopes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($Background) { $null = $scopes.Add('Directory\Background') }
else {
    foreach ($item in $paths) {
        if ([IO.Directory]::Exists($item)) {
            $null = $scopes.Add('AllFilesystemObjects'); $null = $scopes.Add('Directory'); $null = $scopes.Add('Folder')
            if ([IO.Path]::GetPathRoot($item).TrimEnd('\') -eq $item.TrimEnd('\')) { $null = $scopes.Add('Drive') }
        } else {
            $null = $scopes.Add('*'); $null = $scopes.Add('AllFilesystemObjects')
            $extension = [IO.Path]::GetExtension($item)
            if ($extension) {
                $null = $scopes.Add($extension); $null = $scopes.Add("SystemFileAssociations\$extension")
                $extensionKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($extension)
                if ($extensionKey) {
                    try {
                        $progId = [string] $extensionKey.GetValue('')
                        $perceived = [string] $extensionKey.GetValue('PerceivedType')
                        if ($progId) { $null = $scopes.Add($progId) }
                        if ($perceived) { $null = $scopes.Add("SystemFileAssociations\$perceived") }
                    } finally { $extensionKey.Dispose() }
                }
            }
        }
    }
}

$registrations = @(foreach ($scope in ($scopes | Sort-Object)) {
    foreach ($kind in @('shell', 'shellex\ContextMenuHandlers')) {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("$scope\$kind")
        if (-not $key) { continue }
        try {
            foreach ($name in $key.GetSubKeyNames()) {
                $entry = $key.OpenSubKey($name)
                try {
                    $default = [string] $entry.GetValue('')
                    $label = [string] $entry.GetValue('MUIVerb')
                    $handler = [string] $entry.GetValue('ExplorerCommandHandler')
                    $commandKey = $entry.OpenSubKey('command')
                    $command = if ($commandKey) { try { [string] $commandKey.GetValue('') } finally { $commandKey.Dispose() } } else { '' }
                    [PSCustomObject]@{ Scope = $scope; Kind = $kind; Name = $name; Default = $default; MUIVerb = $label;
                        ExplorerCommandHandler = $handler; Command = $command;
                        CategoryHints = Get-CategoryHints "$name $default $label $handler $command" }
                } finally { $entry.Dispose() }
            }
        } finally { $key.Dispose() }
    }
})

[PSCustomObject]@{
    Selection = $paths
    Background = [bool] $Background
    Notes = @('Menu entries are from the classic IContextMenu, not necessarily the Windows 11 compact menu.',
        'Submenus are inspected without opening them; dynamically populated entries may be missing.',
        'Registry entries are candidates, not proven providers or proof of applicability; active user associations and other sources may be missing.',
        'Category hints are name-based guesses, not classifications. Command IDs apply only to this menu instance; no commands are executed.')
    Menu = $menu
    RegistryCandidates = $registrations
} | ConvertTo-Json -Depth 8