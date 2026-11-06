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
    [DllImport("user32.dll")] public static extern bool EnableWindow(IntPtr window, bool enabled);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
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
$registeredAppType = $assembly.GetType('SUTWinExplorer.RegisteredApp', $true)
$unknownApp = [Activator]::CreateInstance($registeredAppType, [object[]] @('not-a-registered-app', 'Unknown'))
$missingPath = [string] (Join-Path ([IO.Path]::GetTempPath()) ('kis-missing-' + [guid]::NewGuid().ToString('N') + '.docx'))
$shellResult = $accessor.GetMethod('OpenByShellOpen').Invoke($null, [object[]] @($unknownApp, $missingPath))
if ($shellResult.Dispatched -or -not $shellResult.Error) { throw 'Shell Open must reject a missing file.' }
$existingPath = [string] (Join-Path $PSScriptRoot '../Configuration.md')
$shellResult = $accessor.GetMethod('OpenByShellOpen').Invoke($null, [object[]] @($unknownApp, $existingPath))
if ($shellResult.Dispatched -or -not $shellResult.Error) { throw 'Shell Open must reject an unregistered application.' }
$privateStatic = [Reflection.BindingFlags]'Static,NonPublic'
$resolveMethod = $accessor.GetMethod('ResolveConfiguredOpenMethod', $privateStatic)
if ($resolveMethod.Invoke($null, @('winword.exe', 'microsoft corporation')) -ne 'OpenByShellOpen' -or
    $resolveMethod.Invoke($null, @('Acrobat.exe', 'Adobe Systems Incorporated')) -ne 'OpenByShellOpen' -or
    $null -ne $resolveMethod.Invoke($null, @('WINWORD.EXE', 'Another company')) -or
    $null -ne $resolveMethod.Invoke($null, @('unknown.exe', 'Microsoft Corporation'))) { throw 'Application identity matching failed.' }
$resolveAppMethod = $accessor.GetMethod('ResolveConfiguredAppMethod', $privateStatic)
if ($resolveAppMethod.Invoke($null, @('microsoft.windows.photos_8wekyb3d8bbwe!app')) -ne 'OpenByShellOpen' -or
    $null -ne $resolveAppMethod.Invoke($null, @('Unrelated.Package_1234567890123!App')) -or
    $null -ne $resolveAppMethod.Invoke($null, @($null))) { throw 'Packaged application identity matching failed.' }
foreach ($executable in @('EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE', 'ONENOTE.EXE', 'MSACCESS.EXE', 'MSPUB.EXE', 'VISIO.EXE', 'WINPROJ.EXE', 'INFOPATH.EXE')) {
    if ($resolveMethod.Invoke($null, @($executable, 'Microsoft Corporation')) -ne 'OpenByShellOpen') { throw "Office application $executable is not configured for Shell Open." }
}
foreach ($executable in @('soffice.bin', 'soffice.exe', 'swriter.exe', 'scalc.exe', 'simpress.exe', 'sdraw.exe', 'sbase.exe', 'smath.exe')) {
    if ($resolveMethod.Invoke($null, @($executable, 'The Document Foundation')) -ne 'OpenByShellOpen') { throw "LibreOffice application $executable is not configured for Shell Open." }
    if ($null -ne $resolveMethod.Invoke($null, @($executable, 'Another company'))) { throw "LibreOffice application $executable matched the wrong company." }
}
$matchLibreOffice = $accessor.GetMethod('MatchesLibreOfficeLauncher', $privateStatic)
foreach ($launcher in @('soffice.exe', 'swriter.exe', 'scalc.exe', 'simpress.exe', 'sdraw.exe', 'sbase.exe', 'smath.exe')) {
    if (-not $matchLibreOffice.Invoke($null, @("C:\LibreOffice\$launcher", 'C:\LibreOffice\soffice.bin', 'The Document Foundation'))) { throw "LibreOffice launcher $launcher did not match its window process." }
}
if ($matchLibreOffice.Invoke($null, @('C:\Other\soffice.exe', 'C:\LibreOffice\soffice.bin', 'The Document Foundation')) -or
    $matchLibreOffice.Invoke($null, @('C:\LibreOffice\soffice.exe', 'C:\LibreOffice\soffice.bin', 'Another company')) -or
    $matchLibreOffice.Invoke($null, @('C:\LibreOffice\other.exe', 'C:\LibreOffice\soffice.bin', 'The Document Foundation'))) { throw 'LibreOffice launcher matched an unrelated application.' }
$configuredMethods = $accessor.GetField('ConfiguredOpenMethods', $privateStatic).GetValue($null).Value
$testProcess = [Diagnostics.Process]::GetCurrentProcess()
$testKey = [ValueTuple[string, string]]::new([IO.Path]::GetFileName($testProcess.MainModule.FileName).ToUpperInvariant(), $testProcess.MainModule.FileVersionInfo.CompanyName.ToUpperInvariant())
$testApp = [Activator]::CreateInstance($registeredAppType, [object[]] @([string] $testProcess.MainModule.FileName, 'Test process'))
$testProcess.Dispose()
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-resourceful-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($directory)
$firstFile = Join-Path $directory 'first.txt'
$secondFile = Join-Path $directory 'second.txt'
$unregisteredFile = Join-Path $directory ('file.kis-resourceful-' + [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($firstFile, 'first')
[IO.File]::WriteAllText($secondFile, 'second')
[IO.File]::WriteAllText($unregisteredFile, 'unregistered')
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
    $unrelatedPackagedApp = [Activator]::CreateInstance($registeredAppType, [object[]] @('not-a-handler', 'Unrelated package'))
    $registeredAppType.GetProperty('AppUserModelId').SetValue($unrelatedPackagedApp, 'Microsoft.Windows.Photos_8wekyb3d8bbwe!App')
    $matchAppWindow = $accessor.GetMethod('MatchesAppWindow', $privateStatic)
    if ($matchAppWindow.Invoke($null, [object[]] @($unrelatedPackagedApp, $targetHandle, [uint32] $PID))) { throw 'A packaged application matched an unrelated window.' }
    $target = [Activator]::CreateInstance($appWindowType, [object[]] @($targetHandle, 'test target'))
    $resourceful = $accessor.GetMethod('OpenInRunningAppResourcefully')
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile, [string] $secondFile), $null))
    $result = Wait-ResourcefulTask $task
    if ($result.Error -or $result.Dialogs.Count -ne 1 -or $result.Dialogs[0].Submitted -or -not $result.Drop.Dropped) { throw "The multi-file drop fallback failed: $($result.Error) $($result.Drop.Error); dialog=$($result.Dialogs[0].Error); foreground=$([ResourcefulTestNative]::GetForegroundWindow()); target=$targetHandle." }
    if ($script:resourcefulFiles.Count -ne 2 -or $firstFile -notin $script:resourcefulFiles -or $secondFile -notin $script:resourcefulFiles) { throw 'The fallback did not drop both remaining files.' }
    $script:resourcefulFiles = @()
    $script:blockResourceful = $true
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if ($null -eq $script:resourcefulDialog -or $null -ne $result.Drop -or -not $result.Error -or $script:resourcefulFiles.Count -ne 0) { throw 'An open unsupported dialog did not prevent the fallback drop.' }
    $dialogHandle = [System.Windows.Interop.WindowInteropHelper]::new($script:resourcefulDialog).Handle
    $existingHandles = [Collections.Generic.HashSet[IntPtr]]::new()
    [void] $existingHandles.Add($targetHandle)
    $matchDialogOwner = $accessor.GetMethod('IsExpectedOpenDialogOwner', $privateStatic)
    if (-not $matchDialogOwner.Invoke($null, [object[]] @($dialogHandle, $targetHandle, [uint32] $PID, $existingHandles, $existingHandles))) { throw 'A directly owned dialog was not recognized.' }
    if ($matchDialogOwner.Invoke($null, [object[]] @($dialogHandle, $dialogHandle, [uint32] $PID, $existingHandles, $existingHandles))) { throw 'An unrelated same-process dialog owner was accepted.' }
    $script:resourcefulDialog.Close()
    $script:resourcefulDialog = $null
    $probeScript = @'
Add-Type -AssemblyName PresentationFramework
$window = [System.Windows.Window]::new()
$window.Title = 'Cross-process dialog test'
[System.Windows.Interop.WindowInteropHelper]::new($window).Owner = [IntPtr] TARGET_HANDLE
$window.add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$window.Show()
[Console]::WriteLine([System.Windows.Interop.WindowInteropHelper]::new($window).Handle.ToInt64())
[Console]::Out.Flush()
[System.Windows.Threading.Dispatcher]::Run()
'@.Replace('TARGET_HANDLE', $targetHandle.ToInt64().ToString())
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    foreach ($argument in @('-NoProfile', '-STA', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript)))) { $startInfo.ArgumentList.Add($argument) }
    $dialogProcess = [Diagnostics.Process]::Start($startInfo)
    $foreignHandle = [IntPtr]::Zero
    try {
        $foreignHandle = [IntPtr] [long] (Wait-ResourcefulTask $dialogProcess.StandardOutput.ReadLineAsync())
        if ($foreignHandle -eq [IntPtr]::Zero) { throw 'The cross-process test dialog did not open.' }
        if ($matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $targetHandle, [uint32] $PID, $existingHandles, $existingHandles))) { throw 'A cross-process dialog was accepted while the target was enabled.' }
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $false)
        if (-not $matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $targetHandle, [uint32] $PID, $existingHandles, $existingHandles))) { throw 'The directly owned cross-process dialog was rejected.' }
        $emptyHandles = [Collections.Generic.HashSet[IntPtr]]::new()
        if ($matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $targetHandle, [uint32] $PID, $existingHandles, $emptyHandles)) -or
            $matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $targetHandle, [uint32] $PID, $emptyHandles, $existingHandles)) -or
            $matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $targetHandle, [uint32] $dialogProcess.Id, $existingHandles, $existingHandles)) -or
            $matchDialogOwner.Invoke($null, [object[]] @($foreignHandle, $foreignHandle, [uint32] $dialogProcess.Id, $existingHandles, $existingHandles))) { throw 'An unrelated or previously unavailable cross-process target was accepted.' }
        $matchDialogProcess = $accessor.GetMethod('IsDialogProcess', $privateStatic)
        if (-not $matchDialogProcess.Invoke($null, [object[]] @($foreignHandle, [uint32] $dialogProcess.Id)) -or
            $matchDialogProcess.Invoke($null, [object[]] @($foreignHandle, [uint32] $PID))) { throw 'The dialog process identity was not checked correctly.' }
    } finally {
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $true)
        if ($foreignHandle -ne [IntPtr]::Zero) { [void] [ResourcefulTestNative]::PostMessage($foreignHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        try { [void] (Wait-ResourcefulTask $dialogProcess.WaitForExitAsync()) }
        catch { if (-not $dialogProcess.HasExited) { $dialogProcess.Kill(); $dialogProcess.WaitForExit() } }
        $dialogProcess.Dispose()
    }
    $sharedOwner = [System.Windows.Window]::new()
    $sharedOwner.Title = 'Shared application window'
    $sharedDialog = [System.Windows.Window]::new()
    $sharedDialog.Title = 'Shared owner test dialog'
    try {
        $sharedOwner.Show()
        $sharedDialog.Owner = $sharedOwner
        $sharedDialog.Show()
        $sharedOwnerHandle = [System.Windows.Interop.WindowInteropHelper]::new($sharedOwner).Handle
        $sharedDialogHandle = [System.Windows.Interop.WindowInteropHelper]::new($sharedDialog).Handle
        $visibleBefore = [Collections.Generic.HashSet[IntPtr]]::new()
        [void] $visibleBefore.Add($targetHandle)
        [void] $visibleBefore.Add($sharedOwnerHandle)
        $enabledBefore = [Collections.Generic.HashSet[IntPtr]]::new($visibleBefore)
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $false)
        [void] [ResourcefulTestNative]::EnableWindow($sharedOwnerHandle, $false)
        if (-not $matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'A uniquely identified shared application owner was rejected.' }
        $extraWindow = [System.Windows.Window]::new()
        try {
            $extraWindow.Title = 'Additional application window'
            $extraWindow.Show()
            if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'A newly visible unrelated window was accepted.' }
        } finally { $extraWindow.Close() }
        if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] 0, $visibleBefore, $enabledBefore))) { throw 'A shared owner from a different process was accepted.' }
        [void] $visibleBefore.Add($sharedDialogHandle)
        if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'An ambiguous shared owner was accepted.' }
        [void] $visibleBefore.Remove($sharedDialogHandle)
        [void] $enabledBefore.Remove($sharedOwnerHandle)
        if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'A previously disabled shared owner was accepted.' }
        [void] $enabledBefore.Add($sharedOwnerHandle)
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $true)
        if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'A shared owner was accepted while the target remained enabled.' }
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $false)
        [void] [ResourcefulTestNative]::EnableWindow($sharedOwnerHandle, $true)
        if ($matchDialogOwner.Invoke($null, [object[]] @($sharedDialogHandle, $targetHandle, [uint32] $PID, $visibleBefore, $enabledBefore))) { throw 'An enabled shared owner was accepted.' }
    } finally {
        [void] [ResourcefulTestNative]::EnableWindow($targetHandle, $true)
        if ($sharedOwnerHandle -ne [IntPtr]::Zero) { [void] [ResourcefulTestNative]::EnableWindow($sharedOwnerHandle, $true) }
        $sharedDialog.Close()
        $sharedOwner.Close()
    }
    $script:keepDialogInBackground = $true
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if ($null -eq $script:resourcefulDialog -or [ResourcefulTestNative]::GetForegroundWindow() -ne $targetHandle -or
        $null -ne $result.Drop -or -not $result.Error -or $script:resourcefulFiles.Count -ne 0) { throw 'A background owned dialog did not prevent the fallback drop.' }
    $script:resourcefulDialog.Close()
    $script:resourcefulDialog = $null
    $script:blockResourceful = $false
    $configuredMethods.Add($testKey, 'LetOpenByDialog')
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if (-not $result.Error -or $null -ne $result.Drop -or $result.Dialogs.Count -ne 1 -or $result.Dialogs[0].Submitted -or $script:resourcefulFiles.Count -ne 0) { throw 'A configured dialog failure must not fall back to a drop.' }
    $configuredMethods[$testKey] = 'LetOpenByDialogUsingO'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if (-not $script:plainOReceived -or -not $result.Error -or $null -ne $result.Drop) { throw 'The configured plain-O dialog method was not used.' }
    $configuredMethods[$testKey] = 'LetOpenByDialogUsingCtrlF12'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if (-not $script:ctrlF12Received -or -not $result.Error -or $null -ne $result.Drop) { throw 'The configured Ctrl+F12 dialog method was not used.' }
    $configuredMethods[$testKey] = 'OpenByShellOpen'
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $unknownApp))
    $result = Wait-ResourcefulTask $task
    if (-not $result.Error -or $null -ne $result.Drop -or $null -ne $result.ShellOpens -or $result.Dialogs.Count -ne 0) { throw 'A mismatched selected application must not trigger any transfer.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $unregisteredFile, [string] $secondFile), $testApp))
    $result = Wait-ResourcefulTask $task
    if (-not $result.Error -or $null -ne $result.Drop -or $result.Dialogs.Count -ne 0 -or $result.ShellOpens.Count -ne 1 -or $result.ShellOpens[0].Dispatched) { throw 'A failed Shell Open must stop without a fallback or further files.' }
    $configuredMethods[$testKey] = 'DropToAppWindow'
    if (-not [ResourcefulTestNative]::Activate($targetHandle)) { throw 'Could not reactivate the test window.' }
    $task = $resourceful.Invoke($null, [object[]] @($target, [string[]] @([string] $firstFile), $null))
    $result = Wait-ResourcefulTask $task
    if ($result.Error -or -not $result.Drop.Dropped -or $result.Dialogs.Count -ne 0 -or $firstFile -notin $script:resourcefulFiles) { throw 'The configured drop method was not used.' }
    'Resourceful open tests passed.'
} finally {
    [void] $configuredMethods.Remove($testKey)
    if ($null -ne $script:resourcefulDialog) { $script:resourcefulDialog.Close() }
    $targetWindow.Close()
    [IO.Directory]::Delete($directory, $true)
}