$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ResourcefulTestNative
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint thread, uint other, bool attach);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    public static bool Activate(IntPtr window)
    {
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        uint current = GetCurrentThreadId();
        bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
        try { BringWindowToTop(window); return SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
    }
}
'@
function Wait-ResourcefulTask($task) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $timer.add_Tick({ if ($task.IsCompleted -or [DateTime]::UtcNow -gt $deadline) { $timer.Stop(); $frame.Continue = $false } }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $task.IsCompleted) { throw 'The resourceful operation timed out.' }
    return $task.GetAwaiter().GetResult()
}
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll')))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$appWindowType = $assembly.GetType('SUTWinExplorer.AppWindow', $true)
$privateStatic = [Reflection.BindingFlags]'Static,NonPublic'
$resolveMethod = $accessor.GetMethod('ResolveConfiguredOpenMethod', $privateStatic)
if ($resolveMethod.Invoke($null, @('winword.exe', 'microsoft corporation')) -ne 'LetOpenByDialogUsingCtrlF12' -or
    $resolveMethod.Invoke($null, @('Acrobat.exe', 'Adobe Systems Incorporated')) -ne 'LetOpenByDialog' -or
    $null -ne $resolveMethod.Invoke($null, @('WINWORD.EXE', 'Another company')) -or
    $null -ne $resolveMethod.Invoke($null, @('unknown.exe', 'Microsoft Corporation'))) { throw 'Application identity matching failed.' }
$configuredMethods = $accessor.GetField('ConfiguredOpenMethods', $privateStatic).GetValue($null).Value
$testProcess = [Diagnostics.Process]::GetCurrentProcess()
$testKey = [ValueTuple[string, string]]::new([IO.Path]::GetFileName($testProcess.MainModule.FileName).ToUpperInvariant(), $testProcess.MainModule.FileVersionInfo.CompanyName.ToUpperInvariant())
$testProcess.Dispose()
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-resourceful-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($directory)
$firstFile = Join-Path $directory 'first.txt'
$secondFile = Join-Path $directory 'second.txt'
[IO.File]::WriteAllText($firstFile, 'first')
[IO.File]::WriteAllText($secondFile, 'second')
$targetWindow = [System.Windows.Window]::new()
$script:resourcefulTargetWindow = $targetWindow
$targetWindow.Title = 'Resourceful test target'
$targetWindow.Left = 100; $targetWindow.Top = 100; $targetWindow.Width = 500; $targetWindow.Height = 400
$surface = [System.Windows.Controls.Border]::new()
$surface.Background = [System.Windows.Media.Brushes]::LightGray
$surface.AllowDrop = $true
$targetWindow.Content = $surface
$script:resourcefulFiles = @()
$script:blockResourceful = $false
$script:keepDialogInBackground = $false
$script:plainOReceived = $false
$script:ctrlF12Received = $false
$script:resourcefulDialog = $null
$dragHandler = [System.Windows.DragEventHandler] {
    param($sender, $eventArgs)
    $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
    $eventArgs.Handled = $true
}
$dropHandler = [System.Windows.DragEventHandler] {
    param($sender, $eventArgs)
    $script:resourcefulFiles = @($eventArgs.Data.GetData([System.Windows.DataFormats]::FileDrop))
    $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
    $eventArgs.Handled = $true
}
$keyHandler = [System.Windows.Input.KeyEventHandler] {
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::O -and
        -not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { $script:plainOReceived = $true }
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::F12 -and
        ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { $script:ctrlF12Received = $true }
    if ($script:blockResourceful -and $eventArgs.Key -eq [System.Windows.Input.Key]::O -and
        ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $script:resourcefulDialog = [System.Windows.Window]::new()
        $script:resourcefulDialog.Title = 'Unsupported test dialog'
        $script:resourcefulDialog.Owner = $script:resourcefulTargetWindow
        $script:resourcefulDialog.Show()
        $null = $script:resourcefulDialog.Activate()
        if ($script:keepDialogInBackground) { [void] [ResourcefulTestNative]::Activate($targetHandle) }
        $eventArgs.Handled = $true
    }
}
$surface.Add_DragEnter($dragHandler)
$surface.Add_DragOver($dragHandler)
$surface.Add_Drop($dropHandler)
$targetWindow.Add_PreviewKeyDown($keyHandler)
try {
    $targetWindow.Show()
    $targetHandle = [System.Windows.Interop.WindowInteropHelper]::new($targetWindow).Handle
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not activate the test window.' }
    $target = [Activator]::CreateInstance($appWindowType, [object[]] @($targetHandle, 'test target'))
    $resourceful = $accessor.GetMethod('OpenInRunningAppResourcefully')
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile, [string] $secondFile)))
    $result = Wait-ResourcefulTask $task
    if ($result.Error -or $result.Dialogs.Count -ne 1 -or $result.Dialogs[0].Submitted -or -not $result.Drop.Dropped) { throw "The multi-file drop fallback failed: $($result.Error) $($result.Drop.Error); dialog=$($result.Dialogs[0].Error); foreground=$([ResourcefulTestNative]::GetForegroundWindow()); target=$targetHandle." }
    if ($script:resourcefulFiles.Count -ne 2 -or $firstFile -notin $script:resourcefulFiles -or $secondFile -notin $script:resourcefulFiles) { throw 'The fallback did not drop both remaining files.' }
    $script:resourcefulFiles = @()
    $script:blockResourceful = $true
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if ($null -eq $script:resourcefulDialog -or $null -ne $result.Drop -or -not $result.Error -or $script:resourcefulFiles.Count -ne 0) { throw 'An open unsupported dialog did not prevent the fallback drop.' }
    $script:resourcefulDialog.Close()
    $script:resourcefulDialog = $null
    $script:keepDialogInBackground = $true
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if ($null -eq $script:resourcefulDialog -or [ResourcefulTestNative]::GetForegroundWindow() -ne $targetHandle -or
        $null -ne $result.Drop -or -not $result.Error -or $script:resourcefulFiles.Count -ne 0) { throw 'A background owned dialog did not prevent the fallback drop.' }
    $script:resourcefulDialog.Close()
    $script:resourcefulDialog = $null
    $script:blockResourceful = $false
    $configuredMethods.Add($testKey, 'LetOpenByDialog')
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if (-not $result.Error -or $null -ne $result.Drop -or $result.Dialogs.Count -ne 1 -or $result.Dialogs[0].Submitted -or $script:resourcefulFiles.Count -ne 0) { throw 'A configured dialog failure must not fall back to a drop.' }
    $configuredMethods[$testKey] = 'LetOpenByDialogUsingO'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if (-not $script:plainOReceived -or -not $result.Error -or $null -ne $result.Drop) { throw 'The configured plain-O dialog method was not used.' }
    $configuredMethods[$testKey] = 'LetOpenByDialogUsingCtrlF12'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if (-not $script:ctrlF12Received -or -not $result.Error -or $null -ne $result.Drop) { throw 'The configured Ctrl+F12 dialog method was not used.' }
    $configuredMethods[$testKey] = 'DropToAppWindow'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile)))
    $result = Wait-ResourcefulTask $task
    if ($result.Error -or -not $result.Drop.Dropped -or $result.Dialogs.Count -ne 0 -or $firstFile -notin $script:resourcefulFiles) { throw 'The configured drop method was not used.' }
    'Resourceful open tests passed.'
} finally {
    [void] $configuredMethods.Remove($testKey)
    if ($null -ne $script:resourcefulDialog) { $script:resourcefulDialog.Close() }
    $targetWindow.Close()
    [IO.Directory]::Delete($directory, $true)
}