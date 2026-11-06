$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ModernPlayerTestWindow
{
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
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

$appId = 'Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic'
$startApps = @(Get-StartApps | Where-Object { $_.AppID -eq $appId })
if ($startApps.Count -ne 1) { throw 'The Windows Media Player package is not installed or registered.' }
$package = Get-AppxPackage -Name Microsoft.ZuneMusic
if ($null -eq $package) { throw 'The Windows Media Player package was not found.' }
if (@(Get-Process -Name 'Microsoft.Media.Player' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Windows Media Player is already running. Close it before running this test.'
}

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$handlers = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @('test.wav')) | Where-Object { $_.Name -eq $startApps[0].Name })
if ($handlers.Count -ne 1) { throw 'Expected exactly one registered Windows Media Player WAV handler.' }
$selectedApp = $handlers[0].PSObject.BaseObject
$process = $null
$windowHandle = [IntPtr]::Zero
try {
    Start-Process "shell:AppsFolder\$appId"
    Wait-Until {
        $players = @(Get-Process -Name 'Microsoft.Media.Player' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $package.InstallLocation 'Microsoft.Media.Player.exe') })
        if ($players.Count -ne 1) { return $false }
        $script:process = $players[0]
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $script:process.Id)
        $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        $matches = @($roots | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $null -ne $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition) })
        if ($matches.Count -ne 1) { return $false }
        $script:windowHandle = [IntPtr] $matches[0].Current.NativeWindowHandle
        return [ModernPlayerTestWindow]::IsWindowEnabled($script:windowHandle)
    } 'The test player did not open exactly one enabled window.' 30

    $directory = Join-Path ([IO.Path]::GetTempPath()) 'KIS-File-Paste-Test'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $trackName = 'KIS-Paste-' + [guid]::NewGuid().ToString('N')
    $filePath = Join-Path $directory ($trackName + '.wav')
    $sampleRate = 44100
    $sampleCount = $sampleRate * 10
    $writer = [IO.BinaryWriter]::new([IO.File]::Create($filePath))
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32] (36 + $sampleCount * 2))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32] 16)
        $writer.Write([uint16] 1)
        $writer.Write([uint16] 1)
        $writer.Write([uint32] $sampleRate)
        $writer.Write([uint32] ($sampleRate * 2))
        $writer.Write([uint16] 2)
        $writer.Write([uint16] 16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32] ($sampleCount * 2))
        $writer.Write([byte[]]::new($sampleCount * 2))
    } finally { $writer.Dispose() }

    $readyAt = [DateTime]::UtcNow.AddSeconds(5)
    Wait-Until { [DateTime]::UtcNow -ge $readyAt } 'The player startup wait did not complete.'
    $process.Refresh()
    if ($process.HasExited -or -not [ModernPlayerTestWindow]::IsWindowEnabled($windowHandle)) { throw 'The test player is no longer ready.' }
    Wait-Until {
        $apps = @($accessor.GetMethod('GetRunningApps').Invoke($null, @([string] $filePath)) | Where-Object { $_.App.Id -eq $selectedApp.Id })
        $script:matchingWindows = @($apps.Windows | Where-Object { $_.Handle -eq $script:windowHandle })
        return $script:matchingWindows.Count -eq 1
    } 'The running Windows Media Player window was not found among the WAV applications.'
    $window = $script:matchingWindows[0].PSObject.BaseObject
    if (-not [ModernPlayerTestWindow]::IsWindowEnabled($window.Handle)) { throw 'The player window is no longer ready.' }
    $task = $accessor.GetMethod('OpenInRunningAppResourcefully').Invoke($null, [object[]] @($window, [string[]] @($filePath), $selectedApp))
    Wait-Until { $task.IsCompleted } 'The Resourceful operation did not complete.'
    $result = $task.GetAwaiter().GetResult()
    if ($result.Error) { throw "The Resourceful operation failed: $($result.Error)" }
    Wait-Until {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle)
        $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
        return @($elements | Where-Object { $_.Current.Name -like "*$trackName*" }).Count -gt 0
    } 'Windows Media Player did not show the transferred test track.'
    Write-Host "Windows Media Player opened the test track: $trackName"
} finally {
    if ($windowHandle -ne [IntPtr]::Zero) {
        [void] [ModernPlayerTestWindow]::PostMessage($windowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    if ($null -ne $process) {
        try {
            try { Wait-Until { $process.Refresh(); $process.HasExited } 'The test player did not close normally.' 10 }
            catch { $process.Refresh(); if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } }
        } finally { $process.Dispose() }
    }
}