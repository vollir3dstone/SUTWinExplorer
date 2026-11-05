$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupWindowProbe
{
    public sealed class WindowInfo
    {
        public IntPtr Handle;
        public string ClassName;
        public string Title;
        public bool IsToolPopup;
    }
    private delegate bool EnumCallback(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    public static WindowInfo[] VisibleWindows(uint processId)
    {
        var windows = new List<WindowInfo>();
        EnumWindows((window, state) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId && IsWindowVisible(window)) {
                var title = new StringBuilder(512);
                var type = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                GetClassName(window, type, type.Capacity);
                windows.Add(new WindowInfo {
                    Handle = window, ClassName = type.ToString(), Title = title.ToString(),
                    IsToolPopup = (GetWindowLong(window, -16) & unchecked((int)0x80000000)) != 0 &&
                        (GetWindowLong(window, -20) & 0x80) != 0
                });
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
    $toolTipCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ToolTip)
    $applicationWindows = @(foreach ($window in $windows) {
        if ($window.IsToolPopup -and -not $window.Title) {
            try {
                $element = [System.Windows.Automation.AutomationElement]::FromHandle($window.Handle)
                if ($null -ne $element -and $null -ne $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $toolTipCondition)) {
                    Write-Host 'Ignoring visible tooltip popup.'
                    continue
                }
            } catch [System.Windows.Automation.ElementNotAvailableException] {
                continue
            }
        }
        $window
    })
    $applicationWindows | ForEach-Object { "Visible window: $($_.ClassName) | $($_.Title)" }
    if ($applicationWindows.Count -ne 1 -or $applicationWindows[0].Title -notmatch '^KIS Explorer') {
        throw "Expected one visible application window, found $($applicationWindows.Count)."
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