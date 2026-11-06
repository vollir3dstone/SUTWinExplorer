$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PhotosTestWindow
{
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
}
'@

function Wait-Until([scriptblock] $condition, [string] $message, [int] $seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $message
}

function Get-PhotosWindows {
    $processIds = @(Get-Process -Name Photos -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $package.InstallLocation 'Photos.exe') } | Select-Object -ExpandProperty Id)
    $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($root in $roots) {
        if ($root.Current.NativeWindowHandle -eq 0 -or $root.Current.IsOffscreen) { continue }
        foreach ($processId in $processIds) {
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $processId)
            if ($root.Current.ProcessId -eq $processId -or $null -ne $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                $root
                break
            }
        }
    }
}

$appId = 'Microsoft.Windows.Photos_8wekyb3d8bbwe!App'
$startApps = @(Get-StartApps | Where-Object { $_.AppID -eq $appId })
if ($startApps.Count -ne 1) { throw 'The Windows Photos package is not installed or registered.' }
$package = Get-AppxPackage -Name Microsoft.Windows.Photos
if ($null -eq $package) { throw 'The Windows Photos package was not found.' }
if (@(Get-PhotosWindows).Count -ne 0) { throw 'Windows Photos already has an open window. Close it before running this test.' }

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$handlers = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @('test.jpg')) | Where-Object { $_.AppUserModelId -eq $appId })
if ($handlers.Count -ne 1) { throw 'Expected exactly one registered Windows Photos JPEG handler.' }
$selectedApp = $handlers[0].PSObject.BaseObject
$windowHandle = [IntPtr]::Zero
$temporaryMediaPath = $null
$imageName = $null
try {
    Start-Process "shell:AppsFolder\$appId"
    Wait-Until {
        $windows = @(Get-PhotosWindows)
        if ($windows.Count -ne 1) { return $false }
        $script:windowHandle = [IntPtr] $windows[0].Current.NativeWindowHandle
        return [PhotosTestWindow]::IsWindowEnabled($script:windowHandle)
    } 'Windows Photos did not open exactly one enabled window.' 30

    $directory = Join-Path ([IO.Path]::GetTempPath()) 'KIS-File-Paste-Test'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $imageName = 'KIS-Paste-' + [guid]::NewGuid().ToString('N')
    $filePath = Join-Path $directory ($imageName + '.jpg')
    [IO.File]::Copy((Join-Path $PSScriptRoot 'resources\image.jpg'), $filePath)
    $temporaryMediaPath = $filePath

    $readyAt = [DateTime]::UtcNow.AddSeconds(5)
    Wait-Until { [DateTime]::UtcNow -ge $readyAt } 'The Photos startup wait did not complete.'
    if (-not [PhotosTestWindow]::IsWindowEnabled($windowHandle)) { throw 'The Photos window is no longer ready.' }
    Wait-Until {
        $apps = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)) | Where-Object { $_.App.Id -eq $selectedApp.Id })
        $script:matchingWindows = @($apps.Windows | Where-Object { $_.Handle -eq $script:windowHandle })
        return $script:matchingWindows.Count -eq 1
    } 'The Windows Photos window was not found among the JPEG applications.'
    $window = $script:matchingWindows[0].PSObject.BaseObject
    $task = $accessor.GetMethod('OpenInRunningAppResourcefully').Invoke($null, [object[]] @($window, [string[]] @($filePath), $selectedApp))
    Wait-Until { $task.IsCompleted } 'The Resourceful operation did not complete.'
    $result = $task.GetAwaiter().GetResult()
    if ($result.Error) { throw "The Resourceful operation failed: $($result.Error)" }
    if ($result.ShellOpens.Count -ne 1 -or -not $result.ShellOpens[0].Dispatched -or $result.Dialogs.Count -ne 0 -or $null -ne $result.Drop) {
        throw 'Windows Photos did not receive exactly one Shell Open operation.'
    }
    Wait-Until {
        $roots = @(Get-PhotosWindows)
        foreach ($root in $roots) {
            $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
            if (@($elements | Where-Object { $_.Current.Name -like "*$imageName*" }).Count -gt 0) { return $true }
        }
        return $false
    } 'Windows Photos did not show the transferred test image.'
    Write-Host "Windows Photos opened the test image: $imageName"
} finally {
    try {
        if ($null -ne $imageName) {
            foreach ($root in @(Get-PhotosWindows)) {
                if ($root.Current.Name -like "*$imageName*" -and $root.Current.NativeWindowHandle -ne 0) {
                    $imageHandle = [IntPtr] $root.Current.NativeWindowHandle
                    [void] [PhotosTestWindow]::PostMessage($imageHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                    Wait-Until { -not [PhotosTestWindow]::IsWindow($imageHandle) } 'The test image window did not close normally.' 10
                }
            }
        }
        if ($windowHandle -ne [IntPtr]::Zero -and [PhotosTestWindow]::IsWindow($windowHandle)) {
            [void] [PhotosTestWindow]::PostMessage($windowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            Wait-Until { -not [PhotosTestWindow]::IsWindow($windowHandle) } 'The test Photos window did not close normally.' 10
        }
    } finally {
        if ($null -ne $temporaryMediaPath) { [IO.File]::Delete($temporaryMediaPath) }
    }
}