$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class ManualAssociationProbe
{
    private readonly string _directory;
    private readonly List<string> _events = new List<string>();
    private uint _registration;

    public ManualAssociationProbe(string directory) { _directory = directory; }
    public void Register(IntPtr window, string path)
    {
        IntPtr pidl;
        uint attributes;
        if (SHParseDisplayName(path, IntPtr.Zero, out pidl, 0, out attributes) < 0 || pidl == IntPtr.Zero)
            throw new InvalidOperationException("Could not parse " + path);
        try
        {
            var entry = new ChangeEntry { Pidl = pidl, Recursive = true };
            _registration = SHChangeNotifyRegister(window, 0x0001 | 0x0002 | 0x1000 | 0x8000, 0x7fffffff, 0x8371, 1, ref entry);
            if (_registration == 0) throw new InvalidOperationException("Could not register " + path);
        }
        finally { Marshal.FreeCoTaskMem(pidl); }
    }
    public IntPtr OnMessage(IntPtr window, int message, IntPtr change, IntPtr process, ref bool handled)
    {
        if (message != 0x8371) return IntPtr.Zero;
        handled = true;
        IntPtr items;
        int eventId;
        IntPtr notification = SHChangeNotificationLock(change, unchecked((uint)process.ToInt64()), out items, out eventId);
        if (notification == IntPtr.Zero) return IntPtr.Zero;
        try
        {
            int kind = eventId & 0x7fffffff;
            if ((kind & 0x08000000) != 0)
            {
                if (items == IntPtr.Zero)
                    _events.Add("0x" + kind.ToString("X8") + " <global> item-array=NULL");
                else
                {
                    IntPtr first = Marshal.ReadIntPtr(items);
                    IntPtr second = Marshal.ReadIntPtr(items, IntPtr.Size);
                    _events.Add("0x" + kind.ToString("X8") + " <global> item1=" +
                        DescribePidl(first) + " item2=" + DescribePidl(second));
                }
                return IntPtr.Zero;
            }
            string path = null;
            if ((kind & (0x08000000 | 0x00008000 | 0x04000000)) == 0 && items != IntPtr.Zero)
            {
                IntPtr pidl = Marshal.ReadIntPtr(items);
                IntPtr name;
                if (pidl != IntPtr.Zero && SHGetNameFromIDList(pidl, 0x80058000, out name) >= 0)
                {
                    try { path = Marshal.PtrToStringUni(name); }
                    finally { Marshal.FreeCoTaskMem(name); }
                }
            }
            if ((kind & 0x08000000) != 0 || (path != null && path.StartsWith(_directory, StringComparison.OrdinalIgnoreCase)))
                _events.Add("0x" + kind.ToString("X8") + " " + (path ?? "<global>"));
        }
        finally { SHChangeNotificationUnlock(notification); }
        return IntPtr.Zero;
    }
    public string[] Drain() { var result = _events.ToArray(); _events.Clear(); return result; }
    public void Stop() { if (_registration != 0) SHChangeNotifyDeregister(_registration); }

    private static string DescribePidl(IntPtr pidl)
    {
        if (pidl == IntPtr.Zero) return "NULL";
        uint size = ILGetSize(pidl);
        IntPtr name;
        int result = SHGetNameFromIDList(pidl, 0x80028000, out name);
        string display = "HRESULT 0x" + unchecked((uint)result).ToString("X8");
        if (result >= 0)
        {
            try { display = Marshal.PtrToStringUni(name); }
            finally { Marshal.FreeCoTaskMem(name); }
        }
        return "0x" + pidl.ToInt64().ToString("X") + "[bytes=" + size + ",name=" + display + "]";
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHParseDisplayName(string name, IntPtr context, out IntPtr pidl, uint attributesIn, out uint attributesOut);
    [DllImport("shell32.dll")] private static extern int SHGetNameFromIDList(IntPtr pidl, uint type, out IntPtr name);
    [DllImport("shell32.dll")] private static extern uint ILGetSize(IntPtr pidl);
    [DllImport("shell32.dll")] private static extern uint SHChangeNotifyRegister(IntPtr window, int sources, int events, int message, int count, ref ChangeEntry entry);
    [DllImport("shell32.dll")] private static extern bool SHChangeNotifyDeregister(uint registration);
    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Lock")] private static extern IntPtr SHChangeNotificationLock(IntPtr change, uint process, out IntPtr items, out int eventId);
    [DllImport("shell32.dll", EntryPoint = "SHChangeNotification_Unlock")] private static extern bool SHChangeNotificationUnlock(IntPtr notification);
    [StructLayout(LayoutKind.Sequential)] private struct ChangeEntry { public IntPtr Pidl; [MarshalAs(UnmanagedType.Bool)] public bool Recursive; }
}

[ComImport, Guid("4E530B0A-E611-4C77-A3AC-9031D022281B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IManualAssociationRegistration
{
    [PreserveSig] int QueryCurrentDefault([MarshalAs(UnmanagedType.LPWStr)] string query, int type, int level, out IntPtr association);
}

public static class ManualAssociationQuery
{
    public static string Effective(string extension)
    {
        var registration = (IManualAssociationRegistration)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("591209C7-767B-42B2-9FBA-44EE4615F2C7")));
        try
        {
            IntPtr value;
            int result = registration.QueryCurrentDefault(extension, 0, 1, out value);
            if (result < 0) return "HRESULT 0x" + unchecked((uint)result).ToString("X8");
            try { return Marshal.PtrToStringUni(value); }
            finally { Marshal.FreeCoTaskMem(value); }
        }
        finally { Marshal.FinalReleaseComObject(registration); }
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

$identifier = [guid]::NewGuid().ToString('N').Substring(0, 8)
$extension = '.kistest' + $identifier
$type = 'KisManualAssociationTest.' + $identifier
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-association-' + $identifier)
$file = Join-Path $directory ('test' + $extension)
$secondFile = Join-Path $directory ('second' + $extension.ToUpperInvariant())
$unrelatedFile = Join-Path $directory 'unrelated.txt'
$matchingDirectory = Join-Path $directory ('folder' + $extension)
$classes = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes', $true)
$fileExtsPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $extension
$probes = [Collections.Generic.List[object]]::new()
$observer = $null
try {
    [void] [IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText($file, 'Temporary association notification test')
    [IO.File]::WriteAllText($secondFile, 'Second association notification test')
    [IO.File]::WriteAllText($unrelatedFile, 'Unrelated cache entry')
    [void] [IO.Directory]::CreateDirectory($matchingDirectory)
    $key = $classes.CreateSubKey($extension)
    try { $key.SetValue('', $type) } finally { $key.Dispose() }
    $key = $classes.CreateSubKey($type + '\shell\open\command')
    try { $key.SetValue('', '"' + (Join-Path $env:SystemRoot 'System32\notepad.exe') + '" "%1"') } finally { $key.Dispose() }
    $key = $classes.CreateSubKey($type + '\DefaultIcon')
    try { $key.SetValue('', (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',4') } finally { $key.Dispose() }
    $before = [ManualAssociationQuery]::Effective($extension)
    $assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $cacheType = $assembly.GetType('SUTWinExplorer.IconCache', $true)
    $observerType = $assembly.GetType('SUTWinExplorer.IconChangeObserver', $true)
    $cache = $cacheType.GetConstructor($flags, $null, [type[]] @([string]), $null).Invoke([object[]] @([string] (Join-Path $directory 'cache.json')))
    $store = $cacheType.GetMethod('Store', $flags)
    $find = $cacheType.GetMethod('Find', $flags)
    $pixels = [byte[]] @(0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255)
    $sentinel = [Windows.Media.Imaging.BitmapSource]::Create(2, 2, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, 8)
    $sentinel.Freeze()
    foreach ($path in @($file, $secondFile, $unrelatedFile, $matchingDirectory)) {
        [void] $store.Invoke($cache, [object[]] @([string] $path, [string] 'small', [int] 16, [int] 16, $sentinel, [bool] $false, [int] 999999))
    }
    [void] $store.Invoke($cache, [object[]] @([string] $file, [string] 'sized', [int] 32, [int] 32, $sentinel, [bool] $false, $null))
    $observer = $observerType.GetConstructor($flags, $null, [type[]] @($cacheType, [Windows.Threading.Dispatcher]), $null).Invoke([object[]] @($cache, [Windows.Threading.Dispatcher]::CurrentDispatcher))
    foreach ($specification in @(@{ Name = 'drive'; Path = [IO.Path]::GetPathRoot($directory) }, @{ Name = 'directory'; Path = $directory })) {
        $window = [Windows.Interop.HwndSource]::new([Windows.Interop.HwndSourceParameters]::new('KIS manual association test'))
        $probe = [ManualAssociationProbe]::new($directory)
        $hook = [Delegate]::CreateDelegate([Windows.Interop.HwndSourceHook], $probe, $probe.GetType().GetMethod('OnMessage'))
        $window.AddHook($hook)
        $probe.Register($window.Handle, $specification.Path)
        $probes.Add([pscustomobject] @{ Name = $specification.Name; Probe = $probe; Window = $window; Hook = $hook })
    }
    Pump 1000
    foreach ($entry in $probes) { [void] $entry.Probe.Drain() }
    Write-Output "READY Extension: $extension"
    Write-Output "Test file: $file"
    Write-Output "Effective association before: $before"
    Start-Process 'ms-settings:defaultapps'
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $after = $before
    while ([DateTime]::UtcNow -lt $deadline) {
        Pump 500
        $after = [ManualAssociationQuery]::Effective($extension)
        if ($after -ne $before) { break }
    }
    if ($after -eq $before) { throw 'Timed out without a verified effective association change.' }
    Pump 5000
    $after = [ManualAssociationQuery]::Effective($extension)
    Write-Output "Effective association after: $after"
    foreach ($specification in @(@{ Path = $file; Variant = 'small'; Size = 16 }, @{ Path = $file; Variant = 'sized'; Size = 32 }, @{ Path = $secondFile; Variant = 'small'; Size = 16 })) {
        $entry = $find.Invoke($cache, [object[]] @([string] $specification.Path, [string] $specification.Variant, [int] $specification.Size, [int] $specification.Size))
        if ($null -eq $entry -or [object]::ReferenceEquals($entry.Image, $sentinel)) { throw "Matching cache entry was not refreshed: $($specification.Path) $($specification.Variant)" }
    }
    foreach ($path in @($unrelatedFile, $matchingDirectory)) {
        $entry = $find.Invoke($cache, [object[]] @([string] $path, [string] 'small', [int] 16, [int] 16))
        if ($null -eq $entry -or -not [object]::ReferenceEquals($entry.Image, $sentinel)) { throw "Unrelated cache entry was refreshed: $path" }
    }
    Write-Output 'Production observer: matching file variants refreshed; unrelated file and matching directory unchanged.'
    foreach ($entry in $probes) {
        $events = @($entry.Probe.Drain())
        Write-Output "Events / $($entry.Name): $($events -join '; ')"
        Write-Output "UPDATEITEM / $($entry.Name): $(@($events | Where-Object { $_ -like '0x00002000 *' }).Count)"
        Write-Output "ASSOCCHANGED / $($entry.Name): $(@($events | Where-Object { $_ -like '0x08000000 *' }).Count)"
    }
}
finally {
    if ($null -ne $observer) { $observer.Dispose() }
    foreach ($entry in $probes) { $entry.Probe.Stop(); $entry.Window.RemoveHook($entry.Hook); $entry.Window.Dispose() }
    foreach ($name in @($extension, $type)) { $classes.DeleteSubKeyTree($name, $false) }
    $classes.Dispose()
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fileExtsPath, $false) }
    catch { Write-Warning "Could not remove temporary user association $fileExtsPath`: $($_.Exception.Message)" }
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}