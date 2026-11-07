$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ExplorerLinkInput {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint index, StringBuilder text, int length, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr window, IntPtr menu, uint index, out Rect rect);
}
'@
function Wait-Dispatcher([int] $milliseconds) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    $timer.add_Tick({ $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-explorer-link-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source.txt'
$destination = Join-Path $root 'destination'
[void] [IO.Directory]::CreateDirectory($destination)
[IO.File]::WriteAllText($source, 'source')
$original = [System.Windows.Clipboard]::GetDataObject()
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$shell = New-Object -ComObject Shell.Application
$explorer = $null
$cursor = [ExplorerLinkInput+Point]::new()
[void] [ExplorerLinkInput]::GetCursorPos([ref] $cursor)
try {
    $shell.Open($destination)
    for ($attempt = 0; $attempt -lt 100 -and $null -eq $explorer; $attempt++) {
        foreach ($candidate in @($shell.Windows())) {
            try { if ($candidate.Document.Folder.Self.Path -ceq $destination) { $explorer = $candidate; break } } catch { }
        }
        if ($null -eq $explorer) {
            Wait-Dispatcher 100
        }
    }
    if ($null -eq $explorer) { throw 'Explorer did not open the test directory.' }
    $window = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $explorer.HWND)
    $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $content = @($elements | Where-Object { $_.Current.AutomationId -eq 'listview' })[0]
    if ($null -eq $content) { throw 'Explorer content view not found.' }
    $bounds = $content.Current.BoundingRectangle
    foreach ($mode in @('copy', 'link')) {
        if ($mode -eq 'copy') {
            $null = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('CopyToClipboard', $flags).Invoke($null, [object[]] @([string[]] @($source), [IntPtr]::Zero))
        } else {
            $null = $assembly.GetType('SUTWinExplorer.ShellDragDrop', $true).GetMethod('PrepareLinkToClipboard', $flags).Invoke($null, [object[]] @([string[]] @($source), [IntPtr]::Zero))
        }
        [void] [ExplorerLinkInput]::SetForegroundWindow([IntPtr] $explorer.HWND)
        [void] [ExplorerLinkInput]::SetCursorPos([int] ($bounds.X + $bounds.Width / 2), [int] ($bounds.Y + $bounds.Height / 2))
        [ExplorerLinkInput]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
        [ExplorerLinkInput]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
        Wait-Dispatcher 1000
        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        $desktopElements = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        $found = $false
        foreach ($element in $desktopElements) {
            if ($element.Current.ClassName -eq '#32768') {
                $menuWindow = [IntPtr] $element.Current.NativeWindowHandle
                $menu = [ExplorerLinkInput]::SendMessage($menuWindow, 0x01E1, [IntPtr]::Zero, [IntPtr]::Zero)
                for ($index = 0; $index -lt [ExplorerLinkInput]::GetMenuItemCount($menu); $index++) {
                    $text = [Text.StringBuilder]::new(512)
                    [void] [ExplorerLinkInput]::GetMenuString($menu, $index, $text, $text.Capacity, 0x400)
                    if ($text.ToString().Replace('&', '') -notin @('Verknüpfung einfügen', 'Paste shortcut')) { continue }
                    $found = $true
                    if (([ExplorerLinkInput]::GetMenuState($menu, $index, 0x400) -band 3) -ne 0) { throw "Explorer Paste shortcut is disabled for $mode." }
                    if ($mode -eq 'link') {
                        $rect = [ExplorerLinkInput+Rect]::new()
                        if (-not [ExplorerLinkInput]::GetMenuItemRect($menuWindow, $menu, $index, [ref] $rect)) { throw 'Could not locate Explorer Paste shortcut.' }
                        [void] [ExplorerLinkInput]::SetCursorPos([int] (($rect.Left + $rect.Right) / 2), [int] (($rect.Top + $rect.Bottom) / 2))
                        [ExplorerLinkInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
                        [ExplorerLinkInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
                    }
                    break
                }
            }
        }
        if (-not $found) { throw "Explorer Paste shortcut was not found for $mode (supported UI languages: German, English)." }
        if ($mode -eq 'copy') {
            [ExplorerLinkInput]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
            [ExplorerLinkInput]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
        }
    }
    for ($attempt = 0; $attempt -lt 50 -and @([IO.Directory]::GetFiles($destination, '*.lnk')).Count -eq 0; $attempt++) { Wait-Dispatcher 100 }
    $shortcuts = @([IO.Directory]::GetFiles($destination, '*.lnk'))
    $resolve = $assembly.GetType('SUTWinExplorer.ShellFileOperations', $true).GetMethod('GetLinkTarget')
    if ($shortcuts.Count -ne 1 -or $resolve.Invoke($null, [object[]] @($shortcuts[0])) -cne $source -or -not [IO.File]::Exists($source)) { throw 'Explorer did not create the expected shortcut.' }
} finally {
    if ($null -ne $explorer) { $explorer.Quit() }
    [void] [ExplorerLinkInput]::SetCursorPos($cursor.X, $cursor.Y)
    for ($attempt = 0; ; $attempt++) {
        try {
            if ($null -eq $original) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($original, $true) }
            break
        } catch {
            if ($attempt -ge 19 -or $_.Exception.GetBaseException() -isnot [Runtime.InteropServices.ExternalException]) { throw }
            Wait-Dispatcher 100
        }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
'Explorer clipboard Link test passed.'