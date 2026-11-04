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
            $icon.Template -ne $view.Resources['ClipboardCopyIconTemplate']) { throw "$name clipboard copy has an incorrect label or icon." }
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
    if (-not $backgroundItemClipboardPaste.IsEnabled) { throw 'Item clipboard paste is disabled for Shell Cut.' }
    $backgroundItemClipboardPaste.Invoke.Invoke()
    Wait-Until { [IO.File]::Exists((Join-Path $secondDestination 'cut.txt')) -and -not [IO.File]::Exists($cutFile) } 'Shell Cut and Item clipboard paste'
    if (-not $copy.IsPrepared -or @($copy.PreparedPaths)[0] -cne $file) { throw 'Shell Cut and Item clipboard paste changed the prepared Copy.' }
    Write-Output 'Item clipboard action tests passed.'
} finally {
    $copy.Abort(); $link.Abort(); $move.Abort()
    if ($null -eq $original) { [System.Windows.Clipboard]::Clear() }
    else { [System.Windows.Clipboard]::SetDataObject($original, $true) }
    $window.Close()
    [IO.Directory]::Delete($root, $true)
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
}