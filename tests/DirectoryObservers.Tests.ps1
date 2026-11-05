param(
    [string[]] $Modes = @('filesystem', 'shell'),
    [string[]] $Scenarios = @('file-create', 'file-write', 'file-date', 'file-rename', 'file-delete',
        'folder-create', 'folder-rename', 'folder-date', 'folder-delete', 'idle', 'nested-create',
        'nested-write', 'nested-rename', 'nested-delete', 'deep-create', 'shell-parent-update',
        'shell-child-update', 'shell-grandchild-update', 'shell-file-create', 'shell-nested-create',
        'shell-folder-update', 'shell-file-rename')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public sealed class DirectoryObserverProbe
{
    public readonly List<string> Notifications = new List<string>();

    public void OnChanged(object notification)
    {
        var type = notification.GetType();
        var path = (string)type.GetProperty("DirectoryPath").GetValue(notification);
        var change = type.GetProperty("Change").GetValue(notification) as FileSystemEventArgs;
        var rename = change as RenamedEventArgs;
        lock (Notifications)
            Notifications.Add(path + " | " + (change == null ? "directory" : change.ChangeType + " " + change.FullPath + (rename == null ? "" : " from " + rename.OldFullPath)));
    }

    public string[] Drain()
    {
        lock (Notifications)
        {
            var result = Notifications.ToArray();
            Notifications.Clear();
            return result;
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);

    [DllImport("shell32.dll", EntryPoint = "SHChangeNotify", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotifyRename(int eventId, uint flags, string item1, string item2);
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

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$method = $shell.GetMethod('ObservePathviewDirectories', [Reflection.BindingFlags]'Static,NonPublic')
$notificationType = $assembly.GetType('SUTWinExplorer.DirectoryNotification', $true)
$actionType = [Action``1].MakeGenericType($notificationType)
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-directory-observers-' + [guid]::NewGuid().ToString('N'))
$oldObserver = [Environment]::GetEnvironmentVariable('KIS_DIRECTORY_OBSERVER')
$results = [Collections.Generic.List[object]]::new()

try {
    foreach ($mode in $Modes) {
        foreach ($scenario in $Scenarios) {
            $directory = Join-Path $root ($mode + '-' + $scenario)
            $child = Join-Path $directory 'child'
            $grandchild = Join-Path $child 'grandchild'
            $file = Join-Path $directory 'file.txt'
            $nested = Join-Path $child 'nested.txt'
            [void] [IO.Directory]::CreateDirectory($grandchild)
            [IO.File]::WriteAllText($file, 'initial')
            if ($scenario -eq 'shell-file-rename') { [IO.File]::WriteAllText((Join-Path $directory 'renamed.txt'), 'initial') }
            [IO.File]::WriteAllText($nested, 'initial')
            Pump 1500
            [Environment]::SetEnvironmentVariable('KIS_DIRECTORY_OBSERVER', $mode)
            $probe = [DirectoryObserverProbe]::new()
            $callback = [Delegate]::CreateDelegate($actionType, $probe, $probe.GetType().GetMethod('OnChanged'))
            $arguments = [object[]]::new(3)
            $arguments[0] = [string[]] @($directory)
            $arguments[1] = [string] $directory
            $arguments[2] = $callback
            $observer = $method.Invoke($null, $arguments)
            try {
                Pump 500
                [void] $probe.Drain()
                switch ($scenario) {
                    'file-create' { [IO.File]::WriteAllText((Join-Path $directory 'created.txt'), 'created') }
                    'file-write' { [IO.File]::AppendAllText($file, 'changed') }
                    'file-date' { [IO.File]::SetLastWriteTimeUtc($file, [datetime]::UtcNow.AddDays(-2)) }
                    'file-rename' { [IO.File]::Move($file, (Join-Path $directory 'renamed.txt')) }
                    'file-delete' { [IO.File]::Delete($file) }
                    'folder-create' { [void] [IO.Directory]::CreateDirectory((Join-Path $directory 'created-folder')) }
                    'folder-rename' { [IO.Directory]::Move($child, (Join-Path $directory 'renamed-folder')) }
                    'folder-date' { [IO.Directory]::SetLastWriteTimeUtc($child, [datetime]::UtcNow.AddDays(-2)) }
                    'folder-delete' { [IO.Directory]::Delete($child, $true) }
                    'idle' { }
                    'nested-create' { [IO.File]::WriteAllText((Join-Path $child 'created.txt'), 'created') }
                    'nested-write' { [IO.File]::AppendAllText($nested, 'changed') }
                    'nested-rename' { [IO.File]::Move($nested, (Join-Path $child 'renamed.txt')) }
                    'nested-delete' { [IO.File]::Delete($nested) }
                    'deep-create' { [IO.File]::WriteAllText((Join-Path $grandchild 'created.txt'), 'created') }
                    'shell-parent-update' { [DirectoryObserverProbe]::SHChangeNotify(0x1000, 0x1005, $directory, [IntPtr]::Zero) }
                    'shell-child-update' { [DirectoryObserverProbe]::SHChangeNotify(0x1000, 0x1005, $child, [IntPtr]::Zero) }
                    'shell-grandchild-update' { [DirectoryObserverProbe]::SHChangeNotify(0x1000, 0x1005, $grandchild, [IntPtr]::Zero) }
                    'shell-file-create' { [DirectoryObserverProbe]::SHChangeNotify(0x0002, 0x1005, $file, [IntPtr]::Zero) }
                    'shell-nested-create' { [DirectoryObserverProbe]::SHChangeNotify(0x0002, 0x1005, $nested, [IntPtr]::Zero) }
                    'shell-folder-update' { [DirectoryObserverProbe]::SHChangeNotify(0x2000, 0x1005, $child, [IntPtr]::Zero) }
                    'shell-file-rename' { [DirectoryObserverProbe]::SHChangeNotifyRename(0x0001, 0x1005, $file, (Join-Path $directory 'renamed.txt')) }
                }
                Pump 2000
                $notifications = @($probe.Drain())
                $results.Add([pscustomobject] @{ Observer = $mode; Scenario = $scenario; Count = $notifications.Count; Notifications = $notifications -join '; ' })
            }
            finally {
                $observer.Dispose()
            }
        }
    }
    $results | Format-Table Observer, Scenario, Count -AutoSize | Out-String -Width 120 | Write-Output
    foreach ($result in $results | Where-Object { $_.Observer -eq 'shell' -and $_.Count -gt 0 -and $_.Scenario -in @('idle', 'nested-create', 'nested-write', 'nested-rename', 'nested-delete', 'deep-create', 'shell-child-update', 'shell-grandchild-update', 'shell-nested-create') }) {
        Write-Output "Nested operation $($result.Scenario): $($result.Notifications)"
    }
    $parentControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-parent-update' }
    $childControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-child-update' }
    $grandchildControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-grandchild-update' }
    $createControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-file-create' }
    $nestedCreateControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-nested-create' }
    $folderUpdateControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-folder-update' }
    $renameControl = $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -eq 'shell-file-rename' }
    $failures = [Collections.Generic.List[string]]::new()
    if ($null -ne $parentControl -and $parentControl.Count -lt 1) { $failures.Add('The Shell observer missed a parent UPDATEDIR notification.') }
    if ($null -ne $childControl -and $childControl.Count -ne 0) { $failures.Add('A child UPDATEDIR operation notified the parent observer.') }
    if ($null -ne $grandchildControl -and $grandchildControl.Count -ne 0) { $failures.Add('A grandchild UPDATEDIR operation notified the parent observer.') }
    if ($null -ne $createControl -and ($createControl.Count -lt 1 -or $createControl.Notifications -notmatch 'Created')) { $failures.Add('A direct CREATE notification was not delivered.') }
    if ($null -ne $nestedCreateControl -and $nestedCreateControl.Count -ne 0) { $failures.Add('A nested CREATE operation notified the parent observer.') }
    if ($null -ne $folderUpdateControl -and ($folderUpdateControl.Count -lt 1 -or $folderUpdateControl.Notifications -notmatch 'Changed')) { $failures.Add('A direct folder UPDATEITEM notification was not delivered as a metadata change.') }
    if ($null -ne $renameControl -and ($renameControl.Count -lt 1 -or $renameControl.Notifications -notmatch 'Renamed .*renamed\.txt from .*file\.txt')) { $failures.Add('A direct RENAMEITEM notification did not preserve both paths.') }
    foreach ($result in $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -in @('file-create', 'file-write', 'file-date', 'file-rename', 'file-delete', 'folder-create', 'folder-rename', 'folder-date', 'folder-delete') }) {
        if ($result.Count -eq 0) { $failures.Add("The Shell observer missed the direct operation: $($result.Scenario).") }
        if ($result.Scenario -eq 'folder-date' -and $result.Notifications -notmatch 'Changed .*\\child') { $failures.Add('The folder timestamp change did not identify the direct child.') }
        if ($result.Scenario -eq 'folder-rename' -and $result.Notifications -notmatch 'Renamed .*renamed-folder from .*\\child') { $failures.Add('The folder rename did not preserve both paths.') }
    }
    foreach ($result in $results | Where-Object { $_.Observer -eq 'shell' -and $_.Scenario -in @('idle', 'nested-create', 'nested-write', 'nested-rename', 'nested-delete', 'deep-create') }) {
        if ($result.Count -ne 0) { $failures.Add("A nested or idle operation notified the Shell parent observer: $($result.Scenario).") }
    }
    foreach ($result in $results | Where-Object { $_.Observer -eq 'filesystem' -and $_.Scenario -in @('folder-rename', 'folder-date') }) {
        if ($result.Count -eq 0) { $failures.Add("The filesystem observer missed the baseline operation: $($result.Scenario).") }
    }
    if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
}
finally {
    [Environment]::SetEnvironmentVariable('KIS_DIRECTORY_OBSERVER', $oldObserver)
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}