$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ItemMenuProbe
{
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint position, System.Text.StringBuilder text, int length, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct MenuItemInfo
    {
        public uint Size, Mask, Type, State, Id;
        public IntPtr SubMenu, CheckedBitmap, UncheckedBitmap, ItemData, Text;
        public uint TextLength;
        public IntPtr Bitmap;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BitmapInfo
    {
        public int Type, Width, Height, WidthBytes;
        public ushort Planes, BitsPixel;
        public IntPtr Bits;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMenuItemInfo(IntPtr menu, uint item, bool byPosition, ref MenuItemInfo info);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int GetObject(IntPtr handle, int size, out BitmapInfo info);
}
public sealed class SequenceMenuProbe : IDisposable
{
    private delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    private readonly uint thread = GetCurrentThreadId();
    private readonly IntPtr owner;
    private readonly string mode;
    private readonly Point origin;
    private readonly System.Threading.Timer timer;
    private int phase, busy, ticks;
    public bool Seen, IsBase, SecondSeen, SecondIsBase;
    public string ClickWindow;
    public static Func<int, int, (T, bool)> Target<T>(T target) => (x, y) => (target, false);
    public static Func<int, int, (T, bool)> Background<T>() => (x, y) => (default(T), true);
    public SequenceMenuProbe(IntPtr owner, string mode)
    {
        this.owner = owner; this.mode = mode;
        GetCursorPos(out origin);
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }
    private void Check(object unused)
    {
        if (System.Threading.Interlocked.Exchange(ref busy, 1) != 0) return;
        try
        {
            EnumThreadWindows(thread, (window, parameter) =>
            {
                var name = new System.Text.StringBuilder(32);
                GetClassName(window, name, name.Capacity);
                if (name.ToString() != "#32768") return true;
                var menu = SendMessage(window, 0x01E1, IntPtr.Zero, IntPtr.Zero);
                if (!Seen) { Seen = true; IsBase = GetMenuItemID(menu, 0) == 0x8000; }
                if (mode == "move-right" && phase == 0)
                {
                    phase = 1;
                    mouse_event(1, GetSystemMetrics(36) * 4, 0, 0, UIntPtr.Zero);
                }
                else if (mode == "move-right" && phase == 1)
                {
                    phase = 2;
                    SetCursorPos(origin.X + 2, origin.Y + 2);
                }
                else if (mode == "move-right" && phase == 2)
                {
                    phase = 3;
                    GetCursorPos(out var clickPoint);
                    var clickClass = new System.Text.StringBuilder(32);
                    GetClassName(WindowFromPoint(clickPoint), clickClass, clickClass.Capacity);
                    ClickWindow = clickClass.ToString();
                    mouse_event(8, 0, 0, 0, UIntPtr.Zero);
                    mouse_event(16, 0, 0, 0, UIntPtr.Zero);
                }
                else if (mode == "move-right")
                {
                    SecondSeen = true;
                    SecondIsBase = GetMenuItemID(menu, 0) == 0x8000;
                    PostMessage(owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
                }
                else if (mode == "move" && phase++ == 0)
                    mouse_event(1, GetSystemMetrics(36) * 4, 0, 0, UIntPtr.Zero);
                else if (mode == "command" && phase < 3)
                {
                    PostMessage(window, 0x0100, (IntPtr)(phase < 2 ? 0x28 : 0x0D), IntPtr.Zero);
                    phase++;
                }
                else if (mode != "command" || phase++ > 5)
                    PostMessage(owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
                return false;
            }, IntPtr.Zero);
            if (++ticks > 120) PostMessage(owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
        }
        finally { System.Threading.Volatile.Write(ref busy, 0); }
    }
    public void Dispose() => timer.Dispose();
}
'@
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$resources = [System.Windows.Application]::LoadComponent([Uri]::new('/SUTWinExplorer;component/Styles/InputControlStyles.xaml', [UriKind]::Relative))
$application.Resources.MergedDictionaries.Add($resources)
$buttonStyle = [System.Windows.Style]::new([System.Windows.Controls.Button], $resources[[System.Windows.Controls.Button]])
$buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::HeightProperty, [double] 24))
$buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MinHeightProperty, [double] 24))
$buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center))
$buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::FocusVisualStyleProperty, $null))
$application.Resources['ContentPaneButtonStyle'] = $buttonStyle
foreach ($key in @('ItemHoverBrush', 'ItemSelectionBrush', 'ItemSelectionBorderBrush', 'ItemRequestBrush')) {
    $application.Resources[$key] = [System.Windows.Media.Brushes]::LightGray
}
$application.Resources['ViewFrameBrush'] = [System.Windows.Media.Brushes]::LightGray
$application.Resources['ViewFrameThickness'] = [System.Windows.Thickness]::new(1)
$application.Resources['ShellIconTemplate'] = [System.Windows.DataTemplate]::new()
$previousContext = [System.Threading.SynchronizationContext]::Current
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
function Wait-Until([scriptblock] $condition, [string] $description) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $state = @{ Ready = $false }
    $timer.add_Tick({
        if (& $condition) { $state.Ready = $true; $frame.Continue = $false }
        elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) { throw "Timed out: $description." }
}
function Invoke-Button($button) {
    if (-not $button.IsEnabled) { throw "$($button.Name) is disabled." }
    $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
}
function Show-SequenceMenu($controller, $row, [IntPtr] $owner, [string] $mode, [bool] $expectedBase) {
    $probe = [SequenceMenuProbe]::new($owner, $mode)
    try { $null = $controller.GetType().GetMethod('Show', $flags).Invoke($controller, [object[]] @($row, $owner, $true)) }
    finally { $probe.Dispose() }
    if (-not $probe.Seen -or $probe.IsBase -ne $expectedBase) { throw "Unexpected menu for $mode`: seen=$($probe.Seen), base=$($probe.IsBase), expected=$expectedBase." }
    if ($mode -eq 'move-right' -and (-not $probe.SecondSeen -or -not $probe.SecondIsBase)) { throw "The right-click after movement did not open a new Base Menu: second=$($probe.SecondSeen), base=$($probe.SecondIsBase), click window=$($probe.ClickWindow)." }
}
function Assert-ItemMenu($actions, [string[]] $paths, [bool] $background, [IntPtr] $owner) {
    $factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
    $menu = $factory.GetMethod('GetBaseMenuForContext', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $actions, $background))
    $bitmaps = @()
    try {
        $handle = $menu.GetType().GetField('_menu', $flags).GetValue($menu)
        $commandIds = @(for ($index = 0; $index -lt [ItemMenuProbe]::GetMenuItemCount($handle); $index++) { [ItemMenuProbe]::GetMenuItemID($handle, $index) })
        $actionIds = @($actions | ForEach-Object { $_.Id })
        $nameClipboardCopyId = [uint32] (0x8000 + [Array]::IndexOf($actionIds, 'NameClipboardCopy'))
        $itemClipboardCopyId = [uint32] (0x8000 + [Array]::IndexOf($actionIds, 'ItemClipboardCopy'))
        $pathClipboardCopyId = [uint32] (0x8000 + [Array]::IndexOf($actionIds, 'PathClipboardCopy'))
        $itemClipboardPasteId = [uint32] (0x8000 + [Array]::IndexOf($actionIds, 'ItemClipboardPaste'))
        $getPosition = [Array]::IndexOf($commandIds, $itemClipboardCopyId)
        $pastePosition = [Array]::IndexOf($commandIds, $itemClipboardPasteId)
        if ($getPosition -lt 2 -or $commandIds[$getPosition - 2] -ne $nameClipboardCopyId -or $commandIds[$getPosition - 1] -ne $pathClipboardCopyId -or $pastePosition -ne $getPosition + 2 -or
            ([ItemMenuProbe]::GetMenuState($handle, [uint32] ($getPosition + 1), 0x400) -band 0x800) -eq 0) {
            throw 'The native Base Menu does not group clipboard copy actions before Item clipboard paste.'
        }
        foreach ($entry in @(@(($getPosition - 2), 'Name clipboard copy'), @(($getPosition - 1), 'Path clipboard copy'), @($getPosition, 'Item clipboard copy'), @($pastePosition, 'Item clipboard paste'))) {
            $label = [System.Text.StringBuilder]::new(128)
            $null = [ItemMenuProbe]::GetMenuString($handle, [uint32] $entry[0], $label, $label.Capacity, 0x400)
            if ($label.ToString() -cne $entry[1]) { throw "Unexpected native menu label: $label." }
        }
        foreach ($action in @($actions | Where-Object { $_.IsTransfer -and $_.IsEnabled })) {
            $position = [Array]::IndexOf($commandIds, [uint32] (0x8000 + [Array]::IndexOf($actionIds, $action.Id)))
            $expected = switch -Regex ($action.Id) { '^(.+)MarkItem$' { "$($Matches[1]) mark item" } '^(.+)Execute$' { "$($Matches[1]) execute" } '^(.+)Abort$' { "$($Matches[1]) abort" } default { throw "Unexpected transfer ID: $($action.Id)." } }
            $label = [System.Text.StringBuilder]::new(128)
            if ($position -lt 0) { throw "Missing transfer action: $($action.Id)." }
            $null = [ItemMenuProbe]::GetMenuString($handle, [uint32] $position, $label, $label.Capacity, 0x400)
            if ($label.ToString() -cne $expected) { throw "Unexpected transfer menu label: $label." }
        }
        foreach ($action in @($actions | Where-Object { $_.Id -in @('NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'ItemClipboardPaste', 'Delete') -or ($_.IsTransfer -and $_.IsEnabled) })) {
            $command = [uint32] (0x8000 + [Array]::IndexOf($actionIds, $action.Id))
            $info = [ItemMenuProbe+MenuItemInfo]::new()
            $info.Size = [uint32] [Runtime.InteropServices.Marshal]::SizeOf([type] [ItemMenuProbe+MenuItemInfo])
            $info.Mask = 0x80
            if (-not [ItemMenuProbe]::GetMenuItemInfo($handle, $command, $false, [ref] $info) -or $info.Bitmap -eq [IntPtr]::Zero) { throw "Missing menu icon: $($action.Id)." }
            $bitmaps += $info.Bitmap
            $bitmap = [ItemMenuProbe+BitmapInfo]::new()
            if ([ItemMenuProbe]::GetObject($info.Bitmap, [Runtime.InteropServices.Marshal]::SizeOf([type] [ItemMenuProbe+BitmapInfo]), [ref] $bitmap) -eq 0 -or $bitmap.Bits -eq [IntPtr]::Zero -or $bitmap.BitsPixel -ne 32) { throw "Invalid menu icon: $($action.Id)." }
            $pixels = [byte[]]::new($bitmap.WidthBytes * $bitmap.Height)
            [Runtime.InteropServices.Marshal]::Copy($bitmap.Bits, $pixels, 0, $pixels.Length)
            $visible = $false
            for ($offset = 3; $offset -lt $pixels.Length; $offset += 4) { if ($pixels[$offset] -ne 0) { $visible = $true; break } }
            if (-not $visible) { throw "Blank menu icon: $($action.Id)." }
        }
    } finally { ([IDisposable] $menu).Dispose() }
    foreach ($bitmap in $bitmaps) {
        $info = [ItemMenuProbe+BitmapInfo]::new()
        if ([ItemMenuProbe]::GetObject($bitmap, [Runtime.InteropServices.Marshal]::SizeOf([type] [ItemMenuProbe+BitmapInfo]), [ref] $info) -ne 0) { throw 'Menu icon bitmap was not released.' }
    }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('SutItemActions-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$destination = Join-Path $root 'destination'
[IO.Directory]::CreateDirectory($source) | Out-Null
[IO.Directory]::CreateDirectory($destination) | Out-Null
$file = [string] (Join-Path $source 'test.txt')
$folder = [string] (Join-Path $source 'test-folder')
[IO.File]::WriteAllText($file, 'item test')
[IO.Directory]::CreateDirectory($folder) | Out-Null
[IO.File]::WriteAllText((Join-Path $folder 'nested.txt'), 'nested')
$original = [System.Windows.Clipboard]::GetDataObject()
$copy = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
$link = $assembly.GetType('SUTWinExplorer.LinkWorkflowState', $true).GetProperty('Shared').GetValue($null)
$move = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
$window = [System.Windows.Window]::new()
$window.ShowInTaskbar = $false
$window.Left = -20000
$window.Top = -20000
$window.Width = 1000
$window.Height = 500
try {
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = $view.GetType().GetMethod('Initialize', $flags).Invoke($view, [object[]] @([bool] $false))
    $null = $view.GetType().GetMethod('SetCurrentPath', $flags).Invoke($view, [object[]] @([string] $source))
    $window.Content = $view
    $window.Show()
    $null = $view.GetType().GetMethod('RevealInsertedItems', $flags).Invoke($view, [object[]] @(,[string[]] @($file, $folder)))
    Wait-Until { @($view.FindName('FileList').SelectedItems).Count -eq 2 -and $view.FindName('ItemClipboardCopyButton').IsEnabled } 'selection'
    $itemClipboardCopy = $view.FindName('ItemClipboardCopyButton')
    $itemClipboardPaste = $view.FindName('ItemClipboardPasteButton')
    $nameClipboardCopy = $view.FindName('NameClipboardCopyButton')
    $pathClipboardCopy = $view.FindName('PathClipboardCopyButton')
    $linkMarkItem = $view.FindName('LinkMarkItemButton')
    $copyMarkItem = $view.FindName('CopyMarkItemButton')
    $moveMarkItem = $view.FindName('MoveMarkItemButton')
    $linkAbort = $view.FindName('LinkAbortButton')
    if ($nameClipboardCopy.Parent -ne $pathClipboardCopy.Parent -or $pathClipboardCopy.Parent -ne $itemClipboardCopy.Parent -or
        $nameClipboardCopy.Parent.Children.IndexOf($pathClipboardCopy) -ne $nameClipboardCopy.Parent.Children.IndexOf($nameClipboardCopy) + 1 -or
        $pathClipboardCopy.Parent.Children.IndexOf($itemClipboardCopy) -ne $pathClipboardCopy.Parent.Children.IndexOf($pathClipboardCopy) + 1) { throw 'Clipboard copy buttons are not in the same button group.' }
    $cornerRadius = $assembly.GetType('SUTWinExplorer.InputChrome', $true).GetMethod('GetCornerRadius')
    if ($cornerRadius.Invoke($null, @($nameClipboardCopy)) -ne [System.Windows.CornerRadius]::new(3, 0, 0, 3) -or
        $cornerRadius.Invoke($null, @($pathClipboardCopy)) -ne [System.Windows.CornerRadius]::new(0) -or
        $cornerRadius.Invoke($null, @($itemClipboardCopy)) -ne [System.Windows.CornerRadius]::new(0, 3, 3, 0) -or
        $pathClipboardCopy.BorderThickness.Left -ne 0 -or $itemClipboardCopy.BorderThickness.Left -ne 0) { throw 'Clipboard copy buttons do not share the group outline.' }
    if ($linkMarkItem.Parent -ne $copyMarkItem.Parent -or $copyMarkItem.Parent -ne $moveMarkItem.Parent -or
        $linkMarkItem.Parent.Children.IndexOf($copyMarkItem) -ne $linkMarkItem.Parent.Children.IndexOf($linkMarkItem) + 1 -or
        $copyMarkItem.Parent.Children.IndexOf($moveMarkItem) -ne $copyMarkItem.Parent.Children.IndexOf($copyMarkItem) + 1 -or
        $cornerRadius.Invoke($null, @($linkMarkItem)) -ne [System.Windows.CornerRadius]::new(3, 0, 0, 3) -or
        $cornerRadius.Invoke($null, @($copyMarkItem)) -ne [System.Windows.CornerRadius]::new(0) -or
        $cornerRadius.Invoke($null, @($moveMarkItem)) -ne [System.Windows.CornerRadius]::new(0, 3, 3, 0)) { throw 'Transfer mark item buttons are not in one group.' }
    foreach ($name in @('Name', 'Path', 'Item')) {
        $button = $view.FindName("${name}ClipboardCopyButton")
        $icon = $button.Content.Children[1]
        if ([System.Windows.Automation.AutomationProperties]::GetName($button) -cne "$name clipboard copy" -or $button.ToolTip -cne "$name clipboard copy" -or
            $icon.Template -ne $view.FindResource('ClipboardCopyIconTemplate')) { throw "$name clipboard copy has an incorrect label or icon." }
        if ($button.Margin -ne [System.Windows.Thickness]::new(0) -or $null -eq $button.Template.FindName('outline', $button)) { throw "$name clipboard copy has an unexpected margin or button style." }
    }
    if ([System.Windows.Automation.AutomationProperties]::GetName($itemClipboardPaste) -cne 'Item clipboard paste' -or $itemClipboardPaste.ToolTip -cne 'Item clipboard paste' -or
        $itemClipboardPaste.Content.Children[1].Template -ne $view.Resources['ClipboardPasteIconTemplate']) { throw 'Item clipboard paste has an incorrect label or icon.' }
    foreach ($name in @('Link', 'Copy', 'Move')) {
        foreach ($action in @(@('MarkItem', 'mark item'), @('Execute', 'execute'))) {
            $button = $view.FindName("$name$($action[0])Button")
            if ([System.Windows.Automation.AutomationProperties]::GetName($button) -cne "$name $($action[1])" -or $button.ToolTip -cne "$name $($action[1])") { throw "Incorrect transfer button label: $name $($action[1])." }
        }
    }
    $namePosition = $nameClipboardCopy.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    $pathPosition = $pathClipboardCopy.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    $itemPosition = $itemClipboardCopy.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    $linkPosition = $linkMarkItem.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    $copyPosition = $copyMarkItem.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    $movePosition = $moveMarkItem.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
    if ([Math]::Abs($namePosition.X + $nameClipboardCopy.ActualWidth - $pathPosition.X) -gt 0.01 -or
        [Math]::Abs($pathPosition.X + $pathClipboardCopy.ActualWidth - $itemPosition.X) -gt 0.01 -or
        $itemPosition.X + $itemClipboardCopy.ActualWidth -gt $linkPosition.X) { throw 'Clipboard copy buttons are not contiguous before Link mark item.' }
    if ([Math]::Abs($linkPosition.X + $linkMarkItem.ActualWidth - $copyPosition.X) -gt 0.01 -or
        [Math]::Abs($copyPosition.X + $copyMarkItem.ActualWidth - $movePosition.X) -gt 0.01) { throw 'Transfer mark item buttons are not contiguous.' }
    if ($itemClipboardPaste.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y -ge $linkAbort.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y) { throw 'Item clipboard paste is not above the Link group.' }
    $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $actions = $view.GetType().GetMethod('CreateContextMenuActions', $flags).Invoke($view, @())
    Assert-ItemMenu $actions ([string[]] @($file, $folder)) $false $owner
    $controller = $view.GetType().GetField('_contextMenu', $flags).GetValue($view)
    $reset = $controller.GetType().GetMethod('Reset', $flags)
    $baseCommands = $controller.GetType().GetField('_baseCommands', $flags)
    $skipNext = $controller.GetType().GetField('_skipNextMenu', $flags)
    $hitTest = $controller.GetType().GetField('_hitTest', $flags)
    $originalHitTest = $hitTest.GetValue($controller)
    $row = $view.FindName('FileList').SelectedItems[0]
    $otherRow = $view.FindName('FileList').SelectedItems[1]
    $originalCursor = [SequenceMenuProbe+Point]::new()
    $null = [SequenceMenuProbe]::GetCursorPos([ref] $originalCursor)
    $originX = [int] ([SequenceMenuProbe]::GetSystemMetrics(0) / 2)
    $originY = [int] ([SequenceMenuProbe]::GetSystemMetrics(1) / 2)
    try {
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        if ($null -eq $baseCommands.GetValue($controller)) { throw 'Closing the Base Menu did not retain the sequence.' }
        [SequenceMenuProbe]::mouse_event(1, 1, 0, 0, [UIntPtr]::Zero)
        Wait-Until { $null -ne $baseCommands.GetValue($controller) } 'movement inside the double-click area'
        [SequenceMenuProbe]::mouse_event(1, ([SequenceMenuProbe]::GetSystemMetrics(36) * 4), 0, 0, [UIntPtr]::Zero)
        Wait-Until { $null -eq $baseCommands.GetValue($controller) } 'movement outside the double-click area'
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'move' $true
        if ($null -ne $baseCommands.GetValue($controller)) { throw 'Movement while the Base Menu was open did not reset the sequence.' }
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        Show-SequenceMenu $controller $row $owner 'move' $false
        if ($null -ne $baseCommands.GetValue($controller)) { throw 'Movement while the Content Menu was open did not reset the sequence.' }
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        [System.Windows.Clipboard]::SetText('sequence action sentinel')
        Show-SequenceMenu $controller $row $owner 'command' $true
        if ([System.Windows.Clipboard]::GetText() -ceq 'sequence action sentinel' -or $null -ne $baseCommands.GetValue($controller)) { throw 'The selected menu command did not execute and reset the sequence.' }
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        Show-SequenceMenu $controller $row $owner 'dismiss' $false
        [SequenceMenuProbe]::mouse_event(1, ([SequenceMenuProbe]::GetSystemMetrics(36) * 4), 0, 0, [UIntPtr]::Zero)
        Wait-Until { -not $skipNext.GetValue($controller) } 'movement after the Content Menu'
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        Show-SequenceMenu $controller $row $owner 'dismiss' $false
        $null = $controller.GetType().GetMethod('Show', $flags).Invoke($controller, [object[]] @($row, $owner, $true))
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        $null = $reset.Invoke($controller, @())
        $fakeHitTest = [SequenceMenuProbe].GetMethod('Target').MakeGenericMethod($row.GetType()).Invoke($null, @($row))
        $hitTest.SetValue($controller, $fakeHitTest)
        $window.Left = 100
        $window.Top = 100
        $null = $window.Activate()
        $originX = 150
        $originY = 150
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'move-right' $true
        if ($null -eq $baseCommands.GetValue($controller)) { throw 'The replacement Base Menu did not start a new sequence.' }
        $null = $reset.Invoke($controller, @())
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'dismiss' $true
        Show-SequenceMenu $controller $row $owner 'move-right' $false
        if ($null -eq $baseCommands.GetValue($controller)) { throw 'The replacement Base Menu after the Content Menu did not start a new sequence.' }
        $null = $reset.Invoke($controller, @())
        $hitTest.SetValue($controller, [SequenceMenuProbe].GetMethod('Target').MakeGenericMethod($row.GetType()).Invoke($null, @($otherRow)))
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $row $owner 'move-right' $true
        $path = $controller.GetType().GetField('_path', $flags).GetValue($controller).DynamicInvoke($otherRow)
        if ($controller.GetType().GetField('_basePath', $flags).GetValue($controller) -ne $path) { throw 'The replacement Base Menu did not target the other item.' }
        $null = $reset.Invoke($controller, @())
        $hitTest.SetValue($controller, [SequenceMenuProbe].GetMethod('Background').MakeGenericMethod($row.GetType()).Invoke($null, @()))
        $null = [SequenceMenuProbe]::SetCursorPos($originX, $originY)
        Show-SequenceMenu $controller $otherRow $owner 'move-right' $true
        if (-not $controller.GetType().GetField('_baseIsBackground', $flags).GetValue($controller)) { throw 'The replacement Base Menu did not target the background.' }
        $window.Content = $null
        Wait-Until { $null -eq $baseCommands.GetValue($controller) } 'sequence cleanup on ContentView unload'
        $window.Content = $view
        $null = $view.GetType().GetMethod('RevealInsertedItems', $flags).Invoke($view, [object[]] @(,[string[]] @($file, $folder)))
        Wait-Until { @($view.FindName('FileList').SelectedItems).Count -eq 2 -and $view.FindName('CopyMarkItemButton').IsEnabled } 'selection after menu sequence checks'
    } finally {
        $hitTest.SetValue($controller, $originalHitTest)
        $null = $reset.Invoke($controller, @())
        $window.Left = -20000
        $window.Top = -20000
        $null = [SequenceMenuProbe]::SetCursorPos($originalCursor.X, $originalCursor.Y)
    }
    [System.Windows.Clipboard]::SetText('copy transfer sentinel')
    Invoke-Button ($view.FindName('CopyMarkItemButton'))
    if (-not $copy.IsPrepared -or [System.Windows.Clipboard]::GetText() -cne 'copy transfer sentinel') { throw "Copy mark item state=$($copy.IsPrepared), clipboard=$([System.Windows.Clipboard]::GetText())." }
    Invoke-Button $itemClipboardCopy
    Wait-Until { [System.Windows.Clipboard]::ContainsFileDropList() -and $itemClipboardPaste.IsEnabled } 'Item clipboard copy and paste availability'
    $paths = @([System.Windows.Clipboard]::GetFileDropList())
    if ($paths.Count -ne 2 -or $file -notin $paths -or $folder -notin $paths -or -not $copy.IsPrepared) { throw 'Item clipboard copy did not copy the selection independently of the transfer.' }
    $actions = $view.GetType().GetMethod('CreateContextMenuActions', $flags).Invoke($view, @())
    if (-not (@($actions | Where-Object { $_.Id -eq 'ItemClipboardCopy' })[0].IsEnabled) -or -not (@($actions | Where-Object { $_.Id -eq 'ItemClipboardPaste' })[0].IsEnabled)) { throw 'Item Base Menu actions are not enabled.' }
    Assert-ItemMenu $actions ([string[]] @($file, $folder)) $false $owner
    $null = $view.GetType().GetMethod('SetCurrentPath', $flags).Invoke($view, [object[]] @([string] $destination))
    Wait-Until { $itemClipboardPaste.IsEnabled } 'Item clipboard paste destination'
    Invoke-Button $itemClipboardPaste
    Wait-Until { [IO.File]::Exists((Join-Path $destination 'test.txt')) -and [IO.File]::Exists((Join-Path $destination 'test-folder/nested.txt')) } 'Item clipboard paste completion'
    if (-not $copy.IsPrepared -or @($copy.PreparedPaths).Count -ne 2) { throw 'Item clipboard paste changed the prepared Copy.' }
    [System.Windows.Clipboard]::SetText('not files')
    Wait-Until { -not $itemClipboardPaste.IsEnabled } 'Item clipboard paste disabled for text clipboard'
    if (-not $copy.IsPrepared) { throw 'Clipboard changes reset the prepared Copy.' }
    $secondDestination = [string] (Join-Path $root 'sidebar-destination')
    [IO.Directory]::CreateDirectory($secondDestination) | Out-Null
    $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
        [object[]] @($secondDestination, [bool] $false, $null, $null, $null, $null))
    $window.Content = $pathview
    $entry = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.TreeEntry', $true), [object[]] @([string] 'folder', $folder))
    $directoryActions = $pathview.GetType().GetMethod('CreateDirectoryMenuActions', $flags).Invoke($pathview, [object[]] @($entry))
    Assert-ItemMenu $directoryActions ([string[]] @($folder)) $false $owner
    $directoryItemClipboardCopy = @($directoryActions | Where-Object { $_.Id -eq 'ItemClipboardCopy' })[0]
    if (-not $directoryItemClipboardCopy.IsEnabled) { throw 'Sidebar Item clipboard copy is disabled.' }
    $directoryItemClipboardCopy.Invoke.Invoke()
    Wait-Until { [System.Windows.Clipboard]::ContainsFileDropList() -and $folder -in @([System.Windows.Clipboard]::GetFileDropList()) } 'sidebar Item clipboard copy'
    $backgroundActions = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags).Invoke($pathview, @())
    Assert-ItemMenu $backgroundActions ([string[]] @($secondDestination)) $true $owner
    $backgroundItemClipboardPaste = @($backgroundActions | Where-Object { $_.Id -eq 'ItemClipboardPaste' })[0]
    if (-not $backgroundItemClipboardPaste.IsEnabled) { throw 'Background Item clipboard paste is disabled.' }
    $backgroundItemClipboardPaste.Invoke.Invoke()
    Wait-Until { [IO.File]::Exists((Join-Path $secondDestination 'test-folder/nested.txt')) } 'background Item clipboard paste'
    if (-not $copy.IsPrepared -or @($copy.PreparedPaths).Count -ne 2) { throw 'Sidebar clipboard actions changed the prepared Copy.' }
    $copy.Abort()
    [System.Windows.Clipboard]::SetText('sidebar copy sentinel')
    $directoryActions = $pathview.GetType().GetMethod('CreateDirectoryMenuActions', $flags).Invoke($pathview, [object[]] @($entry))
    $directoryCopyMarkItem = @($directoryActions | Where-Object { $_.Id -eq 'CopyMarkItem' })[0]
    $directoryCopyMarkItem.Invoke.Invoke()
    if (-not $copy.IsPrepared -or [System.Windows.Clipboard]::GetText() -cne 'sidebar copy sentinel') { throw 'Sidebar Copy mark item changed the clipboard or failed to prepare.' }
    $copy.Abort()
    $shellCopy = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('CopyToClipboard', $staticFlags)
    $containsItems = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('ClipboardContainsItems', $staticFlags)
    foreach ($case in @(@('Link', $link), @('Copy', $copy), @('Move', $move))) {
        $name = $case[0]
        $state = $case[1]
        $transferFile = [string] (Join-Path $source ($name + '-transfer.txt'))
        [IO.File]::WriteAllText($transferFile, $name)
        $state.Prepare([string[]] @($transferFile))
        $directoryItemClipboardCopy.Invoke.Invoke()
        Wait-Until { [System.Windows.Clipboard]::ContainsFileDropList() -and $folder -in @([System.Windows.Clipboard]::GetFileDropList()) } "$name with Item clipboard copy"
        if (-not $state.IsPrepared -or @($state.PreparedPaths)[0] -cne $transferFile) { throw "Item clipboard copy changed the prepared $name." }
        $caseFile = [string] (Join-Path $source ($name + '.txt'))
        [IO.File]::WriteAllText($caseFile, $name)
        $null = $shellCopy.Invoke($null, [object[]] @([string[]] @($caseFile), $owner))
        Wait-Until { $containsItems.Invoke($null, @()) } "$name clipboard copy availability"
        $backgroundActions = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags).Invoke($pathview, @())
        Assert-ItemMenu $backgroundActions ([string[]] @($secondDestination)) $true $owner
        $backgroundItemClipboardPaste = @($backgroundActions | Where-Object { $_.Id -eq 'ItemClipboardPaste' })[0]
        if (-not $backgroundItemClipboardPaste.IsEnabled) { throw "Item clipboard paste is disabled during $name." }
        $backgroundItemClipboardPaste.Invoke.Invoke()
        Wait-Until { [IO.File]::Exists((Join-Path $secondDestination ($name + '.txt'))) } "$name with Item clipboard paste"
        if (-not $state.IsPrepared -or @($state.PreparedPaths)[0] -cne $transferFile) { throw "Item clipboard paste changed the prepared $name." }
        $execute = @($backgroundActions | Where-Object { $_.Id -eq "${name}Execute" })[0]
        if (-not $execute.IsEnabled) { throw "$name execute is disabled." }
        $execute.Invoke.Invoke()
        $targetName = if ($name -eq 'Link') { "$name-transfer.txt - Shortcut.lnk" } else { "$name-transfer.txt" }
        Wait-Until { [IO.File]::Exists((Join-Path $secondDestination $targetName)) } "$name execute"
        if ($state.IsPrepared -or [IO.File]::Exists($transferFile) -ne ($name -ne 'Move')) { throw "$name execute did not complete correctly." }
    }
    $cutFile = [string] (Join-Path $source 'cut.txt')
    [IO.File]::WriteAllText($cutFile, 'cut')
    $factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
    $cutMenu = $factory.GetMethod('GetItemMenu', $staticFlags).Invoke($null, [object[]] @([string[]] @($cutFile), $owner, $null))
    try { $null = $cutMenu.GetType().GetMethod('InvokeVerb', $flags).Invoke($cutMenu, [object[]] @([string] 'cut')) }
    finally { ([IDisposable] $cutMenu).Dispose() }
    $copy.Prepare([string[]] @($file))
    $backgroundActions = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags).Invoke($pathview, @())
    $backgroundItemClipboardPaste = @($backgroundActions | Where-Object { $_.Id -eq 'ItemClipboardPaste' })[0]
    if ($backgroundItemClipboardPaste.IsEnabled) { throw 'Item clipboard paste is enabled for Shell Cut.' }
    $paste = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('PasteFromClipboard', $staticFlags)
    try { $null = $paste.Invoke($null, [object[]] @($secondDestination, $owner)); throw 'Direct paste accepted Shell Cut.' }
    catch { if ($_.Exception.GetBaseException() -isnot [InvalidOperationException]) { throw } }
    if (-not [IO.File]::Exists($cutFile) -or [IO.File]::Exists((Join-Path $secondDestination 'cut.txt')) -or
        -not $copy.IsPrepared -or @($copy.PreparedPaths)[0] -cne $file) { throw 'Rejected Shell Cut changed a file or the prepared Copy.' }
    $window.Content = $view
    Wait-Until { $view.IsLoaded -and -not $itemClipboardPaste.IsEnabled } 'ContentView rejects Shell Cut'
    foreach ($case in @(@('copy-only', 1, $true), @('copy-and-link', 5, $true), @('cut', 2, $false),
        @('link', 4, $false), @('copy-and-cut', 3, $false), @('all-effects', 7, $false),
        @('none', 0, $false), @('missing', -1, $false), @('short', -2, $false))) {
        $name, $effect, $allowed = $case
        $caseFile = [string] (Join-Path $source ("clipboard-$name.txt"))
        [IO.File]::WriteAllText($caseFile, $name)
        $data = [System.Windows.DataObject]::new()
        $fileList = [System.Collections.Specialized.StringCollection]::new()
        $null = $fileList.Add($caseFile)
        $data.SetFileDropList($fileList)
        if ($effect -ge 0) { $data.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] $effect))) }
        elseif ($effect -eq -2) { $data.SetData('Preferred DropEffect', [IO.MemoryStream]::new([byte[]] @(1))) }
        [System.Windows.Clipboard]::SetDataObject($data, $true)
        if ([bool] $containsItems.Invoke($null, @()) -ne $allowed) { throw "Incorrect clipboard availability for $name." }
        Wait-Until { $itemClipboardPaste.IsEnabled -eq $allowed } "clipboard button availability for $name"
        $backgroundActions = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags).Invoke($pathview, @())
        if ([bool] (@($backgroundActions | Where-Object { $_.Id -eq 'ItemClipboardPaste' })[0].IsEnabled) -ne $allowed) { throw "Incorrect menu availability for $name." }
        if ($allowed) {
            $null = $paste.Invoke($null, [object[]] @($secondDestination, $owner))
            if (-not [IO.File]::Exists($caseFile) -or -not [IO.File]::Exists((Join-Path $secondDestination ([IO.Path]::GetFileName($caseFile))))) { throw "Clipboard copy failed for $name." }
        } else {
            try { $null = $paste.Invoke($null, [object[]] @($secondDestination, $owner)); throw "Direct paste accepted $name." }
            catch { if ($_.Exception.GetBaseException() -isnot [InvalidOperationException]) { throw } }
            if ([IO.File]::Exists((Join-Path $secondDestination ([IO.Path]::GetFileName($caseFile)))) -or -not [IO.File]::Exists($caseFile)) { throw "Rejected $name changed files." }
        }
    }
    foreach ($case in @(@('external-copy', 1, $true), @('external-cut', 2, $false), @('external-link', 4, $false))) {
        $name, $effect, $allowed = $case
        $caseFile = [string] (Join-Path $source ("clipboard-$name.txt"))
        [IO.File]::WriteAllText($caseFile, $name)
        $escapedPath = $caseFile.Replace("'", "''")
        $script = "Add-Type -AssemblyName PresentationFramework; `$data = [System.Windows.DataObject]::new(); `$paths = [System.Collections.Specialized.StringCollection]::new(); `$null = `$paths.Add('$escapedPath'); `$data.SetFileDropList(`$paths); `$data.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] $effect))); [System.Windows.Clipboard]::SetDataObject(`$data, `$true)"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        & pwsh -NoProfile -STA -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) { throw "Could not set $name clipboard data from another process." }
        Wait-Until { $itemClipboardPaste.IsEnabled -eq $allowed } "external clipboard button availability for $name"
        if ([bool] $containsItems.Invoke($null, @()) -ne $allowed) { throw "Incorrect external clipboard availability for $name." }
        if ($allowed) {
            $null = $paste.Invoke($null, [object[]] @($secondDestination, $owner))
            if (-not [IO.File]::Exists($caseFile) -or -not [IO.File]::Exists((Join-Path $secondDestination ([IO.Path]::GetFileName($caseFile))))) { throw 'External clipboard copy failed.' }
        } else {
            try { $null = $paste.Invoke($null, [object[]] @($secondDestination, $owner)); throw "Direct paste accepted $name." }
            catch { if ($_.Exception.GetBaseException() -isnot [InvalidOperationException]) { throw } }
            if ([IO.File]::Exists((Join-Path $secondDestination ([IO.Path]::GetFileName($caseFile)))) -or -not [IO.File]::Exists($caseFile)) { throw "Rejected $name changed files." }
        }
    }
    Write-Output 'Item clipboard action tests passed.'
} finally {
    $copy.Abort(); $link.Abort(); $move.Abort()
    if ($null -eq $original) { [System.Windows.Clipboard]::Clear() }
    else { [System.Windows.Clipboard]::SetDataObject($original, $true) }
    $window.Close()
    [IO.Directory]::Delete($root, $true)
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
}