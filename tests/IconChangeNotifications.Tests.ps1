$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class IconNotificationProbe
{
    private readonly string _testDirectory;
    private readonly List<string> _events = new List<string>();
    private uint _registration;

    public IconNotificationProbe(string testDirectory) { _testDirectory = testDirectory; }

    public void Register(IntPtr window, string path, int eventMask)
    {
        IntPtr pidl;
        uint attributes;
        if (SHParseDisplayName(path, IntPtr.Zero, out pidl, 0, out attributes) < 0 || pidl == IntPtr.Zero)
            throw new InvalidOperationException("Could not parse " + path);
        try
        {
            var entry = new ChangeEntry { Pidl = pidl, Recursive = true };
            _registration = SHChangeNotifyRegister(window, 0x0001 | 0x0002 | 0x1000 | 0x8000,
                eventMask, 0x8370, 1, ref entry);
            if (_registration == 0) throw new InvalidOperationException("Could not register " + path);
        }
        finally { Marshal.FreeCoTaskMem(pidl); }
    }

    public IntPtr OnMessage(IntPtr window, int message, IntPtr change, IntPtr process, ref bool handled)
    {
        if (message != 0x8370) return IntPtr.Zero;
        handled = true;
        IntPtr items;
        int eventId;
        var notification = SHChangeNotificationLock(change, unchecked((uint)process.ToInt64()), out items, out eventId);
        if (notification == IntPtr.Zero) return IntPtr.Zero;
        try
        {
            var kind = eventId & 0x7fffffff;
            string path = null;
            if ((kind & 0x08000000) == 0 && (kind & 0x00008000) == 0 && (kind & 0x04000000) == 0 && items != IntPtr.Zero)
            {
                var pidl = Marshal.ReadIntPtr(items);
                IntPtr name;
                if (pidl != IntPtr.Zero && SHGetNameFromIDList(pidl, 0x80058000, out name) >= 0)
                {
                    try { path = Marshal.PtrToStringUni(name); }
                    finally { Marshal.FreeCoTaskMem(name); }
                }
            }
            if ((kind & 0x08000000) != 0 || (path != null && path.StartsWith(_testDirectory, StringComparison.OrdinalIgnoreCase)))
                lock (_events) _events.Add("0x" + kind.ToString("X8") + " " + (path ?? "<global>"));
        }
        finally { SHChangeNotificationUnlock(notification); }
        return IntPtr.Zero;
    }

    public string[] Drain()
    {
        lock (_events) { var result = _events.ToArray(); _events.Clear(); return result; }
    }

    public static System.Threading.Tasks.Task StoreOnBackground(object cache, System.Reflection.MethodInfo store, string path, object bitmap)
    {
        return System.Threading.Tasks.Task.Run(() => store.Invoke(cache, new object[] { path, "small", 16, 16, bitmap, false, 999999 }));
    }

    public void Stop() { if (_registration != 0) { SHChangeNotifyDeregister(_registration); _registration = 0; } }

    public static IntPtr GetIcon(string path)
    {
        var info = new ShellFileInfo();
        return SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf(typeof(ShellFileInfo)), 0x00000101) == IntPtr.Zero
            ? IntPtr.Zero : info.Icon;
    }

    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHParseDisplayName(string name, IntPtr context, out IntPtr pidl, uint attributesIn, out uint attributesOut);
    [DllImport("shell32.dll")] private static extern int SHGetNameFromIDList(IntPtr pidl, uint type, out IntPtr name);
    [DllImport("shell32.dll")] private static extern uint SHChangeNotifyRegister(IntPtr window, int sources, int events, int message, int count, ref ChangeEntry entry);
    [DllImport("shell32.dll")] private static extern bool SHChangeNotifyDeregister(uint registration);
    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Lock")] private static extern IntPtr SHChangeNotificationLock(IntPtr change, uint process, out IntPtr items, out int eventId);
    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Unlock")] private static extern bool SHChangeNotificationUnlock(IntPtr notification);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SHGetFileInfo(string path, uint attributes, ref ShellFileInfo info, uint size, uint flags);

    [StructLayout(LayoutKind.Sequential)] private struct ChangeEntry { public IntPtr Pidl; [MarshalAs(UnmanagedType.Bool)] public bool Recursive; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ShellFileInfo
    {
        public IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }
}
'@

function Pump([int] $milliseconds) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
}

    function Wait-Until([scriptblock] $condition, [string] $message) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (& $condition) -and [DateTime]::UtcNow -lt $deadline) { Pump 100 }
        if (-not (& $condition)) { throw $message }
    }

    function Get-CachedHash($cache, [string] $path, [string] $variant, [int] $size) {
        $entry = $findCache.Invoke($cache, [object[]] @([string] $path, [string] $variant, [int] $size, [int] $size))
        if ($null -eq $entry) { return '' }
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($entry.Image))
        $stream = [IO.MemoryStream]::new()
        try { $encoder.Save($stream); return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray())) }
        finally { $stream.Dispose() }
    }

function Get-IconHash([string] $path) {
    $handle = [IconNotificationProbe]::GetIcon($path)
    if ($handle -eq [IntPtr]::Zero) { throw "Could not get icon for $path" }
    try {
        $icon = [Drawing.Icon]::FromHandle($handle)
        $bitmap = $icon.ToBitmap()
        $stream = [IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray()))
        }
        finally { $stream.Dispose(); $bitmap.Dispose(); $icon.Dispose() }
    }
    finally { [void] [IconNotificationProbe]::DestroyIcon($handle) }
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-icon-events-' + [guid]::NewGuid().ToString('N'))
$shortcutPath = Join-Path $directory 'icon-test.lnk'
$driveRoot = [IO.Path]::GetPathRoot($directory)
$probes = [Collections.Generic.List[object]]::new()
$createdKeys = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
$classes = $null
$shell = $null
$observer = $null
$loadedObserver = $null
try {
    [void] [IO.Directory]::CreateDirectory($directory)
    $sentinelPath = Join-Path $directory 'unrelated.txt'
    [IO.File]::WriteAllText($sentinelPath, 'unchanged')
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',0'
    $shortcut.Save()
    $before = Get-IconHash $shortcutPath
    $assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
    $staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
    $instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
    $provider = $assembly.GetType('SUTWinExplorer.ShellIconProvider', $true)
    $cacheType = $assembly.GetType('SUTWinExplorer.IconCache', $true)
    $observerType = $assembly.GetType('SUTWinExplorer.IconChangeObserver', $true)
    $cachePath = Join-Path $directory 'cache.json'
    $provider.GetMethod('InitializeCache', $staticFlags).Invoke($null, [object[]] @([string] $cachePath))
    $cache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    $findCache = $cacheType.GetMethod('Find', $instanceFlags)
    $storeCache = $cacheType.GetMethod('Store', $instanceFlags)
    $getSmall = $provider.GetMethod('GetSmallIcons')
    $getSized = $provider.GetMethod('GetIconAtSize')
    $registrations = $observerType.GetField('_registrations', $instanceFlags)
    $observerConstructor = $observerType.GetConstructor($instanceFlags, $null, [type[]] @($cacheType, [Windows.Threading.Dispatcher]), $null)
    $observer = $observerConstructor.Invoke([object[]] @($cache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    if ($registrations.GetValue($observer).Count -ne 0) { throw 'An empty cache unexpectedly registered a drive.' }
    $pixels = [byte[]] @(0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255)
    $sentinelBitmap = [Windows.Media.Imaging.BitmapSource]::Create(2, 2, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, 8)
    $sentinelBitmap.Freeze()
    [IconNotificationProbe]::StoreOnBackground($cache, $storeCache, $sentinelPath, $sentinelBitmap).GetAwaiter().GetResult()
    Wait-Until { $registrations.GetValue($observer).ContainsKey($driveRoot) } 'A drive cached on a background thread was not registered.'
    [void] $getSmall.Invoke($null, [object[]] @([string] $shortcutPath))
    [void] $getSized.Invoke($null, [object[]] @([string] $shortcutPath, [int] 32, [int] 32))
    if (-not $registrations.GetValue($observer).ContainsKey($driveRoot)) { throw 'The first newly cached drive was not registered.' }
    $cachedShortcutBefore = Get-CachedHash $cache $shortcutPath 'small' 16
    $cachedShortcutSizedBefore = Get-CachedHash $cache $shortcutPath 'sized' 32
    if (-not $cachedShortcutBefore -or -not $cachedShortcutSizedBefore) { throw 'Shortcut icon variants were not cached.' }
    $storeCache.Invoke($cache, [object[]] @([string] $sentinelPath, [string] 'small', [int] 16, [int] 16, $sentinelBitmap, [bool] $false, [int] 999999))
    $sentinelBefore = Get-CachedHash $cache $sentinelPath 'small' 16
    $cacheType.GetMethod('Save', $instanceFlags).Invoke($cache, @())
    $cacheConstructor = $cacheType.GetConstructor($instanceFlags, $null, [type[]] @([string]), $null)
    $loadedCache = $cacheConstructor.Invoke([object[]] @([string] $cachePath))
    $cacheType.GetMethod('Load', $instanceFlags).Invoke($loadedCache, @())
    $loadedObserver = $observerConstructor.Invoke([object[]] @($loadedCache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    if (-not $registrations.GetValue($loadedObserver).ContainsKey($driveRoot)) { throw 'A previously cached drive was not registered at startup.' }
    $loadedObserver.Dispose()
    $loadedObserver = $null
    foreach ($specification in @(
        @{ Name = 'drive-all'; Path = $driveRoot; Mask = 0x7fffffff },
        @{ Name = 'drive-updateitem'; Path = $driveRoot; Mask = 0x00002000 },
        @{ Name = 'drive-association'; Path = $driveRoot; Mask = 0x08000000 },
        @{ Name = 'drive-combined'; Path = $driveRoot; Mask = 0x08002000 },
        @{ Name = 'directory-all'; Path = $directory; Mask = 0x7fffffff }
    )) {
        $window = [Windows.Interop.HwndSource]::new([Windows.Interop.HwndSourceParameters]::new('KIS icon event test'))
        $probe = [IconNotificationProbe]::new($directory)
        $hook = [Delegate]::CreateDelegate([Windows.Interop.HwndSourceHook], $probe, $probe.GetType().GetMethod('OnMessage'))
        $window.AddHook($hook)
        $probe.Register($window.Handle, $specification.Path, $specification.Mask)
        $probes.Add([pscustomobject] @{ Name = $specification.Name; Probe = $probe; Window = $window; Hook = $hook })
    }
    Pump 1500
    foreach ($entry in $probes) { [void] $entry.Probe.Drain() }

    $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',4'
    $shortcut.Save()
    Pump 3000
    Wait-Until { (Get-CachedHash $cache $shortcutPath 'small' 16) -ne $cachedShortcutBefore -and (Get-CachedHash $cache $shortcutPath 'sized' 32) -ne $cachedShortcutSizedBefore } 'An UPDATEITEM did not refresh all cached shortcut variants.'
    if ((Get-CachedHash $cache $sentinelPath 'small' 16) -ne $sentinelBefore) { throw 'A shortcut UPDATEITEM refreshed an unrelated cached item.' }
    $after = Get-IconHash $shortcutPath
    Write-Output "Shortcut icon hash before: $before"
    Write-Output "Shortcut icon hash after:  $after"
    Write-Output "Shortcut icon changed: $($before -ne $after)"
    if ($before -eq $after) { $failures.Add('The shortcut icon did not change.') }
    foreach ($entry in $probes) {
        $events = @($entry.Probe.Drain())
        Write-Output "Shortcut change / $($entry.Name): $($events -join '; ')"
        if ($entry.Name -in @('drive-all', 'drive-updateitem', 'drive-combined') -and -not @($events | Where-Object { $_ -like '0x00002000 *icon-test.lnk' }).Count) {
            $failures.Add("The shortcut change did not deliver UPDATEITEM to $($entry.Name).")
        }
    }

    [IconNotificationProbe]::SHChangeNotify(0x00002000, 0x1005, $shortcutPath, [IntPtr]::Zero)
    Pump 1500
    foreach ($entry in $probes) { Write-Output "Explicit UPDATEITEM / $($entry.Name): $(@($entry.Probe.Drain()) -join '; ')" }

    $identifier = [guid]::NewGuid().ToString('N')
    $extension = '.kisicon' + $identifier
    $firstType = 'KisIconTest.' + $identifier + '.First'
    $secondType = 'KisIconTest.' + $identifier + '.Second'
    $classes = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes', $true)
    foreach ($keyName in @($extension, $firstType, $secondType)) {
        $existing = $classes.OpenSubKey($keyName)
        if ($null -ne $existing) { $existing.Dispose(); throw "Test registry key already exists: $keyName" }
    }
    $iconLibrary = Join-Path $env:SystemRoot 'System32\shell32.dll'
    foreach ($specification in @(@{ Name = $firstType; Index = 0 }, @{ Name = $secondType; Index = 4 })) {
        $key = $classes.CreateSubKey($specification.Name)
        $createdKeys.Add($specification.Name)
        $key.Dispose()
        $iconKey = $classes.CreateSubKey($specification.Name + '\DefaultIcon')
        try { $iconKey.SetValue('', ($iconLibrary + ',' + $specification.Index)) } finally { $iconKey.Dispose() }
    }
    $extensionKey = $classes.CreateSubKey($extension)
    $createdKeys.Add($extension)
    try { $extensionKey.SetValue('', $firstType) } finally { $extensionKey.Dispose() }
    $associationPath = Join-Path $directory ('association' + $extension)
    [IO.File]::WriteAllText($associationPath, 'icon association test')
    Pump 1500
    $associationBefore = Get-IconHash $associationPath
    [void] $getSmall.Invoke($null, [object[]] @([string] $associationPath))
    [void] $getSized.Invoke($null, [object[]] @([string] $associationPath, [int] 32, [int] 32))
    $cachedAssociationBefore = Get-CachedHash $cache $associationPath 'small' 16
    $cachedAssociationSizedBefore = Get-CachedHash $cache $associationPath 'sized' 32
    if (-not $cachedAssociationBefore -or -not $cachedAssociationSizedBefore) { throw 'Association icon variants were not cached.' }
    foreach ($entry in $probes) { [void] $entry.Probe.Drain() }
    $extensionKey = $classes.OpenSubKey($extension, $true)
    try { $extensionKey.SetValue('', $secondType) } finally { $extensionKey.Dispose() }
    Pump 1500
    foreach ($entry in $probes) { Write-Output "Association registry change without notification / $($entry.Name): $(@($entry.Probe.Drain()) -join '; ')" }

    [IconNotificationProbe]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
    Pump 1500
    Wait-Until { (Get-CachedHash $cache $associationPath 'small' 16) -ne $cachedAssociationBefore -and (Get-CachedHash $cache $associationPath 'sized' 32) -ne $cachedAssociationSizedBefore } 'ASSOCCHANGED did not refresh all cached association icon variants.'
    Wait-Until { (Get-CachedHash $cache $sentinelPath 'small' 16) -ne $sentinelBefore } 'ASSOCCHANGED did not refresh another cached filesystem item.'
    $associationAfter = Get-IconHash $associationPath
    Write-Output "Associated icon hash before: $associationBefore"
    Write-Output "Associated icon hash after:  $associationAfter"
    Write-Output "Associated icon changed: $($associationBefore -ne $associationAfter)"
    if ($associationBefore -eq $associationAfter) { $failures.Add('The associated file icon did not change.') }
    foreach ($entry in $probes) {
        $events = @($entry.Probe.Drain())
        Write-Output "Association change with explicit ASSOCCHANGED / $($entry.Name): $($events -join '; ')"
        if ($entry.Name -in @('drive-all', 'drive-association', 'drive-combined') -and -not @($events | Where-Object { $_ -like '0x08000000 *' }).Count) {
            $failures.Add("The explicit ASSOCCHANGED notification was not delivered to $($entry.Name).")
        }
    }
    $sync = $observerType.GetField('_sync', $instanceFlags).GetValue($observer)
    [Threading.Monitor]::Enter($sync)
    try {
        $observerType.GetMethod('QueueItem', $instanceFlags).Invoke($observer, [object[]] @([string] $sentinelPath))
        $observer.Dispose()
        $observer = $null
    }
    finally { [Threading.Monitor]::Exit($sync) }
    if (Get-CachedHash $cache $sentinelPath 'small' 16) { throw 'Closing with an unfinished item refresh retained its stale icon.' }
    if (-not (Get-CachedHash $cache $shortcutPath 'small' 16)) { throw 'Closing with an unfinished item refresh invalidated an unrelated icon.' }
    $observer = $observerConstructor.Invoke([object[]] @($cache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    $sync = $observerType.GetField('_sync', $instanceFlags).GetValue($observer)
    [Threading.Monitor]::Enter($sync)
    try {
        $observerType.GetMethod('QueueRefreshAll', $instanceFlags).Invoke($observer, @())
        $observer.Dispose()
        $observer = $null
    }
    finally { [Threading.Monitor]::Exit($sync) }
    if ((Get-CachedHash $cache $shortcutPath 'small' 16) -or (Get-CachedHash $cache $associationPath 'small' 16)) { throw 'Closing with an unfinished association refresh retained stale icons.' }
    $loadedObserver = $observerConstructor.Invoke([object[]] @($loadedCache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    $remaining = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void] $remaining.Add($sentinelPath)
    $observerType.GetField('_remainingGlobalPaths', $instanceFlags).SetValue($loadedObserver, $remaining)
    $loadedObserver.Dispose()
    $loadedObserver = $null
    $cacheType.GetMethod('Save', $instanceFlags).Invoke($loadedCache, @())
    $reloadedCache = $cacheConstructor.Invoke([object[]] @([string] $cachePath))
    $cacheType.GetMethod('Load', $instanceFlags).Invoke($reloadedCache, @())
    if (Get-CachedHash $reloadedCache $sentinelPath 'small' 16) { throw 'An unfinished global refresh was retained after save and reload.' }
    if (-not (Get-CachedHash $reloadedCache $shortcutPath 'small' 16)) { throw 'A completed global refresh was invalidated on shutdown.' }
    $storeCache.Invoke($reloadedCache, [object[]] @([string] $sentinelPath, [string] 'small', [int] 16, [int] 16, $sentinelBitmap, [bool] $false, [int] 999999))
    $loadedObserver = $observerConstructor.Invoke([object[]] @($reloadedCache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    $sync = $observerType.GetField('_sync', $instanceFlags).GetValue($loadedObserver)
    [Threading.Monitor]::Enter($sync)
    try {
        [void] $observerType.GetField('_pendingExtensions', $instanceFlags).GetValue($loadedObserver).Add('.TXT')
        $loadedObserver.Dispose()
        $loadedObserver = $null
    }
    finally { [Threading.Monitor]::Exit($sync) }
    if (Get-CachedHash $reloadedCache $sentinelPath 'small' 16) { throw 'An unfinished extension refresh retained a matching stale icon.' }
    if (-not (Get-CachedHash $reloadedCache $shortcutPath 'small' 16)) { throw 'An unfinished extension refresh invalidated an unrelated icon.' }
    if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
}
finally {
    if ($null -ne $loadedObserver) { $loadedObserver.Dispose() }
    if ($null -ne $observer) { $observer.Dispose() }
    foreach ($entry in $probes) { $entry.Probe.Stop(); $entry.Window.RemoveHook($entry.Hook); $entry.Window.Dispose() }
    if ($null -ne $shortcut) { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    if ($null -ne $shell) { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    if ($null -ne $classes) {
        foreach ($keyName in $createdKeys) { $classes.DeleteSubKeyTree($keyName, $false) }
        $classes.Dispose()
    }
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}