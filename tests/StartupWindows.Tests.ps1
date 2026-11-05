$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupWindowProbe
{
    private delegate bool EnumCallback(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    public static string[] VisibleWindows(uint processId)
    {
        var windows = new List<string>();
        EnumWindows((window, state) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId && IsWindowVisible(window)) {
                var title = new StringBuilder(512);
                var type = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                GetClassName(window, type, type.Capacity);
                windows.Add(type + " | " + title);
            }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
'@
$executable = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/KIS Explorer.exe'))
if (@(Get-Process -Name 'KIS Explorer' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable }).Count) {
    throw 'The Debug application is already running.'
}
$process = Start-Process -FilePath $executable -PassThru
try {
    if (-not $process.WaitForInputIdle(15000)) { throw 'The application did not become ready.' }
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(3)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    $process.Refresh()
    if ($process.HasExited) { throw "The application exited during startup with code $($process.ExitCode)." }
    $windows = @([StartupWindowProbe]::VisibleWindows([uint32] $process.Id))
    $windows | ForEach-Object { "Visible window: $_" }
    if ($windows.Count -ne 1 -or $windows[0] -notmatch 'KIS Explorer') {
        throw "Expected one visible application window, found $($windows.Count)."
    }
    'Startup window test passed.'
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); $process.WaitForExit() }
    }
    $process.Dispose()
}