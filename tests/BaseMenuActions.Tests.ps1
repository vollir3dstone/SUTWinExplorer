$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$parseErrors = $null
$suiteAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
$suiteHelpers = $suiteAst.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('public sealed class SutShellTestSignal') }, $true)
Add-Type -TypeDefinition $suiteHelpers.Value
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BaseMenuProbe
{
    [DllImport("user32.dll")] public static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] public static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint index, StringBuilder text, int length, uint flags);
}
'@
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$previousContext = [System.Threading.SynchronizationContext]::Current
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
$insert = $factory.GetMethod('InsertActions', [Reflection.BindingFlags]'Static,NonPublic')
$actionIds = @('Properties', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'ItemClipboardPaste', 'PrepareInternalLinking', 'LinkAbort', 'ExecuteInternalLinking', 'PrepareInternalCopying', 'CopyAbort', 'ExecuteInternalCopying', 'PrepareInternalMoving', 'MoveAbort', 'ExecuteInternalMoving', 'Rename', 'Delete')
$baseActionIds = @('Properties', 'PrepareClipboardCopying', 'PrepareClipboardLinking', 'PrepareClipboardMoving', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'AbortTransfer', 'PrepareInternalLinking', 'PrepareInternalCopying', 'PrepareInternalMoving', 'Rename', 'Relocate', 'Delete')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutBaseMenu-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
function Wait-SelectedPaths($view, [string[]] $expected) {
    $list = $view.FindName('FileList')
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $state = @{ Ready = $false }
    $timer.add_Tick({
        $paths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        if ($paths.Count -eq $expected.Count -and @($expected | Where-Object { $_ -notin $paths }).Count -eq 0) {
            $state.Ready = $true
            $frame.Continue = $false
        } elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) { throw "Could not select test items: $expected." }
}
function Assert-ClipboardText([string] $expected, [string] $description) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    $state = @{ Actual = ''; Ready = $false }
    $timer.add_Tick({
        $state.Actual = [System.Windows.Clipboard]::GetText()
        if ($state.Actual -ceq $expected) { $state.Ready = $true; $frame.Continue = $false }
        elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) { throw "$description expected=[$expected], actual=[$($state.Actual)]." }
}
function Assert-ClipboardFiles([string[]] $expected) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $state = @{ Ready = $false; Paths = @() }
    $timer.add_Tick({
        if ([System.Windows.Clipboard]::ContainsFileDropList()) {
            $state.Paths = @([System.Windows.Clipboard]::GetFileDropList())
            if ($state.Paths.Count -eq $expected.Count -and @($expected | Where-Object { $_ -notin $state.Paths }).Count -eq 0) {
                $state.Ready = $true
                $frame.Continue = $false
            }
        }
        if ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) { throw "Incorrect clipboard files: expected=$expected, actual=$($state.Paths)." }
    $effect = [System.Windows.Clipboard]::GetDataObject().GetData('Preferred DropEffect', $false)
    $value = if ($effect -is [IO.MemoryStream]) { [BitConverter]::ToUInt32($effect.ToArray(), 0) } elseif ($effect -is [byte[]]) { [BitConverter]::ToUInt32($effect, 0) } else { $effect }
    if (($value -band 3) -ne 1) { throw "Clipboard does not contain a Shell copy effect: $value." }
}
function Assert-PropertiesDialog($action, [string] $titlePart, [string] $description) {
    if (-not $action.IsEnabled) { throw "Properties was disabled for $description." }
    $probe = [SutShellPropertiesProbe]::new($titlePart)
    try {
        $action.Invoke.Invoke()
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(50)
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $timer.add_Tick({ if ($probe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        if (-not $probe.Opened) { throw "Properties did not open a Shell dialog for $description." }
    } finally { $probe.Dispose() }
}
function Assert-Menu($actions, [string[]] $expected, [string[]] $disabled) {
    if ((@($actions | ForEach-Object { $_.Id }) -join ',') -cne ($baseActionIds -join ',')) { throw 'Incorrect action IDs.' }
    $menu = [BaseMenuProbe]::CreatePopupMenu()
    try {
        if (-not [BaseMenuProbe]::AppendMenu($menu, 0, [UIntPtr] 1, 'Shell command')) { throw 'Could not create fixture menu.' }
        $null = $insert.Invoke($null, [object[]] @($menu, $actions))
        $actual = @()
        for ($index = 0; $index -lt [BaseMenuProbe]::GetMenuItemCount($menu); $index++) {
            $state = [BaseMenuProbe]::GetMenuState($menu, $index, 0x400)
            if (($state -band 0x800) -ne 0) { $actual += '|'; continue }
            $command = [BaseMenuProbe]::GetMenuItemID($menu, $index)
            if ($command -eq 1) { $actual += 'Shell command'; continue }
            $actionIndex = [int] $command - 0x8000
            if ($actionIndex -lt 0 -or $actionIndex -ge $actions.Count) { throw "Incorrect command ID: $command." }
            $id = $actions[$actionIndex].Id
            $actual += $id
            if ((($state -band 3) -ne 0) -ne ($id -in $disabled)) { throw "Incorrect enabled state for $id (state=$state, disabled=$($disabled -join ','))." }
        }
        if (($actual -join ',') -cne ($expected -join ',')) { throw "Incorrect menu: $($actual -join ','); expected $($expected -join ',')." }
    } finally { $null = [BaseMenuProbe]::DestroyMenu($menu) }
}
function Assert-ShellMenu($actions, [string[]] $expected, [bool] $background, [IntPtr] $owner) {
    $create = $factory.GetMethod('GetBaseMenuForContext', [Reflection.BindingFlags]'Static,NonPublic')
    $instance = $create.Invoke($null, [object[]] @([string[]] @($directory), $owner, $actions, $background))
    try {
        $menu = $instance.GetType().GetField('_menu', $flags).GetValue($instance)
        $count = [BaseMenuProbe]::GetMenuItemCount($menu)
        for ($index = 0; $index -lt $count; $index++) {
            $state = [BaseMenuProbe]::GetMenuState($menu, $index, 0x400)
            $command = [BaseMenuProbe]::GetMenuItemID($menu, $index)
            if ($index -ge $expected.Count -and $index -lt $count - 5) {
                if ($command -ge 0x8000 -and $command -ne [uint]::MaxValue) { throw 'Application action appeared in the Shell section.' }
                if ($command -ge 1 -and $command -le 0x7fff) {
                    $shellMenu = $instance.GetType().GetField('_contextMenu', $flags).GetValue($instance)
                    $getVerb = $factory.GetMethod('GetCommandVerb', [Reflection.BindingFlags]'Static,NonPublic')
                    if ($getVerb.Invoke($null, [object[]] @($shellMenu, [uint] ($command - 1))) -eq 'properties') { throw 'Duplicate Shell properties command.' }
                }
                continue
            }
            $expectedItem = if ($index -lt $expected.Count) { $expected[$index] } else { @('|', 'Rename', 'Relocate', '|', 'Delete')[$index - ($count - 5)] }
            $actual = if (($state -band 0x800) -ne 0) { '|' } else {
                $actionIndex = [int] $command - 0x8000
                if ($actionIndex -lt 0 -or $actionIndex -ge $actions.Count) { throw "Incorrect Shell menu command ID: $command." }
                $actions[$actionIndex].Id
            }
            if ($actual -cne $expectedItem) { throw "Incorrect Shell menu item at ${index}: $actual; expected $expectedItem." }
        }
    } finally { ([IDisposable] $instance).Dispose() }
}
try {
    $testFile = Join-Path $directory 'name with spaces.txt'
    $testFolder = Join-Path $directory 'test-folder'
    [IO.File]::WriteAllText($testFile, 'test')
    [IO.Directory]::CreateDirectory($testFolder) | Out-Null
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Show()
    $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
        [object[]] @([string] $directory, [bool] $false, $null, $null, $null, $null))
    $view = $pathview.FindName('DirectoryContent')
    if ($pathview.EnableInternalItemTransfers -or $view.EnableInternalItemTransfers -or
        $pathview.FindName('MoveMarkCurrentDirectoryButton').Visibility -ne 'Collapsed' -or
        @('TransferMarkItemButtons', 'LinkTransferButtons', 'CopyTransferButtons', 'MoveTransferButtons' | Where-Object { $view.FindName($_).Visibility -ne 'Collapsed' }).Count -ne 0) { throw 'Internal transfer controls were not hidden by default.' }
    foreach ($name in $actionIds) {
        [System.Windows.Automation.AutomationProperties]::SetName($view.FindName($name + 'Button'), 'Lokalisierte Aktion')
    }
    $createContent = $view.GetType().GetMethod('CreateContextMenuActions', $flags)
    $createDirectory = $pathview.GetType().GetMethod('CreateDirectoryMenuActions', $flags)
    $createBackground = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags)
    $entry = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.TreeEntry', $true), [object[]] @([string] 'folder', [string] $directory))
    $link = $assembly.GetType('SUTWinExplorer.LinkWorkflowState', $true).GetProperty('Shared').GetValue($null)
    $copy = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
    $move = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
    $copy.Prepare([string[]] @($directory))
    foreach ($actions in @($createContent.Invoke($view, @()), $createDirectory.Invoke($pathview, [object[]] @($entry)), $createBackground.Invoke($pathview, @()))) {
        $ids = @($actions | ForEach-Object { $_.Id })
        if (@($ids | Where-Object { $_ -in @('AbortTransfer', 'PrepareInternalLinking', 'PrepareInternalCopying', 'PrepareInternalMoving') }).Count -ne 0 -or
            @($ids | Where-Object { $_ -in @('PrepareClipboardCopying', 'PrepareClipboardLinking', 'PrepareClipboardMoving') }).Count -ne 3) { throw 'Disabled internal transfers affected the wrong Base Menu actions.' }
    }
    $contentTransfers = $view.GetType().GetMethod('CreateContentTransferActions', $flags)
    if (@($contentTransfers.Invoke($view, [object[]] @([string] $directory)) | Where-Object { $_.Id -in @('AbortTransfer', 'ExecuteInternalCopying') }).Count -ne 0) { throw 'Disabled internal transfer appeared in the Content Menu.' }
    if (-not $copy.IsPrepared) { throw 'Hiding internal transfers discarded the prepared transfer.' }
    $pathview.EnableInternalItemTransfers = $true
    if (@($contentTransfers.Invoke($view, [object[]] @([string] $directory)) | Where-Object { $_.Id -in @('AbortTransfer', 'ExecuteInternalCopying') }).Count -ne 2 -or
        $pathview.FindName('MoveMarkCurrentDirectoryButton').Visibility -ne 'Visible' -or
        @('TransferMarkItemButtons', 'LinkTransferButtons', 'CopyTransferButtons', 'MoveTransferButtons' | Where-Object { $view.FindName($_).Visibility -ne 'Visible' }).Count -ne 0) { throw 'Enabling internal transfers did not restore their actions.' }
    $copy.Abort()
    foreach ($case in @('Idle', 'Link', 'Copy', 'Move')) {
        if ($case -eq 'Link') { $link.Prepare([string[]] @($directory)) }
        if ($case -eq 'Copy') { $copy.Prepare([string[]] @($directory)) }
        if ($case -eq 'Move') { $move.Prepare([string[]] @($directory)) }
        $head = @('Properties', '|', 'PrepareClipboardCopying', 'PrepareClipboardLinking', 'PrepareClipboardMoving', '|', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', '|', 'AbortTransfer', 'PrepareInternalLinking', 'PrepareInternalCopying', 'PrepareInternalMoving')
        $expected = $head + @('|', 'Shell command', '|', 'Rename', 'Relocate', '|', 'Delete')
        $clipboardReady = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('ClipboardContainsItems', [Reflection.BindingFlags]'Static,NonPublic').Invoke($null, @())
        $directoryActions = $createDirectory.Invoke($pathview, [object[]] @($entry))
        $directoryDisabled = @(if ($case -eq 'Idle') { 'AbortTransfer' } else { 'PrepareInternalLinking', 'PrepareInternalCopying', 'PrepareInternalMoving', 'Delete' })
        Assert-Menu $directoryActions $expected $directoryDisabled
        Assert-ShellMenu $directoryActions $head $false $owner
        $backgroundExpected = $expected
        $backgroundActions = $createBackground.Invoke($pathview, @())
        $backgroundDisabled = $directoryDisabled
        Assert-Menu $backgroundActions $backgroundExpected $backgroundDisabled
        Assert-ShellMenu $backgroundActions $head $true $owner
        $contentBackground = $view.GetType().GetMethod('CreateContextMenuActionsForContext', $flags).Invoke($view, [object[]] @($true))
        Assert-Menu $contentBackground $backgroundExpected $backgroundDisabled
        foreach ($name in $actionIds) {
            $enabled = switch ($name) {
                'Properties' { $true } 'Rename' { $true } 'NameClipboardCopy' { $true } 'PathClipboardCopy' { $true } 'ItemClipboardCopy' { $true } 'ItemClipboardPaste' { $clipboardReady } 'Delete' { $case -eq 'Idle' }
                'PrepareInternalLinking' { $case -eq 'Idle' } 'PrepareInternalCopying' { $case -eq 'Idle' } 'PrepareInternalMoving' { $case -eq 'Idle' }
                'LinkAbort' { $case -eq 'Link' } 'ExecuteInternalLinking' { $case -eq 'Link' }
                'CopyAbort' { $case -eq 'Copy' } 'ExecuteInternalCopying' { $case -eq 'Copy' }
                'MoveAbort' { $case -eq 'Move' } 'ExecuteInternalMoving' { $case -eq 'Move' }
            }
            $view.FindName($name + 'Button').IsEnabled = $enabled
        }
        Assert-Menu ($createContent.Invoke($view, @())) $expected ($directoryDisabled + @('Relocate', 'PrepareClipboardCopying', 'PrepareClipboardLinking', 'PrepareClipboardMoving'))
        $link.Abort()
        $copy.Abort()
        $move.Abort()
    }
    $rootView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $rootView.EnableInternalItemTransfers = $true
    $null = $rootView.GetType().GetMethod('SetCurrentPath', $flags).Invoke($rootView, [object[]] @([string] [IO.Path]::GetPathRoot($directory)))
    $rootActions = $rootView.GetType().GetMethod('CreateActiveDirectoryMenuActions', $flags).Invoke($rootView, @())
    foreach ($id in @('PrepareInternalMoving', 'Rename', 'Relocate', 'Delete')) {
        if ((@($rootActions | Where-Object { $_.Id -eq $id })[0].IsEnabled)) { throw "$id was enabled for a drive root." }
    }
    $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
    try {
        $pathview.EnableInternalItemTransfers = $false
        $copy.Prepare([string[]] @($testFile))
        foreach ($effect in @(1, 2, 4)) {
            $clipboardData = [System.Windows.DataObject]::new()
            $clipboardPaths = [System.Collections.Specialized.StringCollection]::new()
            [void] $clipboardPaths.Add($testFile)
            $clipboardData.SetFileDropList($clipboardPaths)
            $clipboardData.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] $effect)))
            [System.Windows.Clipboard]::SetDataObject($clipboardData, $true)
            $ids = @($contentTransfers.Invoke($view, [object[]] @([string] $directory)) | ForEach-Object Id)
            $expectedId = switch ($effect) { 1 { 'ExecuteClipboardCopying' } 2 { 'ExecuteClipboardMoving' } 4 { 'ExecuteClipboardLinking' } }
            if ($expectedId -notin $ids -or 'AbortTransfer' -in $ids -or 'ExecuteInternalCopying' -in $ids) { throw "Clipboard effect $effect was affected by disabled internal transfers." }
            if ($effect -in @(2, 4) -and @('Action_AbortClipboardMoving', 'Action_AbortClipboardLinking' | Where-Object { $_ -in $ids }).Count -ne 1) { throw "Clipboard effect $effect lost its abort action." }
        }
        if (-not $copy.IsPrepared) { throw 'Clipboard actions changed the hidden internal transfer.' }
        $copy.Abort()
        $pathview.EnableInternalItemTransfers = $true
        $window.Content = $pathview
        $window.Width = 800
        $window.Height = 500
        $window.UpdateLayout()
        $nameButton = $view.FindName('NameClipboardCopyButton')
        $pathButton = $view.FindName('PathClipboardCopyButton')
        $namePosition = $nameButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $pathPosition = $pathButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        if ($namePosition.X + $nameButton.ActualWidth -gt $pathPosition.X -or [Math]::Abs($namePosition.Y - $pathPosition.Y) -gt 1) {
            throw 'Name clipboard copy was not laid out directly before Path clipboard copy.'
        }
        $linkButton = $view.FindName('PrepareInternalLinkingButton')
        $itemButton = $view.FindName('ItemClipboardCopyButton')
        $copyButton = $view.FindName('PrepareInternalCopyingButton')
        $itemPosition = $itemButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $linkPosition = $linkButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $copyPosition = $copyButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        if ($pathPosition.X + $pathButton.ActualWidth -gt $itemPosition.X -or $itemPosition.X + $itemButton.ActualWidth -gt $linkPosition.X -or $linkPosition.X + $linkButton.ActualWidth -gt $copyPosition.X -or
            [Math]::Abs($pathPosition.Y - $linkPosition.Y) -gt 1 -or [Math]::Abs($linkPosition.Y - $copyPosition.Y) -gt 1) {
            throw 'Item clipboard copy and Link mark item were not laid out between Path clipboard copy and Copy mark item.'
        }
        $renameButton = $view.FindName('RenameButton')
        $deleteButton = $view.FindName('DeleteButton')
        $renamePosition = $renameButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $deletePosition = $deleteButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        if ($renamePosition.X + $renameButton.ActualWidth -gt $deletePosition.X -or [Math]::Abs($renamePosition.Y - $deletePosition.Y) -gt 1) {
            throw 'Rename was not laid out directly before Delete.'
        }
        $reveal = $view.GetType().GetMethod('RevealInsertedItems', $flags)
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFile)))
        Wait-SelectedPaths $view ([string[]] @($testFile))
        foreach ($backgroundKind in @('Content', 'Sidebar')) {
            $backgroundActions = if ($backgroundKind -eq 'Content') {
                $view.GetType().GetMethod('CreateContextMenuActionsForContext', $flags).Invoke($view, [object[]] @($true))
            } else { $createBackground.Invoke($pathview, @()) }
            foreach ($case in @(@('NameClipboardCopy', [IO.Path]::GetFileName($directory)), @('PathClipboardCopy', $directory))) {
                @($backgroundActions | Where-Object { $_.Id -eq $case[0] })[0].Invoke.Invoke()
                Assert-ClipboardText $case[1] "$backgroundKind background copied the wrong directory value:"
            }
            @($backgroundActions | Where-Object { $_.Id -eq 'ItemClipboardCopy' })[0].Invoke.Invoke()
            Assert-ClipboardFiles ([string[]] @($directory))
            foreach ($transferCase in @(@('Link', $link), @('Copy', $copy), @('Move', $move))) {
                $operation, $state = $transferCase
                $actions = if ($backgroundKind -eq 'Content') {
                    $view.GetType().GetMethod('CreateContextMenuActionsForContext', $flags).Invoke($view, [object[]] @($true))
                } else { $createBackground.Invoke($pathview, @()) }
                @($actions | Where-Object { $_.Id -eq "${operation}MarkItem" })[0].Invoke.Invoke()
                if (-not $state.IsPrepared -or @($state.PreparedPaths).Count -ne 1 -or $state.PreparedPaths[0] -cne $directory) {
                    throw "$backgroundKind background marked the selection instead of the active directory for $operation."
                }
                $state.Abort()
            }
            Wait-SelectedPaths $view ([string[]] @($testFile))
            foreach ($dialogCase in @(@('Rename'), @('Relocate'))) {
                $dialogState = @{ Seen = $false }
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(25)
                $timer.add_Tick({
                    $dialog = @([System.Windows.Application]::Current.Windows | Where-Object { $_.GetType().FullName -eq 'SUTWinExplorer.DirectoryLocationDialog' -and $_.IsVisible }) | Select-Object -First 1
                    if ($null -ne $dialog) { $dialogState.Seen = $true; $dialog.DialogResult = $false }
                }.GetNewClosure())
                $timer.Start()
                try { @($backgroundActions | Where-Object { $_.Id -eq $dialogCase[0] })[0].Invoke.Invoke() }
                finally { $timer.Stop() }
                if (-not $dialogState.Seen -or $pathview.CurrentPath -cne $directory) { throw "$backgroundKind background $($dialogCase[0]) did not open the active directory dialog." }
            }
        }
        if (-not (@($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'Relocate' })[0].IsEnabled)) { throw 'Relocate was disabled for a single file.' }
        if (-not $view.FindName('NameClipboardCopyButton').IsEnabled) { throw 'Name clipboard copy was disabled for a single file.' }
        $view.FindName('NameClipboardCopyButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText 'name with spaces.txt' 'Name clipboard copy copied an incorrect file name:'
        Wait-SelectedPaths $view ([string[]] @($testFile))
        $view.FindName('PathClipboardCopyButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText $testFile 'Path clipboard copy copied an incorrect file path:'
        Wait-SelectedPaths $view ([string[]] @($testFile))
        $contentAction = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'NameClipboardCopy' })[0]
        $contentAction.Invoke.Invoke()
        Assert-ClipboardText 'name with spaces.txt' 'Content menu Name clipboard copy copied an incorrect file name:'
        Wait-SelectedPaths $view ([string[]] @($testFile))
        $propertiesAction = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'Properties' })[0]
        Assert-PropertiesDialog $propertiesAction 'name with spaces.txt' 'a single file'
        $directoryAction = @($createDirectory.Invoke($pathview, [object[]] @($entry)) | Where-Object { $_.Id -eq 'Properties' })[0]
        Assert-PropertiesDialog $directoryAction ([IO.Path]::GetFileName($directory)) 'the sidebar directory'
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFolder)))
        Wait-SelectedPaths $view ([string[]] @($testFolder))
        if (-not (@($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'Relocate' })[0].IsEnabled)) { throw 'Relocate was disabled for a single directory.' }
        $view.FindName('NameClipboardCopyButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText 'test-folder' 'Name clipboard copy copied an incorrect folder name:'
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFile, $testFolder)))
        Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
        if ((@($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'Relocate' })[0].IsEnabled)) { throw 'Relocate was enabled for multiple items.' }
        if (-not $nameButton.IsEnabled -or -not $pathButton.IsEnabled) { throw 'Name clipboard copy or Path clipboard copy was disabled for multiple items.' }
        foreach ($actionId in @('NameClipboardCopy', 'PathClipboardCopy')) {
            Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
            $selectedPaths = @($view.FindName('FileList').SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $expectedNames = @($selectedPaths | ForEach-Object { [IO.Path]::GetFileName($_) }) -join [Environment]::NewLine
            $expectedPaths = $selectedPaths -join [Environment]::NewLine
            $expectedText = if ($actionId -eq 'NameClipboardCopy') { $expectedNames } else { $expectedPaths }
            $view.FindName($actionId + 'Button').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-ClipboardText $expectedText "$actionId copied incorrect text for multiple items:"
            if ([System.Windows.Clipboard]::ContainsFileDropList()) { throw "$actionId unexpectedly copied a file-drop list." }
            Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
            $selectedPaths = @($view.FindName('FileList').SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $expectedText = if ($actionId -eq 'NameClipboardCopy') { @($selectedPaths | ForEach-Object { [IO.Path]::GetFileName($_) }) -join [Environment]::NewLine } else { $selectedPaths -join [Environment]::NewLine }
            $action = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq $actionId })[0]
            if (-not $action.IsEnabled) { throw "$actionId was disabled in the Base Menu for multiple items." }
            [System.Windows.Clipboard]::SetText('clipboard test sentinel')
            $action.Invoke.Invoke()
            Assert-ClipboardText $expectedText "Base Menu $actionId copied incorrect text for multiple items:"
        }
        foreach ($source in @('toolbar', 'content')) {
            Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
            [System.Windows.Clipboard]::SetText('clipboard test sentinel')
            if ($copy.IsPrepared) { throw "Copy was unexpectedly prepared before $source Item clipboard copy." }
            $link.Prepare([string[]] @($testFolder))
            $errorProbe = [SutShellPropertiesProbe]::new('Operation failed')
            try {
                if ($source -eq 'toolbar') {
                    $itemButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                } else {
                    $itemAction = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'ItemClipboardCopy' })[0]
                    $itemAction.Invoke.Invoke()
                }
                if ($errorProbe.Opened) { throw "$source Item clipboard copy displayed an error dialog." }
            } finally { $errorProbe.Dispose() }
            if ($copy.IsPrepared -or -not $link.IsPrepared -or @($link.PreparedPaths)[0] -cne $testFolder) { throw "$source Item clipboard copy changed the transfer state." }
            Assert-ClipboardFiles ([string[]] @($testFile, $testFolder))
            $link.Abort()
        }
        [System.Windows.Clipboard]::SetText('clipboard test sentinel')
        $directoryItem = @($createDirectory.Invoke($pathview, [object[]] @($entry)) | Where-Object { $_.Id -eq 'ItemClipboardCopy' })[0]
        $errorProbe = [SutShellPropertiesProbe]::new('Operation failed')
        try {
            $directoryItem.Invoke.Invoke()
            if ($errorProbe.Opened) { throw 'Sidebar Item clipboard copy displayed an error dialog.' }
        } finally { $errorProbe.Dispose() }
        if ($copy.IsPrepared) { throw 'Sidebar Item clipboard copy prepared a Copy transfer.' }
        Assert-ClipboardFiles ([string[]] @($directory))
        [System.Windows.Clipboard]::SetText('clipboard test sentinel')
        Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
        $copyButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        if (-not $copy.IsPrepared -or @($copy.PreparedPaths).Count -ne 2) { throw 'Copy mark item did not stage the selected items.' }
        Assert-ClipboardText 'clipboard test sentinel' 'Copy mark item changed the clipboard:'
        $copy.Abort()
        $shellCopy = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('CopyToClipboard', [Reflection.BindingFlags]'Static,NonPublic')
        foreach ($transfer in @('Idle', 'Copy', 'Link', 'Move')) {
            if ($transfer -eq 'Copy') { $copy.Prepare([string[]] @($testFolder)) }
            if ($transfer -eq 'Link') { $link.Prepare([string[]] @($testFolder)) }
            if ($transfer -eq 'Move') { $move.Prepare([string[]] @($testFolder)) }
            $null = $shellCopy.Invoke($null, [object[]] @([string[]] @($testFile), $owner))
            Assert-ClipboardFiles ([string[]] @($testFile))
            if ($copy.IsPrepared -ne ($transfer -eq 'Copy') -or $link.IsPrepared -ne ($transfer -eq 'Link') -or
                $move.IsPrepared -ne ($transfer -eq 'Move')) { throw "External Shell copy changed the $transfer workflow." }
            foreach ($state in @($copy, $link, $move)) {
                if ($state.IsPrepared -and @($state.PreparedPaths)[0] -cne $testFolder) { throw "External Shell copy replaced the $transfer paths." }
                $state.Abort()
            }
        }
        Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
        $propertiesAction = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'Properties' })[0]
        if (-not $view.FindName('PropertiesButton').IsEnabled) { throw 'Properties was disabled for multiple selected items.' }
        Assert-PropertiesDialog $propertiesAction '' 'multiple selected items'
        Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
        if ($copy.IsPrepared) { throw 'Copy was unexpectedly prepared before Link mark item.' }
        $PrepareInternalLinking = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'PrepareInternalLinking' })[0]
        $PrepareInternalLinking.Invoke.Invoke()
        if (-not $link.IsPrepared -or @($link.PreparedPaths).Count -ne 2 -or
            -not $view.FindName('LinkAbortButton').IsEnabled -or -not $view.FindName('ExecuteInternalLinkingButton').IsEnabled -or
            $view.FindName('PrepareInternalLinkingButton').IsEnabled -or $copyButton.IsEnabled -or
            $view.FindName('PrepareInternalMovingButton').IsEnabled -or $deleteButton.IsEnabled) { throw 'Prepared Link states were incorrect.' }
        $view.FindName('ExecuteInternalLinkingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $shortcuts = [string[]] @((Join-Path $directory 'name with spaces.txt - Shortcut.lnk'), (Join-Path $directory 'test-folder - Shortcut.lnk'))
        if ($link.IsPrepared -or @($shortcuts | Where-Object { -not [IO.File]::Exists($_) }).Count -ne 0 -or
            -not [IO.File]::Exists($testFile) -or -not [IO.Directory]::Exists($testFolder)) { throw 'Link execute did not create shortcuts and retain the sources.' }
        Wait-SelectedPaths $view $shortcuts
        $directoryLink = @($createDirectory.Invoke($pathview, [object[]] @($entry)) | Where-Object { $_.Id -eq 'PrepareInternalLinking' })[0]
        $directoryLink.Invoke.Invoke()
        if (-not $link.IsPrepared -or @($link.PreparedPaths)[0] -cne $directory) { throw 'Sidebar Link mark item did not prepare its directory.' }
        $linkAbort = @($createBackground.Invoke($pathview, @()) | Where-Object { $_.Id -eq 'AbortTransfer' })[0]
        $linkAbort.Invoke.Invoke()
        if ($link.IsPrepared) { throw 'Background Link abort did not clear the workflow.' }
        $disappearing = Join-Path $directory 'disappearing.txt'
        [IO.File]::WriteAllText($disappearing, 'temporary')
        $link.Prepare([string[]] @($disappearing))
        [IO.File]::Delete($disappearing)
        $errorProbe = [SutShellPropertiesProbe]::new('Operation failed')
        try {
            $view.FindName('ExecuteInternalLinkingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            if (-not $errorProbe.Opened -or -not $link.IsPrepared -or -not $view.FindName('ExecuteInternalLinkingButton').IsEnabled -or
                [IO.File]::Exists((Join-Path $directory 'disappearing.txt - Shortcut.lnk'))) {
                throw 'Failed Link execute did not report the error and retain the prepared workflow.'
            }
        } finally { $errorProbe.Dispose(); $link.Abort() }
        $view.FindName('FileList').SelectedItems.Clear()
        if ($nameButton.IsEnabled -or $pathButton.IsEnabled) { throw 'Name clipboard copy or Path clipboard copy was enabled without a selection.' }
        $directoryAction = @($createDirectory.Invoke($pathview, [object[]] @($entry)) | Where-Object { $_.Id -eq 'NameClipboardCopy' })[0]
        $directoryAction.Invoke.Invoke()
        Assert-ClipboardText ([IO.Path]::GetFileName($directory)) 'Directory menu Name clipboard copy copied an incorrect folder name:'
        $getName = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('GetFileSystemName', [Reflection.BindingFlags]'Static,NonPublic')
        foreach ($case in @(@('C:\', 'C:'), @('C:\folder\', 'folder'), @('\\server\share\', 'share'))) {
            if ($getName.Invoke($null, [object[]] @($case[0])) -cne $case[1]) { throw "Incorrect filesystem name for $($case[0])." }
        }
    } finally {
        if ($null -eq $originalClipboard) { [System.Windows.Clipboard]::Clear() }
        else { [System.Windows.Clipboard]::SetDataObject($originalClipboard, $true) }
    }
} finally {
    if ($null -ne $link) { $link.Abort() }
    if ($null -ne $copy) { $copy.Abort() }
    if ($null -ne $move) { $move.Abort() }
    if ($null -ne $window) { $window.Close() }
    [IO.Directory]::Delete($directory, $true)
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
}
Write-Host 'Base menu action tests passed.'